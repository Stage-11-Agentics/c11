#!/usr/bin/env python3
"""Tagged-build acceptance checks for the journal query/export contract."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / "tests_v2" / "journal_analytics_reader.py"


def run(command: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, input=input_text, text=True, capture_output=True)
    if result.returncode != 0:
        raise AssertionError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stderr}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=os.environ.get("C11_CLI", "c11"))
    parser.add_argument("--socket", default=os.environ.get("C11_SOCKET") or os.environ.get("C11_SOCKET_PATH"))
    parser.add_argument("--bundle-id", default=os.environ.get("C11_JOURNAL_BUNDLE_ID"))
    args = parser.parse_args()
    if not args.socket or not args.bundle_id:
        raise SystemExit("set --socket/ C11_SOCKET and --bundle-id/ C11_JOURNAL_BUNDLE_ID")

    common = [args.cli, "--socket", args.socket]
    end = str(int(time.time() * 1000) + 60_000)
    query = run(common + ["journal", "query", "--json", "--bundle-id", args.bundle_id,
                          "--from", "0", "--to", end])
    payload = json.loads(query.stdout)
    required = {"schema_version", "units", "window", "coverage", "time_in_state_ms",
                "operator_response", "blocked_ms", "turns", "errors", "stalls",
                "by_agent", "by_model", "by_workspace"}
    missing = required.difference(payload)
    if missing:
        raise AssertionError(f"query missing keys: {sorted(missing)}")

    reader = run([sys.executable, str(READER)], input_text=query.stdout)
    if len([line for line in reader.stdout.splitlines() if line.strip()]) != 6:
        raise AssertionError(f"reader did not emit six metrics: {reader.stdout!r}")

    with tempfile.TemporaryDirectory(prefix="c11-journal-export-") as directory:
        output = Path(directory) / "journal.ndjson"
        run(common + ["journal", "export", "--bundle-id", args.bundle_id,
                      "--from", "0", "--to", end, "--output", str(output)])
        lines = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]
        if not lines or lines[0].get("record_type") != "manifest":
            raise AssertionError("export does not start with a manifest")
        high_water = lines[0].get("high_water_sequence", 0)
        sequences = [row["sequence"] for row in lines if row.get("record_type") == "event"]
        if sequences != sorted(sequences) or any(sequence > high_water for sequence in sequences):
            raise AssertionError("export event rows are not bounded and ordered")
        forbidden = {"prompt", "command", "arguments", "cwd", "output", "body", "generated_at"}
        for row in lines:
            if forbidden.intersection(row):
                raise AssertionError(f"private/generated field in export: {forbidden.intersection(row)}")

    print("journal analytics: query shape, reader, and bounded NDJSON export passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
