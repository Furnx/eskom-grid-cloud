# 0004. IAM user instead of IAM Identity Center

Date: 2026-09-21
Status: Accepted

## Context

AWS recommends IAM Identity Center for human access: people sign in through
a portal and the CLI receives short-lived credentials, so no long-lived key
ever sits on a laptop. Its organization instance, however, requires AWS
Organizations — and on the Free Plan, creating an organization upgrades the
account to pay-as-you-go and cancels the credits immediately (ADR 0003).
The alternative *account instance* of Identity Center exists only for
AWS-managed applications and cannot grant access to the account itself
(no permission sets), so it does not solve the problem.

## Options considered

1. **Identity Center, organization instance** — the best security posture;
   ends the Free Plan. Rejected on cost.
2. **A single IAM user** with `AdministratorAccess`, MFA on the console, and
   one CLI access key — the standard pattern for a standalone account.
   Introduces one long-lived credential.
3. **The root user with access keys** — never. Root can close the account
   and change payment details; it gets MFA and is otherwise not used.

## Decision

We will use one IAM user (`AdministratorAccess`, MFA on the console) with a
single CLI access key stored only in `~/.aws/credentials`, under the profile
`eskom-admin`. Workloads (Lambda) authenticate with IAM roles and CI
authenticates with GitHub OIDC (Phase 4), so the laptop key is the **only**
long-lived credential in the system.

## Consequences

Easier: works on the Free Plan; Terraform and the CLI use a plain profile;
nothing to renew every day.

Harder: one long-lived secret exists. Mitigations: the key lives in exactly
one place and is never committed, logged or pasted anywhere; it is rotated
periodically and deleted when the project is paused; the user has MFA; the
Zero-spend budget would surface abuse. `AdministratorAccess` for the human
is a deliberate sandbox trade-off — permissions match the job of building
and destroying every resource in the design — while every workload role is
least-privilege.

Revisit if: the account ever moves to a paid plan with Organizations (switch
to Identity Center and delete the key), or a second person needs access.
