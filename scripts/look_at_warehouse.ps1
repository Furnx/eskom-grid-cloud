<#
.SYNOPSIS
    Downloads a fresh copy of the warehouse and opens it read-only in DuckDB.

.DESCRIPTION
    The warehouse is one DuckDB file in S3 (warehouse/eskom_data.duckdb),
    replaced every hour by the transform function. This script copies the
    current version to a local folder and opens it in the DuckDB command-line
    tool, read-only, so nothing you type can change the copy.

    The copy is a snapshot: run the script again to see newer runs. It never
    uploads anything. The transform function owns the object in S3 and
    replaces it with a conditional write keyed on what it downloaded
    (ADR 0007); a copy uploaded by hand would not be part of that chain.

    Needs the DuckDB command-line tool (winget install DuckDB.cli, then a new
    terminal) and the AWS CLI with the eskom-admin profile. Read-only in AWS:
    it only identifies the account and downloads one object.

.PARAMETER Query
    Run one SQL statement, print the result and exit, instead of opening an
    interactive session. Write string values in single quotes: Windows
    PowerShell mangles double quotes inside arguments to other programs.

.PARAMETER Folder
    Where to keep the copy. Defaults to a folder in your home directory,
    outside the repository.

.EXAMPLE
    ./scripts/look_at_warehouse.ps1
    ./scripts/look_at_warehouse.ps1 -Query "SELECT count(*) AS runs FROM fct_pipeline_runs"
#>

param(
    [string]$Query,
    [string]$Folder = (Join-Path $HOME "eskom-grid-look"),
    [string]$AwsProfile = "eskom-admin",
    [string]$Region = "af-south-1"
)

$ErrorActionPreference = "Stop"

$Key = "warehouse/eskom_data.duckdb"
$File = Join-Path $Folder "eskom_data.duckdb"

if (-not (Get-Command duckdb -ErrorAction SilentlyContinue)) {
    throw "The DuckDB command-line tool was not found. Install it with 'winget install DuckDB.cli', then open a new terminal."
}

# The bucket is named after the account, exactly as infra/storage.tf names it,
# so nothing here has to be updated if the stack is rebuilt in another account.
$account = aws sts get-caller-identity --profile $AwsProfile --query Account --output text
if ($LASTEXITCODE -ne 0) { throw "Could not identify the AWS account with profile '$AwsProfile'." }
$Bucket = "eskom-grid-$account"

# When the transform last replaced the warehouse: a snapshot you can't date is
# easy to mistake for the current state.
$lastModified = aws s3api head-object --bucket $Bucket --key $Key --profile $AwsProfile --region $Region `
    --query LastModified --output text
if ($LASTEXITCODE -ne 0) { throw "s3://$Bucket/$Key could not be read. Has the transform run yet?" }
$replacedAt = ([datetimeoffset]::Parse($lastModified)).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")

New-Item -ItemType Directory -Force -Path $Folder | Out-Null
aws s3 cp "s3://$Bucket/$Key" $File --profile $AwsProfile --region $Region --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Download failed. If the previous copy is still open in another DuckDB window, quit it (.quit) and try again: Windows locks open files."
}

Write-Host "Warehouse as replaced at $replacedAt (local time), copied to $File" -ForegroundColor Cyan

if ($Query) {
    duckdb -readonly -c $Query $File
    if ($LASTEXITCODE -ne 0) { throw "The query failed; DuckDB's message is above." }
    return
}

Write-Host "Opening read-only. Type SQL ending in ';', .tables to list tables, .quit to leave."
duckdb -readonly $File
