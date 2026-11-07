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


def remove_brand(name):
    if BRANDS_TABLE:
        _table(BRANDS_TABLE).delete_item(Key={"name": name})


def save_finding(result):
    """Save a manual /score result, unless the scan already tracks this domain in more detail."""
    if not FINDINGS_TABLE:
        return
    from botocore.exceptions import ClientError
    try:
        _table(FINDINGS_TABLE).put_item(
            Item={
                **result,
                "source": "manual",
                "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            },
            ConditionExpression="attribute_not_exists(#src) OR #src <> :scan",
            ExpressionAttributeNames={"#src": "source"},
            ExpressionAttributeValues={":scan": "scan"},
        )
    except ClientError as err:
        if err.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise


def get_finding(domain):
    if not FINDINGS_TABLE:
        return None
    return _table(FINDINGS_TABLE).get_item(Key={"domain": domain}).get("Item")


def save_scan_finding(item):
    if FINDINGS_TABLE:
        _table(FINDINGS_TABLE).put_item(Item=item)


def list_tracked(brand):
    """Domains a previous scan found for this brand."""
    if not FINDINGS_TABLE:
        return []
    return sorted(i["domain"] for i in _scan_all(FINDINGS_TABLE)
                  if i.get("source") == "scan" and i.get("brand") == brand)


def list_findings(limit=100):
    """Riskiest first; newest first among equal scores."""
    if not FINDINGS_TABLE:
        return []
    items = sorted(_scan_all(FINDINGS_TABLE), key=lambda i: i["checked_at"], reverse=True)
    items.sort(key=lambda i: i["score"], reverse=True)  # stable sort keeps the date order
    # DynamoDB returns numbers as Decimal, which json can't serialise
    return [{**i, "score": int(i["score"])} for i in items[:limit]]
