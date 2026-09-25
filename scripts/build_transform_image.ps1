<#
.SYNOPSIS
    Builds the transform Lambda's container image locally.

.DESCRIPTION
    Builds functions/transform/Dockerfile for linux/arm64 and loads the result
    into the local Docker image store. It does not push: publishing to ECR is a
    separate step.

    Needs Docker Desktop running. The build runs under arm64 emulation on an
    x86 laptop, so the first build takes a few minutes; later builds reuse
    Docker's layer cache.

    --provenance=false: by default buildx attaches a provenance attestation,
    which turns the result into a multi-entry image index. Lambda accepts only
    a single image, so the attestation is switched off.

    The tag is <app_version>-<short commit of this repository>, with -dirty
    appended when functions/transform has uncommitted changes. It records
    which recipe the image was built from; the image digest, not the tag, is
    what identifies the exact bytes.

.PARAMETER AppVersion
    Git tag of eskom-grid-observability to build from. Defaults to the
    app_version default in infra/variables.tf, the single source of truth.

.EXAMPLE
    ./scripts/build_transform_image.ps1
#>

param(
    [string]$AppVersion
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FunctionDir = Join-Path $RepoRoot "functions\transform"
$AppRepo = "https://github.com/Furnx/eskom-grid-observability.git"
$ImageName = "eskom-grid-transform"
$Platform = "linux/arm64"

if (-not $AppVersion) {
    $variables = Get-Content (Join-Path $RepoRoot "infra\variables.tf") -Raw
    $match = [regex]::Match($variables, '(?s)variable\s+"app_version"\s*\{.*?default\s*=\s*"([^"]+)"')
    if (-not $match.Success) { throw "Could not read the app_version default from infra/variables.tf." }
    $AppVersion = $match.Groups[1].Value
}

# The Dockerfile clones whatever ref it is given, branch or tag. Only a release
# tag may be built, so check that one exists by that exact name.
$tagRef = git ls-remote --tags $AppRepo "refs/tags/$AppVersion"
if ($LASTEXITCODE -ne 0) { throw "Could not reach $AppRepo." }
if (-not $tagRef) { throw "$AppVersion is not a tag in $AppRepo." }

$commit = git -C $RepoRoot rev-parse --short HEAD
if ($LASTEXITCODE -ne 0) { throw "Could not read this repository's commit." }
$dirty = git -C $RepoRoot status --porcelain -- functions/transform
$tag = "$AppVersion-$commit" + $(if ($dirty) { "-dirty" } else { "" })
$image = "${ImageName}:$tag"

Write-Host "Building transform image" -ForegroundColor Cyan
Write-Host "  app version : $AppVersion"
Write-Host "  platform    : $Platform"
Write-Host "  image       : $image"
Write-Host ""

docker buildx build `
    --platform $Platform `
    --provenance=false `
    --build-arg "APP_VERSION=$AppVersion" `
    --tag $image `
    --load `
    $FunctionDir
if ($LASTEXITCODE -ne 0) { throw "docker build failed." }

# Smoke test inside the image, with no network: what the handler imports is
# present, Dagster is not, the runtime's boto3 supports the conditional write,
# and both DuckDB extensions load from the image alone. The script goes in on
# stdin: Windows PowerShell mangles quotes inside arguments to native programs.
$check = @'
import importlib.util, os, boto3, duckdb
import eskom_grid.transform, dbt.cli.main, handler
assert importlib.util.find_spec('dagster') is None, 'Dagster found in the image'
s3 = boto3.client('s3', region_name='af-south-1')
params = s3.meta.service_model.operation_model('PutObject').input_shape.members
assert {'IfMatch', 'IfNoneMatch'} <= set(params), 'boto3 lacks conditional writes'
con = duckdb.connect(config={'extension_directory': os.environ['DUCKDB_EXTENSION_DIRECTORY'],
                             'autoinstall_known_extensions': False})
con.execute('LOAD httpfs; LOAD aws')
print(f'boto3 {boto3.__version__}, duckdb {duckdb.__version__}: OK')
'@
$check | docker run --rm -i --network none --entrypoint python $image -
if ($LASTEXITCODE -ne 0) { throw "Smoke test failed for $image." }

$sizeMb = [math]::Round((docker image inspect $image --format "{{.Size}}") / 1MB)

Write-Host ""
Write-Host "Build complete: $image ($sizeMb MB)." -ForegroundColor Green
