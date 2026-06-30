---------------------------------------------------------------------------------------------------
------------------------------- SELECTION QUERIES------------------------------------------------
---------------------------------------------------------------------------------------------------

-------------------- Party Ledger with-in given time range---------------------------------------------

WITH party_ledger AS (
    SELECT 
        je.entry_date,
        je.journal_id,
        je.description,
        p.party_name,                
        a.account_name,               
        jl.debit,
        jl.credit,
        (jl.debit - jl.credit) AS amount
    FROM JournalLines jl
    JOIN JournalEntries je ON jl.journal_id = je.journal_id
    JOIN ChartOfAccounts a ON jl.account_id = a.account_id
    LEFT JOIN Parties p ON jl.party_id = p.party_id   
    WHERE p.party_name = 'Test Customer'
      AND je.entry_date BETWEEN '2025-01-01' AND '2025-09-02'
)
SELECT 
    entry_date,
    journal_id,
    description,
    party_name,
    account_name AS account_type,
    debit,
    credit,
    SUM(amount) OVER (ORDER BY entry_date, journal_id ROWS UNBOUNDED PRECEDING) AS running_balance
FROM party_ledger
ORDER BY entry_date, journal_id;

SELECT * FROM PurchaseInvoices

-- DELETE FROM JournalEntries WHERE journal_id = 32
-------------------------- STOCK-----------------------------------------------------

SELECT
    i.item_id AS "Item ID",
    i.item_name AS "Item Name",
    COUNT(pu.unit_id) AS "Quantity",
    STRING_AGG(pu.serial_number, ', ' ORDER BY pu.serial_number) AS "Serial Numbers"
FROM Items i
LEFT JOIN PurchaseItems pi ON i.item_id = pi.item_id
LEFT JOIN PurchaseUnits pu ON pi.purchase_item_id = pu.purchase_item_id
GROUP BY i.item_id, i.item_name
ORDER BY i.item_id;


--------------------------------STOCK REPORT-------------------------------------
WITH stock AS (
    SELECT 
        i.item_id,
        i.item_name,
        COUNT(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
        pu.serial_number,
        ROW_NUMBER() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
    FROM PurchaseUnits pu
    JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN Items i ON pit.item_id = i.item_id
    WHERE pu.in_stock = TRUE
)
SELECT
    CASE WHEN rn = 1 THEN item_id::text ELSE '' END AS item_id,
    CASE WHEN rn = 1 THEN item_name ELSE '' END AS item_name,
    CASE WHEN rn = 1 THEN quantity::text ELSE '' END AS quantity,
    serial_number
FROM stock
ORDER BY item_id::int, rn;


------------------------Stock Worth Report------------------------------------------


WITH stock AS (
    SELECT 
        i.item_id,
        i.item_name,
        COUNT(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
        pu.serial_number,
        pit.unit_price AS purchase_price,
        i.sale_price AS market_price,
        ROW_NUMBER() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
    FROM PurchaseUnits pu
    JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN Items i ON pit.item_id = i.item_id
    WHERE pu.in_stock = TRUE
),
running AS (
    SELECT
        item_id,
        item_name,
        quantity,
        serial_number,
        purchase_price,
        market_price,
        SUM(purchase_price) OVER (ORDER BY item_id, rn) AS running_total_purchase,
        SUM(market_price)   OVER (ORDER BY item_id, rn) AS running_total_market,
        rn
    FROM stock
)
SELECT
    CASE WHEN rn = 1 THEN item_id::text ELSE '' END AS item_id,
    CASE WHEN rn = 1 THEN item_name ELSE '' END AS item_name,
    CASE WHEN rn = 1 THEN quantity::text ELSE '' END AS quantity,
    serial_number,
    purchase_price,
    market_price,
    running_total_purchase,
    running_total_market
FROM running
ORDER BY item_id::int NULLS LAST, rn;

------------------------ General Trial Balance-------------------------------------
SELECT 
    coa.account_code,
    coa.account_name,
    coa.account_type,
    COALESCE(SUM(jl.debit), 0) AS total_debit,
    COALESCE(SUM(jl.credit), 0) AS total_credit,
    COALESCE(SUM(jl.debit), 0) - COALESCE(SUM(jl.credit), 0) AS balance
FROM ChartOfAccounts coa
LEFT JOIN JournalLines jl ON coa.account_id = jl.account_id
GROUP BY coa.account_id, coa.account_code, coa.account_name, coa.account_type
ORDER BY coa.account_code;

------------- Full Trial Balance ------------------------------------------------
WITH account_totals AS (
    SELECT 
        coa.account_id,
        coa.account_code,
        coa.account_name,
        coa.account_type,
        COALESCE(SUM(jl.debit), 0) AS total_debit,
        COALESCE(SUM(jl.credit), 0) AS total_credit
    FROM ChartOfAccounts coa
    LEFT JOIN JournalLines jl ON coa.account_id = jl.account_id
    GROUP BY coa.account_id, coa.account_code, coa.account_name, coa.account_type
),
party_totals AS (
    SELECT
        p.party_id,
        p.party_name,
        'Customer/Vendor' AS account_type,
        COALESCE(SUM(jl.debit),0) AS total_debit,
        COALESCE(SUM(jl.credit),0) AS total_credit
    FROM Parties p
    LEFT JOIN JournalLines jl ON p.party_id = jl.party_id
    GROUP BY p.party_id, p.party_name
)
SELECT 
    at.account_code AS code,
    at.account_name AS name,
    at.account_type AS type,
    at.total_debit,
    at.total_credit,
    (at.total_debit - at.total_credit) AS balance
FROM account_totals at

UNION ALL

SELECT
    NULL AS code,
    pt.party_name AS name,
    pt.account_type AS type,
    pt.total_debit,
    pt.total_credit,
    (pt.total_debit - pt.total_credit) AS balance
FROM party_totals pt

ORDER BY code NULLS FIRST, name;

SELECT * FROM Items
-- TRUNCATE TABLE ChartOfAccounts, Parties, JournalEntries, JournalLines,Items,StockMovements,PurchaseInvoices,PurchaseItems,PurchaseUnits,SalesInvoices,SalesItems,SoldUnits,Payments,Receipts,PurchaseReturns, PurchaseReturnItems,  SalesReturns,SalesReturnItems    
-- RESTART IDENTITY CASCADE;
