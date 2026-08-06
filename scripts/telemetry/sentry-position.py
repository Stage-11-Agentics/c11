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
    scripts/telemetry/sentry-position.py --check         # recurrence detector
    scripts/telemetry/sentry-position.py --self-test     # offline, no token

`--check` asserts the ways this has gone wrong before: the org over quota, events
dropped, the org or a single client on pace to overrun by period end, and — the
one that hid the last outage for over a week — a client that should be reporting
having gone silent. It runs daily from `.github/workflows/sentry-quota-watch.yml`.

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
import math
import os
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

API = "https://sentry.io/api/0"
DEFAULT_ORG = "stage-11-kl"
KEYS_FILE = Path.home() / "Projects" / "Gregorovich" / "keys.txt"
KEY_NAME = "SENTRY_USER_AUTH_TOKEN"

# Outcomes that mean "Sentry threw the event away". `accepted` and `filtered`
# (an inbound filter the operator configured on purpose) are not failures.
DROP_OUTCOMES = {"rate_limited", "invalid", "abuse", "cardinality_limited"}

# Each client's declared slice of the org's monthly errors, and whether it is
# expected to be reporting continuously. The quota is shared and has no
# server-side per-project fence, so these are a promise enforced here rather
# than by Sentry — the point is to catch a client eating the pool *before* it
# starves its neighbours, not to divide the pool exactly.
#
# c11's 20,000 is sized against measurement, not taste: unfenced installs ran at
# ~986 events/day (~29,600/month, 59% of the org) and 99% of that was
# main-thread-hang reports, which the client budget caps at 15/day/process. The
# fenced projection is roughly 1,000-9,000/month, so 20,000 is about 2x the
# pessimistic case — loose enough that ordinary growth in installs does not page
# anyone, tight enough that a regression to unfenced behaviour trips long before
# the org is threatened.
DECLARED_SHARES = {
    "c11": {"monthly": 20_000, "expect_reporting": True},
    "acetate": {"monthly": 5_000, "expect_reporting": False},
}

# A project that should be reporting and has sent nothing in this many hours is
# the failure that started all of this: monitoring that has gone silent looks
# exactly like a quiet week.
LIVENESS_HOURS = 24


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

    # Accepted-per-project over the billing period so far, for the share check,
    # plus a short window for the liveness check. Both are cheap; ask for them
    # unconditionally so `--json` consumers always get the same shape.
    since = customer.get("billingPeriodStart")
    elapsed_days, total_days = billing_progress(
        since, customer.get("billingPeriodEnd")
    )
    period_accepted = accepted_by_project(
        org, token, projects, f"{max(1, math.ceil(elapsed_days))}d"
    )
    recent_accepted = accepted_by_project(org, token, projects, f"{LIVENESS_HOURS}h")

    return {
        "org": org,
        "period": period,
        "plan": customer.get("plan"),
        "billing_period": [
            customer.get("billingPeriodStart"),
            customer.get("billingPeriodEnd"),
        ],
        "billing_elapsed_days": round(elapsed_days, 2),
        "billing_total_days": total_days,
        "reserved": errors.get("reserved"),
        "usage": errors.get("usage"),
        "usage_exceeded": errors.get("usageExceeded"),
        "on_demand_max_spend_cents": customer.get("onDemandMaxSpend"),
        "on_demand_spend_used_cents": errors.get("onDemandSpendUsed"),
        "projects": {slug: dict(o) for slug, o in sorted(by_project.items())},
        "drop_reasons": dict(sorted(by_reason.items(), key=lambda kv: -kv[1])),
        "period_accepted": period_accepted,
        "recent_accepted": recent_accepted,
        "liveness_hours": LIVENESS_HOURS,
    }


def billing_progress(start: str | None, end: str | None) -> tuple[float, float]:
    """Days elapsed in the billing period, and its total length.

    Sentry reports these as bare `YYYY-MM-DD` strings covering inclusive days.
    A period that has only just started still counts as one elapsed day, so the
    projection never divides by zero on reset day.
    """
    fmt = "%Y-%m-%d"
    try:
        begin = datetime.strptime(start, fmt).replace(tzinfo=timezone.utc)
        finish = datetime.strptime(end, fmt).replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return 1.0, 30.0
    total = max(1.0, (finish - begin).days + 1)
    elapsed = (datetime.now(timezone.utc) - begin).total_seconds() / 86_400
    return max(1.0, min(elapsed, total)), total


def accepted_by_project(
    org: str, token: str, projects: dict[str, str], period: str
) -> dict[str, int]:
    stats = get(
        f"/organizations/{org}/stats_v2/"
        f"?statsPeriod={period}&field=sum(quantity)&category=error"
        "&groupBy=project&groupBy=outcome&interval=1d",
        token,
    )
    out: dict[str, int] = defaultdict(int)
    for group in stats.get("groups", []):
        if group["by"].get("outcome") != "accepted":
            continue
        slug = projects.get(
            str(group["by"].get("project")), str(group["by"].get("project"))
        )
        out[slug] += group["totals"]["sum(quantity)"]
    return dict(out)


def checks(data: dict) -> list[tuple[bool, str]]:
    """The recurrence detector: every way this has gone wrong, asserted.

    Returns (ok, message) per check so a failing run says which one tripped.
    """
    results: list[tuple[bool, str]] = []
    elapsed = data["billing_elapsed_days"] or 1
    total = data["billing_total_days"] or 30
    remaining_fraction = total / elapsed

    # 1. The original incident: the org over quota, everything dropped silently.
    results.append(
        (
            not data["usage_exceeded"],
            "org is over quota — every project is being dropped"
            if data["usage_exceeded"]
            else "org is under quota",
        )
    )

    # 2. Drops of any kind in the window. Zero is the only healthy number:
    #    a dropped event is one nobody will ever see.
    dropped = sum(data["drop_reasons"].values())
    results.append(
        (dropped == 0, f"{dropped:,} events dropped in the last {data['period']}")
        if dropped
        else (True, f"nothing dropped in the last {data['period']}")
    )

    # 3. Org-level pace. Being under quota today says nothing about landing
    #    under it on the last day of the period.
    usage, reserved = data["usage"] or 0, data["reserved"] or 0
    projected = usage * remaining_fraction
    results.append(
        (
            projected <= reserved,
            f"on pace for {projected:,.0f} of {reserved:,} errors this period",
        )
    )

    # 4. Per-client share. There is no server-side per-project fence on this
    #    plan, so one client can quietly eat the pool its neighbours depend on.
    for slug, share in DECLARED_SHARES.items():
        used = data["period_accepted"].get(slug, 0)
        proj = used * remaining_fraction
        results.append(
            (
                proj <= share["monthly"],
                f"{slug}: on pace for {proj:,.0f} of its declared "
                f"{share['monthly']:,}",
            )
        )

    # 5. Liveness. A client that should be reporting and is not looks exactly
    #    like a quiet week — which is how the last outage hid for over a week.
    for slug, share in DECLARED_SHARES.items():
        if not share["expect_reporting"]:
            continue
        recent = data["recent_accepted"].get(slug, 0)
        results.append(
            (
                recent > 0,
                f"{slug}: {recent:,} events accepted in the last "
                f"{data['liveness_hours']}h"
                + ("" if recent else " — REPORTING HAS GONE SILENT"),
            )
        )

    return results


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


def self_test() -> int:
    """Exercise every failure path of `checks()` against synthetic state.

    A detector whose alarms have never fired is a detector nobody should trust,
    and these paths are awkward to reach for real — you would have to exhaust a
    real quota or silence a real client to see them. `checks()` is a pure
    function of the collected dict, so they are cheap to reach here. Runs
    offline, needs no token.
    """
    healthy = {
        "period": "24h",
        "billing_elapsed_days": 15.0,
        "billing_total_days": 30.0,
        "usage_exceeded": False,
        "usage": 5_000,
        "reserved": 50_000,
        "drop_reasons": {},
        "period_accepted": {"c11": 5_000, "acetate": 100},
        "recent_accepted": {"c11": 400, "acetate": 10},
        "liveness_hours": LIVENESS_HOURS,
    }

    def failing(state: dict) -> list[str]:
        return [m for ok, m in checks({**healthy, **state}) if not ok]

    cases = [
        ("healthy baseline", {}, 0),
        ("org over quota", {"usage_exceeded": True}, 1),
        ("events dropped", {"drop_reasons": {"rate_limited/quota": 42}}, 1),
        # Half the period gone, 45k of 50k spent: fine today, over by month end.
        ("org on pace to exceed", {"usage": 45_000}, 1),
        # c11 alone on pace for 40k against its declared 20k. Only the share
        # check fires: org pace reads `usage`, the share reads per-project
        # accepted, so a client can breach its promise while the org is still
        # comfortable. That separation is the point — it is the early warning.
        ("client over declared share", {"period_accepted": {"c11": 20_000}}, 1),
        # The incident that started this: reporting silently stopped.
        ("client gone silent", {"recent_accepted": {"c11": 0}}, 1),
    ]

    failures = 0
    for name, state, expected in cases:
        got = failing(state)
        status = "ok" if len(got) == expected else "UNEXPECTED"
        if len(got) != expected:
            failures += 1
        print(f"  [{status}] {name}: {len(got)} check(s) failed, expected {expected}")
        for message in got:
            print(f"      - {message}")

    print("self-test passed" if not failures else f"self-test FAILED ({failures})")
    return 0 if not failures else 1


def render_checks(data: dict) -> tuple[str, bool]:
    results = checks(data)
    lines = ["Recurrence checks:"]
    for ok, message in results:
        lines.append(f"  {'PASS' if ok else 'FAIL'}  {message}")
    healthy = all(ok for ok, _ in results)
    lines.append("")
    lines.append("OK: all checks pass." if healthy else "ALARM: a check failed above.")
    return "\n".join(lines), healthy


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--org", default=DEFAULT_ORG)
    ap.add_argument(
        "--period",
        default="30d",
        help="stats window: 24h, 7d, 30d, 90d (default 30d)",
    )
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument(
        "--check",
        action="store_true",
        help="run the recurrence checks and exit non-zero if any fails "
        "(quota, drops, org pace, per-client share, liveness)",
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="exercise the checks against synthetic state; offline, no token",
    )
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    data = collect(args.org, args.period, read_token())

    if args.check:
        data["checks"] = [
            {"ok": ok, "message": message} for ok, message in checks(data)
        ]
        text, healthy = render_checks(data)
        print(json.dumps(data, indent=2) if args.json else render(data) + "\n\n" + text)
        return 0 if healthy else 1

    ok, _ = verdict(data)
    print(json.dumps(data, indent=2) if args.json else render(data))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
