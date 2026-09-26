# 0010. Failures are emailed by the failure branch, with an alarm as backstop

Date: 2026-09-26
Status: Accepted

## Context

Until Phase 3 nothing reports a failure: it is found by reading logs. ADR 0002
decided that the state machine has a failure branch that publishes to SNS. That
branch can report any error a step raises, with detail: the step, the error, its
cause and a link to the run. It cannot report its own failure: an error in its
expressions, or in the publish itself, ends the execution without an email.

Constraints (ADR 0003): SNS email (1,000 a month) and CloudWatch alarms (10) are
within always-free allowances. Encrypting the topic with KMS is not free in
practice: CloudWatch alarms cannot publish to a topic encrypted with the
AWS-managed key `aws/sns`, and a customer-managed key costs $1 a month.

## Options considered

1. **Failure branch, plus an alarm on failed executions** (`ExecutionsFailed`).
   The alarm reaches the topic by a separate route, so it covers the branch.
   Most failures send two emails.
2. **Failure branch, plus an alarm on missing success** ("no successful run in
   two hours", a dead man's switch). It also notices executions that never start
   (a disabled schedule, a broken scheduler role), but its behaviour can only be
   tested by letting runs lapse, which leaves gaps in the history.
3. **Both alarms.** The widest cover, and the most email.

## Decision

We will use option 1 (chosen by the project owner): one SNS topic with one email
subscription; the failure branch publishes the detail and then ends the
execution in a Fail state carrying the step's own error name; an alarm fires
when `ExecutionsFailed` is at least 1 in five minutes. The topic is not
encrypted with KMS. The address lives in the git-ignored `terraform.tfvars`.

## Consequences

Easier: a detailed email within about a minute of a failure; the execution list
shows the real error (`HTTPError`, not a generic one); a failing branch is still
reported; no new cost.

Harder: most failures send two emails, and an alarm email that arrives alone
means the branch failed too. Nothing reports executions that never start: the
scheduler's start retries (ADR 0009) narrow that gap but do not close it. The
topic is encrypted only in transit, which security scanners will flag; the
messages carry no secrets, since the API key travels in a request header, never
in an error message. The subscription must be confirmed by hand after every
fresh deployment, and anyone holding an alert email can unsubscribe with its
link. CI will need the address in Phase 4.

Revisit in Phase 5 (option 2, to close the gap above), or if the emails become
noise.
