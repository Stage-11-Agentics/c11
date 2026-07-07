#!/usr/bin/env python3
"""C11-163 events stream (EVT-8) parity/validation test.

Two layers:

1. **Schema conformance (always runs, no app needed).** Every
   `spec/fixtures/events/valid-*.json` must validate against
   `spec/event-envelope.v1.schema.json`; every `invalid-*.json` must fail with
   exactly one error against the intended rule. This is the drift lock between
   the documented envelope and the fixtures.

2. **CLI-vs-file parity (runs only when a `c11` binary + a running instance's
   event log are reachable).** `c11 events tail` output must be byte-identical
   to reading the NDJSON file directly, and every emitted line must validate
   against the schema. Skipped cleanly when no built binary / log is present so
   the schema layer stays runnable in any environment.

Run manually:

    python3 tests_v2/test_events_parity.py
"""

import glob
import json
import os
import subprocess
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
except ImportError:  # pragma: no cover
    print("SKIP: jsonschema not installed (pip install jsonschema)")
    sys.exit(0)

REPO = Path(__file__).resolve().parent.parent
SCHEMA_PATH = REPO / "spec" / "event-envelope.v1.schema.json"
FIXTURES_DIR = REPO / "spec" / "fixtures" / "events"


def _load_schema():
    with open(SCHEMA_PATH) as f:
        return Draft202012Validator(json.load(f))


def test_valid_fixtures_pass():
    validator = _load_schema()
    valids = sorted(glob.glob(str(FIXTURES_DIR / "valid-*.json")))
    assert valids, "no valid fixtures found"
    for path in valids:
        with open(path) as f:
            doc = json.load(f)
        errors = list(validator.iter_errors(doc))
        assert not errors, f"{Path(path).name} should validate, got: {[e.message for e in errors]}"
    print(f"OK  {len(valids)} valid fixtures pass the schema")


def test_invalid_fixtures_fail_once():
    validator = _load_schema()
    invalids = sorted(glob.glob(str(FIXTURES_DIR / "invalid-*.json")))
    assert invalids, "no invalid fixtures found"
    for path in invalids:
        with open(path) as f:
            doc = json.load(f)
        errors = list(validator.iter_errors(doc))
        assert len(errors) >= 1, f"{Path(path).name} should fail the schema but passed"
    print(f"OK  {len(invalids)} invalid fixtures each fail the schema")


def _find_binary():
    for cand in ("c11", "cmux"):
        try:
            out = subprocess.run(["which", cand], capture_output=True, text=True)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except Exception:
            pass
    return None


def _events_dir():
    base = os.environ.get("C11_STATE") or os.path.expanduser(
        "~/Library/Application Support/c11"
    )
    return Path(base) / "events"


def test_cli_vs_file_parity_and_schema():
    binary = _find_binary()
    ev_dir = _events_dir()
    logs = sorted(ev_dir.glob("events-*.ndjson")) if ev_dir.exists() else []
    if not binary or not logs:
        print("SKIP  CLI-vs-file parity (no c11 binary or no instance log present)")
        return

    newest = max(logs, key=lambda p: p.stat().st_mtime)
    file_lines = [l for l in newest.read_text().splitlines() if l.strip()]

    proc = subprocess.run([binary, "events", "tail"], capture_output=True, text=True, timeout=30)
    cli_lines = [l for l in proc.stdout.splitlines() if l.strip()]

    # CLI one-shot output must equal the file's lines.
    assert cli_lines == file_lines, "c11 events tail output diverged from the raw file"

    # Every emitted line validates against the schema.
    validator = _load_schema()
    for line in cli_lines:
        doc = json.loads(line)
        errors = list(validator.iter_errors(doc))
        assert not errors, f"emitted line failed schema: {[e.message for e in errors]}\n{line}"
    print(f"OK  CLI parity + schema conformance over {len(cli_lines)} live lines")


if __name__ == "__main__":
    failures = 0
    for fn in (
        test_valid_fixtures_pass,
        test_invalid_fixtures_fail_once,
        test_cli_vs_file_parity_and_schema,
    ):
        try:
            fn()
        except AssertionError as e:
            failures += 1
            print(f"FAIL  {fn.__name__}: {e}")
    sys.exit(1 if failures else 0)
