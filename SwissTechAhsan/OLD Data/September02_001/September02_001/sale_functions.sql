-- =================================================================================
------------ Create Sale Invoice (also Adding entry in Stock Movements)
-- =================================================================================
CREATE OR REPLACE FUNCTION create_sale(
    p_party_id BIGINT,
    p_invoice_date DATE,
    p_items JSONB  -- array of items [{item_name, qty, unit_price, serials:[..]}]
)
RETURNS BIGINT AS $$
DECLARE
    v_invoice_id BIGINT;
    v_sales_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_unit_id BIGINT;
    v_serial TEXT;
    v_item_id BIGINT;
    v_item JSONB;
BEGIN
    -- 1. Create Invoice (header)
    INSERT INTO SalesInvoices(customer_id, invoice_date, total_amount)
    VALUES (p_party_id, p_invoice_date, 0)
    RETURNING sales_invoice_id INTO v_invoice_id;

    -- 2. Loop through items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve item_id from item_name
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            RAISE EXCEPTION 'Item "%" not found in Items table', (v_item->>'item_name');
        END IF;

        -- Insert sales item
        INSERT INTO SalesItems(sales_invoice_id, item_id, quantity, unit_price)
        VALUES (
            v_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING sales_item_id INTO v_sales_item_id;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert sold units from serials
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            -- find unit_id for this serial
            SELECT unit_id INTO v_unit_id
            FROM PurchaseUnits
            WHERE serial_number = v_serial
              AND in_stock = TRUE
            LIMIT 1;

            IF v_unit_id IS NULL THEN
                RAISE EXCEPTION 'Serial % not found or already sold', v_serial;
            END IF;

            -- insert sold unit
            INSERT INTO SoldUnits(sales_item_id, unit_id, sold_price, status)
            VALUES (v_sales_item_id, v_unit_id, (v_item->>'unit_price')::NUMERIC, 'Sold');

            -- mark purchase unit as not in stock
            UPDATE PurchaseUnits
            SET in_stock = FALSE
            WHERE unit_id = v_unit_id;

            -- log stock movement (OUT)
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'OUT', 'SalesInvoice', v_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- 3. Update invoice total
    UPDATE SalesInvoices
    SET total_amount = v_total
    WHERE sales_invoice_id = v_invoice_id;

    -- 4. Build Journal Entry (explicit, no trigger needed)
    PERFORM rebuild_sales_journal(v_invoice_id);

    RETURN v_invoice_id;
END;
$$ LANGUAGE plpgsql;



-- =================================================================================
------------ Deleting Sale Invoice (also removing entry in Stock Movements)
-- =================================================================================

CREATE OR REPLACE FUNCTION delete_sale(p_invoice_id BIGINT)
RETURNS VOID AS $$
DECLARE
    rec RECORD;
BEGIN
    -- 1. For each sold unit, restore stock + log movement
    FOR rec IN
        SELECT su.unit_id, pu.serial_number, si.item_id
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        WHERE si.sales_invoice_id = p_invoice_id
    LOOP
        -- restore stock
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE unit_id = rec.unit_id;

        -- log stock movement (IN)
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'SalesInvoice-Delete', p_invoice_id, 1);
    END LOOP;

    -- 2. Delete the invoice (cascade removes SalesItems + SoldUnits)
    DELETE FROM SalesInvoices
    WHERE sales_invoice_id = p_invoice_id;
END;
$$ LANGUAGE plpgsql;

-- ======================================================================================================================
--                                               🔹 Update Sales Invoice Function
-- ======================================================================================================================

CREATE OR REPLACE FUNCTION update_sale_items(
    p_invoice_id BIGINT,
    p_items JSONB
)
RETURNS VOID AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_sales_item_id BIGINT;
    v_serial TEXT;
    v_unit_id BIGINT;
BEGIN
    -- 1. Remove old stock + items
    DELETE FROM StockMovements
    WHERE reference_type = 'SalesInvoice'
      AND reference_id = p_invoice_id;

    DELETE FROM SoldUnits
    WHERE sales_item_id IN (
        SELECT sales_item_id FROM SalesItems WHERE sales_invoice_id = p_invoice_id
    );

    DELETE FROM SalesItems
    WHERE sales_invoice_id = p_invoice_id;

    -- 2. Insert new items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve item_id
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            RAISE EXCEPTION 'Item "%" not found in Items table for update_sale', (v_item->>'item_name');
        END IF;

        -- Insert sale item
        INSERT INTO SalesItems(sales_invoice_id, item_id, quantity, unit_price)
        VALUES (
            p_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING sales_item_id INTO v_sales_item_id;

        -- Update invoice total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert sold units + stock movements
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            -- get matching purchase unit
            SELECT unit_id INTO v_unit_id
            FROM PurchaseUnits
            WHERE serial_number = v_serial
              AND in_stock = FALSE  -- because it's already sold once
            LIMIT 1;

            IF v_unit_id IS NULL THEN
                RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
            END IF;

            -- insert into SoldUnits
            INSERT INTO SoldUnits(sales_item_id, unit_id, sold_price, status)
            VALUES (v_sales_item_id, v_unit_id, (v_item->>'unit_price')::NUMERIC, 'Sold');

            -- log stock OUT
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'OUT', 'SalesInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- 3. Update invoice total
    UPDATE SalesInvoices
    SET total_amount = v_total
    WHERE sales_invoice_id = p_invoice_id;

    -- 4. Rebuild journal (with COGS vs Inventory)
    PERFORM rebuild_sales_journal(p_invoice_id);
END;
$$ LANGUAGE plpgsql;


-- Sale invoice
SELECT create_sale(
    (SELECT party_id FROM Parties WHERE party_name='Test Customer'),
    CURRENT_DATE,
    '[
        {"item_name": "Item A", "qty": 2, "unit_price": 200, "serials": ["A100010", "A100020"]},
        {"item_name": "Item B", "qty": 1, "unit_price": 300, "serials": ["B100010"]}
     ]'::jsonb
);

SELECT * FROM SalesInvoices

-- Delete sale invoice #5
-- SELECT delete_sale(6);

-- Audit trail
SELECT * FROM StockMovements


SELECT update_sale_items(
    1,
    '[
        {
            "item_name": "Item A",
            "qty": 2,
            "unit_price": 225,
            "serials": ["A100010", "A100020"]
        },
        {
            "item_name": "Item B",
            "qty": 1,
            "unit_price": 300,
            "serials": ["B100010"]
        }
    ]'::jsonb
);


-- Sales Return
SELECT create_sale_return('Test Customer', '["A100010", "A100020","B100010"]'::jsonb);

SELECT * FROM SalesReturns

SELECT delete_sale_return(1);

SELECT update_sale_return(2, '["A100010", "A100020"]'::jsonb);
