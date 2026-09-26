# Phase 2 plan — transform in the cloud

Written 2026-09-24, after an investigation and a spike against the live bucket.
Status: **Part A done** — released as `v0.3.0` (commit `2f70d6b`, 2026-09-25),
patched as `v0.3.1` (commit `bf9c3a2`, same day) after the image tests in Part B
exposed two faults (see "Part B, chunk 1 results"), and as `v0.3.2` (commit
`8b5fe0d`, 2026-09-26) after the first real Lambda run exposed a third (see
"Chunk 2 results"). Order of work step 2 done: the extract function was
redeployed from `v0.3.0` (2026-09-25 14:30 SAST), `v0.3.1` (19:07 SAST) and
`v0.3.2` (2026-09-26 13:11 SAST). Part A's session confirmed two points for
Part B: `pipeline_run_log` no longer exists anywhere (neither asset nor table),
and `dbt deps` at image build time is required, not optional (see B2).
**Part B:** chunk 1 (image, handler, build script, local tests) done 2026-09-25;
chunk 2 (ECR, transform Lambda, role, schedule, lifecycle split) deployed
2026-09-26, first successful cloud run 13:13 SAST; **chunk 3 next** (the
two-run milestone, memory tuning, docs).

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

### Chunk 1 results (2026-09-25)

Built: `functions/transform/Dockerfile`, `functions/transform/handler.py`,
`scripts/build_transform_image.ps1` (build only; its smoke tests run offline,
read-only and as a non-root user, and compile through the image's own profile).
Image `v0.3.1-a70261b`: 265 MB compressed (what ECR stores and Lambda pulls),
about 800 MB unpacked.

Testing the image the way Lambda runs it found two faults in app `v0.3.0` that a
laptop cannot show, both fixed in `v0.3.1` with regression tests:

- **Extensions not found.** The prod profile set `extension_directory` under
  `settings`, which dbt-duckdb applies only after it has installed the
  extensions; DuckDB fell back to `~/.duckdb`, read-only in Lambda. Now under
  `config_options`.
- **Database left open.** After `run_transform()` returned, the tables were still
  in the `.wal` beside a 12 KB file, and a warm process reused its handle to a
  file the handler had since replaced. The handler would have uploaded an empty
  warehouse every hour. `run_transform()` now closes dbt-duckdb's connection.

Then, in the Lambda runtime emulator against the live bucket (temporary
credentials; the user ran the writes):

| Run | Result |
|---|---|
| First (no warehouse) | Created `warehouse/eskom_data.duckdb` with `IfNoneMatch='*'`: 105 raw files, 53 runs, 40/40 nodes. Landing model 14.7 s |
| Second, same warm container | `IfMatch` upload; compiled cutoff `>= '20260925_170016'` (a literal); landing model 2.2 s |
| Conflict check | Wrong ETag and `IfNoneMatch='*'` over the existing object: both `412 PreconditionFailed` → `WarehouseConflictError`; object and version count unchanged |

Carried into chunk 2:

- **B6, first-run detection:** S3 answers a GetObject for a missing key with
  404 only if the caller may `s3:ListBucket` *for that key's prefix*;
  otherwise 403. Tested 2026-09-25 with `sts get-federation-token` session
  policies (reads of a nonexistent key only): `s3:prefix` limited to `raw/*`
  gives AccessDenied for a missing `warehouse/` key; `["raw/*", "warehouse/*"]`
  gives NoSuchKey, as does an unconditioned `ListBucket`. So the condition must
  name both prefixes.
- **B1, pull permission:** Lambda needs `ecr:BatchGetImage` and
  `ecr:GetDownloadUrlForLayer`, granted by the execution role or the repository
  policy. If neither does, Lambda adds a repository policy itself, outside
  Terraform (AWS docs, "Create a Lambda function using a container image").
  Declare it, and make the function depend on it.
- **B1, lifecycle:** a function whose image is deleted from ECR enters the
  `Failed` state. "Keep the last N" counts pushes, not deployments, so it must
  never be able to expire the deployed image.
- **B5, memory:** the emulator does not measure memory (it reports its 3008 MB
  default). Start at 1024 MB and tune from real REPORT lines. Emulated arm64
  timings (slower than Graviton): init 9.5 s, first run 101 s, warm run 43 s.
- **B5, environment:** `DUCKDB_EXTENSION_DIRECTORY` is set in the image, where
  the extensions are installed; the function needs only `ESKOM_RAW_GLOB` and
  `ESKOM_WAREHOUSE_URI`.
- **B8, sizes:** the warehouse file alternates between about 1.8 and 3.6 MB
  from one run to the next (DuckDB reuses freed blocks; tested over 8 runs), so
  each hourly version is a few MB. Under the current 30-day rule that is ~2 GB
  of non-current versions; the split matters.
- **B1/B9, ECR:** ~265 MB per image, so "keep the last 3" is ~0.8 GB stored;
  ECR storage in af-south-1 is $0.10 per GB-month (AWS Pricing API), so about
  $0.08 a month against the credits.
- **B4, push:** tags are `<app_version>-<commit>` and ECR tags will be
  immutable, so pushing a second build of the same commit must be refused or
  skipped, not overwrite.

### Chunk 2 results (2026-09-26)

Deployed: `infra/registry.tf` (ECR repository, keep-3 rule, repository policy
for this one function), the transform function, role and log group, the hh:10
schedule (retries explicitly 0), and the split lifecycle rule; `-Push` on the
build script. After the apply, `terraform plan` reported no changes and ECR held
only the declared repository policy; `simulate-principal-policy` confirmed the
role's 5 intended allows and 6 tested denies.

- **A third fault, found only in Lambda:** the first run failed with
  `[Errno 2] No such file or directory` in `multiprocessing` (Lambda has no
  `/dev/shm`, so no POSIX semaphores). Fixed in app `v0.3.2` (thread locks
  when no semaphore can be made). The image smoke tests now run with
  `--ipc none` and build through `run_transform()` itself.
- **First successful cloud run, 13:13 SAST** (image `v0.3.2-e47b7c0`, digest
  `7254ea6b…`): 40/40; init 0.57 s; duration 21.1 s (about 6 s importing dbt,
  10 s building); **max memory 401 MB of 1024**; read 38 new raw files of 141;
  warehouse 1,847,296 bytes. The downloaded copy matches the bucket: 141
  landing rows, 71 runs.
- **Deploy timing:** the 13:10 run and Lambda's first retry (3 s after the
  update completed) still ran the old image; the second retry ran v0.3.2. Avoid
  deploying in the minute a schedule fires.

Carried into chunk 3: the two-run milestone (14:10 and 15:10 SAST onwards);
memory, from the REPORT lines (401 MB used); B9's docs; and whether the handler
should log the app version at the start of each run (it would have made the
deploy timing above obvious).

**B1. `infra/registry.tf`** (new): ECR repository `eskom-grid-transform`;
immutable tags; scan on push; lifecycle policy keeping the last 3 images;
`force_delete = true` (images are rebuildable, unlike raw history — ADR 0005).

**B2. `functions/transform/Dockerfile`** (new; done in chunk 1): base
`public.ecr.aws/lambda/python:3.13` pinned by digest, built for `linux/arm64`.
BuildKit clones the app at `APP_VERSION` (`ADD <repo>.git#<tag>`; the image has
no git or tar); `pip install ".[transform]"`. boto3 is the base image's own
(1.42.97, which supports `put_object(IfMatch=…)`), pinned by the digest rather
than installed a second time; copy `dbt_project/` into the
image with `profiles.yml` made from `profiles.yml.example`; run `dbt deps` at build
time — **required**: `fct_pipeline_runs` uses `dbt_utils.generate_surrogate_key`, so
without `dbt_packages/` in the image every build fails; install the `httpfs` and `aws` DuckDB extensions at build time into
`/opt/duckdb_extensions`; add `handler.py`.

**B3. `functions/transform/handler.py`** (new, thin; done in chunk 1): download the warehouse to
`/tmp` (if absent: first run, full build) and keep its ETag; call `run_transform`
with `/tmp` paths; upload with `IfMatch` (or `IfNoneMatch='*'` on first run);
let exceptions propagate. Start from a clean `/tmp` — warm environments keep it.

**B4. `scripts/build_transform_image.ps1`** (new; build done in chunk 1, push in chunk 2): read `app_version` from
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
"-target=aws_ecr_repository.transform"` - quoted, or PowerShell splits it at the
dot - then build and push, then a full apply),
cost table (ECR storage; S3 requests), diagram and status; `outputs.tf`; ROADMAP.
Once the milestone is met, revise the local `docs/GUIDE.md` (never committed) with
a Phase 2 part: WAL and checkpoints, S3 conditional writes, image tags vs
digests, and bringing its version numbers up to date.

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
