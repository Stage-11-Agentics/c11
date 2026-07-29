#!/usr/bin/env python3
"""Behavioral parity checks for explicit state-verify recovery modes."""

from __future__ import annotations

import glob
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import uuid
from pathlib import Path


def resolve_c11_cli() -> str:
    explicit = os.environ.get("C11_CLI_BIN") or os.environ.get("CMUX_CLI_BIN")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit
    candidates = glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/c11"
    ))
    candidates = [path for path in candidates if os.access(path, os.X_OK)]
    if candidates:
        return max(candidates, key=os.path.getmtime)
    found = shutil.which("c11")
    if found:
        return found
    raise RuntimeError("Unable to find c11 CLI binary; set C11_CLI_BIN")


def snapshot(path: Path, refs: list[dict]) -> None:
    panels = []
    for index, ref in enumerate(refs):
        panels.append({
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"surface-{index}")),
            "type": "terminal",
            "surface_conversations": {"active": ref, "history": []},
        })
    path.write_text(json.dumps({
        "windows": [{"tabManager": {"workspaces": [{"panels": panels}]}}],
    }), encoding="utf-8")


def run(
    cli: str,
    sessions_root: Path,
    path: Path,
    mode: str | None,
    *,
    qa_gate: bool = True,
    opencode_db: Path | None = None,
) -> subprocess.CompletedProcess:
    args = [cli, "--json", "state", "verify"]
    if mode is not None:
        args += ["--mode", mode]
    args.append(str(path))
    env = os.environ.copy()
    for key in (
        "C11_TAG", "CMUX_TAG", "C11_QA_LAUNCH",
        "C11_QA_CLAUDE_PROJECTS_ROOT", "C11_QA_OPENCODE_DB_PATH",
    ):
        env.pop(key, None)
    env.update({
        "C11_QA_CODEX_SESSIONS_ROOT": str(sessions_root),
        "C11_QA_CLAUDE_PROJECTS_ROOT": str(
            sessions_root.parent / "claude-projects"
        ),
        "CMUX_CLI_SENTRY_DISABLED": "1",
    })
    if qa_gate:
        env["C11_TAG"] = "c11-206-state-verify-test"
    if opencode_db is not None:
        env["C11_QA_OPENCODE_DB_PATH"] = str(opencode_db)
    return subprocess.run(args, env=env, capture_output=True, text=True, timeout=5, check=False)


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def payload(proc: subprocess.CompletedProcess) -> dict:
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}


def main() -> int:
    failures: list[str] = []
    try:
        cli = resolve_c11_cli()
    except RuntimeError as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="c11-state-verify-modes-") as raw_tmp:
        tmp = Path(raw_tmp)
        sessions_root = tmp / "sessions"
        sessions_root.mkdir()
        path = tmp / "snapshot.json"
        codex_id = str(uuid.uuid4())
        exact_ref = {
            "kind": "codex", "id": codex_id, "placeholder": False,
            "state": "suspended", "cwd": "/work/project",
            "capturedVia": "runtimeEnv",
        }
        snapshot(path, [exact_ref])

        omitted = run(cli, sessions_root, path, None)
        expect(omitted.returncode != 0 and "requires --mode" in omitted.stderr, f"missing mode was accepted: {omitted.stderr}", failures)

        clean = run(cli, sessions_root, path, "clean")
        clean_payload = payload(clean)
        expect(clean.returncode == 0 and clean_payload.get("mode") == "clean", f"clean mode failed: {clean.stderr} {clean.stdout}", failures)
        clean_panel = (clean_payload.get("panels") or [{}])[0]
        expect(clean_panel.get("action") == f"codex resume '{codex_id}'", f"clean mode did not emit exact command: {clean_panel}", failures)

        snapshot(path, [{
            "kind": "codex", "id": "wrapper-claim:test", "placeholder": True,
            "state": "unknown", "cwd": "/work/project",
            "capturedVia": "wrapperClaim",
        }])
        placeholder = run(cli, sessions_root, path, "clean")
        placeholder_panel = (payload(placeholder).get("panels") or [{}])[0]
        expect(
            placeholder.returncode != 0
            and placeholder_panel.get("skip_code") == "placeholder",
            f"clean placeholder did not match app typed skip: {placeholder_panel}",
            failures,
        )

        unknown_ref = dict(exact_ref)
        unknown_ref["state"] = "unknown"
        unknown_ref["capturedVia"] = "manual"
        snapshot(path, [unknown_ref])
        unknown = run(cli, sessions_root, path, "clean")
        unknown_panel = (payload(unknown).get("panels") or [{}])[0]
        expect(
            unknown.returncode != 0
            and unknown_panel.get("skip_code") == "state-not-resumable",
            f"clean unknown lifecycle did not match app typed skip: {unknown_panel}",
            failures,
        )

        snapshot(path, [exact_ref])
        dirty_missing = run(cli, sessions_root, path, "dirty")
        missing_panel = (payload(dirty_missing).get("panels") or [{}])[0]
        expect(dirty_missing.returncode != 0 and missing_panel.get("skip_code") == "transcript-missing", f"dirty missing transcript did not skip: {missing_panel}", failures)

        rollout = sessions_root / "2026" / "07" / "22"
        rollout.mkdir(parents=True)
        target = rollout / f"rollout-2026-07-22T00-00-00-{codex_id}.jsonl"
        target.touch()
        os.utime(target, (1_000, 1_000))
        # Prove exact verification is not the assignment rail's old top-16:
        # the target is the 21st-newest metadata entry and must still resolve.
        decoys: list[Path] = []
        for index in range(20):
            decoy = rollout / f"rollout-newer-{index}-{uuid.uuid4()}.jsonl"
            decoy.touch()
            os.utime(decoy, (2_000 + index, 2_000 + index))
            decoys.append(decoy)
        override_without_gate = run(cli, sessions_root, path, "dirty", qa_gate=False)
        override_without_gate_panel = (payload(override_without_gate).get("panels") or [{}])[0]
        expect(
            override_without_gate.returncode != 0
            and override_without_gate_panel.get("skip_code") == "transcript-missing",
            f"untagged CLI honored the QA Codex sessions override: {override_without_gate_panel}",
            failures,
        )
        dirty_present = run(cli, sessions_root, path, "dirty")
        present_panel = (payload(dirty_present).get("panels") or [{}])[0]
        expect(dirty_present.returncode == 0 and present_panel.get("action") == f"codex resume '{codex_id}'", f"dirty exact transcript did not resume: {present_panel}", failures)

        no_resume = run(cli, sessions_root, path, "no-resume")
        no_resume_payload = payload(no_resume)
        no_resume_panel = (no_resume_payload.get("panels") or [{}])[0]
        expect(no_resume.returncode != 0 and no_resume_payload.get("mode") == "no-resume" and no_resume_panel.get("skip_code") == "policy-no-resume", f"no-resume policy failed: {no_resume_panel}", failures)

        # Exact verification is not candidate discovery. Push the target past
        # 512 newer entries and prove exact filename membership still succeeds.
        for index in range(20, 512):
            decoy = rollout / f"rollout-newer-{index}-{uuid.uuid4()}.jsonl"
            decoy.touch()
            os.utime(decoy, (2_000 + index, 2_000 + index))
        dirty_beyond_bound = run(cli, sessions_root, path, "dirty")
        bounded_panel = (payload(dirty_beyond_bound).get("panels") or [{}])[0]
        expect(dirty_beyond_bound.returncode == 0 and bounded_panel.get("action") == f"codex resume '{codex_id}'", f"Codex exact lookup inherited the 512 candidate bound: {bounded_panel}", failures)

        snapshot(path, [exact_ref, exact_ref])
        duplicate = run(cli, sessions_root, path, "clean")
        duplicate_panels = payload(duplicate).get("panels") or []
        expect(duplicate.returncode != 0 and len(duplicate_panels) == 2 and all(row.get("skip_code") == "duplicate-ownership" for row in duplicate_panels), f"duplicate exact ownership was not quarantined: {duplicate_panels}", failures)

        inferred_duplicate = dict(exact_ref)
        inferred_duplicate["capturedVia"] = "scrape"
        snapshot(path, [exact_ref, inferred_duplicate])
        causal_wins = run(cli, sessions_root, path, "clean")
        causal_wins_panels = payload(causal_wins).get("panels") or []
        expect(
            causal_wins.returncode != 0
            and len(causal_wins_panels) == 2
            and causal_wins_panels[0].get("action") == f"codex resume '{codex_id}'"
            and causal_wins_panels[1].get("skip_code") == "duplicate-ownership",
            f"sole causal duplicate owner did not displace inferred owner: {causal_wins_panels}",
            failures,
        )

        scrape_refs = [
            {
                "kind": "codex", "id": str(uuid.uuid4()), "placeholder": False,
                "state": "suspended", "cwd": "/work/shared/../shared",
                "captured_via": "scrape",
            },
            {
                "kind": "codex", "id": str(uuid.uuid4()), "placeholder": False,
                "state": "suspended", "cwd": "/work/shared",
                "capturedVia": "scrape",
            },
        ]
        snapshot(path, scrape_refs)
        inferred_same_cwd = run(cli, sessions_root, path, "clean")
        inferred_same_cwd_panels = payload(inferred_same_cwd).get("panels") or []
        expect(
            inferred_same_cwd.returncode != 0
            and len(inferred_same_cwd_panels) == 2
            and all(row.get("skip_code") == "ambiguous-ownership" for row in inferred_same_cwd_panels),
            f"noncausal same-cwd Codex owners were not all ambiguous: {inferred_same_cwd_panels}",
            failures,
        )

        nonresumable_same_cwd_refs = [
            {
                "kind": "codex", "id": str(uuid.uuid4()), "placeholder": False,
                "state": "suspended", "cwd": "/work/shared",
                "capturedVia": "scrape",
            },
            {
                "kind": "codex", "id": str(uuid.uuid4()), "placeholder": False,
                "state": "tombstoned", "cwd": "/work/shared",
                "capturedVia": "scrape",
            },
            {
                "kind": "codex", "id": str(uuid.uuid4()), "placeholder": False,
                "state": "unsupported", "cwd": "/work/shared",
                "capturedVia": "scrape",
            },
        ]
        snapshot(path, nonresumable_same_cwd_refs)
        nonresumable_same_cwd = run(cli, sessions_root, path, "clean")
        nonresumable_panels = payload(nonresumable_same_cwd).get("panels") or []
        expect(
            nonresumable_same_cwd.returncode != 0
            and len(nonresumable_panels) == 3
            and nonresumable_panels[0].get("action")
                == f"codex resume '{nonresumable_same_cwd_refs[0]['id']}'"
            and [row.get("skip_code") for row in nonresumable_panels[1:]]
                == ["state-not-resumable", "state-not-resumable"],
            "nonresumable Codex refs polluted same-cwd ownership: "
            f"{nonresumable_panels}",
            failures,
        )

        causal_same_cwd_refs = [
            {
                "kind": "codex", "id": str(uuid.uuid4()), "placeholder": False,
                "state": "suspended", "cwd": "/work/shared",
                "capturedVia": "runtimeEnv",
            },
            {
                "kind": "codex", "id": str(uuid.uuid4()), "placeholder": False,
                "state": "suspended", "cwd": "/work/shared",
                "captured_via": "runtimeEnv",
            },
        ]
        snapshot(path, causal_same_cwd_refs)
        causal_same_cwd = run(cli, sessions_root, path, "clean")
        causal_same_cwd_panels = payload(causal_same_cwd).get("panels") or []
        expect(
            causal_same_cwd.returncode == 0
            and len(causal_same_cwd_panels) == 2
            and all(row.get("would_resume") is True for row in causal_same_cwd_panels),
            f"distinct causal same-cwd Codex owners were not eligible: {causal_same_cwd_panels}",
            failures,
        )

        claude_id = str(uuid.uuid4())
        claude_cwd = (
            "/Users/atin/Projects/Gregorovich/projects/singularist_salon"
        )
        claude_slug = (
            "-Users-atin-Projects-Gregorovich-projects-singularist-salon"
        )
        claude_projects_root = tmp / "claude-projects"
        claude_transcript = (
            claude_projects_root / claude_slug / f"{claude_id}.jsonl"
        )
        claude_transcript.parent.mkdir(parents=True)
        claude_transcript.touch()
        snapshot(path, [{
            "kind": "claude-code", "id": claude_id, "placeholder": False,
            "state": "suspended", "cwd": claude_cwd,
            "capturedVia": "hook",
        }])
        claude_override_without_gate = run(
            cli, sessions_root, path, "dirty", qa_gate=False
        )
        claude_ungated_panel = (
            payload(claude_override_without_gate).get("panels") or [{}]
        )[0]
        expect(
            claude_override_without_gate.returncode != 0
            and claude_ungated_panel.get("skip_code") == "transcript-missing",
            "untagged CLI honored the QA Claude projects override: "
            f"{claude_ungated_panel}",
            failures,
        )
        claude_dirty = run(cli, sessions_root, path, "dirty")
        claude_panel = (payload(claude_dirty).get("panels") or [{}])[0]
        expect(
            claude_dirty.returncode == 0
            and claude_panel.get("transcript_evidence") == "verified"
            and claude_panel.get("action")
                == f"claude --dangerously-skip-permissions --resume {claude_id}",
            f"dirty Claude underscore cwd slug diverged from app behavior: {claude_panel}",
            failures,
        )

        opencode_db = tmp / "opencode.db"
        opencode_id = "ses_" + ("A" * 26)
        with sqlite3.connect(opencode_db) as database:
            database.execute("CREATE TABLE session (id TEXT PRIMARY KEY)")
            database.execute("INSERT INTO session (id) VALUES (?)", (opencode_id,))
        snapshot(path, [{
            "kind": "opencode", "id": opencode_id, "placeholder": False,
            "state": "suspended", "cwd": "/work/opencode",
            "capturedVia": "hook",
        }])
        opencode_dirty = run(
            cli, sessions_root, path, "dirty", opencode_db=opencode_db
        )
        opencode_panel = (payload(opencode_dirty).get("panels") or [{}])[0]
        expect(
            opencode_dirty.returncode == 0
            and opencode_panel.get("transcript_evidence") == "verified"
            and opencode_panel.get("action") == f"cd '/work/opencode' && opencode --auto -s '{opencode_id}'",
            f"dirty OpenCode SQLite verification diverged from app behavior: {opencode_panel}",
            failures,
        )

        opencode_missing_id = "ses_" + ("B" * 26)
        snapshot(path, [{
            "kind": "opencode", "id": opencode_missing_id, "placeholder": False,
            "state": "suspended", "cwd": "/work/opencode",
            "capturedVia": "hook",
        }])
        opencode_missing = run(
            cli, sessions_root, path, "dirty", opencode_db=opencode_db
        )
        opencode_missing_panel = (payload(opencode_missing).get("panels") or [{}])[0]
        expect(
            opencode_missing.returncode != 0
            and opencode_missing_panel.get("transcript_evidence") == "missing"
            and opencode_missing_panel.get("skip_code") == "transcript-missing",
            f"dirty OpenCode missing-row decision diverged from app behavior: {opencode_missing_panel}",
            failures,
        )

        unavailable_db = tmp / "missing-opencode.db"
        opencode_unavailable = run(
            cli, sessions_root, path, "dirty", opencode_db=unavailable_db
        )
        opencode_unavailable_panel = (
            payload(opencode_unavailable).get("panels") or [{}]
        )[0]
        expect(
            opencode_unavailable.returncode != 0
            and opencode_unavailable_panel.get("transcript_evidence") == "unavailable"
            and opencode_unavailable_panel.get("skip_code") == "transcript-unverified",
            f"dirty OpenCode unavailable-DB decision diverged from app behavior: {opencode_unavailable_panel}",
            failures,
        )

    if failures:
        print("FAIL: state verify recovery modes")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: state verify requires an explicit mode and shares exact Codex decisions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
