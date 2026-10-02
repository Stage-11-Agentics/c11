#!/usr/bin/env python3
"""Measure the bundled journal CLI at C11-270's registered 1,000-turn volume.

The database is synthetic, namespaced to one disposable c11 bundle ID, and
removed after both bounded-reader and streamed-export runs complete.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from time import perf_counter


REGISTERED_TURNS = 1_000
ROWS_PER_TURN = 4
OWNERS = 40
TEN_HOURS_MS = 10 * 60 * 60 * 1_000


def event_record(sequence: int, owner: int, turn: int, ordinal: int, at_ms: int,
                 tab_id: str, workspace_id: str, app_id: str) -> tuple:
    event_id = str(uuid.uuid4())
    agent, adapter, source = ("claude", "claude_hook", "hook")
    if owner % 3 == 1:
        agent, adapter, source = "codex", "codex_notify", "hook"
    elif owner % 3 == 2:
        agent, adapter, source = "grok", "grok_transcript", "transcript"

    kind = "agent.turn.started" if ordinal == 0 else "agent.turn.completed" if ordinal == 3 else "agent.state.changed"
    native = "turn.started" if ordinal == 0 else "turn.completed" if ordinal == 3 else "PreToolUse"
    signal = None if ordinal in (0, 3) else "tool_activity"
    draft = {
        "schema_version": 1,
        "event_id": event_id,
        "kind": kind,
        "emitted_at_ms": at_ms,
        "occurred_at_ms": at_ms,
        "time_quality": "observed",
        "tab_id": tab_id,
        "workspace_id": workspace_id,
        "session_id": f"session-{owner:02d}",
        "agent_kind": agent,
        "is_child": False,
        "source": source,
        "adapter": adapter,
        "adapter_version": "1",
        "native_event": native,
        "turn_id": f"turn-{turn:04d}",
    }
    if signal:
        draft["signal"] = signal

    event = {
        "sequence": sequence,
        "committed_at_ms": at_ms,
        "observed_tick_ns": sequence * 1_000_000,
        "app_instance_id": app_id,
        "draft": draft,
        "draft_hash": "0" * 64,
        "attribution": "registered-volume-synthetic",
        "confidence_rank": 60 if source == "hook" else 40,
        "capabilities": ["turn"],
        "model_id": f"model-{(turn + owner) % 4}",
        "fold_version": 1,
        "projection_effect": "applied",
        "effect_reason": "registered-volume-synthetic",
        "from_phase": "working" if ordinal else "unknown",
        "to_phase": "working",
        "from_since_ms": at_ms - 1 if ordinal else None,
    }
    return (sequence, event_id, at_ms, tab_id, f"session-{owner:02d}", agent,
            event["model_id"], workspace_id,
            json.dumps(draft, separators=(",", ":")).encode(),
            json.dumps(event, separators=(",", ":")).encode())


def seed(path: Path, base_ms: int) -> int:
    import sqlite3

    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript("""
        PRAGMA journal_mode=WAL;
        PRAGMA user_version=1;
        CREATE TABLE journal_events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT NOT NULL UNIQUE,
          committed_at_ms INTEGER NOT NULL,tab_id TEXT,session_id TEXT,
          agent_kind TEXT NOT NULL,model_id TEXT,workspace_id TEXT,draft BLOB NOT NULL,event BLOB);
        CREATE INDEX journal_owner_sequence ON journal_events(tab_id,session_id,sequence);
        CREATE INDEX journal_dimensions ON journal_events(committed_at_ms,agent_kind,model_id,workspace_id);
        CREATE TABLE journal_current (owner TEXT PRIMARY KEY,state BLOB NOT NULL,observed_at_ms INTEGER NOT NULL,protected INTEGER NOT NULL);
        CREATE TABLE journal_meta (key TEXT PRIMARY KEY,value INTEGER NOT NULL);
        INSERT INTO journal_meta VALUES('fold_version',1),('coverage_low_water',1),('last_writer_observation',0);
    """)
    app_id = str(uuid.uuid4())
    owners = [(str(uuid.uuid4()), str(uuid.uuid4())) for _ in range(OWNERS)]
    step_ms = TEN_HOURS_MS // REGISTERED_TURNS
    rows = []
    sequence = 0
    for turn in range(REGISTERED_TURNS):
        owner = turn % OWNERS
        tab_id, workspace_id = owners[owner]
        for ordinal in range(ROWS_PER_TURN):
            sequence += 1
            at_ms = base_ms + turn * step_ms + ordinal * max(1, step_ms // ROWS_PER_TURN)
            rows.append(event_record(sequence, owner, turn, ordinal, at_ms,
                                     tab_id, workspace_id, app_id))
    db.executemany("""
        INSERT INTO journal_events(sequence,event_id,committed_at_ms,tab_id,session_id,
          agent_kind,model_id,workspace_id,draft,event)
        VALUES(?,?,?,?,?,?,?,?,?,?)
    """, rows)
    db.execute("UPDATE journal_meta SET value=? WHERE key='last_writer_observation'",
               (base_ms + TEN_HOURS_MS,))
    db.commit()
    db.close()
    return sequence


def measured(command: list[str]) -> tuple[subprocess.CompletedProcess[str], str, int, float]:
    started = perf_counter()
    result = subprocess.run(["/usr/bin/time", "-l", *command], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    elapsed_ms = (perf_counter() - started) * 1_000
    match = re.search(r"(?m)^\s*(\d+)\s+(maximum resident set size|peak memory footprint)\s*$",
                      result.stderr)
    if not match:
        raise AssertionError(f"/usr/bin/time did not report process memory: {result.stderr[-1000:]}")
    return result, match.group(2), int(match.group(1)), elapsed_ms


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, help="tagged Atlas bundle CLI executable")
    parser.add_argument("--support", type=Path,
                        default=Path.home() / "Library/Application Support")
    parser.add_argument("--bundle-id", help="optional isolated bundle namespace")
    parser.add_argument("--preserve", action="store_true",
                        help="keep only the absent tagged c11-277 validation namespace for live append checks")
    args = parser.parse_args()

    cli = str(Path(args.cli).resolve())
    if not Path(cli).is_file():
        raise SystemExit(f"tagged CLI not found: {cli}")
    suffix = uuid.uuid4().hex
    bundle_id = args.bundle_id or f"com.stage11.c11.c11-277.measure.{suffix}"
    if not re.fullmatch(r"com\.stage11\.c11(?:\.[A-Za-z0-9-]+)+", bundle_id) or ".." in bundle_id:
        raise SystemExit(f"invalid measurement bundle id: {bundle_id}")
    if args.preserve and bundle_id != "com.stage11.c11.debug.c11.277":
        raise SystemExit("--preserve is limited to the c11-277 tagged app namespace")
    journal_root = args.support / "c11/journal"
    fixture_dir = journal_root / bundle_id
    if fixture_dir.exists():
        raise SystemExit(f"refusing to replace existing fixture: {fixture_dir}")
    database = fixture_dir / "lifecycle.sqlite3"
    base_ms = int(time.time() * 1_000) - TEN_HOURS_MS

    try:
        rows = seed(database, base_ms)
        socket_path = f"/tmp/c11-277-measure-{suffix}.sock"
        base = [cli, "--socket", socket_path]
        query, memory_metric, query_memory, query_ms = measured(
            base + ["journal", "query", "--json", "--bundle-id", bundle_id])
        payload = json.loads(query.stdout)
        if payload["turns"]["started"] != REGISTERED_TURNS or payload["turns"]["completed"] != REGISTERED_TURNS:
            raise AssertionError(f"query totals mismatch: {payload['turns']}")

        with tempfile.TemporaryDirectory(prefix="c11-277-journal-measure-") as temporary:
            first = Path(temporary) / "first.ndjson"
            second = Path(temporary) / "second.ndjson"
            _, export_metric, export_memory, export_ms = measured(
                base + ["journal", "export", "--bundle-id", bundle_id, "--output", str(first)])
            _, repeat_metric, repeat_memory, repeat_ms = measured(
                base + ["journal", "export", "--bundle-id", bundle_id, "--output", str(second)])
            if {memory_metric, export_metric, repeat_metric} != {memory_metric}:
                raise AssertionError("/usr/bin/time changed memory units during the run")
            if first.read_bytes() != second.read_bytes():
                raise AssertionError("default exports differ for an unchanged frozen journal")
            export_bytes = first.stat().st_size

        print(json.dumps({
            "tag": "c11-277",
            "bundle_id": bundle_id,
            "fixture_directory": str(fixture_dir) if args.preserve else None,
            "registered_volume": {"fleet_hours": 10, "turns_per_fleet_hour": 100,
                                  "turns": REGISTERED_TURNS, "synthetic_rows_per_turn": ROWS_PER_TURN,
                                  "owners": OWNERS, "rows": rows},
            "memory_metric": memory_metric,
            "query_peak_memory_bytes": query_memory,
            "query_elapsed_ms": round(query_ms, 2),
            "export_peak_memory_bytes": export_memory,
            "export_elapsed_ms": round(export_ms, 2),
            "repeat_export_peak_memory_bytes": repeat_memory,
            "repeat_export_elapsed_ms": round(repeat_ms, 2),
            "export_bytes": export_bytes,
            "turns": payload["turns"],
            "stable_default_export": True,
        }, sort_keys=True))
    finally:
        if not args.preserve and fixture_dir.exists() and fixture_dir.parent == journal_root and fixture_dir.name == bundle_id:
            shutil.rmtree(fixture_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
