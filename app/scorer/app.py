"""Lambda entry point: routes API Gateway requests to the scorer and storage."""

import base64
import json
import os
import re
import time
from datetime import datetime, timezone

import store
from scoring import BRANDS, score_domain

BRAND_RE = re.compile(r"^[a-z0-9]{3,30}$")
STATE_MACHINE_ARN = os.environ.get("STATE_MACHINE_ARN")
SCAN_COOLDOWN = 900  # seconds: at most one "Scan now" per 15 minutes


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def _json_body(event):
    raw = event.get("body")
    if not raw:
        return {}
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    body = json.loads(raw)
    if not isinstance(body, dict):
        raise ValueError("body must be a JSON object")
    return body


def score(event):
    # GET /score?domain=... or POST /score with {"domain": "..."}
    domain = (event.get("queryStringParameters") or {}).get("domain")
    if not domain:
        try:
            domain = _json_body(event).get("domain")
        except ValueError:
            return _response(400, {"error": 'body must be JSON like {"domain": "example.com"}'})
    if not domain:
        return _response(400, {"error": "missing 'domain'"})

    try:
        result = score_domain(domain, store.list_brands())
    except ValueError as err:
        return _response(400, {"error": str(err)})
    store.save_finding(result)
    return _response(200, result)


def get_brands(event):
    return _response(200, {"builtin": BRANDS, "custom": store.list_brands()})


def add_brand(event):
    try:
        name = str(_json_body(event).get("name", "")).strip().lower()
    except ValueError:
        name = ""
    if not BRAND_RE.match(name):
        return _response(400, {"error": 'send JSON like {"name": "acme"}: 3-30 letters or digits'})
    store.add_brand(name)
    return _response(201, {"added": name})


def remove_brand(event):
    name = str((event.get("pathParameters") or {}).get("name", "")).lower()
    if not BRAND_RE.match(name):
        return _response(400, {"error": "brand names are 3-30 letters or digits"})
    store.remove_brand(name)
    return _response(200, {"removed": name})


def get_findings(event):
    return _response(200, {"findings": store.list_findings()})


def scan_now(event):
    """Start the scan workflow, at most once per cooldown window.

    The cooldown needs no database: the execution is named after the current 15-minute
    window, and Step Functions refuses to start a second execution with the same name.
    """
    if not STATE_MACHINE_ARN:
        return _response(503, {"error": "scanning is not configured"})
    import boto3
    sfn = boto3.client("stepfunctions")

    window = int(time.time()) // SCAN_COOLDOWN
    retry_at = datetime.fromtimestamp((window + 1) * SCAN_COOLDOWN, timezone.utc)
    cooling = _response(429, {
        "error": "a scan was started in the last few minutes",
        "retry_at": retry_at.isoformat(timespec="seconds"),
    })
    try:
        started = sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=f"scan-now-{window}",
            input=json.dumps({"trigger": "scan-now"}),
        )
    except sfn.exceptions.ExecutionAlreadyExists:
        return cooling  # this window's scan already ran
    # Same name while it's still running: AWS hands back the existing execution
    if time.time() - started["startDate"].timestamp() > 10:
        return cooling
    return _response(202, {"started": True, "execution": started["executionArn"].split(":")[-1]})


ROUTES = {
    "GET /score": score,
    "POST /score": score,
    "GET /brands": get_brands,
    "POST /brands": add_brand,
    "DELETE /brands/{name}": remove_brand,
    "GET /findings": get_findings,
    "POST /scan": scan_now,
}


def handler(event, context):
    route = ROUTES.get(event.get("routeKey", "GET /score"))
    if route is None:
        return _response(404, {"error": "not found"})
    return route(event)
