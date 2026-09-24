# 0007. One writer for the warehouse, enforced by S3 conditional writes

Date: 2026-09-24
Status: Accepted

## Context

The warehouse is one DuckDB file, `warehouse/eskom_data.duckdb`. Each transform
run downloads it, runs dbt, and uploads it back. If two runs overlap — a manual
invoke during a scheduled run, say — both download the same copy and whichever
uploads last silently discards the other's work (a lost update).

The usual guard is reserved concurrency of 1 on the function. This account's
Lambda concurrency limit is 10, and AWS requires at least 10 to stay unreserved,
so none can be reserved (checked with `aws lambda get-account-settings`,
2026-09-24).

## Options considered

1. **Reserved concurrency 1.** Needs a quota increase first; free but slow, and
   not guaranteed.
2. **A lock table in DynamoDB.** Works and fits the always-free allowance, but
   adds a service, a table and lock-expiry logic for one file.
3. **S3 conditional writes.** Upload with `If-Match` set to the ETag that was
   downloaded (`If-None-Match: *` when no warehouse exists yet). If anything
   replaced the file in between, S3 answers `412 Precondition Failed` and nothing
   is overwritten.
4. **Accept the risk.** Overlaps are rare at hourly cadence, but a lost update
   is silent.

## Decision

We will upload the warehouse with an S3 conditional write keyed on the ETag read
at the start of the run. A run that loses the race fails loudly and uploads
nothing.

## Consequences

Easier: no extra service or cost; correctness does not depend on how the function
is triggered. A losing run's work is not lost for good: raw files are the source
of truth, and the next run's landing model picks them up again.

Harder: the handler must carry the ETag from download to upload; a losing run
spends its compute for nothing; the image must ship a boto3 recent enough to send
`IfMatch` on `put_object` (pinned in the image, not taken from the runtime).

Revisit if: Phase 3's state machine serialises runs by construction — the
conditional write then stays as a cheap backstop rather than the main guard.
