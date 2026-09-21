# Architecture Decision Records

An ADR is a short document that captures **one** architectural decision: the
situation that forced it, the options that were on the table, what was chosen,
and what that choice costs. It answers "why is it like this?" for anyone who
arrives later — including the author, six months on.

Rules:

- One decision per file, numbered in sequence: `NNNN-short-title.md`.
- Written **when the decision is made**, not reconstructed afterwards.
- An accepted ADR is never edited. If the decision changes, write a new ADR
  that supersedes it and mark the old one `Superseded by NNNN`.
- Consequences include the *bad* ones. An ADR with no downsides is a sales pitch.
- Keep it under a page. If it needs more, it is probably several decisions.

Statuses: `Proposed` → `Accepted` → (`Superseded by NNNN` | `Deprecated`).

Format (after Michael Nygard): see [template.md](template.md).

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-serverless-over-always-on-vm.md) | Serverless compute instead of an always-on VM | Accepted |
| [0002](0002-dagster-stays-local.md) | Dagster stays local; Step Functions orchestrates production | Accepted |
| [0003](0003-zero-cost-constraints.md) | Zero-cost constraints and the AWS Free Plan | Accepted |
| [0004](0004-iam-user-over-identity-center.md) | IAM user instead of IAM Identity Center | Accepted |
