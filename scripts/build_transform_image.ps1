<#
.SYNOPSIS
    Builds the transform Lambda's container image, and with -Push publishes it
    to ECR for Terraform to deploy.

.DESCRIPTION
    Builds functions/transform/Dockerfile for linux/arm64, loads the result
    into the local Docker image store and smoke-tests it. With -Push it also
    uploads the image to the ECR repository (infra/registry.tf) and records
    the pushed tag in build/transform_image_tag.txt, which infra/compute.tf
    reads to decide what to deploy.

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

.PARAMETER Push
    After a successful build and smoke test, push the image to ECR. Refused
    for a -dirty build: ECR tags are immutable, so it would stay there forever
    under a name that does not identify its contents.

.EXAMPLE
    ./scripts/build_transform_image.ps1          # build and test only
    ./scripts/build_transform_image.ps1 -Push    # then publish; next: terraform plan
#>

param(
    [string]$AppVersion,
    [switch]$Push,
    [string]$AwsProfile = "eskom-admin",
    [string]$Region = "af-south-1"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FunctionDir = Join-Path $RepoRoot "functions\transform"
$TagFile = Join-Path $RepoRoot "build\transform_image_tag.txt"
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

if ($Push) {
    # Checked before the build, not after it: no point spending minutes first.
    if ($dirty) { throw "functions/transform has uncommitted changes; commit them before pushing." }

    # From here until a push is confirmed, there is no record for Terraform to
    # deploy, so a failed run cannot leave an older tag looking current.
    if (Test-Path $TagFile) { Remove-Item -Force $TagFile }
}

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
# read-only filesystem except /tmp, a user that is neither root nor the owner
# of the files (the uid itself is arbitrary), and no /dev/shm. Docker provides
# /dev/shm by default and Lambda does not; without it, multiprocessing locks
# (which dbt creates) cannot be made. That difference first showed in the cloud.
$lambdaLike = @("--platform", $Platform, "--network", "none", "--ipc", "none",
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

# 2. A full dbt build on the path production takes: run_transform(), the
#    function the handler calls, with the image's own prod profile, on one raw
#    file written here. It covers the profile, loading both DuckDB extensions
#    from the image, the missing /dev/shm, and closing the database before
#    returning: a separate process must then find the row in the file on disk.
#    Calling the dbt command line instead would skip run_transform(), and with
#    it the code these checks are about; an earlier version of this test did,
#    and passed or failed for the wrong reasons.
#    The credentials are placeholders; DuckDB's S3 secret refuses to be
#    created without some, and with no network nothing can use them.
$build = @'
import json, os, pathlib, subprocess, sys
from eskom_grid.transform import run_transform
work = pathlib.Path('/tmp/smoke')
area = work / 'raw' / 'za_gt_jhb_johannesburg_9hfs'
area.mkdir(parents=True)
(area / '20260101_000000.json').write_text(json.dumps({'events': [], '_meta': {
    'area_id': 'za_gt_jhb_johannesburg_9hfs', 'area_name': 'Johannesburg',
    'municipality': 'City of Johannesburg', 'province': 'Gauteng'}}))
db = work / 'eskom_data.duckdb'
os.environ['ESKOM_RAW_GLOB'] = str(work / 'raw') + '/**/*.json'
os.environ['ESKOM_DUCKDB_PATH'] = str(db)
summary = run_transform('/var/task/dbt_project', target='prod',
                        target_path=work / 'target', log_path=work / 'logs')
assert not list(work.glob('*.wal')), 'the database was left open (.wal beside it)'
count = 'import duckdb, sys; print(duckdb.connect(sys.argv[1], read_only=True).sql(' \
        + repr('select count(*) from stg_eskom__raw_payloads') + ').fetchone()[0])'
rows = subprocess.run([sys.executable, '-c', count, str(db)],
                      capture_output=True, text=True, check=True).stdout.strip()
assert rows == '1', f'expected 1 landed row on disk, found {rows}'
print(f'run_transform: {summary.passed}/{summary.total_nodes} nodes, file complete on disk: OK')
'@
$build | docker run --rm -i @lambdaLike `
    -e "DBT_QUIET=true" `
    -e "AWS_REGION=af-south-1" `
    -e "AWS_ACCESS_KEY_ID=smoke-test-placeholder" `
    -e "AWS_SECRET_ACCESS_KEY=smoke-test-placeholder" `
    --entrypoint python $image -
if ($LASTEXITCODE -ne 0) { throw "Smoke test failed for $image (dbt build through run_transform)." }

$sizeMb = [math]::Round((docker image inspect $image --format "{{.Size}}") / 1MB)

Write-Host ""
Write-Host "Build complete: $image ($sizeMb MB compressed)." -ForegroundColor Green

if (-not $Push) {
    Write-Host "Not pushed. Add -Push to publish it to ECR."
    return
}

# -- Push to ECR --------------------------------------------------------------
# Existence checks use queries that come back empty rather than failing, so no
# error output needs suppressing (Windows PowerShell can turn it into an
# exception).

Write-Host ""
Write-Host "Pushing to ECR ($Region)" -ForegroundColor Cyan

$repositoryUri = aws ecr describe-repositories --profile $AwsProfile --region $Region `
    --query "repositories[?repositoryName=='$ImageName'].repositoryUri" --output text
if ($LASTEXITCODE -ne 0) { throw "Could not list ECR repositories." }
if (-not $repositoryUri) {
    throw "ECR repository $ImageName does not exist. First deployment: cd infra; terraform apply `"-target=aws_ecr_repository.transform`""
}
$registry = $repositoryUri.Split("/")[0]
$remote = "${repositoryUri}:$tag"

$existing = aws ecr list-images --repository-name $ImageName --profile $AwsProfile --region $Region `
    --query "imageIds[?imageTag=='$tag'].imageDigest" --output text
if ($LASTEXITCODE -ne 0) { throw "Could not list images in $ImageName." }

if ($existing) {
    # Tags are immutable, so a second push of this tag would be rejected. The
    # image already there was built from the same recipe.
    Write-Host "  $tag is already in ECR; not pushed again."
} else {
    # The password travels through the pipe from one program to the other and
    # is never shown. Docker keeps it in the Windows credential store for the
    # token's lifetime (12 hours).
    aws ecr get-login-password --profile $AwsProfile --region $Region |
        docker login --username AWS --password-stdin $registry
    if ($LASTEXITCODE -ne 0) { throw "docker login to $registry failed." }

    docker tag $image $remote
    docker push $remote
    if ($LASTEXITCODE -ne 0) { throw "docker push of $remote failed." }
}

# Lambda accepts a single image manifest, not an index listing several (which
# is what a build with provenance attestations, or for several platforms,
# produces). Checked in ECR itself, on what Lambda will actually pull.
$detail = aws ecr describe-images --repository-name $ImageName --image-ids "imageTag=$tag" `
    --profile $AwsProfile --region $Region `
    --query "imageDetails[0].[imageDigest, imageManifestMediaType]" --output text
if ($LASTEXITCODE -ne 0 -or -not $detail) { throw "$tag was not found in ECR after the push." }
$digest, $mediaType = $detail -split "\s+"
if ($mediaType -match "index|manifest\.list") {
    throw "$tag was pushed as an image index ($mediaType); Lambda will not run it."
}

# Only now is there something for Terraform to deploy.
New-Item -ItemType Directory -Force -Path (Split-Path $TagFile) | Out-Null
Set-Content -Path $TagFile -Value $tag -NoNewline

Write-Host ""
Write-Host "In ECR: $remote" -ForegroundColor Green
Write-Host "  digest     : $digest"
Write-Host "  media type : $mediaType"
Write-Host "Recorded in build/transform_image_tag.txt. Next: cd infra; terraform plan"
