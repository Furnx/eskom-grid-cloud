<#
.SYNOPSIS
    Permanently deletes every object version and delete marker in an S3 bucket.

.DESCRIPTION
    The deliberate first half of a full teardown (ADR 0005). Terraform never
    deletes the raw history: the bucket does not set force_destroy, and S3
    refuses to delete a bucket that still holds data. This script is the one
    place the history is removed, so it says exactly what it will delete and
    asks for the bucket name to be typed before doing it.

    Why not `aws s3 rm --recursive`: the bucket is versioned, so that only
    stacks a delete marker on top of each object. Every version survives, and
    so does the bucket. This script deletes the versions themselves.

    Back up first (README, "Full teardown"). Nothing deleted here can be
    recovered.

.PARAMETER Bucket
    Bucket to purge. `terraform output raw_bucket` prints it.

.PARAMETER DryRun
    List what would be deleted, then stop without asking or deleting.

.EXAMPLE
    ./scripts/purge_bucket.ps1 -Bucket eskom-grid-433490648023 -DryRun
    ./scripts/purge_bucket.ps1 -Bucket eskom-grid-433490648023
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Bucket,
    [string]$AwsProfile = "eskom-admin",
    [string]$Region = "af-south-1",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$AwsArgs = @("--profile", $AwsProfile, "--region", $Region, "--output", "json")

# Every version and delete marker, as { Key, VersionId } pairs. The CLI follows
# the pagination itself, so this is complete however many pages it takes.
function Get-AllVersions {
    $text = (aws s3api list-object-versions --bucket $Bucket @AwsArgs) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not list object versions in '$Bucket'." }
    if (-not $text.Trim()) { return @() }

    $listing = $text | ConvertFrom-Json
    @($listing.Versions) + @($listing.DeleteMarkers) |
        Where-Object { $_ } |
        ForEach-Object { [pscustomobject]@{ Key = $_.Key; VersionId = $_.VersionId } }
}

$items = @(Get-AllVersions)
if ($items.Count -eq 0) {
    Write-Host "s3://$Bucket holds no object versions or delete markers. Nothing to do." -ForegroundColor Green
    return
}

$keys = @($items | Select-Object -ExpandProperty Key -Unique)
Write-Host ""
Write-Host "s3://$Bucket holds $($items.Count) object version(s) and delete marker(s) across $($keys.Count) key(s), e.g.:"
$keys | Select-Object -First 3 | ForEach-Object { Write-Host "  $_" }
Write-Host ""

if ($DryRun) {
    Write-Host "Dry run: nothing was deleted." -ForegroundColor Yellow
    return
}

Write-Host "Every one of them will be PERMANENTLY deleted. This cannot be undone." -ForegroundColor Red
Write-Host "Back up raw/ first (README, 'Full teardown')."
$answer = Read-Host "Type the bucket name to continue"
if ($answer -ne $Bucket) {
    Write-Host "That is not '$Bucket'. Nothing was deleted."
    exit 1
}

# DeleteObjects accepts at most 1,000 entries per call. The request goes via a
# temporary file because a JSON document on the command line does not survive
# PowerShell's quoting rules intact.
$batchFile = Join-Path ([System.IO.Path]::GetTempPath()) "purge-$Bucket.json"
try {
    for ($start = 0; $start -lt $items.Count; $start += 1000) {
        $end = [math]::Min($start + 999, $items.Count - 1)
        $request = @{ Objects = @($items[$start..$end]); Quiet = $true } | ConvertTo-Json -Depth 3 -Compress
        # WriteAllText writes UTF-8 without a byte-order mark, which the CLI requires.
        [System.IO.File]::WriteAllText($batchFile, $request)

        $text = (aws s3api delete-objects --bucket $Bucket --delete "file://$batchFile" @AwsArgs) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "delete-objects failed; see the error above." }

        # Quiet mode reports failures only, so any output here is a refusal.
        if ($text.Trim()) {
            $refused = @(($text | ConvertFrom-Json).Errors | Where-Object { $_ })
            if ($refused.Count -gt 0) {
                throw "S3 refused $($refused.Count) deletion(s); first: $($refused[0].Key) - $($refused[0].Message)"
            }
        }
        Write-Host "  deleted $($end + 1) / $($items.Count)"
    }
}
finally {
    Remove-Item $batchFile -ErrorAction SilentlyContinue
}

# Check rather than assume: a scheduled run may have written a new object while
# this script was running.
$left = @(Get-AllVersions)
if ($left.Count -gt 0) {
    throw "$($left.Count) version(s) remain in '$Bucket' (a scheduled run may have just landed). Run the script again."
}

Write-Host ""
Write-Host "s3://$Bucket is empty. Next: cd infra; terraform destroy" -ForegroundColor Green
