#!/usr/bin/env python3
"""Regression: `c11 set-tab-icon` / `c11 set-tab-color` round-trip through tab metadata.

Run against a tagged build's socket:
  C11_SOCKET=/tmp/c11-debug-<tag>.sock python3 tests_v2/test_cli_tab_icon_color.py
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError, find_cli_binary


SOCKET_PATH = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET", "/tmp/c11-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _cli(cli: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run([cli, "--socket", SOCKET_PATH, *args], capture_output=True, text=True, check=False)


def _ok(cli: str, args: list[str]) -> str:
    proc = _cli(cli, args)
    if proc.returncode != 0:
        raise cmuxError(f"CLI failed ({' '.join(args)}): {proc.stdout}\n{proc.stderr}")
    return proc.stdout.strip()


def main() -> int:
    cli = find_cli_binary()
    created: list[str] = []
    try:
        with cmux(SOCKET_PATH) as client:
            ws = client.new_workspace()
            created.append(ws)
            tab = client.list_surfaces(ws)[0][1]
            target = ["--workspace", ws, "--tab", tab]

            def meta() -> dict:
                res = client._call("tab.get_metadata", {"workspace_id": ws, "tab_id": tab}) or {}
                return res.get("metadata") or {}

            out = _ok(cli, ["set-tab-icon", *target, "🚀"])
            _must(out.startswith("OK icon=🚀"), f"set-tab-icon output: {out!r}")
            _must(meta().get("icon") == "🚀", f"icon not stored: {meta()!r}")

            out = _ok(cli, ["set-tab-color", *target, "teal"])
            _must(out.startswith("OK color=#"), f"set-tab-color should report normalized hex: {out!r}")
            teal = meta().get("color")
            _must(isinstance(teal, str) and teal.startswith("#") and len(teal) == 7, f"color not normalized: {teal!r}")
            got = _ok(cli, ["tab-color", "get", *target])
            _must(teal in got, f"tab-color get should read the same color ({teal}): {got!r}")

            # The legacy tab-color command writes the same color the metadata key reads.
            _ok(cli, ["tab-color", "set", *target, "#C0392B"])
            _must(meta().get("color") == "#C0392B", f"tab-color set should mirror into metadata: {meta()!r}")

            # set-metadata --key is equivalent; blank clears.
            _ok(cli, ["set-metadata", *target, "--key", "icon", "--value", "sf:star.fill"])
            _must(meta().get("icon") == "sf:star.fill", f"set-metadata icon: {meta()!r}")
            _ok(cli, ["set-tab-icon", *target, ""])
            _must("icon" not in meta(), f"empty value should clear icon: {meta()!r}")
            _ok(cli, ["set-tab-color", *target, "--clear"])
            _must("color" not in meta(), f"--clear should clear color: {meta()!r}")
            got = _ok(cli, ["tab-color", "get", *target])
            _must("#C0392B" not in got, f"clearing color metadata should clear the tab color: {got!r}")

            # Validation surfaces as a non-zero exit.
            for args in (["set-tab-color", *target, "chartreuse"],
                         ["set-tab-icon", *target, "x" * 33],
                         ["set-tab-icon", *target, "🚀", "--clear"]):
                proc = _cli(cli, args)
                _must(proc.returncode != 0, f"{args} should fail, got {proc.stdout!r}")

            client.close_workspace(ws)
            created.clear()
    finally:
        if created:
            try:
                with cmux(SOCKET_PATH) as cleanup:
                    for ws in created:
                        cleanup.close_workspace(ws)
            except Exception:
                pass

    print("PASS: set-tab-icon / set-tab-color round-trip through tab metadata")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
