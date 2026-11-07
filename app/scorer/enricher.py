"""Enricher Lambda: checks each queued domain, scores it and compares it with last time.

Triggered by SQS in small batches. Lookups are passive only: DNS (over HTTPS) and RDAP
(registration records). The suspicious sites themselves are never visited.

Failed messages are reported back individually, so SQS retries only those. After 3
failed attempts SQS moves a message to the dead-letter queue.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import store
from scoring import risk_level, score_domain

DOH_URL = "https://cloudflare-dns.com/dns-query"
RDAP_URL = "https://rdap.org/domain/"
NXDOMAIN = 3
EVENT_BUS = os.environ.get("EVENT_BUS_NAME")


def dns(name, rtype):
    """(status, answers) from DNS-over-HTTPS. Network errors raise, so SQS retries."""
    url = DOH_URL + "?" + urllib.parse.urlencode({"name": name, "type": rtype})
    req = urllib.request.Request(url, headers={"accept": "application/dns-json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.load(resp)
    return data.get("Status"), data.get("Answer", [])


def registration_date(domain):
    """When the domain was registered, from RDAP. None if unknown (RDAP is best effort)."""
    try:
        req = urllib.request.Request(RDAP_URL + domain, headers={"accept": "application/rdap+json"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, ValueError, OSError) as err:
        log("rdap lookup failed", domain=domain, error=str(err))
        return None
    for event in data.get("events", []):
        if event.get("eventAction") == "registration":
            return event.get("eventDate")
    return None


def lookup(domain):
    """Facts about a domain, or None if it isn't registered."""
    status, a_records = dns(domain, "A")
    if status == NXDOMAIN:
        return None
    _, mx_records = dns(domain, "MX")
    return {
        "resolves": any(r.get("type") == 1 for r in a_records),
        "has_mail": any(r.get("type") == 15 for r in mx_records),
        "registered_at": registration_date(domain),
    }


def days_since(iso, now):
    try:
        then = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None
    return (now - then).days


def assess(domain, brand, facts, previous, now):
    """Score a registered domain and work out what changed since the last scan."""
    result = score_domain(domain, [brand])
    score, reasons = result["score"], [r for r in result["reasons"] if r != "no warning signs found"]

    age = days_since(facts.get("registered_at"), now)
    if age is not None and age <= 30:
        score += 15
        reasons.append(f"registered {age} days ago")
    if facts["has_mail"]:
        score += 15
        reasons.append("can send email (has mail servers)")
    if facts["resolves"]:
        score += 5
        reasons.append("points to a server")
    score = min(score, 100)

    stamp = now.isoformat(timespec="seconds")
    changes = []
    if previous is None or previous.get("source") != "scan":
        status = "new"
    else:
        if facts["has_mail"] and not previous.get("has_mail"):
            changes.append("gained mail servers")
        if facts["resolves"] and not previous.get("resolves"):
            changes.append("now points to a server")
        if score - int(previous.get("score", 0)) >= 10:
            changes.append(f"risk rose from {int(previous['score'])} to {score}")
        status = "changed" if changes else "unchanged"

    return {
        "domain": domain,
        "brand": brand,
        "source": "scan",
        "score": score,
        "risk": risk_level(score),
        "reasons": reasons or ["no warning signs found"],
        **facts,
        "status": status,
        "changes": changes,
        "checked_at": stamp,
        "first_seen": previous.get("first_seen", stamp) if previous and status != "new" else stamp,
        "last_changed": stamp if status in ("new", "changed") else previous.get("last_changed", stamp),
    }


def defang(domain):
    """'evil.com' -> 'evil[.]com', so nobody can click it in an email."""
    return domain.replace(".", "[.]")


def finding_event(item):
    """EventBridge event for a new or changed finding. Rules on the bus decide who hears about it."""
    return {
        "Source": "squatscope.scan",
        "DetailType": "Finding",
        "EventBusName": EVENT_BUS,
        "Detail": json.dumps({
            "domain": item["domain"],
            "defanged": defang(item["domain"]),
            "brand": item["brand"],
            "score": item["score"],
            "risk": item["risk"],
            "status": item["status"],
            # Plain-text versions, so the alert email reads well
            "changes_text": "; ".join(item["changes"]) or "first time seen",
            "reasons_text": "; ".join(item["reasons"]),
            "first_seen": item["first_seen"],
            "last_changed": item["last_changed"],
        }),
    }


def publish(item):
    if not EVENT_BUS:  # unit tests and local runs
        return
    import boto3
    resp = boto3.client("events").put_events(Entries=[finding_event(item)])
    if resp.get("FailedEntryCount"):
        raise RuntimeError(f"EventBridge rejected the event: {resp['Entries']}")


def process(message):
    domain, brand = message["domain"], message["brand"]
    facts = lookup(domain)
    if facts is None:
        return "unregistered"
    item = assess(domain, brand, facts, store.get_finding(domain), datetime.now(timezone.utc))
    # Publish before saving: if the save then fails, the retry sends a duplicate alert.
    # Saving first would be worse: the retry would see "unchanged" and the alert would be lost.
    if item["status"] in ("new", "changed"):
        publish(item)
    store.save_scan_finding(item)
    log("domain checked", domain=domain, score=item["score"], status=item["status"])
    return item["status"]


def log(msg, **fields):
    print(json.dumps({"msg": msg, **fields}))


def handler(event, context):
    failures = []
    for record in event.get("Records", []):
        try:
            process(json.loads(record["body"]))
        except Exception as err:
            log("message failed", message_id=record.get("messageId"), error=repr(err))
            failures.append({"itemIdentifier": record["messageId"]})
    # Only the failed messages go back on the queue
    return {"batchItemFailures": failures}
