CREATE SEQUENCE IF NOT EXISTS payments_ref_seq START 1;

CREATE OR REPLACE FUNCTION make_payment(p_data JSONB)
RETURNS JSONB AS $$
DECLARE
    v_party_id BIGINT;
    v_account_id BIGINT;
    v_amount NUMERIC(14,2);
    v_method TEXT;
    v_reference TEXT;
    v_id BIGINT;
BEGIN
    -- Extract
    v_amount    := (p_data->>'amount')::NUMERIC;
    v_method    := p_data->>'method';
    v_reference := p_data->>'reference_no';

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    -- Get Vendor
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_data->>'party_name'
    LIMIT 1;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Vendor % not found', p_data->>'party_name';
    END IF;

    -- Always Cash for now
    SELECT account_id INTO v_account_id
    FROM ChartOfAccounts
    WHERE account_name = 'Cash';

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found';
    END IF;

    -- Auto ref
    IF v_reference IS NULL OR v_reference = '' THEN
        v_reference := 'PMT-' || nextval('payments_ref_seq');
    END IF;

    -- Insert
    INSERT INTO Payments(party_id, account_id, amount, method, reference_no)
    VALUES (v_party_id, v_account_id, v_amount, v_method, v_reference)
    RETURNING payment_id INTO v_id;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment created successfully',
        'payment_id',v_id
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION update_payment(p_payment_id BIGINT, p_data JSONB)
RETURNS JSONB AS $$
DECLARE
    v_amount NUMERIC(14,2);
    v_method TEXT;
    v_reference TEXT;
    v_party_id BIGINT;
    v_updated RECORD;
BEGIN
    v_amount    := NULLIF(p_data->>'amount','')::NUMERIC;
    v_method    := NULLIF(p_data->>'method','');
    v_reference := NULLIF(p_data->>'reference_no','');

    IF p_data ? 'party_name' THEN
        SELECT party_id INTO v_party_id
        FROM Parties
        WHERE party_name = p_data->>'party_name'
        LIMIT 1;
        IF v_party_id IS NULL THEN
            RAISE EXCEPTION 'Vendor % not found', p_data->>'party_name';
        END IF;
    END IF;

    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount';
    END IF;

    UPDATE Payments
    SET amount       = COALESCE(v_amount, amount),
        method       = COALESCE(v_method, method),
        reference_no = COALESCE(v_reference, reference_no),
        party_id     = COALESCE(v_party_id, party_id)
    WHERE payment_id = p_payment_id
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment ID % not found', p_payment_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment updated successfully',
        'payment', to_jsonb(v_updated)
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION delete_payment(p_payment_id BIGINT)
RETURNS JSONB AS $$
BEGIN
    DELETE FROM Payments WHERE payment_id = p_payment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment ID % not found', p_payment_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment deleted successfully',
        'payment_id',p_payment_id
    );
END;
$$ LANGUAGE plpgsql;

-- DROP FUNCTION IF EXISTS delete_payment(bigint);

-- Insert Payment to a vendor
SELECT make_payment('{
    "party_name":"Party 2",
    "amount":600,
    "method":"Cash"
}'::jsonb);

-- Delete payment
SELECT delete_payment(1);

-- Change vendor
SELECT update_payment(2,'{
    "party_name":"Party 2", "amount":600
}'::jsonb);
