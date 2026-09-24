<#
.SYNOPSIS
    Backs up and verifies an S3 bucket, then permanently deletes every object
    version and delete marker in it.

.DESCRIPTION
    The deliberate first half of a full teardown (ADR 0005). Terraform never
    deletes the raw history: the bucket does not set force_destroy, and S3
    refuses to delete a bucket that still holds data. This script is the one
    place the history is removed, so it guards the deletion twice:

      1. Backup. Every current object is downloaded to <BackupPath>\objects and
         checked against the fingerprint S3 recorded for it. The fingerprints
         are saved to <BackupPath>\fingerprints.tsv for checking a restore. If
         any file fails, the script stops before asking anything.
      2. Confirmation. Only after a verified backup does it ask for the bucket
         name to be typed.

    The backup is built in rather than left as a separate step because a
    separate step can be skipped: on 2026-09-24 one was, and the purge went
    ahead regardless (ROADMAP, Phase 1).

    Why not `aws s3 rm --recursive`: the bucket is versioned, so that only
    stacks a delete marker on top of each object. Every version survives, and
    so does the bucket. This script deletes the versions themselves.

.PARAMETER Bucket
    Bucket to purge. `terraform output raw_bucket` prints it.

.PARAMETER BackupPath
    A new or empty folder to back up into. Required unless -NoBackup is given.

.PARAMETER NoBackup
    Purge without a backup. Only for data you are certain is not needed.

.PARAMETER DryRun
    Do everything except delete: list, and with -BackupPath also back up and
    verify, then stop without asking. Doubles as a way to take a verified backup.

.EXAMPLE
    ./scripts/purge_bucket.ps1 -Bucket eskom-grid-433490648023 -DryRun
    ./scripts/purge_bucket.ps1 -Bucket eskom-grid-433490648023 -BackupPath "$HOME\eskom-grid-backup\2026-10-01"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Bucket,
    [string]$BackupPath,
    [switch]$NoBackup,
    [string]$AwsProfile = "eskom-admin",
    [string]$Region = "af-south-1",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$AwsArgs = @("--profile", $AwsProfile, "--region", $Region, "--output", "json")

# Settle the backup question before touching anything.
if ($BackupPath -and $NoBackup) { throw "Pass either -BackupPath or -NoBackup, not both." }
if (-not $DryRun -and -not $BackupPath -and -not $NoBackup) {
    throw "Pass -BackupPath <new or empty folder> so the data is backed up and verified before anything is deleted (or -NoBackup if you are certain it is not needed)."
}
if ($BackupPath -and (Test-Path $BackupPath) -and (Get-ChildItem $BackupPath -Force | Select-Object -First 1)) {
    throw "Backup folder '$BackupPath' is not empty. Use a new folder, so that two backups are never mixed."
}

# One listing of every version and delete marker. The CLI follows the
# pagination itself, so this is complete however many pages it takes.
function Get-Listing {
    $text = (aws s3api list-object-versions --bucket $Bucket @AwsArgs) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not list object versions in '$Bucket'." }
    $listing = if ($text.Trim()) { $text | ConvertFrom-Json } else { $null }
    [pscustomobject]@{
        Versions      = @($listing.Versions | Where-Object { $_ })
        DeleteMarkers = @($listing.DeleteMarkers | Where-Object { $_ })
    }
}

# What DeleteObjects needs: every version and every delete marker.
function Get-DeletionTargets($listing) {
    @($listing.Versions) + @($listing.DeleteMarkers) |
        ForEach-Object { [pscustomobject]@{ Key = $_.Key; VersionId = $_.VersionId } }
}

# Compares each current object with its downloaded copy and returns what is
# wrong. For a single-part upload without KMS encryption, which is how every
# object in this bucket is written, the ETag is the MD5 of the content. A
# multipart ETag (it contains a '-') is not an MD5, so those are checked by
# size alone.
function Test-Backup($current, $objectsDir) {
    foreach ($object in $current) {
        # Zero-byte "folder" keys created by the console hold no data.
        if ($object.Key.EndsWith("/")) { continue }

        $path = Join-Path $objectsDir ($object.Key -replace "/", "\")
        $etag = $object.ETag.Trim('"')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { "missing: $($object.Key)"; continue }
        if ((Get-Item -LiteralPath $path).Length -ne $object.Size) { "size differs: $($object.Key)"; continue }
        if ($etag -notmatch "-" -and (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash -ne $etag) {
            "content differs: $($object.Key)"
        }
    }
}

$listing = Get-Listing
$targets = @(Get-DeletionTargets $listing)
if ($targets.Count -eq 0) {
    Write-Host "s3://$Bucket holds no object versions or delete markers. Nothing to do." -ForegroundColor Green
    return
}

$current = @($listing.Versions | Where-Object { $_.IsLatest })
$keys = @($targets | Select-Object -ExpandProperty Key -Unique)
Write-Host ""
Write-Host "s3://$Bucket holds $($targets.Count) object version(s) and delete marker(s) across $($keys.Count) key(s); $($current.Count) are current objects. E.g.:"
$keys | Select-Object -First 3 | ForEach-Object { Write-Host "  $_" }
Write-Host ""

if ($BackupPath) {
    $objectsDir = Join-Path $BackupPath "objects"
    $fingerprints = Join-Path $BackupPath "fingerprints.tsv"
    New-Item -ItemType Directory -Force -Path $objectsDir | Out-Null

    Write-Host "Backing up $($current.Count) current object(s) to $objectsDir ..."
    aws s3 sync "s3://$Bucket/" $objectsDir --profile $AwsProfile --region $Region --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "The backup download failed. Nothing was deleted." }

    $problems = @(Test-Backup $current $objectsDir)
    if ($problems.Count -gt 0) {
        $problems | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "$($problems.Count) object(s) failed verification against S3. Nothing was deleted."
    }

    # Same format as `aws s3api list-objects-v2 --query "Contents[].[Key, ETag, Size]"
    # --output text` sorted, so a restore can be compared line for line.
    $current | ForEach-Object { "$($_.Key)`t$($_.ETag)`t$($_.Size)" } | Sort-Object | Set-Content -Path $fingerprints
    Write-Host "Backup verified: all $($current.Count) object(s) match S3's fingerprints." -ForegroundColor Green
    Write-Host "Fingerprints saved to $fingerprints"
    Write-Host ""
}

if ($DryRun) {
    Write-Host "Dry run: nothing was deleted." -ForegroundColor Yellow
    return
}

Write-Host "Every version listed above will be PERMANENTLY deleted. This cannot be undone." -ForegroundColor Red
if ($BackupPath) {
    Write-Host "A verified backup is in $BackupPath."
} else {
    Write-Host "There is NO backup (-NoBackup)." -ForegroundColor Red
}
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
    for ($start = 0; $start -lt $targets.Count; $start += 1000) {
        $end = [math]::Min($start + 999, $targets.Count - 1)
        $request = @{ Objects = @($targets[$start..$end]); Quiet = $true } | ConvertTo-Json -Depth 3 -Compress
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
        Write-Host "  deleted $($end + 1) / $($targets.Count)"
    }
}
finally {
    Remove-Item $batchFile -ErrorAction SilentlyContinue
}

# Check rather than assume: a scheduled run may have written a new object while
# this script was running.
$left = @(Get-DeletionTargets (Get-Listing))
if ($left.Count -gt 0) {
    throw "$($left.Count) version(s) remain in '$Bucket' (a scheduled run may have just landed). Run the script again with a new -BackupPath."
}

Write-Host ""
Write-Host "s3://$Bucket is empty. Next: cd infra; terraform destroy" -ForegroundColor Green
if ($BackupPath) {
    Write-Host "Restore after a rebuild: aws s3 sync `"$objectsDir`" s3://$Bucket/ (README, 'Rebuild and restore')"
}
