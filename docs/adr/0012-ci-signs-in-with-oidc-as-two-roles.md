# 0012. CI signs in with OIDC as two roles: read-only for pull requests, broad with explicit denies for main

Date: 2026-09-27
Status: Accepted

## Context

Phase 4 moves `terraform plan` and `apply` from the laptop to GitHub Actions.
The roadmap rules out AWS keys stored in GitHub. With OIDC, GitHub signs a
short-lived token for each workflow run stating which repository it belongs to
and why it runs (a pull request, a push to `main`); an IAM role's trust policy
decides which of those it accepts, and AWS answers with credentials that expire
within the hour. The identity provider and roles live in the bootstrap
configuration, so CI never manages them (ADR 0011).

Terraform here manages S3, Lambda, ECR, Step Functions, EventBridge Scheduler,
SNS, CloudWatch and four IAM roles, so whatever applies it needs wide rights,
IAM included. The repository is public: every workflow log is public, and
anyone can open a pull request (though GitHub gives a pull request from a fork
no way to request a token). The account is on the Free Plan, where
Organizations, Marketplace, Reserved Instances, Savings Plans or a paid support
plan would end the credits at once (ADR 0003). And the AWS-managed key for SSM
lets any principal allowed to read a parameter decrypt it: that would include
the API key.

## Options considered

1. **One role, `AdministratorAccess`**, for every workflow. Simplest; a pull
   request's plan could then change anything.
2. **Two roles with hand-written, scoped policies.** Least privilege, but every
   new kind of resource needs the policies extended, usually after an
   `AccessDenied`.
3. **Two roles with AWS's managed policies and explicit denies:**
   `ReadOnlyAccess` for pull requests, `AdministratorAccess` for `main`, each
   with a short list of denies. In IAM an explicit deny always beats an allow.

And for deployment: apply automatically on merge, or wait for a manual approval.

## Decision

We will use option 3 and apply automatically on merge (both chosen by the
project owner).

- `eskom-grid-ci-plan`: assumable only for a pull request in this repository;
  `ReadOnlyAccess`; denied reading SSM parameters. It plans without taking the
  state lock, since it may not write.
- `eskom-grid-ci-deploy`: assumable only from `main`, through a GitHub
  environment limited to that branch; `AdministratorAccess`; denied the Free
  Plan's landmines, any change to CI's own identity provider and roles, reading
  SSM parameters, and deleting the raw history (ADR 0005).

## Consequences

Easier: no policy to extend as the infrastructure grows; a pull request can
never change anything; a merge deploys without a laptop, and nothing is stored
in GitHub that could sign in to AWS.

Harder: the deploy role is not least-privilege, unlike every workload role
(the README says so). A mistaken or hijacked workflow on `main` can do anything
not explicitly denied, such as creating resources that spend credits or
deleting infrastructure, and the deny list is only as good as its author's
imagination. Merging is the approval, so a pull request's plan must be read
before merging. Third-party actions run with these credentials, so they are
pinned to exact commits.

Revisit before anyone else gets write access to the repository, if the deny
list grows long, or if a mistake ever gets past it: then write scoped policies
(option 2).
