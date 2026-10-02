#!/usr/bin/env python3
"""
C11-257 Lane C: behavioral checks of `c11 mailbox recv --drain` against a fake
c11 socket, so the stall and broken-pipe paths can be forced.

  1. A socket that stalls after the claim cannot hold the hook drain near the
     harness deadline: the hook JSON is printed and the process exits fast.
  2. An empty recipient answers with no socket call at all, even while a
     sibling inbox holds mail.
  3. A plain drain whose stdout is a closed pipe puts the envelope back: no
     mail reaches `_read/` without reaching stdout.
  4. `mailbox.delivered` reports name the recipient tab, never the caller:
     a hook drain reports its own tab, `recv --tab <name>` reports no tab.

Run: C11_CLI_BIN=<path to c11> python3 tests/test_mailbox_hook_drain_cli.py
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

WORKSPACE = "56CB5ABD-E57D-4800-9EFD-C4267A0FE6A7"
TAB = "B3A3DFEF-0A83-4887-BBE9-FDE27516A3B5"
SIBLING = "45DE0126-1661-4511-BD57-99C26976AB31"


def resolve_cli() -> str:
    for key in ("C11_CLI_BIN", "CMUX_CLI_BIN"):
        explicit = os.environ.get(key)
        if explicit and os.access(explicit, os.X_OK):
            return explicit
    candidates = glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/*.app/Contents/Resources/bin/c11"
    ))
    candidates = [p for p in candidates if os.access(p, os.X_OK)]
    if not candidates:
        raise RuntimeError("Unable to find the c11 CLI. Set C11_CLI_BIN.")
    return max(candidates, key=os.path.getmtime)


class FakeC11:
    """Line-delimited JSON v2 server. `stall=True` reads requests and never answers."""

    def __init__(self, path: str, stall: bool):
        self.path = path
        self.stall = stall
        self.requests: list[dict] = []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(16)
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        buf = b""
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    req = json.loads(line)
                except ValueError:
                    continue
                self.requests.append(req)
                if self.stall:
                    continue
                result: dict = {}
                if req.get("method") == "system.capabilities":
                    result = {"methods": ["tab.list", "mailbox.report_delivered"]}
                conn.sendall(json.dumps({"id": req.get("id"), "ok": True, "result": result}).encode() + b"\n")

    def reports(self) -> list[dict]:
        return [r["params"] for r in self.requests if r.get("method") == "mailbox.report_delivered"]

    def close(self) -> None:
        self.sock.close()


class Fixture:
    def __init__(self) -> None:
        self.home = tempfile.mkdtemp(prefix="c11-drain-home-")
        self.mailboxes = os.path.join(
            self.home, "Library", "Application Support", "c11", "workspaces", WORKSPACE, "mailboxes"
        )
        self.counter = 0

    def deliver(self, inbox_key: str, body: str = "hello", to: str = "watcher") -> str:
        self.counter += 1
        ulid = "01K" + "0" * 22 + "ABCDEFGHJK"[self.counter % 10]
        ulid = ulid[:-2] + f"{self.counter:02d}"
        inbox = os.path.join(self.mailboxes, inbox_key)
        os.makedirs(inbox, exist_ok=True)
        envelope = {"version": 1, "id": ulid, "from": "builder", "to": to,
                    "ts": "2026-10-01T12:00:00Z", "body": body}
        with open(os.path.join(inbox, ulid + ".msg"), "w") as f:
            json.dump(envelope, f)
        return ulid

    def listing(self, inbox_key: str) -> tuple[list[str], list[str]]:
        inbox = os.path.join(self.mailboxes, inbox_key)
        root = sorted(n for n in os.listdir(inbox) if n.endswith(".msg")) if os.path.isdir(inbox) else []
        read_dir = os.path.join(inbox, "_read")
        read = sorted(n for n in os.listdir(read_dir) if n.endswith(".msg")) if os.path.isdir(read_dir) else []
        return root, read

    def env(self, sock_path: str) -> dict:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
        env.update({
            "HOME": self.home,
            "CMUX_SOCKET_PATH": sock_path,
            "CMUX_WORKSPACE_ID": WORKSPACE,
            "C11_TAB_ID": TAB,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        })
        return env

    def cleanup(self) -> None:
        shutil.rmtree(self.home, ignore_errors=True)


FAILURES: list[str] = []


def check(cond: bool, label: str, detail: str = "") -> None:
    print(("PASS: " if cond else "FAIL: ") + label + (f" ({detail})" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


def run(cli: str, args: list[str], env: dict, stdin: str = "", stdout=subprocess.PIPE, timeout: float = 15):
    start = time.monotonic()
    proc = subprocess.run([cli, *args], input=stdin.encode(), stdout=stdout, stderr=subprocess.PIPE,
                          env=env, timeout=timeout, check=False)
    return proc, (time.monotonic() - start) * 1000


def main() -> int:
    cli = resolve_cli()
    tmp = tempfile.mkdtemp(prefix="c11-drain-sock-")
    stop_input = json.dumps({"hook_event_name": "Stop", "stop_hook_active": False})

    # 1. Stalled socket after the claim.
    fx = Fixture()
    stalled = FakeC11(os.path.join(tmp, "stall.sock"), stall=True)
    ulid = fx.deliver(TAB.lower())
    proc, ms = run(cli, ["--socket", stalled.path, "mailbox", "recv", "--drain", "--hook-format", "codex"],
                   fx.env(stalled.path), stop_input)
    out = proc.stdout.decode()
    check(proc.returncode == 0, "stalled socket: exit 0", f"exit {proc.returncode} {proc.stderr!r}")
    check('"decision":"block"' in out and ulid in out, "stalled socket: hook JSON with the message printed", out[:200])
    check(ms < 2500, f"stalled socket: exits well inside the 10 s hook deadline ({ms:.0f} ms)")
    check(fx.listing(TAB.lower()) == ([], [ulid + ".msg"]), "stalled socket: envelope claimed into _read/")

    # 2. Empty recipient, sibling holds mail: no socket call before answering.
    fx.deliver(SIBLING.lower())
    stalled.requests.clear()
    timings = []
    for _ in range(10):
        proc, ms = run(cli, ["--socket", stalled.path, "mailbox", "recv", "--drain", "--hook-format", "claude"],
                       fx.env(stalled.path), stop_input)
        timings.append(ms)
        check(proc.returncode == 0 and proc.stdout == b"", "empty recipient: silent exit 0") if _ == 0 else None
    timings.sort()
    check(timings[5] < 100, f"empty recipient with sibling mail: median {timings[5]:.0f} ms < 100 ms")
    check(stalled.requests == [], "empty recipient: no socket request", str(stalled.requests[:2]))
    stalled.close()
    fx.cleanup()

    # 3 + 4. Recording socket.
    fx = Fixture()
    rec = FakeC11(os.path.join(tmp, "rec.sock"), stall=False)
    ulid = fx.deliver(TAB.lower(), to="lane-c-agent")
    proc, _ = run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--hook-format", "codex"],
                  fx.env(rec.path), stop_input)
    reports = rec.reports()
    check(len(reports) == 1 and reports[0].get("tab_id", "").upper() == TAB,
          "hook drain reports the recipient tab", json.dumps(reports))
    check(bool(reports) and reports[0].get("deliveries") == [{"id": ulid, "recipient": "lane-c-agent"}]
          and reports[0].get("via") == "drain", "hook drain report names the envelope recipient", json.dumps(reports))

    # Plain drain of someone else's (title-keyed) inbox into a closed pipe.
    ids = [fx.deliver("watcher") for _ in range(3)]
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    rec.requests.clear()
    proc, _ = run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--tab", "watcher"],
                  fx.env(rec.path), stdout=write_fd)
    os.close(write_fd)
    root, read = fx.listing("watcher")
    check(root == sorted(i + ".msg" for i in ids) and read == [],
          "broken pipe: every envelope stays in the inbox, none in _read/", f"root={root} read={read}")
    check(rec.reports() == [], "broken pipe: nothing reported delivered", json.dumps(rec.reports()))

    proc, _ = run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--tab", "watcher"], fx.env(rec.path))
    printed = proc.stdout.decode()
    root, read = fx.listing("watcher")
    check(all(i in printed for i in ids) and root == [] and len(read) == 3,
          "plain drain to a live pipe: all printed and claimed")
    reports = rec.reports()
    check(len(reports) == 1 and "tab_id" not in reports[0] and len(reports[0].get("deliveries", [])) == 3,
          "recv --tab <name>: report carries no tab_id rather than the caller's", json.dumps(reports))
    rec.close()
    fx.cleanup()
    shutil.rmtree(tmp, ignore_errors=True)

    if FAILURES:
        print(f"FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("PASS: mailbox drain CLI checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
