#!/usr/bin/env python3
"""C11H-365: `c11-core link <machine> --yes` is refused inside a c11 terminal.

Inside a c11 terminal a link is the operator's typed answer, as with
`c11 machine link`. The refusal comes before c11-core reads anything, so no
plan is printed and no core is reached. HOME is a fresh folder and the hc
session tag is this test's own, so even a build without the refusal finds no
core to talk to.

Run with C11_CLI_BIN set to a tagged build's bundled `c11` CLI; without it
the test prints SKIP and exits 0.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

import json
import subprocess
import tempfile
from pathlib import Path

PANEL = "11111111-2222-4333-8444-555555555555"


def run(cli, home, args):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_", "HC_"))}
    env.update(HOME=home, CFFIXED_USER_HOME=home, C11_INVOKED_AS="c11-core",
               C11_TAG="core-link-yes-test", C11_PANEL_ID=PANEL)
    return subprocess.run([cli] + args, env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=20)


def main():
    cli = os.environ.get("C11_CLI_BIN")
    if not cli:
        print("SKIP: set C11_CLI_BIN to a tagged build's bundled c11 CLI")
        return 0
    if not Path(cli).is_file():
        raise RuntimeError(f"C11_CLI_BIN is not a file: {cli}")
    with tempfile.TemporaryDirectory(prefix="c11-core-link-yes-") as home:
        text = run(cli, home, ["link", "anyhost", "--yes"])
        shown = text.stdout + text.stderr
        assert text.returncode == 2, (text.returncode, shown)
        assert "--yes isn't accepted inside a c11 terminal" in text.stderr, shown
        assert "a shell on anyhost as you" in text.stderr, shown
        assert "Plan (nothing changes" not in shown, shown
        assert "machine add" not in shown, shown

        as_json = run(cli, home, ["link", "anyhost", "--yes", "--json"])
        assert as_json.returncode == 2, (as_json.returncode, as_json.stdout, as_json.stderr)
        payload = json.loads(as_json.stdout)
        assert payload.get("ok") is False, payload
        assert payload.get("error", {}).get("code") == "yes_refused_in_c11", payload
        assert "Plan (nothing changes" not in as_json.stdout + as_json.stderr, as_json.stdout
    print("PASS: c11-core link --yes is refused inside a c11 terminal before anything is read")
    return 0


if __name__ == "__main__":
    sys.exit(main())
