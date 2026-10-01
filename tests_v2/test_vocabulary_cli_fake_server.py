#!/usr/bin/env python3
"""Vocabulary regression for the CLI side, against a fake socket server. Needs no app.

The bundled CLI is driven against an in-process fake that speaks the v2 socket protocol
(and the v1 text protocol), in two flavors:

- modern: knows tab.* / area.* beside the hidden surface.* / pane.* aliases, and answers
  with canonical and legacy keys.
- legacy: an app that predates the vocabulary. It knows only surface.* / pane.*, legacy
  param keys and `surface:N` / `pane:N` refs, and rejects anything canonical.

What this pins (review items 1, 2, 9, 17):

- tmux format variables `#{pane_id}`, `#{pane_index}`, `#{surface_id}` keep rendering
  through `display-message` (the tmux shim keeps tmux vocabulary).
- `default-agent launch --in-tab` / `--in-surface` / `--area` / `--pane` compose the
  v1 wire the app understands (`--in-surface`, `--pane`).
- reorder/move flags (`--before-tab`, `--after-surface`, ...) reach the app as canonical
  params, in every spelling.
- version skew: the CLI probes `system.capabilities` once and, against a legacy app,
  sends legacy methods, legacy param keys and legacy ref values for every request
  (unchanged-name methods and nested keys included). Against a modern app it never
  retries a failed request.

CLI binary: C11_CLI / CMUX_CLI_BIN, else the usual tests_v2 discovery.
"""

from __future__ import annotations

import json
import os
import re
import socketserver
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError, find_cli_binary  # type: ignore[import]


WS = "11111111-1111-4111-8111-111111111111"
WIN = "22222222-2222-4222-8222-222222222222"
A1 = "33333333-3333-4333-8333-333333333331"
A2 = "33333333-3333-4333-8333-333333333332"
T1 = "44444444-4444-4444-8444-444444444441"
T2 = "44444444-4444-4444-8444-444444444442"
T3 = "44444444-4444-4444-8444-444444444443"
NEW_A = "33333333-3333-4333-8333-333333333399"
NEW_T = "44444444-4444-4444-8444-444444444499"

# Areas: (uuid, ordinal, tmux index). Tabs: (uuid, ordinal, area uuid, title).
AREAS = [(A1, 1, 7), (A2, 2, 8)]
TABS = [(T1, 1, A1, "leader"), (T2, 2, A1, "second"), (T3, 3, A2, "teammate")]

ID_ENV_KEYS = (
    "C11_TAB_ID", "C11_SURFACE_ID", "C11_PANEL_ID", "C11_WORKSPACE_ID",
    "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_WORKSPACE_ID",
    "TMUX", "TMUX_PANE",
)

CANONICAL_METHOD_PREFIXES = ("tab.", "area.")
LEGACY_METHOD_PREFIXES = ("surface.", "pane.")

# Param keys only an up-to-date app understands, and the ones only an old app does.
CANONICAL_PARAM_KEYS = {
    "tab_id", "tab_ref", "area_id", "area_ref", "before_tab_id", "after_tab_id",
    "target_tab_id", "source_tab_id", "target_area_id", "source_area_id",
    "caller_tab_id",
}
LEGACY_PARAM_KEYS = {
    "surface_id", "surface_ref", "pane_id", "pane_ref", "before_surface_id",
    "after_surface_id", "target_surface_id", "source_surface_id",
    "target_pane_id", "source_pane_id", "caller_surface_id", "panel_id",
}


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _walk_params(value: Any, path: str = ""):
    """Yield (path, key, value) for every dict entry and (path, None, value) for every scalar."""
    if isinstance(value, dict):
        for key, child in value.items():
            yield (path, key, child)
            yield from _walk_params(child, f"{path}.{key}")
    elif isinstance(value, list):
        for idx, child in enumerate(value):
            yield from _walk_params(child, f"{path}[{idx}]")
    else:
        yield (path, None, value)


# ---------------------------------------------------------------------------
# The fake app
# ---------------------------------------------------------------------------

class FakeApp:
    def __init__(self, vocabulary: str) -> None:
        assert vocabulary in ("modern", "legacy")
        self.vocabulary = vocabulary
        self.lock = threading.Lock()
        self.v2: List[Tuple[str, Dict[str, Any]]] = []
        self.v1: List[str] = []
        self.violations: List[str] = []
        self.fail_once: Dict[str, str] = {}   # method -> error code, consumed on first hit
        self.split_done = False

    # -- refs ---------------------------------------------------------------

    @property
    def legacy(self) -> bool:
        return self.vocabulary == "legacy"

    def tab_ref(self, ordinal: int, *, legacy: bool) -> str:
        return f"{'surface' if legacy else 'tab'}:{ordinal}"

    def area_ref(self, ordinal: int, *, legacy: bool) -> str:
        return f"{'pane' if legacy else 'area'}:{ordinal}"

    def _areas(self) -> List[Tuple[str, int, int]]:
        extra = [(NEW_A, 3, 9)] if self.split_done else []
        return AREAS + extra

    def _tabs(self) -> List[Tuple[str, int, str, str]]:
        extra = [(NEW_T, 4, NEW_A, "split")] if self.split_done else []
        return TABS + extra

    def _tab_by_handle(self, handle: str) -> Tuple[str, int, str, str]:
        for tab in self._tabs():
            if handle in (tab[0], f"tab:{tab[1]}", f"surface:{tab[1]}"):
                return tab
        raise KeyError(handle)

    def _area_by_handle(self, handle: str) -> Tuple[str, int, int]:
        for area in self._areas():
            if handle in (area[0], f"area:{area[1]}", f"pane:{area[1]}"):
                return area
        raise KeyError(handle)

    # -- rows ---------------------------------------------------------------

    def _tab_row(self, tab: Tuple[str, int, str, str]) -> Dict[str, Any]:
        tid, n, aid, title = tab
        area = self._area_by_handle(aid)
        legacy_row = {
            "id": tid, "ref": self.tab_ref(n, legacy=True), "title": title,
            "index": n, "selected": tid == T1, "focused": tid == T1,
            "pane_id": aid, "pane_ref": self.area_ref(area[1], legacy=True),
        }
        if self.legacy:
            return legacy_row
        row = dict(legacy_row)
        row.update({
            "ref": self.tab_ref(n, legacy=False),
            "area_id": aid, "area_ref": self.area_ref(area[1], legacy=False),
        })
        return row

    def _area_row(self, area: Tuple[str, int, int]) -> Dict[str, Any]:
        aid, n, index = area
        tabs = [t for t in self._tabs() if t[2] == aid]
        legacy_row = {
            "id": aid, "ref": self.area_ref(n, legacy=True), "index": index,
            "surface_ids": [t[0] for t in tabs],
        }
        if self.legacy:
            return legacy_row
        row = dict(legacy_row)
        row.update({"ref": self.area_ref(n, legacy=False), "tab_ids": [t[0] for t in tabs]})
        return row

    def _focus_block(self) -> Dict[str, Any]:
        tab, area = TABS[0], AREAS[0]
        block: Dict[str, Any] = {
            "workspace_id": WS, "workspace_ref": "workspace:1",
            "window_id": WIN, "window_ref": "window:1",
            "pane_id": area[0], "pane_ref": self.area_ref(area[1], legacy=True),
            "surface_id": tab[0], "surface_ref": self.tab_ref(tab[1], legacy=True),
            "surface_type": "terminal",
        }
        if not self.legacy:
            block.update({
                "area_id": area[0], "area_ref": self.area_ref(area[1], legacy=False),
                "tab_id": tab[0], "tab_ref": self.tab_ref(tab[1], legacy=False),
                "tab_type": "terminal",
            })
        return block

    # -- dispatch -----------------------------------------------------------

    @staticmethod
    def canonical_method(method: str) -> str:
        if method == "pane.surfaces":
            return "area.tabs"
        if method.startswith("surface."):
            return "tab." + method[len("surface."):]
        if method.startswith("pane."):
            return "area." + method[len("pane."):]
        return method

    def capabilities(self) -> Dict[str, Any]:
        base = ["system.ping", "system.capabilities", "system.identify", "window.list",
                "workspace.list", "workspace.current", "browser.url.get"]
        names = ["list", "current", "focus", "move", "reorder", "send_text", "split"]
        if self.legacy:
            methods = base + [f"surface.{n}" for n in names] + ["pane.list", "pane.surfaces"]
        else:
            methods = base + [f"tab.{n}" for n in names] + ["area.list", "area.tabs"]
        return {"protocol": "cmux-socket", "version": 2, "methods": sorted(methods)}

    def handle_v2(self, method: str, params: Dict[str, Any]) -> Tuple[bool, Any]:
        with self.lock:
            self.v2.append((method, params))
            code = self.fail_once.pop(method, None)
            if code:
                return False, {"code": code, "message": f"injected {code}"}

            # What this flavor of app does not understand.
            if self.legacy and method.startswith(CANONICAL_METHOD_PREFIXES + ("notification.create_for_tab",)):
                self.violations.append(f"canonical method on a legacy app: {method}")
                return False, {"code": "method_not_found", "message": f"Unknown method: {method}"}
            if not self.legacy and method.startswith(LEGACY_METHOD_PREFIXES):
                self.violations.append(f"legacy method on a modern app: {method}")
            seen = len(self.violations)
            for path, key, value in _walk_params(params):
                if self.legacy:
                    if key in CANONICAL_PARAM_KEYS:
                        self.violations.append(f"{method}: canonical param key {path}.{key}")
                    if isinstance(value, str) and re.match(r"^(tab|area):\d+$", value):
                        self.violations.append(f"{method}: canonical ref value {value!r} at {path}.{key or ''}")
                elif key in LEGACY_PARAM_KEYS and not method.startswith("browser."):
                    self.violations.append(f"{method}: legacy param key {path}.{key} on a modern app")
            if self.legacy and len(self.violations) > seen:
                return False, {"code": "invalid_params", "message": self.violations[-1]}

            return self._dispatch(self.canonical_method(method), params)

    def _dispatch(self, method: str, params: Dict[str, Any]) -> Tuple[bool, Any]:
        if method == "system.capabilities":
            return True, self.capabilities()
        if method == "system.ping":
            return True, {"pong": True}
        if method == "system.identify":
            result: Dict[str, Any] = {"focused": self._focus_block()}
            caller = params.get("caller")
            if isinstance(caller, dict):
                block = self._focus_block()
                tab_key = caller.get("tab_id") or caller.get("surface_id")
                if tab_key:
                    tab = self._tab_by_handle(str(tab_key))
                    block["surface_id"] = tab[0]
                    if not self.legacy:
                        block["tab_id"] = tab[0]
                result["caller"] = block
            return True, result
        if method == "window.list":
            return True, {"windows": [{"id": WIN, "ref": "window:1", "workspace_id": WS, "workspace_ref": "workspace:1"}]}
        if method == "workspace.list":
            return True, {"workspaces": [{"id": WS, "ref": "workspace:1", "index": 1, "title": "demo", "selected": True}]}
        if method == "workspace.current":
            return True, {"workspace_id": WS, "workspace_ref": "workspace:1"}
        if method == "tab.list":
            rows = [self._tab_row(t) for t in self._tabs()]
            return True, {"workspace_id": WS, "workspace_ref": "workspace:1",
                          ("surfaces" if self.legacy else "tabs"): rows,
                          **({} if self.legacy else {"surfaces": rows})}
        if method == "area.list":
            rows = [self._area_row(a) for a in self._areas()]
            return True, {"workspace_id": WS, "workspace_ref": "workspace:1",
                          ("panes" if self.legacy else "areas"): rows,
                          **({} if self.legacy else {"panes": rows})}
        if method == "area.tabs":
            handle = str(params.get("area_id") or params.get("pane_id") or "")
            try:
                area = self._area_by_handle(handle)
            except KeyError:
                return False, {"code": "not_found", "message": f"area not found: {handle}"}
            rows = [{"id": t[0], "selected": t[0] == T1} for t in self._tabs() if t[2] == area[0]]
            return True, {("surfaces" if self.legacy else "tabs"): rows,
                          **({} if self.legacy else {"surfaces": rows})}
        if method == "tab.current":
            block = self._focus_block()
            block.pop("window_id", None)
            block.pop("window_ref", None)
            return True, block
        if method in ("tab.focus", "tab.move", "tab.reorder", "tab.send_text"):
            return True, {"workspace_id": WS, "workspace_ref": "workspace:1", "ok": True,
                          **{k: v for k, v in self._tab_ids_for(params).items()}}
        if method == "tab.split":
            self.split_done = True
            return True, {"tab_id": NEW_T, "surface_id": NEW_T, "area_id": NEW_A, "pane_id": NEW_A}
        if method == "browser.url.get":
            return True, {"url": "https://example.test/"}
        return False, {"code": "method_not_found", "message": f"fake app has no method {method}"}

    def _tab_ids_for(self, params: Dict[str, Any]) -> Dict[str, Any]:
        handle = params.get("tab_id") or params.get("surface_id")
        if not handle:
            return {}
        try:
            tab = self._tab_by_handle(str(handle))
        except KeyError:
            return {}
        out: Dict[str, Any] = {"surface_id": tab[0], "surface_ref": self.tab_ref(tab[1], legacy=True)}
        if not self.legacy:
            out.update({"tab_id": tab[0], "tab_ref": self.tab_ref(tab[1], legacy=False)})
        return out

    def handle_v1(self, line: str) -> str:
        with self.lock:
            self.v1.append(line)
        if line == "ping":
            return "PONG"
        return "OK"

    def calls(self, method: str) -> List[Dict[str, Any]]:
        with self.lock:
            return [p for m, p in self.v2 if m == method]

    def methods(self) -> List[str]:
        with self.lock:
            return [m for m, _ in self.v2]

    def reset(self) -> None:
        with self.lock:
            self.v2.clear()
            self.v1.clear()
            self.violations.clear()
            self.fail_once.clear()


class _Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        app: FakeApp = self.server.app  # type: ignore[attr-defined]
        while True:
            line = self.rfile.readline()
            if not line:
                return
            text = line.decode("utf-8").strip()
            if text.startswith("{"):
                request = json.loads(text)
                ok, payload = app.handle_v2(str(request.get("method")), request.get("params") or {})
                response: Dict[str, Any] = {"id": request.get("id"), "ok": ok}
                response["result" if ok else "error"] = payload
                out = json.dumps(response)
            else:
                out = app.handle_v1(text)
            self.wfile.write((out + "\n").encode("utf-8"))
            self.wfile.flush()


class _Server(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, path: str, app: FakeApp) -> None:
        self.app = app
        super().__init__(path, _Handler)


class Running:
    def __init__(self, vocabulary: str, tmp: Path) -> None:
        self.app = FakeApp(vocabulary)
        self.path = str(tmp / f"{vocabulary}.sock")
        self.server = _Server(self.path, self.app)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


# ---------------------------------------------------------------------------
# CLI runner
# ---------------------------------------------------------------------------

def _resolve_cli() -> str:
    for key in ("C11_CLI", "CMUX_CLI_BIN", "CMUX_CLI"):
        value = os.environ.get(key)
        if value and os.path.isfile(value) and os.access(value, os.X_OK):
            return value
    return find_cli_binary()


def _run(cli: str, run: Running, args: Sequence[str], extra_env: Optional[Dict[str, str]] = None,
         check: bool = True) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    for key in ID_ENV_KEYS:
        env.pop(key, None)
    env["CMUX_SOCKET_PATH"] = run.path
    env["C11_SOCKET_PATH"] = run.path
    env["CMUX_SOCKET"] = run.path
    env["C11_SOCKET"] = run.path
    env.update(extra_env or {})
    cmd = [cli, "--socket", run.path, *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env, timeout=30)
    if check and proc.returncode != 0:
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): exit={proc.returncode} {proc.stdout!r} {proc.stderr!r}")
    return proc


def _json(cli: str, run: Running, args: Sequence[str], extra_env: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    proc = _run(cli, run, ["--json", "--id-format", "both", *args], extra_env)
    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise cmuxError(f"invalid JSON from `{' '.join(args)}`: {proc.stdout!r} ({exc})")


def _tmux(cli: str, run: Running, args: Sequence[str]) -> List[str]:
    proc = _run(cli, run, ["__tmux-compat", *args])
    return proc.stdout.splitlines()


# ---------------------------------------------------------------------------
# tmux format variables (review item 1)
# ---------------------------------------------------------------------------

def test_tmux_format_variables(cli: str, run: Running) -> None:
    run.app.reset()
    target = f"%{A1}"
    expectations = [
        ("#{pane_id}", f"%{A1}"),
        ("#{pane_index}", "7"),
        ("#{surface_id}", T1),
        ("#{pane_uuid}", A1),
        ("#{window_id}", f"@{WS}"),
        ("#{session_name}:#{window_index}.#{pane_index}", "cmux:1.7"),
        ("#{pane_id} #{pane_title}", f"%{A1} leader"),
        ("#{pane_index}/#{surface_id}", f"7/{T1}"),
    ]
    for fmt, want in expectations:
        out = _tmux(cli, run, ["display-message", "-t", target, "-p", fmt])
        _must(out == [want], f"display-message -p {fmt!r} printed {out!r}, expected {[want]!r}")

    # Without -t the format resolves against the focused area.
    out = _tmux(cli, run, ["display-message", "-p", "#{pane_id}"])
    _must(out == [f"%{A1}"], f"display-message -p '#{{pane_id}}' (no -t) printed {out!r}")

    # The second area renders its own values.
    out = _tmux(cli, run, ["display-message", "-t", f"%{A2}", "-p", "#{pane_index} #{surface_id}"])
    _must(out == [f"8 {T3}"], f"display-message for the second area printed {out!r}")

    # list-panes and split-window -P render through the same context.
    out = _tmux(cli, run, ["list-panes", "-F", "#{pane_index}:#{pane_id}"])
    _must(out == [f"7:%{A1}", f"8:%{A2}"], f"list-panes -F printed {out!r}")
    out = _tmux(cli, run, ["split-window", "-t", target, "-h", "-P", "-F", "#{pane_id}"])
    _must(out == [f"%{NEW_A}"], f"split-window -P -F '#{{pane_id}}' printed {out!r}")
    _must(not run.app.violations, f"tmux shim sent non-canonical wire: {run.app.violations}")
    print("PASS: tmux #{pane_id} / #{pane_index} / #{surface_id} render through display-message, list-panes, split-window")


# ---------------------------------------------------------------------------
# v1 wire for default-agent launch (review item 2)
# ---------------------------------------------------------------------------

def _launch_wire(cli: str, run: Running, args: Sequence[str]) -> str:
    run.app.reset()
    _run(cli, run, ["default-agent", "launch", *args])
    launches = [line for line in run.app.v1 if line.startswith("default_agent launch")]
    _must(len(launches) == 1, f"expected one v1 default_agent launch for {args}, got {run.app.v1}")
    return launches[0]


def test_default_agent_launch_wire(cli: str, run: Running) -> None:
    cases: List[Tuple[List[str], str]] = [
        (["--in-surface", T1], f"default_agent launch --in-surface {T1}"),
        (["--in-tab", T1], f"default_agent launch --in-surface {T1}"),
        (["--in-tab", "tab:3"], f"default_agent launch --in-surface {T3}"),
        (["--in-surface", "surface:3"], f"default_agent launch --in-surface {T3}"),
        (["--agent", "claude", "--in-tab", T2], f"default_agent launch --agent claude --in-surface {T2}"),
        (["--area", A2], f"default_agent launch --pane {A2}"),
        (["--pane", A2], f"default_agent launch --pane {A2}"),
    ]
    for args, want in cases:
        got = _launch_wire(cli, run, args)
        _must(got == want, f"`default-agent launch {' '.join(args)}` composed {got!r}, expected {want!r}")
        _must("--in-tab" not in got and "--area" not in got, f"v1 wire must stay closed: {got!r}")

    # --in-tab and --area (or their old spellings) are mutually exclusive: nothing reaches the app.
    for args in (["--in-tab", T1, "--area", A2], ["--in-surface", T1, "--pane", A2]):
        run.app.reset()
        proc = _run(cli, run, ["default-agent", "launch", *args], check=False)
        _must(proc.returncode != 0, f"`default-agent launch {' '.join(args)}` should fail: {proc.stdout!r}")
        _must("mutually exclusive" in (proc.stdout + proc.stderr), f"missing exclusivity error: {proc.stdout!r} {proc.stderr!r}")
        _must(not [line for line in run.app.v1 if line.startswith("default_agent")], f"launch reached the app: {run.app.v1}")
    print("PASS: default-agent launch --in-tab/--in-surface/--area/--pane compose the v1 wire (--in-surface, --pane)")


# ---------------------------------------------------------------------------
# reorder / move flag spellings (review item 17)
# ---------------------------------------------------------------------------

def test_reorder_and_move_flags(cli: str, run: Running) -> None:
    placement: List[Tuple[List[str], str, str]] = [
        (["--before-tab", T1], "before_tab_id", T1),
        (["--before-surface", T1], "before_tab_id", T1),
        (["--after-tab", T1], "after_tab_id", T1),
        (["--after-surface", T1], "after_tab_id", T1),
        (["--before", T1], "before_tab_id", T1),
        (["--after", T1], "after_tab_id", T1),
    ]
    for target_flag in ("--tab", "--surface", "--panel"):
        for flags, key, value in placement:
            run.app.reset()
            _run(cli, run, ["reorder-tab", target_flag, T2, *flags])
            calls = run.app.calls("tab.reorder")
            _must(len(calls) == 1, f"reorder-tab {target_flag} {flags}: expected one tab.reorder, got {run.app.methods()}")
            _must(calls[0].get("tab_id") == T2, f"reorder-tab {target_flag} {flags}: tab_id {calls[0]}")
            _must(calls[0].get(key) == value, f"reorder-tab {target_flag} {flags}: {key} missing in {calls[0]}")
            _must(not run.app.violations, f"reorder-tab sent non-canonical params: {run.app.violations}")
    # The old command name takes the old flags too.
    run.app.reset()
    _run(cli, run, ["reorder-surface", "--surface", T2, "--after-surface", T1])
    calls = run.app.calls("tab.reorder")
    _must(len(calls) == 1 and calls[0].get("tab_id") == T2 and calls[0].get("after_tab_id") == T1,
          f"reorder-surface --after-surface composed {calls}")

    for area_flag in ("--area", "--pane"):
        for flags, key, value in placement[:4]:
            run.app.reset()
            _run(cli, run, ["move-tab", "--tab", T2, area_flag, A2, *flags])
            calls = run.app.calls("tab.move")
            _must(len(calls) == 1, f"move-tab {area_flag} {flags}: expected one tab.move, got {run.app.methods()}")
            call = calls[0]
            _must(call.get("tab_id") == T2 and call.get("area_id") == A2 and call.get(key) == value,
                  f"move-tab {area_flag} {flags} composed {call}")
            _must(not run.app.violations, f"move-tab sent non-canonical params: {run.app.violations}")
    run.app.reset()
    _run(cli, run, ["move-surface", "--surface", T2, "--pane", A2, "--before-surface", T3])
    calls = run.app.calls("tab.move")
    _must(len(calls) == 1 and calls[0].get("area_id") == A2 and calls[0].get("before_tab_id") == T3,
          f"move-surface --pane --before-surface composed {calls}")
    print("PASS: --before-tab/--after-tab/--before-surface/--after-surface (and --before/--after) reach the app as canonical params")


# ---------------------------------------------------------------------------
# Version skew: capability probe (review items 9 and 17)
# ---------------------------------------------------------------------------

def test_modern_app_gets_canonical_names_and_no_retry(cli: str, run: Running) -> None:
    run.app.reset()
    _run(cli, run, ["focus-tab", "--tab", "tab:2"])
    _run(cli, run, ["list-area-tabs", "--area", "area:1"])
    _run(cli, run, ["list-tabs"])
    _run(cli, run, ["list-areas"])
    methods = run.app.methods()
    _must(not any(m.startswith(LEGACY_METHOD_PREFIXES) for m in methods), f"CLI sent a legacy method to a modern app: {methods}")
    _must(methods.count("system.capabilities") <= len(("focus-tab", "list-area-tabs", "list-tabs", "list-areas")),
          f"capability probe should run at most once per invocation: {methods}")
    focus = run.app.calls("tab.focus")
    _must(len(focus) == 1 and focus[0].get("tab_id") == "tab:2", f"focus-tab --tab tab:2 composed {focus}")
    _must(not run.app.violations, f"non-canonical wire on a modern app: {run.app.violations}")

    # A rejected request is never retried under another spelling.
    for code in ("invalid_params", "missing_ref", "method_not_found"):
        run.app.reset()
        run.app.fail_once["tab.focus"] = code
        proc = _run(cli, run, ["focus-tab", "--tab", T2], check=False)
        _must(proc.returncode != 0, f"focus-tab should fail when the app answers {code}: {proc.stdout!r}")
        _must(code in (proc.stdout + proc.stderr), f"error should carry the app's code {code}: {proc.stdout!r} {proc.stderr!r}")
        attempts = [m for m in run.app.methods() if m.endswith(".focus")]
        _must(attempts == ["tab.focus"], f"a rejected tab.focus ({code}) must not be retried: {attempts}")
    print("PASS: modern app: canonical names only, one attempt per request, no retry")


def test_legacy_app_gets_legacy_wire(cli: str, run: Running) -> None:
    app = run.app

    def fresh() -> None:
        app.reset()

    # Probe first, then everything in the legacy spelling.
    fresh()
    out = _json(cli, run, ["list-tabs"])
    methods = app.methods()
    _must(methods and methods[0] == "system.capabilities", f"the first request must be the capability probe: {methods}")
    _must("surface.list" in methods and "tab.list" not in methods, f"list-tabs against a legacy app used {methods}")
    _must(not app.violations, f"legacy app saw canonical wire: {app.violations}")
    rows = out.get("tabs")
    _must(isinstance(rows, list) and sorted(r.get("id") for r in rows) == sorted(t[0] for t in TABS),
          f"list-tabs --json should expose the canonical `tabs` key from a legacy app: {out}")
    _must(all(str(r.get("ref", "")).startswith("tab:") for r in rows), f"refs should be modernized for the user: {rows}")

    fresh()
    out = _json(cli, run, ["list-areas"])
    rows = out.get("areas")
    _must(isinstance(rows, list) and sorted(r.get("id") for r in rows) == [A1, A2], f"list-areas --json from a legacy app: {out}")
    _must("pane.list" in app.methods() and "area.list" not in app.methods(), f"list-areas used {app.methods()}")
    _must(not app.violations, f"legacy app saw canonical wire: {app.violations}")

    # Ref values convert too: tab:N / area:N never reach an app that only knows surface:N / pane:N.
    fresh()
    _run(cli, run, ["focus-tab", "--tab", "tab:2"])
    focus = app.calls("surface.focus")
    _must(len(focus) == 1 and focus[0].get("surface_id") == "surface:2", f"focus-tab --tab tab:2 composed {focus}")
    _must(not app.violations, f"legacy app saw canonical wire: {app.violations}")

    fresh()
    _run(cli, run, ["list-area-tabs", "--area", "area:2"])
    calls = app.calls("pane.surfaces")
    _must(len(calls) == 1 and calls[0].get("pane_id") == "pane:2", f"list-area-tabs --area area:2 composed {calls}")
    _must(not app.violations, f"legacy app saw canonical wire: {app.violations}")

    fresh()
    _run(cli, run, ["move-tab", "--tab", T2, "--area", "area:2", "--before-tab", "tab:3"])
    calls = app.calls("surface.move")
    _must(len(calls) == 1, f"move-tab against a legacy app used {app.methods()}")
    call = calls[0]
    _must(call.get("surface_id") == T2 and call.get("pane_id") == "pane:2" and call.get("before_surface_id") == "surface:3",
          f"move-tab composed {call}")
    _must(not app.violations, f"legacy app saw canonical wire: {app.violations}")

    fresh()
    _run(cli, run, ["reorder-tab", "--tab", "tab:2", "--after-tab", T1])
    calls = app.calls("surface.reorder")
    _must(len(calls) == 1 and calls[0].get("surface_id") == "surface:2" and calls[0].get("after_surface_id") == T1,
          f"reorder-tab composed {calls}")
    _must(not app.violations, f"legacy app saw canonical wire: {app.violations}")

    # Unchanged-name methods and nested keys convert as well.
    fresh()
    _run(cli, run, ["browser", "tab:3", "get-url"], check=False)
    calls = app.calls("browser.url.get")
    _must(len(calls) == 1 and calls[0].get("surface_id") == "surface:3" and "tab_id" not in calls[0],
          f"browser get-url against a legacy app composed {calls}")
    _must(not app.violations, f"legacy app saw canonical wire: {app.violations}")

    fresh()
    out = _run(cli, run, ["--id-format", "both", "identify", "--workspace", WS, "--tab", "tab:2"]).stdout
    calls = app.calls("system.identify")
    _must(len(calls) == 1, f"identify sent {app.methods()}")
    caller = calls[0].get("caller") or {}
    _must(caller.get("surface_id") == "surface:2" and "tab_id" not in caller, f"identify caller block against a legacy app: {caller}")
    _must(not app.violations, f"legacy app saw canonical wire: {app.violations}")
    block = (json.loads(out).get("caller") or {})
    _must(block.get("tab_id") == T2, f"identify output should carry the canonical caller.tab_id from a legacy app: {block}")

    # The probe runs once per invocation, even for multi-request commands.
    fresh()
    _run(cli, run, ["move-tab", "--tab", "tab:2", "--area", "area:2"])
    _must(app.methods().count("system.capabilities") == 1, f"probe should run once per invocation: {app.methods()}")
    print("PASS: legacy app: capability probe first, then legacy methods, keys and ref values on every request")


# ---------------------------------------------------------------------------

def main() -> int:
    cli = _resolve_cli()
    with tempfile.TemporaryDirectory(prefix="c11vf-") as td:
        tmp = Path(td)
        modern = Running("modern", tmp)
        legacy = Running("legacy", tmp)
        try:
            test_tmux_format_variables(cli, modern)
            test_default_agent_launch_wire(cli, modern)
            test_reorder_and_move_flags(cli, modern)
            test_modern_app_gets_canonical_names_and_no_retry(cli, modern)
            test_legacy_app_gets_legacy_wire(cli, legacy)
        finally:
            modern.stop()
            legacy.stop()
    print("PASS: vocabulary CLI fake-server checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
