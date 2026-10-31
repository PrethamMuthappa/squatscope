"""Score how likely a domain is a typosquat of a well-known brand."""

import re

BRANDS = [
    "paypal", "google", "amazon", "microsoft", "apple",
    "netflix", "facebook", "instagram", "github", "chase",
]

# Characters scammers swap in because they look alike
HOMOGLYPHS = {"0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b"}
MULTI_HOMOGLYPHS = {"rn": "m", "vv": "w", "cl": "d"}

SUSPICIOUS_WORDS = [
    "login", "signin", "secure", "verify", "account",
    "update", "support", "wallet", "billing", "password",
]

RISKY_TLDS = {"xyz", "top", "click", "online", "site", "live", "icu", "shop", "info"}

DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9-]{1,63}\.)+[a-z]{2,63}$")


def levenshtein(a, b):
    """Number of single-letter edits needed to turn a into b."""
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def normalize(text):
    """Undo common lookalike swaps, e.g. 'paypa1' -> 'paypal'."""
    for fake, real in MULTI_HOMOGLYPHS.items():
        text = text.replace(fake, real)
    return "".join(HOMOGLYPHS.get(c, c) for c in text)


def clean(domain):
    """Turn user input like 'https://Foo.com/login' into 'foo.com'."""
    domain = domain.strip().lower()
    domain = re.sub(r"^[a-z]+://", "", domain)
    domain = domain.split("/")[0].split(":")[0].rstrip(".")
    if not DOMAIN_RE.match(domain):
        raise ValueError(f"'{domain}' is not a valid domain name")
    return domain


def brand_signal(name, tokens):
    """Best brand-imitation signal for this name: (points, reason) or None."""
    best = None
    for brand in BRANDS:
        if brand in name:
            hit = (35, f"contains the brand name '{brand}'")
        elif brand in normalize(name):
            hit = (45, f"uses lookalike characters to imitate '{brand}'")
        else:
            close = [t for t in tokens if len(t) >= 4 and 0 < levenshtein(t, brand) <= 2]
            if not close:
                continue
            hit = (40, f"'{close[0]}' is a near-misspelling of '{brand}'")
        if best is None or hit[0] > best[0]:
            best = hit
    return best


def score_domain(domain):
    domain = clean(domain)
    labels = domain.split(".")
    registered, tld = labels[-2], labels[-1]

    if registered in BRANDS:
        return {"domain": domain, "score": 0, "risk": "low",
                "reasons": [f"official '{registered}' domain"]}

    name = ".".join(labels[:-1])
    tokens = re.split(r"[.-]", name)
    score, reasons = 0, []

    brand = brand_signal(name, tokens)
    if brand:
        score += brand[0]
        reasons.append(brand[1])

    words = [w for w in SUSPICIOUS_WORDS if w in name]
    if words:
        score += min(10 * len(words), 30)
        reasons.append("uses phishing words: " + ", ".join(words))

    if tld in RISKY_TLDS:
        score += 15
        reasons.append(f"'.{tld}' is a cheap ending popular with scammers")

    if name.count("-") >= 2:
        score += 10
        reasons.append("has many hyphens")

    score = min(score, 100)
    risk = "high" if score >= 70 else "medium" if score >= 40 else "low"
    return {"domain": domain, "score": score, "risk": risk,
            "reasons": reasons or ["no warning signs found"]}
