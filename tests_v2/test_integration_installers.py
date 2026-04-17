#!/usr/bin/env python3
"""Module 4: integration installer regression tests.

Exercises `cmux install` / `cmux uninstall` / `cmux install --list` / `--status` via subprocess
against a temporary fake HOME so no real user config is touched. The installer is pure CLI —
no running cmux socket is required.
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


TUIS = ("claude-code", "codex", "opencode", "kimi")
MARKER_ID = "c11mux-v1"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli
    fixed = os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux"
    )
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed
    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run(cli: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([cli, *args], capture_output=True, text=True, check=False)


def _config_path_for(tui: str, home: str) -> str:
    return {
        "claude-code": f"{home}/.claude/settings.json",
        "codex": f"{home}/.codex/config.toml",
        "opencode": f"{home}/.config/opencode/opencode.json",
        "kimi": f"{home}/.kimi/config.toml",
    }[tui]


def _shim_path_for(tui: str, home: str) -> str | None:
    if tui == "claude-code":
        return None
    return f"{home}/.local/bin/cmux-shims/{tui}"


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------------------
# Test 1-4: install-from-empty, idempotency, uninstall round-trip, status.
# ---------------------------------------------------------------------------


def test_empty_install_and_round_trip(cli: str, home: str, tui: str) -> None:
    cfg = _config_path_for(tui, home)
    shim = _shim_path_for(tui, home)

    # status before install
    p = _run(cli, "--json", "install", "--status", tui, "--home", home)
    _must(p.returncode == 0, f"[{tui}] status should succeed pre-install: {p.returncode} {p.stderr}")
    status = json.loads(p.stdout)
    _must(status["state"] == "not_installed", f"[{tui}] expected not_installed, got {status['state']}")

    # install from empty
    p = _run(cli, "install", tui, "--no-confirm", "--home", home)
    _must(p.returncode == 0, f"[{tui}] install should succeed: {p.returncode} {p.stderr}")
    _must(os.path.isfile(cfg), f"[{tui}] expected config at {cfg}")
    content = _read(cfg)
    _must(MARKER_ID in content, f"[{tui}] marker {MARKER_ID} missing from config")
    if shim:
        _must(os.path.isfile(shim), f"[{tui}] shim missing at {shim}")
        st = os.stat(shim)
        _must(st.st_mode & 0o111 != 0, f"[{tui}] shim not executable at {shim}")

    # status after install
    p = _run(cli, "--json", "install", "--status", tui, "--home", home)
    _must(p.returncode == 0, f"[{tui}] post-install status should succeed")
    status = json.loads(p.stdout)
    _must(
        status["state"] == "installed_current",
        f"[{tui}] expected installed_current, got {status['state']}",
    )

    # idempotency: re-running is a no-op
    pre = _read(cfg)
    p = _run(cli, "install", tui, "--no-confirm", "--home", home)
    _must(p.returncode == 0, f"[{tui}] second install should succeed: {p.returncode} {p.stderr}")
    post = _read(cfg)
    _must(pre == post, f"[{tui}] second install changed config (idempotency broken)")

    # uninstall
    p = _run(cli, "uninstall", tui, "--no-confirm", "--home", home)
    _must(p.returncode == 0, f"[{tui}] uninstall should succeed: {p.returncode} {p.stderr}")
    if shim:
        _must(not os.path.isfile(shim), f"[{tui}] shim should be removed: {shim}")


# ---------------------------------------------------------------------------
# Test 5: merge-safe install over existing user config.
# ---------------------------------------------------------------------------


def test_install_merge_preserves_user_keys(cli: str, home: str) -> None:
    # opencode is the JSON-merge TUI that best exercises the merge path without
    # the layout constraints of claude-code's hook arrays.
    cfg_dir = Path(home) / ".config" / "opencode"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    cfg = cfg_dir / "opencode.json"
    cfg.write_text(json.dumps({"theme": "dark", "fontSize": 14}), encoding="utf-8")

    p = _run(cli, "install", "opencode", "--no-confirm", "--home", home)
    _must(p.returncode == 0, f"opencode install should succeed: {p.returncode} {p.stderr}")
    merged = json.loads(cfg.read_text(encoding="utf-8"))
    _must(merged.get("theme") == "dark", "user key 'theme' was lost in merge")
    _must(merged.get("fontSize") == 14, "user key 'fontSize' was lost in merge")
    _must("x-cmux" in merged, "expected x-cmux key after install")

    # uninstall preserves user keys and removes x-cmux
    p = _run(cli, "uninstall", "opencode", "--no-confirm", "--home", home)
    _must(p.returncode == 0, f"opencode uninstall should succeed: {p.returncode} {p.stderr}")
    remaining = json.loads(cfg.read_text(encoding="utf-8"))
    _must("x-cmux" not in remaining, "x-cmux key leaked after uninstall")
    _must(remaining.get("theme") == "dark", "user key 'theme' lost on uninstall")
    _must(remaining.get("fontSize") == 14, "user key 'fontSize' lost on uninstall")


# ---------------------------------------------------------------------------
# Test 6: dry-run writes nothing.
# ---------------------------------------------------------------------------


def test_dry_run_writes_nothing(cli: str, home: str) -> None:
    tui = "claude-code"
    cfg = _config_path_for(tui, home)
    p = _run(cli, "install", tui, "--dry-run", "--no-confirm", "--home", home)
    _must(p.returncode == 0, f"dry-run should succeed: {p.returncode} {p.stderr}")
    _must(not os.path.isfile(cfg), f"dry-run should not create {cfg}")


# ---------------------------------------------------------------------------
# Test 7: --list emits JSON array for 4 TUIs.
# ---------------------------------------------------------------------------


def test_list_json(cli: str, home: str) -> None:
    p = _run(cli, "--json", "install", "--list", "--home", home)
    _must(p.returncode == 0, f"--list should succeed: {p.returncode} {p.stderr}")
    payload = json.loads(p.stdout)
    _must(payload.get("ok") is True, f"--list ok=true: {payload}")
    rows = payload.get("integrations") or []
    _must(len(rows) == 4, f"expected 4 TUIs in --list, got {len(rows)}")
    ids = sorted(r["tui"] for r in rows)
    _must(ids == sorted(TUIS), f"expected TUIs {sorted(TUIS)}, got {ids}")


# ---------------------------------------------------------------------------
# Test 8: unknown TUI yields non-zero exit.
# ---------------------------------------------------------------------------


def test_unknown_tui_fails(cli: str, home: str) -> None:
    p = _run(cli, "install", "not-a-tui", "--no-confirm", "--home", home)
    _must(p.returncode != 0, f"unknown tui should fail: {p.stdout} {p.stderr}")
    combined = (p.stdout + p.stderr).lower()
    _must("unknown tui" in combined or "unknown" in combined, f"expected unknown-tui error: {combined}")


# ---------------------------------------------------------------------------
# Test 9: non-interactive install without --no-confirm aborts (no TTY).
# ---------------------------------------------------------------------------


def test_interactive_without_tty_aborts(cli: str, home: str) -> None:
    p = _run(cli, "install", "claude-code", "--home", home)
    _must(p.returncode != 0, f"install without --no-confirm and no TTY should fail: {p.stdout} {p.stderr}")
    combined = (p.stdout + p.stderr).lower()
    _must("tty" in combined or "aborted" in combined, f"expected TTY/abort error: {combined}")


def main() -> int:
    cli = _find_cli_binary()

    for tui in TUIS:
        home = tempfile.mkdtemp(prefix=f"cmux-m4-{tui}-")
        try:
            test_empty_install_and_round_trip(cli, home, tui)
        finally:
            shutil.rmtree(home, ignore_errors=True)

    home = tempfile.mkdtemp(prefix="cmux-m4-merge-")
    try:
        test_install_merge_preserves_user_keys(cli, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)

    home = tempfile.mkdtemp(prefix="cmux-m4-dry-")
    try:
        test_dry_run_writes_nothing(cli, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)

    home = tempfile.mkdtemp(prefix="cmux-m4-list-")
    try:
        test_list_json(cli, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)

    home = tempfile.mkdtemp(prefix="cmux-m4-unk-")
    try:
        test_unknown_tui_fails(cli, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)

    home = tempfile.mkdtemp(prefix="cmux-m4-tty-")
    try:
        test_interactive_without_tty_aborts(cli, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)

    print("PASS: cmux install/uninstall lifecycle across all 4 TUIs (merge, dry-run, list, status, unknown, tty)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
