/* =============================================================================
   International Payments Analytics
   00 - Database and schemas
   -----------------------------------------------------------------------------
   Target : SQL Server 2019 or later (built and tested on SQL Server 2025 Express)
   Layers :
     stg   -> raw CSV landing zone (everything as text, no constraints)
     core  -> clean, typed and constrained model (the single source of truth)
     recon -> nostro reconciliation engine (ledger vs correspondent statements)
     rpt   -> star-schema views consumed by Power BI
   ============================================================================= */

IF DB_ID(N'InternationalPaymentsAnalytics') IS NULL
    CREATE DATABASE InternationalPaymentsAnalytics;
GO

USE InternationalPaymentsAnalytics;
GO

IF SCHEMA_ID(N'stg')   IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'core')  IS NULL EXEC (N'CREATE SCHEMA core');
IF SCHEMA_ID(N'recon') IS NULL EXEC (N'CREATE SCHEMA recon');
IF SCHEMA_ID(N'rpt')   IS NULL EXEC (N'CREATE SCHEMA rpt');
GO
