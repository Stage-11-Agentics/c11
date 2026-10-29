#!/usr/bin/env python3
"""
C11-491: a panel moved to another workspace keeps the C11_WORKSPACE_ID its
shell started with. The CLI must find the caller by its panel UUID, against a
fake c11 that answers like the app after a move to another window: a request
that pins the start workspace finds no such panel there.

  1. `mailbox send` asks for the caller by panel only, then names the live
     workspace to `mailbox.resolve` and in the envelope's sender claim. The
     envelope's `from` is the caller's mailbox address.
  2. `mailbox panel-name` and `mailbox outbox-dir` follow the live workspace.
  3. `mailbox recv` reads the live inbox and the ones left in each workspace
     the panel passed through, and only this panel's.
     A `--panel` ref names that panel wherever it is, not a panel title.
  4. A caller panel c11 cannot find, or one with no title, gets an error that
     names its UUID and says why, never "(untitled)".
  5. Panel-targeted commands (`capture-pane --surface panel:N`, a bare
     `read-screen`, `notify`, flashes, `new-split`, `close-panel`,
     `read-selection`, `input-state`) send no workspace beside a panel named
     by UUID or ref, so c11 finds it wherever it is.
  6. With `panel.locate` (C11-499), every command that defaults to the
     caller's workspace follows the moved panel, sidebar writes and creation
     commands included; an app without it keeps the start workspace.

Run: C11_CLI_BIN=<path to c11> python3 tests/test_cli_moved_panel_caller.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("drain", HERE / "test_mailbox_hook_drain_cli.py")
drain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drain)

START = drain.WORKSPACE     # C11_WORKSPACE_ID in the caller's environment
LIVE = drain.MOVED_TO       # where the panel is now
PANEL = drain.TAB           # C11_PANEL_ID
RECIPIENT = drain.SIBLING
PASSED_THROUGH = "7A6B5C4D-3E2F-4A1B-9C8D-7E6F5A4B3C2D"   # a workspace between START and LIVE


class MovedPanelServer(drain.FakeC11):
    """`metadata` is what c11 holds for the caller panel; None means the
    panel is open nowhere."""

    def __init__(self, path: str, metadata: dict | None, locate: bool = False, locate_delay: float = 0.0):
        self.metadata = metadata
        self.locate = locate   # an app with `panel.locate` (C11-499); older apps answer {}
        self.locate_delay = locate_delay
        super().__init__(path, False)

    def answer(self, method: str, params: dict) -> tuple[dict | None, dict | None]:
        pinned = params.get("workspace_id")
        if method == "system.capabilities" and self.locate:
            return {"methods": ["panel.list", "mailbox.resolve", "panel.read_text", "panel.locate"],
                    "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}, None
        if method == "panel.locate" and self.locate:
            time.sleep(self.locate_delay)
            if str(params.get("panel_id", "")).upper() == PANEL:
                return {"panel_id": PANEL, "workspace_id": LIVE}, None
            return None, {"code": "not_found", "message": "Panel not found"}
        if method == "system.capabilities":
            return {"methods": ["panel.list", "mailbox.resolve", "panel.read_text"],
                    "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}, None
        target = str(params.get("panel_id", ""))
        if method == "panel.get_metadata" and target.upper() in ("PANEL:136", RECIPIENT):
            # The app's reply after wire alias completion names the panel `panel_id`.
            return {"workspace_id": PASSED_THROUGH, "panel_id": RECIPIENT, "metadata": {"title": "Recipient"}}, None
        if method == "panel.get_metadata" and target.startswith("panel:"):
            return None, {"code": "not_found", "message": f"Unknown panel_id: {target}; commands with "
                          "explicit targets never fall back to the focused target"}
        if method == "panel.get_metadata":
            if self.metadata is None:
                # What the app answers for a panel UUID it does not know.
                return None, {"code": "not_found", "message": f"Unknown panel_id: {PANEL}; commands with "
                              "explicit targets never fall back to the focused target"}
            if pinned and pinned.upper() != LIVE:
                return None, {"code": "surface_not_found", "message": "Panel not found"}
            return {"workspace_id": LIVE, "surface_id": PANEL, "metadata": self.metadata}, None
        if method == "mailbox.resolve":
            if str(params.get("to", "")).startswith("panel:"):
                return {"resolution": "none", "panel_ids": []}, None   # a ref is no panel's name
            return {"resolution": "unique", "target_workspace_id": START, "panel_ids": [RECIPIENT]}, None
        if method == "panel.read_text":
            if pinned and pinned.upper() != LIVE:
                return None, {"code": "invalid_params", "message": "Panel is not a terminal"}
            return {"text": "moved screen"}, None
        return {}, None

    def _serve(self, conn):
        try:
            with conn, conn.makefile("rb") as handle:
                for line in handle:
                    try:
                        request = json.loads(line)
                    except ValueError:
                        self.requests.append({"v1": line.decode(errors="replace").strip()})
                        conn.sendall(b"OK\n")
                        continue
                    self.requests.append(request)
                    result, error = self.answer(request.get("method"), request.get("params") or {})
                    reply = {"id": request.get("id"), "ok": error is None}
                    reply.update({"error": error} if error else {"result": result})
                    conn.sendall(json.dumps(reply).encode() + b"\n")
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def params_of(self, method: str) -> list[dict]:
        return [r.get("params") or {} for r in self.requests if r.get("method") == method]


FAILURES: list[str] = []


def check(condition: bool, label: str, detail: str = "") -> None:
    print(("PASS: " if condition else "FAIL: ") + label + (f" ({detail})" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


def outbox_envelopes(fixture: drain.Fixture) -> list[dict]:
    files = pathlib.Path(fixture.home).glob(
        "Library/Application Support/c11/workspaces/*/mailboxes/_outbox/*.msg"
    )
    return [json.loads(path.read_text()) for path in files]


def main() -> int:
    cli = drain.resolve_cli()
    tmp = tempfile.mkdtemp(prefix="c11-moved-sock-")
    titled = {"title": "Move fixer", "mailbox.address": "c11-move-fixer"}
    try:
        # 1. send
        fixture = drain.Fixture()
        server = MovedPanelServer(os.path.join(tmp, "send.sock"), titled)
        try:
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "send", "--to", "watcher", "hello"],
                                fixture.env(server.path))
            detail = f"rc={proc.returncode} stderr={proc.stderr[:300]!r}"
            check(proc.returncode == 0, "send from a moved panel succeeds", detail)
            lookups = server.params_of("panel.get_metadata")
            check(bool(lookups) and all("workspace_id" not in p for p in lookups),
                  "send looks the caller up by panel only", repr(lookups))
            resolves = server.params_of("mailbox.resolve")
            check([p.get("sender_workspace_id", "").upper() for p in resolves] == [LIVE],
                  "mailbox.resolve names the live workspace", repr(resolves))
            envelopes = outbox_envelopes(fixture)
            claim = (envelopes[0].get("ext") or {}).get("c11_sender_claim") if len(envelopes) == 1 else None
            check(len(envelopes) == 1 and envelopes[0].get("from") == "c11-move-fixer",
                  "envelope from is the caller's mailbox address", repr(envelopes))
            check(claim == {"panel": PANEL.lower(), "workspace": LIVE.lower()},
                  "sender claim names the live workspace", repr(claim))
        finally:
            fixture.cleanup()

        # 2. panel-name, outbox-dir
        fixture = drain.Fixture()
        server = MovedPanelServer(os.path.join(tmp, "name.sock"), titled)
        try:
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "panel-name"], fixture.env(server.path))
            check(proc.returncode == 0 and proc.stdout.decode().strip() == "Move fixer",
                  "panel-name prints the moved panel's title", f"rc={proc.returncode} out={proc.stdout!r} err={proc.stderr!r}")
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "outbox-dir"], fixture.env(server.path))
            out = proc.stdout.decode().strip()
            check(proc.returncode == 0 and LIVE in out.upper() and START not in out.upper(),
                  "outbox-dir is in the live workspace", f"rc={proc.returncode} out={out!r} err={proc.stderr!r}")
        finally:
            fixture.cleanup()

        # 3. recv reads the live inbox and the start workspace's
        fixture = drain.Fixture()
        server = MovedPanelServer(os.path.join(tmp, "recv.sock"), titled)
        try:
            fixture.deliver(PANEL.lower(), body="before the move", workspace=START)
            fixture.deliver(PANEL.lower(), body="between the moves", workspace=PASSED_THROUGH)
            fixture.deliver(PANEL.lower(), body="after the move", workspace=LIVE)
            fixture.deliver(RECIPIENT.lower(), body="someone else's mail", workspace=PASSED_THROUGH)
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "recv", "--peek"], fixture.env(server.path))
            out = proc.stdout.decode()
            check(proc.returncode == 0 and "before the move" in out and "between the moves" in out
                  and "after the move" in out and "someone else" not in out,
                  "recv shows the panel's mail from every workspace it passed through",
                  f"rc={proc.returncode} out={out[:400]!r} err={proc.stderr!r}")
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "recv", "--drain", "--ack"],
                                fixture.env(server.path))
            remaining = [fixture.listing(PANEL.lower(), workspace=ws)[0] for ws in (START, PASSED_THROUGH, LIVE)]
            check(proc.returncode == 0 and remaining == [[], [], []],
                  "recv --drain claims the mail in every one of them",
                  f"rc={proc.returncode} remaining={remaining!r} err={proc.stderr!r}")
        finally:
            fixture.cleanup()

        # 3b. a --panel ref is that panel, wherever it is, not a name
        fixture = drain.Fixture()
        server = MovedPanelServer(os.path.join(tmp, "ref.sock"), titled)
        try:
            fixture.deliver(RECIPIENT.lower(), body="for the recipient", workspace=PASSED_THROUGH)
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "inbox-dir", "--panel", "panel:136"],
                                fixture.env(server.path))
            out = proc.stdout.decode().strip()
            check(proc.returncode == 0 and PASSED_THROUGH in out.upper() and RECIPIENT.lower() in out,
                  "inbox-dir --panel <ref> prints that panel's inbox", f"rc={proc.returncode} out={out!r} err={proc.stderr!r}")
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "recv", "--peek", "--panel", "panel:136"],
                                fixture.env(server.path))
            check(proc.returncode == 0 and "for the recipient" in proc.stdout.decode(),
                  "recv --panel <ref> reads that panel's inbox", f"rc={proc.returncode} out={proc.stdout!r} err={proc.stderr!r}")
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "inbox-dir", "--panel", RECIPIENT.upper()],
                                fixture.env(server.path))
            out = proc.stdout.decode().strip()
            check(proc.returncode == 0 and PASSED_THROUGH in out.upper() and RECIPIENT.lower() in out,
                  "inbox-dir --panel <UUID> prints that panel's live inbox", f"rc={proc.returncode} out={out!r} err={proc.stderr!r}")
            fixture.deliver(RECIPIENT.lower(), body="left behind", workspace=START)
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "recv", "--drain", "--ack", "--panel", "panel:136"],
                                fixture.env(server.path))
            out = proc.stdout.decode()
            remaining = [fixture.listing(RECIPIENT.lower(), workspace=ws)[0] for ws in (START, PASSED_THROUGH)]
            check(proc.returncode == 0 and "for the recipient" in out and "left behind" in out and remaining == [[], []],
                  "recv --drain --panel <ref> claims that panel's mail in every workspace",
                  f"rc={proc.returncode} out={out[:300]!r} remaining={remaining!r} err={proc.stderr!r}")
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "recv", "--peek", "--panel", "panel:999"],
                                fixture.env(server.path))
            check(proc.returncode != 0 and "panel:999" in proc.stderr.decode(),
                  "recv --panel <unknown ref> is an error, not an empty inbox",
                  f"rc={proc.returncode} out={proc.stdout!r} err={proc.stderr!r}")
            proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "inbox-dir", "--panel", "watcher"],
                                fixture.env(server.path))
            out = proc.stdout.decode().strip()
            check(proc.returncode == 0 and START in out.upper() and RECIPIENT.lower() in out,
                  "inbox-dir --panel <name> still matches by name", f"rc={proc.returncode} out={out!r} err={proc.stderr!r}")
        finally:
            fixture.cleanup()

        # 4. errors name the panel
        for index, (label, metadata, reason) in enumerate((
            ("caller open nowhere", None, "not open"),
            ("caller with no title", {}, "no title"),
        )):
            fixture = drain.Fixture()
            server = MovedPanelServer(os.path.join(tmp, f"err-{index}.sock"), metadata)
            try:
                proc, _ = drain.run(cli, ["--socket", server.path, "mailbox", "send", "--to", "watcher", "hi"],
                                    fixture.env(server.path))
                err = proc.stderr.decode()
                check(proc.returncode != 0 and PANEL in err and reason in err and "(untitled)" not in err
                      and "Unknown panel_id" not in err
                      and not outbox_envelopes(fixture),
                      f"{label}: error names the panel and why", f"rc={proc.returncode} err={err!r}")
            finally:
                fixture.cleanup()

        # 5. panel-ref reads
        fixture = drain.Fixture()
        server = MovedPanelServer(os.path.join(tmp, "read.sock"), titled)
        try:
            for argv in (["capture-pane", "--surface", "panel:7"], ["read-screen"]):
                before = len(server.params_of("panel.read_text"))
                proc, _ = drain.run(cli, ["--socket", server.path, *argv], fixture.env(server.path))
                sent = server.params_of("panel.read_text")[before:]
                check(proc.returncode == 0 and proc.stdout.decode().strip() == "moved screen"
                      and sent and all("workspace_id" not in p for p in sent),
                      f"{argv[0]} finds a moved panel", f"rc={proc.returncode} sent={sent!r} err={proc.stderr!r}")
            for argv, method in (
                (["notify", "--title", "done"], "notification.create_for_panel"),
                (["trigger-flash"], "panel.trigger_flash"),
                (["cancel-flash"], "panel.cancel_flash"),
                (["new-split", "right"], "panel.split"),
                (["close-panel", "--panel", "panel:7"], "panel.close"),
                (["read-selection"], "panel.read_selection"),
                (["input-state", "--panel", "panel:7"], "panel.input_state"),
            ):
                before = len(server.params_of(method))
                proc, _ = drain.run(cli, ["--socket", server.path, *argv], fixture.env(server.path))
                sent = server.params_of(method)[before:]
                check(sent and all("workspace_id" not in p and p.get("panel_id") for p in sent),
                      f"{argv[0]} sends the panel without the start workspace",
                      f"rc={proc.returncode} sent={sent!r} err={proc.stderr[:200]!r}")
        finally:
            fixture.cleanup()
        # 6. C11-499: with `panel.locate`, every command that defaults to the
        # caller's workspace follows the moved panel; an older app keeps it.
        fixture = drain.Fixture()
        server = MovedPanelServer(os.path.join(tmp, "locate.sock"), titled, locate=True)
        note = os.path.join(tmp, "note.md")
        with open(note, "w") as handle:
            handle.write("# note\n")
        try:
            for argv in (
                ["list-panels"], ["browser", "open", "https://example.com"], ["new-panel", "--type", "terminal"],
                ["new-area"], ["markdown", "open", note], ["set-status", "build", "ok"], ["log", "hello"],
                ["set-progress", "0.5"], ["get-titlebar-state"], ["panel-action", "rename", "--title", "x"],
                ["workspace-action", "--workspace", "self", "rename", "--title", "x"],
                ["send", "--panel", "panel:3", "hi"], ["send-key", "--panel", "panel:3", "enter"],
                ["pipe-pane", "--command", "cat"], ["clear-history"],
                ["close-panel", "--workspace", "self", "--panel", "panel:3"],
            ):
                before = len(server.requests)
                proc, _ = drain.run(cli, ["--socket", server.path, *argv], fixture.env(server.path))
                sent = [r for r in server.requests[before:] if r.get("method") not in ("system.capabilities", "panel.locate")]
                named = json.dumps(sent).upper()
                check(proc.returncode == 0 and LIVE in named and START not in named,
                      f"{' '.join(argv[:2])} follows the moved panel's workspace",
                      f"rc={proc.returncode} sent={sent!r} err={proc.stderr[:200]!r}")
        finally:
            fixture.cleanup()
        # A lookup that outlasts the deadline must not leave its late reply to
        # be read as the next command's answer: the CLI reconnects.
        fixture = drain.Fixture()
        server = MovedPanelServer(os.path.join(tmp, "slow.sock"), titled, locate=True, locate_delay=0.8)
        try:
            env = dict(fixture.env(server.path), C11_DEFAULT_SOCKET_DEADLINE_MS="300")
            proc, _ = drain.run(cli, ["--socket", server.path, "--json", "list-panels"], env)
            out = proc.stdout.decode()
            # The late locate reply names the panel; list-panels' own does not.
            check(proc.returncode == 0 and PANEL not in out.upper() and len(server.params_of("panel.list")) == 1,
                  "a slow panel.locate reconnects instead of reading its late reply",
                  f"rc={proc.returncode} out={out[:200]!r} err={proc.stderr[:200]!r}")
        finally:
            fixture.cleanup()
        fixture = drain.Fixture()
        server = MovedPanelServer(os.path.join(tmp, "old-app.sock"), titled)
        try:
            proc, _ = drain.run(cli, ["--socket", server.path, "list-panels"], fixture.env(server.path))
            listed = server.params_of("panel.list")
            check(proc.returncode == 0 and [p.get("workspace_id", "").upper() for p in listed] == [START],
                  "an app without panel.locate keeps the start workspace", f"rc={proc.returncode} sent={listed!r}")
        finally:
            fixture.cleanup()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
