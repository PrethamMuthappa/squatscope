"""Generator Lambda: builds the list of lookalike domains for one brand and queues them.

Invoke with {"brand": "acme"}. Candidates come from three places:
  1. typo tricks applied to the brand name (missing letter, lookalike characters, ...)
  2. certificate transparency logs (crt.sh): real certificates issued for names containing the brand
  3. domains already tracked for this brand, so they get re-checked every scan
"""

import json
import os
import re
import urllib.parse
import urllib.request

import store
from scoring import clean

QUEUE_URL = os.environ.get("SCAN_QUEUE_URL")
BRAND_RE = re.compile(r"^[a-z0-9]{3,30}$")

TLDS = ["com", "net", "org", "co", "xyz", "online", "shop", "info"]
MAX_CANDIDATES = 400

# Characters scammers swap in because they look alike (the reverse of the scorer's table)
LOOKALIKES = {
    "o": ["0"], "l": ["1", "i"], "i": ["1", "l"], "e": ["3"], "a": ["4"],
    "s": ["5"], "b": ["8"], "t": ["7"], "m": ["rn"], "w": ["vv"], "d": ["cl"],
}

# Keys next to each other on a QWERTY keyboard: fat-finger typos
KEYBOARD_ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
NEIGHBOURS = {}
for row in KEYBOARD_ROWS:
    for i, key in enumerate(row):
        NEIGHBOURS[key] = row[max(i - 1, 0):i] + row[i + 1:i + 2]

PHISHING_WORDS = ["login", "secure", "support", "account", "verify", "help"]


def lookalike_names(brand):
    """Typo variants of the brand name, without a TLD."""
    names = set()
    for i, ch in enumerate(brand):
        names.add(brand[:i] + brand[i + 1:])                      # missing letter
        names.add(brand[:i] + ch + brand[i:])                     # doubled letter
        if i < len(brand) - 1:
            names.add(brand[:i] + brand[i + 1] + ch + brand[i + 2:])  # swapped neighbours
        for fake in LOOKALIKES.get(ch, []):
            names.add(brand[:i] + fake + brand[i + 1:])           # lookalike character
        for key in NEIGHBOURS.get(ch, ""):
            names.add(brand[:i] + key + brand[i + 1:])            # fat-finger typo
    for word in PHISHING_WORDS:
        names.update({f"{brand}-{word}", f"{word}-{brand}", brand + word})
    names.discard(brand)
    return {n for n in names if len(n) >= 2}


def typo_candidates(brand):
    """Variants on every TLD, plus the brand itself on other TLDs. .com first."""
    names = sorted(lookalike_names(brand))
    domains = [f"{brand}.{tld}" for tld in TLDS if tld != "com"]
    for tld in TLDS:
        domains += [f"{name}.{tld}" for name in names]
    return domains


def registered_domain(name):
    """'*.mail.acme-login.com' -> 'acme-login.com' (naive: last two labels)."""
    labels = clean(name.lstrip("*.")).split(".")
    return ".".join(labels[-2:])


def cert_log_candidates(brand, limit=100):
    """Domains from public certificate logs whose name contains the brand. Best effort."""
    url = "https://crt.sh/?" + urllib.parse.urlencode({"q": f"%{brand}%", "output": "json"})
    try:
        with urllib.request.urlopen(url, timeout=25) as resp:
            rows = json.load(resp)
    except Exception as err:  # crt.sh is often slow; the typo list still works without it
        log("crt.sh lookup failed", brand=brand, error=str(err))
        return []

    found = []
    for row in rows:
        for name in row.get("name_value", "").split("\n"):
            try:
                domain = registered_domain(name.strip())
            except ValueError:
                continue
            if brand in domain.split(".")[0] and domain not in found:
                found.append(domain)
        if len(found) >= limit:
            break
    return found


def send_to_queue(brand, domains):
    import boto3
    sqs = boto3.client("sqs")
    for start in range(0, len(domains), 10):  # SQS takes at most 10 messages per call
        batch = domains[start:start + 10]
        resp = sqs.send_message_batch(QueueUrl=QUEUE_URL, Entries=[
            {"Id": str(i), "MessageBody": json.dumps({"domain": d, "brand": brand})}
            for i, d in enumerate(batch)
        ])
        if resp.get("Failed"):
            raise RuntimeError(f"SQS rejected {len(resp['Failed'])} messages: {resp['Failed']}")


def log(msg, **fields):
    print(json.dumps({"msg": msg, **fields}))


def handler(event, context):
    brand = str(event.get("brand", "")).strip().lower()
    if not BRAND_RE.match(brand):
        raise ValueError('invoke with {"brand": "acme"}: 3-30 letters or digits')

    official = f"{brand}.com"
    tracked = store.list_tracked(brand)
    from_certs = cert_log_candidates(brand)

    # Tracked and cert-log domains first: they are real; typo guesses fill the rest
    domains = []
    for d in tracked + from_certs + typo_candidates(brand):
        if d != official and d not in domains:
            domains.append(d)
    domains = domains[:MAX_CANDIDATES]

    send_to_queue(brand, domains)
    summary = {"brand": brand, "queued": len(domains),
               "tracked": len(tracked), "from_cert_logs": len(from_certs)}
    log("brand queued", **summary)
    return summary
