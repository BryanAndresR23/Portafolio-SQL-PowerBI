/* =============================================================================
   International Payments Analytics
   04 - Data quality checks
   -----------------------------------------------------------------------------
   Each check returns the number of offending rows.
     severity = 'Error' -> must be 0 (result FAIL otherwise)
     severity = 'Info'  -> expected and explained, reported for transparency
   ============================================================================= */

USE InternationalPaymentsAnalytics;
GO

WITH checks AS (
    SELECT 1 AS check_id, N'Error' AS severity,
           N'Staging rows not accounted for (stg - core - rejected)' AS check_name,
           (SELECT COUNT(*) FROM stg.payments)
         - (SELECT COUNT(*) FROM core.payment)
         - (SELECT COUNT(*) FROM core.etl_reject WHERE source_table = N'stg.payments') AS issues
    UNION ALL
    SELECT 2, N'Error', N'Duplicated payment references',
           (SELECT COUNT(*) FROM (SELECT reference FROM core.payment
                                  GROUP BY reference HAVING COUNT(*) > 1) AS d)
    UNION ALL
    SELECT 3, N'Error', N'Customer names with leading, trailing or double spaces',
           (SELECT COUNT(*) FROM core.customer
            WHERE customer_name LIKE N' %' OR customer_name LIKE N'% ' OR customer_name LIKE N'%  %')
    UNION ALL
    SELECT 4, N'Error', N'Settled payments without a settlement date',
           (SELECT COUNT(*) FROM core.payment
            WHERE status IN (N'Completed', N'Returned') AND settled_at IS NULL)
    UNION ALL
    SELECT 5, N'Error', N'Payments created before the customer was onboarded',
           (SELECT COUNT(*) FROM core.payment AS p
            JOIN core.customer AS c ON c.customer_id = p.customer_id
            WHERE CAST(p.created_at AS DATE) < c.onboarding_date)
    UNION ALL
    SELECT 6, N'Error', N'Rejected payments that charged a fee',
           (SELECT COUNT(*) FROM core.payment WHERE status = N'Rejected' AND fee_usd > 0)
    UNION ALL
    SELECT 7, N'Error', N'Calendar days without an exchange rate (per currency)',
           (SELECT COUNT(*) FROM core.calendar AS cal
            CROSS JOIN core.currency AS cur
            WHERE NOT EXISTS (SELECT 1 FROM core.exchange_rate AS r
                              WHERE r.rate_date = cal.[date] AND r.currency_code = cur.currency_code))
    UNION ALL
    SELECT 8, N'Error', N'USD amount does not match amount / rate (> 1 cent)',
           (SELECT COUNT(*) FROM core.payment
            WHERE ABS(amount / fx_rate_to_usd - amount_usd) > 0.01)
    UNION ALL
    SELECT 9, N'Error', N'Payment currency not held at the correspondent (no statement account)',
           (SELECT COUNT(*) FROM (SELECT DISTINCT correspondent_bank_id, currency_code FROM core.payment) AS p
            WHERE NOT EXISTS (SELECT 1 FROM core.bank_statement_line AS s
                              WHERE s.bank_id = p.correspondent_bank_id AND s.currency_code = p.currency_code))
    UNION ALL
    SELECT 10, N'Info', N'Rows rejected during the load (see detail below)',
           (SELECT COUNT(*) FROM core.etl_reject)
    UNION ALL
    SELECT 11, N'Info', N'Statement lines without any reference (to be investigated in reconciliation)',
           (SELECT COUNT(*) FROM core.bank_statement_line WHERE reference_text IS NULL)
    UNION ALL
    SELECT 12, N'Info', N'Payments still pending at period close',
           (SELECT COUNT(*) FROM core.payment WHERE status = N'Pending')
)
SELECT check_id,
       severity,
       check_name,
       issues,
       CASE WHEN severity = N'Info' THEN N'INFO'
            WHEN issues = 0         THEN N'PASS'
            ELSE N'FAIL' END AS result
FROM checks
ORDER BY check_id;

/* Detail of the rows left out of the core layer */
SELECT source_table, reason, COUNT(*) AS rows_rejected
FROM core.etl_reject
GROUP BY source_table, reason
ORDER BY source_table, rows_rejected DESC;
GO
