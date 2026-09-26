# Roadmap

Each phase ends at a **milestone** that can be demonstrated, not merely described.
Phases are sequential. The checkboxes are the source of truth for status.

## Phase 0 — Account & guardrails ✅ 2026-09-21

Goal: an AWS account that is safe to build in and cannot cost money.

- [x] AWS account created on the Free Plan (credits; cannot be charged)
- [x] MFA on the root user; no root access keys (verified: `AccountAccessKeysPresent = 0`)
- [x] Zero-spend budget with email alert
- [x] `af-south-1` (Cape Town) enabled and set as the working region
- [x] Day-to-day IAM user with `AdministratorAccess` + MFA (Identity Center unavailable on the Free Plan — [ADR 0004](adr/0004-iam-user-over-identity-center.md))
- [x] AWS CLI v2 installed; profile `eskom-admin`; `aws sts get-caller-identity` returns the user ARN
- [x] This repository, with roadmap and initial ADRs

**Milestone:** `aws sts get-caller-identity --profile eskom-admin` succeeds; the budget exists; root MFA is on.

## Phase 1 — Landing zone in the cloud ✅ 2026-09-24

Goal: raw JSON lands in S3 every hour with the laptop switched off.

**1a — Application seam** ✅ 2026-09-22 — [eskom-grid-observability@v0.1.0](https://github.com/Furnx/eskom-grid-observability/releases/tag/v0.1.0):
- [x] Extraction logic pulled out of the `@asset` body into pure functions; the decorator becomes a thin wrapper
- [x] Storage-sink abstraction: local path or `s3://…`, selected by environment variable (`ESKOM_RAW_SINK`)
- [x] dbt `prod` target in `profiles.yml.example`; source `external_location` from `env_var("ESKOM_RAW_GLOB")`
- [x] Repository pip-installable (`src/` package, `[project]` metadata); first release tag `v0.1.0`

Verified by installing the tag into a clean interpreter outside the repository:
only `requests` and `pyyaml` came with it — no Dagster, dbt or DuckDB — and the
packaged area portfolio loaded. That is exactly what the Lambda image will do.
The application repository also carries a test asserting this boundary holds.

**1b — By hand, once** (console, to see the parts before automating them):
- [x] S3 bucket: versioning on, public access blocked
- [x] Hello-world Lambda that writes one object into the bucket
- [x] Execution role with `s3:PutObject` on one prefix only
- [x] EventBridge Scheduler rule invoking it hourly
- [x] All of it deleted again

**1c — In Terraform** (`infra/`) ✅ 2026-09-24:
- [x] Provider, bucket, extract Lambda with the real code, least-privilege role, SSM parameter for the API key, hourly schedule
- [x] `terraform apply` from the laptop; `terraform destroy` proven to work
- [x] README: deploy/destroy instructions

Destroy proven by a full drill on 2026-09-24
([ADR 0005](adr/0005-raw-history-outlives-infrastructure.md)): purge →
`terraform destroy` (11 destroyed; only the out-of-band API key remained) →
`terraform apply` (11 added, then "No changes") → restore. All 49 raw objects
came back byte-identical, checked by ETag against a listing taken beforehand,
and the rebuilt stack's first scheduled run landed at 16:00 SAST.

The drill also exposed a gap: the local backup step was skipped and nothing
stopped the purge. The files were rebuilt exactly — every payload that day was
identical per area, so two known bodies and the recorded MD5s were enough — but
that was luck, not design. Fixed the same day: the purge script now takes the
backup itself and checks every file against S3's MD5 fingerprint before it will
ask for the bucket name, so the backup can no longer be skipped by accident.

**Milestone:** laptop off overnight → `raw/<area_id>/<ts>.json` objects appear in S3 every hour.
Met overnight 23–24 September: 20 consecutive hourly runs, both areas, no gaps.

## Phase 2 — Transform in the cloud

Goal: the dbt models build in the cloud; the warehouse accumulates history.

Plan and spike results: [PHASE2_PLAN.md](PHASE2_PLAN.md). Decisions:
[ADR 0006](adr/0006-transform-reads-only-new-raw-files.md) (only new raw files are read),
[ADR 0007](adr/0007-single-writer-for-the-warehouse.md) (one writer for the warehouse).

**2a — Application** ✅ 2026-09-25 — [eskom-grid-observability@v0.3.0](https://github.com/Furnx/eskom-grid-observability/releases/tag/v0.3.0):
- [x] Landing model `stg_eskom__raw_payloads`: the only S3 reader, new files only
- [x] `fct_pipeline_runs` derived from raw files; Dagster `pipeline_run_log` asset removed
- [x] `run_transform()`, a `[transform]` extra, and a `prod` profile for S3
- [x] Fixture tests (including one event); release `v0.3.0`

Verified before release against the 55 real files: 40/40 dbt nodes pass; a
second build re-read 2 files instead of 55; the compiled SQL carries the cutoff
as a literal on the file read; importing `eskom_grid.transform` does not import dbt.

Patched in [v0.3.1](https://github.com/Furnx/eskom-grid-observability/releases/tag/v0.3.1)
the same day: testing the Lambda image offline, read-only and warm exposed two
faults a laptop cannot show — DuckDB extensions looked for in a read-only home
directory, and the database left open (tables still in the `.wal`) when
`run_transform()` returned. Both fixed with regression tests.

**2b — Platform** (deployed 2026-09-26):
- [x] ECR repository and container image with `dbt-core` + `dbt-duckdb` (arm64)
- [x] Transform Lambda: DuckDB reads `s3://…/raw/` directly (httpfs); warehouse pulled from and pushed back to `s3://…/warehouse/` with a conditional write
- [x] Least-privilege role: list and read `raw/*`, read + write `warehouse/*`, nothing else
- [x] Second schedule at hh:10 (temporary until Phase 3)

The first real Lambda run exposed a third environment difference, no
`/dev/shm` (so no POSIX semaphores for dbt's locks), fixed in
[v0.3.2](https://github.com/Furnx/eskom-grid-observability/releases/tag/v0.3.2).
First successful cloud run 2026-09-26 13:13 SAST: 40/40, 21.7 s billed,
401 MB of 1024 MB, 38 new raw files read of 141. Details in
[PHASE2_PLAN.md](PHASE2_PLAN.md), "Chunk 2 results".

**Milestone:** `fct_pipeline_runs` gains a row every hour in the cloud without the
laptop, and a fixture proves events reach `fct_grid_events`. (Amended 2026-09-24:
no loadshedding has been scheduled since collection began, so `fct_grid_events`
alone cannot show growth yet.)

## Phase 3 — Orchestration & alerting

Goal: dependency ordering and failure handling, with a human notified.

- [ ] Step Functions state machine: extract → transform, retries, catch-all
- [ ] Scheduler targets the state machine instead of the Lambda
- [ ] SNS topic + email subscription; the failure branch publishes to it
- [ ] CloudWatch alarm on failed executions → same topic
- [ ] Retries owned by the state machine. Today the scheduler invokes the Lambda
      asynchronously, so Lambda's default of two retries applies despite
      `maximum_retry_attempts = 0` on the schedule: a failing hour can spend up to
      6 API requests against a daily buffer of 2. A synchronous invoke from Step
      Functions removes that layer.

**Milestone:** break the API key on purpose → an email arrives within one cycle; fix it → the next run succeeds.

## Phase 4 — CI/CD

Goal: no human runs Terraform from a laptop; no AWS keys in GitHub.

- [ ] GitHub OIDC identity provider + deploy role in IAM (least privilege for Terraform)
- [ ] Terraform state moved to an S3 backend with locking
- [ ] `plan.yml`: `terraform fmt -check`, `validate`, `plan` on every pull request
- [ ] `deploy.yml`: build and push the image, `terraform apply` on merge to `main`

**Milestone:** a pull request that changes the cron expression deploys itself after merge.

## Phase 5 — Polish

Goal: the repository explains itself to an assessor in five minutes.

- [ ] Cost analysis with *measured* usage against allowances (replaces the README estimates)
- [ ] Architecture diagram marked "as built"
- [ ] ADRs reviewed; any superseded decisions recorded
- [ ] Smoke-test script: trigger a run, assert a new object in S3
- [ ] `eskom-grid-observability` README links here

**Milestone:** a stranger can deploy, verify and destroy the whole platform from the README alone.

## Beyond (not committed)

- Port to Azure using the Azure for Students credit — proves the IaC skills transfer
- A third monitored area (needs a lower cadence or a paid EskomSePush tier — API budget)
- A serving layer for the warehouse (DuckDB over S3 from a notebook, or MotherDuck)
