<#
.SYNOPSIS
    Is the pipeline healthy? Shows the schedule, the latest runs, the failure
    alarm and the alert subscription, then gives one verdict.

.DESCRIPTION
    Alerts only speak when something breaks (ADR 0010): a failed run sends an
    email, a successful one sends nothing. So "is it fixed?" is answered here,
    not in the inbox. Silence alone cannot tell "fixed" from "nothing ran", so
    this script checks both: that runs still start every hour, and how the
    latest one ended.

    Read-only: it only lists and describes. It starts nothing, changes nothing
    and spends no EskomSePush requests.

    The verdict is also the exit code: 0 when healthy, 1 otherwise.

.PARAMETER Runs
    How many recent runs to list, newest first.

.EXAMPLE
    ./scripts/check_pipeline.ps1
    ./scripts/check_pipeline.ps1 -Runs 24     # the last day
#>

param(
    [int]$Runs = 5,
    [string]$AwsProfile = "eskom-admin",
    [string]$Region = "af-south-1"
)

$ErrorActionPreference = "Stop"

# Named as infra/ names them. The ARNs are built from the account, as
# look_at_warehouse.ps1 builds the bucket name, so a rebuilt stack needs no edit.
$account = aws sts get-caller-identity --profile $AwsProfile --query Account --output text
if ($LASTEXITCODE -ne 0) { throw "Could not identify the AWS account with profile '$AwsProfile'." }
$StateMachineArn = "arn:aws:states:${Region}:${account}:stateMachine:eskom-grid-pipeline"
$TopicArn = "arn:aws:sns:${Region}:${account}:eskom-grid-alerts"
$ScheduleName = "eskom-grid-hourly"
$AlarmName = "eskom-grid-pipeline-failed"

# A scheduled run starts at hh:00 and is over within a minute. Longer than this
# without a new start means the schedule has stopped starting runs.
$MaxMinutesBetweenRuns = 65

function Format-Time([datetimeoffset]$time) {
    $time.ToLocalTime().ToString("ddd dd MMM HH:mm")
}

# Existence checks use queries that come back empty rather than failing, so no
# error output needs suppressing (Windows PowerShell can turn it into an
# exception).

# -- The schedule: is anything going to start runs? --------------------------
$scheduleState = aws scheduler list-schedules --profile $AwsProfile --region $Region `
    --query "Schedules[?Name=='$ScheduleName'].State" --output text
if ($LASTEXITCODE -ne 0) { throw "Could not list the schedules." }
if (-not $scheduleState) { $scheduleState = "MISSING" }

# -- The latest runs, newest first --------------------------------------------
# Text output, one run per line, so the dates arrive as plain strings in every
# PowerShell version. A run still in progress has no stop date ("None").
$lines = aws stepfunctions list-executions --state-machine-arn $StateMachineArn --max-items $Runs `
    --query "executions[].[startDate, stopDate, status, name, executionArn]" --output text `
    --profile $AwsProfile --region $Region
if ($LASTEXITCODE -ne 0) { throw "Could not list the runs of $StateMachineArn. Does it exist?" }

$executions = @(foreach ($line in $lines) {
    $fields = $line -split "`t"
    if ($fields.Count -lt 5) { continue }
    [pscustomobject]@{
        Start  = [datetimeoffset]::Parse($fields[0])
        Stop   = $(if ($fields[1] -ne "None") { [datetimeoffset]::Parse($fields[1]) } else { $null })
        Status = $fields[2]
        Name   = $fields[3]
        Arn    = $fields[4]
        Error  = ""
    }
})

# The list does not say why a run failed; each failed run's own record does.
foreach ($run in $executions | Where-Object { $_.Status -in "FAILED", "TIMED_OUT", "ABORTED" }) {
    $run.Error = aws stepfunctions describe-execution --execution-arn $run.Arn `
        --query error --output text --profile $AwsProfile --region $Region
}

# -- The alarm and the subscription -------------------------------------------
$alarm = aws cloudwatch describe-alarms --alarm-names $AlarmName --profile $AwsProfile --region $Region `
    --query "MetricAlarms[0].[StateValue, StateTransitionedTimestamp]" --output text
if ($LASTEXITCODE -ne 0) { throw "Could not read the alarm $AlarmName." }

$subscriptions = aws sns list-subscriptions --profile $AwsProfile --region $Region `
    --query "Subscriptions[?TopicArn=='$TopicArn'].SubscriptionArn" --output text
if ($LASTEXITCODE -ne 0) { throw "Could not list the SNS subscriptions." }

# -- Report -------------------------------------------------------------------
Write-Host ""
Write-Host "Schedule  $ScheduleName : $scheduleState" -ForegroundColor $(if ($scheduleState -eq "ENABLED") { "Green" } else { "Red" })

Write-Host ""
Write-Host "Latest runs (newest first; scheduled runs have a generated id, named ones were started by hand):"
foreach ($run in $executions) {
    $seconds = $(if ($run.Stop) { "{0,4:N0} s" -f ($run.Stop - $run.Start).TotalSeconds } else { "   ..." })
    $label = $(if ($run.Name -match '^[0-9a-f]{8}-[0-9a-f]{4}-') { "" } else { $run.Name })
    $colour = switch ($run.Status) { "SUCCEEDED" { "Green" } "RUNNING" { "Cyan" } default { "Red" } }
    Write-Host ("  {0}  {1,-10} {2}  {3,-16} {4}" -f (Format-Time $run.Start), $run.Status, $seconds, $run.Error, $label) -ForegroundColor $colour
}
if (-not $executions) { Write-Host "  (none yet)" }

Write-Host ""
if (-not $alarm -or $alarm -eq "None") {
    Write-Host "Alarm     $AlarmName : MISSING" -ForegroundColor Red
} else {
    $alarmState, $alarmSince = $alarm -split "`t"
    # The alarm turns ALARM when a run fails and back to OK about 15 minutes
    # later by itself (infra/monitoring.tf). So it says whether a run failed
    # recently, not whether the next one succeeded: the verdict below is based
    # on the runs, not on the alarm.
    Write-Host ("Alarm     {0} : {1} since {2}" -f $AlarmName, $alarmState, (Format-Time ([datetimeoffset]::Parse($alarmSince)))) `
        -ForegroundColor $(if ($alarmState -eq "OK") { "Green" } else { "Red" })
}

$alertsConfirmed = $subscriptions -match "^arn:"
if ($alertsConfirmed) {
    Write-Host "Alerts    email subscription confirmed" -ForegroundColor Green
} elseif ($subscriptions -match "PendingConfirmation") {
    Write-Host "Alerts    email subscription NOT CONFIRMED: click the link in AWS's email, or alerts go nowhere" -ForegroundColor Yellow
} else {
    Write-Host "Alerts    no email subscription: failures will not be reported" -ForegroundColor Red
}

# -- Verdict ------------------------------------------------------------------
$now = [datetimeoffset]::Now
$nextRun = (Get-Date).Date.AddHours((Get-Date).Hour + 1).ToString("HH:mm")
$lastFinished = $executions | Where-Object { $_.Status -ne "RUNNING" } | Select-Object -First 1
$healthy = $false

Write-Host ""
if ($scheduleState -ne "ENABLED") {
    $verdict = "NOT RUNNING: the schedule is $scheduleState, so no runs will start."
} elseif (-not $executions) {
    $verdict = "NO RUNS YET: the first scheduled run is at $nextRun."
} elseif (($now - $executions[0].Start).TotalMinutes -gt $MaxMinutesBetweenRuns) {
    $minutes = [math]::Round(($now - $executions[0].Start).TotalMinutes)
    $verdict = "STALE: no run has started for $minutes minutes, though the schedule is enabled. Runs should start every hour."
} elseif (-not $lastFinished) {
    $verdict = "IN PROGRESS: the first run has not finished yet."
} elseif ($lastFinished.Status -eq "SUCCEEDED") {
    $healthy = $true
    $verdict = "HEALTHY: the latest run ($(Format-Time $lastFinished.Start)) succeeded. Next scheduled run at $nextRun."
} else {
    $verdict = "FAILING: the latest run ($(Format-Time $lastFinished.Start)) ended $($lastFinished.Status) with $($lastFinished.Error). The alert email has the details; the next scheduled run is at $nextRun."
}

Write-Host "Verdict   $verdict" -ForegroundColor $(if ($healthy) { "Green" } else { "Red" })
if ($healthy -and -not $alertsConfirmed) {
    Write-Host "          (but see Alerts above: a failure would not reach you)" -ForegroundColor Yellow
}
Write-Host ""

if (-not $healthy) { exit 1 }
