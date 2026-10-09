#!/usr/bin/env python3
"""Executable regressions for the C11-364 mailbox repair.

The built CLI must:
  * store a dash-prefixed ``--body`` and a body after ``--``, including
    ``--help`` and ``-h``, as the envelope body;
  * still print help for ``mailbox send --help`` / ``-h`` and write nothing;
  * refuse an empty, conflicting, extra, or unknown send without an outbox write;
  * repeat a refused ``recv`` as the original argv plus ``--ack``, including
    ``--socket`` and ``--window``. Running that text, and only that text,
    drains the inbox selected by the original command.
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import shlex
import shutil
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("drain", HERE / "test_mailbox_hook_drain_cli.py")
drain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drain)


class RoutingServer(drain.FakeC11):
    """One socket, one inbox. The panel comes from which socket answered,
    not from the recipient name, so a retry that drops ``--socket`` reads
    the other inbox."""

    def __init__(self, path: str, panel: str):
        self.panel = panel
        super().__init__(path, False)

    def _serve(self, conn):
        try:
            with conn, conn.makefile("rb") as handle:
                for line in handle:
                    try:
                        request = json.loads(line)
                    except ValueError:
                        conn.sendall(b"OK\n")
                        continue
                    self.requests.append(request)
                    method = request.get("method")
                    result = {}
                    if method == "system.capabilities":
                        result = {
                            "methods": ["panel.list", "mailbox.resolve", "window.list"],
                            "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}],
                        }
                    elif method == "mailbox.resolve":
                        result = {
                            "resolution": "unique",
                            "target_workspace_id": drain.WORKSPACE,
                            "panel_ids": [self.panel],
                        }
                    elif method == "panel.get_metadata":
                        result = {"metadata": {"title": "watcher"}}
                    elif method == "window.list":
                        result = {"windows": [{"id": drain.MOVED_TO, "ref": "window:1", "index": 1}]}
                    conn.sendall(
                        json.dumps({"id": request.get("id"), "ok": True, "result": result}).encode()
                        + b"\n"
                    )
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


class Server(drain.FakeC11):
    def _serve(self, conn):
        try:
            with conn, conn.makefile("rb") as handle:
                for line in handle:
                    try:
                        request = json.loads(line)
                    except ValueError:
                        conn.sendall(b"OK\n")
                        continue
                    self.requests.append(request)
                    method = request.get("method")
                    result = {}
                    if method == "system.capabilities":
                        result = {
                            "methods": ["panel.list", "mailbox.resolve"],
                            "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}],
                        }
                    elif method == "mailbox.resolve":
                        target = request.get("params", {}).get("to")
                        panel = drain.TAB if target in (None, "", "watcher", "builder") else drain.SIBLING
                        result = {
                            "resolution": "unique",
                            "target_workspace_id": drain.WORKSPACE,
                            "panel_ids": [panel],
                        }
                    elif method == "panel.get_metadata":
                        result = {"metadata": {"title": "watcher"}}
                    conn.sendall(
                        json.dumps({"id": request.get("id"), "ok": True, "result": result}).encode()
                        + b"\n"
                    )
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


FAILURES: list[str] = []


def check(condition: bool, label: str, detail: str = "") -> None:
    print(("PASS: " if condition else "FAIL: ") + label + (f" ({detail})" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


def outbox_bodies(fixture: drain.Fixture) -> list[str]:
    files = pathlib.Path(fixture.home).glob(
        "Library/Application Support/c11/workspaces/*/mailboxes/_outbox/*.msg"
    )
    return [json.loads(path.read_text())["body"] for path in files]


def main() -> int:
    cli = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("C11_CLI_BIN", "")
    if not cli or not os.access(cli, os.X_OK):
        print(f"FAIL: CLI is not executable ({cli!r})")
        return 1

    tmp = tempfile.mkdtemp(prefix="c11-body-sock-")
    server = Server(os.path.join(tmp, "socket"), False)
    try:
        send_cases = [
            ("body leading dashes", ["--body", "---\nBuild green"], "---\nBuild green"),
            ("body flag token", ["--body", "--nope"], "--nope"),
            ("literal help", ["--", "--help"], "--help"),
            ("literal short help", ["--", "-h"], "-h"),
            ("body help", ["--body", "--help"], "--help"),
            ("body short help", ["--body", "-h"], "-h"),
            ("inline body", ["--body=---\nBuild green"], "---\nBuild green"),
            ("positional", ["build green sha=abc"], "build green sha=abc"),
            ("literal flag", ["--", "--nope"], "--nope"),
            ("empty", [], None),
            ("empty explicit", ["--body", ""], None),
            ("both", ["--body", "flag", "positional"], None),
            ("extra", ["one", "two"], None),
            ("unknown", ["--nope", "hello"], None),
            ("duplicate body", ["--body", "one", "--body", "two"], None),
            ("boolean value", ["--urgent=yes", "hello"], None),
            ("missing value", ["--body"], None),
            ("other flag rejects dashes", ["--to", "--nope"], None),
        ]
        for label, args, expected in send_cases:
            fixture = drain.Fixture()
            try:
                proc, _ = drain.run(
                    cli,
                    ["--socket", server.path, "mailbox", "send", "--to", "watcher", "--from", "builder", *args],
                    fixture.env(server.path),
                )
                bodies = outbox_bodies(fixture)
                if expected is None:
                    ok = proc.returncode != 0 and not bodies
                else:
                    ok = proc.returncode == 0 and bodies == [expected] and b"Send flags" not in proc.stdout
                check(
                    ok,
                    label,
                    f"rc={proc.returncode} bodies={bodies!r} stdout={proc.stdout[:180]!r} stderr={proc.stderr[:240]!r}",
                )
            finally:
                fixture.cleanup()

        for label, args in (
            ("send help", ["mailbox", "send", "--help"]),
            ("send short help", ["mailbox", "send", "-h"]),
            ("mailbox help", ["mailbox", "--help"]),
        ):
            fixture = drain.Fixture()
            try:
                proc, _ = drain.run(cli, ["--socket", server.path, *args], fixture.env(server.path))
                bodies = outbox_bodies(fixture)
                check(
                    proc.returncode == 0 and not bodies and b"c11 mailbox" in proc.stdout,
                    label,
                    f"rc={proc.returncode} bodies={bodies!r} stdout={proc.stdout[:180]!r} stderr={proc.stderr[:180]!r}",
                )
            finally:
                fixture.cleanup()

        # The default socket and the command's --socket name different
        # inboxes. The retry is the emitted text alone: no socket is added
        # back around it.
        route_tmp = tempfile.mkdtemp(prefix="c11-route-sock-")
        target_server = RoutingServer(os.path.join(route_tmp, "target socket"), drain.SIBLING)
        default_server = RoutingServer(os.path.join(route_tmp, "default socket"), drain.TAB)
        try:
            for flag in ("--panel", "--tab", "--surface"):
                for routing in ("same default", "explicit socket", "explicit socket and window"):
                    for name in ("other", "other agent's inbox"):
                        label = f"guidance {flag} {routing} {name}"
                        fixture = drain.Fixture()
                        try:
                            own = fixture.deliver(drain.TAB.lower(), body="SELF")
                            target = fixture.deliver(drain.SIBLING.lower(), body="TARGET", to=name)
                            default = target_server if routing == "same default" else default_server
                            env = fixture.env(default.path)
                            route = ["--socket", target_server.path]
                            if routing == "explicit socket and window":
                                route += ["--window", "window:1"]
                            refused, _ = drain.run(
                                cli,
                                [*route, "mailbox", "recv", flag, name, "--drain"],
                                env,
                            )
                            untouched = (
                                refused.returncode != 0
                                and refused.stdout == b""
                                and fixture.listing(drain.TAB.lower()) == ([own + ".msg"], [])
                                and fixture.listing(drain.SIBLING.lower()) == ([target + ".msg"], [])
                            )
                            hint = refused.stderr.decode().split("Run ", 1)[-1].strip()
                            if not hint.startswith("c11 "):
                                check(False, label, f"hint={hint!r} stderr={refused.stderr.decode()!r}")
                                continue
                            tokens = shlex.split(hint)
                            retry, _ = drain.run(cli, tokens[1:], env)
                            own_state = fixture.listing(drain.TAB.lower())
                            target_state = fixture.listing(drain.SIBLING.lower())
                            check(
                                untouched
                                and retry.returncode == 0
                                and own_state == ([own + ".msg"], [])
                                and target_state == ([], [target + ".msg"])
                                and flag in tokens
                                and name in tokens
                                and "--socket" in tokens
                                and ("--window" in tokens) == (routing == "explicit socket and window"),
                                label,
                                f"hint={hint!r} rc={retry.returncode} own={own_state} target={target_state} stdout={retry.stdout[:120]!r} stderr={retry.stderr[:200]!r}",
                            )
                        finally:
                            fixture.cleanup()
        finally:
            target_server.close()
            default_server.close()
            shutil.rmtree(route_tmp, ignore_errors=True)
    finally:
        server.close()
        shutil.rmtree(tmp, ignore_errors=True)

    if FAILURES:
        print(f"FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("PASS: mailbox body CLI checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
