# CLAUDE.md — eskom-grid-cloud

Project context for Claude Code sessions opened in this repository. The user's
global `~/.claude/CLAUDE.md` (learning workflow: investigate → teach → plan →
wait for approval → implement) applies on top of this file.

## What this repository is

The **platform** that runs the Eskom Grid Observability pipeline on AWS:
Terraform, thin Lambda entry points, CI/CD, monitoring, and Architecture
Decision Records. It is a portfolio project for a cloud-computing course and
must show a steady stream of *meaningful* commits — never manufactured ones.

It is **not** the application. No extraction logic, dbt models or tests live here.

## Companion repository (the application)

- Local path: `../eskom-grid-observability` (sibling directory)
- GitHub: https://github.com/Furnx/eskom-grid-observability
- This repo consumes it at a **pinned git tag** — never `main`.
- The application exposes the seam this repo depends on: pure extraction
  functions callable without Dagster, a storage-sink abstraction (local path
  or `s3://`), a `prod` dbt target, and pip-installability.
- If a change here needs a change there, say so explicitly and let the user
  decide. Never edit the other repository silently from a session in this one.

## AWS facts — read before touching anything

- The account is on the **AWS Free Plan** (created September 2026, window
  closes ~March 2027, cannot be charged). **NEVER enable AWS Organizations,
  Control Tower, the organization instance of IAM Identity Center, Reserved
  Instances, Savings Plans, paid Support plans or Marketplace.** Any of these
  converts the account to pay-as-you-go and cancels the credits immediately.
  See ADR 0003 and ADR 0004.
- Region: `af-south-1` (Cape Town). Always confirm the region.
- CLI profile: `eskom-admin` — an MFA-protected IAM user with one CLI access
  key (Identity Center is unavailable on the Free Plan).
- **Read-only** `aws` calls (`describe-*`, `get-*`, `list-*`,
  `sts get-caller-identity`) may be run freely to verify state. Anything that
  creates, changes or deletes resources — including `terraform apply` and
  `terraform destroy` — requires the user's explicit go for that action.
- Never print, log or commit access keys. They live only in `~/.aws/credentials`.
- Design only within always-free allowances: no NAT gateway, no always-on
  compute (EC2, RDS, Fargate services), no pay-per-query services (Athena).
  See ADR 0003.

## Conventions

- **Terraform** lives in `infra/`, one file per concern (`storage.tf`,
  `compute.tf`, `orchestration.tf`, `iam.tf`, `secrets.tf`, `monitoring.tf`,
  `github_oidc.tf`). Run `terraform fmt` and `terraform validate` before
  committing. State is local and git-ignored until Phase 4, then an S3
  backend. `.terraform.lock.hcl` **is** committed.
- **Never commit** `*.tfstate*`, `*.tfvars`, `.env`, or any secret.
- **Lambda entry points** live in `functions/<name>/handler.py` and are thin:
  they call the application's functions and nothing else.
- **Commits**: conventional commits with a scope — `feat(infra): …`,
  `feat(functions): …`, `ci: …`, `docs(adr): …`, `docs: …`, `chore: …`.
  One logical change per commit.
- **Branches**: feature branch → pull request → `main`, even solo. CI runs
  `terraform plan` on PRs from Phase 4.
- **Decisions**: every architectural decision gets an ADR in `docs/adr/`
  (next number in sequence; `docs/adr/template.md`). Accepted ADRs are never
  edited — write a superseding one.
- **Roadmap**: tick `docs/ROADMAP.md` when a milestone lands; keep the README
  status line and diagrams current.
- Tag every AWS resource `project = eskom-grid`.

## Working with this user

- **Never run `git commit`, `git tag` or `git push`.** Make the file changes, run the
  verification, then hand over a suggested commit message. Approving a plan that lists
  "commit 1 / commit 2" means "make those changes", not "commit them".
- They are learning cloud engineering from zero and want to understand, not just ship:
  investigate, explain what matters, propose a plan, and wait for approval before
  changing files. Their global CLAUDE.md has the full workflow.
- **Beginner's guide:** delivered 2026-09-24 as `docs/GUIDE.md`, local only (listed in
  `.git/info/exclude`, never committed). Grounded in these files and live output;
  revise it when a phase lands.

## Where things are

- Plan and status: `docs/ROADMAP.md` — read this first in every session.
- Why things are the way they are: `docs/adr/`.
- Architecture diagrams: `README.md` (Mermaid).

## Current phase

Phase 1 complete as of 2026-09-24 and deployed:
`eskom-grid-433490648023` (S3), `eskom-grid-extract` (Lambda, app v0.3.2),
`eskom-grid-hourly` (EventBridge Scheduler) - all live in af-south-1 and
writing `raw/<area_id>/<ts>.json` every hour. Terraform state is local in
`infra/terraform.tfstate` (git-ignored). Destroy → rebuild → restore was
proven on 2026-09-24; Terraform never deletes the raw history (ADR 0005).

Build before planning: `./scripts/build_lambda.ps1` (reads `app_version` from
`infra/variables.tf`) and, since Phase 2, `./scripts/build_transform_image.ps1
-Push`, then `cd infra; terraform plan`. The plan reads `build/lambda/` (via
`archive_file`) and `build/transform_image_tag.txt` (via `aws_ecr_image`), and
preconditions refuse either one if it was built from a different version.

Full teardown is `scripts/purge_bucket.ps1 -BackupPath <new folder>` (backs up,
verifies every file by MD5, then asks for the bucket name), then `terraform
destroy`; the README has the rebuild-and-restore steps.

Open follow-up: Lambda's default async retries apply despite the schedule's
retry 0 (Phase 3).

Phase 2 complete as of 2026-09-26 (milestone: the 14:10 and 15:10 SAST runs
each added a `fct_pipeline_runs` row). Both functions run app `v0.3.2`.
`eskom-grid-transform` (container image in ECR repository
`eskom-grid-transform`, deployed by digest, ADR 0008) runs at hh:10 and keeps
`warehouse/eskom_data.duckdb`. `docs/PHASE2_PLAN.md` has the full record.
Deploying it: `./scripts/build_transform_image.ps1 -Push` (needs Docker
Desktop; smoke tests run offline, read-only, without /dev/shm, through
`run_transform()`; ~2 min from cache, ~13 min after an app change), which writes
`build/transform_image_tag.txt` for the plan; then `terraform plan`/`apply`.
The first deploy of an empty registry needs
`terraform apply "-target=aws_ecr_repository.transform"` first (quoted in
PowerShell). Avoid deploying in the minute a schedule fires (hh:00, hh:10).
Key decisions: ADR 0006 (only new raw files are read - the cutoff must stay a
literal on the file read), ADR 0007 (warehouse uploaded with an S3 conditional
write), ADR 0008 (image pushed by script, deployed by digest).

Next: Phase 3 (Step Functions extract -> transform, SNS alerting, retries owned
by the state machine, handlers logging the app version). See docs/ROADMAP.md.
