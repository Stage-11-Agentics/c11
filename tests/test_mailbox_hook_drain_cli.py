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
  5. A tab moved to another workspace (stale CMUX_WORKSPACE_ID) still finds
     its inbox there, with no socket call, and the report names that
     workspace.
  6. A hook whose pre-claim socket calls are slow stops them at the 6 s claim
     cutoff and exits before 8 s; its mail is claimed and printed, or left in
     the inbox, never claimed into a result the harness would discard.
  7. After the claim the hook does no socket I/O at all: with a socket that
     reads one line and then stops reading, the hook exits at once with its
     output intact, the detached reporter ends within its lifetime, and a
     large plain-drain report is cut off by the send deadline.
  8. A c11 that stops reading for a while and then recovers still records
     every delivery (the detached reporter waits), for the Codex hook format
     and for Claude's `claude-hook stop`.
  9. Socket calls a hook makes before its claim stop at the claim cutoff: a
     `claude-hook prompt-submit` against a c11 that stops reading exits
     well before 8 s and leaves the mail in the inbox.

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
MOVED_TO = "0D1F2E3C-4B5A-4978-8695-A4B3C2D1E0F9"


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
    """Line-delimited c11 socket. v2 JSON requests get `ok`, v1 text commands
    get `OK`. `stall=True` reads requests and never answers; `one_line=True`
    reads one line per connection and then stops reading; `delay` holds every
    answer that many seconds."""

    def __init__(self, path: str, stall: bool, delay: float = 0.0, one_line: bool = False, pause: float = 0.0):
        self.path = path
        self.pause = pause
        self.stall = stall or one_line
        self.one_line = one_line
        self.delay = delay
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
        if self.pause:
            time.sleep(self.pause)   # a wedged c11: reads nothing, then recovers
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
                    self.requests.append({"v1": line.decode(errors="replace")})
                    if not self.stall:
                        time.sleep(self.delay)
                        conn.sendall(b"OK\n")
                    continue
                self.requests.append(req)
                if self.one_line:
                    time.sleep(30)   # stop reading: the peer's next write fills the buffer
                    return
                if self.stall:
                    continue
                time.sleep(self.delay)
                result: dict = {}
                if req.get("method") == "system.capabilities":
                    result = {"methods": ["tab.list", "mailbox.report_delivered"]}
                conn.sendall(json.dumps({"id": req.get("id"), "ok": True, "result": result}).encode() + b"\n")

    def reports(self, wait: float = 3.0) -> list[dict]:
        # The hook's report comes from a detached child, so it may land a
        # moment after the hook exits.
        deadline = time.monotonic() + wait
        while True:
            found = [r["params"] for r in self.requests if r.get("method") == "mailbox.report_delivered"]
            if found or time.monotonic() > deadline:
                return found
            time.sleep(0.05)

    def close(self) -> None:
        self.sock.close()


class Fixture:
    def __init__(self) -> None:
        self.home = tempfile.mkdtemp(prefix="c11-drain-home-")
        self.mailboxes = os.path.join(
            self.home, "Library", "Application Support", "c11", "workspaces", WORKSPACE, "mailboxes"
        )
        self.counter = 0

    def deliver(self, inbox_key: str, body: str = "hello", to: str = "watcher", workspace: str = WORKSPACE) -> str:
        self.counter += 1
        ulid = "01K" + f"{self.counter:023d}"
        inbox = os.path.join(self.mailboxes.replace(WORKSPACE, workspace), inbox_key)
        os.makedirs(inbox, exist_ok=True)
        envelope = {"version": 1, "id": ulid, "from": "builder", "to": to,
                    "ts": "2026-10-01T12:00:00Z", "body": body}
        with open(os.path.join(inbox, ulid + ".msg"), "w") as f:
            json.dump(envelope, f)
        return ulid

    def listing(self, inbox_key: str, workspace: str = WORKSPACE) -> tuple[list[str], list[str]]:
        inbox = os.path.join(self.mailboxes.replace(WORKSPACE, workspace), inbox_key)
        root = sorted(n for n in os.listdir(inbox) if n.endswith(".msg")) if os.path.isdir(inbox) else []
        read_dir = os.path.join(inbox, "_read")
        read = sorted(n for n in os.listdir(read_dir) if n.endswith(".msg")) if os.path.isdir(read_dir) else []
        return root, read

    def env(self, sock_path: str) -> dict:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
        env.update({
            "HOME": self.home,
            # Foundation resolves Application Support from this, not HOME.
            "CFFIXED_USER_HOME": self.home,
            "CMUX_SOCKET_PATH": sock_path,
            "CMUX_WORKSPACE_ID": WORKSPACE,
            "C11_TAB_ID": TAB,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        })
        return env

    def cleanup(self) -> None:
        shutil.rmtree(self.home, ignore_errors=True)


FAILURES: list[str] = []


def check(cond: bool, label: str, detail: str = "") -> None:
    print(("PASS: " if cond else "FAIL: ") + label + (f" ({detail})" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


def exactly_once(fx: "Fixture", ulid: str, out: bytes, inbox_key: str = TAB.lower()) -> bool:
    """The invariant the claim cutoff protects: a message is either claimed
    and printed, or left in the inbox; never claimed but unprinted."""
    root, read = fx.listing(inbox_key)
    claimed, printed = (ulid + ".msg") in read, ulid in out.decode()
    return (claimed and printed and root == []) or (not claimed and not printed and root == [ulid + ".msg"])


def run(cli: str, args: list[str], env: dict, stdin: str = "", stdout=subprocess.PIPE, timeout: float = 15):
    """A hung CLI is a failed check, not a crashed test: it comes back with
    exit code -9 and whatever it printed before the timeout."""
    start = time.monotonic()
    try:
        proc = subprocess.run([cli, *args], input=stdin.encode(), stdout=stdout, stderr=subprocess.PIPE,
                              env=env, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        proc = subprocess.CompletedProcess(exc.cmd, -9, exc.stdout or b"", exc.stderr or b"")
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
    #    A fresh socket, so check 1's detached reporter cannot land in its log.
    stalled.close()
    stalled = FakeC11(os.path.join(tmp, "stall-empty.sock"), stall=True)
    fx.deliver(SIBLING.lower())
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
    check(bool(reports) and reports[0].get("deliveries") == [{"id": ulid, "recipient": "lane-c-agent", "workspace_id": WORKSPACE}]
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

    # 5. Moved tab: the environment still names WORKSPACE, the inbox is in MOVED_TO.
    fx = Fixture()
    stalled = FakeC11(os.path.join(tmp, "stall2.sock"), stall=True)
    ulid = fx.deliver(TAB.lower(), workspace=MOVED_TO)
    proc, ms = run(cli, ["--socket", stalled.path, "mailbox", "recv", "--drain", "--hook-format", "codex"],
                   fx.env(stalled.path), stop_input)
    check(ulid in proc.stdout.decode() and fx.listing(TAB.lower(), MOVED_TO) == ([], [ulid + ".msg"]),
          "moved tab: mail in the other workspace's inbox is delivered and claimed", proc.stdout.decode()[:120])
    pre_claim = [r for r in stalled.requests if r.get("method") != "mailbox.report_delivered"
                 and r.get("method") != "system.capabilities"]
    check(pre_claim == [], "moved tab: no socket call before the claim", str(pre_claim[:2]))
    stalled.close()
    rec = FakeC11(os.path.join(tmp, "rec2.sock"), stall=False)
    ulid = fx.deliver(TAB.lower(), workspace=MOVED_TO)
    run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--hook-format", "codex"], fx.env(rec.path), stop_input)
    reports = rec.reports()
    check(len(reports) == 1 and [d.get("workspace_id", "").upper() for d in reports[0].get("deliveries", [])] == [MOVED_TO],
          "moved tab: report names the workspace that held the inbox", json.dumps(reports))
    rec.close()
    fx.cleanup()

    # 7. Many workspace groups, socket that reads one line and stops: the hook
    #    exits at once with every message, the reporter dies within its bound.
    fx = Fixture()
    stuck = FakeC11(os.path.join(tmp, "oneline.sock"), stall=False, one_line=True)
    # 70 inboxes: the hook claims what fits its budget (~60), whose report is
    # over 8 KB, past what the socket buffers when the peer stops reading.
    groups = [f"{i:08X}-0000-4000-8000-000000000000" for i in range(1, 71)]
    ulids = [fx.deliver(TAB.lower(), workspace=w) for w in groups]
    env = fx.env(stuck.path)
    env["C11_MAILBOX_REPORT_LIFETIME_SECONDS"] = "2"
    proc, ms = run(cli, ["--socket", stuck.path, "mailbox", "recv", "--drain", "--hook-format", "codex"],
                   env, stop_input, timeout=12)
    out = proc.stdout.decode()
    taken = [(w, u) for w, u in zip(groups, ulids) if fx.listing(TAB.lower(), w)[1]]
    claimed = len(taken) >= 50 and all(u in out for _, u in taken)
    check(proc.returncode == 0 and '"decision":"block"' in out and claimed,
          f"{len(groups)} workspace inboxes, socket stops reading: hook exits 0 and prints every message it claimed "
          f"({len(taken)})", f"exit {proc.returncode} {out[:120]}")
    check(ms < 500, f"{len(groups)} workspace inboxes, socket stops reading: hook exits in {ms:.0f} ms (no socket I/O after the claim)")
    time.sleep(3.0)
    lingering = subprocess.run(["pgrep", "-f", f"{stuck.path} mailbox __report-delivered"], capture_output=True).stdout
    check(lingering.strip() == b"", "detached reporter ends within its lifetime (2 s here, 120 s by default)", lingering.decode())
    stuck.close()
    fx.cleanup()

    # Same kind of socket, plain drain with a report far over the socket send buffer:
    # the send deadline ends it.
    fx = Fixture()
    stuck = FakeC11(os.path.join(tmp, "oneline2.sock"), stall=False, one_line=True)
    many = [fx.deliver("watcher") for _ in range(300)]
    proc, ms = run(cli, ["--socket", stuck.path, "mailbox", "recv", "--drain", "--tab", "watcher"], fx.env(stuck.path),
                   timeout=30)
    root, read = fx.listing("watcher")
    check(proc.returncode == 0 and len(read) == 300 and all(u in proc.stdout.decode() for u in many),
          "plain drain, 300 messages (report far over the socket buffer), socket stops reading: all printed and claimed")
    check(ms < 3000, f"plain drain report bounded by the send deadline ({ms:.0f} ms)")
    stuck.close()
    fx.cleanup()

    # 8. Wedged-then-recovered c11: 70 inboxes, the socket reads nothing for 4 s.
    for label, args, stdin in [
        ("codex hook format", ["mailbox", "recv", "--drain", "--hook-format", "codex"], stop_input),
        ("claude-hook stop", ["claude-hook", "stop"], json.dumps({"hook_event_name": "Stop", "stop_hook_active": False, "session_id": "s"})),
    ]:
        fx = Fixture()
        paused = FakeC11(os.path.join(tmp, f"pause-{len(label)}.sock"), stall=False, pause=4.0)
        ulids = [fx.deliver(TAB.lower(), workspace=w) for w in groups]
        proc, ms = run(cli, ["--socket", paused.path, *args], fx.env(paused.path), stdin, timeout=12)
        out = proc.stdout.decode()
        taken = [u for w, u in zip(groups, ulids) if fx.listing(TAB.lower(), w)[1]]
        check(proc.returncode == 0 and '"decision":"block"' in out and len(taken) >= 50 and all(u in out for u in taken),
              f"{label}, c11 not reading: hook exits 0 with every claimed message ({len(taken)})", out[:120])
        check(ms < 1000, f"{label}, c11 not reading: hook exits in {ms:.0f} ms")
        reports = paused.reports(wait=8.0)
        recorded = [d["id"] for r in reports for d in r.get("deliveries", [])]
        check(sorted(recorded) == sorted(taken), f"{label}: once c11 reads again, all {len(taken)} deliveries are recorded",
              f"{len(recorded)} recorded")
        paused.close()
        fx.cleanup()

    # 9. Pre-claim calls bounded by the claim cutoff.
    fx = Fixture()
    stuck = FakeC11(os.path.join(tmp, "oneline3.sock"), stall=False, one_line=True)
    ulid = fx.deliver(TAB.lower())
    proc, ms = run(cli, ["--socket", stuck.path, "claude-hook", "prompt-submit"], fx.env(stuck.path),
                   json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s"}), timeout=15)
    # Exit status is claude-hook's own business: its status calls time out at
    # the cutoff and it reports that as a hook error, as it always has for a
    # stuck c11 (formerly at the 10 s kill). The mailbox invariant is what
    # this checks.
    check(ms < 8000 and exactly_once(fx, ulid, proc.stdout),
          f"prompt-submit against a c11 that stops reading: exits in {ms / 1000:.1f} s (exit {proc.returncode}); "
          f"the mail is claimed-and-printed or left in the inbox", f"listing={fx.listing(TAB.lower())}")
    stuck.close()
    fx.cleanup()

    # 6. Claim deadline: prompt-submit's status calls take ~2.5 s each before the claim.
    fx = Fixture()
    slow = FakeC11(os.path.join(tmp, "slow.sock"), stall=False, delay=2.5)
    ulid = fx.deliver(TAB.lower())
    prompt_input = json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s"})
    proc, ms = run(cli, ["--socket", slow.path, "claude-hook", "prompt-submit"], fx.env(slow.path), prompt_input,
                   timeout=60)
    check(ms < 8000 and exactly_once(fx, ulid, proc.stdout),
          f"claim cutoff: {ms / 1000:.1f} s of slow pre-claim calls, exit before 8 s, the mail claimed-and-printed "
          f"or left in the inbox", f"stdout={proc.stdout.decode()[:120]!r} listing={fx.listing(TAB.lower())}")
    slow.close()
    if fx.listing(TAB.lower())[1]:
        ulid = fx.deliver(TAB.lower())
    fast = FakeC11(os.path.join(tmp, "fast.sock"), stall=False)
    proc, ms = run(cli, ["--socket", fast.path, "claude-hook", "prompt-submit"], fx.env(fast.path), prompt_input)
    check(ulid in proc.stdout.decode() and fx.listing(TAB.lower())[0] == [] and ulid + ".msg" in fx.listing(TAB.lower())[1],
          f"claim deadline: a prompt-submit with time left delivers it ({ms:.0f} ms)")
    fast.close()
    fx.cleanup()
    shutil.rmtree(tmp, ignore_errors=True)

    if FAILURES:
        print(f"FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("PASS: mailbox drain CLI checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
