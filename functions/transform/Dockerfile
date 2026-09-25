# syntax=docker/dockerfile:1

# The transform Lambda's image: the application's dbt project, dbt + DuckDB, and
# a thin handler. Built for linux/arm64 by scripts/build_transform_image.ps1.
#
# A container image rather than a zip: dbt and DuckDB together are far beyond
# the 250 MB limit on an unzipped zip package; an image may be up to 10 GB.

# Pinned by digest, not only by tag: ":3.13" is republished with every patch.
# The digest also pins the runtime's boto3, which the handler's conditional
# write depends on (put_object IfMatch / IfNoneMatch; ADR 0007). Bump it
# deliberately, and rebuild and retest when you do.
ARG BASE_IMAGE=public.ecr.aws/lambda/python:3.13@sha256:60bfb942eb957677e4e3759233fa11d69780987f801e83075e88a94f8243248a

# ── Stage 1: the application source at its release tag ──────────────────────
# BuildKit clones the repository on the build host, so the image needs neither
# git nor tar. Nothing from this stage reaches the image except what is copied
# or mounted below.
FROM scratch AS app-source
ARG APP_VERSION
ADD https://github.com/Furnx/eskom-grid-observability.git#${APP_VERSION} /

# ── Stage 2: the function ────────────────────────────────────────────────────
FROM ${BASE_IMAGE}

ARG APP_VERSION
# Without a tag, the clone above would silently take the default branch.
RUN test -n "${APP_VERSION}" || { echo "APP_VERSION build argument is required" >&2; exit 1; }
LABEL org.opencontainers.image.version="${APP_VERSION}"

# DUCKDB_EXTENSION_DIRECTORY is read both here (install) and by the prod
# profile at runtime (load), so one definition serves both.
# dbt would otherwise report anonymous usage statistics and write a .user.yml
# next to profiles.yml, which is on a read-only filesystem in Lambda.
ENV DUCKDB_EXTENSION_DIRECTORY=/opt/duckdb_extensions \
    DBT_SEND_ANONYMOUS_USAGE_STATS=false

# Into the runtime's own site-packages rather than --target /var/task, so the
# dbt command is on PATH for `dbt deps` below. The [transform] extra does not
# depend on boto3, so the runtime's copy stays the one in use. The source is
# mounted, not copied: pip builds in it (rw keeps those writes out of the image).
RUN --mount=type=bind,from=app-source,target=/src,rw \
    pip install --no-cache-dir "/src[transform]"

# The dbt project, with the application's template as its profile: the prod
# target in it was written for this image.
COPY --from=app-source /dbt_project ${LAMBDA_TASK_ROOT}/dbt_project
COPY --from=app-source /dbt_project/profiles.yml.example ${LAMBDA_TASK_ROOT}/dbt_project/profiles.yml

# dbt packages (dbt_utils) are fetched now: the project directory is read-only
# at runtime, and every build needs them. package-lock.yml pins the version.
RUN cd ${LAMBDA_TASK_ROOT}/dbt_project \
    && dbt deps --profiles-dir . --log-path /tmp/dbt-deps-logs \
    && rm -rf /tmp/dbt-deps-logs

# DuckDB downloads extensions on first use unless they are already installed.
# Installing them here, for this image's platform and DuckDB version, means the
# function never depends on DuckDB's extension repository at runtime.
RUN python -c "import duckdb; duckdb.connect(config={'extension_directory': '${DUCKDB_EXTENSION_DIRECTORY}'}).execute('INSTALL httpfs; INSTALL aws')"

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.lambda_handler"]
