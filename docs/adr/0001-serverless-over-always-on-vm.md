# 0001. Serverless compute instead of an always-on VM

Date: 2026-09-21
Status: Accepted

## Context

The Eskom Grid Observability pipeline does roughly one minute of work per
hour: two HTTP calls, two small JSON writes, and a dbt build over a few
megabytes. Locally it runs as a Docker Compose stack (Dagster webserver and
daemon) that only runs while a laptop is on, so the history it exists to
accumulate has gaps.

Constraints: a zero-rand budget (AWS Free Plan — ADR 0003), a single
developer with no prior cloud experience, and a portfolio goal of
demonstrating cloud-native engineering rather than server administration.

## Options considered

1. **Lift and shift** — run the existing Docker Compose stack unchanged on a
   free VM (Oracle Cloud Always Free, or EC2 under credits). No code changes;
   the Dagster UI survives. The developer owns the operating system, patching,
   restarts, disk, and Dagster's metadata database.
2. **Serverless** — decompose the pipeline into functions (Lambda) triggered
   by a managed scheduler and state machine, with S3 as the landing zone.
   Requires restructuring the application's entry points; Dagster is not
   part of production.

## Decision

We will run the pipeline as serverless functions orchestrated by managed
services: EventBridge Scheduler, Step Functions, Lambda, and S3.

## Consequences

Easier: zero idle cost for a workload that is idle about 98% of the time; no
operating system, patching, restarts or metadata database to own; uptime is
AWS's responsibility; every resource is declarable in Terraform; the whole
design fits inside always-free allowances.

Harder: the application must expose its logic as plain functions callable
without Dagster (a change in the companion repository); the transform step
needs a container image because dbt exceeds the Lambda zip size limit;
orchestration becomes AWS-specific (Step Functions), which is vendor lock-in
accepted knowingly; the Dagster UI and asset lineage are unavailable in
production (ADR 0002).

Revisit if: the asset graph grows large enough to need partitions and
backfills, a team needs a production UI, or the platform must be portable
across clouds — at that point an always-on orchestrator earns its cost.
