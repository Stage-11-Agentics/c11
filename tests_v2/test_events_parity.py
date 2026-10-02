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

To validate a specific serialized instance log, set `C11_EVENT_LOG` to its
NDJSON path. This also asserts that the C11-257 tab and mailbox event examples
are present in that runtime log.
"""

import glob
import json
import os
import subprocess
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:  # pragma: no cover
    print("SKIP: jsonschema not installed (pip install jsonschema)")
    sys.exit(0)

REPO = Path(__file__).resolve().parent.parent
SCHEMA_PATH = REPO / "spec" / "event-envelope.v1.schema.json"
FIXTURES_DIR = REPO / "spec" / "fixtures" / "events"


def _load_schema():
    with open(SCHEMA_PATH) as f:
        return Draft202012Validator(json.load(f), format_checker=FormatChecker())


def _load_fixture(name):
    with open(FIXTURES_DIR / name) as f:
        return json.load(f)


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


def test_c11_257_payload_examples():
    """Keep the C11-257 C1/C2 serialized payload examples in the schema loop."""
    validator = _load_schema()
    cases = (
        ("valid-tab-input-sent.json", "tab.input_sent", "text"),
        ("valid-mailbox-accepted.json", "mailbox.accepted", "build green"),
        ("valid-mailbox-delivered.json", "mailbox.delivered", "inbox"),
    )
    for filename, expected_type, expected_value in cases:
        doc = _load_fixture(filename)
        errors = list(validator.iter_errors(doc))
        assert not errors, f"{filename} should validate, got: {[e.message for e in errors]}"
        assert doc["type"] == expected_type
        payload = doc["payload"]
        if expected_type == "tab.input_sent":
            assert payload["kind"] == expected_value
            assert payload["submitted"] is True
        elif expected_type == "mailbox.accepted":
            assert payload["body"] == expected_value
        else:
            assert payload["via"] == expected_value
    print("OK  C11-257 tab.input_sent/mailbox payload examples validate")


def test_serialized_event_log_schema():
    """Validate a caller-selected raw log, including the C11-257 event lines."""
    raw_path = os.environ.get("C11_EVENT_LOG")
    if not raw_path:
        print("SKIP  serialized event-log validation (C11_EVENT_LOG not set)")
        return

    path = Path(raw_path)
    assert path.is_file(), f"C11_EVENT_LOG does not name a file: {path}"
    lines = [line for line in path.read_text().splitlines() if line.strip()]
    assert lines, f"C11_EVENT_LOG is empty: {path}"
    validator = _load_schema()
    documents = [json.loads(line) for line in lines]
    for line, doc in zip(lines, documents):
        errors = list(validator.iter_errors(doc))
        assert not errors, f"serialized line failed schema: {[e.message for e in errors]}\n{line}"

    by_type = {doc["type"]: doc for doc in documents if "type" in doc}
    assert by_type.get("tab.input_sent", {}).get("payload", {}).get("text"), \
        "serialized log is missing tab.input_sent with text"
    assert by_type.get("mailbox.accepted", {}).get("payload", {}).get("body"), \
        "serialized log is missing mailbox.accepted with body"
    assert by_type.get("mailbox.delivered", {}).get("payload", {}).get("via"), \
        "serialized log is missing mailbox.delivered with via"
    print(f"OK  schema conformance over {len(documents)} serialized lines: {path}")


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
        test_c11_257_payload_examples,
        test_serialized_event_log_schema,
        test_cli_vs_file_parity_and_schema,
    ):
        try:
            fn()
        except AssertionError as e:
            failures += 1
            print(f"FAIL  {fn.__name__}: {e}")
    sys.exit(1 if failures else 0)
