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

## Where things are

- Plan and status: `docs/ROADMAP.md` — read this first in every session.
- Why things are the way they are: `docs/adr/`.
- Architecture diagrams: `README.md` (Mermaid).

## Current phase

Phase 1 — landing zone in the cloud. Sub-steps: 1a application seam in the
companion repo; 1b hello-world Lambda → S3 built by hand in the console, then
deleted; 1c the same, with real extraction code, in Terraform.
