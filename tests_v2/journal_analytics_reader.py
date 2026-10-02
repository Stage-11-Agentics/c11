#!/usr/bin/env python3
"""Small example consumer for ``c11 journal query --json`` output.

The reader intentionally consumes the machine contract only.  It never
scrapes the human report, and it emits one stable line for each of Q1-Q6.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any


def _number(value: Any) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"expected number, got {value!r}")
    return value


def summarize(payload: dict[str, Any]) -> dict[str, int | float | None]:
    time_in_state = payload["time_in_state_ms"]
    blocked = payload["blocked_ms"]
    turns = payload["turns"]
    errors = payload["errors"]
    response = payload["operator_response"]
    stalls = payload["stalls"]
    if not isinstance(time_in_state, dict) or not isinstance(blocked, dict):
        raise ValueError("query payload has invalid time or blocked metrics")
    if not isinstance(turns, dict) or not isinstance(errors, dict) or not isinstance(response, dict):
        raise ValueError("query payload has invalid count metrics")
    if not isinstance(stalls, list):
        raise ValueError("query payload has invalid stalls metric")
    confirmed_phases = ("working", "blocked", "idle", "error", "unknown")
    return {
        "q1_time_in_state_ms": sum(_number(time_in_state.get(name, 0)) for name in confirmed_phases),
        "q2_operator_wait_ms": None if response["wait_ms"] is None else _number(response["wait_ms"]),
        "q3_blocked_ms": sum(_number(value) for value in blocked.values()),
        "q4_turns_started": _number(turns["started"]),
        "q5_root_errors_and_interrupts": _number(errors["root"]) + _number(errors["interrupts"]),
        "q6_stall_count": len(stalls),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", help="JSON file; defaults to stdin")
    args = parser.parse_args()
    try:
        text = Path(args.input).read_text(encoding="utf-8") if args.input else sys.stdin.read()
        payload = json.loads(text)
        if not isinstance(payload, dict):
            raise ValueError("query payload must be an object")
        for name, value in summarize(payload).items():
            print(f"{name}={json.dumps(value, separators=(',', ':'))}")
        return 0
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"journal reader: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
