#!/usr/bin/env python3
"""Read the Sentry org's error position: quota, and accepted vs dropped per project.

Sentry's edge accepts an event with HTTP 200 and a real event id and *then* drops it
server-side when the org is over quota or spike protection fires. The sender cannot
tell. `stats_v2` is the only surface that can, which is why this exists: so nobody has
to rediscover the incantation the next time monitoring goes quiet.

Usage:
    scripts/telemetry/sentry-position.py                 # 30d, human table
    scripts/telemetry/sentry-position.py --period 24h
    scripts/telemetry/sentry-position.py --json          # machine-readable

Auth: a read-only Sentry *user* token (`sntryu_...`), taken from $SENTRY_USER_AUTH_TOKEN
or, failing that, from ~/Projects/Gregorovich/keys.txt. The token is never printed.

Exit codes:
    0  healthy: nothing dropped in the window and the quota is not exhausted
    1  degraded: the org is over quota, or events were dropped in the window
    2  could not read (no token, network/API failure)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

API = "https://sentry.io/api/0"
DEFAULT_ORG = "stage-11-kl"
KEYS_FILE = Path.home() / "Projects" / "Gregorovich" / "keys.txt"
KEY_NAME = "SENTRY_USER_AUTH_TOKEN"

# Outcomes that mean "Sentry threw the event away". `accepted` and `filtered`
# (an inbound filter the operator configured on purpose) are not failures.
DROP_OUTCOMES = {"rate_limited", "invalid", "abuse", "cardinality_limited"}


def read_token() -> str:
    token = os.environ.get(KEY_NAME, "").strip()
    if token:
        return token
    if KEYS_FILE.exists():
        for line in KEYS_FILE.read_text().splitlines():
            if line.startswith(f"{KEY_NAME}="):
                return line.split("=", 1)[1].strip()
    sys.exit(
        f"error: no {KEY_NAME}. Export it, or add it to {KEYS_FILE}.\n"
        "       It is the read-only user token (sntryu_...), not the org token."
    )


def get(path: str, token: str):
    req = urllib.request.Request(
        f"{API}{path}", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:400]
        sys.exit(f"error: GET {path} -> HTTP {exc.code}\n{body}")
    except urllib.error.URLError as exc:
        sys.exit(f"error: GET {path} -> {exc.reason}")


def collect(org: str, period: str, token: str) -> dict:
    customer = get(f"/customers/{org}/", token)
    errors = customer.get("categories", {}).get("errors", {})

    # stats_v2 groups by numeric project id; the projects endpoint returns it as a
    # string. Key on str both sides or every row renders as a bare id.
    projects = {
        str(p["id"]): p["slug"] for p in get(f"/organizations/{org}/projects/", token)
    }

    # interval must be < the period or the API 400s; 1d works for every period we use.
    stats = get(
        f"/organizations/{org}/stats_v2/"
        f"?statsPeriod={period}&field=sum(quantity)&category=error"
        "&groupBy=project&groupBy=outcome&groupBy=reason&interval=1d",
        token,
    )

    by_project: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    by_reason: dict[str, int] = defaultdict(int)
    for group in stats.get("groups", []):
        by = group["by"]
        slug = projects.get(str(by.get("project")), str(by.get("project")))
        qty = group["totals"]["sum(quantity)"]
        if not qty:
            continue
        by_project[slug][by.get("outcome", "?")] += qty
        reason = by.get("reason") or "none"
        if by.get("outcome") in DROP_OUTCOMES:
            by_reason[f"{by.get('outcome')}/{reason}"] += qty

    return {
        "org": org,
        "period": period,
        "plan": customer.get("plan"),
        "billing_period": [
            customer.get("billingPeriodStart"),
            customer.get("billingPeriodEnd"),
        ],
        "reserved": errors.get("reserved"),
        "usage": errors.get("usage"),
        "usage_exceeded": errors.get("usageExceeded"),
        "on_demand_max_spend_cents": customer.get("onDemandMaxSpend"),
        "on_demand_spend_used_cents": errors.get("onDemandSpendUsed"),
        "projects": {slug: dict(o) for slug, o in sorted(by_project.items())},
        "drop_reasons": dict(sorted(by_reason.items(), key=lambda kv: -kv[1])),
    }


def verdict(data: dict) -> tuple[bool, str]:
    if data["usage_exceeded"]:
        return False, "OVER QUOTA — every project on this org is being dropped."
    dropped = sum(data["drop_reasons"].values())
    if dropped:
        return False, f"{dropped:,} events dropped in the window — see drop reasons."
    return True, "healthy — nothing dropped in the window."


def render(data: dict) -> str:
    reserved = data["reserved"] or 0
    usage = data["usage"] or 0
    pct = (usage / reserved * 100) if reserved else 0
    out = [
        f"Sentry org {data['org']} — plan {data['plan']}",
        f"  billing period  {data['billing_period'][0]} -> {data['billing_period'][1]}",
        f"  errors          {usage:,} / {reserved:,} ({pct:.1f}%)"
        f"{'  *** QUOTA EXCEEDED ***' if data['usage_exceeded'] else ''}",
        f"  on-demand       ${(data['on_demand_spend_used_cents'] or 0)/100:.2f}"
        f" used of ${(data['on_demand_max_spend_cents'] or 0)/100:.2f} ceiling",
        "",
        f"Per project, last {data['period']}:",
    ]

    outcomes = sorted({o for p in data["projects"].values() for o in p})
    if outcomes:
        width = max(len(s) for s in data["projects"]) + 2
        out.append("  " + "project".ljust(width) + "  ".join(o.rjust(16) for o in outcomes))
        for slug, counts in data["projects"].items():
            row = "  " + slug.ljust(width)
            row += "  ".join(f"{counts.get(o, 0):,}".rjust(16) for o in outcomes)
            out.append(row)
    else:
        out.append("  (no error events in the window)")

    if data["drop_reasons"]:
        out += ["", "Why events were dropped:"]
        for reason, qty in data["drop_reasons"].items():
            out.append(f"  {reason:<40} {qty:>12,}")

    ok, note = verdict(data)
    out += ["", ("OK: " if ok else "ALARM: ") + note]
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--org", default=DEFAULT_ORG)
    ap.add_argument(
        "--period",
        default="30d",
        help="stats window: 24h, 7d, 30d, 90d (default 30d)",
    )
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    data = collect(args.org, args.period, read_token())
    ok, _ = verdict(data)
    print(json.dumps(data, indent=2) if args.json else render(data))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
