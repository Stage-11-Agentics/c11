#!/usr/bin/env python3
"""
Stress test: 20 concurrent CLI calls complete within wall-clock deadline.

Covers the original dogfood failure shape: batch automation that fires many
surface/metadata commands back-to-back could hang indefinitely before
3d0b8257 + this ticket's Tier 1 deadline bridge.
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET", "")
WALL_CLOCK_LIMIT = 15.0
SUBPROCESS_TIMEOUT = 15.0
CALL_COUNT = 20
DEADLINE_ENV_MS = "9000"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> Optional[str]:
    """Return path to c11/cmux CLI binary, or None if not found (caller should skip)."""
    import shutil

    # Prefer explicit env vars (c11-style first, then legacy cmux compat).
    for env_key in ("C11_CLI_BIN", "CMUX_CLI_BIN", "CMUX_CLI", "CMUXTERM_CLI"):
        val = os.environ.get(env_key)
        if val and os.path.isfile(val) and os.access(val, os.X_OK):
            return val

    # Prefer the path written by scripts/reload.sh --tag.
    last_cli_path_file = "/tmp/c11-last-cli-path"
    if os.path.isfile(last_cli_path_file) and not os.path.islink(last_cli_path_file):
        try:
            candidate = open(last_cli_path_file).read().strip()
            if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
        except OSError:
            pass

    # Xcode DerivedData — search both project names (c11 current, cmux historical).
    candidates: list[str] = []
    for binary_name in ("c11", "cmux"):
        candidates.extend(glob.glob(
            os.path.expanduser(
                f"~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/{binary_name}"
            ),
            recursive=True,
        ))
        candidates.extend(glob.glob(f"/tmp/c11-*/Build/Products/Debug/{binary_name}"))
        candidates.extend(glob.glob(f"/tmp/cmux-*/Build/Products/Debug/{binary_name}"))
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    # PATH fallback.
    for binary_name in ("c11", "cmux"):
        found = shutil.which(binary_name)
        if found:
            return found

    return None


def _cli_env() -> dict[str, str]:
    env = dict(os.environ)
    env["C11_DEFAULT_SOCKET_DEADLINE_MS"] = DEADLINE_ENV_MS
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    return env


def _run(cli: str, args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    cmd = [cli, "--socket", SOCKET_PATH] + args
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
        timeout=SUBPROCESS_TIMEOUT,
        env=env,
    )


def test_no_cli_hangs_under_rapid_surface_creation() -> int:
    if not SOCKET_PATH:
        print("SKIP: C11_SOCKET / CMUX_SOCKET not set — no live c11 instance")
        return 0

    cli = _find_cli_binary()
    if cli is None:
        print("SKIP: c11/cmux CLI binary not found. Run ./scripts/reload.sh --tag <name>, or set C11_CLI_BIN.")
        return 0
    env = _cli_env()

    # Seed workspace and surface IDs to use for surface.create and set-metadata.
    # We need at least one workspace+surface already live; create one via the
    # Python client so it's available before the stress loop starts.
    seed_ws_id: Optional[str] = None
    seed_surface_id: Optional[str] = None
    stress_ws_ids: list[str] = []

    with cmux(SOCKET_PATH) as c:
        created = c._call("workspace.create", {}) or {}
        seed_ws_id = str(created.get("workspace_id") or "")
        _must(bool(seed_ws_id), f"seed workspace.create returned no workspace_id: {created}")

        surfaces = c.list_surfaces(seed_ws_id)
        if surfaces:
            seed_surface_id = str(surfaces[0][1])

    results: list[subprocess.CompletedProcess[str]] = [None] * CALL_COUNT  # type: ignore[list-item]

    def worker(idx: int) -> None:
        # Distribute call types across the 20 workers.
        call_type = idx % 4
        try:
            if call_type == 0:
                # workspace.create via new-workspace
                results[idx] = _run(cli, ["new-workspace"], env)
            elif call_type == 1:
                # surface.create via new-surface (terminal type in existing workspace)
                args = ["new-surface", "--type", "terminal"]
                if seed_ws_id:
                    args += ["--workspace", seed_ws_id]
                results[idx] = _run(cli, args, env)
            elif call_type == 2:
                # pane.create via new-pane (split right in existing workspace)
                args = ["new-pane", "--direction", "right"]
                if seed_ws_id:
                    args += ["--workspace", seed_ws_id]
                results[idx] = _run(cli, args, env)
            else:
                # surface.set_metadata via set-metadata
                args = ["set-metadata", "--key", "stress_test", "--value", f"v{idx}"]
                if seed_surface_id:
                    args += ["--surface", seed_surface_id]
                elif seed_ws_id:
                    args += ["--workspace", seed_ws_id]
                results[idx] = _run(cli, args, env)
        except subprocess.TimeoutExpired:
            # Replace with a synthetic result so assertion below can check it.
            results[idx] = subprocess.CompletedProcess(
                args=[],
                returncode=124,
                stdout="",
                stderr="c11: timeout: subprocess.TimeoutExpired (hard wall timeout hit)",
            )

    start = time.monotonic()
    threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(CALL_COUNT)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=WALL_CLOCK_LIMIT + 1.0)
    elapsed = time.monotonic() - start

    _must(
        elapsed < WALL_CLOCK_LIMIT,
        f"20 concurrent CLI calls took {elapsed:.1f}s, exceeding {WALL_CLOCK_LIMIT}s wall-clock limit",
    )

    # Collect workspace IDs created during the run so we can clean up.
    for i, proc in enumerate(results):
        if proc is None:
            raise cmuxError(f"Worker {i} never completed (thread join timed out)")
        if proc.returncode == 0 and (i % 4) == 0:
            # new-workspace output: "OK workspace:..." or "OK <uuid>"
            out = (proc.stdout or "").strip()
            if out.startswith("OK "):
                stress_ws_ids.append(out[3:].strip())

    # Assertion: any non-zero result must carry the named timeout prefix, not silence.
    failed_silently = []
    for i, proc in enumerate(results):
        if proc.returncode != 0:
            combined = (proc.stdout or "") + (proc.stderr or "")
            has_timeout_prefix = "c11: timeout:" in combined
            has_error_label = (
                "error" in combined.lower()
                or "timeout" in combined.lower()
                or "ERROR" in combined
            )
            if not (has_timeout_prefix or has_error_label):
                failed_silently.append((i, proc.returncode, combined[:200]))

    _must(
        not failed_silently,
        f"Some CLI calls exited non-zero without a named error/timeout prefix: {failed_silently}",
    )

    # Clean up: close workspaces created during stress run + the seed workspace.
    cleanup_ids = stress_ws_ids[:]
    if seed_ws_id:
        cleanup_ids.append(seed_ws_id)

    if cleanup_ids:
        with cmux(SOCKET_PATH) as c:
            for ws_id in cleanup_ids:
                try:
                    c._call("workspace.close", {"workspace_id": ws_id})
                except Exception:
                    pass

    passed = sum(1 for p in results if p.returncode == 0)
    timed_out = sum(1 for p in results if "c11: timeout:" in ((p.stdout or "") + (p.stderr or "")))
    print(
        f"PASS: {CALL_COUNT} concurrent CLI calls completed in {elapsed:.2f}s "
        f"({passed} ok, {timed_out} named-timeout, "
        f"{CALL_COUNT - passed - timed_out} other-nonzero)"
    )
    return 0


def main() -> int:
    return test_no_cli_hangs_under_rapid_surface_creation()


if __name__ == "__main__":
    raise SystemExit(main())
