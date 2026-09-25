"""AWS Lambda entry point for the transform step.

Moves the warehouse between S3 and /tmp and calls the application's
run_transform() in between. No modelling logic lives here: the dbt project, and
the decision about which raw files to read (ADR 0006), belong to the application.

Environment:
    ESKOM_RAW_GLOB       s3://<bucket>/raw/**/*.json - read by the dbt project's
                         source definition, not by this file.
    ESKOM_WAREHOUSE_URI  s3://<bucket>/warehouse/eskom_data.duckdb

The warehouse is replaced with an S3 conditional write (ADR 0007): the upload
succeeds only if the object is still the one this run downloaded, or on the
first run, only if there is still no object at all. Two overlapping runs can
therefore never silently overwrite each other; the later one fails instead.
"""

import logging
import os
import shutil
from pathlib import Path
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

from eskom_grid.transform import run_transform

# The Lambda runtime attaches a handler to the root logger but leaves the level
# above INFO, so the application's log lines would otherwise be dropped.
logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger("eskom_grid")

# Created at import time so the client is reused across warm invocations.
_s3 = boto3.client("s3")

# Baked into the image next to this file (see the Dockerfile). Read-only.
PROJECT_DIR = Path(__file__).resolve().parent / "dbt_project"

# /tmp is the only writable place in Lambda, and a warm environment keeps it
# between invocations, so every run starts by emptying its own directory.
WORK_DIR = Path("/tmp/transform")

# S3 answers 412 when the condition fails, and 409 when another conditional
# write to the same key is in flight at the same moment. Both mean "someone
# else wrote the warehouse".
_CONFLICT_CODES = {"PreconditionFailed", "ConditionalRequestConflict"}


class WarehouseConflictError(Exception):
    """The warehouse in S3 changed while this run was building its copy.

    Nothing was overwritten. The next run starts from the newer warehouse and
    reads any raw files it is missing, so no data is lost by giving up here.
    """


def _split_s3_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    key = parsed.path.lstrip("/")
    if parsed.scheme != "s3" or not parsed.netloc or not key:
        raise ValueError(f"Expected s3://<bucket>/<key>, got {uri!r}.")
    return parsed.netloc, key


def _download(bucket: str, key: str, path: Path) -> str | None:
    """Download the warehouse and return its ETag, or None if there is none yet.

    One GetObject rather than a HEAD followed by a download: the ETag then
    describes exactly the bytes that were read, even if the object is replaced
    a moment later.
    """
    try:
        response = _s3.get_object(Bucket=bucket, Key=key)
    except ClientError as error:
        if error.response["Error"]["Code"] == "NoSuchKey":
            return None
        raise
    with open(path, "wb") as file:
        shutil.copyfileobj(response["Body"], file)
    return response["ETag"]


def _upload(path: Path, bucket: str, key: str, etag: str | None) -> str:
    """Replace the warehouse only if it is still the one that was downloaded."""
    condition = {"IfMatch": etag} if etag else {"IfNoneMatch": "*"}
    try:
        with open(path, "rb") as body:
            response = _s3.put_object(Bucket=bucket, Key=key, Body=body, **condition)
    except ClientError as error:
        if error.response["Error"]["Code"] in _CONFLICT_CODES:
            raise WarehouseConflictError(
                f"s3://{bucket}/{key} changed during this run; not overwritten."
            ) from error
        raise
    return response["ETag"]


def lambda_handler(event, context):
    """Run one transform. Returns a JSON-serialisable summary of the run.

    Exceptions are deliberately allowed to propagate: Lambda records the failure
    and, from Phase 3, Step Functions matches on the exception class name
    (TransformError, WarehouseConflictError) to decide what to do next.
    """
    # Read by dbt rather than here, but checked here: unset, the source falls
    # back to a local path and the run would fail later, less clearly.
    if not os.environ.get("ESKOM_RAW_GLOB", "").startswith("s3://"):
        raise ValueError("ESKOM_RAW_GLOB must be set to s3://<bucket>/raw/**/*.json.")
    bucket, key = _split_s3_uri(os.environ["ESKOM_WAREHOUSE_URI"])

    shutil.rmtree(WORK_DIR, ignore_errors=True)
    WORK_DIR.mkdir(parents=True)
    db_path = WORK_DIR / "eskom_data.duckdb"

    etag = _download(bucket, key, db_path)
    log.info("No warehouse yet: first run, full build." if etag is None
             else f"Warehouse downloaded ({db_path.stat().st_size} bytes, ETag {etag}).")

    # The prod profile takes the database path from this variable.
    os.environ["ESKOM_DUCKDB_PATH"] = str(db_path)
    summary = run_transform(
        PROJECT_DIR,
        target="prod",
        target_path=WORK_DIR / "target",
        log_path=WORK_DIR / "logs",
        log=log,
    )

    new_etag = _upload(db_path, bucket, key, etag)
    log.info(f"Warehouse uploaded ({db_path.stat().st_size} bytes, ETag {new_etag}).")

    return {
        "first_run": etag is None,
        "total_nodes": summary.total_nodes,
        "passed": summary.passed,
        "failed": summary.failed,
        "skipped": summary.skipped,
        "warehouse_etag": new_etag,
    }
