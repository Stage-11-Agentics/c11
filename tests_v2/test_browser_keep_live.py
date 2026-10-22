#!/usr/bin/env python3
"""C11-324: `browser.keep_live` keeps a hidden workspace's page running.

A page in a background workspace counts timer ticks, reports
document.visibilityState, and plays a canvas-captured video. With keep-live off
the page is hidden to WebKit; with it on it stays visible and live; turning it
off restores the hidden state. The operator's selected workspace never changes.

Run only through scripts/sandbox-tests-v2.sh (it creates and selects workspaces).
"""

from __future__ import annotations

import glob
import http.server
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError, find_cli_binary  # type: ignore[import]


SOCKET_PATH = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET", "/tmp/c11-debug.sock")

PAGE = b"""<!doctype html><meta charset=utf-8><title>keep-live-probe</title>
<body><h1>keep-live-probe</h1><canvas id=c width=160 height=120></canvas>
<video id=v muted playsinline width=160 height=120></video>
<script>
window.ticks = 0;
setInterval(() => { window.ticks++; }, 100);
window.vis = [];
document.addEventListener('visibilitychange', () => window.vis.push(document.visibilityState));
const c = document.getElementById('c'), x = c.getContext('2d');
let n = 0;
setInterval(() => { x.fillStyle = 'hsl(' + ((n++ * 20) % 360) + ',80%,50%)'; x.fillRect(0, 0, 160, 120); }, 50);
const v = document.getElementById('v');
v.srcObject = c.captureStream(15);
v.play().catch(e => { window.videoError = String(e); });
</script></body>"""


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *args: object) -> None:
        pass


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _probe(client: cmux, panel: str) -> dict:
    script = (
        "JSON.stringify({hidden: document.hidden, vis: document.visibilityState, ticks: window.ticks,"
        " video: document.getElementById('v').currentTime, paused: document.getElementById('v').paused,"
        " videoError: window.videoError || null, events: window.vis})"
    )
    res = client._call("browser.eval", {"panel_id": panel, "script": script}) or {}
    return json.loads(res.get("value"))


def _measure(client: cmux, panel: str, window_s: float = 3.0) -> dict:
    """Two probes `window_s` apart; reports state and the deltas."""
    first = _probe(client, panel)
    time.sleep(window_s)
    second = _probe(client, panel)
    return {
        "hidden": second["hidden"],
        "vis": second["vis"],
        "tick_delta": second["ticks"] - first["ticks"],
        "video_delta": second["video"] - first["video"],
        "paused": second["paused"],
        "videoError": second["videoError"],
        "events": second["events"],
    }


def _selected_events() -> int | None:
    base = os.path.expanduser("~/Library/Application Support/c11/events")
    files = sorted(glob.glob(os.path.join(base, "events-*.ndjson")), key=os.path.getmtime)
    if not files:
        return None
    with open(files[-1], "r", encoding="utf-8", errors="replace") as handle:
        return sum(1 for line in handle if '"type":"workspace.selected"' in line)


def _wait_page(client: cmux, panel: str) -> None:
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            if _probe(client, panel)["ticks"] > 0:
                return
        except Exception:
            pass
        time.sleep(0.25)
    raise cmuxError("probe page never started")


def _current(client: cmux) -> str:
    return str((client._call("workspace.current") or {}).get("workspace_id") or "")


def _scenario(client: cmux, cli: str, url: str, operator_ws: str, *, name: str, cold: bool, replace: bool,
              close_workspace_directly: bool) -> None:
    """One background workspace: keep-live off, on, (replaced), off; selection never moves.

    cold: the workspace's creation-time background mount has expired before the browser is created,
    so the web view has no portal host until keep-live creates one.
    """
    print(f"-- {name}")
    ws = str((client._call("workspace.create") or {}).get("workspace_id") or "")
    _must(bool(ws), "workspace.create returned no workspace_id")
    try:
        if cold:
            time.sleep(10)
        panel = str((client._call("browser.panel.new", {"workspace_id": ws, "url": url}) or {}).get("panel_id") or "")
        other = str((client._call("browser.panel.new", {"workspace_id": ws, "url": url}) or {}).get("panel_id") or "")
        _must(bool(panel) and bool(other), "browser.panel.new returned no panel_id")
        current = _current(client)
        _must(current != ws, f"{name}: the browser workspace is the selected one")
        _wait_page(client, panel)
        _wait_page(client, other)
        selected_before = _selected_events()

        status = client._call("browser.keep_live", {"panel_id": panel}) or {}
        _must(status.get("keep_live") is False, f"keep-live must default off: {status}")
        off = _measure(client, panel)
        print("off  :", off)
        _must(off["hidden"] is True and off["vis"] == "hidden", f"{name}: keep-live off must be hidden: {off}")

        on_res = client._call("browser.keep_live", {"panel_id": panel, "enabled": True}) or {}
        _must(on_res.get("keep_live") is True, f"enable failed: {on_res}")
        time.sleep(1.0)
        on = _measure(client, panel)
        print("on   :", on)
        _must(on["hidden"] is False and on["vis"] == "visible", f"{name}: keep-live on: document.hidden must be false: {on}")
        _must(on["tick_delta"] >= 20, f"{name}: keep-live on: timers must run (~30 ticks in 3 s): {on}")
        _must(on["videoError"] is None and on["paused"] is False and on["video_delta"] > 1.0,
              f"{name}: keep-live on: video must play: {on}")

        # A second browser in the same workspace that did not opt in stays hidden.
        bystander = _probe(client, other)
        _must(bystander["hidden"] is True, f"{name}: a non-opted browser must stay hidden: {bystander}")

        snap = client._call("browser.snapshot", {"panel_id": panel}) or {}
        _must("keep-live-probe" in str(snap.get("snapshot") or ""), f"{name}: snapshot is blank while kept live: {snap}")

        if replace:
            time.sleep(6)
            result = client._call("debug.browser.simulate_web_content_termination", {"panel_id": panel}) or {}
            _must(result.get("scheduled") is True, f"replacement not scheduled: {result}")
            time.sleep(3)
            recovered = _measure(client, panel)
            print("after hidden replacement:", recovered)
            _must(recovered["hidden"] is False and recovered["tick_delta"] >= 20,
                  f"{name}: keep-live lost its host after replacement: {recovered}")

        _must(_current(client) == current, f"{name}: the operator's selected workspace changed")

        if close_workspace_directly:
            entries_with = (client._call("debug.portal.stats") or {}).get("browser_portal_entries")
            client._call("workspace.close", {"workspace_id": ws})
            time.sleep(1.5)
            entries_after = (client._call("debug.portal.stats") or {}).get("browser_portal_entries")
            print("browser portal entries:", entries_with, "->", entries_after)
            _must(entries_with is not None and entries_after is not None and entries_after <= entries_with - 1,
                  f"{name}: closing the workspace must release the kept-live host: {entries_with} -> {entries_after}")
            return

        cli_off = subprocess.run([cli, "--socket", SOCKET_PATH, "browser", panel, "keep-live", "off"],
                                 capture_output=True, text=True, check=False)
        _must(cli_off.returncode == 0 and cli_off.stdout.strip() == "off", f"CLI off: {cli_off}")
        time.sleep(1.0)
        back = _measure(client, panel)
        print("off2 :", back)
        _must(back["hidden"] is True and back["vis"] == "hidden", f"{name}: off again must be hidden: {back}")

        _must(_current(client) == current, f"{name}: the operator's selected workspace changed")
        selected_after = _selected_events()
        print("workspace.selected events:", selected_before, "->", selected_after)
        if selected_before is not None and selected_after is not None:
            _must(selected_after == selected_before, f"workspace.selected events appeared: {selected_before} -> {selected_after}")

        # Closing the panel while kept live tears the host down.
        client._call("browser.keep_live", {"panel_id": panel, "enabled": True})
        time.sleep(0.5)
        client._call("browser.panel.close", {"workspace_id": ws, "target_panel_id": panel})
        time.sleep(0.5)
        left = [row.get("id") for row in (client._call("browser.panel.list", {"workspace_id": ws}) or {}).get("panels") or []]
        _must(panel not in [str(x) for x in left], f"panel did not close: {left}")
    finally:
        try:
            client._call("workspace.close", {"workspace_id": ws})
        except Exception:
            pass


def main() -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    cli = find_cli_binary()
    try:
        with cmux(SOCKET_PATH) as client:
            operator_ws = _current(client)
            _must(bool(operator_ws), "no current workspace")
            _scenario(client, cli, url, operator_ws, name="immediate", cold=False, replace=False, close_workspace_directly=False)
            _scenario(client, cli, url, operator_ws, name="cold-workspace", cold=True, replace=False, close_workspace_directly=False)
            _scenario(client, cli, url, operator_ws, name="hidden-replacement", cold=True, replace=True, close_workspace_directly=False)
            _scenario(client, cli, url, operator_ws, name="workspace-close", cold=True, replace=False, close_workspace_directly=True)
            _must(_current(client) == operator_ws, "the operator's selected workspace changed")
        print("PASS test_browser_keep_live")
        return 0
    finally:
        server.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
