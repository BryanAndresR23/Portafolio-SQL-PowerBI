/* =============================================================================
   International Payments Analytics
   07 - Business questions answered with SQL
   -----------------------------------------------------------------------------
   Each block answers one business question (EN | ES) and names the SQL
   technique it demonstrates. Amounts are in USD. Unless stated otherwise,
   "processed" means payments with status = 'Completed'.
   ============================================================================= */

USE InternationalPaymentsAnalytics;
GO

/* -----------------------------------------------------------------------------
   Q1. How do volume and value evolve month by month?
       ¿Cómo evolucionan el volumen y el valor mes a mes?
   Technique: CTE + LAG() with offsets 1 (MoM) and 12 (YoY)
   ----------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT DATEFROMPARTS(YEAR(created_at), MONTH(created_at), 1) AS month_start,
           COUNT(*)        AS payments,
           SUM(amount_usd) AS value_usd,
           SUM(fee_usd)    AS fee_revenue_usd
    FROM core.payment
    WHERE status = N'Completed'
    GROUP BY DATEFROMPARTS(YEAR(created_at), MONTH(created_at), 1)
)
SELECT month_start,
       payments,
       CAST(value_usd / 1e6 AS DECIMAL(10,2)) AS value_usd_millions,
       fee_revenue_usd,
       CAST(100.0 * (payments - LAG(payments) OVER (ORDER BY month_start))
            / NULLIF(LAG(payments) OVER (ORDER BY month_start), 0) AS DECIMAL(6,1))      AS payments_mom_pct,
       CAST(100.0 * (payments - LAG(payments, 12) OVER (ORDER BY month_start))
            / NULLIF(LAG(payments, 12) OVER (ORDER BY month_start), 0) AS DECIMAL(6,1))  AS payments_yoy_pct,
       CAST(100.0 * (fee_revenue_usd - LAG(fee_revenue_usd, 12) OVER (ORDER BY month_start))
            / NULLIF(LAG(fee_revenue_usd, 12) OVER (ORDER BY month_start), 0) AS DECIMAL(6,1)) AS fees_yoy_pct
FROM monthly
ORDER BY month_start;
GO

/* -----------------------------------------------------------------------------
   Q2. Fee revenue: year-to-date running total and 3-month moving average
       Ingresos por comisiones: acumulado del año y media móvil de 3 meses
   Technique: window frames (ROWS UNBOUNDED PRECEDING / ROWS 2 PRECEDING)
   ----------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT YEAR(created_at) AS [year], MONTH(created_at) AS [month], SUM(fee_usd) AS fee_revenue_usd
    FROM core.payment
    WHERE status IN (N'Completed', N'Returned')
    GROUP BY YEAR(created_at), MONTH(created_at)
)
SELECT [year], [month], fee_revenue_usd,
       SUM(fee_revenue_usd) OVER (PARTITION BY [year] ORDER BY [month] ROWS UNBOUNDED PRECEDING) AS ytd_fee_revenue_usd,
       CAST(AVG(fee_revenue_usd) OVER (ORDER BY [year], [month] ROWS 2 PRECEDING) AS DECIMAL(12,2)) AS moving_avg_3m_usd
FROM monthly
ORDER BY [year], [month];
GO

/* -----------------------------------------------------------------------------
   Q3. Top 10 payment corridors by value and their share of the total
       Top 10 corredores de pago por valor y su participación
   Technique: aggregation + SUM() OVER () for shares + RANK()
   ----------------------------------------------------------------------------- */
WITH corridors AS (
    SELECT p.direction, c.country_name, COUNT(*) AS payments, SUM(p.amount_usd) AS value_usd
    FROM core.payment AS p
    JOIN core.country AS c ON c.country_code = p.counterparty_country
    WHERE p.status = N'Completed'
    GROUP BY p.direction, c.country_name
)
SELECT TOP (10)
       RANK() OVER (ORDER BY value_usd DESC) AS corridor_rank,
       CASE direction WHEN N'Inbound' THEN country_name + N' -> Ecuador'
                      ELSE N'Ecuador -> ' + country_name END AS corridor,
       payments,
       CAST(value_usd / 1e6 AS DECIMAL(10,2)) AS value_usd_millions,
       CAST(100.0 * value_usd / SUM(value_usd) OVER () AS DECIMAL(5,1)) AS share_pct,
       CAST(value_usd / payments AS DECIMAL(12,2)) AS avg_ticket_usd
FROM corridors
ORDER BY value_usd DESC;
GO

/* -----------------------------------------------------------------------------
   Q4. Customer concentration: how many customers generate 80% of the value?
       Concentración: ¿cuántos clientes generan el 80% del valor? (Pareto)
   Technique: running share with window functions partitioned by segment
   ----------------------------------------------------------------------------- */
WITH value_by_customer AS (
    SELECT c.segment, p.customer_id, SUM(p.amount_usd) AS value_usd
    FROM core.payment AS p
    JOIN core.customer AS c ON c.customer_id = p.customer_id
    WHERE p.status = N'Completed'
    GROUP BY c.segment, p.customer_id
), running AS (
    SELECT segment,
           ROW_NUMBER() OVER (PARTITION BY segment ORDER BY value_usd DESC) AS rank_in_segment,
           COUNT(*)     OVER (PARTITION BY segment)                         AS active_customers,
           SUM(value_usd) OVER (PARTITION BY segment ORDER BY value_usd DESC ROWS UNBOUNDED PRECEDING)
             / SUM(value_usd) OVER (PARTITION BY segment)                   AS cumulative_share
    FROM value_by_customer
)
SELECT segment,
       MAX(active_customers) AS active_customers,
       MIN(CASE WHEN cumulative_share >= 0.8 THEN rank_in_segment END) AS customers_for_80pct_of_value,
       CAST(100.0 * MIN(CASE WHEN cumulative_share >= 0.8 THEN rank_in_segment END)
            / MAX(active_customers) AS DECIMAL(5,1)) AS pct_of_customers
FROM running
GROUP BY segment
ORDER BY segment;
GO

/* -----------------------------------------------------------------------------
   Q5. Top 3 customers of each segment
       Los 3 principales clientes de cada segmento
   Technique: DENSE_RANK() OVER (PARTITION BY ...) filtered in a CTE
   ----------------------------------------------------------------------------- */
WITH ranked AS (
    SELECT c.segment, c.customer_name, COUNT(*) AS payments, SUM(p.amount_usd) AS value_usd,
           DENSE_RANK() OVER (PARTITION BY c.segment ORDER BY SUM(p.amount_usd) DESC) AS rank_in_segment
    FROM core.payment AS p
    JOIN core.customer AS c ON c.customer_id = p.customer_id
    WHERE p.status = N'Completed'
    GROUP BY c.segment, c.customer_id, c.customer_name
)
SELECT segment, rank_in_segment, customer_name, payments,
       CAST(value_usd / 1e6 AS DECIMAL(10,2)) AS value_usd_millions
FROM ranked
WHERE rank_in_segment <= 3
ORDER BY segment, rank_in_segment;
GO

/* -----------------------------------------------------------------------------
   Q6. Settlement SLA (T+1) and median processing time by correspondent
       Cumplimiento del SLA (T+1) y tiempo mediano por banco corresponsal
   Technique: PERCENTILE_CONT() as a window function + conditional averages
   ----------------------------------------------------------------------------- */
WITH settled AS (
    SELECT b.bank_name, f.currency_code, f.is_within_sla, f.processing_hours,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.processing_hours)
               OVER (PARTITION BY b.bank_name, f.currency_code) AS median_hours
    FROM rpt.fact_payment AS f
    JOIN core.correspondent_bank AS b ON b.bank_id = f.bank_id
    WHERE f.is_within_sla IS NOT NULL
)
SELECT bank_name, currency_code,
       COUNT(*) AS settled_payments,
       CAST(100.0 * AVG(CAST(is_within_sla AS DECIMAL(5,2))) AS DECIMAL(5,1)) AS sla_pct,
       CAST(MAX(median_hours) AS DECIMAL(6,1)) AS median_processing_hours
FROM settled
GROUP BY bank_name, currency_code
ORDER BY sla_pct;
GO

/* -----------------------------------------------------------------------------
   Q7. SLA alerts: months where a currency fell > 15 pp below its own
       trailing 6-month average (minimum 30 payments in the month)
       Alertas de SLA: meses en que una moneda cayó > 15 pp bajo su promedio
       móvil de 6 meses
   Technique: window frame ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING
   ----------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT currency_code,
           DATEFROMPARTS(YEAR(created_date), MONTH(created_date), 1) AS month_start,
           COUNT(*) AS settled_payments,
           100.0 * AVG(CAST(is_within_sla AS DECIMAL(5,2))) AS sla_pct
    FROM rpt.fact_payment
    WHERE is_within_sla IS NOT NULL
    GROUP BY currency_code, DATEFROMPARTS(YEAR(created_date), MONTH(created_date), 1)
), baseline AS (
    SELECT *,
           AVG(sla_pct) OVER (PARTITION BY currency_code ORDER BY month_start
                              ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS trailing_6m_sla_pct
    FROM monthly
)
SELECT currency_code, month_start, settled_payments,
       CAST(sla_pct AS DECIMAL(5,1))                       AS sla_pct,
       CAST(trailing_6m_sla_pct AS DECIMAL(5,1))           AS trailing_6m_sla_pct,
       CAST(sla_pct - trailing_6m_sla_pct AS DECIMAL(5,1)) AS change_pp
FROM baseline
WHERE settled_payments >= 30
  AND sla_pct < trailing_6m_sla_pct - 15
ORDER BY month_start, currency_code;
GO

/* -----------------------------------------------------------------------------
   Q8. Rejection rate by channel: months above twice the channel's average
       Tasa de rechazo por canal: meses con más del doble del promedio del canal
   Technique: conditional aggregation + AVG() OVER (PARTITION BY ...)
   ----------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT ch.channel_name,
           DATEFROMPARTS(YEAR(p.created_at), MONTH(p.created_at), 1) AS month_start,
           COUNT(*) AS payments,
           SUM(CASE WHEN p.status = N'Rejected' THEN 1 ELSE 0 END) AS rejected,
           100.0 * SUM(CASE WHEN p.status = N'Rejected' THEN 1 ELSE 0 END) / COUNT(*) AS rejection_pct
    FROM core.payment AS p
    JOIN core.channel AS ch ON ch.channel_id = p.channel_id
    GROUP BY ch.channel_name, DATEFROMPARTS(YEAR(p.created_at), MONTH(p.created_at), 1)
), compared AS (
    SELECT *, AVG(rejection_pct) OVER (PARTITION BY channel_name) AS channel_avg_pct
    FROM monthly
)
SELECT channel_name, month_start, payments, rejected,
       CAST(rejection_pct AS DECIMAL(5,1))   AS rejection_pct,
       CAST(channel_avg_pct AS DECIMAL(5,1)) AS channel_avg_pct
FROM compared
WHERE rejection_pct > 2 * channel_avg_pct
ORDER BY channel_name, month_start;
GO

/* -----------------------------------------------------------------------------
   Q9. Why are payments rejected? Reasons ranked with cumulative share
       ¿Por qué se rechazan los pagos? Motivos con participación acumulada
   Technique: running SUM() OVER (ORDER BY ...) for a Pareto table
   ----------------------------------------------------------------------------- */
WITH reasons AS (
    SELECT status_reason, COUNT(*) AS rejected_payments
    FROM core.payment
    WHERE status = N'Rejected'
    GROUP BY status_reason
)
SELECT status_reason, rejected_payments,
       CAST(100.0 * rejected_payments / SUM(rejected_payments) OVER () AS DECIMAL(5,1)) AS share_pct,
       CAST(100.0 * SUM(rejected_payments) OVER (ORDER BY rejected_payments DESC ROWS UNBOUNDED PRECEDING)
            / SUM(rejected_payments) OVER () AS DECIMAL(5,1)) AS cumulative_pct
FROM reasons
ORDER BY rejected_payments DESC;
GO

/* -----------------------------------------------------------------------------
   Q10. Fee revenue and effective fee rate (basis points) with subtotals
        Ingresos por comisiones y tasa efectiva (pb) con subtotales
   Technique: GROUP BY ROLLUP + GROUPING() to label subtotal rows
   ----------------------------------------------------------------------------- */
SELECT CASE WHEN GROUPING(c.segment) = 1 THEN N'** All segments **' ELSE c.segment END AS segment,
       CASE WHEN GROUPING(p.payment_type) = 1 THEN N'-- Subtotal --' ELSE p.payment_type END AS payment_type,
       COUNT(*)                                                    AS payments,
       SUM(p.fee_usd)                                              AS fee_revenue_usd,
       CAST(10000.0 * SUM(p.fee_usd) / SUM(p.amount_usd) AS DECIMAL(8,2)) AS effective_fee_bps
FROM core.payment AS p
JOIN core.customer AS c ON c.customer_id = p.customer_id
WHERE p.status IN (N'Completed', N'Returned')
GROUP BY ROLLUP (c.segment, p.payment_type)
ORDER BY GROUPING(c.segment), c.segment, GROUPING(p.payment_type), fee_revenue_usd DESC;
GO

/* -----------------------------------------------------------------------------
   Q11. Retention of customers onboarded in 2024 (cohorts by onboarding month)
        Retención de clientes vinculados en 2024 (cohortes por mes de alta)
   Technique: cohort analysis + PIVOT (% of the cohort active N months later)
   ----------------------------------------------------------------------------- */
WITH cohort AS (
    SELECT customer_id, DATEFROMPARTS(YEAR(onboarding_date), MONTH(onboarding_date), 1) AS cohort_month
    FROM core.customer
    WHERE onboarding_date >= '2024-01-01' AND onboarding_date < '2025-01-01'
), activity AS (
    SELECT DISTINCT customer_id, DATEFROMPARTS(YEAR(created_at), MONTH(created_at), 1) AS activity_month
    FROM core.payment
    WHERE status <> N'Rejected'
), cohort_size AS (
    SELECT cohort_month, COUNT(*) AS customers FROM cohort GROUP BY cohort_month
), retention AS (
    SELECT c.cohort_month, s.customers AS cohort_customers,
           DATEDIFF(MONTH, c.cohort_month, a.activity_month) AS month_offset,
           CAST(100.0 * COUNT(*) / s.customers AS DECIMAL(5,1)) AS pct_active
    FROM cohort AS c
    JOIN activity AS a ON a.customer_id = c.customer_id
    JOIN cohort_size AS s ON s.cohort_month = c.cohort_month
    GROUP BY c.cohort_month, s.customers, DATEDIFF(MONTH, c.cohort_month, a.activity_month)
)
SELECT cohort_month, cohort_customers,
       [0] AS m0, [1] AS m1, [2] AS m2, [3] AS m3, [6] AS m6, [12] AS m12
FROM retention
PIVOT (MAX(pct_active) FOR month_offset IN ([0], [1], [2], [3], [6], [12])) AS pv
ORDER BY cohort_month;
GO

/* -----------------------------------------------------------------------------
   Q12. RFM segmentation (recency, frequency, monetary value)
        Segmentación RFM (recencia, frecuencia, valor)
   Technique: NTILE(5) scoring + CROSS APPLY for readable business rules
   ----------------------------------------------------------------------------- */
WITH base AS (
    SELECT p.customer_id,
           DATEDIFF(DAY, MAX(p.created_at), pe.period_end) AS recency_days,
           COUNT(*)                                        AS frequency,
           SUM(p.amount_usd)                               AS monetary_usd
    FROM core.payment AS p
    CROSS JOIN (SELECT MAX([date]) AS period_end FROM core.calendar) AS pe
    WHERE p.status = N'Completed'
    GROUP BY p.customer_id, pe.period_end
), scored AS (
    SELECT *,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,   -- 5 = most recent
           NTILE(5) OVER (ORDER BY frequency)         AS f_score,   -- 5 = most frequent
           NTILE(5) OVER (ORDER BY monetary_usd)      AS m_score    -- 5 = highest value
    FROM base
)
SELECT s.rfm_segment,
       COUNT(*)                                     AS customers,
       AVG(recency_days)                            AS avg_recency_days,
       AVG(frequency)                               AS avg_payments,
       CAST(SUM(monetary_usd) / 1e6 AS DECIMAL(10,2)) AS value_usd_millions
FROM scored
CROSS APPLY (SELECT CASE
        WHEN r_score >= 4 AND f_score >= 4 THEN N'Champions'
        WHEN r_score >= 3 AND f_score >= 3 THEN N'Loyal'
        WHEN r_score >= 4 AND f_score <= 2 THEN N'New / promising'
        WHEN r_score <= 2 AND f_score >= 3 THEN N'At risk'
        ELSE N'Hibernating' END AS rfm_segment) AS s
GROUP BY s.rfm_segment
ORDER BY value_usd_millions DESC;
GO

/* -----------------------------------------------------------------------------
   Q13. Unusual payments versus the customer's own history (AML-style alert)
        Pagos inusuales frente al historial del propio cliente (alerta tipo AML)
   Technique: AVG() / STDEV() OVER (PARTITION BY customer) -> z-score
   ----------------------------------------------------------------------------- */
WITH history AS (
    SELECT p.payment_id, p.reference, p.customer_id, p.created_at, p.payment_type, p.amount_usd,
           AVG(p.amount_usd)   OVER (PARTITION BY p.customer_id) AS customer_avg_usd,
           STDEV(p.amount_usd) OVER (PARTITION BY p.customer_id) AS customer_std_usd,
           COUNT(*)            OVER (PARTITION BY p.customer_id) AS customer_payments
    FROM core.payment AS p
    WHERE p.status <> N'Rejected'
)
SELECT TOP (15)
       h.reference, c.customer_name, c.segment, c.risk_rating, h.payment_type, h.created_at,
       h.amount_usd,
       CAST(h.customer_avg_usd AS DECIMAL(14,2)) AS customer_avg_usd,
       CAST((h.amount_usd - h.customer_avg_usd) / NULLIF(h.customer_std_usd, 0) AS DECIMAL(6,2)) AS z_score
FROM history AS h
JOIN core.customer AS c ON c.customer_id = h.customer_id
WHERE h.customer_payments >= 20
  AND (h.amount_usd - h.customer_avg_usd) / NULLIF(h.customer_std_usd, 0) > 4
ORDER BY z_score DESC;
GO

/* -----------------------------------------------------------------------------
   Q14. When do payments arrive? Hour of the day x day of the week
        ¿Cuándo llegan los pagos? Hora del día x día de la semana
   Technique: PIVOT on a calendar attribute
   ----------------------------------------------------------------------------- */
SELECT created_hour, [Monday], [Tuesday], [Wednesday], [Thursday], [Friday], [Saturday], [Sunday]
FROM (
    SELECT f.created_hour, d.day_name, f.payment_id
    FROM rpt.fact_payment AS f
    JOIN rpt.dim_date AS d ON d.[date] = f.created_date
) AS src
PIVOT (COUNT(payment_id) FOR day_name IN ([Monday], [Tuesday], [Wednesday], [Thursday], [Friday], [Saturday], [Sunday])) AS pv
ORDER BY created_hour;
GO

/* -----------------------------------------------------------------------------
   Q15. FX risk: yearly change and annualised volatility of each currency
        Riesgo cambiario: variación anual y volatilidad anualizada por moneda
   Technique: FIRST_VALUE / LAST_VALUE with an explicit frame + STDEV()
   ----------------------------------------------------------------------------- */
WITH rates AS (
    SELECT currency_code, YEAR(rate_date) AS [year], daily_change_pct,
           FIRST_VALUE(units_per_usd) OVER (PARTITION BY currency_code, YEAR(rate_date) ORDER BY rate_date
                                            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_rate,
           LAST_VALUE(units_per_usd)  OVER (PARTITION BY currency_code, YEAR(rate_date) ORDER BY rate_date
                                            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_rate
    FROM rpt.fact_fx_rate
    WHERE currency_code <> 'USD'
)
SELECT currency_code, [year],
       CAST(MAX(first_rate) AS DECIMAL(14,4)) AS units_per_usd_start,
       CAST(MAX(last_rate)  AS DECIMAL(14,4)) AS units_per_usd_end,
       CAST(100.0 * (MAX(last_rate) / MAX(first_rate) - 1) AS DECIMAL(6,2)) AS change_vs_usd_pct,  -- + = currency weakened
       CAST(STDEV(daily_change_pct) * SQRT(252) AS DECIMAL(6,2))           AS annualised_volatility_pct
FROM rates
GROUP BY currency_code, [year]
ORDER BY [year], annualised_volatility_pct DESC;
GO

/* -----------------------------------------------------------------------------
   Q16. Net foreign-currency flow (inbound - outbound) by region and year
        Flujo neto de divisas (entradas - salidas) por región y año
   Technique: conditional aggregation (pivot without PIVOT)
   ----------------------------------------------------------------------------- */
SELECT c.region,
       CAST(SUM(CASE WHEN YEAR(p.created_at) = 2024 AND p.direction = N'Inbound'  THEN p.amount_usd ELSE 0 END) / 1e6 AS DECIMAL(10,1)) AS inbound_2024_m,
       CAST(SUM(CASE WHEN YEAR(p.created_at) = 2024 AND p.direction = N'Outbound' THEN p.amount_usd ELSE 0 END) / 1e6 AS DECIMAL(10,1)) AS outbound_2024_m,
       CAST(SUM(CASE WHEN YEAR(p.created_at) = 2025 AND p.direction = N'Inbound'  THEN p.amount_usd ELSE 0 END) / 1e6 AS DECIMAL(10,1)) AS inbound_2025_m,
       CAST(SUM(CASE WHEN YEAR(p.created_at) = 2025 AND p.direction = N'Outbound' THEN p.amount_usd ELSE 0 END) / 1e6 AS DECIMAL(10,1)) AS outbound_2025_m,
       CAST(SUM(CASE WHEN YEAR(p.created_at) = 2025
                     THEN CASE p.direction WHEN N'Inbound' THEN p.amount_usd ELSE -p.amount_usd END
                     ELSE 0 END) / 1e6 AS DECIMAL(10,1)) AS net_flow_2025_m
FROM core.payment AS p
JOIN core.country AS c ON c.country_code = p.counterparty_country
WHERE p.status = N'Completed'
GROUP BY c.region
ORDER BY net_flow_2025_m DESC;
GO

/* -----------------------------------------------------------------------------
   Q17. Reconciliation quality by correspondent account
        Calidad de la conciliación por cuenta corresponsal
   Technique: reads the reconciliation results (05) through the rpt view
   ----------------------------------------------------------------------------- */
SELECT b.bank_name, r.currency_code,
       COUNT(*) AS items,
       CAST(100.0 * SUM(CASE WHEN r.recon_status = N'Reconciled' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS reconciled_pct,
       SUM(CASE WHEN r.recon_status = N'Exception' THEN 1 ELSE 0 END)                 AS exceptions,
       SUM(CASE WHEN r.recon_status = N'Exception' THEN r.item_value_usd ELSE 0 END)  AS exceptions_value_usd
FROM rpt.fact_reconciliation AS r
JOIN core.correspondent_bank AS b ON b.bank_id = r.bank_id
GROUP BY b.bank_name, r.currency_code
ORDER BY reconciled_pct, exceptions_value_usd DESC;
GO

/* -----------------------------------------------------------------------------
   Q18. Ageing of open reconciliation exceptions
        Antigüedad de las partidas conciliatorias abiertas
   Technique: PIVOT of counts by ageing bucket + row totals
   ----------------------------------------------------------------------------- */
SELECT recon_category,
       ISNULL([1. 0-7 days], 0)      AS [0-7 days],
       ISNULL([2. 8-30 days], 0)     AS [8-30 days],
       ISNULL([3. 31-90 days], 0)    AS [31-90 days],
       ISNULL([4. Over 90 days], 0)  AS [Over 90 days],
       ISNULL([1. 0-7 days], 0) + ISNULL([2. 8-30 days], 0)
     + ISNULL([3. 31-90 days], 0) + ISNULL([4. Over 90 days], 0) AS total
FROM (
    SELECT recon_category, aging_bucket, result_id
    FROM rpt.fact_reconciliation
    WHERE recon_status = N'Exception'
) AS src
PIVOT (COUNT(result_id) FOR aging_bucket IN ([1. 0-7 days], [2. 8-30 days], [3. 31-90 days], [4. Over 90 days])) AS pv
ORDER BY total DESC;
GO
