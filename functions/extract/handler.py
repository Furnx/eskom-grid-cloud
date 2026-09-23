"""AWS Lambda entry point for the extraction step.

The mirror image of the Dagster asset in the application repository: it resolves
configuration from the environment, calls the same pure function, and returns a
summary. No extraction logic lives here — if it did, the two environments could
drift apart.

Environment:
    ESKOM_RAW_SINK       s3://<bucket>/raw — where payloads are written.
    ESKOM_API_KEY_PARAM  SSM parameter NAME holding the EskomSePush key.

The key is fetched at runtime rather than passed as an environment variable,
because Lambda environment variables are visible to anyone who can describe the
function. The execution role may read this one parameter and nothing else.
"""

import logging
import os

import boto3

from eskom_grid.config import load_areas
from eskom_grid.extract import run_extraction
from eskom_grid.sinks import sink_from_uri

# The Lambda runtime attaches a handler to the root logger but leaves the level
# above INFO, so the application's log lines would otherwise be dropped.
logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger("eskom_grid")

# Created at import time so the client is reused across warm invocations.
_ssm = boto3.client("ssm")


def _read_api_key() -> str:
    parameter_name = os.environ["ESKOM_API_KEY_PARAM"]
    response = _ssm.get_parameter(Name=parameter_name, WithDecryption=True)
    return response["Parameter"]["Value"]


def lambda_handler(event, context):
    """Run one extraction. Returns a JSON-serialisable summary of the run.

    Exceptions are deliberately allowed to propagate: Lambda records the failure
    and, from Phase 3, Step Functions matches on the exception class name
    (RateLimitError, ApiError) to decide whether retrying is worthwhile.
    """
    sink = sink_from_uri(os.environ["ESKOM_RAW_SINK"])
    areas = load_areas()

    summary = run_extraction(areas, _read_api_key(), sink, log=log)

    return {
        "run_ts": summary.run_ts,
        "areas_processed": summary.areas_processed,
        "total_events": summary.total_events,
        "zero_event_areas": summary.zero_event_areas,
        "written": summary.written,
    }
