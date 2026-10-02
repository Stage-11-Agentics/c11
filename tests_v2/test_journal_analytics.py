#!/usr/bin/env python3
"""Tagged-build acceptance checks for the journal query/export contract."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from time import perf_counter

from cmux import cmux


ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / "tests_v2" / "journal_analytics_reader.py"


def run(command: list[str], *, input_text: str | None = None,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, input=input_text, text=True, capture_output=True, env=env)
    if result.returncode != 0:
        raise AssertionError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stderr}")
    return result


def human_metrics(text: str) -> dict[str, dict[str, str]]:
    parsed: dict[str, dict[str, str]] = {}
    for line in text.splitlines():
        if " " not in line:
            continue
        name, values = line.split(" ", 1)
        if name in {"time_in_state_ms", "operator_response", "blocked_ms", "turns", "errors"}:
            parsed[name] = dict(re.findall(r"([a-z_]+)=([^ ;]+)", values))
        elif name == "stalls":
            parsed[name] = {"count": str(0 if not values else len(values.split(";")))}
    return parsed


def concurrent_append_check(cli: str, socket_path: str, bundle_id: str) -> dict[str, float]:
    """Time real socket receipts while tagged CLI exports the registered-volume store."""
    barrier = threading.Barrier(2)
    latencies: list[float] = []
    failures: list[BaseException] = []
    with tempfile.TemporaryDirectory(prefix="c11-journal-concurrent-export-") as directory:
        def append_events() -> None:
            try:
                with cmux(socket_path) as client:
                    barrier.wait(timeout=10)
                    for _ in range(32):
                        now_ms = int(time.time() * 1_000)
                        event = {
                            "schema_version": 1,
                            "event_id": str(uuid.uuid4()),
                            "kind": "agent.state.changed",
                            "emitted_at_ms": now_ms,
                            "occurred_at_ms": now_ms,
                            "time_quality": "observed",
                            "agent_kind": "c11-validation",
                            "source": "self_report",
                            "adapter": "self_report",
                            "native_event": "other",
                            "signal": "observation",
                        }
                        start = perf_counter()
                        receipt = client._call("agent.event.append", {"event": event}, timeout_s=5)
                        latencies.append((perf_counter() - start) * 1_000)
                        if not isinstance(receipt.get("sequence"), int):
                            raise AssertionError(f"append did not return a durable receipt: {receipt}")
            except BaseException as error:
                failures.append(error)

        def export_snapshots() -> None:
            try:
                barrier.wait(timeout=10)
                for index in range(4):
                    output = Path(directory) / f"concurrent-{index}.ndjson"
                    run([cli, "--socket", socket_path, "journal", "export", "--bundle-id",
                         bundle_id, "--output", str(output)])
                    records = [json.loads(row) for row in output.read_text(encoding="utf-8").splitlines()]
                    if not records or records[0].get("record_type") != "manifest" or records[-1].get("record_type") != "coverage_summary":
                        raise AssertionError("concurrent export lost its frozen header or coverage footer")
            except BaseException as error:
                failures.append(error)

        append_thread = threading.Thread(target=append_events, name="journal-append-receipts")
        export_thread = threading.Thread(target=export_snapshots, name="journal-stream-exports")
        append_thread.start()
        export_thread.start()
        append_thread.join(timeout=60)
        export_thread.join(timeout=60)
        if append_thread.is_alive() or export_thread.is_alive():
            raise AssertionError("concurrent append/export scenario exceeded 60 seconds")
        if failures:
            raise AssertionError(f"concurrent append/export failed: {failures[0]}") from failures[0]
    ordered = sorted(latencies)
    p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
    maximum = ordered[-1]
    if maximum > 250:
        raise AssertionError(f"append receipt exceeded the 250 ms hook budget: max={maximum:.2f} ms")
    return {"append_receipts": float(len(ordered)), "append_p95_ms": p95,
            "append_max_ms": maximum, "hook_budget_ms": 250.0}


def clear_live_with_ready_spool(cli: str, socket_path: str, bundle_id: str) -> dict[str, int]:
    """Clear only the fresh tagged test namespace after proving the ready-spool barrier."""
    if bundle_id != "com.stage11.c11.debug.c11.277":
        raise AssertionError("live clear is limited to the fresh c11-277 tagged namespace")
    import sqlite3

    directory = Path.home() / "Library/Application Support/c11/journal" / bundle_id
    database = directory / "lifecycle.sqlite3"
    spool = directory / "spool"
    with sqlite3.connect(database) as db:
        before_high_water = db.execute(
            "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='journal_events'),0)"
        ).fetchone()[0]
    now_ms = int(time.time() * 1_000)
    draft = {
        "schema_version": 1,
        "event_id": str(uuid.uuid4()),
        "kind": "agent.state.changed",
        "emitted_at_ms": now_ms,
        "occurred_at_ms": now_ms,
        "time_quality": "observed",
        "agent_kind": "c11-validation",
        "source": "self_report",
        "adapter": "self_report",
        "native_event": "other",
        "signal": "observation",
    }
    absent_socket = "/tmp/c11-277-unavailable-spool.sock"
    environment = dict(os.environ, CMUX_BUNDLE_ID=bundle_id)
    spooled = run([cli, "--socket", absent_socket, "agent-event", "append", "--stdin"],
                  input_text=json.dumps(draft), env=environment)
    if json.loads(spooled.stdout).get("spooled") is not True:
        raise AssertionError(f"offline test event was not spooled: {spooled.stdout!r}")
    ready = list(spool.glob("*.ready"))
    if not ready:
        raise AssertionError("ready spool was not present immediately before live clear")

    run([cli, "--socket", socket_path, "journal", "clear", "--yes", "--bundle-id", bundle_id])
    with sqlite3.connect(database) as db:
        event_count = db.execute("SELECT count(*) FROM journal_events").fetchone()[0]
        current_count = db.execute("SELECT count(*) FROM journal_current").fetchone()[0]
        after_high_water = db.execute(
            "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='journal_events'),0)"
        ).fetchone()[0]
        coverage_floor = db.execute(
            "SELECT value FROM journal_meta WHERE key='coverage_low_water'"
        ).fetchone()[0]
    remaining_ready = list(spool.glob("*.ready"))
    if event_count or current_count or after_high_water != before_high_water or coverage_floor != after_high_water + 1 or remaining_ready:
        raise AssertionError(
            "live clear did not atomically empty state/spool and preserve the reset boundary: "
            f"events={event_count} current={current_count} high_water={after_high_water} "
            f"coverage_floor={coverage_floor} ready={len(remaining_ready)}"
        )
    query = json.loads(run([cli, "--socket", socket_path, "journal", "query", "--json",
                            "--bundle-id", bundle_id, "--from", "0",
                            "--to", str(int(time.time() * 1_000) + 1_000)]).stdout)
    if not query["coverage"]["incomplete"] or query["turns"]["started"] != 0:
        raise AssertionError("live clear did not expose empty-but-truncated coverage")
    return {"high_water": int(after_high_water), "coverage_floor": int(coverage_floor),
            "ready_before": len(ready), "ready_after": len(remaining_ready)}


def clear_offline_with_ready_spool(cli: str, socket_path: str, bundle_id: str) -> dict[str, int | bool]:
    """Keep an empty cleared database and its sequence boundary while offline."""
    if bundle_id != "com.stage11.c11.debug.c11.277":
        raise AssertionError("offline clear is limited to the c11-277 tagged namespace")
    import sqlite3

    directory = Path.home() / "Library/Application Support/c11/journal" / bundle_id
    database = directory / "lifecycle.sqlite3"
    spool = directory / "spool"
    if not database.is_file():
        raise AssertionError("offline clear would not have an existing tagged journal to preserve")
    with sqlite3.connect(database) as db:
        high_water = db.execute(
            "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='journal_events'),0)"
        ).fetchone()[0]
        floor_before = db.execute(
            "SELECT value FROM journal_meta WHERE key='coverage_low_water'"
        ).fetchone()[0]
    now_ms = int(time.time() * 1_000)
    draft = {
        "schema_version": 1,
        "event_id": str(uuid.uuid4()),
        "kind": "agent.state.changed",
        "emitted_at_ms": now_ms,
        "occurred_at_ms": now_ms,
        "time_quality": "observed",
        "agent_kind": "c11-validation",
        "source": "self_report",
        "adapter": "self_report",
        "native_event": "other",
        "signal": "observation",
    }
    environment = dict(os.environ, CMUX_BUNDLE_ID=bundle_id)
    spooled = run([cli, "--socket", "/tmp/c11-277-unavailable-offline-clear.sock",
                   "agent-event", "append", "--stdin"],
                  input_text=json.dumps(draft), env=environment)
    if json.loads(spooled.stdout).get("spooled") is not True:
        raise AssertionError(f"offline test event was not spooled: {spooled.stdout!r}")
    ready_before = list(spool.glob("*.ready"))
    if not ready_before:
        raise AssertionError("offline ready spool was not present immediately before clear")

    run([cli, "--socket", socket_path, "journal", "clear", "--yes", "--bundle-id", bundle_id])
    if not database.is_file():
        raise AssertionError("offline clear deleted the journal database")
    with sqlite3.connect(database) as db:
        event_count = db.execute("SELECT count(*) FROM journal_events").fetchone()[0]
        current_count = db.execute("SELECT count(*) FROM journal_current").fetchone()[0]
        after_high_water = db.execute(
            "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='journal_events'),0)"
        ).fetchone()[0]
        floor_after = db.execute(
            "SELECT value FROM journal_meta WHERE key='coverage_low_water'"
        ).fetchone()[0]
    ready_after = list(spool.glob("*.ready"))
    if event_count or current_count or after_high_water != high_water or floor_after != high_water + 1 or ready_after:
        raise AssertionError(
            "offline clear lost sequence/coverage or retained state/spool: "
            f"events={event_count} current={current_count} high_water={after_high_water} "
            f"floor={floor_after} ready={len(ready_after)}"
        )
    query = json.loads(run([cli, "--socket", socket_path, "journal", "query", "--json",
                            "--bundle-id", bundle_id, "--from", "0",
                            "--to", str(int(time.time() * 1_000) + 1_000)]).stdout)
    if not query["coverage"]["incomplete"] or query["turns"]["started"] != 0:
        raise AssertionError("offline clear did not expose empty-but-truncated coverage")
    return {"database_preserved": True, "high_water": int(after_high_water),
            "coverage_floor_before": int(floor_before), "coverage_floor_after": int(floor_after),
            "ready_before": len(ready_before), "ready_after": len(ready_after)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=os.environ.get("C11_CLI", "c11"))
    parser.add_argument("--socket", default=os.environ.get("C11_SOCKET") or os.environ.get("C11_SOCKET_PATH"))
    parser.add_argument("--bundle-id", default=os.environ.get("C11_JOURNAL_BUNDLE_ID"))
    parser.add_argument("--measure-append-concurrency", action="store_true",
                        help="append 32 synthetic records while four tagged CLI exports run")
    parser.add_argument("--clear-live-after", action="store_true",
                        help="live-clear only the fresh c11-277 tagged test namespace after checks")
    parser.add_argument("--clear-offline-after", action="store_true",
                        help="offline-clear only the c11-277 tagged namespace after the app is stopped")
    args = parser.parse_args()
    if not args.socket or not args.bundle_id:
        raise SystemExit("set --socket/ C11_SOCKET and --bundle-id/ C11_JOURNAL_BUNDLE_ID")

    common = [args.cli, "--socket", args.socket]
    capabilities = json.loads(run(common + ["capabilities"]).stdout)
    features = capabilities.get("features", [])
    if not any(feature.get("id") == "journal.analytics" and feature.get("version") == 1
               for feature in features if isinstance(feature, dict)):
        raise AssertionError("system.capabilities did not advertise journal.analytics v1")

    unavailable_reader = run([sys.executable, str(READER)], input_text=json.dumps({
        "time_in_state_ms": {}, "blocked_ms": {},
        "turns": {"started": 0}, "errors": {"root": 0, "interrupts": 0},
        "operator_response": {"wait_ms": None}, "stalls": [],
    }))
    if "q2_operator_wait_ms=null" not in unavailable_reader.stdout:
        raise AssertionError(f"unavailable Q2 was coerced: {unavailable_reader.stdout!r}")

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

    readable = human_metrics(run(common + ["journal", "query", "--bundle-id", args.bundle_id,
                                           "--from", "0", "--to", end]).stdout)
    time_values = payload["time_in_state_ms"]
    phases = ("working", "blocked", "idle", "error", "unknown")
    if any(int(readable["time_in_state_ms"][phase]) != time_values.get(phase, 0) for phase in phases):
        raise AssertionError("readable Q1 differs from JSON")
    response = payload["operator_response"]
    if readable["operator_response"]["wait_ms"] != ("null" if response["wait_ms"] is None else str(response["wait_ms"])):
        raise AssertionError("readable Q2 differs from JSON")
    if sum(map(int, readable["blocked_ms"].values())) != sum(payload["blocked_ms"].values()):
        raise AssertionError("readable Q3 differs from JSON")
    if int(readable["turns"]["started"]) != payload["turns"]["started"]:
        raise AssertionError("readable Q4 differs from JSON")
    if int(readable["errors"]["root"]) + int(readable["errors"]["interrupts"]) != payload["errors"]["root"] + payload["errors"]["interrupts"]:
        raise AssertionError("readable Q5 differs from JSON")
    if int(readable["stalls"]["count"]) != len(payload["stalls"]):
        raise AssertionError("readable Q6 differs from JSON")

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
        if lines[-1].get("record_type") != "coverage_summary":
            raise AssertionError("export does not end with final coverage")
        high_water = lines[0].get("high_water_sequence", 0)
        sequences = [row["sequence"] for row in lines if row.get("record_type") == "event"]
        if sequences != sorted(sequences) or any(sequence > high_water for sequence in sequences):
            raise AssertionError("export event rows are not bounded and ordered")
        forbidden = {"prompt", "command", "arguments", "cwd", "output", "body", "generated_at"}
        for row in lines:
            if forbidden.intersection(row):
                raise AssertionError(f"private/generated field in export: {forbidden.intersection(row)}")
        has_gap = any(row.get("record_type") == "gap" for row in lines)
        export_coverage_incomplete = lines[0]["coverage"]["incomplete"]
        if lines[-1].get("incomplete") is not (export_coverage_incomplete or has_gap):
            raise AssertionError(
                "final export coverage summary disagrees with records: "
                f"manifest={export_coverage_incomplete} footer={lines[-1].get('incomplete')} gap={has_gap}"
            )

        stable_a = Path(directory) / "default-a.ndjson"
        stable_b = Path(directory) / "default-b.ndjson"
        run(common + ["journal", "export", "--bundle-id", args.bundle_id, "--output", str(stable_a)])
        run(common + ["journal", "export", "--bundle-id", args.bundle_id, "--output", str(stable_b)])
        if stable_a.read_bytes() != stable_b.read_bytes():
            raise AssertionError("default export changed without a journal snapshot change")

    concurrency = (concurrent_append_check(args.cli, args.socket, args.bundle_id)
                   if args.measure_append_concurrency else None)
    live_clear = (clear_live_with_ready_spool(args.cli, args.socket, args.bundle_id)
                  if args.clear_live_after else None)
    offline_clear = (clear_offline_with_ready_spool(args.cli, args.socket, args.bundle_id)
                     if args.clear_offline_after else None)
    print("journal analytics: query shape, reader, and bounded NDJSON export passed")
    if concurrency:
        print("journal concurrent append/export: " + json.dumps(concurrency, sort_keys=True))
    if live_clear:
        print("journal live clear with ready spool: " + json.dumps(live_clear, sort_keys=True))
    if offline_clear:
        print("journal offline clear with ready spool: " + json.dumps(offline_clear, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
