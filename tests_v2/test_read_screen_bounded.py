#!/usr/bin/env python3
"""C11-295: bounded production reads, complete framing, and stale targets.

Run only in the sandbox guest against an explicit isolated C11_SOCKET_PATH.
Emits at most 131072 short numbered Unicode lines (default 98304, about 3 MB)
into one terminal, once. C11_READ_SCREEN_LINES tunes the line count; set
C11_READ_SCREEN_MIN_BYTES=2097152 when the tagged app's scrollback capacity
supports a required multi-MB retained capture. The default minimum is 64 KiB.
No config is changed. Small scrollback is reported, never claimed as multi-MB.

Never-focused tabs exercise cold-demand paths, but background priming may win
that race; host tests must independently prove an absent native runtime.
This fixture cannot force renderer contention or prove native formatting has a
wall-time bound. Only typed busy responses may be retried, within a deadline.
"""

import base64
import json
import os
import re
import shlex
import time
import uuid

from cmux import cmux, cmuxError


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class FramedClient(cmux):
    """Keep bytes intact until the complete newline-delimited JSON frame arrives."""

    def exchange(self, method, params=None, timeout_s=12.0):
        deadline = time.monotonic() + timeout_s
        request_id = self._next_id
        self._next_id += 1
        request = {"id": request_id, "method": method, "params": params or {}}
        self._socket.settimeout(max(0.001, deadline - time.monotonic()))
        self._socket.sendall((json.dumps(request) + "\n").encode("utf-8"))
        frame = bytearray()
        while b"\n" not in frame:
            remaining = deadline - time.monotonic()
            require(remaining > 0, f"{method}: response deadline expired")
            self._socket.settimeout(remaining)
            chunk = self._socket.recv(65536)
            require(chunk, f"{method}: connection ended inside response ({len(frame)} bytes)")
            frame.extend(chunk)
            require(len(frame) <= 64 * 1024 * 1024, "Response exceeded fixture's 64 MiB cap")
        line, remainder = frame.split(b"\n", 1)
        require(not remainder, f"{method}: more than one reply for a request")
        response = json.loads(line.decode("utf-8", errors="strict"))
        require(isinstance(response, dict), f"{method}: response is not an object")
        require(response.get("id") == request_id, f"{method}: wrong/duplicate response ID")
        require(isinstance(response.get("ok"), bool), f"{method}: missing protocol status")
        return response

    def _call(self, method, params=None, timeout_s=12.0):
        response = self.exchange(method, params, timeout_s)
        if response["ok"]:
            return response.get("result")
        raise cmuxError(f"{method}: {response.get('error')}")


def read_text(client, params, deadline=None):
    deadline = deadline if deadline is not None else time.monotonic() + 12
    while True:
        remaining = deadline - time.monotonic()
        require(remaining > 0, "Read never succeeded within bounded busy retry budget")
        response = client.exchange("tab.read_text", params, timeout_s=min(12, remaining))
        if response["ok"]:
            result = response.get("result")
            require(isinstance(result, dict), "Read success has no result object")
            text, encoded = result.get("text"), result.get("base64")
            require(isinstance(text, str) and isinstance(encoded, str), "Read success lacks text/base64")
            require(base64.b64decode(encoded, validate=True) == text.encode("utf-8"),
                    "Text/base64 bytes differ")
            require(result.get("tab_id", result.get("surface_id")) == params["tab_id"],
                    "Read returned another tab")
            return text
        error = response.get("error") or {}
        require(error.get("code") == "busy", f"Terminal read failed: {error}")
        require(time.monotonic() < deadline, "Terminal remained busy beyond retry budget")
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))


def wait_marker(client, params, marker, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = read_text(client, {**params, "lines": 40}, deadline)
        if marker in text:
            require(text.count(marker) == 1, "Command executed more than once")
            return text
        time.sleep(0.1)
    raise AssertionError(f"Output marker did not arrive: {marker}")


def send_marker(client, params, marker):
    # Split the output marker so the echoed shell command cannot satisfy it.
    middle = len(marker) // 2
    command = "printf '%s%s\\n' " + shlex.quote(marker[:middle]) + " " + shlex.quote(marker[middle:])
    client._call("tab.send_text", {**params, "text": command + "\n"})


def main():
    socket_path = (os.environ.get("C11_SOCKET_PATH") or os.environ.get("C11_SOCKET")
                   or os.environ.get("CMUX_SOCKET_PATH") or os.environ.get("CMUX_SOCKET"))
    require(socket_path, "Set an explicit isolated sandbox socket; no discovery is allowed")
    require(os.path.realpath(socket_path) not in {
        os.path.expanduser("~/Library/Application Support/c11/c11.sock"),
        os.path.expanduser("~/Library/Application Support/c11mux/cmux.sock"),
        "/tmp/cmux.sock",
    }, "Refusing the operator's stable socket")
    rows = int(os.environ.get("C11_READ_SCREEN_LINES", "98304"))
    minimum_bytes = int(os.environ.get("C11_READ_SCREEN_MIN_BYTES", "65536"))
    require(4096 <= rows <= 131072, "Line count must be between 4096 and 131072")
    require(0 < minimum_bytes <= 8 * 1024 * 1024, "Retained-byte minimum must be 1..8 MiB")
    created = []
    with FramedClient(socket_path) as client:
        original = client._call("workspace.current")["workspace_id"]
        try:
            sentinel = client._call("workspace.create")["workspace_id"]
            created.append(sentinel)
            client._call("workspace.select", {"workspace_id": sentinel})
            sentinel_tab = client._call("tab.current", {"workspace_id": sentinel})["tab_id"]
            sentinel_params = {"workspace_id": sentinel, "tab_id": sentinel_tab}
            sentinel_marker = "C295_SENTINEL_" + uuid.uuid4().hex
            send_marker(client, sentinel_params, sentinel_marker)
            wait_marker(client, sentinel_params, sentinel_marker)

            def focus_snapshot():
                return (client._call("workspace.current")["workspace_id"],
                        client._call("tab.current", {"workspace_id": sentinel})["tab_id"],
                        len(client._call("tab.list", {"workspace_id": sentinel})["tabs"]))

            baseline = focus_snapshot()
            target = client._call("workspace.create", {"focus": False})["workspace_id"]
            created.append(target)
            cold_tab = client._call("tab.list", {"workspace_id": target})["tabs"][0]["id"]
            cold_params = {"workspace_id": target, "tab_id": cold_tab}
            started = time.monotonic()
            read_text(client, cold_params)  # Read must succeed before any send/focus.
            print(f"Never-focused first read: {time.monotonic() - started:.3f}s")
            cold_marker = "C295_READ_FIRST_" + uuid.uuid4().hex
            send_marker(client, cold_params, cold_marker)
            wait_marker(client, cold_params, cold_marker)

            queued_tab = client._call("tab.create", {
                "workspace_id": target, "type": "terminal", "focus": False,
            })["tab_id"]
            queued_params = {"workspace_id": target, "tab_id": queued_tab}
            queued_marker = "C295_SEND_FIRST_" + uuid.uuid4().hex
            send_marker(client, queued_params, queued_marker)  # Queue before first read.
            wait_marker(client, queued_params, queued_marker)
            time.sleep(0.2)
            for params, marker in ((cold_params, cold_marker), (queued_params, queued_marker)):
                require(read_text(client, {**params, "scrollback": True}).count(marker) == 1,
                        "Cold input was duplicated or lost")
            require(focus_snapshot() == baseline, "Cold read/send changed sentinel focus/tab count")

            prefix = "R" + uuid.uuid4().hex[:8]
            finished = "C295_FINISHED_" + uuid.uuid4().hex
            script = ("import sys\n"
                      f"for i in range({rows}):\n"
                      f" sys.stdout.write('{prefix} %06d λ界🌲\\n' % i)\n"
                      f"print('{finished}', flush=True)\n")
            encoded = base64.b64encode(script.encode()).decode()
            command = "python3 -c " + shlex.quote(
                f"import base64;exec(base64.b64decode('{encoded}'))")
            client._call("tab.send_text", {**cold_params, "text": command + "\n"})
            wait_marker(client, cold_params, finished, timeout=30)

            # Wait for shell prompt/terminal output to settle before cross-request
            # comparisons. Every individual successful read checks both encodings.
            deadline = time.monotonic() + 15
            while True:
                full = read_text(client, {**cold_params, "scrollback": True}, deadline)
                viewport = read_text(client, cold_params, deadline)
                tail = read_text(client, {**cold_params, "lines": 80}, deadline)
                again = read_text(client, {**cold_params, "scrollback": True}, deadline)
                if full == again:
                    break
                require(time.monotonic() < deadline, "Output did not settle for parity comparison")
                time.sleep(0.1)
            require(tail == "\n".join(full.split("\n")[-80:]), "Last-N differs from full scrollback suffix")
            pattern = re.compile(rf"^{prefix} (\d{{6}}) λ界🌲\s*$", re.MULTILINE)
            indices = [int(value) for value in pattern.findall(full)]
            visible = [int(value) for value in pattern.findall(viewport)]
            require(indices and indices[-1] == rows - 1, "Full capture lost final numbered Unicode line")
            require(indices == list(range(indices[0], rows)), "Retained Unicode rows have gaps/duplicates")
            require(visible and visible == indices[-len(visible):], "Viewport is not the numbered scrollback suffix")
            require(full.count(finished) == 1 and viewport.count(finished) == 1,
                    "Completion marker missing/duplicated in viewport or scrollback")
            retained = len(full.encode("utf-8"))
            require(retained >= minimum_bytes, f"Retained {retained} bytes, required {minimum_bytes}")
            generated = sum(len(f"{prefix} {i:06d} λ界🌲\n".encode()) for i in range(rows))
            print(f"Unicode rows generated={rows} bytes={generated}; retained rows={len(indices)} bytes={retained}")
            if retained < 2 * 1024 * 1024:
                print("LIMITATION: retained capture below 2 MiB; multi-MB capture not proven")

            stale = client._call("tab.create", {
                "workspace_id": sentinel, "type": "terminal", "focus": False,
            })["tab_id"]
            client._call("tab.close", {"workspace_id": sentinel, "tab_id": stale})
            require(focus_snapshot() == baseline, "Stale fixture preparation changed sentinel")
            for ref in (stale, "tab:2147483647", "tab:not-a-number"):
                for method in ("tab.read_text", "tab.split"):
                    response = client.exchange(method, {
                        "workspace_id": sentinel, "tab_id": ref, "direction": "right",
                    })
                    require(response["ok"] is False, f"{method} silently accepted stale target {ref}")
                    require((response.get("error") or {}).get("code") == "not_found",
                            f"{method}: stale target failed for wrong reason: {response}")
                    require(focus_snapshot() == baseline, f"{method} changed sentinel focus/tab count")
            require(sentinel_marker in read_text(client, sentinel_params), "Sentinel content was lost")
        finally:
            # Only workspaces recorded immediately after our own successful create
            # are closed. Attempt each cleanup even if a previous close fails.
            cleanup_errors = []
            try:
                client._call("workspace.select", {"workspace_id": original})
            except Exception as error:
                cleanup_errors.append(str(error))
            for workspace in reversed(created):
                try:
                    client.close_workspace(workspace)
                except Exception as error:
                    cleanup_errors.append(str(error))
            require(not cleanup_errors, f"Fixture cleanup failed: {cleanup_errors}")
    print("PASS: complete frames, Unicode capture parity, cold input once, stale target isolation")


if __name__ == "__main__":
    main()
