<#
.SYNOPSIS
    Builds the extract Lambda deployment directory.

.DESCRIPTION
    Produces build/lambda/, which infra/compute.tf zips via archive_file.
    Run this BEFORE terraform plan or apply: archive_file is a data source and
    is read at plan time, so the directory must already exist.

    Two installation steps, for one reason: the application package is
    installed from a git tag, which pip must build from source, and pip refuses
    to combine that with --platform. So the package goes in with --no-deps, and
    its dependencies are fetched separately as Linux/arm64 wheels.

    Why --platform matters: this script runs on Windows, but the code runs on
    Linux/arm64. Without it, pip would install Windows wheels and the function
    would fail at import time in the cloud.

.PARAMETER AppVersion
    Git tag of eskom-grid-observability to deploy. Must match app_version in
    infra/variables.tf.

.EXAMPLE
    ./scripts/build_lambda.ps1
    ./scripts/build_lambda.ps1 -AppVersion v0.2.0
#>

param(
    [string]$AppVersion = "v0.1.0",
    [string]$PythonVersion = "3.13",
    [string]$Platform = "manylinux2014_aarch64"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $RepoRoot "build\lambda"
$FunctionDir = Join-Path $RepoRoot "functions\extract"
$AppRepo = "https://github.com/Furnx/eskom-grid-observability"

Write-Host "Building extract Lambda package" -ForegroundColor Cyan
Write-Host "  app version : $AppVersion"
Write-Host "  target      : $Platform / python $PythonVersion"
Write-Host "  output      : $BuildDir"
Write-Host ""

# Start clean so a removed dependency cannot survive in the zip.
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

Write-Host "[1/3] Installing eskom-grid@$AppVersion (no dependencies)..." -ForegroundColor Yellow
pip install "git+$AppRepo@$AppVersion" --target $BuildDir --no-deps --quiet
if ($LASTEXITCODE -ne 0) { throw "pip install of the application package failed." }

Write-Host "[2/3] Installing Linux/arm64 dependency wheels..." -ForegroundColor Yellow
pip install `
    --requirement (Join-Path $FunctionDir "requirements.txt") `
    --target $BuildDir `
    --platform $Platform `
    --python-version $PythonVersion `
    --implementation cp `
    --only-binary=:all: `
    --quiet
if ($LASTEXITCODE -ne 0) { throw "pip install of dependencies failed." }

Write-Host "[3/3] Adding handler.py..." -ForegroundColor Yellow
Copy-Item (Join-Path $FunctionDir "handler.py") -Destination $BuildDir

# Smoke test: the things the handler imports must actually be in the package.
$required = @("handler.py", "eskom_grid\extract.py", "eskom_grid\sinks.py",
              "eskom_grid\config.py", "eskom_grid\areas_config.yml",
              "requests", "yaml")
$missing = $required | Where-Object { -not (Test-Path (Join-Path $BuildDir $_)) }
if ($missing) { throw "Build is missing: $($missing -join ', ')" }

# Dagster must never reach the Lambda package (see the import-boundary test in
# the application repository).
if (Test-Path (Join-Path $BuildDir "dagster")) {
    throw "Dagster found in the Lambda package  -  the dependency boundary has been broken."
}

$sizeMb = [math]::Round((Get-ChildItem $BuildDir -Recurse -File |
    Measure-Object -Property Length -Sum).Sum / 1MB, 2)

Write-Host ""
Write-Host "Build complete: $sizeMb MB unzipped." -ForegroundColor Green
Write-Host "Next: cd infra; terraform plan"
