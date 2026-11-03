"""Lambda entry point: routes API Gateway requests to the scorer and storage."""

import base64
import json
import re

import store
from scoring import BRANDS, score_domain

BRAND_RE = re.compile(r"^[a-z0-9]{3,30}$")


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


def get_findings(event):
    return _response(200, {"findings": store.list_findings()})


ROUTES = {
    "GET /score": score,
    "POST /score": score,
    "GET /brands": get_brands,
    "POST /brands": add_brand,
    "GET /findings": get_findings,
}


def handler(event, context):
    route = ROUTES.get(event.get("routeKey", "GET /score"))
    if route is None:
        return _response(404, {"error": "not found"})
    return route(event)
