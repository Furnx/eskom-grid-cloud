# 0002. Dagster stays local; Step Functions orchestrates production

Date: 2026-09-21
Status: Acceptted

## Context

Locally, the pipeline is orchestrated by Dagster: a job runs the Python
extraction asset and then the dbt assets on an hourly schedule. At runtime
Dagster is three always-on components — a **daemon** that polls schedules and
launches runs, a **webserver** for the UI, and a **metadata store** holding
run history and schedule state (SQLite in the local setup). The local project
has already met the cost of owning that store: SQLite lock errors between the
daemon and the webserver on Windows, which is why it runs inside a Linux
container. A production deployment would need Postgres for the same reason.

The workload does about one minute of work per hour. Whatever orchestrates it
in production is idle roughly 98% of the time.

Production needs three things from an orchestrator: run extract and then
transform, hourly; retry transient failures; tell a human when a run fails.
Development needs something different: an asset graph, lineage, per-asset
metadata, and a UI for iterating and inspecting — the reasons Dagster was
chosen in the first place. These are not the same requirements.

Constraints: no always-on compute (ADR 0001) and no spend (ADR 0003).
Dagster's hosted product has no free tier.

## Options considered

1. **Dagster OSS on a free VM.** Keeps the UI and asset graph in production.
   The developer owns the operating system, process supervision for the
   daemon and webserver, a Postgres instance, upgrades and uptime. Conflicts
   with ADR 0001; a "free" VM converts money cost into operational cost.
2. **Dagster's hosted product.** Removes the operational burden; costs money.
   Rejected under ADR 0003.
3. **A single Lambda that does both steps, no orchestrator.** Simplest
   possible design. But one function means one retry policy: a failure in the
   transform step would re-run the extraction, spending EskomSePush API quota
   (50 requests/day on the free tier) on data that was already landed.
4. **Managed scheduler and state machine** — EventBridge Scheduler triggering
   a Step Functions state machine that runs the extract and transform Lambdas
   in order, with per-step retries and a failure branch to SNS. Always-free
   at this cadence; nothing to keep alive. No asset graph or UI in production.

## Decision

We will keep Dagster as the local development orchestrator only. In
production, EventBridge Scheduler triggers a Step Functions state machine
that runs the extract and transform functions in sequence, with retries and
a failure branch that publishes to SNS. The application exposes its logic as
plain functions so that both orchestrators call the same code.

## Consequences

Easier: no always-on process and nothing to patch; retry and alerting
semantics are declared in the state machine rather than coded; the design
fits inside always-free allowances; the state machine has the same shape as
the Dagster job (extract → transform), so the mental model is identical in
both environments; each step is retried independently, so a transform
failure never re-spends API quota on a fresh extraction.

Harder: no asset graph, lineage or UI in production — observability becomes
CloudWatch logs and the Step Functions execution history, which is per-run
rather than per-asset. There are now two orchestration definitions to keep
consistent (`defs.py` locally, the state machine in Terraform); the
pure-function seam in the application is what keeps that drift small.
Step Functions is AWS-specific — vendor lock-in accepted knowingly. The
always-free allowance of 4,000 state transitions per month caps the state
machine at roughly five states at hourly cadence.

Revisit if: the asset graph grows to need partitions, backfills or sensors;
a team needs a production UI; the platform must be portable across clouds;
or a hosted Dagster tier becomes free for a workload of this size. Given budget,
the developer would keep Dagster in production for its asset-level observability;
cost and operational burden decide against it here
