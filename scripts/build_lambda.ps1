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
    Git tag of eskom-grid-observability to deploy. Defaults to the app_version
    default in infra/variables.tf, which is the single source of truth. The tag
    built is recorded in build/app_version.txt, and a precondition in
    infra/compute.tf fails the plan if it differs from var.app_version.

.EXAMPLE
    ./scripts/build_lambda.ps1
    ./scripts/build_lambda.ps1 -AppVersion v0.3.0   # only after updating variables.tf
#>

param(
    [string]$AppVersion,
    [string]$PythonVersion = "3.13",
    [string]$Platform = "manylinux2014_aarch64"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
# Forward slashes throughout: Windows accepts them, and on Linux (the CI
# runners) a backslash is an ordinary character in a file name.
$BuildDir = Join-Path $RepoRoot "build/lambda"
$VersionFile = Join-Path $RepoRoot "build/app_version.txt"
$FunctionDir = Join-Path $RepoRoot "functions/extract"
$AppRepo = "https://github.com/Furnx/eskom-grid-observability"

if (-not $AppVersion) {
    $variables = Get-Content (Join-Path $RepoRoot "infra/variables.tf") -Raw
    $match = [regex]::Match($variables, '(?s)variable\s+"app_version"\s*\{.*?default\s*=\s*"([^"]+)"')
    if (-not $match.Success) { throw "Could not read the app_version default from infra/variables.tf." }
    $AppVersion = $match.Groups[1].Value
}

Write-Host "Building extract Lambda package" -ForegroundColor Cyan
Write-Host "  app version : $AppVersion"
Write-Host "  target      : $Platform / python $PythonVersion"
Write-Host "  output      : $BuildDir"
Write-Host ""

# Start clean so a removed dependency cannot survive in the zip, and so a
# failed build leaves no version record behind to vouch for it.
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
if (Test-Path $VersionFile) { Remove-Item -Force $VersionFile }
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

# The same code must always give the same bytes: otherwise every build looks
# like a code change to Terraform, and every CI run would redeploy the function.
# So pip compiles no .pyc files (they record when they were compiled, and
# Lambda can't write its own cache into the read-only package anyway), and the
# command-line launchers it adds under bin/ are removed afterwards (on Windows
# they are .exe files; on Linux they name the building machine's Python), along
# with pip's RECORD lists, which name those launchers with their hashes. None
# of these is ever read by the handler; the version check reads METADATA.
Write-Host "[1/3] Installing eskom-grid@$AppVersion (no dependencies)..." -ForegroundColor Yellow
pip install "git+$AppRepo@$AppVersion" --target $BuildDir --no-deps --no-compile --quiet
if ($LASTEXITCODE -ne 0) { throw "pip install of the application package failed." }

Write-Host "[2/3] Installing Linux/arm64 dependency wheels..." -ForegroundColor Yellow
pip install `
    --requirement (Join-Path $FunctionDir "requirements.txt") `
    --target $BuildDir `
    --platform $Platform `
    --python-version $PythonVersion `
    --implementation cp `
    --only-binary=:all: `
    --no-compile `
    --quiet
if ($LASTEXITCODE -ne 0) { throw "pip install of dependencies failed." }

$launchers = Join-Path $BuildDir "bin"
if (Test-Path $launchers) { Remove-Item -Recurse -Force $launchers }
Get-ChildItem $BuildDir -Directory -Filter "*.dist-info" |
    ForEach-Object { Join-Path $_.FullName "RECORD" } |
    Where-Object { Test-Path $_ } |
    Remove-Item -Force

Write-Host "[3/3] Adding handler.py..." -ForegroundColor Yellow
Copy-Item (Join-Path $FunctionDir "handler.py") -Destination $BuildDir

# Smoke test: the things the handler imports must actually be in the package.
$required = @("handler.py", "eskom_grid/extract.py", "eskom_grid/sinks.py",
              "eskom_grid/config.py", "eskom_grid/areas_config.yml",
              "requests", "yaml")
$missing = $required | Where-Object { -not (Test-Path (Join-Path $BuildDir $_)) }
if ($missing) { throw "Build is missing: $($missing -join ', ')" }

# Dagster must never reach the Lambda package (see the import-boundary test in
# the application repository).
if (Test-Path (Join-Path $BuildDir "dagster")) {
    throw "Dagster found in the Lambda package  -  the dependency boundary has been broken."
}

# The handler logs the version in the package's metadata (the .dist-info
# folder), which pip takes from the application's pyproject.toml, not from the
# git tag. The two have disagreed before, so a mismatch stops the build rather
# than put the wrong version in every log line.
$expectedMetadata = "eskom_grid-$($AppVersion.TrimStart('v')).dist-info"
if (-not (Test-Path (Join-Path $BuildDir $expectedMetadata))) {
    $found = (Get-ChildItem $BuildDir -Directory -Filter "eskom_grid-*.dist-info").Name -join ", "
    throw "Package metadata is $found, not ${expectedMetadata}: pyproject.toml at $AppVersion does not match its tag."
}

# Record what was built, next to (not inside) the package so the zip is
# unaffected. infra/compute.tf compares it with var.app_version at plan time.
Set-Content -Path $VersionFile -Value $AppVersion -NoNewline

$sizeMb = [math]::Round((Get-ChildItem $BuildDir -Recurse -File |
    Measure-Object -Property Length -Sum).Sum / 1MB, 2)

Write-Host ""
Write-Host "Build complete: $sizeMb MB unzipped." -ForegroundColor Green
Write-Host "Next: cd infra; terraform plan"
