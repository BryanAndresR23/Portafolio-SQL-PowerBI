/* =============================================================================
   International Payments Analytics
   01 - Tables, keys, constraints and indexes
   -----------------------------------------------------------------------------
   Re-runnable: drops the objects in dependency order before creating them.
   ============================================================================= */

USE InternationalPaymentsAnalytics;
GO

DROP TABLE IF EXISTS recon.match_result;
DROP TABLE IF EXISTS recon.run_log;

DROP TABLE IF EXISTS core.bank_statement_line;
DROP TABLE IF EXISTS core.payment;
DROP TABLE IF EXISTS core.customer;
DROP TABLE IF EXISTS core.channel;
DROP TABLE IF EXISTS core.correspondent_bank;
DROP TABLE IF EXISTS core.exchange_rate;
DROP TABLE IF EXISTS core.country;
DROP TABLE IF EXISTS core.currency;
DROP TABLE IF EXISTS core.calendar;
DROP TABLE IF EXISTS core.etl_reject;

DROP TABLE IF EXISTS stg.currencies;
DROP TABLE IF EXISTS stg.countries;
DROP TABLE IF EXISTS stg.correspondent_banks;
DROP TABLE IF EXISTS stg.channels;
DROP TABLE IF EXISTS stg.exchange_rates;
DROP TABLE IF EXISTS stg.customers;
DROP TABLE IF EXISTS stg.payments;
DROP TABLE IF EXISTS stg.bank_statement_lines;
GO

/* -----------------------------------------------------------------------------
   STAGING: one table per CSV file, every column as text.
   Nothing is rejected at this point; cleaning happens in 03_transform_core.sql
   ----------------------------------------------------------------------------- */
CREATE TABLE stg.currencies (
    currency_code NVARCHAR(10),
    currency_name NVARCHAR(100));

CREATE TABLE stg.countries (
    country_code  NVARCHAR(10),
    country_name  NVARCHAR(100),
    region        NVARCHAR(100),
    currency_code NVARCHAR(10));

CREATE TABLE stg.correspondent_banks (
    bank_id      NVARCHAR(20),
    bank_name    NVARCHAR(200),
    swift_code   NVARCHAR(20),
    country_code NVARCHAR(10));

CREATE TABLE stg.channels (
    channel_id   NVARCHAR(20),
    channel_name NVARCHAR(100));

CREATE TABLE stg.exchange_rates (
    rate_date     NVARCHAR(30),
    currency_code NVARCHAR(10),
    units_per_usd NVARCHAR(50));

CREATE TABLE stg.customers (
    customer_id     NVARCHAR(20),
    customer_name   NVARCHAR(300),
    customer_type   NVARCHAR(50),
    segment         NVARCHAR(50),
    city            NVARCHAR(100),
    onboarding_date NVARCHAR(30),
    risk_rating     NVARCHAR(20));

CREATE TABLE stg.payments (
    payment_id            NVARCHAR(20),
    reference             NVARCHAR(50),
    customer_id           NVARCHAR(20),
    direction             NVARCHAR(20),
    payment_type          NVARCHAR(50),
    counterparty_country  NVARCHAR(10),
    currency_code         NVARCHAR(10),
    amount                NVARCHAR(50),
    fee_usd               NVARCHAR(50),
    channel               NVARCHAR(100),
    correspondent_bank_id NVARCHAR(20),
    created_at            NVARCHAR(30),
    settled_at            NVARCHAR(30),
    status                NVARCHAR(30),
    status_reason         NVARCHAR(200));

CREATE TABLE stg.bank_statement_lines (
    statement_line_id NVARCHAR(20),
    bank_id           NVARCHAR(20),
    currency_code     NVARCHAR(10),
    value_date        NVARCHAR(30),
    amount            NVARCHAR(50),
    reference_text    NVARCHAR(100),
    description       NVARCHAR(300));
GO

/* -----------------------------------------------------------------------------
   CORE: typed model with primary keys, foreign keys and business rules
   ----------------------------------------------------------------------------- */
CREATE TABLE core.currency (
    currency_code CHAR(3)      NOT NULL CONSTRAINT pk_currency PRIMARY KEY,
    currency_name NVARCHAR(50) NOT NULL);

CREATE TABLE core.country (
    country_code  CHAR(2)      NOT NULL CONSTRAINT pk_country PRIMARY KEY,
    country_name  NVARCHAR(60) NOT NULL,
    region        NVARCHAR(30) NOT NULL,
    currency_code CHAR(3)      NOT NULL
        CONSTRAINT fk_country_currency REFERENCES core.currency (currency_code));

CREATE TABLE core.exchange_rate (
    rate_date     DATE          NOT NULL,
    currency_code CHAR(3)       NOT NULL
        CONSTRAINT fk_rate_currency REFERENCES core.currency (currency_code),
    units_per_usd DECIMAL(18,6) NOT NULL CONSTRAINT ck_rate_positive CHECK (units_per_usd > 0),
    CONSTRAINT pk_exchange_rate PRIMARY KEY (rate_date, currency_code));

CREATE TABLE core.correspondent_bank (
    bank_id      INT           NOT NULL CONSTRAINT pk_correspondent_bank PRIMARY KEY,
    bank_name    NVARCHAR(100) NOT NULL,
    swift_code   CHAR(8)       NOT NULL CONSTRAINT uq_bank_swift UNIQUE,
    country_code CHAR(2)       NOT NULL
        CONSTRAINT fk_bank_country REFERENCES core.country (country_code));

CREATE TABLE core.channel (
    channel_id   TINYINT      NOT NULL CONSTRAINT pk_channel PRIMARY KEY,
    channel_name NVARCHAR(30) NOT NULL CONSTRAINT uq_channel_name UNIQUE);

CREATE TABLE core.customer (
    customer_id     CHAR(6)       NOT NULL CONSTRAINT pk_customer PRIMARY KEY,
    customer_name   NVARCHAR(120) NOT NULL,
    customer_type   NVARCHAR(20)  NOT NULL
        CONSTRAINT ck_customer_type CHECK (customer_type IN (N'Individual', N'Company', N'Public Entity')),
    segment         NVARCHAR(20)  NOT NULL
        CONSTRAINT ck_customer_segment CHECK (segment IN (N'Retail', N'SME', N'Corporate', N'Government')),
    city            NVARCHAR(40)  NOT NULL,
    onboarding_date DATE          NOT NULL,
    risk_rating     NVARCHAR(10)  NOT NULL
        CONSTRAINT ck_customer_risk CHECK (risk_rating IN (N'Low', N'Medium', N'High')));

CREATE TABLE core.payment (
    payment_id            INT           NOT NULL CONSTRAINT pk_payment PRIMARY KEY,
    reference             CHAR(14)      NOT NULL CONSTRAINT uq_payment_reference UNIQUE,
    customer_id           CHAR(6)       NOT NULL
        CONSTRAINT fk_payment_customer REFERENCES core.customer (customer_id),
    direction             NVARCHAR(10)  NOT NULL
        CONSTRAINT ck_payment_direction CHECK (direction IN (N'Inbound', N'Outbound')),
    payment_type          NVARCHAR(30)  NOT NULL,
    counterparty_country  CHAR(2)       NOT NULL
        CONSTRAINT fk_payment_country REFERENCES core.country (country_code),
    currency_code         CHAR(3)       NOT NULL
        CONSTRAINT fk_payment_currency REFERENCES core.currency (currency_code),
    amount                DECIMAL(19,2) NOT NULL CONSTRAINT ck_payment_amount CHECK (amount > 0),
    fx_rate_to_usd        DECIMAL(18,6) NOT NULL,      -- units of currency per 1 USD on the creation date
    amount_usd            DECIMAL(19,2) NOT NULL,
    fee_usd               DECIMAL(10,2) NOT NULL CONSTRAINT ck_payment_fee CHECK (fee_usd >= 0),
    channel_id            TINYINT       NOT NULL
        CONSTRAINT fk_payment_channel REFERENCES core.channel (channel_id),
    correspondent_bank_id INT           NOT NULL
        CONSTRAINT fk_payment_bank REFERENCES core.correspondent_bank (bank_id),
    created_at            DATETIME2(0)  NOT NULL,
    settled_at            DATETIME2(0)  NULL,
    status                NVARCHAR(10)  NOT NULL
        CONSTRAINT ck_payment_status CHECK (status IN (N'Completed', N'Pending', N'Rejected', N'Returned')),
    status_reason         NVARCHAR(60)  NULL,
    processing_hours AS CAST(DATEDIFF(MINUTE, created_at, settled_at) / 60.0 AS DECIMAL(9,2)) PERSISTED,
    CONSTRAINT ck_payment_settlement_order CHECK (settled_at IS NULL OR settled_at >= created_at),
    CONSTRAINT ck_payment_settlement_status CHECK (
        (status IN (N'Completed', N'Returned') AND settled_at IS NOT NULL)
     OR (status IN (N'Pending', N'Rejected')  AND settled_at IS NULL)));

CREATE INDEX ix_payment_created  ON core.payment (created_at) INCLUDE (amount_usd, fee_usd, status);
CREATE INDEX ix_payment_customer ON core.payment (customer_id, created_at);
CREATE INDEX ix_payment_bank     ON core.payment (correspondent_bank_id, currency_code, settled_at);

CREATE TABLE core.bank_statement_line (
    statement_line_id INT           NOT NULL CONSTRAINT pk_statement_line PRIMARY KEY,
    bank_id           INT           NOT NULL
        CONSTRAINT fk_statement_bank REFERENCES core.correspondent_bank (bank_id),
    currency_code     CHAR(3)       NOT NULL
        CONSTRAINT fk_statement_currency REFERENCES core.currency (currency_code),
    value_date        DATE          NOT NULL,
    amount            DECIMAL(19,2) NOT NULL,           -- signed: + credit (money in), - debit (money out)
    reference_text    NVARCHAR(40)  NULL,               -- free text typed by the correspondent
    description       NVARCHAR(120) NOT NULL);

CREATE INDEX ix_statement_account ON core.bank_statement_line (bank_id, currency_code, value_date);

CREATE TABLE core.calendar (
    [date]              DATE         NOT NULL CONSTRAINT pk_calendar PRIMARY KEY,
    [year]              SMALLINT     NOT NULL,
    [quarter]           TINYINT      NOT NULL,
    [month]             TINYINT      NOT NULL,
    month_name          NVARCHAR(10) NOT NULL,
    month_short         CHAR(3)      NOT NULL,
    year_month          CHAR(7)      NOT NULL,          -- e.g. 2025-03
    day_of_month        TINYINT      NOT NULL,
    day_of_week         TINYINT      NOT NULL,          -- 1 = Monday ... 7 = Sunday
    day_name            NVARCHAR(10) NOT NULL,
    is_weekend          BIT          NOT NULL,
    is_business_day     BIT          NOT NULL,
    business_day_number INT          NOT NULL);         -- running count of business days

CREATE TABLE core.etl_reject (
    reject_id    INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_etl_reject PRIMARY KEY,
    source_table NVARCHAR(50)  NOT NULL,
    business_key NVARCHAR(50)  NULL,
    reason       NVARCHAR(200) NOT NULL,
    rejected_at  DATETIME2(0)  NOT NULL CONSTRAINT df_etl_reject_at DEFAULT SYSDATETIME());
GO
