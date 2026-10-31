"""Lambda entry point: turns an API Gateway request into a domain score."""

import base64
import json

from scoring import score_domain


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    # Accept GET /score?domain=... or POST /score with {"domain": "..."}
    domain = (event.get("queryStringParameters") or {}).get("domain")

    if not domain and event.get("body"):
        raw = event["body"]
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode()
        try:
            domain = json.loads(raw).get("domain")
        except (ValueError, AttributeError):
            return _response(400, {"error": 'body must be JSON like {"domain": "example.com"}'})

    if not domain:
        return _response(400, {"error": "missing 'domain'"})

    try:
        return _response(200, score_domain(domain))
    except ValueError as err:
        return _response(400, {"error": str(err)})
