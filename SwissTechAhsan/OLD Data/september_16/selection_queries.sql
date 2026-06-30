-- ======================================================
-- Function: full_trial_balance
-- Produces full trial balance in tabular format
-- ======================================================

CREATE OR REPLACE FUNCTION full_trial_balance()
RETURNS TABLE(
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    total_debit NUMERIC(14,2),
    total_credit NUMERIC(14,2),
    balance NUMERIC(14,2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        coa.code AS account_code,
        coa.name AS account_name,
        coa.type AS account_type,
        COALESCE(SUM(jl.debit), 0) AS total_debit,
        COALESCE(SUM(jl.credit), 0) AS total_credit,
        COALESCE(SUM(jl.debit), 0) - COALESCE(SUM(jl.credit), 0) AS balance
    FROM ChartOfAccounts coa
    LEFT JOIN JournalLines jl ON coa.account_id = jl.account_id
    GROUP BY coa.code, coa.name, coa.type
    ORDER BY coa.code;
END;
$$ LANGUAGE plpgsql;

SELECT * FROM Parties

-- Generate full trial balance
SELECT * FROM full_trial_balance();


-- First delete dependent child records
TRUNCATE TABLE JournalLines RESTART IDENTITY CASCADE;
TRUNCATE TABLE JournalEntries RESTART IDENTITY CASCADE;
TRUNCATE TABLE Parties RESTART IDENTITY CASCADE;