#!/usr/bin/env python3
"""Measure the bundled journal CLI at registered and 10x scaling volumes.

The databases are synthetic and namespaced to disposable c11 bundle IDs. The
registered 1,000-turn fixture is the C11-270 volume; the 10,000-turn fixture
asserts that CLI RSS does not grow with the number of rows.
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
SCALING_TURNS = REGISTERED_TURNS * 10
ROWS_PER_TURN = 4
OWNERS = 40
TEN_HOURS_MS = 10 * 60 * 60 * 1_000
SEED_BATCH_ROWS = 1_000
MAX_SCALING_RSS_GROWTH_BYTES = 32 * 1024 * 1024


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


def seed(path: Path, base_ms: int, turns: int = REGISTERED_TURNS) -> int:
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
    step_ms = TEN_HOURS_MS // turns
    rows = []
    sequence = 0
    insert_sql = """
        INSERT INTO journal_events(sequence,event_id,committed_at_ms,tab_id,session_id,
          agent_kind,model_id,workspace_id,draft,event)
        VALUES(?,?,?,?,?,?,?,?,?,?)
    """
    for turn in range(turns):
        owner = turn % OWNERS
        tab_id, workspace_id = owners[owner]
        for ordinal in range(ROWS_PER_TURN):
            sequence += 1
            at_ms = base_ms + turn * step_ms + ordinal * max(1, step_ms // ROWS_PER_TURN)
            rows.append(event_record(sequence, owner, turn, ordinal, at_ms,
                                     tab_id, workspace_id, app_id))
            if len(rows) == SEED_BATCH_ROWS:
                db.executemany(insert_sql, rows)
                rows.clear()
    if rows:
        db.executemany(insert_sql, rows)
    db.execute("UPDATE journal_meta SET value=? WHERE key='last_writer_observation'",
               (base_ms + TEN_HOURS_MS,))
    db.commit()
    db.close()
    return sequence


def measured(command: list[str]) -> tuple[subprocess.CompletedProcess[str], str, int, float]:
    started = perf_counter()
    result = subprocess.run(["/usr/bin/time", "-l", *command], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise AssertionError(
            f"measured command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    elapsed_ms = (perf_counter() - started) * 1_000
    match = re.search(r"(?m)^\s*(\d+)\s+(maximum resident set size|peak memory footprint)\s*$",
                      result.stderr)
    if not match:
        raise AssertionError(f"/usr/bin/time did not report process memory: {result.stderr[-1000:]}")
    return result, match.group(2), int(match.group(1)), elapsed_ms


def count_export_events(path: Path) -> int:
    count = 0
    with path.open(encoding="utf-8") as exported:
        for line in exported:
            if json.loads(line).get("record_type") == "event":
                count += 1
    return count


def require_bounded_growth(label: str, registered_bytes: int, scaling_bytes: int) -> None:
    if scaling_bytes > registered_bytes + MAX_SCALING_RSS_GROWTH_BYTES:
        growth = scaling_bytes - registered_bytes
        raise AssertionError(
            f"{label} RSS scaled with row count: registered={registered_bytes} bytes, "
            f"10x_rows={scaling_bytes} bytes, growth={growth} bytes, "
            f"limit={MAX_SCALING_RSS_GROWTH_BYTES} bytes"
        )


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
    scale_bundle_id = f"com.stage11.c11.c11-277.scale.{uuid.uuid4().hex}"
    scale_fixture_dir = journal_root / scale_bundle_id
    for candidate in (fixture_dir, scale_fixture_dir):
        if candidate.exists():
            raise SystemExit(f"refusing to replace existing fixture: {candidate}")
    database = fixture_dir / "lifecycle.sqlite3"
    scale_database = scale_fixture_dir / "lifecycle.sqlite3"
    base_ms = int(time.time() * 1_000) - TEN_HOURS_MS

    try:
        rows = seed(database, base_ms)
        scaling_rows = seed(scale_database, base_ms, turns=SCALING_TURNS)
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
            scaled = Path(temporary) / "scaled.ndjson"
            _, export_metric, export_memory, export_ms = measured(
                base + ["journal", "export", "--bundle-id", bundle_id, "--output", str(first)])
            _, repeat_metric, repeat_memory, repeat_ms = measured(
                base + ["journal", "export", "--bundle-id", bundle_id, "--output", str(second)])
            scale_query, scale_query_metric, scale_query_memory, scale_query_ms = measured(
                base + ["journal", "query", "--json", "--bundle-id", scale_bundle_id])
            scale_payload = json.loads(scale_query.stdout)
            if (scale_payload["turns"]["started"] != SCALING_TURNS
                    or scale_payload["turns"]["completed"] != SCALING_TURNS):
                raise AssertionError(f"10x query totals mismatch: {scale_payload['turns']}")
            _, scale_export_metric, scale_export_memory, scale_export_ms = measured(
                base + ["journal", "export", "--bundle-id", scale_bundle_id,
                        "--output", str(scaled)])
            metrics = {memory_metric, export_metric, repeat_metric,
                       scale_query_metric, scale_export_metric}
            if len(metrics) != 1:
                raise AssertionError(f"/usr/bin/time changed memory metrics during the run: {metrics}")
            if first.read_bytes() != second.read_bytes():
                raise AssertionError("default exports differ for an unchanged frozen journal")
            registered_export_events = count_export_events(first)
            scaling_export_events = count_export_events(scaled)
            if registered_export_events != rows or scaling_export_events != scaling_rows:
                raise AssertionError(
                    f"export row counts mismatch: registered={registered_export_events}/{rows}, "
                    f"10x_rows={scaling_export_events}/{scaling_rows}"
                )
            export_bytes = first.stat().st_size
            scaling_export_bytes = scaled.stat().st_size

        require_bounded_growth("query", query_memory, scale_query_memory)
        require_bounded_growth("export", export_memory, scale_export_memory)

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
            "scaling_volume": {"fleet_hours": 10, "turns_per_fleet_hour": 1_000,
                               "turns": SCALING_TURNS, "synthetic_rows_per_turn": ROWS_PER_TURN,
                               "owners": OWNERS, "rows": scaling_rows},
            "scaling_bundle_id": scale_bundle_id,
            "scaling_query_peak_memory_bytes": scale_query_memory,
            "scaling_query_elapsed_ms": round(scale_query_ms, 2),
            "scaling_export_peak_memory_bytes": scale_export_memory,
            "scaling_export_elapsed_ms": round(scale_export_ms, 2),
            "scaling_export_bytes": scaling_export_bytes,
            "scaling_export_event_rows": scaling_export_events,
            "max_scaling_rss_growth_bytes": MAX_SCALING_RSS_GROWTH_BYTES,
            "query_rss_growth_bytes": scale_query_memory - query_memory,
            "export_rss_growth_bytes": scale_export_memory - export_memory,
            "bounded_query_memory": True,
            "bounded_export_memory": True,
            "stable_default_export": True,
        }, sort_keys=True))
    finally:
        if (not args.preserve and fixture_dir.exists()
                and fixture_dir.parent == journal_root and fixture_dir.name == bundle_id):
            shutil.rmtree(fixture_dir)
        if (scale_fixture_dir.exists() and scale_fixture_dir.parent == journal_root
                and scale_fixture_dir.name == scale_bundle_id):
            shutil.rmtree(scale_fixture_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
