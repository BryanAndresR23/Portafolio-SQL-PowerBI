/* =============================================================================
   International Payments Analytics
   06 - Reporting layer (star schema) for Power BI
   -----------------------------------------------------------------------------
   Power BI connects ONLY to the rpt schema. Business rules (USD conversion,
   SLA, aging) live here, in one place, instead of being repeated in DAX.

       dim_date  dim_customer  dim_country  dim_currency  dim_channel  dim_correspondent_bank
            \          |            |            |             |             /
             +---------+------------+--- fact_payment ---------+------------+
                                         fact_reconciliation
                                         fact_fx_rate
   ============================================================================= */

USE InternationalPaymentsAnalytics;
GO

/* ---------------------------------------------------------------- dimensions */
CREATE OR ALTER VIEW rpt.dim_date AS
SELECT
    [date],
    [year],
    [quarter],
    CONCAT(N'Q', [quarter])               AS quarter_label,
    CONCAT([year], N'-Q', [quarter])      AS year_quarter,
    [month],
    month_name,
    month_short,
    year_month,
    DATEFROMPARTS([year], [month], 1)     AS month_start,
    day_of_month,
    day_of_week,
    day_name,
    is_weekend,
    is_business_day
FROM core.calendar;
GO

CREATE OR ALTER VIEW rpt.dim_customer AS
SELECT
    c.customer_id,
    c.customer_name,
    c.customer_type,
    c.segment,
    c.city,
    c.onboarding_date,
    YEAR(c.onboarding_date) AS onboarding_year,
    c.risk_rating,
    CASE
        WHEN t.tenure_years < 1 THEN N'1. Less than 1 year'
        WHEN t.tenure_years < 3 THEN N'2. 1-3 years'
        WHEN t.tenure_years < 5 THEN N'3. 3-5 years'
        ELSE                         N'4. 5+ years'
    END AS tenure_band
FROM core.customer AS c
CROSS APPLY (SELECT DATEDIFF(DAY, c.onboarding_date, (SELECT MAX([date]) FROM core.calendar)) / 365.25 AS tenure_years) AS t;
GO

CREATE OR ALTER VIEW rpt.dim_country AS
SELECT country_code, country_name, region, currency_code AS local_currency
FROM core.country;
GO

CREATE OR ALTER VIEW rpt.dim_currency AS
SELECT currency_code, currency_name
FROM core.currency;
GO

CREATE OR ALTER VIEW rpt.dim_channel AS
SELECT channel_id, channel_name
FROM core.channel;
GO

CREATE OR ALTER VIEW rpt.dim_correspondent_bank AS
SELECT b.bank_id, b.bank_name, b.swift_code, c.country_name AS bank_country
FROM core.correspondent_bank AS b
JOIN core.country AS c ON c.country_code = b.country_code;
GO

/* --------------------------------------------------------------------- facts */
CREATE OR ALTER VIEW rpt.fact_payment AS
SELECT
    p.payment_id,
    p.reference,
    p.customer_id,
    p.counterparty_country                     AS country_code,
    p.currency_code,
    p.channel_id,
    p.correspondent_bank_id                    AS bank_id,
    CAST(p.created_at AS DATE)                 AS created_date,
    p.created_at,
    DATEPART(HOUR, p.created_at)               AS created_hour,
    CAST(p.settled_at AS DATE)                 AS settled_date,
    p.direction,
    p.payment_type,
    p.status,
    p.status_reason,
    p.amount,
    p.fx_rate_to_usd,
    p.amount_usd,
    p.fee_usd,
    CASE WHEN p.direction = N'Inbound' THEN p.amount_usd ELSE -p.amount_usd END AS net_flow_usd,
    p.processing_hours,
    -- business days between creation and settlement (weekends do not count)
    s.business_days_to_settle,
    -- SLA: settled no later than the next business day (T+1)
    CASE WHEN p.settled_at IS NULL THEN NULL
         WHEN s.business_days_to_settle <= 1 THEN 1 ELSE 0 END AS is_within_sla
FROM core.payment AS p
JOIN core.calendar AS created ON created.[date] = CAST(p.created_at AS DATE)
LEFT JOIN core.calendar AS settled ON settled.[date] = CAST(p.settled_at AS DATE)
CROSS APPLY (SELECT settled.business_day_number - created.business_day_number AS business_days_to_settle) AS s;
GO

CREATE OR ALTER VIEW rpt.fact_fx_rate AS
SELECT
    r.rate_date,
    r.currency_code,
    r.units_per_usd,
    CAST(1.0 / r.units_per_usd AS DECIMAL(18,8)) AS usd_per_unit,
    CAST(100.0 * (r.units_per_usd / LAG(r.units_per_usd) OVER (PARTITION BY r.currency_code ORDER BY r.rate_date) - 1)
         AS DECIMAL(9,4)) AS daily_change_pct
FROM core.exchange_rate AS r
JOIN core.calendar AS c ON c.[date] = r.rate_date
WHERE c.is_business_day = 1;
GO

CREATE OR ALTER VIEW rpt.fact_reconciliation AS
SELECT
    r.result_id,
    r.bank_id,
    r.currency_code,
    r.item_type,
    r.payment_id,
    r.statement_line_id,
    d.item_date,
    r.ledger_date,
    r.statement_date,
    r.ledger_amount,
    r.statement_amount,
    r.amount_difference,
    r.days_difference,
    r.match_rule,
    r.recon_status,
    r.recon_category,
    CAST(ABS(COALESCE(r.ledger_amount, r.statement_amount)) / fx.units_per_usd AS DECIMAL(19,2)) AS item_value_usd,
    CAST(r.amount_difference / fx.units_per_usd AS DECIMAL(19,2))                               AS difference_usd,
    CASE WHEN r.recon_status = N'Exception' THEN a.age_days END                                 AS age_days,
    CASE WHEN r.recon_status <> N'Exception' THEN NULL
         WHEN a.age_days <= 7  THEN N'1. 0-7 days'
         WHEN a.age_days <= 30 THEN N'2. 8-30 days'
         WHEN a.age_days <= 90 THEN N'3. 31-90 days'
         ELSE                       N'4. Over 90 days' END                                      AS aging_bucket
FROM recon.match_result AS r
CROSS APPLY (SELECT COALESCE(r.ledger_date, r.statement_date) AS item_date) AS d
CROSS APPLY (SELECT DATEDIFF(DAY, d.item_date, (SELECT MAX([date]) FROM core.calendar)) AS age_days) AS a
JOIN core.exchange_rate AS fx
  ON fx.rate_date = d.item_date
 AND fx.currency_code = r.currency_code
WHERE r.run_id = (SELECT MAX(run_id) FROM recon.run_log);
GO

/* Quick check: row counts per view */
SELECT N'rpt.fact_payment' AS view_name, COUNT(*) AS row_count FROM rpt.fact_payment
UNION ALL SELECT N'rpt.fact_reconciliation', COUNT(*) FROM rpt.fact_reconciliation
UNION ALL SELECT N'rpt.fact_fx_rate',        COUNT(*) FROM rpt.fact_fx_rate
UNION ALL SELECT N'rpt.dim_customer',        COUNT(*) FROM rpt.dim_customer
UNION ALL SELECT N'rpt.dim_date',            COUNT(*) FROM rpt.dim_date;
GO
