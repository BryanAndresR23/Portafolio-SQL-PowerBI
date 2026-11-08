/* =============================================================================
   International Payments Analytics
   05 - Nostro reconciliation engine
   -----------------------------------------------------------------------------
   Business problem
     Every payment the bank settles must appear on the statement that the
     correspondent bank sends for the nostro account (bank + currency).
     Operations teams usually tick these off by hand in Excel. This procedure
     does it automatically and classifies everything that does not match.

   How it works
     1. Ledger side    : what our books expect to see (settled payments and
                         the return of funds for returned payments).
     2. Statement side : the correspondent's lines, with the free-text
                         reference normalised ('ref pay2401...', '/RFB/PAY...').
     3. Pass 1         : match on normalised reference (one-to-one).
     4. Pass 2         : for what is left, match on account + exact amount +
                         value date within the tolerance (one-to-one).
     5. Classification : reconciled, amount difference, timing difference,
                         missing in statement, duplicate, not booked, etc.
   ============================================================================= */

USE InternationalPaymentsAnalytics;
GO

DROP TABLE IF EXISTS recon.match_result;
DROP TABLE IF EXISTS recon.run_log;
GO

CREATE TABLE recon.run_log (
    run_id              INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_recon_run PRIMARY KEY,
    run_at              DATETIME2(0)  NOT NULL CONSTRAINT df_recon_run_at DEFAULT SYSDATETIME(),
    date_tolerance_days INT           NOT NULL,
    amount_tolerance    DECIMAL(19,2) NOT NULL,
    ledger_items        INT           NULL,
    statement_lines     INT           NULL,
    reconciled_items    INT           NULL,
    exception_items     INT           NULL,
    duration_ms         INT           NULL);

CREATE TABLE recon.match_result (
    result_id         INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_recon_result PRIMARY KEY,
    run_id            INT           NOT NULL
        CONSTRAINT fk_recon_result_run REFERENCES recon.run_log (run_id),
    bank_id           INT           NOT NULL,
    currency_code     CHAR(3)       NOT NULL,
    item_type         NVARCHAR(20)  NOT NULL,   -- Payment | Return | Statement only
    payment_id        INT           NULL,
    statement_line_id INT           NULL,
    ledger_date       DATE          NULL,
    statement_date    DATE          NULL,
    ledger_amount     DECIMAL(19,2) NULL,
    statement_amount  DECIMAL(19,2) NULL,
    amount_difference AS (ISNULL(statement_amount, 0) - ISNULL(ledger_amount, 0)),
    days_difference   AS (DATEDIFF(DAY, ledger_date, statement_date)),
    match_rule        NVARCHAR(30)  NULL,       -- Reference | Amount + date window
    recon_status      NVARCHAR(12)  NOT NULL,   -- Reconciled | Exception
    recon_category    NVARCHAR(40)  NOT NULL);

CREATE INDEX ix_recon_result_run ON recon.match_result (run_id, recon_status, recon_category);
GO

CREATE OR ALTER PROCEDURE recon.usp_reconcile
    @date_tolerance_days INT           = 2,
    @amount_tolerance    DECIMAL(19,2) = 0.00
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started DATETIME2 = SYSDATETIME(), @run_id INT;

    /* 1. Ledger side ---------------------------------------------------------- */
    DROP TABLE IF EXISTS #ledger;

    SELECT
        ROW_NUMBER() OVER (ORDER BY p.payment_id, x.is_return) AS ledger_item_id,
        p.payment_id,
        x.item_type,
        x.is_return,
        p.correspondent_bank_id               AS bank_id,
        p.currency_code,
        CAST(p.reference AS NVARCHAR(14))     AS ref_key,
        CAST(p.settled_at AS DATE)            AS ledger_date,
        x.sign * p.amount                     AS ledger_amount
    INTO #ledger
    FROM core.payment AS p
    CROSS APPLY (VALUES
        (N'Payment', 0, CASE p.direction WHEN N'Inbound' THEN 1 ELSE -1 END),
        (N'Return',  1, CASE p.direction WHEN N'Inbound' THEN -1 ELSE 1 END)
    ) AS x (item_type, is_return, sign)
    WHERE p.status IN (N'Completed', N'Returned')
      AND (x.is_return = 0 OR p.status = N'Returned');

    /* 2. Statement side: normalise the free-text reference -------------------- */
    DROP TABLE IF EXISTS #stmt;

    SELECT
        s.statement_line_id, s.bank_id, s.currency_code, s.value_date, s.amount, s.description,
        CASE WHEN n.clean_ref LIKE N'RTN%' THEN 1 ELSE 0 END AS is_return,
        CASE WHEN CHARINDEX(N'PAY', n.clean_ref) > 0
             THEN SUBSTRING(n.clean_ref, CHARINDEX(N'PAY', n.clean_ref), 14) END AS ref_key
    INTO #stmt
    FROM core.bank_statement_line AS s
    CROSS APPLY (SELECT UPPER(REPLACE(REPLACE(REPLACE(ISNULL(s.reference_text, N''),
                        N' ', N''), N'/', N''), N'-', N'')) AS clean_ref) AS n;

    CREATE INDEX ix_stmt_ref ON #stmt (bank_id, currency_code, ref_key, is_return);

    DROP TABLE IF EXISTS #match;
    CREATE TABLE #match (ledger_item_id INT PRIMARY KEY, statement_line_id INT UNIQUE, match_rule NVARCHAR(30));

    /* 3. Pass 1: reference match (first line wins, extra lines are duplicates) - */
    WITH ranked AS (
        SELECT st.*,
               ROW_NUMBER() OVER (PARTITION BY st.bank_id, st.currency_code, st.ref_key, st.is_return
                                  ORDER BY st.value_date, st.statement_line_id) AS rn
        FROM #stmt AS st
        WHERE st.ref_key IS NOT NULL AND LEN(st.ref_key) = 14
    )
    INSERT #match (ledger_item_id, statement_line_id, match_rule)
    SELECT l.ledger_item_id, r.statement_line_id, N'Reference'
    FROM #ledger AS l
    JOIN ranked  AS r
      ON r.bank_id = l.bank_id
     AND r.currency_code = l.currency_code
     AND r.ref_key = l.ref_key
     AND r.is_return = l.is_return
     AND r.rn = 1;

    /* 4. Pass 2: account + exact amount + date window, closest date first ----- */
    WITH candidates AS (
        SELECT l.ledger_item_id, s.statement_line_id,
               ROW_NUMBER() OVER (PARTITION BY l.ledger_item_id
                                  ORDER BY ABS(DATEDIFF(DAY, l.ledger_date, s.value_date)), s.statement_line_id) AS rn_ledger,
               ROW_NUMBER() OVER (PARTITION BY s.statement_line_id
                                  ORDER BY ABS(DATEDIFF(DAY, l.ledger_date, s.value_date)), l.ledger_item_id) AS rn_stmt
        FROM #ledger AS l
        JOIN #stmt   AS s
          ON s.bank_id = l.bank_id
         AND s.currency_code = l.currency_code
         AND s.amount = l.ledger_amount
         AND s.value_date BETWEEN DATEADD(DAY, -@date_tolerance_days, l.ledger_date)
                              AND DATEADD(DAY,  @date_tolerance_days, l.ledger_date)
        WHERE l.is_return = 0
          AND (s.ref_key IS NULL OR LEN(s.ref_key) < 14)      -- only lines with a broken reference
          AND NOT EXISTS (SELECT 1 FROM #match AS m WHERE m.ledger_item_id = l.ledger_item_id)
          AND NOT EXISTS (SELECT 1 FROM #match AS m WHERE m.statement_line_id = s.statement_line_id)
    )
    INSERT #match (ledger_item_id, statement_line_id, match_rule)
    SELECT ledger_item_id, statement_line_id, N'Amount + date window'
    FROM candidates
    WHERE rn_ledger = 1 AND rn_stmt = 1;

    /* 5. Classify and store ---------------------------------------------------- */
    BEGIN TRANSACTION;

    INSERT recon.run_log (date_tolerance_days, amount_tolerance)
    VALUES (@date_tolerance_days, @amount_tolerance);
    SET @run_id = SCOPE_IDENTITY();

    -- 5a. Matched pairs
    INSERT recon.match_result (run_id, bank_id, currency_code, item_type, payment_id, statement_line_id,
                               ledger_date, statement_date, ledger_amount, statement_amount,
                               match_rule, recon_status, recon_category)
    SELECT @run_id, l.bank_id, l.currency_code, l.item_type, l.payment_id, s.statement_line_id,
           l.ledger_date, s.value_date, l.ledger_amount, s.amount, m.match_rule,
           c.recon_status, c.recon_category
    FROM #match  AS m
    JOIN #ledger AS l ON l.ledger_item_id = m.ledger_item_id
    JOIN #stmt   AS s ON s.statement_line_id = m.statement_line_id
    CROSS APPLY (
        SELECT
            CASE WHEN l.is_return = 0
                  AND (ABS(s.amount - l.ledger_amount) > @amount_tolerance
                       OR ABS(DATEDIFF(DAY, l.ledger_date, s.value_date)) > @date_tolerance_days)
                 THEN N'Exception' ELSE N'Reconciled' END AS recon_status,
            CASE WHEN l.is_return = 1                                                     THEN N'Return of funds matched'
                 WHEN ABS(s.amount - l.ledger_amount) > @amount_tolerance                 THEN N'Amount difference'
                 WHEN ABS(DATEDIFF(DAY, l.ledger_date, s.value_date)) > @date_tolerance_days THEN N'Timing difference'
                 WHEN m.match_rule = N'Reference'                                         THEN N'Matched by reference'
                 ELSE N'Matched by amount and date' END AS recon_category
    ) AS c;

    -- 5b. In our books but not on the statement
    INSERT recon.match_result (run_id, bank_id, currency_code, item_type, payment_id,
                               ledger_date, ledger_amount, recon_status, recon_category)
    SELECT @run_id, l.bank_id, l.currency_code, l.item_type, l.payment_id,
           l.ledger_date, l.ledger_amount, N'Exception',
           CASE WHEN l.is_return = 1 THEN N'Return of funds not received'
                ELSE N'Missing in statement' END
    FROM #ledger AS l
    WHERE NOT EXISTS (SELECT 1 FROM #match AS m WHERE m.ledger_item_id = l.ledger_item_id);

    -- 5c. On the statement but not in our books
    INSERT recon.match_result (run_id, bank_id, currency_code, item_type, statement_line_id,
                               statement_date, statement_amount, recon_status, recon_category)
    SELECT @run_id, s.bank_id, s.currency_code, N'Statement only', s.statement_line_id,
           s.value_date, s.amount, N'Exception',
           CASE
               WHEN s.description LIKE N'%MAINTENANCE FEE%' THEN N'Bank charge not booked'
               WHEN s.description LIKE N'INTEREST%'         THEN N'Interest not booked'
               WHEN s.ref_key IS NULL                       THEN N'Unidentified item'
               WHEN EXISTS (SELECT 1
                            FROM #stmt  AS s2
                            JOIN #match AS m2 ON m2.statement_line_id = s2.statement_line_id
                            WHERE s2.bank_id = s.bank_id AND s2.currency_code = s.currency_code
                              AND s2.ref_key = s.ref_key AND s2.is_return = s.is_return)
                                                            THEN N'Duplicate in statement'
               ELSE N'Unknown reference'
           END
    FROM #stmt AS s
    WHERE NOT EXISTS (SELECT 1 FROM #match AS m WHERE m.statement_line_id = s.statement_line_id);

    UPDATE recon.run_log
    SET ledger_items     = (SELECT COUNT(*) FROM #ledger),
        statement_lines  = (SELECT COUNT(*) FROM #stmt),
        reconciled_items = (SELECT COUNT(*) FROM recon.match_result WHERE run_id = @run_id AND recon_status = N'Reconciled'),
        exception_items  = (SELECT COUNT(*) FROM recon.match_result WHERE run_id = @run_id AND recon_status = N'Exception'),
        duration_ms      = DATEDIFF(MILLISECOND, @started, SYSDATETIME())
    WHERE run_id = @run_id;

    COMMIT TRANSACTION;

    SELECT * FROM recon.run_log WHERE run_id = @run_id;
END
GO

/* Run it --------------------------------------------------------------------- */
EXEC recon.usp_reconcile @date_tolerance_days = 2, @amount_tolerance = 0.00;
GO

/* Result of the latest run by category --------------------------------------- */
WITH latest AS (
    SELECT r.*
    FROM recon.match_result AS r
    WHERE r.run_id = (SELECT MAX(run_id) FROM recon.run_log)
)
SELECT recon_status,
       recon_category,
       COUNT(*) AS items,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_items
FROM latest
GROUP BY recon_status, recon_category
ORDER BY recon_status DESC, items DESC;
GO
