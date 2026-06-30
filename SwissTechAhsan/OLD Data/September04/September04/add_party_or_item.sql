----------------------------------------------------------------------------------
-- ========================================================================
-- Function to Insert Parties
-- ========================================================================

CREATE OR REPLACE FUNCTION add_party_from_json(party_data JSONB)
RETURNS VOID AS $$
BEGIN
    INSERT INTO Parties (
        party_name, party_type, contact_info, address,
        opening_balance, balance_type,
        ar_account_id, ap_account_id
    )
    VALUES (
        party_data->>'party_name',
        party_data->>'party_type',
        party_data->>'contact_info',
        party_data->>'address',
        COALESCE((party_data->>'opening_balance')::NUMERIC, 0),
        COALESCE(party_data->>'balance_type', 'Debit'),
        (SELECT account_id FROM ChartOfAccounts WHERE account_name = 'Accounts Receivable'),
        (SELECT account_id FROM ChartOfAccounts WHERE account_name = 'Accounts Payable')
    );
END;
$$ LANGUAGE plpgsql;


-------------------------- Adding Parties Using its Function------------------------------------------

SELECT add_party_from_json('{
  "party_name": "Party 1",
  "party_type": "Both",
  "contact_info": "123-456789",
  "address": "Customer & Vendor Address",
  "opening_balance": 1000,
  "balance_type": "Debit"
}');


SELECT add_party_from_json('{
  "party_name": "Party 2",
  "party_type": "Both",
  "contact_info": "123-456789",
  "address": "Customer & Vendor Address",
  "opening_balance": 0,
  "balance_type": "Debit"
}');


SELECT add_party_from_json('{
  "party_name": "Test Customer",
  "party_type": "Both",
  "contact_info": "123-456789",
  "address": "Customer & Vendor Address",
  "opening_balance": 0,
  "balance_type": "Debit"
}');

SELECT add_party_from_json('{
  "party_name": "Party 3",
  "party_type": "Both",
  "contact_info": "123-456789",
  "address": "Customer & Vendor Address",
  "opening_balance":1000,
  "balance_type": "Credit"
}');

-- ===========================================================================================================
-- ------------------------- Function to Add Items using Json ------------------------------------------------
-- ===========================================================================================================
CREATE OR REPLACE FUNCTION add_item_from_json(item_data JSONB)
RETURNS VOID AS $$
BEGIN
    INSERT INTO Items (item_name, storage, sale_price)
    VALUES (
        item_data->>'item_name',
        COALESCE(item_data->>'storage', 'Main Warehouse'),  -- default if not given
        (item_data->>'sale_price')::NUMERIC
    );
END;
$$ LANGUAGE plpgsql;


--------------------------------------------------------------------------------
--                  Insert Items using its Function in JSON Format
-------------------------------------------------------------------------------
SELECT add_item_from_json('{
  "item_name": "Item A",
  "storage": "Main Warehouse",
  "sale_price": 200
}');

SELECT add_item_from_json('{
  "item_name": "Item B",
  "storage": "Main Warehouse",
  "sale_price": 300
}');

SELECT add_item_from_json('{
  "item_name": "Item C",
  "storage": "Main Warehouse",
  "sale_price": 400
}');