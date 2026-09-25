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

# Smoke tests run under the restrictions Lambda imposes: no network, a
# read-only filesystem except /tmp, and a user that is neither root nor the
# owner of the files (the uid itself is arbitrary).
$lambdaLike = @("--platform", $Platform, "--network", "none",
                "--read-only", "--tmpfs", "/tmp", "--user", "993:990")

# 1. What the handler imports is present, Dagster is not, and the runtime's
#    boto3 supports the conditional write. The script goes in on stdin: Windows
#    PowerShell mangles quotes inside arguments to native programs.
$check = @'
import importlib.util, boto3
import eskom_grid.transform, dbt.cli.main, handler
assert importlib.util.find_spec('dagster') is None, 'Dagster found in the image'
s3 = boto3.client('s3', region_name='af-south-1')
params = s3.meta.service_model.operation_model('PutObject').input_shape.members
assert {'IfMatch', 'IfNoneMatch'} <= set(params), 'boto3 lacks conditional writes'
print(f'imports and boto3 {boto3.__version__}: OK')
'@
$check | docker run --rm -i @lambdaLike --entrypoint python $image -
if ($LASTEXITCODE -ne 0) { throw "Smoke test failed for $image (imports)." }

# 2. dbt compiles the project through the image's own prod profile: the
#    profile parses, DuckDB opens a database in /tmp and loads both extensions
#    from the image, and dbt writes nothing outside /tmp. Loading the extensions
#    directly would not do: a profile that points DuckDB elsewhere passed that.
#    The credentials are placeholders; DuckDB's S3 secret refuses to be
#    created without some, and with no network nothing can use them.
docker run --rm @lambdaLike `
    -e "ESKOM_DUCKDB_PATH=/tmp/smoke/eskom_data.duckdb" `
    -e "ESKOM_RAW_GLOB=s3://smoke-test/raw/**/*.json" `
    -e "AWS_REGION=af-south-1" `
    -e "AWS_ACCESS_KEY_ID=smoke-test-placeholder" `
    -e "AWS_SECRET_ACCESS_KEY=smoke-test-placeholder" `
    --entrypoint dbt $image compile --quiet `
    --project-dir /var/task/dbt_project --profiles-dir /var/task/dbt_project `
    --target prod --target-path /tmp/smoke/target --log-path /tmp/smoke/logs
if ($LASTEXITCODE -ne 0) { throw "Smoke test failed for $image (dbt compile, prod profile)." }
Write-Host "dbt compile through the prod profile, offline and read-only: OK"

$sizeMb = [math]::Round((docker image inspect $image --format "{{.Size}}") / 1MB)

Write-Host ""
Write-Host "Build complete: $image ($sizeMb MB compressed)." -ForegroundColor Green
