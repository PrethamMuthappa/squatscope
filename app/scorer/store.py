"""DynamoDB storage for user brands and scan findings.

Table names come from environment variables set by Terraform. When they are
not set (unit tests, local runs) storage is skipped, so the scorer still works.
"""

import os
from datetime import datetime, timezone

BRANDS_TABLE = os.environ.get("BRANDS_TABLE")
FINDINGS_TABLE = os.environ.get("FINDINGS_TABLE")

_tables = {}


def _table(name):
    # boto3 ships with the Lambda base image; imported lazily so tests don't need it
    if name not in _tables:
        import boto3
        _tables[name] = boto3.resource("dynamodb").Table(name)
    return _tables[name]


def _scan_all(name):
    table, kwargs, items = _table(name), {}, []
    while True:
        page = table.scan(**kwargs)
        items.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def list_brands():
    if not BRANDS_TABLE:
        return []
    return sorted(item["name"] for item in _scan_all(BRANDS_TABLE))


def add_brand(name):
    if BRANDS_TABLE:
        _table(BRANDS_TABLE).put_item(Item={
            "name": name,
            "added_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        })


def save_finding(result):
    """Keep the latest score per domain."""
    if FINDINGS_TABLE:
        _table(FINDINGS_TABLE).put_item(Item={
            **result,
            "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        })


def list_findings(limit=50):
    if not FINDINGS_TABLE:
        return []
    items = sorted(_scan_all(FINDINGS_TABLE), key=lambda i: i["checked_at"], reverse=True)
    # DynamoDB returns numbers as Decimal, which json can't serialise
    return [{**i, "score": int(i["score"])} for i in items[:limit]]
