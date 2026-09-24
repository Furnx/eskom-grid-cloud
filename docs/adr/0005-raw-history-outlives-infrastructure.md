# 0005. Raw history outlives the infrastructure

Date: 2026-09-24
Status: Accepted

## Context

The raw bucket (`eskom-grid-<account id>`) holds the only copy of the history
the project exists to collect, and that history cannot be recreated: the
EskomSePush API returns only the current schedule, so an hour that is lost is
lost for good. Everything else in `infra/` — function, roles, schedule, log
group — can be rebuilt from code in about a minute.

ADR 0003 requires that `terraform destroy` always works, so that nothing is
forgotten and left running. The bucket is versioned, and S3 refuses to delete
a bucket that still holds any object version or delete marker. Emptying it
with `aws s3 rm --recursive` only stacks a delete marker on top of each
object, so the original README instructions (empty, then destroy) fail with
`BucketNotEmpty`.

A plain `terraform destroy` against a bucket that holds data fails partway:
dependants are removed first — including the public access block and the
lifecycle rule, and versioning is suspended — and then the bucket deletion is
refused. The data survives, without its guards, until the next apply.

Constraints: one developer, one environment, no spend, and the history grows
every hour.

## Options considered

1. **`force_destroy = true`** on the bucket. `terraform destroy` always
   succeeds — and deletes every version of every object with it. One command
   from losing all history, with no second chance.
2. **`lifecycle { prevent_destroy = true }`.** Terraform refuses any plan that
   would destroy the bucket, so `terraform destroy` fails for the whole
   configuration. Contradicts ADR 0003.
3. **Separate configurations for data and compute** — the bucket in one state,
   everything else in another. Compute can be destroyed and rebuilt freely.
   The standard pattern at scale, but it means two states, cross-configuration
   references and two pipelines in Phase 4, all for one bucket.
4. **Keep S3's refusal as the safety catch** and make a full teardown a
   deliberate sequence: back up, run a purge script that deletes every version
   only after the bucket name is typed, then `terraform destroy`.

## Decision

We will never let Terraform delete data: the bucket keeps `force_destroy`
unset. Removing the history takes a separate, explicit act —
`scripts/purge_bucket.ps1` — before `terraform destroy`. The README documents
a full teardown as back up → purge → destroy, and a rebuild as
apply → restore.

## Consequences

Easier: losing the history requires two deliberate acts, one of which asks for
the bucket name to be typed; `terraform destroy` remains a statement about
infrastructure only; rebuilding with the data restored is a written procedure
rather than an improvisation.

Harder: a full teardown is three steps, not one. A plain `terraform destroy`
against a bucket that holds data still stops partway and leaves the bucket
without its public access block, lifecycle rule and versioning until
`terraform apply` restores them — the README says so. During a rebuild the
backup on the laptop is the only copy of the history.

Revisit if: a second environment or a second person appears, the history
outgrows a laptop-sized backup, or data that cannot be rebuilt from `raw/` is
ever stored elsewhere (the procedure backs up `raw/` only) — at that point
option 3 earns its complexity.
