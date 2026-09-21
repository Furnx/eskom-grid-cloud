# 0003. Zero-cost constraints and the AWS Free Plan

Date: 2026-09-21
Status: Accepted

## Context

The project must cost nothing. The AWS account was created in September 2026
on the **AWS Free Plan** (the post-July-2025 model): up to $200 in credits,
valid for six months or until spent, and the account **cannot be charged** —
it is frozen instead. More than thirty services additionally have
"always free" monthly allowances that do not consume credits and never expire.

The Free Plan blocks services that would consume credits instantly:
AWS Organizations (and therefore Control Tower and the organization instance
of IAM Identity Center), Reserved Instances, Savings Plans, paid Support
plans, and Marketplace. Enabling any of them converts the account to
pay-as-you-go and cancels the credits immediately (confirmed in the console
on 2026-09-21 — the Identity Center enable screen warns of exactly this).

The Free Plan window closes around **March 2027**.

## Options considered

1. **Design freely and rely on credits.** Fast, but produces a bill-shaped
   architecture (per-query services, NAT gateways, always-on instances) that
   only works while credits last and misrepresents its own cost.
2. **Design only within always-free allowances**, treating credits as a
   safety margin rather than a budget. Slightly more constrained; the design
   stays free or near-free on any plan and is honest about what it costs.

## Decision

We will design only within always-free allowances and treat credits as
margin, enforced by these rules:

- Never enable Organizations, Control Tower, the organization instance of
  Identity Center, Reserved Instances, Savings Plans, Support plans or
  Marketplace.
- No always-on compute: no EC2, RDS or Fargate services. No NAT gateway.
- No pay-per-query services (Athena, Redshift Serverless). DuckDB inside
  Lambda reads S3 directly instead.
- The Step Functions state machine stays at five states or fewer, so hourly
  execution stays under the 4,000 free transitions per month.
- A Zero-spend budget alerts by email; the Free Tier page is checked weekly.
- Every resource is tagged `project = eskom-grid`, and `terraform destroy`
  must always work, so nothing can be forgotten and left running.

## Consequences

Easier: the architecture is identical on the Free Plan, on a paid plan, or
recreated in a fresh account from the Terraform in minutes. Estimated steady
state on a paid plan is under $0.10 per month — S3 and ECR have no
always-free allowance, but usage is a few megabytes.

Harder: no managed warehouse (BigQuery- or Athena-style); the DuckDB file
must be shuttled to and from S3 by the transform function. No always-on UI.
When the Free Plan window closes (~March 2027) the project either moves to a
paid plan at the estimated cost above, or is redeployed elsewhere (for
example Azure for Students). The infrastructure-as-code makes that a bounded
exercise rather than a rebuild.

Revisit if: the account moves to a paid plan (Organizations, Identity Center
and hard billing caps via budget actions become available), or usage grows
beyond always-free allowances.
