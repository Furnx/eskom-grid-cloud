# 0006. The transform reads only new raw files

Date: 2026-09-24
Status: Accepted

## Context

The transform runs `dbt build` against the raw landing zone in S3. As written
for local use, the staging model reads every raw file on every run. Every file
read costs two S3 requests (DuckDB sends a HEAD, then a GET — measured), at
$0.004 per 10,000 in af-south-1 (AWS Price List API). The zone grows by 1,440
files a month.

Reading everything hourly therefore costs about $0.41 more each month than the
month before: ~$9.50 a month by month 12 and ~$60 over the first year, plus Lambda
time that grows the same way (53 files already took 6.2 s from the laptop). That
contradicts ADR 0003's always-free design and the README's cost estimate.

A spike on 2026-09-24 (DuckDB 1.5.4, dbt-duckdb 1.10.1, the real bucket) showed
DuckDB skips files whose name fails a filter, but only when the filter is a
**literal** and sits **on the file read itself**: a subquery (`> (SELECT max…)`)
or a filter placed above a view that unnests the events reads every file.

## Options considered

1. **Read everything every run.** Simplest; cost and run time grow without bound.
2. **Literal cutoff in a landing model.** One incremental model is the only
   reader of S3: one row per raw file, filtered at the read by a `run_ts` cutoff
   that dbt looks up at compile time and writes into the SQL. Spike: a second run
   read 2 files instead of 53.
3. **The handler lists new keys and passes them to dbt.** Works, but moves
   incremental logic out of dbt into platform code.
4. **Re-key raw files by date** (`raw/dt=…/`) for partition pruning. Needs a
   migration of existing objects and a change to the application's sink.

## Decision

We will read raw files through a single incremental landing model,
`stg_eskom__raw_payloads`, filtered at the file read by a literal `run_ts` cutoff
(`>=` the newest already loaded, so the latest run is always re-read and a late
second area is not missed). Every other model and every dbt test reads DuckDB
tables, never S3.

## Consequences

Easier: each run reads about two files and one listing, so cost and run time stay
flat; tests stop scanning S3; a full rebuild is still one `dbt build --full-refresh`
(a single full scan, a fraction of a cent).

Harder: the pattern is easy to break silently — rewriting the cutoff as a subquery,
or moving it below an `UNNEST`, still returns correct rows while reading every file
again. The model carries a comment saying so, and a test asserts that a second run
re-reads only the latest run. The warehouse now holds a copy of every payload
(small: under a kilobyte each).

Revisit if: DuckDB learns to prune files on non-literal filters, or runs start
producing many files each.
