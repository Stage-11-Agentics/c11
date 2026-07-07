#!/usr/bin/env python3
"""C11-165 COR-1 (CLI half): a ref-less WRITE from an environment with no c11
surface/workspace vars must be REJECTED, not resolved to the operator-focused
surface client-side.

Before C11-165 the CLI called `system.identify` and sent the globally-focused
surface_id as a concrete ref, bypassing the server guard — the exact P0.2 stomp
for a cron/launchd/detached caller. Each write sugar now passes
`allowFocused:false`, so a ref-less external call sends no surface/tab ref and
the server rejects (missing_ref).

Requires C11_SOCKET + C11_CLI (the tagged build's `c11` binary). Fails (not
skips) when either is missing.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def _run_scrubbed(cli: str, sock: str, args: list[str]) -> subprocess.CompletedProcess:
    # Strip every c11/cmux surface+workspace env var → simulate a bare external
    # caller (cron/launchd). Keep only the socket path so the CLI can connect.
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("CMUX_") or k.startswith("C11_"))}
    env["C11_SOCKET"] = sock
    env["CMUX_SOCKET"] = sock
    return subprocess.run([cli] + args, env=env, capture_output=True, text=True, timeout=30)


def main() -> int:
    sock = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET")
    cli = os.environ.get("C11_CLI") or os.environ.get("CMUXTERM_CLI")
    if not sock or not os.path.exists(sock):
        print(f"FAIL: no reachable c11 socket ({sock!r})")
        return 1
    if not cli or not (os.path.isfile(cli) and os.access(cli, os.X_OK)):
        print(f"FAIL: C11_CLI not set to an executable c11 binary ({cli!r})")
        return 1

    # Each ref-less write must fail (non-zero) and mention the rejection, and must
    # NOT report a successful write.
    cases = [
        ["set-title", "COR1-STOMP-title"],
        ["set-description", "COR1-STOMP-desc"],
        ["set-agent", "--type", "claude-code"],
        ["set-metadata", "--key", "role", "--value", "COR1-STOMP"],
        ["rename-tab", "COR1-STOMP-rename"],
    ]
    failures = []
    for args in cases:
        proc = _run_scrubbed(cli, sock, args)
        out = (proc.stdout + proc.stderr).lower()
        rejected = proc.returncode != 0 and ("missing_ref" in out or "no surface" in out
                                             or "missing" in out or "empty_ref" in out)
        if not rejected:
            failures.append(f"{args[0]}: expected rejection, got rc={proc.returncode} out={out[:160]!r}")

    if failures:
        print("FAIL: " + " | ".join(failures))
        return 1
    print("PASS: ref-less CLI writes rejected (no client-side focused fallback)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        print(f"FAIL: {e}")
        sys.exit(1)
