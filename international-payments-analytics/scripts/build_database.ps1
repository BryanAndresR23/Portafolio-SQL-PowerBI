<#
.SYNOPSIS
    Builds the InternationalPaymentsAnalytics database end to end.

.DESCRIPTION
    Runs the numbered scripts in the sql folder in order (splitting them on GO),
    fills in the CSV folder for the BULK INSERT step and prints every result set.
    Uses Windows authentication.

.EXAMPLE
    .\scripts\build_database.ps1
.EXAMPLE
    .\scripts\build_database.ps1 -Server "localhost\SQLEXPRESS" -GenerateData -RunAnalysis
#>
param(
    [string]$Server = "localhost",
    [switch]$GenerateData,     # regenerate the CSV files first (needs Python 3)
    [switch]$RunAnalysis       # also run 07_analysis_queries.sql
)

$ErrorActionPreference = 'Stop'
$root     = Split-Path $PSScriptRoot -Parent
$dataPath = (Join-Path $root 'data\raw') + '\'

if ($GenerateData) {
    python (Join-Path $PSScriptRoot 'generate_data.py')
    if ($LASTEXITCODE -ne 0) { throw "Data generation failed." }
}

$scripts = @(
    '00_create_database.sql',
    '01_create_tables.sql',
    '02_load_staging.sql',
    '03_transform_core.sql',
    '04_data_quality.sql',
    '05_reconciliation.sql',
    '06_reporting_views.sql'
)
if ($RunAnalysis) { $scripts += '07_analysis_queries.sql' }

$connection = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=master;Integrated Security=True;TrustServerCertificate=True"
$connection.add_InfoMessage({ param($sender, $e) Write-Host "   $($e.Message)" -ForegroundColor DarkGray })
$connection.Open()
$timer = [Diagnostics.Stopwatch]::StartNew()

try {
    foreach ($file in $scripts) {
        Write-Host "`n==> $file" -ForegroundColor Cyan
        $sql = [IO.File]::ReadAllText((Join-Path $root "sql\$file"), [Text.Encoding]::UTF8)
        if ($file -eq '02_load_staging.sql') {
            $sql = $sql -replace "(@data_path\s+NVARCHAR\(\d+\)\s*=\s*N')[^']*(')", "`${1}$dataPath`${2}"
        }
        foreach ($batch in [regex]::Split($sql, '(?im)^\s*GO\s*$')) {
            if (-not $batch.Trim()) { continue }
            $command = $connection.CreateCommand()
            $command.CommandText    = $batch
            $command.CommandTimeout = 600
            $results = New-Object System.Data.DataSet
            (New-Object System.Data.SqlClient.SqlDataAdapter $command).Fill($results) | Out-Null
            foreach ($table in $results.Tables) {
                $table | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
            }
        }
    }
    Write-Host ("`nDatabase built in {0:n1} s" -f $timer.Elapsed.TotalSeconds) -ForegroundColor Green
}
finally {
    $connection.Close()
}
