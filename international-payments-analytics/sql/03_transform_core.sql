/* =============================================================================
   International Payments Analytics
   03 - Transform staging -> core (clean, validate, deduplicate, enrich)
   -----------------------------------------------------------------------------
   What this script fixes on the way in:
     * extra / repeated spaces in customer names
     * inconsistent casing in segments, channels and country codes
     * duplicated customer and payment rows
     * test records (unknown customer, zero amount)
     * converts every payment to USD with the exchange rate of its creation date
   Every row that is left out is logged in core.etl_reject with the reason.
   Runs as one transaction: either everything loads or nothing does.
   ============================================================================= */

USE InternationalPaymentsAnalytics;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

/* 0. Clear the previous load (children first) ------------------------------ */
IF OBJECT_ID(N'recon.match_result') IS NOT NULL DELETE FROM recon.match_result;
DELETE FROM core.bank_statement_line;
DELETE FROM core.payment;
DELETE FROM core.customer;
DELETE FROM core.channel;
DELETE FROM core.correspondent_bank;
DELETE FROM core.exchange_rate;
DELETE FROM core.country;
DELETE FROM core.currency;
DELETE FROM core.calendar;
DELETE FROM core.etl_reject;

/* 1. Reference data --------------------------------------------------------- */
INSERT core.currency (currency_code, currency_name)
SELECT UPPER(TRIM(currency_code)), TRIM(currency_name)
FROM stg.currencies;

INSERT core.country (country_code, country_name, region, currency_code)
SELECT UPPER(TRIM(country_code)), TRIM(country_name), TRIM(region), UPPER(TRIM(currency_code))
FROM stg.countries;

INSERT core.correspondent_bank (bank_id, bank_name, swift_code, country_code)
SELECT CAST(bank_id AS INT), TRIM(bank_name), UPPER(TRIM(swift_code)), UPPER(TRIM(country_code))
FROM stg.correspondent_banks;

INSERT core.channel (channel_id, channel_name)
SELECT CAST(channel_id AS TINYINT), TRIM(channel_name)
FROM stg.channels;

INSERT core.exchange_rate (rate_date, currency_code, units_per_usd)
SELECT CONVERT(DATE, rate_date, 23), UPPER(TRIM(currency_code)), CAST(units_per_usd AS DECIMAL(18,6))
FROM stg.exchange_rates;

/* 2. Customers -------------------------------------------------------------- */
DROP TABLE IF EXISTS #customers;

SELECT
    TRIM(customer_id) AS customer_id,
    -- collapse any run of spaces into one: 'Ana   Pérez' -> 'Ana<><><>Pérez' -> 'Ana<>Pérez' -> 'Ana Pérez'
    REPLACE(REPLACE(REPLACE(TRIM(customer_name), N' ', N'<>'), N'><', N''), N'<>', N' ') AS customer_name,
    TRIM(customer_type) AS customer_type,
    CASE UPPER(TRIM(segment))
        WHEN N'RETAIL'     THEN N'Retail'
        WHEN N'SME'        THEN N'SME'
        WHEN N'CORPORATE'  THEN N'Corporate'
        WHEN N'GOVERNMENT' THEN N'Government'
    END AS segment,
    TRIM(city) AS city,
    TRY_CONVERT(DATE, onboarding_date, 23) AS onboarding_date,
    TRIM(risk_rating) AS risk_rating,
    ROW_NUMBER() OVER (PARTITION BY TRIM(customer_id) ORDER BY (SELECT NULL)) AS row_num
INTO #customers
FROM stg.customers;

INSERT core.etl_reject (source_table, business_key, reason)
SELECT N'stg.customers', customer_id,
       CASE WHEN row_num > 1           THEN N'Duplicate row (first occurrence kept)'
            WHEN segment IS NULL        THEN N'Unknown segment'
            WHEN onboarding_date IS NULL THEN N'Invalid onboarding date' END
FROM #customers
WHERE row_num > 1 OR segment IS NULL OR onboarding_date IS NULL;

INSERT core.customer (customer_id, customer_name, customer_type, segment, city, onboarding_date, risk_rating)
SELECT customer_id, customer_name, customer_type, segment, city, onboarding_date, risk_rating
FROM #customers
WHERE row_num = 1 AND segment IS NOT NULL AND onboarding_date IS NOT NULL;

/* 3. Payments --------------------------------------------------------------- */
DROP TABLE IF EXISTS #payments;

SELECT
    TRY_CAST(p.payment_id AS INT)              AS payment_id,
    UPPER(TRIM(p.reference))                   AS reference,
    TRIM(p.customer_id)                        AS customer_id,
    TRIM(p.direction)                          AS direction,
    TRIM(p.payment_type)                       AS payment_type,
    UPPER(TRIM(p.counterparty_country))        AS counterparty_country,
    UPPER(TRIM(p.currency_code))               AS currency_code,
    TRY_CAST(p.amount AS DECIMAL(19,2))        AS amount,
    TRY_CAST(p.fee_usd AS DECIMAL(10,2))       AS fee_usd,
    ch.channel_id,
    TRY_CAST(p.correspondent_bank_id AS INT)   AS correspondent_bank_id,
    TRY_CONVERT(DATETIME2(0), p.created_at, 120)                     AS created_at,
    TRY_CONVERT(DATETIME2(0), NULLIF(TRIM(p.settled_at), N''), 120)  AS settled_at,
    TRIM(p.status)                             AS status,
    NULLIF(TRIM(p.status_reason), N'')         AS status_reason,
    ROW_NUMBER() OVER (PARTITION BY TRIM(p.payment_id) ORDER BY (SELECT NULL)) AS row_num,
    CAST(NULL AS DECIMAL(18,6))                AS units_per_usd,
    CAST(NULL AS NVARCHAR(200))                AS reject_reason
INTO #payments
FROM stg.payments AS p
LEFT JOIN core.channel AS ch
       ON UPPER(ch.channel_name) = UPPER(TRIM(p.channel));

UPDATE p
SET units_per_usd = r.units_per_usd
FROM #payments AS p
JOIN core.exchange_rate AS r
  ON r.rate_date = CAST(p.created_at AS DATE)
 AND r.currency_code = p.currency_code;

UPDATE p
SET reject_reason =
    CASE
        WHEN p.row_num > 1                         THEN N'Duplicate row (first occurrence kept)'
        WHEN c.customer_id IS NULL                 THEN N'Unknown customer (test record)'
        WHEN p.amount IS NULL OR p.amount <= 0     THEN N'Amount missing or not positive'
        WHEN p.channel_id IS NULL                  THEN N'Unknown channel'
        WHEN p.created_at IS NULL                  THEN N'Invalid creation date'
        WHEN co.country_code IS NULL               THEN N'Unknown counterparty country'
        WHEN p.units_per_usd IS NULL               THEN N'No exchange rate for date and currency'
    END
FROM #payments AS p
LEFT JOIN core.customer AS c  ON c.customer_id = p.customer_id
LEFT JOIN core.country  AS co ON co.country_code = p.counterparty_country;

INSERT core.etl_reject (source_table, business_key, reason)
SELECT N'stg.payments', CAST(payment_id AS NVARCHAR(50)), reject_reason
FROM #payments
WHERE reject_reason IS NOT NULL;

INSERT core.payment (
    payment_id, reference, customer_id, direction, payment_type, counterparty_country,
    currency_code, amount, fx_rate_to_usd, amount_usd, fee_usd, channel_id,
    correspondent_bank_id, created_at, settled_at, status, status_reason)
SELECT
    payment_id, reference, customer_id, direction, payment_type, counterparty_country,
    currency_code, amount, units_per_usd, CAST(amount / units_per_usd AS DECIMAL(19,2)), fee_usd,
    channel_id, correspondent_bank_id, created_at, settled_at, status, status_reason
FROM #payments
WHERE reject_reason IS NULL;

/* 4. Correspondent bank statements ----------------------------------------- */
INSERT core.bank_statement_line (statement_line_id, bank_id, currency_code, value_date, amount, reference_text, description)
SELECT
    CAST(statement_line_id AS INT),
    CAST(bank_id AS INT),
    UPPER(TRIM(currency_code)),
    CONVERT(DATE, value_date, 23),
    CAST(amount AS DECIMAL(19,2)),
    NULLIF(TRIM(reference_text), N''),
    TRIM(description)
FROM stg.bank_statement_lines;

/* 5. Calendar (recursive CTE) ------------------------------------------------
      business_day_number is a running count of business days. Subtracting two
      of them gives the business days elapsed between two dates (used for SLA). */
DECLARE @from DATE = (SELECT DATEFROMPARTS(YEAR(MIN(created_at)), 1, 1) FROM core.payment);
DECLARE @to   DATE = (SELECT DATEFROMPARTS(YEAR(MAX(d)), 12, 31)
                      FROM (SELECT MAX(value_date) AS d FROM core.bank_statement_line
                            UNION ALL
                            SELECT MAX(CAST(created_at AS DATE)) FROM core.payment) AS x);

WITH days AS (
    SELECT @from AS d
    UNION ALL
    SELECT DATEADD(DAY, 1, d) FROM days WHERE d < @to
), enriched AS (
    SELECT
        d,
        (DATEDIFF(DAY, '19000101', d) % 7) + 1 AS dow          -- 1900-01-01 was a Monday
    FROM days
)
INSERT core.calendar (
    [date], [year], [quarter], [month], month_name, month_short, year_month,
    day_of_month, day_of_week, day_name, is_weekend, is_business_day, business_day_number)
SELECT
    d,
    YEAR(d),
    DATEPART(QUARTER, d),
    MONTH(d),
    FORMAT(d, 'MMMM', 'en-US'),
    FORMAT(d, 'MMM', 'en-US'),
    FORMAT(d, 'yyyy-MM'),
    DAY(d),
    dow,
    FORMAT(d, 'dddd', 'en-US'),
    CASE WHEN dow >= 6 THEN 1 ELSE 0 END,
    CASE WHEN dow <= 5 THEN 1 ELSE 0 END,
    SUM(CASE WHEN dow <= 5 THEN 1 ELSE 0 END) OVER (ORDER BY d ROWS UNBOUNDED PRECEDING)
FROM enriched
OPTION (MAXRECURSION 0);

COMMIT TRANSACTION;

/* 6. Load summary ----------------------------------------------------------- */
SELECT N'core.customer' AS core_table, COUNT(*) AS rows_loaded FROM core.customer
UNION ALL SELECT N'core.payment',             COUNT(*) FROM core.payment
UNION ALL SELECT N'core.bank_statement_line', COUNT(*) FROM core.bank_statement_line
UNION ALL SELECT N'core.exchange_rate',       COUNT(*) FROM core.exchange_rate
UNION ALL SELECT N'core.calendar',            COUNT(*) FROM core.calendar;

SELECT source_table, reason, COUNT(*) AS rows_rejected
FROM core.etl_reject
GROUP BY source_table, reason
ORDER BY source_table, rows_rejected DESC;
GO
