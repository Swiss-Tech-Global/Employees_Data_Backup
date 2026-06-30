CREATE SEQUENCE IF NOT EXISTS receipts_ref_seq START 1;

CREATE OR REPLACE FUNCTION receive_payment(p_data JSONB)
RETURNS JSONB AS $$
DECLARE
    v_party_id BIGINT;
    v_account_id BIGINT;
    v_amount NUMERIC(14,2);
    v_method TEXT;
    v_reference TEXT;
    v_id BIGINT;
BEGIN
    -- Extract fields from JSON
    v_amount    := (p_data->>'amount')::NUMERIC;
    v_method    := p_data->>'method';
    v_reference := p_data->>'reference_no';
    
    -- Validation: amount > 0
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    -- Get party id
    SELECT party_id INTO v_party_id 
    FROM Parties 
    WHERE party_name = p_data->>'party_name'
    LIMIT 1;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Party % not found', p_data->>'party_name';
    END IF;

    -- For simplicity, always use Cash account (extend later for Bank etc.)
    SELECT account_id INTO v_account_id 
    FROM ChartOfAccounts 
    WHERE account_name = 'Cash';

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found in COA';
    END IF;

	-- Auto-generate reference if not provided
    IF v_reference IS NULL OR v_reference = '' THEN
        v_reference := 'RCPT-' || nextval('receipts_ref_seq');
    END IF;
	
    -- Insert Receipt
    INSERT INTO Receipts(party_id, account_id, amount, method, reference_no)
    VALUES (v_party_id, v_account_id, v_amount, v_method, v_reference)
    RETURNING receipt_id INTO v_id;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt created successfully',
        'receipt_id',v_id
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_receipt(p_receipt_id BIGINT, p_data JSONB)
RETURNS JSONB AS $$
DECLARE
    v_amount    NUMERIC(14,2);
    v_method    TEXT;
    v_reference TEXT;
    v_party_id  BIGINT;
    v_updated   RECORD;
BEGIN
    -- Extract fields
    v_amount    := NULLIF(p_data->>'amount','')::NUMERIC;
    v_method    := NULLIF(p_data->>'method','');
    v_reference := NULLIF(p_data->>'reference_no','');

    -- Optional party update
    IF p_data ? 'party_name' THEN
        SELECT party_id INTO v_party_id
        FROM Parties
        WHERE party_name = p_data->>'party_name'
        LIMIT 1;

        IF v_party_id IS NULL THEN
            RAISE EXCEPTION 'Party % not found', p_data->>'party_name';
        END IF;
    END IF;

    -- Validation
    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    -- Update in-place
    UPDATE Receipts
    SET amount       = COALESCE(v_amount, amount),
        method       = COALESCE(v_method, method),
        reference_no = COALESCE(v_reference, reference_no),
        party_id     = COALESCE(v_party_id, party_id)
    WHERE receipt_id = p_receipt_id
    RETURNING * INTO v_updated;

    -- Ensure row exists
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt ID % not found', p_receipt_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt updated successfully',
        'receipt', to_jsonb(v_updated)
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION delete_receipt(p_receipt_id BIGINT)
RETURNS JSONB AS $$
BEGIN
    DELETE FROM Receipts WHERE receipt_id = p_receipt_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt ID % not found', p_receipt_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt deleted successfully',
        'receipt_id',p_receipt_id
    );
END;
$$ LANGUAGE plpgsql;

-- Insert Receipt
-- Insert Receipt
SELECT receive_payment('{
    "party_name":"Test Customer",
    "amount":500,
    "method":"Cash"
}'::jsonb);

-- Update Receipt
SELECT update_receipt(1,'{
    "amount": 700
}'::jsonb);

-- Update Receipt (change party)
SELECT update_receipt(1,'{
    "party_name":"Test Customer",
    "amount": 700
}'::jsonb);

-- Delete Receipt
SELECT delete_receipt(1);


SELECT * FROM Receipts
