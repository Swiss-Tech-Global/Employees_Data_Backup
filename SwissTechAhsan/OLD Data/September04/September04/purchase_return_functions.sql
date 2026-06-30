-- ==============================================================
-- 🔹 Create Purchase Return
-- ==============================================================
CREATE OR REPLACE FUNCTION create_purchase_return(
    p_party_name TEXT,
    p_serials JSONB
)
RETURNS BIGINT AS $$
DECLARE
    v_party_id BIGINT;
    v_return_id BIGINT;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
BEGIN
    -- 1. Find Vendor
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_party_name;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Vendor % not found', p_party_name;
    END IF;

    -- 2. Create Return Header
    INSERT INTO PurchaseReturns(vendor_id, return_date, total_amount)
    VALUES (v_party_id, CURRENT_DATE, 0)
    RETURNING purchase_return_id INTO v_return_id;

    -- 3. Process each serial
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT pu.unit_id, pu.serial_number, pi.item_id, pi.unit_price, p.vendor_id, p.purchase_invoice_id
        INTO v_unit
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
        END IF;

        -- check if in stock
        IF NOT EXISTS (
            SELECT 1 FROM PurchaseUnits WHERE unit_id = v_unit.unit_id AND in_stock = TRUE
        ) THEN
            RAISE EXCEPTION 'Serial % is not currently in stock', v_serial;
        END IF;

        -- check vendor match
        IF v_unit.vendor_id <> v_party_id THEN
            RAISE EXCEPTION 'Serial % was purchased from a different vendor', v_serial;
        END IF;

        -- mark as returned (remove from stock)
        UPDATE PurchaseUnits 
        SET in_stock = FALSE 
        WHERE unit_id = v_unit.unit_id;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'OUT', 'PurchaseReturn', v_return_id, 1);

        -- insert return line (✅ unit_price instead of cost_price)
        INSERT INTO PurchaseReturnItems(purchase_return_id, item_id, unit_price, serial_number)
        VALUES (v_return_id, v_unit.item_id, v_unit.unit_price, v_serial);

        -- accumulate total
        v_total := v_total + v_unit.unit_price;
    END LOOP;

    -- 4. Update header total
    UPDATE PurchaseReturns
    SET total_amount = v_total
    WHERE purchase_return_id = v_return_id;

    -- 5. Build Journal
    PERFORM rebuild_purchase_return_journal(v_return_id);

    RETURN v_return_id;
END;
$$ LANGUAGE plpgsql;



-- ==============================================================
-- 🔹 Update Purchase Return
-- ==============================================================
CREATE OR REPLACE FUNCTION update_purchase_return(
    p_return_id BIGINT,
    p_serials JSONB
)
RETURNS VOID AS $$
DECLARE
    rec RECORD;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
    v_vendor_id BIGINT;
BEGIN
    -- 1. Get vendor id from return header
    SELECT vendor_id INTO v_vendor_id
    FROM PurchaseReturns
    WHERE purchase_return_id = p_return_id;

    IF v_vendor_id IS NULL THEN
        RAISE EXCEPTION 'Purchase Return % not found', p_return_id;
    END IF;

    -- 2. Reverse old items (restore stock)
    FOR rec IN
        SELECT serial_number, item_id
        FROM PurchaseReturnItems
        WHERE purchase_return_id = p_return_id
    LOOP
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE serial_number = rec.serial_number;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'PurchaseReturn-Update-Reverse', p_return_id, 1);
    END LOOP;

    -- 3. Remove old items
    DELETE FROM PurchaseReturnItems WHERE purchase_return_id = p_return_id;

    -- 4. Insert new items
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT pu.unit_id, pu.serial_number, pi.item_id, pi.unit_price, p.vendor_id
        INTO v_unit
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
        END IF;

        -- check if in stock
        IF NOT EXISTS (
            SELECT 1 FROM PurchaseUnits WHERE unit_id = v_unit.unit_id AND in_stock = TRUE
        ) THEN
            RAISE EXCEPTION 'Serial % is not currently in stock', v_serial;
        END IF;

        -- check vendor match
        IF v_unit.vendor_id <> v_vendor_id THEN
            RAISE EXCEPTION 'Serial % was purchased from a different vendor', v_serial;
        END IF;

        -- mark as returned (out of stock)
        UPDATE PurchaseUnits 
        SET in_stock = FALSE 
        WHERE unit_id = v_unit.unit_id;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'OUT', 'PurchaseReturn-Update', p_return_id, 1);

        -- insert return line (✅ unit_price instead of cost_price)
        INSERT INTO PurchaseReturnItems(purchase_return_id, item_id, unit_price, serial_number)
        VALUES (p_return_id, v_unit.item_id, v_unit.unit_price, v_serial);

        v_total := v_total + v_unit.unit_price;
    END LOOP;

    -- 5. Update header total
    UPDATE PurchaseReturns
    SET total_amount = v_total
    WHERE purchase_return_id = p_return_id;

    -- 6. Rebuild journal
    PERFORM rebuild_purchase_return_journal(p_return_id);
END;
$$ LANGUAGE plpgsql;



-- ==============================================================
-- 🔹 Delete Purchase Return
-- ==============================================================

CREATE OR REPLACE FUNCTION delete_purchase_return(
    p_return_id BIGINT
)
RETURNS VOID AS $$
DECLARE
    rec RECORD;
    v_vendor_id BIGINT;
    v_unit_vendor_id BIGINT;
    v_journal_id BIGINT;
BEGIN
    -- 1. Get vendor id from return header
    SELECT vendor_id, journal_id
    INTO v_vendor_id, v_journal_id
    FROM PurchaseReturns
    WHERE purchase_return_id = p_return_id;

    IF v_vendor_id IS NULL THEN
        RAISE EXCEPTION 'Purchase Return % not found', p_return_id;
    END IF;

    -- 2. Restore stock for returned items
    FOR rec IN
        SELECT serial_number, item_id
        FROM PurchaseReturnItems
        WHERE purchase_return_id = p_return_id
    LOOP
        -- fetch the vendor of the original purchase for safety
        SELECT p.vendor_id
        INTO v_unit_vendor_id
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = rec.serial_number;

        IF v_unit_vendor_id IS DISTINCT FROM v_vendor_id THEN
            RAISE EXCEPTION 'Serial % does not belong to vendor % (return %)', 
                rec.serial_number, v_vendor_id, p_return_id;
        END IF;

        -- restore in stock
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE serial_number = rec.serial_number;

        -- log stock IN
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'PurchaseReturn-Delete', p_return_id, 1);
    END LOOP;

    -- 3. Remove journal (if exists)
    IF v_journal_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = v_journal_id;
    END IF;

    -- 4. Delete return items
    DELETE FROM PurchaseReturnItems WHERE purchase_return_id = p_return_id;

    -- 5. Delete return header
    DELETE FROM PurchaseReturns WHERE purchase_return_id = p_return_id;
END;
$$ LANGUAGE plpgsql;


