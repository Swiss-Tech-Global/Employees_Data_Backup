-- =========================================================================================
------------------------ CREATE PURCHASE Function With JSON---------------------------------
-- =========================================================================================
CREATE OR REPLACE FUNCTION create_purchase(
    p_party_id BIGINT,        -- Vendor
    p_invoice_date DATE,
    p_items JSONB             -- array of items [{item_name, qty, unit_price, serials:[..]}]
)
RETURNS BIGINT AS $$
DECLARE
    v_invoice_id BIGINT;
    v_purchase_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_item_id BIGINT;
    v_item JSONB;
    v_serial TEXT;
BEGIN
    -- 1. Create Purchase Invoice (header)
    INSERT INTO PurchaseInvoices(vendor_id, invoice_date, total_amount)
    VALUES (p_party_id, p_invoice_date, 0)
    RETURNING purchase_invoice_id INTO v_invoice_id;

    -- 2. Loop through items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve item_id from item_name
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            -- Optionally auto-create item if not found
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (
            v_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert purchase units (serials) into stock
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            -- Insert stock movement (IN) for audit trail
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', v_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- 3. Update invoice total
    UPDATE PurchaseInvoices
    SET total_amount = v_total
    WHERE purchase_invoice_id = v_invoice_id;

    -- 4. Build Journal Entry (explicit, no trigger needed)
    PERFORM rebuild_purchase_journal(v_invoice_id);

    RETURN v_invoice_id;
END;
$$ LANGUAGE plpgsql;



-- =================================================================================
------------ Deleting Purchase Invoice (also removing entry in Stock Movements
-- =================================================================================

CREATE OR REPLACE FUNCTION delete_purchase(p_invoice_id BIGINT)
RETURNS VOID AS $$
DECLARE
    rec RECORD;
BEGIN
    -- 1. For each unit in the purchase, log a stock OUT movement
    FOR rec IN
        SELECT pu.serial_number, pi.item_id, pu.purchase_item_id
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pi.purchase_item_id = pu.purchase_item_id
        WHERE pi.purchase_invoice_id = p_invoice_id
    LOOP
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'PurchaseInvoice-Delete', p_invoice_id, 1);
    END LOOP;

    -- 2. Delete purchase units (serials)
    DELETE FROM PurchaseUnits
    WHERE purchase_item_id IN (
        SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id
    );

    -- 3. Delete purchase items
    DELETE FROM PurchaseItems
    WHERE purchase_invoice_id = p_invoice_id;

    -- 4. Delete purchase invoice
    DELETE FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id;
END;
$$ LANGUAGE plpgsql;


-- ==========================================================================================
--                   🔹 Update Purchase Invoice Function
-- ==========================================================================================

CREATE OR REPLACE FUNCTION update_purchase_items(
    p_invoice_id BIGINT,
    p_items JSONB
)
RETURNS VOID AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_purchase_item_id BIGINT;
    v_serial TEXT;
BEGIN
    -- Remove old stock + items
    DELETE FROM StockMovements WHERE reference_type = 'PurchaseInvoice' AND reference_id = p_invoice_id;
    DELETE FROM PurchaseUnits WHERE purchase_item_id IN (SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id);
    DELETE FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id;

    -- Insert new items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve or create item
        SELECT item_id INTO v_item_id FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (p_invoice_id, v_item_id, (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Units + Stock IN
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- Update invoice total
    UPDATE PurchaseInvoices SET total_amount = v_total WHERE purchase_invoice_id = p_invoice_id;

    -- 🔑 Rebuild journal manually
    PERFORM rebuild_purchase_journal(p_invoice_id);
END;
$$ LANGUAGE plpgsql;



SELECT create_purchase(
    (SELECT party_id FROM Parties WHERE party_name='Party 2'),
    CURRENT_DATE,
    '[
        {"item_name": "Item A", "qty": 2, "unit_price": 150, "serials": ["A101","A102"]},
        {"item_name": "Item B", "qty": 1, "unit_price": 250, "serials": ["B201"]}
     ]'::jsonb
) AS invoice_id;

-- SELECT delete_purchase(8); -- assuming invoice_id=8
SELECT * FROM PurchaseInvoices
SELECT update_purchase_items(
    1,
    '[
        {
            "item_name": "Item A",
            "qty": 2,
            "unit_price": 175,
            "serials": ["A100010", "A100020"]
        },
        {
            "item_name": "Item B",
            "qty": 1,
            "unit_price": 250,
            "serials": ["B100010"]
        }
    ]'::jsonb
);


SELECT create_purchase_return(
    'Party 2',
    '["A100010", "A100020","B100010"]'::jsonb
);

SELECT delete_purchase_return(2);

SELECT update_purchase_return(
    3,
    '["A100010", "B100010"]'::jsonb
);
