-- ======================================================
-- Chart of Accounts (COA)
-- ======================================================
CREATE TABLE ChartOfAccounts (
    account_id BIGSERIAL PRIMARY KEY,
    account_code VARCHAR(20) UNIQUE NOT NULL,
    account_name VARCHAR(150) NOT NULL,
    account_type VARCHAR(20) NOT NULL CHECK (account_type IN ('Asset','Liability','Equity','Revenue','Expense')),
    parent_account BIGINT REFERENCES ChartOfAccounts(account_id) ON DELETE SET NULL,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ======================================================
-- Parties (Customers & Vendors)
-- ======================================================
CREATE TABLE Parties (
    party_id BIGSERIAL PRIMARY KEY,
    party_name VARCHAR(150) NOT NULL,
    party_type VARCHAR(20) NOT NULL CHECK (party_type IN ('Customer','Vendor','Both')),
    contact_info VARCHAR(50),
    address TEXT,
    ar_account_id BIGINT REFERENCES ChartOfAccounts(account_id) ON DELETE SET NULL, -- linked ledger account
	ap_account_id BIGINT REFERENCES ChartOfAccounts(account_id) ON DELETE SET NULL, -- for Vendor / AP
	opening_balance NUMERIC(14,2) DEFAULT 0,
	balance_type VARCHAR(10) CHECK (balance_type IN ('Debit','Credit')) DEFAULT 'Debit',
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);


-- ALTER TABLE Parties
--     RENAME COLUMN account_id TO ar_account_id; -- for Customer / AR

-- ALTER TABLE Parties
--     ADD COLUMN ap_account_id BIGINT REFERENCES ChartOfAccounts(account_id) ON DELETE SET NULL; -- for Vendor / AP

-- ======================================================
-- Journal Entries (Header)
-- ======================================================
CREATE TABLE JournalEntries (
    journal_id BIGSERIAL PRIMARY KEY,
    entry_date DATE NOT NULL DEFAULT CURRENT_DATE,
    description TEXT,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ======================================================
-- Journal Lines (Double-entry details)
-- ======================================================
CREATE TABLE JournalLines (
    line_id BIGSERIAL PRIMARY KEY,
    journal_id BIGINT NOT NULL REFERENCES JournalEntries(journal_id) ON DELETE CASCADE,
    account_id BIGINT NOT NULL REFERENCES ChartOfAccounts(account_id),
    party_id BIGINT REFERENCES Parties(party_id) ON DELETE SET NULL,
    debit NUMERIC(14,2) DEFAULT 0,
    credit NUMERIC(14,2) DEFAULT 0,
    CHECK (debit >= 0 AND credit >= 0),
    CHECK (NOT (debit = 0 AND credit = 0))
);



-- ======================================================
-- Items (Products stored in inventory)
-- ======================================================
CREATE TABLE Items (
    item_id BIGSERIAL PRIMARY KEY,
    item_name VARCHAR(150) NOT NULL,
    storage VARCHAR(100),             -- Storage / warehouse
    sale_price NUMERIC(12,2)          -- Default sale price
);

-- ======================================================
--             StockMovements (IN and OUT)
-- ======================================================
CREATE TABLE StockMovements (
    movement_id BIGSERIAL PRIMARY KEY,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    serial_number TEXT,
    movement_type VARCHAR(20) NOT NULL CHECK (movement_type IN ('IN','OUT')),
    reference_type VARCHAR(50),   -- e.g., 'PurchaseInvoice'
    reference_id BIGINT,          -- purchase_invoice_id
    movement_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    quantity INT NOT NULL
);


-- ======================================================
-- Purchase Invoices (Header)
-- ======================================================
CREATE TABLE PurchaseInvoices (
    purchase_invoice_id BIGSERIAL PRIMARY KEY,
    vendor_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) NOT NULL,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL
);

-- ======================================================
-- Purchase Items (Line items)
-- ======================================================
CREATE TABLE PurchaseItems (
    purchase_item_id BIGSERIAL PRIMARY KEY,
    purchase_invoice_id BIGINT NOT NULL REFERENCES PurchaseInvoices(purchase_invoice_id) ON DELETE CASCADE,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL
);

-- ======================================================
-- Purchase Units (Serial numbers for purchased items)
-- ======================================================
CREATE TABLE PurchaseUnits (
    unit_id BIGSERIAL PRIMARY KEY,
    purchase_item_id BIGINT NOT NULL REFERENCES PurchaseItems(purchase_item_id) ON DELETE CASCADE,
    serial_number VARCHAR(100) UNIQUE NOT NULL,
    in_stock BOOLEAN DEFAULT TRUE
);

-- ======================================================
-- Sales Invoices (Header)
-- ======================================================
CREATE TABLE SalesInvoices (
    sales_invoice_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) NOT NULL,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL
);

-- ======================================================
-- Sales Items (Line items)
-- ======================================================
CREATE TABLE SalesItems (
    sales_item_id BIGSERIAL PRIMARY KEY,
    sales_invoice_id BIGINT NOT NULL REFERENCES SalesInvoices(sales_invoice_id) ON DELETE CASCADE,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL
);

-- ======================================================
-- Sold Units (Serial numbers for sold items)
-- ======================================================
CREATE TABLE SoldUnits (
    sold_unit_id BIGSERIAL PRIMARY KEY,
    sales_item_id BIGINT NOT NULL REFERENCES SalesItems(sales_item_id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES PurchaseUnits(unit_id) ON DELETE CASCADE,
    sold_price NUMERIC(12,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'Sold' CHECK (status IN ('Sold','Returned','Damaged')),
    CONSTRAINT uq_soldunits_unit UNIQUE (unit_id)
);


-- ======================================================
-- Payments (Outgoing to vendors)
-- ======================================================
CREATE TABLE Payments (
    payment_id BIGSERIAL PRIMARY KEY,
    party_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    account_id BIGINT NOT NULL REFERENCES ChartOfAccounts(account_id),
    amount NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    method VARCHAR(20) CHECK (method IN ('Cash','Bank','Cheque','Online')),
    reference_no VARCHAR(100),
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);

-- ======================================================
-- Receipts (Incoming from customers)
-- ======================================================
CREATE TABLE Receipts (
    receipt_id BIGSERIAL PRIMARY KEY,
    party_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    account_id BIGINT NOT NULL REFERENCES ChartOfAccounts(account_id),
    amount NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    receipt_date DATE NOT NULL DEFAULT CURRENT_DATE,
    method VARCHAR(20) CHECK (method IN ('Cash','Bank','Cheque','Online')),
    reference_no VARCHAR(100),
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);

-- ======================================================
-- General Ledger (VIEW over JournalLines)
-- ======================================================
CREATE VIEW GeneralLedger AS
SELECT 
    jl.line_id AS gl_entry_id,
    je.journal_id,
    je.entry_date,
    jl.account_id,
    jl.party_id,
    jl.debit,
    jl.credit,
    je.description
FROM JournalLines jl
JOIN JournalEntries je ON jl.journal_id = je.journal_id;



-- ======================================================
-- Purchase Returns (Header)
-- ======================================================
CREATE TABLE PurchaseReturns (
    purchase_return_id BIGSERIAL PRIMARY KEY,
    vendor_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    return_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL
);

-- Line items (with serials)
CREATE TABLE PurchaseReturnItems (
    return_item_id BIGSERIAL PRIMARY KEY,
    purchase_return_id BIGINT NOT NULL REFERENCES PurchaseReturns(purchase_return_id) ON DELETE CASCADE,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    unit_price NUMERIC(12,2) NOT NULL,
    serial_number VARCHAR(100) NOT NULL
);
-------------------------------------------------------------------------------------------------------

-- ======================================================
-- Sales Returns (Header)
-- ======================================================
CREATE TABLE SalesReturns (
    sales_return_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    return_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL
);

-- Line items (with serials)
CREATE TABLE SalesReturnItems (
    return_item_id BIGSERIAL PRIMARY KEY,
    sales_return_id BIGINT NOT NULL REFERENCES SalesReturns(sales_return_id) ON DELETE CASCADE,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    sold_price NUMERIC(12,2) NOT NULL,
    cost_price NUMERIC(12,2) NOT NULL,
    serial_number VARCHAR(100) NOT NULL
);
----------------------------------------------------------------------------------------------


-- ================================
-- Base Chart of Accounts (COA)
-- ================================

-- Assets
INSERT INTO ChartOfAccounts (account_code, account_name, account_type)
VALUES 
('1000', 'Cash', 'Asset'),
('1200', 'Accounts Receivable', 'Asset'),
('1400', 'Inventory', 'Asset');

-- Liabilities
INSERT INTO ChartOfAccounts (account_code, account_name, account_type)
VALUES 
('2000', 'Accounts Payable', 'Liability');

-- Equity
INSERT INTO ChartOfAccounts (account_code, account_name, account_type)
VALUES 
('3000', 'Owner''s Capital', 'Equity');


-- Revenue
INSERT INTO ChartOfAccounts (account_code, account_name, account_type)
VALUES 
('4000', 'Sales Revenue', 'Revenue');

-- Expenses
INSERT INTO ChartOfAccounts (account_code, account_name, account_type)
VALUES 
('5000', 'Cost of Goods Sold', 'Expense');
