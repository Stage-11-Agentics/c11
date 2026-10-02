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
  4. Each drain leaves a delivery receipt in the workspace's `_receipts/`
     spool (how `mailbox.delivered via:"drain"` reaches the app, no socket):
     it names the recipient tab, or none for `recv --tab <name>`, never the
     caller, and it lands in the workspace whose inbox held the mail.
     Receipts always fit their limits: a 600-message drain is split across
     receipts, and a hand-written inbox file (`0note.msg`) is claimed and
     recorded under a fresh ULID without costing the rest of the batch.
  5. A tab moved to another workspace (stale CMUX_WORKSPACE_ID) still finds
     its inbox there, with no socket call.
  6. Prompt-submit never drains (an agent does not act on mail added to a
     turn the operator started); the turn's Stop delivers it. Prompt-submit's
     own socket calls stop at the 6 s cutoff against a slow or stuck c11.
  7. After the claim a hook makes no socket request at all: against a socket
     that reads one line and stops, or reads nothing, with 70 inboxes, in the
     Codex format and through `claude-hook stop`, it exits at once with its
     output intact and its receipts written.

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

    def receipts(self, workspace: str = WORKSPACE) -> list[dict]:
        spool = os.path.join(self.mailboxes.replace(WORKSPACE, workspace), "_receipts")
        if not os.path.isdir(spool):
            return []
        found = []
        for name in sorted(os.listdir(spool)):
            if name.endswith(".receipt"):
                with open(os.path.join(spool, name)) as f:
                    found.append(json.load(f))
        return found

    def receipt_ids(self, workspace: str = WORKSPACE) -> list[str]:
        return [d["id"] for r in self.receipts(workspace) for d in r["deliveries"]]

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

    # 1. Stalled socket.
    fx = Fixture()
    stalled = FakeC11(os.path.join(tmp, "stall.sock"), stall=True)
    ulid = fx.deliver(TAB.lower())
    proc, ms = run(cli, ["--socket", stalled.path, "mailbox", "recv", "--drain", "--hook-format", "codex"],
                   fx.env(stalled.path), stop_input)
    out = proc.stdout.decode()
    check(proc.returncode == 0, "stalled socket: exit 0", f"exit {proc.returncode} {proc.stderr!r}")
    check('"decision":"block"' in out and ulid in out, "stalled socket: hook JSON with the message printed", out[:200])
    check(ms < 1000, f"stalled socket: exits at once ({ms:.0f} ms)")
    check(fx.listing(TAB.lower()) == ([], [ulid + ".msg"]), "stalled socket: envelope claimed into _read/")
    check(fx.receipt_ids() == [ulid], "stalled socket: delivery receipt written", str(fx.receipts()))
    check(stalled.requests == [], "stalled socket: no socket request at all", str(stalled.requests[:2]))
    stalled.close()

    # 2. Empty recipient, sibling holds mail: no socket call before answering.
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

    # 3 + 4. Receipts and attribution.
    fx = Fixture()
    rec = FakeC11(os.path.join(tmp, "rec.sock"), stall=False)
    ulid = fx.deliver(TAB.lower(), to="lane-c-agent")
    proc, _ = run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--hook-format", "codex"],
                  fx.env(rec.path), stop_input)
    receipts = fx.receipts()
    check(len(receipts) == 1 and receipts[0].get("tab_id", "").upper() == TAB and receipts[0].get("via") == "drain",
          "hook drain receipt names the recipient tab", json.dumps(receipts))
    check(bool(receipts) and receipts[0].get("deliveries") == [{"id": ulid, "recipient": "lane-c-agent"}],
          "hook drain receipt names the envelope recipient", json.dumps(receipts))
    spool = os.path.join(fx.mailboxes, "_receipts")
    check(not [n for n in os.listdir(spool) if n.endswith(".tmp")], "receipt written atomically (no temp file left)")
    os.remove(os.path.join(spool, os.listdir(spool)[0]))

    # Plain drain of someone else's (title-keyed) inbox into a closed pipe.
    ids = [fx.deliver("watcher") for _ in range(3)]
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    proc, _ = run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--tab", "watcher"],
                  fx.env(rec.path), stdout=write_fd)
    os.close(write_fd)
    root, read = fx.listing("watcher")
    check(root == sorted(i + ".msg" for i in ids) and read == [],
          "broken pipe: every envelope stays in the inbox, none in _read/", f"root={root} read={read}")
    check(fx.receipts() == [], "broken pipe: no receipt", json.dumps(fx.receipts()))

    rec.requests.clear()
    proc, _ = run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--tab", "watcher"], fx.env(rec.path))
    printed = proc.stdout.decode()
    root, read = fx.listing("watcher")
    check(all(i in printed for i in ids) and root == [] and len(read) == 3,
          "plain drain to a live pipe: all printed and claimed")
    receipts = fx.receipts()
    check(len(receipts) == 1 and "tab_id" not in receipts[0] and sorted(fx.receipt_ids()) == sorted(ids),
          "recv --tab <name>: receipt carries no tab_id rather than the caller's", json.dumps(receipts))
    check(rec.requests == [], "plain drain: no socket request", str(rec.requests[:2]))
    rec.close()
    fx.cleanup()

    # Receipt limits: 600 messages in one plain drain.
    fx = Fixture()
    rec = FakeC11(os.path.join(tmp, "rec600.sock"), stall=False)
    many = [fx.deliver("watcher") for _ in range(600)]
    proc, _ = run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--tab", "watcher"], fx.env(rec.path), timeout=60)
    spool = os.path.join(fx.mailboxes, "_receipts")
    sizes = [os.path.getsize(os.path.join(spool, n)) for n in os.listdir(spool) if n.endswith(".receipt")]
    counts = [len(r["deliveries"]) for r in fx.receipts()]
    check(proc.returncode == 0 and sorted(fx.receipt_ids()) == sorted(many),
          f"600-message drain: every delivery is in a receipt ({len(counts)} receipts: {counts})")
    check(all(c <= 512 for c in counts) and all(b <= 64 * 1024 for b in sizes),
          f"600-message drain: each receipt within 512 deliveries and 64 KB (sizes {sizes})")
    rec.close()
    fx.cleanup()

    # A mixed batch: ULID envelopes plus a hand-written non-envelope file.
    fx = Fixture()
    rec = FakeC11(os.path.join(tmp, "recmix.sock"), stall=False)
    good = [fx.deliver("watcher") for _ in range(3)]
    with open(os.path.join(fx.mailboxes, "watcher", "0note.msg"), "w") as f:
        f.write("hand-written note, not an envelope")
    proc, _ = run(cli, ["--socket", rec.path, "mailbox", "recv", "--drain", "--tab", "watcher"], fx.env(rec.path))
    root, read = fx.listing("watcher")
    minted = [n[:-4] for n in read if n[:-4] not in good]
    note_ok = len(minted) == 1 and "hand-written note" in open(os.path.join(fx.mailboxes, "watcher", "_read", minted[0] + ".msg")).read()
    check("hand-written note" in proc.stdout.decode() and root == [] and len(read) == 4 and note_ok,
          "mixed batch: the hand-written file is drained and claimed under a fresh ULID (_read/<ULID>.msg)", str(read))
    check(note_ok and sorted(fx.receipt_ids()) == sorted(good + minted),
          "mixed batch: one receipt records the envelopes and the hand-written file under its ULID", str(fx.receipt_ids()))
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
    check(stalled.requests == [], "moved tab: no socket request", str(stalled.requests[:2]))
    check(fx.receipt_ids(MOVED_TO) == [ulid] and fx.receipts() == [],
          "moved tab: receipt lands in the workspace that held the inbox")
    stalled.close()
    fx.cleanup()

    # 7. 70 inboxes against a socket that reads one line and stops, then one
    #    that reads nothing; Codex format and claude-hook stop.
    groups = [f"{i:08X}-0000-4000-8000-000000000000" for i in range(1, 71)]
    for label, args, stdin in [
        ("codex hook format", ["mailbox", "recv", "--drain", "--hook-format", "codex"], stop_input),
        ("claude-hook stop", ["claude-hook", "stop"], json.dumps({"hook_event_name": "Stop", "stop_hook_active": False, "session_id": "s"})),
    ]:
        for mode, kwargs in [("reads one line then stops", {"one_line": True}), ("reads nothing", {"pause": 30.0})]:
            fx = Fixture()
            stuck = FakeC11(os.path.join(tmp, f"stuck-{len(label)}-{len(mode)}.sock"), stall=False, **kwargs)
            ulids = [fx.deliver(TAB.lower(), workspace=w) for w in groups]
            proc, ms = run(cli, ["--socket", stuck.path, *args], fx.env(stuck.path), stdin, timeout=12)
            out = proc.stdout.decode()
            taken = [(w, u) for w, u in zip(groups, ulids) if fx.listing(TAB.lower(), w)[1]]
            receipted = all(fx.receipt_ids(w) == [u] for w, u in taken)
            check(proc.returncode == 0 and '"decision":"block"' in out and len(taken) >= 50
                  and all(u in out for _, u in taken) and receipted,
                  f"{label}, socket {mode}: exit 0, every claimed message printed and receipted ({len(taken)})",
                  f"exit {proc.returncode} {out[:120]}")
            check(ms < 1000, f"{label}, socket {mode}: hook exits in {ms:.0f} ms")
            check(stuck.requests == [], f"{label}, socket {mode}: no socket request", str(stuck.requests[:1]))
            stuck.close()
            fx.cleanup()

    # 6 + 9. Prompt-submit never drains; Stop does. Its socket calls stop at
    #        the cutoff against a c11 that is slow or stops reading.
    prompt_input = json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s"})
    for label, kwargs in [("stops reading", {"one_line": True}), ("answers every call after 2.5 s", {"delay": 2.5})]:
        fx = Fixture()
        sock = FakeC11(os.path.join(tmp, f"ps-{len(label)}.sock"), stall=False, **kwargs)
        ulid = fx.deliver(TAB.lower())
        proc, ms = run(cli, ["--socket", sock.path, "claude-hook", "prompt-submit"], fx.env(sock.path), prompt_input, timeout=30)
        # Exit status is claude-hook's own business: its status calls time out
        # at the cutoff and it reports that as a hook error, as it always has
        # for a stuck c11 (formerly at the 10 s kill).
        check(ms < 8000 and ulid not in proc.stdout.decode() and fx.listing(TAB.lower()) == ([ulid + ".msg"], []),
              f"prompt-submit, c11 {label}: exits in {ms / 1000:.1f} s (exit {proc.returncode}), mail left for the Stop")
        sock.close()
        fx.cleanup()

    fx = Fixture()
    fast = FakeC11(os.path.join(tmp, "fast.sock"), stall=False)
    ulid = fx.deliver(TAB.lower())
    proc, ms = run(cli, ["--socket", fast.path, "claude-hook", "prompt-submit"], fx.env(fast.path), prompt_input)
    check(proc.stdout.decode().strip() == "" and fx.listing(TAB.lower()) == ([ulid + ".msg"], []),
          f"prompt-submit with a healthy c11: prints nothing and claims nothing ({ms:.0f} ms)")
    proc, _ = run(cli, ["--socket", fast.path, "claude-hook", "stop"], fx.env(fast.path),
                  json.dumps({"hook_event_name": "Stop", "stop_hook_active": False, "session_id": "s"}))
    check('"decision":"block"' in proc.stdout.decode() and ulid in proc.stdout.decode()
          and fx.listing(TAB.lower()) == ([], [ulid + ".msg"]) and fx.receipt_ids() == [ulid],
          "the turn's Stop then delivers it as the agent's own next turn, receipted")
    proc, _ = run(cli, ["--socket", fast.path, "mailbox", "recv", "--drain", "--hook-format", "codex", "--event", "prompt-submit"],
                  fx.env(fast.path), "")
    check(proc.stdout == b"", "recv --hook-format codex --event prompt-submit: nothing (Codex has no prompt-submit hook either)")
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
