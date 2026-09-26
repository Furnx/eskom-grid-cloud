# 0009. Only failures around a function are retried

Date: 2026-09-26
Status: Accepted

## Context

Until Phase 3 the scheduler invokes each Lambda asynchronously. Lambda then
retries a failing run twice on its own, whatever the schedule's retry policy
says: on 2026-09-26 the failing 12:10 transform ran at 12:10, 12:11 and 12:13.
From Phase 3, Step Functions invokes the functions synchronously, so the only
retries are the ones the state machine declares. Which ones to declare?

The two steps fail at different cost. A failed **extract** loses that hour for
good: the API returns only the current schedule. A failed **transform** only
delays: the next run reads whatever was missed (ADR 0006) and nothing is
overwritten (ADR 0007).

Extract retries spend API quota. Two areas hourly use 48 of the 50 daily
requests, and a retry fetches every area again, so the spare covers about one
repeat a day. A retry after a partial run also lands a second, partial run in
`raw/`: the first area written twice, under two run timestamps.

Evidence, 2026-09-22 to 26: extract failed once in 75 runs (during the
build-out); transform failed 6 times in 11, all one deterministic fault, where
each retry failed exactly as the first attempt had.

## Options considered

1. **Retry every error a few times.** Simple, but spends quota on errors that
   cannot succeed (429, a bad key), repeats deterministic faults, and delays the
   alert.
2. **Retry chosen exception classes:** extract once on network errors,
   transform on a lost warehouse race. Recovers an hour after a short blip, at
   up to the whole daily spare per retry, with duplicated partial runs.
3. **Retry only failures around a function:** the Lambda service errors
   (`Lambda.ServiceException`, `Lambda.AWSLambdaException`,
   `Lambda.SdkClientException`, `Lambda.TooManyRequestsException`), and the
   scheduler failing to start an execution. These usually mean the handler never
   ran, so a retry spends nothing.
4. **No retries at all.** Simplest; a throttle or a fault inside Lambda loses
   the hour.

## Decision

We will retry only failures around a function (option 3, chosen by the project
owner): Lambda service errors 3 times, after 2, 4 and 8 seconds, in both steps;
a failed start of an execution up to 3 times within 15 minutes, by the
scheduler. Anything a handler raises goes straight to the failure branch
(ADR 0010), and the next hourly run is its retry.

## Consequences

Easier: one rule - if our code ran, it is not retried. No retry can exhaust the
API quota, and every failure of our code is reported rather than hidden by a
retry that happened to work.

Harder: a short API or network blip loses that hour of raw history for good. A
transform failure leaves the warehouse an hour stale. Rarely, a Lambda service
error arises after the handler started, and retrying extract then spends 2
requests; a lost response to a start could likewise start a second execution.

Revisit if: the alerts show transient extract failures more than rarely; the
quota gains headroom (a paid tier, or fewer areas); or the application learns to
resume a partial run, skipping areas already written, which would make a narrow
extract retry cheap and clean.
