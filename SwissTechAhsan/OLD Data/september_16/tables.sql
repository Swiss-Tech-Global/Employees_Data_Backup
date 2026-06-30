-- ======================================================
-- tables.sql
-- Core schema for Accounting + Inventory system
-- Supports both serial-tracked and non-serial items
-- ======================================================

-- ======================================================
-- Parties
-- ======================================================
CREATE TABLE IF NOT EXISTS Parties (
    party_id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    party_type TEXT, -- customer, vendor, etc.
    opening_balance NUMERIC(14,2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- ======================================================
-- Chart of Accounts
-- ======================================================
CREATE TABLE IF NOT EXISTS ChartOfAccounts (
    account_id BIGSERIAL PRIMARY KEY,
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL, -- Asset, Liability, Equity, Income, Expense
    parent_id BIGINT REFERENCES ChartOfAccounts(account_id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- ======================================================
-- Items
-- ======================================================
CREATE TABLE IF NOT EXISTS Items (
    item_id BIGSERIAL PRIMARY KEY,
    sku TEXT UNIQUE,
    name TEXT NOT NULL,
    description TEXT,
    is_serial BOOLEAN NOT NULL DEFAULT TRUE, -- TRUE = serial-tracked, FALSE = non-serial
    base_unit TEXT,
    cost_price NUMERIC(14,2) DEFAULT 0,
    sell_price NUMERIC(14,2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- ======================================================
-- Serial Numbers (for serial-tracked items only)
-- ======================================================
CREATE TABLE IF NOT EXISTS SerialNumbers (
    serial_id BIGSERIAL PRIMARY KEY,
    item_id BIGINT NOT NULL REFERENCES Items(item_id) ON DELETE CASCADE,
    serial TEXT NOT NULL,
    status TEXT DEFAULT 'IN_STOCK', -- IN_STOCK, SOLD, RETURNED, DAMAGED
    location TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    UNIQUE(item_id, serial)
);

-- ======================================================
-- Stock Levels (for non-serial-tracked items)
-- ======================================================
CREATE TABLE IF NOT EXISTS StockLevels (
    stock_level_id BIGSERIAL PRIMARY KEY,
    item_id BIGINT NOT NULL REFERENCES Items(item_id) ON DELETE CASCADE,
    location TEXT DEFAULT 'MAIN',
    quantity NUMERIC(14,4) NOT NULL DEFAULT 0, -- total available quantity
    reserved NUMERIC(14,4) NOT NULL DEFAULT 0, -- reserved for orders
    last_updated TIMESTAMP WITH TIME ZONE DEFAULT now(),
    UNIQUE(item_id, location)
);

-- ======================================================
-- Stock Movements (common log for serial and non-serial)
-- ======================================================
CREATE TABLE IF NOT EXISTS StockMovements (
    movement_id BIGSERIAL PRIMARY KEY,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    movement_type TEXT NOT NULL, -- IN or OUT
    reference_type TEXT, -- PurchaseInvoice, SalesInvoice, etc.
    reference_id BIGINT,
    location TEXT DEFAULT 'MAIN',
    quantity NUMERIC(14,4) NOT NULL DEFAULT 0,
    serials JSONB, -- used only if item.is_serial = TRUE
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);


-- ======================================================
-- Journal Entries (Header + Lines)
-- ======================================================
CREATE TABLE IF NOT EXISTS JournalEntries (
    journal_id BIGSERIAL PRIMARY KEY,
    reference_type TEXT,
    reference_id BIGINT,
    narration TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS JournalLines (
    journal_line_id BIGSERIAL PRIMARY KEY,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE CASCADE,
    account_id BIGINT REFERENCES ChartOfAccounts(account_id),
    debit NUMERIC(14,2) DEFAULT 0,
    credit NUMERIC(14,2) DEFAULT 0,
    CHECK (
        (debit = 0 AND credit > 0) OR
        (credit = 0 AND debit > 0)
    )
);

-- ======================================================
-- Purchase Invoices (Header + Items)
-- ======================================================
CREATE TABLE IF NOT EXISTS PurchaseInvoices (
    purchase_invoice_id BIGSERIAL PRIMARY KEY,
    vendor_id BIGINT REFERENCES Parties(party_id),
    invoice_no TEXT,
    invoice_date DATE DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS PurchaseInvoiceItems (
    purchase_item_id BIGSERIAL PRIMARY KEY,
    purchase_invoice_id BIGINT REFERENCES PurchaseInvoices(purchase_invoice_id) ON DELETE CASCADE,
    item_id BIGINT REFERENCES Items(item_id),
    description TEXT,
    quantity NUMERIC(14,4) NOT NULL DEFAULT 0,
    unit_price NUMERIC(14,4) NOT NULL DEFAULT 0,
    tax NUMERIC(14,4) DEFAULT 0,
    serials JSONB -- only used if item.is_serial = TRUE
);

-- ======================================================
-- Purchase Units (for serial-tracked items only)
-- ======================================================
CREATE TABLE IF NOT EXISTS PurchaseUnits (
    unit_id BIGSERIAL PRIMARY KEY,
    purchase_item_id BIGINT NOT NULL REFERENCES PurchaseInvoiceItems(purchase_item_id) ON DELETE CASCADE,
    serial_number VARCHAR(100) UNIQUE, -- required if item.is_serial = TRUE
    in_stock BOOLEAN DEFAULT TRUE
);

-- ======================================================
-- Purchase Returns (Header + Items)
-- ======================================================
CREATE TABLE IF NOT EXISTS PurchaseReturns (
    purchase_return_id BIGSERIAL PRIMARY KEY,
    vendor_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    return_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS PurchaseReturnItems (
    return_item_id BIGSERIAL PRIMARY KEY,
    purchase_return_id BIGINT NOT NULL REFERENCES PurchaseReturns(purchase_return_id) ON DELETE CASCADE,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    unit_price NUMERIC(12,2) NOT NULL,
    quantity NUMERIC(14,4) NOT NULL DEFAULT 0, -- used for non-serial
    serials JSONB -- used for serial-tracked
);

-- ======================================================
-- Sales Invoices (Header + Items)
-- ======================================================
CREATE TABLE IF NOT EXISTS SalesInvoices (
    sales_invoice_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT REFERENCES Parties(party_id),
    invoice_no TEXT,
    invoice_date DATE DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS SalesInvoiceItems (
    sales_item_id BIGSERIAL PRIMARY KEY,
    sales_invoice_id BIGINT REFERENCES SalesInvoices(sales_invoice_id) ON DELETE CASCADE,
    item_id BIGINT REFERENCES Items(item_id),
    description TEXT,
    quantity NUMERIC(14,4) NOT NULL DEFAULT 0,
    unit_price NUMERIC(14,4) NOT NULL DEFAULT 0,
    tax NUMERIC(14,4) DEFAULT 0,
    serials JSONB -- only used if item.is_serial = TRUE
);

-- ======================================================
-- Sold Units (for serial-tracked items only)
-- ======================================================
CREATE TABLE IF NOT EXISTS SoldUnits (
    sold_unit_id BIGSERIAL PRIMARY KEY,
    sales_item_id BIGINT NOT NULL REFERENCES SalesInvoiceItems(sales_item_id) ON DELETE CASCADE,
    unit_id BIGINT REFERENCES PurchaseUnits(unit_id) ON DELETE CASCADE,
    sold_price NUMERIC(12,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'Sold' CHECK (status IN ('Sold','Returned','Damaged'))
);

-- ======================================================
-- Sales Returns (Header + Items)
-- ======================================================
CREATE TABLE IF NOT EXISTS SalesReturns (
    sales_return_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    return_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS SalesReturnItems (
    return_item_id BIGSERIAL PRIMARY KEY,
    sales_return_id BIGINT NOT NULL REFERENCES SalesReturns(sales_return_id) ON DELETE CASCADE,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    sold_price NUMERIC(12,2) NOT NULL,
    cost_price NUMERIC(12,2) NOT NULL,
    quantity NUMERIC(14,4) NOT NULL DEFAULT 0, -- used for non-serial
    serials JSONB -- used for serial-tracked
);



-- ======================================================
-- Payments (Outgoing to vendors)
-- ======================================================
CREATE TABLE IF NOT EXISTS Payments (
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
CREATE TABLE IF NOT EXISTS Receipts (
    receipt_id BIGSERIAL PRIMARY KEY,
    party_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    account_id BIGINT NOT NULL REFERENCES ChartOfAccounts(account_id),
    amount NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    receipt_date DATE NOT NULL DEFAULT CURRENT_DATE,
    method VARCHAR(20) CHECK (method IN ('Cash','Bank','Cheque','Online')),
    reference_no VARCHAR(100),
    journal_id BIGSERIAL REFERENCES JournalEntries(journal_id) ON DELETE SET NULL,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);

-- ======================================================
-- End of tables.sql
-- ======================================================


-- ================================
-- Base Chart of Accounts (COA)
-- ================================

-- Assets
INSERT INTO ChartOfAccounts (code, name, type)
VALUES 
('1000', 'Cash', 'Asset'),
('1200', 'Accounts Receivable', 'Asset'),
('1400', 'Inventory', 'Asset');

-- Liabilities
INSERT INTO ChartOfAccounts (code, name, type)
VALUES 
('2000', 'Accounts Payable', 'Liability');

-- Equity
INSERT INTO ChartOfAccounts (code, name, type)
VALUES 
('3000', 'Owner''s Capital', 'Equity');


-- Revenue
INSERT INTO ChartOfAccounts (code, name, type)
VALUES 
('4000', 'Sales Revenue', 'Revenue');

-- Expenses
INSERT INTO ChartOfAccounts (code, name, type)
VALUES 
('5000', 'Cost of Goods Sold', 'Expense');
