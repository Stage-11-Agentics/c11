#!/usr/bin/env python3
"""C11H-248: create 20 terminals while the guest's display mode changes.

Run only through scripts/sandbox-tests-v2.sh <run-id> with a tagged DEBUG app.
The driver refuses a non-VirtualMac or a non-sandbox socket. It never discovers
or connects to the operator's socket. No PyObjC package is required.

The app must emit this DEBUG trace around the actual ghostty_surface_new call:
  surface.create.native panel=<UUID> elapsedMs=<number> created=true
and around all of createSurface, including sizing:
  surface.create.total panel=<UUID> elapsedMs=<number> created=true
--trace PATH overrides /tmp/c11-sandbox-<run-id>.log, derived from the explicit
sandbox socket. Display mode uses only appended bytes and our own panel UUIDs.
A missing trace, unavailable backing-scale change, or missing render evidence
fails; none is a successful skip. Compare the JSON reports from an instrumented
baseline and candidate. Both timings must be present and at most 250 ms.

--native-lock-only is a separate diagnostic scenario. It never changes the
display and requires a fixture GhosttyKit launched by the copied sandbox harness
with C11_TEST_CREATION_FONT_LOCK=1. Before EACH launch that harness must truncate
both DEBUG trace and stdout. The fixture holds the actual shared font-grid writer
for one second at native creation ordinal 2, which can occur during startup.
Native mode reads those launch-scoped logs from byte zero, requires exactly one
C11_248_FONT_LOCK_HELD followed by C11_248_FONT_LOCK_RELEASED, and identifies
the fixture by the second native-creation record. That UUID must belong to an
initial live terminal with a ready native runtime. Only that startup panel and
two driver-created terminals count toward timing assertions; unrelated cold
startup timings do not. An instrumented baseline should fail the 250 ms limit;
the candidate must pass. This scenario is not display-churn evidence.

The first queued command prints a marker assembled from separate shell words,
so terminal command echo cannot satisfy the readback assertion. For each live
panel we require a native surface, a visible portal in a real window, the marker
in panel.read_text, and the exact marker recognized by macOS Vision in a fresh
guest-display screenshot while that panel is focused. Buffer/layer checks gate
the capture; they cannot satisfy the pixel assertion. No expected-marker word
list or OCR substitutions are used. Screenshots remain in the sandbox's shared
out directory (override with --screenshots); the JSON names each captured file.
The cancelled panel is created before the burst. Final trace/liveness checks run
only after its reported ten-second hold expires and a main-thread query returns.
The full scenario, including best-effort cleanup, has a 30-second watchdog.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


COUNT = 20
MAX_CREATION_MS = 250.0
RUN_SECONDS = 26.0  # Leave the watchdog's remaining four seconds for cleanup.
TRACE_RE = re.compile(
    r"surface\.create\.(native|total) panel=([0-9A-Fa-f-]{36}) "
    r"elapsedMs=([0-9]+(?:\.[0-9]+)?) created=(true|false|1|0)"
)


class BlockedEnvironment(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def guest_socket() -> tuple[str, str]:
    path = os.environ.get("C11_SOCKET") or os.environ.get("C11_SOCKET_PATH", "")
    match = re.fullmatch(r"/tmp/c11?-sandbox-([A-Za-z0-9_-]+)\.sock", path)
    if platform.system() != "Darwin" or not match:
        raise BlockedEnvironment("requires an explicit /tmp/c11[h]-sandbox-<run>.sock on macOS")
    model = subprocess.check_output(
        ["/usr/sbin/sysctl", "-n", "hw.model"], text=True, timeout=2
    ).strip()
    if not model.startswith("VirtualMac") or os.environ.get("C11_TEST_ALLOW_LIVE_APP") != "1":
        raise BlockedEnvironment("requires the build host's Tart guest and sandbox-tests-v2.sh")
    if not Path(path).is_socket():
        raise BlockedEnvironment(f"sandbox socket is absent: {path}")
    return path, match.group(1)


class DisplayModes:
    """Own the original mode and mode array until restoration is complete."""

    def __init__(self) -> None:
        self.cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        signatures = {
            "CGMainDisplayID": (ctypes.c_uint32, []),
            "CGDisplayCopyDisplayMode": (ctypes.c_void_p, [ctypes.c_uint32]),
            "CGDisplayCopyAllDisplayModes": (ctypes.c_void_p, [ctypes.c_uint32, ctypes.c_void_p]),
            "CGDisplayModeGetWidth": (ctypes.c_size_t, [ctypes.c_void_p]),
            "CGDisplayModeGetHeight": (ctypes.c_size_t, [ctypes.c_void_p]),
            "CGDisplayModeGetPixelWidth": (ctypes.c_size_t, [ctypes.c_void_p]),
            "CGDisplayModeGetPixelHeight": (ctypes.c_size_t, [ctypes.c_void_p]),
            "CGDisplaySetDisplayMode": (ctypes.c_int32, [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(self.cg, name)
            function.restype, function.argtypes = result, arguments
        self.cf.CFArrayGetCount.restype = ctypes.c_long
        self.cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        self.cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        self.cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]
        self.cf.CFRelease.restype = None
        self.cf.CFDictionaryCreate.restype = ctypes.c_void_p
        self.cf.CFDictionaryCreate.argtypes = [ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
        self.display = self.cg.CGMainDisplayID()
        self.original = self.cg.CGDisplayCopyDisplayMode(self.display)
        self.modes = None
        self.changed = False
        self.history: list[dict] = []
        # Include the HiDPI/low-resolution pairs CoreGraphics normally hides.
        # Keys/values are process-lifetime CF constants, so borrowed callbacks
        # are sufficient for this short-lived options dictionary.
        try:
            key = ctypes.c_void_p.in_dll(self.cg, "kCGDisplayShowDuplicateLowResolutionModes").value
            value = ctypes.c_void_p.in_dll(self.cf, "kCFBooleanTrue").value
            options = self.cf.CFDictionaryCreate(None, (ctypes.c_void_p * 1)(key),
                (ctypes.c_void_p * 1)(value), 1, None, None)
            if not options:
                raise BlockedEnvironment("cannot request all guest backing-scale modes")
            try:
                self.modes = self.cg.CGDisplayCopyAllDisplayModes(self.display, options)
            finally:
                self.cf.CFRelease(options)
        except (OSError, ValueError) as error:
            self.close()
            raise BlockedEnvironment(f"guest display-mode options unavailable: {error}") from error
        except Exception:
            self.close()
            raise
        if not self.original or not self.modes:
            self.close()
            raise BlockedEnvironment("CoreGraphics did not provide guest display modes")
        original = self.dimensions(self.original)
        candidates = []
        for index in range(self.cf.CFArrayGetCount(self.modes)):
            mode = self.cf.CFArrayGetValueAtIndex(self.modes, index)
            dimensions = self.dimensions(mode)
            if (dimensions[0] >= 800 and dimensions[1] >= 600
                    and self.different_scale(dimensions, original)):
                candidates.append((mode, dimensions))
        if not candidates:
            self.close()
            raise BlockedEnvironment(f"guest exposes no alternate backing scale: current={original}")
        candidates.sort(key=lambda item:
            abs(item[1][0] - original[0]) + abs(item[1][1] - original[1]))
        self.alternate = candidates[0][0]

    @staticmethod
    def different_scale(a: tuple, b: tuple) -> bool:
        return a[2] * b[0] != b[2] * a[0] or a[3] * b[1] != b[3] * a[1]

    def dimensions(self, mode: int) -> tuple[int, int, int, int]:
        return tuple(int(getattr(self.cg, "CGDisplayModeGet" + suffix)(mode))
                     for suffix in ("Width", "Height", "PixelWidth", "PixelHeight"))

    def set(self, alternate: bool) -> None:
        mode = self.alternate if alternate else self.original
        expected = self.dimensions(mode)
        before_mode = self.cg.CGDisplayCopyDisplayMode(self.display)
        if not before_mode:
            raise BlockedEnvironment("cannot read the guest's current display mode")
        before = self.dimensions(before_mode)
        self.cf.CFRelease(before_mode)
        self.changed = True  # Even a failed request must attempt restoration.
        started = time.monotonic()
        result = self.cg.CGDisplaySetDisplayMode(self.display, mode, None)
        if result != 0:
            raise BlockedEnvironment(f"CGDisplaySetDisplayMode failed: {result}")
        actual_mode = self.cg.CGDisplayCopyDisplayMode(self.display)
        if not actual_mode:
            raise BlockedEnvironment("cannot verify the changed guest display mode")
        actual = self.dimensions(actual_mode)
        self.cf.CFRelease(actual_mode)
        if actual != expected or not self.different_scale(before, actual):
            raise BlockedEnvironment(f"display did not change: before={before}, expected={expected}, actual={actual}")
        self.history.append({"before": before, "after": actual,
                             "scale_changed": True,
                             "before_scale": [before[2] / before[0], before[3] / before[1]],
                             "after_scale": [actual[2] / actual[0], actual[3] / actual[1]],
                             "elapsed_ms": (time.monotonic() - started) * 1000})

    def close(self) -> None:
        error = None
        if self.changed and self.original:
            result = self.cg.CGDisplaySetDisplayMode(self.display, self.original, None)
            if result:
                error = RuntimeError(f"failed to restore guest display mode: {result}")
        if self.modes:
            self.cf.CFRelease(self.modes)
            self.modes = None
        if self.original:
            self.cf.CFRelease(self.original)
            self.original = None
        if error:
            raise error


class ScreenOCR:
    """Synchronous Vision text recognition through the Objective-C ABI.

    The driver-wide watchdog also bounds native calls that cannot be interrupted
    by Python's alarm. Load this only after guest_socket() validates isolation.
    """

    def __init__(self) -> None:
        try:
            self.foundation = ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
            self.vision = ctypes.CDLL("/System/Library/Frameworks/Vision.framework/Vision")
            # Capture runs in screencapture, whose permission may differ from
            # this Python process. Its exit status and actual pixels decide
            # availability; a Python-only preflight would reject valid captures.
            self.objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
            self.objc.objc_getClass.argtypes = [ctypes.c_char_p]
            self.objc.objc_getClass.restype = ctypes.c_void_p
            self.objc.sel_registerName.argtypes = [ctypes.c_char_p]
            self.objc.sel_registerName.restype = ctypes.c_void_p
            self.send_address = ctypes.cast(self.objc.objc_msgSend, ctypes.c_void_p).value
            self.functions: dict = {}
            self.classes = {name: self.objc.objc_getClass(name.encode()) for name in (
                "NSAutoreleasePool", "NSString", "NSURL", "NSArray", "NSDictionary",
                "VNRecognizeTextRequest", "VNImageRequestHandler")}
            if not all(self.classes.values()):
                raise BlockedEnvironment("guest Vision text-recognition classes unavailable")
        except OSError as error:
            raise BlockedEnvironment(f"guest Vision framework unavailable: {error}") from error

    def send(self, receiver: int, selector: str, result=ctypes.c_void_p,
             arguments: tuple = (), values: tuple = ()):
        signature = (result, arguments)
        if signature not in self.functions:
            self.functions[signature] = ctypes.CFUNCTYPE(
                result, ctypes.c_void_p, ctypes.c_void_p, *arguments)(self.send_address)
        return self.functions[signature](receiver,
            self.objc.sel_registerName(selector.encode()), *values)

    def recognize(self, path: Path) -> list[str]:
        pointer = ctypes.c_void_p
        pool = self.send(self.send(self.classes["NSAutoreleasePool"], "alloc"), "init")
        request = handler = None
        try:
            string = self.send(self.classes["NSString"], "stringWithUTF8String:",
                arguments=(ctypes.c_char_p,), values=(os.fsencode(path),))
            url = self.send(self.classes["NSURL"], "fileURLWithPath:",
                arguments=(pointer,), values=(string,))
            options = self.send(self.classes["NSDictionary"], "dictionary")
            request = self.send(self.send(self.classes["VNRecognizeTextRequest"], "alloc"), "init")
            require(bool(request), "Vision could not initialize text recognition")
            self.send(request, "setUsesLanguageCorrection:", None, (ctypes.c_bool,), (False,))
            # Accurate recognition is the default. Do not feed the expected
            # marker into customWords: only actual pixels may provide the text.
            requests = self.send(self.classes["NSArray"], "arrayWithObject:",
                arguments=(pointer,), values=(request,))
            handler = self.send(self.send(self.classes["VNImageRequestHandler"], "alloc"),
                "initWithURL:options:", arguments=(pointer, pointer), values=(url, options))
            require(bool(handler), "Vision could not open the screenshot")
            error = pointer()
            success = self.send(handler, "performRequests:error:", ctypes.c_bool,
                (pointer, ctypes.POINTER(pointer)), (requests, ctypes.byref(error)))
            if not success:
                raise BlockedEnvironment("Vision failed to recognize the guest screenshot")
            results = self.send(request, "results")
            lines = []
            for index in range(self.send(results, "count", ctypes.c_ulong)):
                observation = self.send(results, "objectAtIndex:",
                    arguments=(ctypes.c_ulong,), values=(index,))
                candidates = self.send(observation, "topCandidates:",
                    arguments=(ctypes.c_ulong,), values=(1,))
                if self.send(candidates, "count", ctypes.c_ulong):
                    candidate = self.send(candidates, "objectAtIndex:",
                        arguments=(ctypes.c_ulong,), values=(0,))
                    text = self.send(self.send(candidate, "string"), "UTF8String", ctypes.c_char_p)
                    lines.append(text.decode("utf-8", errors="replace") if text else "")
            return lines
        finally:
            self.send(handler, "release", None)
            self.send(request, "release", None)
            self.send(pool, "drain", None)


def panel_id(payload: dict) -> str:
    value = str(payload.get("panel_id") or payload.get("surface_id") or "")
    require(bool(value), f"creation returned no panel UUID: {payload}")
    return str(uuid.UUID(value)).lower()


def text_from(payload: dict) -> str:
    if "text" in payload:
        return str(payload["text"])
    return base64.b64decode(payload.get("base64") or "").decode("utf-8", errors="replace")


def appended_text(path: Path, offset: int) -> str:
    require(path.stat().st_size >= offset, f"evidence log was truncated during this run: {path}")
    with path.open("rb") as stream:
        stream.seek(offset)
        return stream.read().decode("utf-8", errors="replace")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, help="the guest app's DEBUG log")
    parser.add_argument("--stdout", type=Path, help="the fixture guest app's stdout/stderr log")
    parser.add_argument("--screenshots", type=Path, help="guest screenshot directory; default is a unique folder in the sandbox shared out directory")
    parser.add_argument("--native-lock-only", action="store_true", help="require the native font-lock fixture, without changing display modes")
    arguments = parser.parse_args(argv)
    count = 2 if arguments.native_lock_only else COUNT
    scenario = "surface_creation_font_lock" if arguments.native_lock_only else "surface_creation_display_churn"
    report: dict = {"scenario": scenario, "requested": count}
    finished = threading.Event()
    started = time.monotonic()
    deadline = started + RUN_SECONDS

    def hard_stop() -> None:
        if not finished.wait(30):
            print("FAIL: 30-second watchdog expired; sandbox-down is required", flush=True)
            os._exit(1)

    threading.Thread(target=hard_stop, daemon=True).start()

    def expired(_signal: int, _frame: object) -> None:
        raise TimeoutError("26-second scenario deadline expired")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, RUN_SECONDS)
    c = None
    display = None
    created: dict[str, str] = {}
    closed: set[str] = set()
    cancelled = ""
    fixture_id = ""
    result = 1
    try:
        socket_path, run_id = guest_socket()
        trace = arguments.trace or Path(f"/tmp/c11-sandbox-{run_id}.log")
        if not trace.is_file():
            raise BlockedEnvironment(f"DEBUG native-creation trace is absent: {trace}")
        trace_offset = 0 if arguments.native_lock_only else trace.stat().st_size
        stdout = arguments.stdout or Path(f"/tmp/c11-sandbox-{run_id}.stdout")
        stdout_offset = 0
        if arguments.native_lock_only:
            if not stdout.is_file():
                raise BlockedEnvironment(f"native fixture stdout is absent: {stdout}")
        else:
            display = DisplayModes()
        report["display_changes"] = display.history if display is not None else []
        ocr = ScreenOCR()
        screenshot_dir = arguments.screenshots or (
            Path("/Volumes/My Shared Files/out") / f"{scenario}-{uuid.uuid4().hex[:12]}")
        screenshot_dir.mkdir(parents=True, exist_ok=False)
        report["screenshot_directory"] = str(screenshot_dir)
        captures: list[dict] = []
        report["screen_captures"] = captures
        c = cmux(socket_path)
        c.connect()

        def call(method: str, params: dict | None = None) -> dict:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("scenario deadline expired")
            return c._call(method, params or {}, timeout_s=min(3.0, remaining)) or {}

        workspace = str(call("workspace.current").get("workspace_id") or "")
        require(bool(workspace), "sandbox has no selected workspace")
        panels = call("panel.list", {"workspace_id": workspace}).get("panels") or []
        seed = next((row for row in panels if row.get("type") == "terminal"), None)
        require(seed is not None, "selected sandbox workspace has no seed terminal")
        seed_id = str(seed["id"])
        seed_area = str(seed.get("area_id") or seed.get("pane_id") or "")
        require(bool(seed_area), f"seed terminal has no area: {seed}")
        call("debug.app.activate")
        if arguments.native_lock_only:
            startup_deadline = min(deadline - 0.1, time.monotonic() + 2.5)
            while True:
                native_records = [match for match in TRACE_RE.finditer(appended_text(trace, 0))
                                  if match.group(1) == "native"]
                initial_rows = call("debug.terminals").get("terminals") or []
                if len(native_records) >= 2:
                    fixture_id = native_records[1].group(2).lower()
                    fixture_row = next((row for row in initial_rows
                                        if str(row.get("panel_id") or row.get("surface_id")).lower() == fixture_id), {})
                    require(bool(fixture_row), "second native-creation UUID is absent from initial live terminals; trace may belong to an older launch")
                    if fixture_row.get("runtime_panel_ready") is True:
                        fixture_workspace = str(fixture_row.get("workspace_id") or "")
                        require(bool(fixture_workspace), "startup fixture has no owning workspace")
                        startup_text = text_from(call("panel.read_text", {
                            "workspace_id": fixture_workspace, "panel_id": fixture_id, "lines": 40,
                        }))
                        layer = call("debug.terminal.layer_probe", {"panel_id": fixture_id})
                        if (not startup_text.strip() or layer.get("in_window") is not True
                                or not any(item.get("non_zero_fraction", 0) > 0
                                           for item in layer.get("surfaces", []))):
                            if time.monotonic() >= startup_deadline:
                                raise BlockedEnvironment("startup fixture did not render its first prompt")
                            time.sleep(0.02)
                            continue
                        report["startup_fixture"] = {
                            "panel_id": fixture_id, "native_ordinal": 2,
                            "workspace_id": fixture_workspace, "runtime_panel_ready": True,
                            "text_characters": len(startup_text),
                            "visible_in_ui": fixture_row.get("hosted_view_visible_in_ui"),
                            "in_headless_bootstrap": fixture_row.get("hosted_view_in_headless_bootstrap_window"),
                            "layer_probe": layer,
                        }
                        break
                if time.monotonic() >= startup_deadline:
                    raise BlockedEnvironment("startup native creation ordinal 2 was not logged and ready; verify the fresh fixture launch")
                time.sleep(0.02)
        # Short uppercase alphabetic text is readable by OCR even in a split.
        # Avoid digit/letter lookalikes; the random suffix is unique per run.
        alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ"
        serial = "".join(alphabet[value % len(alphabet)] for value in uuid.uuid4().bytes[:6])
        split = ""
        rpc_ms = []
        observations = []
        report["panels_observed_before_close"] = observations

        # Start the ten-second cancellation window before the creation burst.
        # Use response receipt + maximum_seconds as a conservative expiry: the
        # app scheduled its callback before it sent this response.
        held = call("debug.terminal.runtime_start_hold", {
            "workspace_id": workspace, "panel_id": seed_id, "create": True, "hold": True,
        })
        cancelled = panel_id(held)
        require(held.get("held") is True and held.get("maximum_seconds") == 10,
                f"unexpected runtime hold contract: {held}")
        cancellation_expires = time.monotonic() + float(held["maximum_seconds"])
        call("panel.close", {"workspace_id": workspace, "panel_id": cancelled})
        report["cancellation"] = {"panel_id": cancelled,
            "expires_after_start_seconds": cancellation_expires - started}

        def observe(live_id: str) -> None:
            call("panel.focus", {"workspace_id": workspace, "panel_id": live_id})
            attempt = 0
            while True:
                rows = call("debug.terminals").get("terminals") or []
                row = next((row for row in rows if str(row.get("panel_id") or row.get("surface_id")).lower() == live_id), {})
                ready = (row.get("runtime_panel_ready") is True
                         and row.get("hosted_view_in_window") is True
                         and row.get("hosted_view_in_headless_bootstrap_window") is False
                         and row.get("hosted_view_visible_in_ui") is True)
                if ready:
                    screen = text_from(call("panel.read_text", {
                        "workspace_id": workspace, "panel_id": live_id, "lines": 40,
                    }))
                    stats = call("debug.terminal.render_stats", {"panel_id": live_id}).get("stats") or {}
                    if (created[live_id] in screen
                            and stats.get("layerContentsKey") not in (None, "", "nil")
                            and int(stats.get("presentCount", 0)) > 0
                            and stats.get("inWindow") is True
                            and stats.get("windowOcclusionVisible") is True):
                        # Readback and layer activity only decide when to take
                        # a picture. Require the unique output in actual pixels.
                        attempt += 1
                        screenshot = screenshot_dir / f"{live_id}-{attempt:02d}.png"
                        capture_started = time.monotonic()
                        remaining = deadline - capture_started
                        if remaining <= 0:
                            raise TimeoutError("scenario deadline expired before screenshot")
                        capture = subprocess.run(
                            ["/usr/sbin/screencapture", "-x", "-D", "1", str(screenshot)],
                            capture_output=True, timeout=min(2.0, remaining), check=False)
                        if capture.returncode or not screenshot.is_file() or screenshot.stat().st_size == 0:
                            raise BlockedEnvironment("guest display capture unavailable: " +
                                capture.stderr.decode("utf-8", errors="replace").strip())
                        lines = ocr.recognize(screenshot)
                        matched = any(line.strip() == created[live_id] for line in lines)
                        captures.append({"panel_id": live_id, "screenshot": str(screenshot),
                            "ocr_text": lines, "exact_marker_found": matched,
                            "capture_and_ocr_ms": (time.monotonic() - capture_started) * 1000})
                        if matched:
                            observations.append({"panel_id": live_id, "marker": created[live_id],
                                                 "screenshot": str(screenshot), "ocr_exact_match": True,
                                                 "layer_contents_key": stats["layerContentsKey"],
                                                 "present_count": stats["presentCount"]})
                            return
                if time.monotonic() >= deadline:
                    raise AssertionError(f"panel did not attach/render its first output: {live_id}; runtime={row}")
                time.sleep(0.02)

        for index in range(count):
            if display is not None and index % 5 == 0:
                display.set(alternate=(index // 5) % 2 == 0)
            suffix = serial + alphabet[index]
            marker = f"SURFACE{suffix}"
            # CreateInitialInput.decide appends CR, so this is executed once
            # without an extra blank command from a second submit byte.
            initial = f"printf '\\n%s%s\\n' 'SURFACE' '{suffix}'"
            params = {"workspace_id": workspace, "initial_input": initial, "cwd": "/tmp"}
            before = time.monotonic()
            if display is not None and index % 5 == 0:
                params.update({"panel_id": seed_id, "direction": "right", "force": True})
                response = call("panel.split", params)
                require(response.get("size_outcome") in ("split", "flipped"),
                        f"split was not exercised: {response}")
                split = panel_id(response)
            else:
                params.update({"area_id": seed_area, "type": "terminal", "focus": False})
                response = call("panel.create", params)
            new_id = panel_id(response)
            created[new_id] = marker
            rpc_ms.append((time.monotonic() - before) * 1000)
            call("panel.focus", {"workspace_id": workspace, "panel_id": new_id})
            if display is not None and index % 5 == 4:
                observe(split)
                call("panel.close", {"workspace_id": workspace, "panel_id": split})
                closed.add(split)

        for live_id in sorted(created.keys() - closed):
            observe(live_id)

        require(len(observations) == count and {item["panel_id"] for item in observations} == created.keys(),
                "not every created panel has exact-marker pixel evidence")
        if display is not None:
            require(len(display.history) == 4 and all(item["scale_changed"] for item in display.history),
                    "four real backing-scale changes were not observed")

        # Exercise the late release, not merely the interval when it was held.
        # Ping proves responsiveness; debug.terminals is the main-thread barrier
        # before inspecting the post-expiry trace and model liveness.
        while True:
            now = time.monotonic()
            if now >= cancellation_expires + 0.1:
                break
            if now >= deadline:
                raise TimeoutError("cancellation release was not observed before the scenario deadline")
            time.sleep(min(0.05, cancellation_expires + 0.1 - now))
        call("system.ping")
        after_expiry = call("debug.terminals").get("terminals") or []
        require(cancelled not in {str(row.get("panel_id") or row.get("surface_id")).lower()
                                 for row in after_expiry},
                "cancelled terminal resurrected after the hold expired")
        report["cancellation"]["checked_after_start_seconds"] = time.monotonic() - started
        report["cancellation"]["post_expiry_main_query_returned"] = True

        if arguments.native_lock_only:
            held_marker = "C11_248_FONT_LOCK_HELD"
            released_marker = "C11_248_FONT_LOCK_RELEASED"
            fixture_deadline = min(deadline - 0.1, time.monotonic() + 2.5)
            while True:
                fixture_output = appended_text(stdout, stdout_offset)
                held_at = fixture_output.find(held_marker)
                released_at = fixture_output.find(released_marker)
                require(fixture_output.count(held_marker) <= 1 and fixture_output.count(released_marker) <= 1,
                        "native fixture markers repeat; stdout is not isolated to one launch")
                if held_at >= 0 and released_at > held_at:
                    report["native_lock_fixture"] = {
                        "held": True, "released": True, "stdout": str(stdout),
                        "markers": [held_marker, released_marker], "panel_id": fixture_id,
                    }
                    break
                if time.monotonic() >= fixture_deadline:
                    raise BlockedEnvironment("native lock fixture did not hold and release in this launch; verify the fixture kit and C11_TEST_CREATION_FONT_LOCK=1")
                time.sleep(0.02)

        new_trace = appended_text(trace, trace_offset)
        expected_timing_ids = created.keys() | ({fixture_id} if fixture_id else set())
        timings: dict[str, dict[str, list[float]]] = {"native": {}, "total": {}}
        for match in TRACE_RE.finditer(new_trace):
            kind, native_id, milliseconds, success = match.groups()
            native_id = native_id.lower()
            if native_id in expected_timing_ids or native_id == cancelled:
                if success not in ("true", "1"):
                    # A parked restore/start or the cancellation fixture enters
                    # createSurface but deliberately returns before native creation.
                    require(kind == "total", f"native creation failed: {match.group(0)}")
                    continue
                timings[kind].setdefault(native_id, []).append(float(milliseconds))
        survivors = created.keys() - closed
        maxima = {}
        for kind, entries in timings.items():
            missing = sorted(expected_timing_ids - entries.keys())
            require(not missing, f"{kind} creation timings missing for attached panels: {missing}")
            require(cancelled not in entries, f"panel closed before attachment entered {kind} creation")
            require(all(len(values) == 1 for values in entries.values()), f"duplicate {kind} creation: {entries}")
            maxima[kind] = max(value for values in entries.values() for value in values)
        report.update({"display_changes": display.history if display is not None else [], "created": count,
                       "closed_during_churn": sorted(closed), "cancelled_before_attach": cancelled,
                       "panels_observed_before_close": observations, "creation_ms": timings,
                       "creation_max_ms": maxima, "create_rpc_ms": rpc_ms, "trace": str(trace)})
        # The native/full timers begin after the model's inherited font lookup.
        # Bound the complete creation request too, so moving a wait earlier
        # cannot make a blocking terminal creation look like a pass.
        require(max(rpc_ms) <= MAX_CREATION_MS,
                f"creation request waited {max(rpc_ms):.3f} ms; maximum is {MAX_CREATION_MS}")
        for kind, maximum in maxima.items():
            require(maximum <= MAX_CREATION_MS, f"{kind} creation waited {maximum:.3f} ms; maximum is {MAX_CREATION_MS}")
        remaining = call("panel.list", {"workspace_id": workspace}).get("panels") or []
        remaining_ids = {str(row["id"]).lower() for row in remaining}
        require(not (closed | {cancelled}) & remaining_ids, "closed panel resurrected during churn")
        require(survivors <= remaining_ids, "surviving panel disappeared during churn")
        report["verdict"] = "PASS"
        result = 0
    except BlockedEnvironment as error:
        report.update({"verdict": "BLOCKED-ENV", "error": str(error)})
        result = 2
    except (AssertionError, RuntimeError, OSError, cmuxError, TimeoutError, subprocess.TimeoutExpired) as error:
        report.update({"verdict": "FAIL", "error": str(error)})
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        cleanup_errors = []
        if c is not None:
            # Only UUIDs created by this driver are eligible for cleanup. A stuck
            # app cannot lengthen the overall watchdog or reach another socket.
            for own_id in (created.keys() - closed) | ({cancelled} if cancelled else set()):
                if time.monotonic() - started >= 28:
                    cleanup_errors.append("panel cleanup deadline; sandbox-down required")
                    break
                try:
                    c._call("panel.close", {"panel_id": own_id}, timeout_s=0.25)
                except Exception as error:
                    if "not_found" not in str(error):
                        cleanup_errors.append(str(error))
                        break  # A timed-out stream cannot be reused safely.
            c.close()
        if display is not None:
            try:
                display.close()
            except Exception as error:
                cleanup_errors.append(str(error))
        if cleanup_errors:
            report["cleanup_errors"] = cleanup_errors
            report["verdict"] = "FAIL"
            result = 1
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        print(json.dumps(report, sort_keys=True), flush=True)
        finished.set()
    return result


if __name__ == "__main__":
    raise SystemExit(main())
