-- ===========================================================================================
-----------------------------------🔹 Sales Return Function--------------------------------
-- ===========================================================================================
CREATE OR REPLACE FUNCTION create_sale_return(
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
    v_cost NUMERIC(14,2) := 0;
BEGIN
    -- 1. Find Customer
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_party_name;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Customer % not found', p_party_name;
    END IF;

    -- 2. Create Return Header
    INSERT INTO SalesReturns(customer_id, return_date, total_amount)
    VALUES (v_party_id, CURRENT_DATE, 0)
    RETURNING sales_return_id INTO v_return_id;

    -- 3. Process each serial
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT su.sold_unit_id, su.unit_id, su.sold_price, si.item_id,
               si.sales_invoice_id, pu.serial_number, pi.unit_price, s.customer_id
        INTO v_unit
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in SoldUnits', v_serial;
        END IF;

        -- check customer match
        IF v_unit.customer_id <> v_party_id THEN
            RAISE EXCEPTION 'Serial % was not sold to %', v_serial, p_party_name;
        END IF;

        -- mark sold unit as returned
        UPDATE SoldUnits SET status = 'Returned' WHERE sold_unit_id = v_unit.sold_unit_id;

        -- restore stock
        UPDATE PurchaseUnits SET in_stock = TRUE WHERE unit_id = v_unit.unit_id;

        -- log stock IN
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'IN', 'SalesReturn', v_return_id, 1);

        -- insert return line item
        INSERT INTO SalesReturnItems(sales_return_id, item_id, sold_price, cost_price, serial_number)
        VALUES (v_return_id, v_unit.item_id, v_unit.sold_price, v_unit.unit_price, v_serial);

        -- accumulate totals
        v_total := v_total + v_unit.sold_price;
        v_cost := v_cost + v_unit.unit_price;
    END LOOP;

    -- 4. Update return total
    UPDATE SalesReturns
    SET total_amount = v_total
    WHERE sales_return_id = v_return_id;

	-- Build Journal
	PERFORM rebuild_sales_return_journal(v_return_id);

    RETURN v_return_id;
END;
$$ LANGUAGE plpgsql;

-------------------------------🔹 Delete Sales Return-------------------------------------------
CREATE OR REPLACE FUNCTION delete_sale_return(p_return_id BIGINT)
RETURNS VOID AS $$
DECLARE
    rec RECORD;
	v_journal_id BIGINT;
BEGIN
    -- 1. Revert each returned unit
    FOR rec IN
        SELECT sri.serial_number, sri.item_id
        FROM SalesReturnItems sri
        WHERE sri.sales_return_id = p_return_id
    LOOP
        -- mark sold unit back as Sold
        UPDATE SoldUnits
        SET status = 'Sold'
        WHERE unit_id = (
            SELECT unit_id
            FROM PurchaseUnits
            WHERE serial_number = rec.serial_number
            LIMIT 1
        );

        -- remove from stock again
        UPDATE PurchaseUnits
        SET in_stock = FALSE
        WHERE serial_number = rec.serial_number;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'SalesReturn-Delete', p_return_id, 1);
    END LOOP;

	-- 2. Remove journal (if exists)
    SELECT journal_id INTO v_journal_id
    FROM SalesReturns
    WHERE sales_return_id = p_return_id;

	IF v_journal_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = v_journal_id;
    END IF;

    -- 2. Delete return items
    DELETE FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- 4. Delete return header (triggers remove journal)
    DELETE FROM SalesReturns WHERE sales_return_id = p_return_id;
END;
$$ LANGUAGE plpgsql;

-------------------------------🔹 Update Sale Return----------------------------------------------------
CREATE OR REPLACE FUNCTION update_sale_return(
    p_return_id BIGINT,
    p_serials JSONB
)
RETURNS VOID AS $$
DECLARE
    rec RECORD;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
    v_cost NUMERIC(14,2) := 0;
    v_customer_id BIGINT;
BEGIN
    -- 1. Reverse old items
    FOR rec IN
        SELECT serial_number, item_id
        FROM SalesReturnItems
        WHERE sales_return_id = p_return_id
    LOOP
        -- revert SoldUnits status
        UPDATE SoldUnits
        SET status = 'Sold'
        WHERE unit_id = (
            SELECT unit_id FROM PurchaseUnits WHERE serial_number = rec.serial_number LIMIT 1
        );

        -- remove stock
        UPDATE PurchaseUnits
        SET in_stock = FALSE
        WHERE serial_number = rec.serial_number;

        -- log OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'SalesReturn-Update-Reverse', p_return_id, 1);
    END LOOP;

    -- 2. Remove old items
    DELETE FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- 3. Get customer id
    SELECT customer_id INTO v_customer_id
    FROM SalesReturns
    WHERE sales_return_id = p_return_id;

    -- 4. Insert new items
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT su.sold_unit_id, su.unit_id, su.sold_price, si.item_id,
               si.sales_invoice_id, pu.serial_number, pi.unit_price, s.customer_id
        INTO v_unit
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in SoldUnits', v_serial;
        END IF;

        IF v_unit.customer_id <> v_customer_id THEN
            RAISE EXCEPTION 'Serial % was not sold to this customer', v_serial;
        END IF;

        UPDATE SoldUnits SET status = 'Returned' WHERE sold_unit_id = v_unit.sold_unit_id;
        UPDATE PurchaseUnits SET in_stock = TRUE WHERE unit_id = v_unit.unit_id;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'IN', 'SalesReturn-Update', p_return_id, 1);

        INSERT INTO SalesReturnItems(sales_return_id, item_id, sold_price, cost_price, serial_number)
        VALUES (p_return_id, v_unit.item_id, v_unit.sold_price, v_unit.unit_price, v_serial);

        v_total := v_total + v_unit.sold_price;
        v_cost := v_cost + v_unit.unit_price;
    END LOOP;

    -- 5. Update header total
    UPDATE SalesReturns
    SET total_amount = v_total
    WHERE sales_return_id = p_return_id;

	-- 6. Rebuild journal
    PERFORM rebuild_sales_return_journal(p_return_id);
END;
$$ LANGUAGE plpgsql;