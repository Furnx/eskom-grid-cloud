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

## Phase 1 — Landing zone in the cloud

Goal: raw JSON lands in S3 every hour with the laptop switched off.

**1a — Application seam** (in [eskom-grid-observability](https://github.com/Furnx/eskom-grid-observability)):
- [ ] Extraction logic pulled out of the `@asset` body into pure functions; the decorator becomes a thin wrapper
- [ ] Storage-sink abstraction: local path or `s3://…`, selected by environment variable
- [ ] dbt `prod` target in `profiles.yml.example`; source `external_location` from `env_var()`
- [ ] Repository pip-installable (`src/` package, `[project]` metadata); first release tag

**1b — By hand, once** (console, to see the parts before automating them):
- [ ] S3 bucket: versioning on, public access blocked
- [ ] Hello-world Lambda that writes one object into the bucket
- [ ] Execution role with `s3:PutObject` on one prefix only
- [ ] EventBridge Scheduler rule invoking it hourly
- [ ] All of it deleted again

**1c — In Terraform** (`infra/`):
- [ ] Provider, bucket, extract Lambda with the real code, least-privilege role, SSM parameter for the API key, hourly schedule
- [ ] `terraform apply` from the laptop; `terraform destroy` proven to work
- [ ] README: deploy/destroy instructions

**Milestone:** laptop off overnight → `raw/<area_id>/<ts>.json` objects appear in S3 every hour.

## Phase 2 — Transform in the cloud

Goal: the dbt models build in the cloud; the warehouse accumulates history.

- [ ] Container-image Lambda with `dbt-core` + `dbt-duckdb`
- [ ] DuckDB reads `s3://…/raw/**/*.json` directly (httpfs)
- [ ] Warehouse file pulled from and pushed back to `s3://…/warehouse/`
- [ ] Least-privilege role: read `raw/*`, read + write `warehouse/*`, nothing else
- [ ] ECR repository and image build

**Milestone:** `fct_grid_events` grows run over run without the laptop.

## Phase 3 — Orchestration & alerting

Goal: dependency ordering and failure handling, with a human notified.

- [ ] Step Functions state machine: extract → transform, retries, catch-all
- [ ] Scheduler targets the state machine instead of the Lambda
- [ ] SNS topic + email subscription; the failure branch publishes to it
- [ ] CloudWatch alarm on failed executions → same topic

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
