# 0002. Dagster stays local; Step Functions orchestrates production

Date: 2026-09-21
Status: Proposed

<!--
Write this ADR yourself, in your own words. Delete these comments when you are
done and change Status to Accepted. Keep it under a page. Prompts per section:

Context
  - What does Dagster actually consist of at runtime? (three always-on things)
  - What is the workload's shape — how much of each hour is it actually working?
  - What did you already experience locally that hints at the operational cost
    of running Dagster's daemon and metadata database yourself?
  - What does production actually NEED from an orchestrator here?
    What does development need? Are those the same requirements?

Options considered
  - Dagster OSS on a free VM — what would you own?
  - Dagster's hosted product — what does it cost?
  - A managed state machine + scheduler — what do you get, what do you lose?

Decision
  - One or two sentences. "We will …"

Consequences
  - What is easier now?
  - What did you give up? Name the lock-in honestly.
  - Under what conditions would you reverse this?
-->

## Context

## Options considered

## Decision

## Consequences
