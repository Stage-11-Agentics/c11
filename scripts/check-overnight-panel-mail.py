#!/usr/bin/env python3
"""C11-478 guest acceptance: stale panel reads and rename-safe mailbox replies.

Run on Atlas: C11_SANDBOX_HOST=local scripts/check-overnight-panel-mail.py RUN
RUN must already be running through sandbox-up.sh. All c11 calls go through
sandbox-agent.sh; shell commands and files go through sandbox-exec.sh. This
script never connects to the host's c11 socket. It removes its own panels and
guest temporary files, emits one JSON evidence object, and fails on any row.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid


SCRIPTS = Path(__file__).resolve().parent
READS = (
    ("get-metadata", "panel.get_metadata"),
    ("get-titlebar-state", "panel.get_titlebar_state"),
    ("read-screen", "panel.read_text"),
    ("read-selection", "panel.read_selection"),
    ("input-state", "panel.input_state"),
)


class ProbeDeadline(BaseException):
    """Bypass per-row failure collection so the overall timer stays hard."""


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


class Probe:
    def __init__(self, run):
        self.run = run
        self.env = dict(os.environ)
        self.env.setdefault("C11_SANDBOX_HOST", "local")
        self.nonce = uuid.uuid4().hex[:12]
        self.root = "/tmp/c11-panel-mail-" + self.nonce
        self.panels = []
        self.rows = []
        self.sequence = 0
        self.workspace = None
        self.started = time.monotonic()

    def command(self, script, *argv, check=True, timeout=35):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPTS / script), self.run, *map(str, argv)],
            text=True, capture_output=True, timeout=timeout, env=self.env,
        )
        if check:
            require(result.returncode == 0,
                    f"{script} {argv}: exit={result.returncode} "
                    f"stdout={result.stdout!r} stderr={result.stderr!r}")
        return result

    def c11(self, *argv, check=True):
        return self.command("sandbox-agent.sh", "c11", "--json", "--id-format", "both",
                            *argv, check=check)

    def data(self, *argv):
        return json.loads(self.c11(*argv).stdout)

    def guest(self, code, *argv):
        return self.command("sandbox-exec.sh", "/usr/bin/python3", "-c", code, *argv).stdout

    def row(self, label, action):
        started = time.monotonic()
        try:
            detail = action()
            row = {"check": label, "passed": True, "detail": detail}
        except Exception as error:
            row = {"check": label, "passed": False, "error": str(error)}
        row["seconds"] = round(time.monotonic() - started, 3)
        self.rows.append(row)
        print(("PASS " if row["passed"] else "FAIL ") + label, file=sys.stderr, flush=True)
        return row

    def create(self, title):
        made = self.data("new-panel", "--workspace", self.workspace, "--no-focus")
        panel = made["panel_id"]
        self.panels.append(panel)
        self.c11("rename-panel", "--workspace", self.workspace, "--panel", panel, title)
        self.metadata(panel, "mailbox.delivery", "silent")
        return made

    def metadata(self, panel, key, value):
        self.c11("set-metadata", "--workspace", self.workspace, "--panel", panel,
                 "--key", key, "--value", value, "--type", "string")

    def rename(self, panel, title):
        self.c11("rename-panel", "--workspace", self.workspace, "--panel", panel, title)

    def panel_command(self, panel, argv):
        # Execute in the actual panel shell so sender attribution uses its
        # inherited C11_PANEL_ID. Capture status separately from transport.
        self.sequence += 1
        path = self.root + "/command-" + str(self.sequence) + ".json"
        code = """import json,os,pathlib,subprocess,sys
p=pathlib.Path(sys.argv[1])
try:
 r=subprocess.run(json.loads(sys.argv[2]),text=True,capture_output=True,timeout=15)
 d=dict(returncode=r.returncode,stdout=r.stdout,stderr=r.stderr)
except Exception as e:
 d=dict(returncode=125,stdout='',stderr=str(e))
t=p.with_suffix('.partial');t.write_text(json.dumps(d));os.replace(t,p)
"""
        shell = shlex.join(["/usr/bin/python3", "-c", code, path, json.dumps(argv)])
        self.c11("send", "--workspace", self.workspace, "--panel", panel, shell)
        result = json.loads(self.guest("""import pathlib,sys,time
p=pathlib.Path(sys.argv[1]);deadline=time.monotonic()+20
while not p.exists() and time.monotonic()<deadline: time.sleep(.1)
if not p.exists(): sys.exit('panel command did not finish: '+str(p))
print(p.read_text())
""", path))
        require(result["returncode"] == 0, f"panel {panel}: {argv}: {result}")
        return result["stdout"]

    def send_mail(self, sender, to, body, override=None):
        argv = ["c11", "--json", "mailbox", "send", "--to", to, "--body", body]
        if override is not None:
            argv += ["--from", override]
        return json.loads(self.panel_command(sender, argv))

    def receive(self, panel, expected_id, inbox):
        self.guest("""import pathlib,sys,time
p=pathlib.Path(sys.argv[1])/(sys.argv[2]+'.msg');deadline=time.monotonic()+8
while not p.exists() and time.monotonic()<deadline: time.sleep(.1)
if not p.exists(): sys.exit('expected envelope did not reach inbox: '+str(p))
""", inbox, expected_id)
        output = self.panel_command(panel, ["c11", "mailbox", "recv", "--ack"])
        envelopes = [json.loads(line) for line in output.splitlines() if line.strip()]
        matches = [item for item in envelopes if item.get("id") == expected_id]
        require(len(matches) == 1, f"recv did not drain exactly one expected envelope: {output}")
        self.guest("""import pathlib,sys
p=pathlib.Path(sys.argv[1]);name=sys.argv[2]+'.msg'
assert not (p/name).exists(), 'recv left expected envelope unread'
assert (p/'_read'/name).is_file(), 'recv did not archive expected envelope'
""", inbox, expected_id)
        return matches[0]

    def rejected_read(self, argv):
        result = self.c11(*argv, check=False)
        require(result.returncode != 0, f"stale target succeeded: {result.stdout}")
        require(not result.stdout.strip(), f"stale target returned data: {result.stdout}")
        # Match the complete code at the start of an error line: accepting a
        # substring would incorrectly treat surface_not_found as not_found.
        exact_code = re.search(r"(?im)^(?:Error:\s*)?not_found:", result.stderr)
        cli_ref_error = argv[0] != "rpc" and re.search(
            r"(?im)^(?:Error:\s*)?Panel ref not found:", result.stderr
        )
        require(exact_code or cli_ref_error,
                f"stale target did not report exact not_found: {result.stderr}")
        return {"exit": result.returncode, "code": "not_found" if exact_code else "cli_ref_not_found",
                "stderr": result.stderr.strip(), "stdout": result.stdout}

    def valid_read(self, command, panel, marker):
        payload = self.data(command, "--workspace", self.workspace, "--panel", panel)
        actual = payload.get("panel_id", payload.get("surface_id"))
        require(str(actual).lower() == panel.lower(), f"{command} read another panel: {payload}")
        if command == "get-metadata":
            require(payload["metadata"].get("description") == marker, f"wrong metadata: {payload}")
        elif command == "get-titlebar-state":
            require(payload.get("description") == marker, f"wrong titlebar: {payload}")
        elif command == "read-screen":
            require(marker in payload.get("text", ""), f"wrong terminal text: {payload}")
        return {"panel_id": actual, "workspace_id": payload.get("workspace_id")}

    def setup(self):
        self.guest("""from pathlib import Path
import sys
assert Path('/Volumes/My Shared Files/out').is_dir(), 'not a sandbox guest'
Path(sys.argv[1]).mkdir()
""", self.root)
        self.workspace = self.data("current-workspace")["workspace_id"]
        a = self.create("unaddressed-" + self.nonce)["panel_id"]
        b = self.create("addressed-original-" + self.nonce)["panel_id"]
        recipient = self.create("recipient-" + self.nonce)["panel_id"]
        stale = self.create("closed-" + self.nonce)
        self.c11("close-panel", "--workspace", self.workspace, "--panel", stale["panel_id"])
        self.panels.remove(stale["panel_id"])
        for panel in (a, b):
            marker = "PRIVATE-" + panel
            self.metadata(panel, "description", marker)
            self.panel_command(panel, ["/usr/bin/true"])
            # Print marker without redirecting it, to establish real terminal
            # content before checking the read-screen response and attribution.
            self.c11("send", "--workspace", self.workspace, "--panel", panel,
                     "printf '%s\\n' " + shlex.quote(marker))
        self.c11("rpc", "panel.focus", json.dumps({"workspace_id": self.workspace, "panel_id": a}))
        return a, b, recipient, stale

    def read_checks(self, a, b, stale):
        stale_refs = (("closed ordinal", stale["panel_ref"]),
                      ("unknown ordinal", "panel:999999999"))
        for command, method in READS:
            for panel in (a, b):
                self.row(f"{command} valid {panel}",
                         lambda command=command, panel=panel:
                         self.valid_read(command, panel, "PRIVATE-" + panel))
            for label, stale_ref in stale_refs:
                self.row(command + " " + label + " CLI", lambda command=command, stale_ref=stale_ref:
                         self.rejected_read([command, "--workspace", self.workspace, "--panel", stale_ref]))
                for key in ("panel_id", "surface_id", "tab_id"):
                    params = {"workspace_id": self.workspace, key: stale_ref}
                    self.row(method + " " + label + " " + key, lambda method=method, params=params:
                             self.rejected_read(["rpc", method, json.dumps(params)]))
            params = {"workspace_id": self.workspace, "panel_id": stale["panel_id"]}
            self.row(method + " closed UUID", lambda method=method, params=params:
                     self.rejected_read(["rpc", method, json.dumps(params)]))

    def mail_checks(self, a, b, recipient):
        address = "stable-" + self.nonce
        self.metadata(b, "mailbox.address", address)
        inboxes = {panel: self.panel_command(panel, ["c11", "mailbox", "inbox-dir"]).strip()
                   for panel in (a, b, recipient)}
        for label, sender, expected in (("unaddressed", a, "id:" + a.lower()),
                                        ("addressed", b, address)):
            def exchange(label=label, sender=sender, expected=expected):
                body = "request-" + label + "-" + self.nonce
                sent = self.send_mail(sender, "id:" + recipient.lower(), body)
                original = self.receive(recipient, sent["id"], inboxes[recipient])
                require(original["body"] == body, f"wrong original body: {original}")
                # Rename before replying to the ORIGINAL envelope, and give
                # its old title to another panel. A stale-title reply is then
                # positively misrouted instead of merely unresolved.
                old_title = ("unaddressed-" if sender == a else "addressed-original-") + self.nonce
                self.rename(sender, "renamed-" + label + "-" + self.nonce)
                self.rename(recipient, old_title)
                from_row = self.row(label + " envelope from", lambda:
                                    self.check_from(sent, original, expected))
                reply = self.send_mail(recipient, original["from"], "reply-" + body)
                received = self.receive(sender, reply["id"], inboxes[sender])
                require(received["body"] == "reply-" + body, f"wrong reply: {received}")
                require(from_row["passed"], "reply arrived but sender stamp assertion failed")
                return {"original": original, "reply": received, "sender_panel": sender}
            self.row(label + " actual reply after rename", exchange)
        for label, sender in (("unaddressed", a), ("addressed", b)):
            def override(sender=sender):
                chosen = "explicit-" + self.nonce
                sent = self.send_mail(sender, "id:" + recipient.lower(), "override", chosen)
                original = self.receive(recipient, sent["id"], inboxes[recipient])
                return self.check_from(sent, original, chosen)
            self.row(label + " explicit --from preserved", override)

    @staticmethod
    def check_from(sent, original, expected):
        require(sent["from"] == expected, f"send reported {sent['from']!r}, expected {expected!r}")
        require(original["from"] == expected, f"envelope stamped {original['from']!r}, expected {expected!r}")
        return {"id": original["id"], "from": original["from"]}

    def cleanup(self):
        for panel in reversed(self.panels):
            self.row("cleanup panel " + panel, lambda panel=panel:
                     self.c11("close-panel", "--workspace", self.workspace, "--panel", panel).stdout.strip())
        self.row("cleanup guest files", lambda: self.guest(
            "import pathlib,shutil,sys;p=pathlib.Path(sys.argv[1]);"
            "assert p.parent==pathlib.Path('/tmp') and p.name.startswith('c11-panel-mail-');"
            "shutil.rmtree(p,ignore_errors=True)", self.root))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", metavar="RUN", help="existing sandbox-up.sh run ID")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,48}", args.run):
        parser.error("RUN is not a safe sandbox run ID")
    probe = Probe(args.run)

    def expired(signum, frame):
        raise ProbeDeadline("acceptance exceeded its five-minute deadline")

    signal.signal(signal.SIGALRM, expired)
    signal.alarm(300)
    try:
        a, b, recipient, stale = probe.setup()
        probe.read_checks(a, b, stale)
        probe.row("mailbox exchanges", lambda: probe.mail_checks(a, b, recipient))
    except (Exception, ProbeDeadline) as error:
        probe.rows.append({"check": "setup or execution", "passed": False, "error": str(error)})
    finally:
        signal.alarm(0)
        probe.cleanup()
    passed = bool(probe.rows) and all(row["passed"] for row in probe.rows)
    print(json.dumps({"run": args.run, "passed": passed, "workspace": probe.workspace,
                      "seconds": round(time.monotonic() - probe.started, 3),
                      "checks": probe.rows}, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
