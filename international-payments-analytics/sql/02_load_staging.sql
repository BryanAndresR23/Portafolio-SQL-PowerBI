/* =============================================================================
   International Payments Analytics
   02 - Load the CSV files into the staging layer (BULK INSERT)
   -----------------------------------------------------------------------------
   >>> Edit @data_path so it points to the data\raw folder of this repository.
       Keep the final backslash. scripts\build_database.ps1 fills it in for you.
   ============================================================================= */

USE InternationalPaymentsAnalytics;
GO

SET NOCOUNT ON;

DECLARE @data_path NVARCHAR(400) = N'C:\Portafolio-SQL-PowerBI\international-payments-analytics\data\raw\';

DECLARE @files TABLE (load_order INT, table_name SYSNAME, file_name NVARCHAR(100));
INSERT @files (load_order, table_name, file_name)
VALUES (1, N'stg.currencies',           N'currencies.csv'),
       (2, N'stg.countries',            N'countries.csv'),
       (3, N'stg.correspondent_banks',  N'correspondent_banks.csv'),
       (4, N'stg.channels',             N'channels.csv'),
       (5, N'stg.exchange_rates',       N'exchange_rates.csv'),
       (6, N'stg.customers',            N'customers.csv'),
       (7, N'stg.payments',             N'payments.csv'),
       (8, N'stg.bank_statement_lines', N'bank_statement_lines.csv');

DECLARE @table SYSNAME, @file NVARCHAR(100), @sql NVARCHAR(MAX);

DECLARE file_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, file_name FROM @files ORDER BY load_order;

OPEN file_cursor;
FETCH NEXT FROM file_cursor INTO @table, @file;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- UTF-8 file, header row skipped, quoted fields handled by FORMAT = 'CSV'
    SET @sql = N'TRUNCATE TABLE ' + @table + N';
BULK INSERT ' + @table + N'
FROM ''' + REPLACE(@data_path + @file, N'''', N'''''') + N'''
WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'',
      FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', TABLOCK);';

    EXEC sys.sp_executesql @sql;
    PRINT CONCAT(N'Loaded ', @file, N' -> ', @table);

    FETCH NEXT FROM file_cursor INTO @table, @file;
END

CLOSE file_cursor;
DEALLOCATE file_cursor;

SELECT N'stg.currencies'           AS staging_table, COUNT(*) AS rows_loaded FROM stg.currencies
UNION ALL SELECT N'stg.countries',            COUNT(*) FROM stg.countries
UNION ALL SELECT N'stg.correspondent_banks',  COUNT(*) FROM stg.correspondent_banks
UNION ALL SELECT N'stg.channels',             COUNT(*) FROM stg.channels
UNION ALL SELECT N'stg.exchange_rates',       COUNT(*) FROM stg.exchange_rates
UNION ALL SELECT N'stg.customers',            COUNT(*) FROM stg.customers
UNION ALL SELECT N'stg.payments',             COUNT(*) FROM stg.payments
UNION ALL SELECT N'stg.bank_statement_lines', COUNT(*) FROM stg.bank_statement_lines;
GO
