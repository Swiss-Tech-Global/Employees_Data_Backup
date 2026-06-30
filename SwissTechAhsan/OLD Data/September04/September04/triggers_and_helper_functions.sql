-- ======================================================
--                          Trigger Functions
-- ======================================================


-- ======================================================
-- Trigger: Party Opening Balance
-- ======================================================



CREATE OR REPLACE FUNCTION trg_party_opening_balance()
RETURNS TRIGGER AS $$
DECLARE
    j_id BIGINT;
    debit_acc BIGINT;
    credit_acc BIGINT;
    cap_acc BIGINT;
BEGIN
    IF NEW.opening_balance > 0 THEN
        -- Owner's Capital account
        SELECT account_id INTO cap_acc FROM ChartOfAccounts WHERE account_name = 'Owner''s Capital';
        IF cap_acc IS NULL THEN
            RAISE EXCEPTION 'Owner''s Capital account not found in COA';
        END IF;

        -- Create journal entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (CURRENT_DATE, 'Opening Balance for ' || NEW.party_name)
        RETURNING journal_id INTO j_id;

        -- Handle party types
        IF NEW.party_type = 'Customer' OR NEW.party_type = 'Both' THEN
            IF NEW.balance_type = 'Debit' THEN
                debit_acc := NEW.ar_account_id;
                credit_acc := cap_acc;

                -- Insert Debit line
                INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
                VALUES (j_id, debit_acc, NEW.party_id, NEW.opening_balance);

                -- Insert Credit line
                INSERT INTO JournalLines(journal_id, account_id, credit)
                VALUES (j_id, credit_acc, NEW.opening_balance);
            END IF;
        END IF;

        IF NEW.party_type = 'Vendor' OR NEW.party_type = 'Both' THEN
            IF NEW.balance_type = 'Credit' THEN
                debit_acc := cap_acc;
                credit_acc := NEW.ap_account_id;

                -- Insert Debit line
                INSERT INTO JournalLines(journal_id, account_id, debit)
                VALUES (j_id, debit_acc, NEW.opening_balance);

                -- Insert Credit line
                INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
                VALUES (j_id, credit_acc, NEW.party_id, NEW.opening_balance);
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate trigger
CREATE TRIGGER trg_party_insert
AFTER INSERT ON Parties
FOR EACH ROW
EXECUTE FUNCTION trg_party_opening_balance();



-- -----------------Trigger Payments-------------------------------
-- When you pay a vendor,
--Debit Vendor’s Payable account
--Credit Cash/Bank account

CREATE OR REPLACE FUNCTION trg_payment_journal()
RETURNS TRIGGER AS $$
DECLARE
    j_id BIGINT;
    party_acc BIGINT;
BEGIN
    -- Handle DELETE: remove related journal
    IF TG_OP = 'DELETE' THEN
        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
        RETURN OLD;
    END IF;

    -- Handle UPDATE: only regenerate if key fields changed
    IF TG_OP = 'UPDATE' THEN
        IF OLD.amount = NEW.amount
           AND OLD.account_id = NEW.account_id
           AND OLD.party_id = NEW.party_id THEN
            RETURN NEW;
        END IF;

        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
    END IF;

    -- Handle INSERT or UPDATE
    IF TG_OP IN ('INSERT','UPDATE') THEN
        -- Find AP account for vendor
        SELECT ap_account_id INTO party_acc
        FROM Parties
        WHERE party_id = NEW.party_id;

        IF party_acc IS NULL THEN
            RAISE EXCEPTION 'No AP account found for vendor %', NEW.party_id;
        END IF;

        INSERT INTO JournalEntries(entry_date, description)
        VALUES (NEW.payment_date, 'Payment to ' || NEW.party_id)
        RETURNING journal_id INTO j_id;

        -- Prevent recursion
        PERFORM pg_catalog.set_config('session_replication_role', 'replica', true);
        UPDATE Payments
        SET journal_id = j_id
        WHERE payment_id = NEW.payment_id;
        PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);

        -- Debit Vendor (reduce liability)
        INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
        VALUES (j_id, party_acc, NEW.party_id, NEW.amount);

        -- Credit Cash/Bank
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, NEW.account_id, NEW.amount);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;



-- INSERT
CREATE TRIGGER trg_payment_insert
AFTER INSERT ON Payments
FOR EACH ROW
EXECUTE FUNCTION trg_payment_journal();

-- UPDATE
CREATE TRIGGER trg_payment_update
AFTER UPDATE ON Payments
FOR EACH ROW
EXECUTE FUNCTION trg_payment_journal();

-- DELETE
CREATE TRIGGER trg_payment_delete
AFTER DELETE ON Payments
FOR EACH ROW
EXECUTE FUNCTION trg_payment_journal();



-- -----------------Trigger Receipts-------------------------------

-- When you receive from a customer,
-- Debit Cash/Bank
-- Credit Customer’s Receivable

CREATE OR REPLACE FUNCTION trg_receipt_journal()
RETURNS TRIGGER AS $$
DECLARE
    j_id BIGINT;
    party_acc BIGINT;
BEGIN
    -- Handle DELETE: remove related journal
    IF TG_OP = 'DELETE' THEN
        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
        RETURN OLD;
    END IF;

    -- Handle UPDATE: only regenerate journal if critical fields changed
    IF TG_OP = 'UPDATE' THEN
        IF OLD.amount = NEW.amount
           AND OLD.account_id = NEW.account_id
           AND OLD.party_id = NEW.party_id THEN
            RETURN NEW; -- nothing relevant changed
        END IF;

        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
    END IF;

    -- Handle INSERT or relevant UPDATE
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        -- Find AR account for party
        SELECT ar_account_id INTO party_acc
        FROM Parties
        WHERE party_id = NEW.party_id;

        INSERT INTO JournalEntries(entry_date, description)
        VALUES (NEW.receipt_date, 'Receipt from ' || NEW.party_id)
        RETURNING journal_id INTO j_id;

        -- Prevent recursion on internal update
        PERFORM pg_catalog.set_config('session_replication_role', 'replica', true);
        UPDATE Receipts
        SET journal_id = j_id
        WHERE receipt_id = NEW.receipt_id;
        PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);

        -- Debit Cash/Bank
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, NEW.account_id, NEW.amount);

        -- Credit Customer
        INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
        VALUES (j_id, party_acc, NEW.party_id, NEW.amount);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- INSERT
CREATE TRIGGER trg_receipt_insert
AFTER INSERT ON Receipts
FOR EACH ROW
EXECUTE FUNCTION trg_receipt_journal();

-- UPDATE
CREATE TRIGGER trg_receipt_update
AFTER UPDATE ON Receipts
FOR EACH ROW
EXECUTE FUNCTION trg_receipt_journal();

-- DELETE
CREATE TRIGGER trg_receipt_delete
AFTER DELETE ON Receipts
FOR EACH ROW
EXECUTE FUNCTION trg_receipt_journal();



-- =================================================================================
-------- Helper For Making Journal Entries When Purchase Invoice ------------------
-- =================================================================================
CREATE OR REPLACE FUNCTION rebuild_purchase_journal(p_invoice_id BIGINT)
RETURNS VOID AS $$
DECLARE
    j_id BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
BEGIN
    -- 1. Remove old journal if exists
    SELECT journal_id INTO j_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id;

    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 2. Get accounts
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ap_account_id INTO party_acc FROM Parties p
    JOIN PurchaseInvoices pi ON pi.vendor_id = p.party_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    -- 3. Get invoice total
    SELECT total_amount INTO v_total
    FROM PurchaseInvoices WHERE purchase_invoice_id = p_invoice_id;

    -- 4. Insert new journal entry
    INSERT INTO JournalEntries(entry_date, description)
    SELECT invoice_date, 'Purchase Invoice ' || purchase_invoice_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id
    RETURNING journal_id INTO j_id;

    -- 5. Update invoice with new journal_id
    UPDATE PurchaseInvoices
    SET journal_id = j_id
    WHERE purchase_invoice_id = p_invoice_id;

    -- 6. Debit Inventory
    INSERT INTO JournalLines(journal_id, account_id, debit)
    VALUES (j_id, inv_acc, v_total);

    -- 7. Credit Vendor (AP)
    INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
    VALUES (j_id, party_acc, (
        SELECT vendor_id FROM PurchaseInvoices WHERE purchase_invoice_id = p_invoice_id
    ), v_total);
END;
$$ LANGUAGE plpgsql;
---------------------------------------------------------------------------------------------

-- =================================================================================
--------------------- Helper For Making Journal Entries When Sales------------------
-- =================================================================================
CREATE OR REPLACE FUNCTION rebuild_sales_journal(p_invoice_id BIGINT)
RETURNS VOID AS $$
DECLARE
    j_id BIGINT;
    rev_acc BIGINT;
    party_acc BIGINT;
    cogs_acc BIGINT;
    inv_acc BIGINT;
    total_cost NUMERIC(14,2);
    total_revenue NUMERIC(14,2);
    v_customer_id BIGINT;
    v_invoice_date DATE;
BEGIN
    -- 1. Get existing journal_id (if any)
    SELECT journal_id INTO j_id
    FROM SalesInvoices
    WHERE sales_invoice_id = p_invoice_id;

    -- 2. If exists, clear old lines + entry
    IF j_id IS NOT NULL THEN
        DELETE FROM JournalLines WHERE journal_id = j_id;
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 3. Get invoice details
    SELECT s.customer_id, s.total_amount, s.invoice_date
    INTO v_customer_id, total_revenue, v_invoice_date
    FROM SalesInvoices s
    WHERE s.sales_invoice_id = p_invoice_id;

    -- 4. Get accounts
    SELECT account_id INTO rev_acc FROM ChartOfAccounts WHERE account_name='Sales Revenue';
    SELECT account_id INTO cogs_acc FROM ChartOfAccounts WHERE account_name='Cost of Goods Sold';
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ar_account_id INTO party_acc FROM Parties WHERE party_id = v_customer_id;

    -- 5. Insert new journal entry
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_invoice_date, 'Sale Invoice ' || p_invoice_id)
    RETURNING journal_id INTO j_id;

    -- 6. Update invoice with new journal_id
    UPDATE SalesInvoices
    SET journal_id = j_id
    WHERE sales_invoice_id = p_invoice_id;

    -- (1) Debit Customer (AR)
    INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
    VALUES (j_id, party_acc, v_customer_id, total_revenue);

    -- (2) Credit Revenue
    INSERT INTO JournalLines(journal_id, account_id, credit)
    VALUES (j_id, rev_acc, total_revenue);

    -- (3) Debit COGS / Credit Inventory
    SELECT COALESCE(SUM(pi.unit_price),0) INTO total_cost
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
    WHERE si.sales_invoice_id = p_invoice_id;

    IF total_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, cogs_acc, total_cost);

        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, inv_acc, total_cost);
    END IF;
END;
$$ LANGUAGE plpgsql;
---------------------------------------------------------------------------------------

-- ------------------Purchase Return Journal Rebuild-----------------------------
-- ==============================================================
-- 🔹 Purchase Return Journal Rebuild (with IF checks)
-- ==============================================================

CREATE OR REPLACE FUNCTION rebuild_purchase_return_journal(p_return_id BIGINT)
RETURNS VOID AS $$
DECLARE
    j_id BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
    v_vendor_id BIGINT;
    v_date DATE;
BEGIN
    -- 1. Remove old journal if exists
    SELECT journal_id INTO j_id 
    FROM PurchaseReturns 
    WHERE purchase_return_id = p_return_id;

    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 2. Get totals
    SELECT vendor_id, total_amount, return_date
    INTO v_vendor_id, v_total, v_date
    FROM PurchaseReturns 
    WHERE purchase_return_id = p_return_id;

    -- 3. Accounts
    SELECT account_id INTO inv_acc 
    FROM ChartOfAccounts 
    WHERE account_name='Inventory';

    SELECT ap_account_id INTO party_acc 
    FROM Parties 
    WHERE party_id = v_vendor_id;

    -- 4. New journal
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_date, 'Purchase Return ' || p_return_id)
    RETURNING journal_id INTO j_id;

    UPDATE PurchaseReturns 
    SET journal_id = j_id 
    WHERE purchase_return_id = p_return_id;

    -- 5. Journal lines (with conditions)
    -- (1) Debit Vendor (reduce AP balance)
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
        VALUES (j_id, party_acc, v_vendor_id, v_total);
    END IF;

    -- (2) Credit Inventory (stock reduced)
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, inv_acc, v_total);
    END IF;
END;
$$ LANGUAGE plpgsql;





------------------------------Sales Return Journal Rebuild-----------------------------------
CREATE OR REPLACE FUNCTION rebuild_sales_return_journal(p_return_id BIGINT)
RETURNS VOID AS $$
DECLARE
    j_id BIGINT;
    rev_acc BIGINT;
    cogs_acc BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
    v_cost NUMERIC(14,2);
    v_customer_id BIGINT;
    v_date DATE;
BEGIN
    -- remove old journal
    SELECT journal_id INTO j_id FROM SalesReturns WHERE sales_return_id = p_return_id;
    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- totals
    SELECT customer_id, total_amount, return_date
    INTO v_customer_id, v_total, v_date
    FROM SalesReturns WHERE sales_return_id = p_return_id;

    SELECT COALESCE(SUM(cost_price),0) INTO v_cost
    FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- accounts
    SELECT account_id INTO rev_acc FROM ChartOfAccounts WHERE account_name='Sales Revenue';
    SELECT account_id INTO cogs_acc FROM ChartOfAccounts WHERE account_name='Cost of Goods Sold';
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ar_account_id INTO party_acc FROM Parties WHERE party_id = v_customer_id;

    -- new journal
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_date, 'Sales Return ' || p_return_id)
    RETURNING journal_id INTO j_id;

    UPDATE SalesReturns SET journal_id = j_id WHERE sales_return_id = p_return_id;

    -- (1) Debit Sales Revenue
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, rev_acc, v_total);
    END IF;

    -- (2) Credit Customer AR
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
        VALUES (j_id, party_acc, v_customer_id, v_total);
    END IF;

    -- (3) Debit Inventory
    IF v_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, inv_acc, v_cost);
    END IF;

    -- (4) Credit COGS
    IF v_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, cogs_acc, v_cost);
    END IF;
END;
$$ LANGUAGE plpgsql;


---

-- -- create a sequence
-- CREATE SEQUENCE receipts_ref_seq START 1;

-- -- trigger function
-- CREATE OR REPLACE FUNCTION receipts_refno_trigger()
-- RETURNS TRIGGER AS $$
-- BEGIN
--     IF NEW.reference_no IS NULL THEN
--         NEW.reference_no := 'RCPT-' || nextval('receipts_ref_seq');
--     END IF;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- attach trigger to table
-- CREATE TRIGGER trg_receipts_refno
-- BEFORE INSERT ON Receipts
-- FOR EACH ROW
-- EXECUTE FUNCTION receipts_refno_trigger();

