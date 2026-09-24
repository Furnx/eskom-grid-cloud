# Phase 2 plan — transform in the cloud

Written 2026-09-24, after an investigation and a spike against the live bucket.
Status: **approved; Part A not started.**

Phase 2 spans both repositories. **Part A** is done in a Claude Code session
opened in `eskom-grid-observability` and ends with release tag `v0.3.0`.
**Part B** is done here, after that tag exists. This file is the hand-over
between the two sessions, so it is self-contained: read it top to bottom before
starting either part, and tick items off in [ROADMAP.md](ROADMAP.md).

## Goal and milestone

Every hour, a second Lambda runs `dbt build` against the raw JSON in S3 and keeps
the warehouse (`s3://eskom-grid-<account>/warehouse/eskom_data.duckdb`)
up to date — without the laptop.

**Milestone (amended 2026-09-24):** `fct_pipeline_runs` gains a row every hour in
the cloud, and a test fixture proves events flow through to `fct_grid_events`.
The original milestone ("`fct_grid_events` grows") cannot be demonstrated yet:
no loadshedding has been scheduled since collection began on 2026-09-23, so every
payload has `events: []`.

## Decisions

| Decision | Choice | Record |
|---|---|---|
| Read cost | Only new raw files are read, through one landing model | [ADR 0006](adr/0006-transform-reads-only-new-raw-files.md) |
| Concurrent runs | Warehouse uploaded with an S3 conditional write | [ADR 0007](adr/0007-single-writer-for-the-warehouse.md) |
| Trigger until Phase 3 | A second schedule at hh:10 | here; replaced by Step Functions in Phase 3 |
| dbt project in the image | Dockerfile downloads the app source at the pinned tag | here; the app's layout is unchanged |
| `pipeline_run_log` | Dagster asset removed; `fct_pipeline_runs` derived from raw files | here |

## What the spike proved (2026-09-24)

DuckDB 1.5.4, dbt-core 1.11.11, dbt-duckdb 1.10.1 — the versions the app pins.

| Question | Result |
|---|---|
| Can DuckDB read the bucket with no keys in config? | Yes: `CREATE SECRET (TYPE s3, PROVIDER credential_chain, REGION 'af-south-1')` read all 53 files via the `eskom-admin` profile, **and** via credentials in environment variables only (how Lambda supplies them) |
| Does a filter on the file name skip S3 requests? | Yes, if it is a **literal** on the file read: 8 of 53 files, `#HEAD 8 / #GET 9` instead of `53 / 54`. A subquery cutoff, or a literal placed above a view that `UNNEST`s events, reads every file |
| Does the pattern work inside dbt? | Yes: a compile-time macro wrote `>= '20260924_150016'` into the SQL; run 2 read **2 files** instead of 53, with no duplicate rows |
| Can dbt run via its Python API with all writes redirected? | Yes: `dbtRunner().invoke([...])` with `DBT_TARGET_PATH`/`DBT_LOG_PATH` pointing elsewhere wrote **nothing** inside the project folder (Lambda's code folder is read-only; only `/tmp` is writable) |
| Can `fct_pipeline_runs` come from raw files alone? | Yes: 27 runs, including the partial manual run of 2026-09-23 13:49 shown honestly as `areas_processed = 1` |
| Do event times depend on the machine's timezone? | No: `CAST('…T16:00:00+02:00' AS TIMESTAMP)` gives `16:00` under both `Africa/Johannesburg` and `UTC` — the offset is dropped. Event times are therefore **SAST wall-clock**, while `run_ts` is **UTC**; document both |

Not yet proven (Part B): extensions loading offline from the image, the transform
role's least-privilege permissions, memory and run time inside Lambda.

## Design

```
:00  Scheduler ──▶ extract Lambda (zip) ──▶ raw/<area_id>/<run_ts>.json         (unchanged)
:10  Scheduler ──▶ transform Lambda (container image, ECR)
        1. download warehouse/eskom_data.duckdb to /tmp, remember its ETag
        2. dbt build --target prod
             stg_eskom__raw_payloads   ◀── the ONLY model that reads S3; new files only
             stg_eskom_grid_schedule, fct_grid_events, fct_pipeline_runs,
             dim_area, dim_event_type, all tests   ◀── DuckDB only
        3. upload the warehouse with If-Match: <ETag>   (ADR 0007)
```

---

## Part A — `eskom-grid-observability`, released as `v0.3.0`

Work on a feature branch; merge by pull request.

**A1. Landing model** `dbt_project/models/staging/stg_eskom__raw_payloads.sql` (new),
incremental, one row per raw file. The pattern proven in the spike:

```sql
{{ config(materialized='incremental', unique_key='source_file') }}
{%- set since = latest_loaded_run_ts() %}
SELECT
    filename                                              AS source_file,
    regexp_extract(filename, '(\d{8}_\d{6})\.json$', 1)   AS run_ts,
    _meta,
    events,
    current_timestamp                                     AS loaded_at
FROM read_json(
    {{ source('eskom_data', 'raw_eskom_grid_schedules') }},
    filename = true,
    columns = {
        '_meta':  'STRUCT(area_id VARCHAR, area_name VARCHAR, municipality VARCHAR, province VARCHAR)',
        'events': 'STRUCT("start" VARCHAR, "end" VARCHAR, note VARCHAR)[]'
    }
)
-- Keep this filter a LITERAL and keep it HERE, on the file read (ADR 0006 in
-- eskom-grid-cloud): as a subquery, or above an UNNEST, it still returns the
-- right rows but makes DuckDB read every file in the bucket again.
WHERE regexp_matches(filename, '\d{8}_\d{6}\.json$')
{% if since %}
  AND regexp_extract(filename, '(\d{8}_\d{6})\.json$', 1) >= '{{ since }}'
{% endif %}
```

The `regexp_matches` guard drops files without a run timestamp in their name
(the two legacy flat files in the local `data/raw`).

**A2. Macro** `dbt_project/macros/latest_loaded_run_ts.sql` (new):

```sql
{% macro latest_loaded_run_ts() %}
    {#- Newest run_ts already loaded, returned as a string so it is written into
        the SQL as a literal: DuckDB only skips files for literals. -#}
    {%- if execute and is_incremental() -%}
        {%- set result = run_query('select max(run_ts) from ' ~ this) -%}
        {{- return(result.columns[0].values()[0]) -}}
    {%- endif -%}
    {{- return(none) -}}
{% endmacro %}
```

**A3. `stg_eskom_grid_schedule`** unnests from `ref('stg_eskom__raw_payloads')`
instead of reading the source; add `run_ts` to its output. Its column tests then
run against DuckDB, not S3. Document `start_time`/`end_time` as SAST wall-clock.

**A4. `fct_pipeline_runs`** is rebuilt from the landing table, grouped by
`run_ts`, keeping its column names and `run_id` (surrogate of `run_ts`):
`run_timestamp = strptime(run_ts, '%Y%m%d_%H%M%S')`, `areas_processed = count(*)`,
`total_events_found = sum(len(events))`, `zero_event_areas` = `string_agg` of
area names where `len(events) = 0`. Materialise as a table (small, cheap).

**A5. Remove the Dagster `pipeline_run_log` asset** from `src/eskom_grid/assets.py`
and any references; the local Dagster graph keeps working through the dbt assets.

**A6. `src/eskom_grid/transform.py`** (new): `run_transform(project_dir, *, profiles_dir,
target, target_path, log_path, full_refresh=False, log=None)`. It runs `dbt build`
through `dbt.cli.main.dbtRunner`, passes `--target-path`/`--log-path` flags (so
callers can point them at `/tmp`), returns a small summary (nodes passed / failed),
and raises a `TransformError` naming the failed nodes. dbt is imported **inside**
the function, so `eskom_grid.extract` stays free of it. Configuration is passed in,
never read from the environment — the same rule as `run_extraction`.

**A7. `pyproject.toml`**: add a `[transform]` extra pinning `dbt-core==1.11.*`,
`dbt-duckdb==1.10.*`, `duckdb==1.5.*`; set `version = "0.3.0"` in the same commit
that is tagged (at v0.2.0 the metadata still said 0.1.0).

**A8. `dbt_project/profiles.yml.example`, `prod` target** (the image copies this
file, so it must be correct):

```yaml
    prod:
      type: duckdb
      path: "{{ env_var('ESKOM_DUCKDB_PATH', '/tmp/eskom_data.duckdb') }}"
      threads: 1
      extensions: [httpfs, aws]
      settings:
        extension_directory: "{{ env_var('DUCKDB_EXTENSION_DIRECTORY', '/opt/duckdb_extensions') }}"
      secrets:
        - type: s3
          provider: credential_chain
          region: af-south-1
```

**A9. Tests**
- Raw fixtures under `tests/fixtures/raw/<area_id>/<run_ts>.json`, including one
  payload with a realistic event (`"start": "2026-09-24T16:00:00+02:00"`,
  `"note": "Stage 2"`).
- A pytest that runs `run_transform` against a temporary copy with a local
  `ESKOM_RAW_GLOB`: build once; add a newer fixture; build again; assert that rows
  from older files kept their original `loaded_at` (they were not re-read), that
  there are no duplicates, that `fct_pipeline_runs` gained a row, and that the event
  reached `fct_grid_events`.
- Extend the import-boundary test: importing the extraction path must not import
  `dbt` or `duckdb`.

**Release:** merge, then tag `v0.3.0` and push the tag.

---

## Part B — `eskom-grid-cloud`

**B1. `infra/registry.tf`** (new): ECR repository `eskom-grid-transform`;
immutable tags; scan on push; lifecycle policy keeping the last 3 images;
`force_delete = true` (images are rebuildable, unlike raw history — ADR 0005).

**B2. `functions/transform/Dockerfile`** (new): base
`public.ecr.aws/lambda/python:3.13`, built for `linux/arm64`. Download the app's
source archive for `APP_VERSION` from GitHub; `pip install ".[transform]"` and a
pinned boto3 new enough for `put_object(IfMatch=…)`; copy `dbt_project/` into the
image with `profiles.yml` made from `profiles.yml.example`; run `dbt deps` at build
time; install the `httpfs` and `aws` DuckDB extensions at build time into
`/opt/duckdb_extensions`; add `handler.py`.

**B3. `functions/transform/handler.py`** (new, thin): download the warehouse to
`/tmp` (if absent: first run, full build) and keep its ETag; call `run_transform`
with `/tmp` paths; upload with `IfMatch` (or `IfNoneMatch='*'` on first run);
let exceptions propagate. Start from a clean `/tmp` — warm environments keep it.

**B4. `scripts/build_transform_image.ps1`** (new): read `app_version` from
`infra/variables.tf` (as `build_lambda.ps1` does); `docker buildx build
--platform linux/arm64 --provenance=false` (Lambda rejects the image index that
provenance attestations create); tag `<app_version>-<platform commit>`; log in to
ECR; push; record the tag in `build/` for Terraform.

**B5. `compute.tf`**: transform function (`package_type = "Image"`, image by
digest, arm64, start at 1024 MB / 300 s and tune from the REPORT lines), its log
group (14 days), environment: `ESKOM_RAW_GLOB`, warehouse URI,
`DUCKDB_EXTENSION_DIRECTORY`.

**B6. `iam.tf`**: transform role — `s3:ListBucket` on the bucket with condition
`s3:prefix` like `raw/*`; `s3:GetObject` on `raw/*`; `s3:GetObject` and
`s3:PutObject` on `warehouse/*`; its own log stream. Verify with
`aws iam simulate-principal-policy`. Check whether Lambda can pull the image
without a repository policy; add one (`ecr:BatchGetImage`,
`ecr:GetDownloadUrlForLayer` for `lambda.amazonaws.com`) if not.

**B7. `orchestration.tf`**: schedule `cron(10 * * * ? *)` for the transform;
the scheduler role may invoke both functions. Retries are harmless here (no API
quota; idempotent models; conditional upload).

**B8. `storage.tf`**: split the lifecycle rule — `raw/` keeps non-current versions
30 days; `warehouse/` only 3 (rewritten hourly, and rebuildable from `raw/`).

**B9. Docs**: README deploy order (first time: `terraform apply
-target=aws_ecr_repository.transform`, then build and push, then a full apply),
cost table (ECR storage; S3 requests), diagram and status; `outputs.tf`; ROADMAP.

**B10. Verify**: run the image locally with the Lambda runtime emulator built into
the base image; deploy; after hh:10 confirm the warehouse object, a clean REPORT
line and a new `fct_pipeline_runs` row; confirm again an hour later.

---

## Order of work

1. Part A in the app repository → merge → tag `v0.3.0`.
2. Here: `app_version = "v0.3.0"`; rebuild and redeploy **extract** first (same
   code path, new tag) and confirm the next hourly run.
3. Part B.

## Risks

- **Breaking ADR 0006 silently**: editing the landing model's filter can restore
  full scans with correct results. Guarded by the A9 test and the model comment.
- **Image pull permissions** (B6) and **extensions loading without network**
  (B2): unproven until the image runs.
- **Cold start**: a container with dbt is far larger than the extract zip; expect
  seconds of init — acceptable hourly, measure it.
- **First run**: no warehouse exists yet; the handler's create path
  (`IfNoneMatch='*'`) must be exercised once, deliberately.
