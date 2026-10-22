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


def main() -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    cli = find_cli_binary()
    created: list[str] = []
    try:
        with cmux(SOCKET_PATH) as client:
            operator_ws = str((client._call("workspace.current") or {}).get("workspace_id") or "")
            _must(bool(operator_ws), "no current workspace")

            ws = str((client._call("workspace.create") or {}).get("workspace_id") or "")
            created.append(ws)
            panel = str((client._call("browser.panel.new", {"workspace_id": ws, "url": url}) or {}).get("panel_id") or "")
            _must(bool(panel), "browser.panel.new returned no panel_id")

            # The new workspace must be in the background for the rest of the run.
            current = str((client._call("workspace.current") or {}).get("workspace_id") or "")
            if current != operator_ws:
                _must(current != ws, f"workspace.create selected the new workspace: {current}")
            background_ws = ws
            _must(current != background_ws, "setup: the browser workspace is the selected one")

            # Wait for the page to load.
            deadline = time.time() + 30
            while time.time() < deadline:
                try:
                    if _probe(client, panel)["ticks"] > 0:
                        break
                except Exception:
                    pass
                time.sleep(0.25)
            else:
                raise cmuxError("probe page never started")

            selected_before = _selected_events()

            # Default: off.
            status = client._call("browser.keep_live", {"panel_id": panel}) or {}
            _must(status.get("keep_live") is False, f"keep-live must default off: {status}")

            off = _measure(client, panel)
            print("off  :", off)
            _must(off["hidden"] is True and off["vis"] == "hidden",
                  f"keep-live off: a hidden workspace's page must report hidden: {off}")

            # On.
            on_res = client._call("browser.keep_live", {"panel_id": panel, "enabled": True}) or {}
            _must(on_res.get("keep_live") is True, f"enable failed: {on_res}")
            time.sleep(1.0)
            on = _measure(client, panel)
            print("on   :", on)
            _must(on["hidden"] is False and on["vis"] == "visible",
                  f"keep-live on: document.hidden must be false: {on}")
            _must(on["tick_delta"] >= 20, f"keep-live on: timers must run (~30 ticks in 3 s): {on}")
            _must(on["videoError"] is None and on["paused"] is False and on["video_delta"] > 1.0,
                  f"keep-live on: video must play: {on}")

            snap = client._call("browser.snapshot", {"panel_id": panel}) or {}
            _must("keep-live-probe" in str(snap.get("snapshot") or ""), f"snapshot is blank while kept live: {snap}")
            shot = client._call("browser.screenshot", {"panel_id": panel}) or {}
            _must(bool(shot.get("png_base64") or shot.get("path") or shot.get("url")), f"screenshot returned nothing: {list(shot)}")

            cli_status = subprocess.run([cli, "--socket", SOCKET_PATH, "browser", panel, "keep-live", "status"],
                                        capture_output=True, text=True, check=False)
            _must(cli_status.returncode == 0 and cli_status.stdout.strip() == "on", f"CLI status: {cli_status}")

            _must(str((client._call("workspace.current") or {}).get("workspace_id") or "") == current,
                  "the operator's selected workspace changed")

            # Off again (through the CLI).
            cli_off = subprocess.run([cli, "--socket", SOCKET_PATH, "browser", panel, "keep-live", "off"],
                                     capture_output=True, text=True, check=False)
            _must(cli_off.returncode == 0 and cli_off.stdout.strip() == "off", f"CLI off: {cli_off}")
            time.sleep(1.0)
            back = _measure(client, panel)
            print("off2 :", back)
            _must(back["hidden"] is True and back["vis"] == "hidden",
                  f"keep-live off again: the page must be hidden again: {back}")

            # Selection never moved, and no workspace.selected event was emitted.
            _must(str((client._call("workspace.current") or {}).get("workspace_id") or "") == current,
                  "the operator's selected workspace changed")
            selected_after = _selected_events()
            print("workspace.selected events:", selected_before, "->", selected_after)
            if selected_before is not None and selected_after is not None:
                _must(selected_after == selected_before,
                      f"workspace.selected events appeared: {selected_before} -> {selected_after}")

            # Closing the panel while kept live tears the parked slot down.
            client._call("browser.keep_live", {"panel_id": panel, "enabled": True})
            time.sleep(0.5)
            client._call("browser.panel.close", {"workspace_id": ws, "target_panel_id": panel})
            time.sleep(0.5)
            gone = client._call("browser.panel.list", {"workspace_id": ws}) or {}
            _must(not (gone.get("panels") or []), f"panel did not close: {gone}")

            client._call("workspace.close", {"workspace_id": ws})
            created.clear()
        print("PASS test_browser_keep_live")
        return 0
    finally:
        server.shutdown()
        if created:
            try:
                with cmux(SOCKET_PATH) as cleanup:
                    for ws in created:
                        cleanup._call("workspace.close", {"workspace_id": ws})
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
