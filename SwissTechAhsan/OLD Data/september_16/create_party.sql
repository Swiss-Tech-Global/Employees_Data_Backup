-- ======================================================
-- Parties Functions (Create, Update, Delete) with Debit/Credit Handling
-- ======================================================

-- Create Party with Opening Balance Handling
CREATE OR REPLACE FUNCTION app_create_party_json(p_json JSONB)
RETURNS BIGINT AS $$
DECLARE
    v_party_id BIGINT;
    v_journal_id BIGINT;
    v_name TEXT := p_json->>'name';
    v_type TEXT := lower(p_json->>'party_type'); -- customer/vendor
    v_opening NUMERIC := COALESCE((p_json->>'opening_balance')::NUMERIC, 0);
    v_opening_type TEXT := lower(COALESCE(p_json->>'opening_balance_type','debit')); -- debit/credit
BEGIN
    -- Insert Party
    INSERT INTO Parties(name, party_type, opening_balance, created_at)
    VALUES (v_name, v_type, v_opening, now())
    RETURNING party_id INTO v_party_id;

    -- If opening balance exists, create journal
    IF v_opening <> 0 THEN
        INSERT INTO JournalEntries(reference_type, reference_id, narration, created_at)
        VALUES ('PartyOpening', v_party_id, 'Opening balance for ' || v_name, now())
        RETURNING journal_id INTO v_journal_id;

        IF v_type = 'customer' THEN
            -- Customer → usually A/R
            IF v_opening_type = 'debit' THEN
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '1200'), v_opening, 0);
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '3000'), 0, v_opening);
            ELSE -- credit
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '3000'), v_opening, 0);
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '1200'), 0, v_opening);
            END IF;

        ELSIF v_type = 'vendor' THEN
            -- Vendor → usually A/P
            IF v_opening_type = 'debit' THEN
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '2000'), v_opening, 0);
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '3000'), 0, v_opening);
            ELSE -- credit
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '3000'), v_opening, 0);
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '2000'), 0, v_opening);
            END IF;
        END IF;
    END IF;

    RETURN v_party_id;
END;
$$ LANGUAGE plpgsql;



-- Update Party and Adjust Opening Balance
CREATE OR REPLACE FUNCTION app_update_party_json(p_json JSONB)
RETURNS VOID AS $$
DECLARE
    v_party_id BIGINT := (p_json->>'party_id')::BIGINT;
    v_name TEXT := p_json->>'name';
    v_type TEXT := lower(p_json->>'party_type');
    v_opening NUMERIC := COALESCE((p_json->>'opening_balance')::NUMERIC, 0);
    v_opening_type TEXT := lower(COALESCE(p_json->>'opening_balance_type','debit'));
    v_old_opening NUMERIC;
    v_journal_id BIGINT;
BEGIN
    SELECT opening_balance INTO v_old_opening FROM Parties WHERE party_id = v_party_id;

    -- Update Party Info
    UPDATE Parties
    SET name = v_name,
        party_type = v_type,
        opening_balance = v_opening
    WHERE party_id = v_party_id;

    -- Reset old journal
    DELETE FROM JournalEntries WHERE reference_type = 'PartyOpening' AND reference_id = v_party_id;

    -- If new opening balance exists, create fresh journal
    IF v_opening <> 0 THEN
        INSERT INTO JournalEntries(reference_type, reference_id, narration, created_at)
        VALUES ('PartyOpening', v_party_id, 'Updated opening balance for ' || v_name, now())
        RETURNING journal_id INTO v_journal_id;

        IF v_type = 'customer' THEN
            IF v_opening_type = 'debit' THEN
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '1200'), v_opening, 0);
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '3000'), 0, v_opening);
            ELSE
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '3000'), v_opening, 0);
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '1200'), 0, v_opening);
            END IF;

        ELSIF v_type = 'vendor' THEN
            IF v_opening_type = 'debit' THEN
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '2000'), v_opening, 0);
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '3000'), 0, v_opening);
            ELSE
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '3000'), v_opening, 0);
                INSERT INTO JournalLines(journal_id, account_id, debit, credit)
                VALUES (v_journal_id, (SELECT account_id FROM ChartOfAccounts WHERE code = '2000'), 0, v_opening);
            END IF;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;



-- Delete Party and related Opening Balance Journal
CREATE OR REPLACE FUNCTION app_delete_party_json(p_json JSONB)
RETURNS VOID AS $$
DECLARE
    v_party_id BIGINT := (p_json->>'party_id')::BIGINT;
BEGIN
    -- Delete related opening balance journal
    DELETE FROM JournalEntries WHERE reference_type = 'PartyOpening' AND reference_id = v_party_id;

    -- Delete Party
    DELETE FROM Parties WHERE party_id = v_party_id;
END;
$$ LANGUAGE plpgsql;



-- Create Customer with Debit Opening Balance
SELECT app_create_party_json('{
  "name": "ABC Traders",
  "party_type": "customer",
  "opening_balance": 5000,
  "opening_balance_type": "debit"
}'::jsonb);

-- Create Vendor with Credit Opening Balance
SELECT app_create_party_json('{
  "name": "XYZ Supplies",
  "party_type": "vendor",
  "opening_balance": 7000,
  "opening_balance_type": "credit"
}'::jsonb);

-- Update Party
SELECT app_update_party_json('{
  "party_id": 1,
  "name": "ABC Traders Pvt Ltd",
  "party_type": "customer",
  "opening_balance": 6000,
  "opening_balance_type": "credit"
}'::jsonb);


-- Delete Party
SELECT app_delete_party_json('{"party_id": 1}'::jsonb);