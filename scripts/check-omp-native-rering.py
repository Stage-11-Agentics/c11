#!/usr/bin/env python3
"""Prove Workspace's omp hard-failure recovery in an isolated sandbox guest.

Run on Atlas: C11_SANDBOX_HOST=local scripts/check-omp-native-rering.py RUN_ID --out DIR
No staged agent or provider credentials are needed. A foreground raw-terminal
fixture uses the production omp native subscription, withholds its first ack,
and accepts its second invitation. This proves routing, not the real omp TUI.
The caller owns the sandbox; this script removes only its own panels and files.
"""
import argparse
import base64
import json
import os
import pathlib
import shlex
import subprocess
import time
import uuid

SCRIPTS = pathlib.Path(__file__).resolve().parent
DOORBELL = "c11 mail waiting: run c11 mailbox recv --ack"

FIXTURE = r'''
import json, os, pathlib, select, socket, sys, termios, time, tty, uuid

root, workspace, panel = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
events = root / "events.jsonl"
control = root / "control.json"
socket_path = os.environ["C11_SOCKET_PATH"]
pid = os.getpid()
draft = ""

def log(event, **data):
    with events.open("a") as stream:
        stream.write(json.dumps(dict(event=event, at=time.time(), **data)) + "\n")

def idle():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(socket_path)
        client.sendall(("report_agent_activity idle --tab=" + workspace +
                        " --panel=" + panel + " --pid=" + str(pid) + "\n").encode())
        response = client.recv(4096).decode().strip()
        if not response.startswith("OK"):
            raise RuntimeError("idle report refused: " + response)

assert os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp(), "fixture must own its terminal"
original = termios.tcgetattr(0)
native = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    tty.setraw(0)
    idle()
    native.settimeout(5)
    native.connect(socket_path)
    native.sendall((json.dumps(dict(id="subscribe", method="mailbox.native.subscribe", params=dict(
        panel_id=panel, agent_pid=pid, session_id=str(uuid.uuid4()), route="omp_extension", can_queue=False
    ))) + "\n").encode())
    pending = b""
    while b"\n" not in pending:
        chunk = native.recv(65536)
        if not chunk:
            raise RuntimeError("subscription closed before acknowledgement")
        pending += chunk
    line, pending = pending.split(b"\n", 1)
    response = json.loads(line)
    assert response.get("ok") and response.get("result", {}).get("subscription_id"), response
    native.setblocking(False)
    log("ready", pid=pid, subscription=response["result"]["subscription_id"])
    os.write(1, b"OMP native routing fixture\r\nDraft> ")
    last_control = None
    deliveries = 0
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        if control.exists():
            request = json.loads(control.read_text())
            if request["sequence"] != last_control:
                last_control = request["sequence"]
                idle()
                log("idle", sequence=last_control, draft=draft)
        readable, _, _ = select.select([0, native], [], [], 0.1)
        if 0 in readable:
            data = os.read(0, 65536)
            if not data:
                break
            draft += data.decode("utf-8", errors="replace")
            os.write(1, data)
            log("draft", draft=draft)
        if native in readable:
            chunk = native.recv(65536)
            if not chunk:
                raise RuntimeError("native subscription closed")
            pending += chunk
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            frame = json.loads(line)
            if frame.get("type") != "deliver":
                raise RuntimeError("unexpected native frame: " + repr(frame))
            deliveries += 1
            log("deliver", number=deliveries, frame=frame, draft=draft)
            if deliveries == 1:
                # No side effect and no acknowledgement: use c11's real deadline.
                log("withheld", delivery_id=frame["delivery_id"], draft=draft)
            else:
                native.sendall((json.dumps(dict(type="accepted", delivery_id=frame["delivery_id"])) + "\n").encode())
                log("accepted", delivery_id=frame["delivery_id"], draft=draft)
    log("stopped", draft=draft)
except BaseException as error:
    log("error", error=repr(error), draft=draft)
    raise
finally:
    native.close()
    termios.tcsetattr(0, termios.TCSANOW, original)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id")
    parser.add_argument("--out", type=pathlib.Path, default=pathlib.Path("/tmp/c11-omp-rering-proof"))
    args = parser.parse_args()
    if os.environ.get("C11_SANDBOX_HOST") != "local":
        parser.error("run on Atlas with C11_SANDBOX_HOST=local; this proof only addresses a sandbox guest")
    args.out.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    nonce = uuid.uuid4().hex[:12]
    root = "/tmp/c11-omp-rering-" + nonce
    panels = []
    observations = {"passed": False, "fixture": "raw foreground omp native subscriber"}
    workspace = target = None

    def command(script, *argv):
        result = subprocess.run([str(SCRIPTS / script), args.run_id, *map(str, argv)],
                                text=True, capture_output=True, timeout=45)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout.strip()

    def c11(*argv):
        if "--json" in argv:
            argv = ("--json", "--id-format", "both", *(arg for arg in argv if arg != "--json"))
        return command("sandbox-agent.sh", "c11", *argv)

    def guest(code, *argv):
        return command("sandbox-exec.sh", "/usr/bin/python3", "-c", code, *argv)

    def inspect():
        return json.loads(guest('''import json,pathlib,sys
root=pathlib.Path.home()/"Library/Application Support/c11/workspaces"/sys.argv[1].upper()/"mailboxes"
def lines(path):
 if not path.exists(): return []
 result=[]
 for line in path.read_text().splitlines():
  try: result.append(json.loads(line))
  except ValueError: pass
 return result
inbox=root/sys.argv[2].lower()
print(json.dumps(dict(events=lines(pathlib.Path(sys.argv[3])/"events.jsonl"),dispatch=lines(root/"_dispatch.log"),unread=[p.stem for p in inbox.glob("*.msg")],read=[p.stem for p in (inbox/"_read").glob("*.msg")])))''', workspace, target, root))

    def wait(label, predicate, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            data = inspect()
            errors = [event for event in data["events"] if event["event"] == "error"]
            assert not errors, errors
            if predicate(data):
                return data
            time.sleep(0.3)
        raise AssertionError("Timed out: " + label)

    def deliveries(data):
        return [event for event in data["events"] if event["event"] == "deliver"]

    def dispatch(data, mail_id, reason):
        return [event for event in data["dispatch"] if event.get("id") == mail_id and event.get("reason") == reason]

    try:
        workspace = json.loads(c11("current-workspace", "--json"))["workspace_id"]
        for label in ("sender", "target"):
            panel = json.loads(c11("new-panel", "--workspace", workspace, "--no-focus", "--json"))["panel_id"]
            panels.append(panel)
        sender, target = panels
        address = "omp-rering-" + nonce
        for key, value in (("mailbox.address", address), ("mailbox.delivery", "stdin")):
            c11("set-metadata", "--workspace", workspace, "--panel", target, "--key", key, "--value", value, "--type", "string")
        c11("set-agent", "--workspace", workspace, "--panel", target, "--type", "omp")
        guest('import base64,pathlib,sys;p=pathlib.Path(sys.argv[1]);p.mkdir();(p/"fixture.py").write_bytes(base64.b64decode(sys.argv[2]))',
              root, base64.b64encode(FIXTURE.encode()).decode())
        c11("send", "--workspace", workspace, "--panel", target,
            shlex.join(["/usr/bin/python3", "-u", root + "/fixture.py", root, workspace, target]))
        wait("foreground native subscriber ready", lambda data: any(e["event"] == "ready" for e in data["events"]))
        draft = "UNSENT-OMP-RERING-" + nonce
        c11("send", "--workspace", workspace, "--panel", target, "--raw", "--no-submit", draft)
        wait("draft received unchanged", lambda data: any(e["event"] == "draft" and e["draft"] == draft for e in data["events"]))

        def mail(label):
            result_path = root + "/send-" + label
            shell = shlex.join(["c11", "mailbox", "send", "--to", address, "--body", label])
            c11("send", "--workspace", workspace, "--panel", sender, shell + " > " + shlex.quote(result_path))
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                result = guest('import pathlib,sys;p=pathlib.Path(sys.argv[1]);print(p.read_text().strip() if p.exists() else "")', result_path)
                if result:
                    assert len(result.splitlines()) == 1, result
                    return result
                time.sleep(0.3)
            raise AssertionError("sibling send did not return an envelope ID")

        first = mail("first")
        observations["first_id"] = first
        data = wait("first invitation times out", lambda d: bool(dispatch(d, first, "native_timeout")))
        assert len(deliveries(data)) == 1, data
        assert first in data["unread"] and first not in data["read"], data

        # Repeat the actual lifecycle edge while only the failed ID is unread.
        for sequence in range(3):
            guest('import json,pathlib,sys;p=pathlib.Path(sys.argv[1]);t=p/"control.tmp";t.write_text(json.dumps({"sequence":int(sys.argv[2])}));t.replace(p/"control.json")', root, sequence)
            wait("idle recheck " + str(sequence), lambda d: any(e["event"] == "idle" and e["sequence"] == sequence for e in d["events"]))
            time.sleep(0.5)
        time.sleep(2)
        data = inspect()
        assert len(deliveries(data)) == 1, "same failed envelope retried: " + repr(data)
        assert len(dispatch(data, first, "started")) == 1, data
        observations["same_failed_mail_held"] = data

        second = mail("second")
        observations["second_id"] = second
        wait("new mail submits through omp native route", lambda d: bool(dispatch(d, second, "submitted")))
        time.sleep(2)
        data = inspect()
        assert first != second and len(deliveries(data)) == 2, data
        for event in deliveries(data):
            assert event["draft"] == draft and event["frame"]["text"] == DOORBELL, event
        submitted = dispatch(data, second, "submitted")
        assert len(submitted) == 1 and submitted[0].get("route") == "omp_extension", submitted
        assert all(mail_id in data["unread"] and mail_id not in data["read"] for mail_id in (first, second)), data
        assert all(event["draft"] == draft for event in data["events"] if event["event"] in ("deliver", "accepted", "idle")), data
        assert [event["draft"] for event in data["events"] if event["event"] == "draft"][-1] == draft, data
        observations["new_mail_native"] = data
        observations["screen"] = c11("read-screen", "--workspace", workspace, "--panel", target, "--lines", "40")
        assert draft in observations["screen"], observations["screen"]
        observations["passed"] = True
        print("PASS: hard timeout, repeated idle checks held, new mail rung natively, both unread, draft preserved")
    except BaseException as error:
        observations["error"] = repr(error)
        raise
    finally:
        if target:
            try:
                observations["final"] = inspect()
            except Exception as error:
                observations["inspect_error"] = repr(error)
        for panel in reversed(panels):
            try:
                c11("close-panel", "--workspace", workspace, "--panel", panel)
            except Exception as error:
                observations.setdefault("cleanup_errors", []).append(str(error))
        try:
            guest('import pathlib,shutil,sys;p=pathlib.Path(sys.argv[1]);shutil.rmtree(p) if p.exists() else None', root)
        except Exception as error:
            observations.setdefault("cleanup_errors", []).append(str(error))
        observations["seconds"] = round(time.monotonic() - started, 3)
        (args.out / "proof.json").write_text(json.dumps(observations, indent=2) + "\n")
        if observations.get("cleanup_errors"):
            raise RuntimeError("proof panel cleanup failed: " + repr(observations["cleanup_errors"]))


if __name__ == "__main__":
    main()
