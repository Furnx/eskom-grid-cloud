# 0011. Terraform state lives in S3; what CI depends on lives in a bootstrap configuration

Date: 2026-09-27
Status: Accepted

## Context

Until Phase 4, Terraform's state was a file on the laptop, `infra/terraform.tfstate`,
git-ignored. Phase 4 moves deployment to GitHub Actions, whose runners are fresh
machines: they need the same state, and a lock so that two runs can never write
it at once. Whatever holds the state must exist before any configuration can
use it: a backend is read at `terraform init`, before anything is created.

CI also needs an identity in AWS: the GitHub OIDC connection and the roles it
assumes. CLAUDE.md's first sketch of the layout (Phase 0) put these in the main
configuration as `infra/github_oidc.tf`. That would make CI manage the role it
runs as. It could then widen its own permissions, or apply a mistake in its own
trust policy and lose the access it needs to fix it; and destroying the main
configuration would remove CI's access with it.

Locking: DynamoDB-based locking for the S3 backend is deprecated. Since
Terraform 1.11 the backend can lock with a lock file in the bucket itself
(`use_lockfile`), which needs no other service.

## Options considered

1. **Everything in the main configuration**, with the state bucket made by hand.
   One configuration, but CI manages itself, with the risks above.
2. **A separate bootstrap configuration** (`infra/bootstrap/`) for the state
   bucket and CI's identity, applied from the laptop by the account admin and
   never by CI. Its own state is kept in the bucket it creates.
3. **Create the bucket and CI's identity by hand** with the CLI. Less code, but
   neither reviewable nor reproducible.

## Decision

We will use a bootstrap configuration (option 2, chosen by the project owner)
and the S3 backend with `use_lockfile`. The bucket is
`eskom-grid-tfstate-<account>`: private, encrypted, reachable only over TLS,
versioned (old versions kept 90 days) and protected by `prevent_destroy`. It
holds `infra/terraform.tfstate` and `bootstrap/terraform.tfstate`.

## Consequences

Easier: the laptop and CI share one state, and a lock keeps their runs apart. CI
never manages its own identity, so its permissions can be limited firmly, and it
cannot lock itself out. `terraform destroy` on the main configuration leaves
the state bucket and CI's access in place. A damaged state can be rolled back
to an earlier version.

Harder: two configurations, and the bootstrap is applied by hand. Its first
apply in an account starts on a local state (an override file) and then moves
it into the bucket it has just created. A backend can't use variables, so the
bucket's name, account ID included, is written out in both backend blocks. The
laptop names its profile at `terraform init -backend-config="profile=eskom-admin"`,
once per clone. Like the raw history (ADR 0005), the state bucket outlives any
`destroy`.

Revisit if the project moves to another account or region (the names are
literal), or gains more people who need different access to the state.
