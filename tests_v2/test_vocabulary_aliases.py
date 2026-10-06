#!/usr/bin/env python3
"""Vocabulary regression: workspace > area > panel, with silent tab/surface/pane aliases.

The canonical names are `panel.*` / `area.*` socket methods, `panel_id` / `area_id`
params, `panel:N` / `area:N` refs, `new-panel` / `list-areas` CLI commands and
`C11_PANEL_ID`. Every older spelling must keep resolving to the same object and
behavior:

- methods: `tab.*` and `surface.*` (for `panel.*`), `pane.*` and `pane.surfaces` /
  `area.tabs` (for `area.*` / `area.panels`), `notification.create_for_tab|surface`,
  `browser.tab.*`, `debug.tab_snapshot` and the other debug renames.
- params: `tab_id` / `surface_id` / `*_ref` (and `pane_id` / `pane_ref`), refs
  `tab:N` / `surface:N` / `pane:N` with any prefix case.
- CLI: `new-tab` / `new-surface` / `list-tabs` / `focus-tab` ... , flags `--tab` /
  `--surface` / `--pane`, env `C11_TAB_ID` / `C11_SURFACE_ID` / `CMUX_*`.

Results carry `panel_*` beside the v0.67 `tab_*` spelling (the `tab_*` ref values
keep `tab:N`), `area_*` alone, `panels` + `tabs` arrays, and never `surface_*` /
`pane_*` / `surfaces` / `panes`.

Runs against a live tagged build, like the rest of tests_v2:

    C11_SOCKET=/tmp/c11-debug-<tag>.sock python3 tests_v2/test_vocabulary_aliases.py
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError, find_cli_binary  # type: ignore[import]


def _socket_path() -> str:
    for key in ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH"):
        value = os.environ.get(key)
        if value:
            return value
    return "/tmp/cmux-debug.sock"


SOCKET_PATH = _socket_path()

ID_ENV_KEYS = (
    "C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID",
    "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID",
    "C11_PANEL_NUM", "C11_TAB_NUM", "C11_SURFACE_NUM",
    "CMUX_PANEL_NUM", "CMUX_TAB_NUM", "CMUX_SURFACE_NUM",
    "C11_WORKSPACE_ID", "CMUX_WORKSPACE_ID",
)

# Every spelling of a panel (the c11 leaf) and of an area.
PANEL_FAMILIES = ("panel", "tab", "surface")
AREA_FAMILIES = ("area", "pane")

# Result subtrees that hold user or page data: their keys are not ours.
OPAQUE_KEYS = {
    "value", "metadata", "metadata_sources", "payload", "headers", "request_headers",
    "response_headers", "cookies", "storage", "entries", "plan",
    "configs", "config", "recent", "removed", "pinned",
}

# Old methods and the canonical method each must reach.
CANONICAL_METHOD_NAMES = (
    "list", "current", "focus", "split", "create", "close", "move", "reorder",
    "drag_to_split", "refresh", "health", "action", "send_text", "send_key",
    "read_text", "read_selection", "input_state", "clear_history", "trigger_flash",
    "cancel_flash", "set_metadata", "get_metadata", "clear_metadata",
    "set_custom_color", "get_titlebar_state", "set_titlebar_visibility",
    "set_titlebar_collapsed",
)


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _ordinal(ref: Any, prefix: str) -> int:
    m = re.fullmatch(rf"{prefix}:(\d+)", str(ref or ""))
    _must(m is not None, f"expected a `{prefix}:N` ref, got {ref!r}")
    return int(m.group(1))  # type: ignore[union-attr]


def _same_ref(new_ref: Any, new_prefix: str, old_ref: Any, old_prefix: str, what: str) -> None:
    """New ref uses the canonical prefix, old ref the old prefix, same ordinal."""
    _must(
        _ordinal(new_ref, new_prefix) == _ordinal(old_ref, old_prefix),
        f"{what}: {new_ref!r} and {old_ref!r} should share one ordinal",
    )


def _same(a: Any, b: Any, msg: str) -> None:
    """Equality that cannot pass vacuously: both sides must be present (not None)."""
    _must(a is not None and b is not None, f"{msg}: a side is missing (new={a!r}, old={b!r})")
    _must(a == b, f"{msg}: {a!r} != {b!r}")


def _error_of(c: cmux, method: str, params: Optional[Dict[str, Any]] = None) -> str:
    """The error text of a call that must fail; the call succeeding is itself a failure."""
    try:
        c._call(method, params or {})
    except cmuxError as exc:
        return str(exc)
    raise cmuxError(f"{method} was expected to fail but succeeded")


def _rows(payload: Dict[str, Any], *keys: str) -> List[Dict[str, Any]]:
    for key in keys:
        if isinstance(payload.get(key), list):
            return list(payload[key])
    raise cmuxError(f"none of {keys} present in payload keys {sorted(payload)}")


def _ids(rows: Sequence[Dict[str, Any]]) -> List[str]:
    return sorted(str(r.get("id")) for r in rows)


def _call(c: cmux, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    return dict(c._call(method, params or {}) or {})


def _wait_for(pred, timeout: float = 6.0, step: float = 0.15) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(step)
    return pred()


def _walk(value: Any) -> Iterator[Dict[str, Any]]:
    """Every dict in a JSON-shaped value."""
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk(child)


def _walk_keys(value: Any, path: str = "") -> Iterator[Tuple[str, str]]:
    """(path, key) for every key, skipping opaque user-data subtrees."""
    if isinstance(value, dict):
        for key, child in value.items():
            yield (path, key)
            if key not in OPAQUE_KEYS:
                yield from _walk_keys(child, f"{path}.{key}")
    elif isinstance(value, list):
        for idx, child in enumerate(value):
            yield from _walk_keys(child, f"{path}[{idx}]")


def _is_legacy_key(key: str) -> bool:
    """`surface_*` / `pane_*` spellings (and their camelCase and array forms) are never emitted."""
    low = key.lower()
    if "surface" in low:
        return True
    if low in ("panes", "panerefs", "paneids"):
        return True
    return re.search(r"(^|_)pane(_|$)", low) is not None


def _assert_wire_clean(payload: Any, what: str) -> None:
    bad = [f"{path}.{key}" for path, key in _walk_keys(payload) if _is_legacy_key(key)]
    _must(not bad, f"{what}: results must not emit surface_*/pane_* keys, found {bad[:6]}")


def _check_dual_panel(block: Dict[str, Any], what: str, prefix: str = "") -> None:
    """`<prefix>panel_id` == `<prefix>tab_id`; `panel_ref` says panel:N, `tab_ref` says tab:N."""
    _same(block.get(f"{prefix}panel_id"), block.get(f"{prefix}tab_id"), f"{what}: {prefix}panel_id/{prefix}tab_id")
    if f"{prefix}panel_ref" in block or f"{prefix}tab_ref" in block:
        _same_ref(block.get(f"{prefix}panel_ref"), "panel", block.get(f"{prefix}tab_ref"), "tab",
                  f"{what}: {prefix}panel_ref/{prefix}tab_ref")


def _check_area_keys(block: Dict[str, Any], what: str) -> None:
    _must(bool(block.get("area_id")), f"{what}: area_id missing in {sorted(block)}")
    _ordinal(block.get("area_ref"), "area")


def _cli_env(extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    env = dict(os.environ)
    for key in ID_ENV_KEYS:
        env.pop(key, None)
    for key in ("C11_SOCKET", "CMUX_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH"):
        env[key] = SOCKET_PATH
    env.update(extra or {})
    if "C11_WORKSPACE_ID" in env:
        env["CMUX_WORKSPACE_ID"] = env["C11_WORKSPACE_ID"]
    return env


def _cli(cli: str, args: Sequence[str], env: Optional[Dict[str, str]] = None, check: bool = True) -> subprocess.CompletedProcess:
    cmd = [cli, "--socket", SOCKET_PATH, *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env or _cli_env(), timeout=60)
    if check and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc


def _cli_json(cli: str, args: Sequence[str], env: Optional[Dict[str, str]] = None, id_format: str = "both") -> Dict[str, Any]:
    proc = _cli(cli, ["--json", "--id-format", id_format, *args], env=env)
    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise cmuxError(f"invalid JSON from `{' '.join(args)}`: {proc.stdout!r} ({exc})")


def _cli_text(cli: str, args: Sequence[str], env: Optional[Dict[str, str]] = None) -> str:
    proc = _cli(cli, ["--id-format", "refs", *args], env=env)
    return proc.stdout


def _panels(c: cmux, ws: str) -> List[Dict[str, Any]]:
    return _rows(_call(c, "panel.list", {"workspace_id": ws}), "panels")


def _areas(c: cmux, ws: str) -> List[Dict[str, Any]]:
    return _rows(_call(c, "area.list", {"workspace_id": ws}), "areas")


def _focused_area_id(c: cmux, ws: str) -> str:
    return str(_call(c, "panel.current", {"workspace_id": ws}).get("area_id") or "")


def _focused_panel_id(c: cmux, ws: str) -> str:
    return str(_call(c, "panel.current", {"workspace_id": ws}).get("panel_id") or "")


def _panel_row(c: cmux, ws: str, panel_id: str) -> Dict[str, Any]:
    for row in _panels(c, ws):
        if row.get("id") == panel_id:
            return row
    raise cmuxError(f"panel {panel_id} is not in workspace {ws}")


def _area_of(c: cmux, ws: str, panel_id: str) -> str:
    return str(_panel_row(c, ws, panel_id).get("area_id") or "")


def _index_of(c: cmux, ws: str, panel_id: str) -> int:
    row = _panel_row(c, ws, panel_id)
    value = row.get("index_in_area")
    _must(isinstance(value, int), f"panel {panel_id} has no index_in_area: {row}")
    return int(value)


def _metadata(c: cmux, ws: str, panel_id: str) -> Dict[str, Any]:
    res = _call(c, "panel.get_metadata", {"workspace_id": ws, "panel_id": panel_id})
    return dict(res.get("metadata") or {})


def _set_title_metadata(c: cmux, ws: str, panel_id: str, token: str) -> None:
    _call(c, "panel.set_metadata", {
        "workspace_id": ws, "panel_id": panel_id, "mode": "merge", "source": "explicit",
        "metadata": {"title": token},
    })


def _spare_panel(c: cmux, ws: str, area_id: str) -> str:
    created = _call(c, "panel.create", {"workspace_id": ws, "area_id": area_id, "focus": False})
    panel_id = str(created.get("panel_id") or "")
    _must(bool(panel_id), f"panel.create returned no panel_id: {created}")
    time.sleep(0.2)
    return panel_id


def _screen_text(c: cmux, ws: str, panel_id: str) -> str:
    return str(_call(c, "panel.read_text", {"workspace_id": ws, "panel_id": panel_id}).get("text") or "")


def _last_screen_line(c: cmux, ws: str, panel_id: str) -> str:
    lines = [ln.rstrip() for ln in _screen_text(c, ws, panel_id).splitlines() if ln.strip()]
    return lines[-1] if lines else ""


class Fixture:
    """A scratch workspace: area A holds panels `p1`,`p2`; area B (a split) holds `p3`."""

    def __init__(self, c: cmux) -> None:
        self.c = c
        self.ws = str(_call(c, "workspace.create").get("workspace_id") or "")
        _must(bool(self.ws), "workspace.create returned no workspace_id")
        # Agents cannot select workspaces (workspace_switch_blocked); the
        # scratch workspace stays in the background, which every call here supports.
        time.sleep(0.3)
        self.p1 = _focused_panel_id(c, self.ws)
        _must(bool(self.p1), "fresh workspace has no focused panel")
        self.p3 = str(_call(c, "panel.split", {"workspace_id": self.ws, "panel_id": self.p1, "direction": "right"}).get("panel_id") or "")
        _must(bool(self.p3), "panel.split returned no panel_id")
        time.sleep(0.3)
        areas = _areas(c, self.ws)
        _must(len(areas) == 2, f"expected 2 areas after split, got {areas}")
        self.area_a = next(a["id"] for a in areas if self.p1 in (a.get("panel_ids") or []))
        self.area_b = next(a["id"] for a in areas if self.p3 in (a.get("panel_ids") or []))
        self.p2 = _spare_panel(c, self.ws, self.area_a)

    def panel_ref(self, prefix: str = "panel") -> str:
        ordinal = _ordinal(_panel_row(self.c, self.ws, self.p2).get("ref"), "panel")
        return f"{prefix}:{ordinal}"

    def area_ref(self, area_id: str, prefix: str = "area") -> str:
        row = next(r for r in _areas(self.c, self.ws) if r["id"] == area_id)
        return f"{prefix}:{_ordinal(row.get('ref'), 'area')}"

    def close(self) -> None:
        try:
            _call(self.c, "workspace.close", {"workspace_id": self.ws})
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Capabilities
# ---------------------------------------------------------------------------

def test_capabilities_advertise_panel_vocabulary(c: cmux) -> None:
    caps = _call(c, "system.capabilities")
    methods = set(caps.get("methods") or [])
    _must(bool(methods), f"system.capabilities returned no methods: {sorted(caps)}")

    for name in CANONICAL_METHOD_NAMES:
        # read_selection / input_state are feature-gated; the rest are always listed.
        if name in ("read_selection", "input_state"):
            continue
        _must(f"panel.{name}" in methods, f"capabilities should list panel.{name}")
    # Methods that were callable but never advertised before this vocabulary change.
    for name in ("panel.set_custom_color", "panel.get_titlebar_state", "panel.set_titlebar_visibility",
                 "panel.set_titlebar_collapsed", "area.confirm"):
        _must(name in methods, f"capabilities should now advertise {name}")
    for name in ("area.list", "area.panels", "notification.create_for_panel"):
        _must(name in methods, f"capabilities should list {name}")
    _must("browser.panel.list" in methods, "capabilities should list browser.panel.list")

    # `tab.list` stays so a v0.67 CLI keeps probing its tab tier; no other old spelling is listed.
    _must("tab.list" in methods, "capabilities must keep `tab.list` for older CLIs")
    stale = sorted(
        m for m in methods
        if m != "tab.list" and (
            m.startswith(("tab.", "surface.", "pane.", "browser.tab."))
            or m in ("area.tabs", "notification.create_for_tab", "notification.create_for_surface")
            or re.match(r"debug\.(tab_|empty_panel)", m)
            or m == "debug.command_palette.rename_tab.open"
        )
    )
    _must(not stale, f"capabilities must list canonical names only (plus tab.list), found {stale}")

    ids = {str(item.get("id")) for item in (caps.get("features") or [])}
    _must("vocabulary.workspace_area_panel" in ids, f"feature vocabulary.workspace_area_panel missing: {sorted(ids)}")
    _must("send.explicit_panel" in ids, f"feature send.explicit_panel missing: {sorted(ids)}")
    old = sorted(i for i in ids if i in ("vocabulary.workspace_area_tab", "send.explicit_tab"))
    _must(not old, f"the old feature ids are gone, found {old}")
    print("PASS: capabilities list panel.* + tab.list only, the 5 newly advertised methods, and the panel feature ids")


# ---------------------------------------------------------------------------
# Socket methods and params
# ---------------------------------------------------------------------------

def test_read_methods_resolve_to_same_handlers(c: cmux, f: Fixture) -> None:
    ws = f.ws
    # Every spelling of the panel methods answers identically and with panel-shaped results.
    baseline_ids: Optional[List[str]] = None
    for family in PANEL_FAMILIES:
        res = _call(c, f"{family}.list", {"workspace_id": ws})
        rows = _rows(res, "panels")
        _must(len(rows) == 3, f"{family}.list should list 3 panels: {_ids(rows)}")
        if baseline_ids is None:
            baseline_ids = _ids(rows)
        _must(_ids(rows) == baseline_ids, f"{family}.list disagrees: {_ids(rows)} != {baseline_ids}")
        _must(_ids(_rows(res, "tabs")) == baseline_ids, f"{family}.list `tabs` array should mirror `panels`")
        _assert_wire_clean(res, f"{family}.list")

        cur = _call(c, f"{family}.current", {"workspace_id": ws})
        _same(cur.get("panel_id"), cur.get("tab_id"), f"{family}.current panel_id/tab_id")
        _assert_wire_clean(cur, f"{family}.current")

        health = _call(c, f"{family}.health", {"workspace_id": ws})
        _must(_ids(_rows(health, "panels")) == baseline_ids, f"{family}.health panels differ: {health}")
        _assert_wire_clean(health, f"{family}.health")

        md = _call(c, f"{family}.get_metadata", {"workspace_id": ws, f"{family}_id": f.p1})
        _must(isinstance(md.get("metadata"), dict), f"{family}.get_metadata must return a metadata object: {md}")
        _same_md = _metadata(c, ws, f.p1)
        _same(md.get("metadata"), _same_md, f"{family}.get_metadata differs from panel.get_metadata")

        tb = _call(c, f"{family}.get_titlebar_state", {"workspace_id": ws, f"{family}_id": f.p1})
        _must(len(tb) > 0, f"{family}.get_titlebar_state returned nothing")
        _assert_wire_clean(tb, f"{family}.get_titlebar_state")

        rt = _call(c, f"{family}.read_text", {"workspace_id": ws, f"{family}_id": f.p1})
        _must("text" in rt, f"{family}.read_text missing text: {sorted(rt)}")

    # Areas: area.* and pane.*; the panel listing is area.panels, area.tabs or pane.surfaces.
    a_ids = _ids(_rows(_call(c, "area.list", {"workspace_id": ws}), "areas"))
    pane_res = _call(c, "pane.list", {"workspace_id": ws})
    _must(_ids(_rows(pane_res, "areas")) == a_ids and len(a_ids) == 2, f"pane.list vs area.list: {pane_res}")
    _assert_wire_clean(pane_res, "pane.list")
    _must("panes" not in _call(c, "area.list", {"workspace_id": ws}), "area.list must emit `areas` only, not `panes`")

    for method, key in (("area.panels", "area_id"), ("area.tabs", "area_id"), ("pane.surfaces", "pane_id")):
        res = _call(c, method, {"workspace_id": ws, key: f.area_a})
        _must(_ids(_rows(res, "panels")) == sorted([f.p1, f.p2]), f"{method} should list the area's two panels: {res}")
        _must(_ids(_rows(res, "tabs")) == sorted([f.p1, f.p2]), f"{method} `tabs` array should mirror `panels`: {res}")
        _same(res.get("area_id"), f.area_a, f"{method} area_id")
        _assert_wire_clean(res, method)

    new_md = _call(c, "area.get_metadata", {"workspace_id": ws, "area_id": f.area_a})
    old_md = _call(c, "pane.get_metadata", {"workspace_id": ws, "pane_id": f.area_a})
    _must(isinstance(new_md.get("metadata"), dict) and isinstance(old_md.get("metadata"), dict),
          f"area get_metadata must return a metadata object: {new_md} {old_md}")
    _same(new_md.get("metadata"), old_md.get("metadata"), "area/pane get_metadata differ")
    print("PASS: read methods (panel.* == tab.* == surface.*, area.* == pane.*, area.panels == area.tabs == pane.surfaces)")


def test_param_spellings_address_the_same_panel(c: cmux, f: Fixture) -> None:
    ws = f.ws
    token = f"alias-{uuid.uuid4().hex[:8]}"
    _set_title_metadata(c, ws, f.p2, token)

    # Every id key resolves the panel.
    for key in ("panel_id", "tab_id", "surface_id"):
        res = _call(c, "panel.get_metadata", {"workspace_id": ws, key: f.p2})
        _same((res.get("metadata") or {}).get("title"), token, f"param {key} should address panel {f.p2}")

    # Every ref key and every ref prefix (any case) resolves the same panel.
    ordinal = _ordinal(_panel_row(c, ws, f.p2).get("ref"), "panel")
    ref_values = [f"{p}:{ordinal}" for p in ("panel", "tab", "surface", "PANEL", "TAB", "Tab", "SURFACE", "Surface")]
    for key in ("panel_ref", "tab_ref", "surface_ref", "panel_id", "tab_id", "surface_id"):
        for ref in ref_values:
            res = _call(c, "panel.get_metadata", {"workspace_id": ws, key: ref})
            _same((res.get("metadata") or {}).get("title"), token, f"{key}={ref} should address panel {f.p2}")
    # The same through the old method names.
    for method in ("tab.get_metadata", "surface.get_metadata"):
        for ref in (f"panel:{ordinal}", f"TAB:{ordinal}", f"surface:{ordinal}"):
            res = _call(c, method, {"workspace_id": ws, "panel_id": ref})
            _same((res.get("metadata") or {}).get("title"), token, f"{method} with {ref}")

    # Areas: area_id / pane_id / area_ref / pane_ref with area:N, pane:N, PANE:N.
    for key in ("area_id", "pane_id"):
        res = _call(c, "area.panels", {"workspace_id": ws, key: f.area_a})
        _must(f.p2 in _ids(_rows(res, "panels")), f"param {key} should address area {f.area_a}: {res}")
    a_ordinal = _ordinal(next(r for r in _areas(c, ws) if r["id"] == f.area_a).get("ref"), "area")
    for key in ("area_ref", "pane_ref", "area_id", "pane_id"):
        for ref in (f"area:{a_ordinal}", f"pane:{a_ordinal}", f"AREA:{a_ordinal}", f"PANE:{a_ordinal}"):
            res = _call(c, "area.panels", {"workspace_id": ws, key: ref})
            _must(f.p2 in _ids(_rows(res, "panels")), f"{key}={ref} should address area {f.area_a}: {res}")
    print("PASS: panel_id/tab_id/surface_id (+_ref) and area_id/pane_id (+_ref), with panel:N/tab:N/surface:N/TAB:N/pane:N refs, address the same objects")


def test_write_methods_cross_over(c: cmux, f: Fixture) -> None:
    ws = f.ws
    # Metadata written through one spelling is readable through every other.
    tokens: Dict[str, str] = {}
    for family in PANEL_FAMILIES:
        tokens[family] = f"{family}-{uuid.uuid4().hex[:6]}"
        _call(c, f"{family}.set_metadata", {
            "workspace_id": ws, f"{family}_id": f.p3, "mode": "merge", "source": "explicit",
            "metadata": {"title": tokens[family]},
        })
        for reader in PANEL_FAMILIES:
            res = _call(c, f"{reader}.get_metadata", {"workspace_id": ws, f"{reader}_id": f.p3})
            _same((res.get("metadata") or {}).get("title"), tokens[family], f"{family}.set_metadata not visible via {reader}.get_metadata")

    for set_family, get_family in (("pane", "area"), ("area", "pane")):
        role = f"{set_family}-{uuid.uuid4().hex[:6]}"
        _call(c, f"{set_family}.set_metadata", {
            "workspace_id": ws, f"{set_family}_id": f.area_b, "mode": "merge", "source": "explicit",
            "metadata": {"role": role},
        })
        res = _call(c, f"{get_family}.get_metadata", {"workspace_id": ws, f"{get_family}_id": f.area_b})
        _same((res.get("metadata") or {}).get("role"), role, f"{set_family}.set_metadata not visible via {get_family}.get_metadata")
    _call(c, "area.clear_metadata", {"workspace_id": ws, "area_id": f.area_b, "keys": ["role"], "source": "explicit"})
    res = _call(c, "pane.get_metadata", {"workspace_id": ws, "pane_id": f.area_b})
    _must("role" not in (res.get("metadata") or {}), "area.clear_metadata not visible via pane.get_metadata")

    # Text sent through any spelling lands in the same panel.
    for family in PANEL_FAMILIES:
        marker = f"vocab_{uuid.uuid4().hex[:8]}"
        _call(c, f"{family}.send_text", {"workspace_id": ws, f"{family}_id": f.p3, "text": f"echo {marker}\n"})
        _must(_wait_for(lambda m=marker: m in _screen_text(c, ws, f.p3)), f"{family}.send_text never reached panel {f.p3}")

    # Focus through every method and key spelling.
    for family in PANEL_FAMILIES:
        _call(c, f"{family}.focus", {"workspace_id": ws, f"{family}_id": f.p2})
        _same(_focused_panel_id(c, ws), f.p2, f"{family}.focus did not focus the panel")
        _call(c, f"{family}.focus", {"workspace_id": ws, f"{family}_id": f.p1})
        _same(_focused_panel_id(c, ws), f.p1, f"{family}.focus did not refocus p1")
    _call(c, "panel.focus", {"workspace_id": ws, "surface_id": f.p2})
    _same(_focused_panel_id(c, ws), f.p2, "panel.focus with surface_id did not focus the panel")
    _call(c, "pane.focus", {"workspace_id": ws, "pane_id": f.area_b})
    _same(_focused_area_id(c, ws), f.area_b, "pane.focus did not focus the area")
    _same(_focused_panel_id(c, ws), f.p3, "pane.focus should land on the area's only panel")
    _call(c, "area.focus", {"workspace_id": ws, "area_id": f.area_a})
    _same(_focused_area_id(c, ws), f.area_a, "area.focus did not focus the area")
    _call(c, "pane.focus", {"workspace_id": ws, "pane_id": f.area_b})
    _call(c, "area.focus", {"workspace_id": ws, "pane_id": f.area_a})
    _same(_focused_area_id(c, ws), f.area_a, "area.focus with the pane_id key did not focus the area")

    # Create and close through every spelling; each result carries both id keys.
    before_ids = {r["id"] for r in _panels(c, ws)}
    created = []
    for family in PANEL_FAMILIES:
        res = _call(c, f"{family}.create", {"workspace_id": ws, "area_id": f.area_a, "focus": False})
        _check_dual_panel(res, f"{family}.create")
        _assert_wire_clean(res, f"{family}.create")
        created.append((family, str(res["panel_id"])))
    via_pane_key = _call(c, "panel.create", {"workspace_id": ws, "pane_id": f.area_a, "focus": False})
    _same(via_pane_key.get("area_id"), f.area_a, "panel.create with pane_id should land in the area")
    created.append(("area-key", str(via_pane_key["panel_id"])))
    _must(len({pid for _, pid in created}) == 4, f"each create should make a distinct panel: {created}")
    _must({r["id"] for r in _panels(c, ws)} == before_ids | {pid for _, pid in created},
          "panel/tab/surface.create should each add one panel")
    for family, panel_id in created[:3]:
        _call(c, f"{family}.close", {"workspace_id": ws, f"{family}_id": panel_id})
    _call(c, "panel.close", {"workspace_id": ws, "panel_id": created[3][1]})
    time.sleep(0.2)
    _must({r["id"] for r in _panels(c, ws)} == before_ids, "close through each spelling should remove the created panels")
    print("PASS: write methods cross over (panel.* / tab.* / surface.* and area.* / pane.* share state)")


def test_notification_create_aliases(c: cmux, f: Fixture) -> None:
    ws = f.ws
    _call(c, "panel.focus", {"workspace_id": ws, "panel_id": f.p1})  # notify a panel that is not focused
    for method, key in (("notification.create_for_panel", "panel_id"), ("notification.create_for_tab", "tab_id"),
                        ("notification.create_for_surface", "surface_id"),
                        ("notification.create_for_panel", "surface_id"), ("notification.create_for_tab", "panel_id")):
        # A panel holds one notification at a time, so check each spelling on its own.
        title = f"vocab {method} {key}"
        _call(c, method, {key: f.p3, "title": title, "subtitle": "", "body": "alias check"})
        items = list(_call(c, "notification.list").get("notifications") or [])
        mine = [n for n in items if n.get("title") == title]
        _must(len(mine) == 1, f"{method} ({key}) should create a notification, got {mine}")
        _same(mine[0].get("panel_id"), f.p3, f"notification panel_id for {method} ({key})")
        _same(mine[0].get("tab_id"), f.p3, f"notification tab_id for {method} ({key})")
        _assert_wire_clean(mine[0], f"notification row for {method}")
        try:
            _call(c, "notification.clear")
        except Exception:
            pass
    try:
        _call(c, "notification.clear")
    except Exception:
        pass
    print("PASS: notification.create_for_panel == create_for_tab == create_for_surface; rows carry panel_id + tab_id")


def test_panel_action_values(c: cmux, f: Fixture) -> None:
    ws = f.ws
    # rename and pin through every method spelling.
    for family in PANEL_FAMILIES:
        title = f"{family}-{uuid.uuid4().hex[:6]}"
        res = _call(c, f"{family}.action", {"workspace_id": ws, f"{family}_id": f.p2, "action": "rename", "title": title})
        _check_dual_panel(res, f"{family}.action result")
        _assert_wire_clean(res, f"{family}.action result")
        _same(_panel_row(c, ws, f.p2).get("title"), title, f"{family}.action rename should retitle the panel")
        pinned = _call(c, f"{family}.action", {"workspace_id": ws, f"{family}_id": f.p2, "action": "pin"})
        _must(pinned.get("pinned") is True, f"{family}.action pin: {pinned}")
        unpinned = _call(c, f"{family}.action", {"workspace_id": ws, f"{family}_id": f.p2, "action": "unpin"})
        _must(unpinned.get("pinned") is False, f"{family}.action unpin: {unpinned}")

    # new_terminal_panel_to_right, its tab spelling and the short form each add one panel.
    for action in ("new_terminal_panel_to_right", "new_terminal_tab_to_right", "new_terminal_to_right", "new_terminal_right"):
        before = len(_panels(c, ws))
        _call(c, "panel.action", {"workspace_id": ws, "panel_id": f.p1, "action": action})
        time.sleep(0.2)
        rows = _panels(c, ws)
        _must(len(rows) == before + 1, f"panel.action {action} should add one panel")
        for row in rows:
            if row["id"] not in (f.p1, f.p2, f.p3) and row.get("area_id") == f.area_a:
                _call(c, "panel.close", {"workspace_id": ws, "panel_id": row["id"]})
        time.sleep(0.2)

    # close_other_panels, close_other_tabs, close_others: each leaves only the anchor (and pinned panels).
    for action in ("close_other_panels", "close_other_tabs", "close_others"):
        _spare_panel(c, ws, f.area_b)
        _spare_panel(c, ws, f.area_b)
        _call(c, "panel.action", {"workspace_id": ws, "panel_id": f.p3, "action": action})
        time.sleep(0.3)
        remaining = [r["id"] for r in _panels(c, ws) if r.get("area_id") == f.area_b]
        _must(remaining == [f.p3], f"panel.action {action} should close the area's other panels, left {remaining}")

    # An unknown action is still an error; the three spellings do not share one by accident.
    err = _error_of(c, "panel.action", {"workspace_id": ws, "panel_id": f.p3, "action": "no_such_action_xyz"})
    _must(err.startswith("invalid_params"), f"unknown panel action should be invalid_params: {err!r}")
    print("PASS: panel.action accepts *_panel*, *_tab* and short action values through panel.* / tab.* / surface.*")


def test_browser_panel_aliases(c: cmux, f: Fixture) -> None:
    ws = f.ws
    try:
        created = _call(c, "panel.create", {"workspace_id": ws, "area_id": f.area_b, "type": "browser",
                                            "url": "about:blank", "focus": False})
    except cmuxError as exc:
        print(f"SKIP: browser panel could not be created here ({exc})")
        return
    browser_id = str(created.get("panel_id") or "")
    _must(bool(browser_id), f"browser panel.create returned no panel_id: {created}")
    try:
        time.sleep(0.5)
        baseline: Optional[List[str]] = None
        for method, key in (("browser.panel.list", "panel_id"), ("browser.tab.list", "tab_id"),
                            ("browser.tab.list", "surface_id"), ("browser.panel.list", "surface_id")):
            res = _call(c, method, {"workspace_id": ws, key: browser_id})
            rows = _rows(res, "panels", "tabs")
            _must(browser_id in _ids(rows), f"{method} ({key}) should list the browser panel: {res}")
            if baseline is None:
                baseline = _ids(rows)
            _must(_ids(rows) == baseline, f"{method} ({key}) disagrees: {_ids(rows)} != {baseline}")
            _assert_wire_clean(res, method)

        # reload and duplicate through every action spelling; duplicates carry both id keys.
        for action in ("reload_panel", "reload_tab", "reload"):
            _call(c, "panel.action", {"workspace_id": ws, "panel_id": browser_id, "action": action})
        duplicates: List[str] = []
        for action in ("duplicate_panel", "duplicate_tab", "duplicate"):
            res = _call(c, "panel.action", {"workspace_id": ws, "panel_id": browser_id, "action": action})
            _same(res.get("created_panel_id"), res.get("created_tab_id"), f"{action} created_panel_id/created_tab_id")
            _same_ref(res.get("created_panel_ref"), "panel", res.get("created_tab_ref"), "tab", f"{action} created refs")
            _assert_wire_clean(res, f"panel.action {action}")
            duplicates.append(str(res["created_panel_id"]))
        for action in ("new_browser_panel_to_right", "new_browser_tab_to_right"):
            before = {r["id"] for r in _panels(c, ws)}
            _call(c, "panel.action", {"workspace_id": ws, "panel_id": browser_id, "action": action})
            duplicates.extend(r["id"] for r in _panels(c, ws) if r["id"] not in before)
        for panel_id in duplicates:
            try:
                _call(c, "panel.close", {"workspace_id": ws, "panel_id": panel_id})
            except cmuxError:
                pass
    finally:
        try:
            _call(c, "panel.close", {"workspace_id": ws, "panel_id": browser_id})
        except cmuxError:
            pass
        time.sleep(0.2)
    print("PASS: browser.panel.list == browser.tab.list; reload/duplicate/new_browser_* action spellings agree")


def test_debug_method_aliases(c: cmux, f: Fixture) -> None:
    # Old debug-only names stay accepted and reach the same handlers.
    new_count = _call(c, "debug.empty_area.count")
    old_count = _call(c, "debug.empty_panel.count")
    _same(new_count.get("count"), old_count.get("count"), "empty_area.count vs empty_panel.count")
    _call(c, "debug.empty_area.reset")
    _call(c, "debug.empty_panel.reset")
    # The scratch workspace stays in the background (agents cannot select it),
    # so its terminals may have no rendered surface to capture. Either way every
    # spelling must reach the same handler and give the same outcome.
    outcomes = []
    for method, key in (("debug.panel_snapshot", "panel_id"), ("debug.tab_snapshot", "tab_id"), ("debug.tab_snapshot", "surface_id")):
        try:
            snap = _call(c, method, {key: f.p3, "label": "vocab"})
        except cmuxError as exc:
            outcomes.append(("error", str(exc).split(":", 1)[0]))
            continue
        _check_dual_panel(snap, method)
        _same(snap.get("panel_id"), f.p3, f"{method} panel_id")
        _assert_wire_clean(snap, method)
        outcomes.append(("ok", ""))
    _must(len(set(outcomes)) == 1, f"debug snapshot spellings disagree: {outcomes}")
    resets = []
    for method in ("debug.panel_snapshot.reset", "debug.tab_snapshot.reset"):
        try:
            _call(c, method, {"panel_id": f.p3})
            resets.append("ok")
        except cmuxError as exc:
            resets.append(str(exc).split(":", 1)[0])
    _must(len(set(resets)) == 1, f"debug snapshot reset spellings disagree: {resets}")
    print("PASS: debug.panel_snapshot == debug.tab_snapshot; debug.empty_area == debug.empty_panel")


# ---------------------------------------------------------------------------
# Result keys
# ---------------------------------------------------------------------------

def _check_panel_row(row: Dict[str, Any], what: str) -> None:
    _check_area_keys(row, what)
    _must(isinstance(row.get("index_in_area"), int), f"{what}: index_in_area missing: {sorted(row)}")
    _must("selected_in_area" in row, f"{what}: selected_in_area missing: {sorted(row)}")
    _ordinal(row.get("ref"), "panel")


def test_results_carry_panel_and_tab_keys(c: cmux, f: Fixture) -> None:
    ws = f.ws
    res = _call(c, "panel.list", {"workspace_id": ws})
    panels, tabs = _rows(res, "panels"), _rows(res, "tabs")
    _must(_ids(panels) == _ids(tabs) and len(panels) == 3, f"panel.list panels/tabs arrays differ: {res}")
    for row in panels:
        _check_panel_row(row, "panel.list row")
    _must("surfaces" not in res and "panes" not in res, f"panel.list must not emit surfaces/panes: {sorted(res)}")
    _assert_wire_clean(res, "panel.list")

    res = _call(c, "area.list", {"workspace_id": ws})
    areas = _rows(res, "areas")
    _must(len(areas) == 2 and "panes" not in res, f"area.list should carry `areas` only: {sorted(res)}")
    for row in areas:
        _same(row.get("panel_ids"), row.get("tab_ids"), "area row panel_ids/tab_ids")
        _must(len(row["panel_ids"]) > 0, f"area row should list its panels: {row}")
        _must(len(row["panel_refs"]) == len(row["tab_refs"]) == len(row["panel_ids"]), f"area row refs mismatch: {row}")
        for new_ref, old_ref in zip(row["panel_refs"], row["tab_refs"]):
            _same_ref(new_ref, "panel", old_ref, "tab", "area row panel_refs/tab_refs")
        _same(row.get("panel_count"), row.get("tab_count"), "area row panel_count/tab_count")
        _same(row.get("panel_count"), len(row["panel_ids"]), "area row panel_count vs panel_ids")
        _same(row.get("selected_panel_id"), row.get("selected_tab_id"), "selected_panel_id/selected_tab_id")
        _same_ref(row.get("selected_panel_ref"), "panel", row.get("selected_tab_ref"), "tab", "selected refs")
        _ordinal(row.get("ref"), "area")
    _assert_wire_clean(res, "area.list")

    res = _call(c, "area.panels", {"workspace_id": ws, "area_id": f.area_a})
    _must(_ids(_rows(res, "panels")) == _ids(_rows(res, "tabs")), f"area.panels panels/tabs differ: {res}")
    _same(res.get("area_id"), f.area_a, "area.panels area_id")
    _ordinal(res.get("area_ref"), "area")

    res = _call(c, "panel.current", {"workspace_id": ws})
    _check_dual_panel(res, "panel.current")
    _check_area_keys(res, "panel.current")
    _same(res.get("panel_type"), res.get("tab_type"), "panel.current panel_type/tab_type")
    _assert_wire_clean(res, "panel.current")

    created = _call(c, "panel.create", {"workspace_id": ws, "area_id": f.area_a, "focus": False})
    _check_dual_panel(created, "panel.create")
    _check_area_keys(created, "panel.create")
    _same(created.get("area_id"), f.area_a, "panel.create area_id")
    _assert_wire_clean(created, "panel.create")
    _call(c, "panel.close", {"workspace_id": ws, "panel_id": created["panel_id"]})

    split = _call(c, "panel.split", {"workspace_id": ws, "panel_id": f.p3, "direction": "down"})
    _check_dual_panel(split, "panel.split")
    _assert_wire_clean(split, "panel.split")
    _call(c, "panel.close", {"workspace_id": ws, "panel_id": split["panel_id"]})
    time.sleep(0.2)

    ident = _call(c, "system.identify", {"caller": {"workspace_id": ws, "panel_id": f.p2}})
    for scope in ("focused", "caller"):
        block = ident.get(scope) or {}
        _check_dual_panel(block, f"identify.{scope}")
        _check_area_keys(block, f"identify.{scope}")
    _same((ident.get("caller") or {}).get("panel_id"), f.p2, "identify did not resolve the caller panel")
    _assert_wire_clean(ident, "system.identify")
    # Every spelling of the caller block is accepted on input.
    for key in ("tab_id", "surface_id"):
        ident_old = _call(c, "system.identify", {"caller": {"workspace_id": ws, key: f.p2}})
        _same((ident_old.get("caller") or {}).get("panel_id"), f.p2, f"identify caller.{key} not resolved")
    print("PASS: panel.list/area.list/current/create/split/identify carry panel_* + tab_* (and area_*), never surface_*/pane_*")


def test_tree_results(c: cmux, cli: str, f: Fixture) -> None:
    ws = f.ws
    # Socket system.tree.
    tree = _call(c, "system.tree", {"workspace_id": ws})
    _assert_wire_clean(tree, "system.tree")
    ws_nodes = [n for n in _walk(tree) if "areas" in n and n.get("id") == ws]
    _must(len(ws_nodes) == 1, f"system.tree has no node for workspace {ws}")
    _check_tree_node(ws_nodes[0], "system.tree")

    # CLI tree --json.
    payload = _cli_json(cli, ["tree", "--workspace", ws])
    _assert_wire_clean(payload, "tree --json")
    nodes = [n for n in _walk(payload) if "areas" in n and ws in (n.get("id"), n.get("ref"))]
    _must(len(nodes) == 1, f"tree --json has no node for workspace {ws}")
    _check_tree_node(nodes[0], "tree --json")
    print("PASS: system.tree and tree --json carry areas, panels + tabs, panel_count + tab_count")


def _check_tree_node(ws_node: Dict[str, Any], what: str) -> None:
    areas = ws_node.get("areas")
    _must(isinstance(areas, list) and len(areas) == 2, f"{what}: workspace node should carry two `areas`: {sorted(ws_node)}")
    _must("panes" not in ws_node, f"{what}: workspace node must not carry `panes`")
    for area in areas:
        panels, tabs = area.get("panels"), area.get("tabs")
        _must(isinstance(panels, list) and isinstance(tabs, list) and len(panels) == len(tabs) > 0,
              f"{what}: area node should carry both `panels` and `tabs`: {sorted(area)}")
        _must("surfaces" not in area, f"{what}: area node must not carry `surfaces`")
        _ordinal(area.get("ref"), "area")
        _same(area.get("panel_count"), area.get("tab_count"), f"{what}: area panel_count/tab_count")
        _same(area.get("panel_count"), len(panels), f"{what}: area panel_count vs panels")
        for panel, tab in zip(panels, tabs):
            _same(panel.get("id"), tab.get("id"), f"{what}: panels/tabs entries should be the same panel")
            # `ref` has no legacy twin: both arrays hold the canonical `panel:N` value.
            _ordinal(panel.get("ref"), "panel")
            _same(panel.get("ref"), tab.get("ref"), f"{what}: panels/tabs entries should share one ref")
            _check_area_keys(panel, f"{what} panel")


def test_old_ref_params_and_caller_keys(c: cmux, f: Fixture) -> None:
    ws = f.ws
    # `area` is the older `pane` placement param (config.launch). Placement conflicts are
    # rejected before anything launches, so a throwaway saved config exercises the key safely.
    a_row = next(r for r in _areas(c, ws) if r["id"] == f.area_a)
    a_ordinal = _ordinal(a_row["ref"], "area")
    name = f"c11-vocab-{uuid.uuid4().hex[:8]}"
    _call(c, "config.save", {"name": name, "harness": "claude-code"})
    try:
        for label, params in (("area", {"area": a_row["ref"]}), ("pane", {"pane": f"pane:{a_ordinal}"}),
                              ("area_id", {"area_id": f.area_a}), ("pane_id", {"pane_id": f.area_a})):
            err = _error_of(c, "config.launch", {"config": name, "new_workspace": True, **params})
            _must(err.startswith("placement_conflict"),
                  f"config.launch with {label} and new_workspace should be a placement conflict: {err!r}")
    finally:
        try:
            _call(c, "config.rm", {"config": name})
        except cmuxError:
            pass

    # flag.raise takes the caller as caller_panel_id, caller_tab_id or caller_surface_id and the
    # target under any id key. The result carries the panel + tab spellings only. The
    # `flag_caller_*` metadata the handler stores keeps the tab spelling older readers use.
    for caller_key in ("caller_panel_id", "caller_tab_id", "caller_surface_id"):
        for panel_key in ("panel_id", "tab_id", "surface_id"):
            reason = f"vocab {caller_key} {panel_key}"
            raised = _call(c, "flag.raise", {"workspace_id": ws, panel_key: f.p2, "reason": reason, caller_key: f.p1})
            _same(raised.get("flag"), reason, "flag.raise result flag")
            _same(raised.get("caller_panel_id"), f.p1, f"flag.raise result caller_panel_id ({caller_key})")
            _same(raised.get("caller_tab_id"), f.p1, f"flag.raise result caller_tab_id ({caller_key})")
            _assert_wire_clean(raised, "flag.raise result")
            md = _metadata(c, ws, f.p2)
            _same(md.get("flag_caller_tab_id"), f.p1, f"flag_caller_tab_id after raise ({caller_key}, {panel_key})")
            _call(c, "flag.lower", {"workspace_id": ws, panel_key: f.p2})
            md = _metadata(c, ws, f.p2)
            for key in ("flag", "flag_caller_panel_id", "flag_caller_tab_id", "flag_caller_surface_id"):
                _must(key not in md, f"flag.lower left {key} behind ({caller_key}, {panel_key}): {md}")
    print("PASS: area->pane placement keys, caller_panel_id/caller_tab_id/caller_surface_id, flag_caller_* clearing")


def test_old_panel_layout_methods(c: cmux) -> None:
    f = Fixture(c)
    try:
        ws = f.ws
        # split through every method spelling
        for family in PANEL_FAMILIES:
            before = len(_areas(c, ws))
            split = _call(c, f"{family}.split", {"workspace_id": ws, f"{family}_id": f.p1, "direction": "down"})
            _check_dual_panel(split, f"{family}.split")
            time.sleep(0.3)
            _must(len(_areas(c, ws)) == before + 1, f"{family}.split should add an area")
            _call(c, f"{family}.close", {"workspace_id": ws, f"{family}_id": split["panel_id"]})
            time.sleep(0.3)
            _must(len(_areas(c, ws)) == before, "closing the split's only panel should remove its area")

        # reorder with before/after anchors in every spelling.
        steps: List[Tuple[str, Dict[str, Any], int]] = [
            ("panel.reorder", {"panel_id": f.p2, "before_panel_id": f.p1}, 0),
            ("tab.reorder", {"tab_id": f.p2, "after_tab_id": f.p1}, 1),
            ("surface.reorder", {"surface_id": f.p2, "before_surface_id": f.p1}, 0),
            ("panel.reorder", {"panel_id": f.p2, "after_panel_id": f.p1}, 1),
            ("tab.reorder", {"surface_id": f.p2, "before_tab_id": f.p1}, 0),
            ("surface.reorder", {"tab_id": f.p2, "after_surface_id": f.p1}, 1),
            ("panel.reorder", {"tab_id": f.p2, "before_surface_id": f.p1}, 0),
            ("panel.reorder", {"panel_ref": f.panel_ref("TAB"), "after_panel_id": f.p1}, 1),
        ]
        for method, params, want in steps:
            _call(c, method, {"workspace_id": ws, **params})
            _same(_index_of(c, ws, f.p2), want, f"{method} {sorted(params)} should place the panel at index {want}")

        # move across areas, with before/after anchors and area/pane keys.
        mover = _spare_panel(c, ws, f.area_b)
        _call(c, "surface.move", {"workspace_id": ws, "surface_id": mover, "pane_id": f.area_a,
                                  "before_surface_id": f.p1, "focus": False})
        _same(_area_of(c, ws, mover), f.area_a, "surface.move should move the panel into the area")
        _same(_index_of(c, ws, mover), 0, "surface.move before_surface_id should place the panel first")
        _call(c, "panel.move", {"workspace_id": ws, "panel_id": mover, "area_id": f.area_b, "focus": False})
        _same(_area_of(c, ws, mover), f.area_b, "panel.move should move the panel back")
        _call(c, "tab.move", {"workspace_id": ws, "tab_id": mover, "area_id": f.area_a,
                              "after_tab_id": f.p1, "focus": False})
        _same(_index_of(c, ws, mover), _index_of(c, ws, f.p1) + 1, "tab.move after_tab_id should place the panel after the anchor")
        _call(c, "panel.move", {"workspace_id": ws, "panel_id": mover, "area_id": f.area_b,
                                "before_panel_id": f.p3, "focus": False})
        _same(_area_of(c, ws, mover), f.area_b, "panel.move with before_panel_id should move the panel")
        _call(c, "surface.move", {"workspace_id": ws, "surface_id": mover, "pane_id": f.area_a, "focus": False})
        _same(_area_of(c, ws, mover), f.area_a, "surface.move should move the panel again")

        # drag_to_split needs a sibling in the source area.
        for family, direction in (("panel", "right"), ("tab", "down"), ("surface", "right")):
            sibling = _spare_panel(c, ws, f.area_b)
            before = len(_areas(c, ws))
            res = _call(c, f"{family}.drag_to_split", {"workspace_id": ws, f"{family}_id": sibling, "direction": direction})
            _assert_wire_clean(res, f"{family}.drag_to_split")
            time.sleep(0.3)
            _must(len(_areas(c, ws)) == before + 1, f"{family}.drag_to_split should split the panel off into a new area")
            _must(_area_of(c, ws, sibling) not in (f.area_a, f.area_b), f"{family}.drag_to_split should leave the panel in a new area")
        print("PASS: split / reorder / move / drag_to_split resolve to the same handlers in every spelling")
    finally:
        f.close()


def test_old_panel_presentation_methods(c: cmux, f: Fixture) -> None:
    ws = f.ws
    for family in PANEL_FAMILIES:
        res = _call(c, f"{family}.trigger_flash", {"workspace_id": ws, f"{family}_id": f.p1})
        _check_dual_panel(res, f"{family}.trigger_flash")
        _assert_wire_clean(res, f"{family}.trigger_flash")
        res = _call(c, f"{family}.cancel_flash", {"workspace_id": ws, f"{family}_id": f.p1})
        _same(res.get("panel_id"), f.p1, f"{family}.cancel_flash panel_id")

    for family, hex_ in (("panel", "#336699"), ("tab", "#996633"), ("surface", "#669933")):
        res = _call(c, f"{family}.set_custom_color", {"workspace_id": ws, f"{family}_id": f.p2, "hex": hex_})
        _same(res.get("custom_color"), hex_, f"{family}.set_custom_color custom_color")
        _check_dual_panel(res, f"{family}.set_custom_color")
    cleared = _call(c, "surface.set_custom_color", {"workspace_id": ws, "surface_id": f.p2, "clear": True})
    _must(cleared.get("cleared") is True and cleared.get("custom_color") is None, f"clear through the old method: {cleared}")

    # Title bar: visibility is workspace-wide, collapsed is per panel.
    try:
        _call(c, "surface.set_titlebar_visibility", {"workspace_id": ws, "surface_id": f.p1, "visible": False})
        _must(_call(c, "panel.get_titlebar_state", {"workspace_id": ws, "panel_id": f.p1}).get("visible") is False,
              "surface.set_titlebar_visibility should hide the title bar")
        _call(c, "tab.set_titlebar_visibility", {"workspace_id": ws, "tab_id": f.p1, "visible": True})
        _must(_call(c, "surface.get_titlebar_state", {"workspace_id": ws, "surface_id": f.p1}).get("visible") is True,
              "tab.set_titlebar_visibility should show the title bar")
    finally:
        _call(c, "panel.set_titlebar_visibility", {"workspace_id": ws, "panel_id": f.p1, "visible": True})
    _call(c, "surface.set_titlebar_collapsed", {"workspace_id": ws, "surface_id": f.p3, "collapsed": False})
    _must(_call(c, "panel.get_titlebar_state", {"workspace_id": ws, "panel_id": f.p3}).get("collapsed") is False,
          "surface.set_titlebar_collapsed should expand the title bar")
    _call(c, "panel.set_titlebar_collapsed", {"workspace_id": ws, "panel_id": f.p3, "collapsed": True})
    _must(_call(c, "tab.get_titlebar_state", {"workspace_id": ws, "tab_id": f.p3}).get("collapsed") is True,
          "panel.set_titlebar_collapsed should collapse the title bar")

    for family in PANEL_FAMILIES:
        marker = f"clr-{uuid.uuid4().hex[:6]}"
        _call(c, "panel.set_metadata", {"workspace_id": ws, "panel_id": f.p3, "mode": "merge", "source": "explicit",
                                        "metadata": {"vocab_clear": marker}})
        _same(_metadata(c, ws, f.p3).get("vocab_clear"), marker, "metadata should be set before clearing")
        _call(c, f"{family}.clear_metadata", {"workspace_id": ws, f"{family}_id": f.p3, "keys": ["vocab_clear"], "source": "explicit"})
        _must("vocab_clear" not in _metadata(c, ws, f.p3), f"{family}.clear_metadata did not clear the key")

    # send_key, clear_history and read_text under every spelling. `$((6*7))` makes the marker
    # appear only in the command's output, never in its echo.
    for family in PANEL_FAMILIES:
        marker = f"vk{uuid.uuid4().hex[:6]}"
        _call(c, f"{family}.send_text", {"workspace_id": ws, f"{family}_id": f.p3, "text": f"echo $((6*7)){marker}"})
        _call(c, f"{family}.send_key", {"workspace_id": ws, f"{family}_id": f.p3, "key": "enter"})
        _must(_wait_for(lambda m=marker: f"42{m}" in _screen_text(c, ws, f.p3)),
              f"{family}.send_key enter never ran the typed command")
        res = _call(c, f"{family}.clear_history", {"workspace_id": ws, f"{family}_id": f.p3})
        _check_dual_panel(res, f"{family}.clear_history")
        _assert_wire_clean(res, f"{family}.clear_history")

    # area.confirm / pane.confirm are off-main methods that open a modal; a call without a title fails
    # before any dialog, so reaching that error proves both names route to the handler.
    old_err = _error_of(c, "pane.confirm", {"workspace_id": ws, "pane_id": f.area_a})
    new_err = _error_of(c, "area.confirm", {"workspace_id": ws, "area_id": f.area_a})
    _must(old_err.startswith("invalid_params") and "title" in old_err, f"pane.confirm without a title: {old_err!r}")
    _same(new_err, old_err, "pane.confirm and area.confirm should fail the same way")
    print("PASS: flash / custom_color / titlebar / clear_metadata / send_key / clear_history / area.confirm resolve in every spelling")


def test_old_area_methods(c: cmux) -> None:
    f = Fixture(c)
    try:
        ws = f.ws

        # pane.create / area.create: the result carries area_* and panel_* + tab_*, never pane_*/surface_*.
        before = len(_areas(c, ws))
        made_all = [_call(c, "pane.create", {"workspace_id": ws, "direction": "down"}),
                    _call(c, "area.create", {"workspace_id": ws, "direction": "down"})]
        time.sleep(0.3)
        _must(len(_areas(c, ws)) == before + 2, f"pane.create / area.create should each add an area: {made_all}")
        for made in made_all:
            _check_area_keys(made, "area create")
            _check_dual_panel(made, "area create")
            _assert_wire_clean(made, "area create")
            _call(c, "panel.close", {"workspace_id": ws, "panel_id": str(made["panel_id"])})
        time.sleep(0.3)
        _must(len(_areas(c, ws)) == before, "closing the created areas' panels should remove them")

        # pane.resize / area.resize: the divider between the two side-by-side areas moves.
        grown = _call(c, "pane.resize", {"workspace_id": ws, "pane_id": f.area_a, "direction": "right", "amount": 40})
        _same(grown.get("area_id"), f.area_a, "pane.resize result area_id")
        _assert_wire_clean(grown, "pane.resize")
        _must(float(grown["new_divider_position"]) > float(grown["old_divider_position"]), f"pane.resize right should grow the area: {grown}")
        # Area A is the left area; its shared border is area B's left edge.
        shrunk = _call(c, "area.resize", {"workspace_id": ws, "area_id": f.area_b, "direction": "left", "amount": 40})
        _same(shrunk.get("area_id"), f.area_b, "area.resize result area_id")
        _must(float(shrunk["new_divider_position"]) < float(shrunk["old_divider_position"]), f"area.resize left should move the divider back: {shrunk}")

        # pane.swap / area.swap with every spelling of the area and target keys. Each swap
        # trades the two areas' selected panels, so the owner of a given panel flips every time.
        rows = {str(r["id"]): r for r in _areas(c, ws)}
        sel_a = str(rows[f.area_a].get("selected_panel_id"))
        area_ref = {r["id"]: r["ref"] for r in _areas(c, ws)}
        old_ref = {k: f"pane:{_ordinal(v, 'area')}" for k, v in area_ref.items()}
        variants = [
            ("pane.swap", {"pane_id": f.area_a, "target_pane_id": f.area_b}),
            ("area.swap", {"area_id": f.area_a, "target_area_id": f.area_b}),
            ("pane.swap", {"pane_ref": old_ref[f.area_a], "target_pane_ref": old_ref[f.area_b]}),
            ("area.swap", {"area_ref": area_ref[f.area_a], "target_area_ref": area_ref[f.area_b]}),
            ("pane.swap", {"area_id": f.area_a, "target_area_id": f.area_b}),
            ("area.swap", {"pane_id": f.area_a, "target_pane_id": f.area_b}),
        ]
        expected_area = f.area_a
        for method, params in variants:
            res = _call(c, method, {"workspace_id": ws, "focus": False, **params})
            expected_area = f.area_b if expected_area == f.area_a else f.area_a
            _same(_area_of(c, ws, sel_a), expected_area, f"{method} {sorted(params)} should move the selected panel")
            _must(bool(res.get("area_id")) and bool(res.get("target_area_id")), f"{method} result needs area_id/target_area_id: {res}")
            _check_dual_panel(res, f"{method} result", "source_")
            _check_dual_panel(res, f"{method} result", "target_")
            _assert_wire_clean(res, method)

        # pane.join / area.join: any panel key picks the panel, target_* the destination.
        joiner = _spare_panel(c, ws, f.area_b)
        _call(c, "pane.join", {"workspace_id": ws, "surface_id": joiner, "target_pane_id": f.area_a, "focus": False})
        _same(_area_of(c, ws, joiner), f.area_a, "pane.join should move the panel into the target area")
        _call(c, "area.join", {"workspace_id": ws, "tab_id": joiner, "target_area_id": f.area_b, "focus": False})
        _same(_area_of(c, ws, joiner), f.area_b, "area.join should move the panel into the target area")
        _call(c, "pane.join", {"workspace_id": ws, "panel_id": joiner, "target_area_ref": area_ref[f.area_a], "focus": False})
        _same(_area_of(c, ws, joiner), f.area_a, "pane.join with target_area_ref should move the panel")
        _call(c, "area.join", {"workspace_id": ws, "panel_id": joiner, "target_pane_ref": old_ref[f.area_b], "focus": False})
        _same(_area_of(c, ws, joiner), f.area_b, "area.join with target_pane_ref should move the panel")

        # pane.break / area.break detach a panel into a new workspace.
        for method, key in (("pane.break", "surface_id"), ("area.break", "panel_id"), ("area.break", "tab_id")):
            breaker = _spare_panel(c, ws, f.area_b)
            res = _call(c, method, {"workspace_id": ws, key: breaker, "focus": False})
            new_ws = str(res.get("workspace_id") or "")
            _must(bool(new_ws) and new_ws != ws, f"{method} should move the panel into another workspace: {res}")
            _assert_wire_clean(res, method)
            try:
                _must(breaker not in [r["id"] for r in _panels(c, ws)], f"{method} left the panel in the source workspace")
            finally:
                try:
                    _call(c, "workspace.close", {"workspace_id": new_ws})
                except Exception:
                    pass

        # pane.last / area.last: with two areas the alternate one is the other area.
        _call(c, "area.focus", {"workspace_id": ws, "area_id": f.area_a})
        res = _call(c, "pane.last", {"workspace_id": ws})
        _same(res.get("area_id"), f.area_b, "pane.last should target the other area")
        _assert_wire_clean(res, "pane.last")
        _same(_focused_area_id(c, ws), f.area_b, "pane.last should focus the other area")
        res = _call(c, "area.last", {"workspace_id": ws})
        _same(res.get("area_id"), f.area_a, "area.last should target the other area")
        _same(_focused_area_id(c, ws), f.area_a, "area.last should focus the other area")
        print("PASS: pane.create / resize / swap / join / break / last resolve to the area.* handlers; results carry area_* only")
    finally:
        f.close()


def test_workspace_apply_ref_maps(c: cmux) -> None:
    """workspace.apply returns panelRefs (panel:N) beside tabRefs (tab:N), and areaRefs; never surfaceRefs/paneRefs."""
    # The plan schema's own words (`surfaces`, `surfaceIds`) are input, not wire keys.
    plan = {
        "version": 1,
        "workspace": {"title": f"vocab-apply-{uuid.uuid4().hex[:6]}"},
        "layout": {"type": "pane", "pane": {"surfaceIds": ["a", "b"]}},
        "surfaces": [
            {"id": "a", "kind": "terminal", "title": "first"},
            {"id": "b", "kind": "terminal", "title": "second"},
        ],
    }
    res = _call(c, "workspace.apply", {"plan": plan})
    ws_ref = str(res.get("workspaceRef") or "")
    try:
        _must(bool(ws_ref), f"workspace.apply returned no workspaceRef: {res}")
        maps = {name: res.get(name) for name in ("panelRefs", "tabRefs", "areaRefs")}
        for name, value in maps.items():
            _must(isinstance(value, dict) and sorted(value) == ["a", "b"], f"workspace.apply {name} should map both plan ids: {value!r}")
        for plan_id in ("a", "b"):
            _same(_ordinal(maps["panelRefs"][plan_id], "panel"), _ordinal(maps["tabRefs"][plan_id], "tab"),
                  f"panelRefs/tabRefs ordinal for plan id {plan_id}")
            _ordinal(maps["areaRefs"][plan_id], "area")
        _must(_ordinal(maps["panelRefs"]["a"], "panel") != _ordinal(maps["panelRefs"]["b"], "panel"), "the two panels should have distinct refs")
        _same(maps["areaRefs"]["a"], maps["areaRefs"]["b"], "both plan panels live in one area")
        for legacy in ("surfaceRefs", "paneRefs"):
            _must(legacy not in res, f"workspace.apply must not emit {legacy}: {sorted(res)}")
    finally:
        if ws_ref:
            try:
                _call(c, "workspace.close", {"workspace_id": ws_ref})
            except cmuxError:
                pass
    print("PASS: workspace.apply carries panelRefs/tabRefs and areaRefs with matching ordinals and prefixes")


# ---------------------------------------------------------------------------
# CLI commands, flags, refs, output
# ---------------------------------------------------------------------------

def test_cli_help_names_panels(cli: str) -> None:
    help_text = _cli(cli, ["--help"]).stdout
    for command in ("new-panel", "close-panel", "rename-panel", "list-panels", "focus-panel",
                    "move-panel", "reorder-panel", "panel-action", "send-panel", "send-key-panel"):
        _must(re.search(rf"(?<![\w-]){re.escape(command)}(?![\w-])", help_text) is not None,
              f"`--help` should mention `{command}`")
    old = ("new-tab", "new-surface", "rename-tab", "close-tab", "close-surface", "list-tabs",
           "focus-tab", "list-area-tabs", "list-pane-surfaces", "send-tab", "send-key-tab",
           "tab-health", "surface-health", "tab-color", "surface-color", "move-tab", "move-surface",
           "reorder-tab", "reorder-surface", "drag-tab-to-split", "drag-surface-to-split",
           "refresh-tabs", "refresh-surfaces", "tab-action", "new-pane", "focus-pane", "pane-confirm")
    leaked = [name for name in old if re.search(rf"(?<![\w-]){re.escape(name)}(?![\w-])", help_text)]
    _must(not leaked, f"`--help` must not mention old command names: {leaked}")

    # Per-command usage: panel names only, and the old names reach the same usage text.
    for command, old_name in (("rename-panel", "rename-tab"), ("focus-panel", "focus-tab"),
                              ("new-panel", "new-tab"), ("close-panel", "close-surface")):
        text = _cli(cli, [command, "--help"], check=False)
        _must(text.returncode == 0, f"`{command} --help` should succeed: {text.stdout!r} {text.stderr!r}")
        usage = text.stdout
        _must("--panel" in usage or command == "new-panel", f"`{command} --help` should document --panel: {usage!r}")
        for stale in (r"--surface\b", r"--tab\b", r"--pane(?!l)", r"\btab:", r"\bsurface:", "C11_TAB_ID", "C11_SURFACE_ID"):
            _must(re.search(stale, usage) is None, f"`{command} --help` must not mention {stale!r}: {usage!r}")
        alias = _cli(cli, [old_name, "--help"], check=False)
        _must(alias.returncode == 0 and alias.stdout == usage,
              f"`{old_name} --help` should print the same usage as `{command} --help`")
    print("PASS: --help documents panel commands and none of the old command names")


def test_cli_read_command_aliases(cli: str, f: Fixture) -> None:
    ws = f.ws
    pairs: List[Tuple[List[str], List[str], Tuple[str, ...]]] = [
        (["list-areas", "--workspace", ws], ["list-panes", "--workspace", ws], ("areas",)),
        (["list-panels", "--workspace", ws], ["list-tabs", "--workspace", ws], ("panels",)),
        (["panel-health", "--workspace", ws], ["tab-health", "--workspace", ws], ("panels",)),
        (["panel-health", "--workspace", ws], ["surface-health", "--workspace", ws], ("panels",)),
        (["list-area-panels", "--workspace", ws, "--area", f.area_a],
         ["list-area-tabs", "--workspace", ws, "--area", f.area_a], ("panels",)),
        (["list-area-panels", "--workspace", ws, "--area", f.area_a],
         ["list-pane-surfaces", "--workspace", ws, "--pane", f.area_a], ("panels",)),
    ]
    for new_args, old_args, keys in pairs:
        new_out = _cli_json(cli, new_args, id_format="uuids")
        old_out = _cli_json(cli, old_args, id_format="uuids")
        new_rows, old_rows = _rows(new_out, *keys), _rows(old_out, *keys)
        _must(_ids(new_rows) == _ids(old_rows) and new_rows, f"`{new_args[0]}` vs `{old_args[0]}` disagree: {new_rows} {old_rows}")
        _assert_wire_clean(new_out, f"{new_args[0]} --json")
        _assert_wire_clean(old_out, f"{old_args[0]} --json")
    listing = _cli_json(cli, ["list-panels", "--workspace", f.ws])
    _must(_ids(_rows(listing, "panels")) == _ids(_rows(listing, "tabs")), f"list-panels --json should carry panels and tabs: {sorted(listing)}")
    for command in ("refresh-panels", "refresh-tabs", "refresh-surfaces"):
        _cli(cli, [command])

    # Ref-format output says panel:N / area:N and never the old prefixes.
    refs_out = _cli_json(cli, ["list-panels", "--workspace", ws], id_format="refs")
    for row in _rows(refs_out, "panels"):
        _ordinal(row.get("ref") or row.get("id"), "panel")
    text = _cli_text(cli, ["list-panels", "--workspace", ws])
    _must(re.search(r"\bpanel:\d+", text) is not None, f"list-panels text output should print panel:N refs: {text!r}")
    _must(re.search(r"\b(surface|pane|tab):\d+", text) is None, f"list-panels text output must not print old ref prefixes: {text!r}")
    text = _cli_text(cli, ["list-areas", "--workspace", ws])
    _must(re.search(r"\barea:\d+", text) is not None and re.search(r"\bpane:\d+", text) is None, f"list-areas text output: {text!r}")

    # identify --json: panel_* + tab_* (and area_*), no surface_*/pane_*.
    env = _cli_env({"C11_WORKSPACE_ID": ws})
    ident = _cli_json(cli, ["identify", "--workspace", ws, "--panel", f.p2], env=env)
    _assert_wire_clean(ident, "identify --json")
    for scope in ("focused", "caller"):
        block = ident.get(scope) or {}
        if block:
            _check_dual_panel(block, f"identify --json {scope}")
    print("PASS: read-only CLI commands (panel == tab == surface names) with panel:N output and no surface/pane keys")


def test_cli_action_command_aliases(c: cmux, cli: str, f: Fixture) -> None:
    ws = f.ws

    # new-panel / new-tab / new-surface and close-panel / close-tab / close-surface, with every flag spelling.
    before = len(_panels(c, ws))
    out = _cli_text(cli, ["new-panel", "--workspace", ws, "--area", f.area_a, "--no-focus"])
    _must(re.search(r"OK\s+panel:\d+", out) is not None, f"new-panel should print `OK panel:N ...`: {out!r}")
    _must(re.search(r"\b(surface|pane|tab):\d+", out) is None, f"new-panel output must not print old ref prefixes: {out!r}")
    created = [
        _cli_json(cli, ["new-tab", "--workspace", ws, "--area", f.area_a, "--no-focus"], id_format="uuids"),
        _cli_json(cli, ["new-surface", "--workspace", ws, "--pane", f.area_a, "--no-focus"], id_format="uuids"),
        _cli_json(cli, ["new-panel", "--workspace", ws, "--area", f.area_a, "--no-focus"], id_format="uuids"),
    ]
    _must(len(_panels(c, ws)) == before + 4, f"new-panel / new-tab / new-surface should each add a panel: {created}")
    ids = [str(x.get("panel_id") or x.get("tab_id")) for x in created]
    _must(all(ids), f"create results should carry panel_id: {created}")
    for x in created:
        _assert_wire_clean(x, "new-panel --json")
    extra = [r["id"] for r in _panels(c, ws) if r["id"] not in (f.p1, f.p2, f.p3) and r["id"] not in ids]
    _cli(cli, ["close-panel", "--workspace", ws, "--panel", ids[0]])
    _cli(cli, ["close-tab", "--workspace", ws, "--tab", ids[1]])
    _cli(cli, ["close-surface", "--workspace", ws, "--surface", ids[2]])
    for panel_id in extra:
        _cli(cli, ["close-panel", "--workspace", ws, "--panel", panel_id])
    time.sleep(0.2)
    _must(len(_panels(c, ws)) == before, "close-panel / close-tab / close-surface should each remove a panel")

    # rename-panel / rename-tab with every target flag.
    for command, flag in (("rename-panel", "--panel"), ("rename-tab", "--tab"), ("rename-tab", "--surface"),
                          ("rename-panel", "--tab")):
        title = f"cli-{uuid.uuid4().hex[:6]}"
        _cli(cli, [command, "--workspace", ws, flag, f.p2, title])
        _same(_panel_row(c, ws, f.p2).get("title"), title, f"{command} {flag} should retitle the panel")

    # focus-panel / focus-tab with every flag spelling.
    for command, flag in (("focus-panel", "--panel"), ("focus-tab", "--tab"), ("focus-tab", "--surface"),
                          ("focus-panel", "--surface")):
        _cli(cli, [command, "--workspace", ws, flag, f.p2])
        _same(_focused_panel_id(c, ws), f.p2, f"{command} {flag} did not focus")
        _cli(cli, ["focus-panel", "--workspace", ws, "--panel", f.p1])
        _same(_focused_panel_id(c, ws), f.p1, "focus-panel --panel did not refocus p1")
    # Ref prefixes on the command line: panel:N, tab:N, surface:N.
    for prefix in ("panel", "tab", "surface"):
        _cli(cli, ["focus-panel", "--workspace", ws, "--panel", f.panel_ref(prefix)])
        _same(_focused_panel_id(c, ws), f.p2, f"focus-panel --panel {prefix}:N did not focus the panel")
        _cli(cli, ["focus-panel", "--workspace", ws, "--panel", f.p1])

    # focus-area / focus-pane
    _cli(cli, ["focus-area", "--workspace", ws, "--area", f.area_b])
    _same(_focused_panel_id(c, ws), f.p3, "focus-area --area did not focus the area's panel")
    _cli(cli, ["focus-pane", "--workspace", ws, "--pane", f.area_a])
    _same(_focused_area_id(c, ws), f.area_a, "focus-pane --pane did not focus the area")
    _cli(cli, ["focus-area", f.area_b, "--workspace", ws])  # positional comes first
    _same(_focused_area_id(c, ws), f.area_b, "focus-area <area> (positional) did not focus the area")
    _cli(cli, ["focus-pane", f.area_a, "--workspace", ws])
    _same(_focused_area_id(c, ws), f.area_a, "focus-pane <area> (positional) did not focus the area")

    # send-panel / send-tab, send-key-panel / send-key-tab.
    for cmd, flag in (("send-panel", "--panel"), ("send-tab", "--tab"), ("send-panel", "--surface")):
        token = f"vocab_{uuid.uuid4().hex[:8]}"
        _cli(cli, [cmd, "--workspace", ws, flag, f.p3, f"echo {token}\\n"])
        _must(_wait_for(lambda t=token: t in _screen_text(c, ws, f.p3)), f"{cmd} {flag} text never reached the panel")
    _cli(cli, ["send-key-panel", "--workspace", ws, "--panel", f.p3, "enter"])
    _cli(cli, ["send-key-tab", "--workspace", ws, "--tab", f.p3, "enter"])

    # panel-color / tab-color / surface-color.
    _cli(cli, ["--json", "panel-color", "set", "#336699", "--workspace", ws, "--panel", f.p2])
    got_new = _cli_json(cli, ["panel-color", "get", "--workspace", ws, "--panel", f.p2])
    got_old = _cli_json(cli, ["tab-color", "get", "--workspace", ws, "--tab", f.p2])
    got_older = _cli_json(cli, ["surface-color", "get", "--workspace", ws, "--surface", f.p2])
    _must(got_new.get("custom_color") == got_old.get("custom_color") == got_older.get("custom_color") == "#336699",
          f"panel-color/tab-color/surface-color disagree: {got_new} {got_old} {got_older}")
    _cli(cli, ["surface-color", "clear", "--workspace", ws, "--surface", f.p2])

    # panel-action / tab-action.
    for command, flag in (("panel-action", "--panel"), ("tab-action", "--tab")):
        _cli(cli, [command, "--workspace", ws, flag, f.p2, "--action", "pin"])
        _cli(cli, [command, "--workspace", ws, flag, f.p2, "--action", "unpin"])

    # move-panel / move-tab / move-surface and reorder-*, with --before-panel/--before-tab/--before-surface.
    _cli(cli, ["move-panel", "--workspace", ws, "--panel", f.p2, "--area", f.area_b, "--focus", "false"])
    _same(_area_of(c, ws, f.p2), f.area_b, "move-panel --area did not move the panel")
    _cli(cli, ["move-tab", "--workspace", ws, "--tab", f.p2, "--pane", f.area_a, "--before-tab", f.p1, "--focus", "false"])
    _same(_area_of(c, ws, f.p2), f.area_a, "move-tab --pane did not move the panel")
    _same(_index_of(c, ws, f.p2), 0, "move-tab --before-tab did not place the panel first")
    _cli(cli, ["move-surface", "--workspace", ws, "--surface", f.p2, "--area", f.area_b, "--focus", "false"])
    _same(_area_of(c, ws, f.p2), f.area_b, "move-surface --area did not move the panel")
    _cli(cli, ["move-surface", "--workspace", ws, "--surface", f.p2, "--pane", f.area_a, "--before-surface", f.p1, "--focus", "false"])
    _same(_index_of(c, ws, f.p2), 0, "move-surface --before-surface did not place the panel first")
    _cli(cli, ["move-panel", "--workspace", ws, "--panel", f.p2, "--area", f.area_b, "--focus", "false"])
    _cli(cli, ["move-panel", "--workspace", ws, "--panel", f.p2, "--area", f.area_a, "--after-panel", f.p1, "--focus", "false"])
    _same(_index_of(c, ws, f.p2), 1, "move-panel --after-panel did not place the panel second")
    for command, target_flag, before_flag, after_flag in (
        ("reorder-panel", "--panel", "--before-panel", "--after-panel"),
        ("reorder-tab", "--tab", "--before-tab", "--after-tab"),
        ("reorder-surface", "--surface", "--before-surface", "--after-surface"),
    ):
        _cli(cli, [command, "--workspace", ws, target_flag, f.p2, before_flag, f.p1])
        _same(_index_of(c, ws, f.p2), 0, f"{command} {before_flag} did not place the panel first")
        _cli(cli, [command, "--workspace", ws, target_flag, f.p2, after_flag, f.p1])
        _same(_index_of(c, ws, f.p2), 1, f"{command} {after_flag} did not place the panel second")
    _cli(cli, ["reorder-panel", "--workspace", ws, "--panel", f.p2, "--before-tab", f.p1])
    _same(_index_of(c, ws, f.p2), 0, "reorder-panel --before-tab (an older flag on the canonical command) did not place the panel first")

    # new-area / new-pane.
    areas_before = len(_areas(c, ws))
    made_new = _cli_json(cli, ["new-area", "--workspace", ws, "--direction", "down"], id_format="uuids")
    made_old = _cli_json(cli, ["new-pane", "--workspace", ws, "--direction", "down"], id_format="uuids")
    _must(len(_areas(c, ws)) == areas_before + 2, f"new-area / new-pane should each add an area: {made_new} {made_old}")
    for made in (made_new, made_old):
        _assert_wire_clean(made, "new-area --json")
        _call(c, "panel.close", {"workspace_id": ws, "panel_id": str(made.get("panel_id") or made.get("tab_id"))})
    time.sleep(0.3)
    _must(len(_areas(c, ws)) == areas_before, "closing the new areas' panels should remove them")

    # drag-panel-to-split / drag-tab-to-split / drag-surface-to-split speak the v1
    # text protocol, which resolves panels in the selected workspace only; the
    # scratch workspace stays in the background (agents cannot select it). Each
    # spelling must reach the same command and give the same outcome.
    outcomes = []
    for command, flag in (("drag-panel-to-split", "--panel"), ("drag-tab-to-split", "--tab"),
                          ("drag-surface-to-split", "--surface")):
        proc = _cli(cli, [command, flag, f.p2, "right"], env=_cli_env({"C11_WORKSPACE_ID": ws}), check=False)
        outcomes.append((proc.returncode, (proc.stdout + proc.stderr).strip()))
        if proc.returncode == 0:
            break  # a real split happened (selected workspace); don't split again
    _must(len(set(o[0] for o in outcomes)) == 1 and all("Unknown command" not in o[1] for o in outcomes),
          f"drag-*-to-split spellings disagree: {outcomes}")

    # area-confirm / pane-confirm open a modal; only check both names are recognized.
    for cmd in ("area-confirm", "pane-confirm"):
        proc = _cli(cli, [cmd, "--help"], check=False)
        _must(proc.returncode == 0, f"`{cmd} --help` should succeed: {proc.stdout!r} {proc.stderr!r}")
    print("PASS: action CLI commands and flags (panel names == tab == surface == pane names)")


def test_flag_caller_metadata_keys(c: cmux, cli: str, f: Fixture) -> None:
    for flag in ("--panel", "--tab", "--surface"):
        env = _cli_env({"C11_PANEL_ID": f.p2, "C11_WORKSPACE_ID": f.ws})
        try:
            _cli(cli, ["raise-flag", flag, f.p2, "vocabulary alias check"], env=env)
            md = _metadata(c, f.ws, f.p2)
            _same(md.get("flag_caller_tab_id"), f.p2, f"flag_caller_tab_id after raise-flag {flag}")
            cli_md = _cli_json(cli, ["get-metadata", flag, f.p2], env=env)
            _same((cli_md.get("metadata") or {}).get("flag_caller_tab_id"), f.p2, f"get-metadata {flag} lost flag_caller_tab_id")
        finally:
            lowered = _cli(cli, ["lower-flag", flag, f.p2], env=env, check=False)
        _must(lowered.returncode == 0, f"lower-flag {flag} failed: {lowered.stdout!r} {lowered.stderr!r}")
        md = _metadata(c, f.ws, f.p2)
        for key in ("flag", "flag_caller_panel_id", "flag_caller_tab_id", "flag_caller_surface_id"):
            _must(key not in md, f"lower-flag {flag} left {key} behind: {md}")
    print("PASS: raise-flag / lower-flag accept --panel, --tab and --surface and clear every flag_caller_* key")


def _window_ref_of(c: cmux, ws: str) -> str:
    tree = _call(c, "system.tree", {"scope": "all", "all_windows": True})
    for window in tree.get("windows") or []:
        if any(str(w.get("id")) == ws for w in window.get("workspaces") or []):
            return str(window.get("ref"))
    raise cmuxError(f"no window holds workspace {ws}: {tree}")


def test_scoped_window_and_feed_refs(c: cmux, cli: str, f: Fixture) -> None:
    """Resolvers that compare refs client-side accept every prefix (panel:/tab:/surface:)."""
    window = _window_ref_of(c, f.ws)
    env = _cli_env({"C11_PANEL_ID": f.p2, "C11_WORKSPACE_ID": f.ws})
    for prefix in ("panel", "tab", "surface", "TAB"):
        ref = f.panel_ref(prefix)
        try:
            _cli(cli, ["--window", window, "raise-flag", "--workspace", f.ws, "--panel", ref, "scoped ref check"], env=env)
            _must("flag" in _metadata(c, f.ws, f.p2), f"--window raise-flag {ref} set no flag")
        finally:
            lowered = _cli(cli, ["--window", window, "lower-flag", "--workspace", f.ws, "--panel", ref], env=env, check=False)
        _must(lowered.returncode == 0, f"--window lower-flag {ref} failed: {lowered.stdout!r} {lowered.stderr!r}")
        _must("flag" not in _metadata(c, f.ws, f.p2), f"--window lower-flag {ref} left the flag")
        # feed open resolves the ref before anything else; any outcome but a resolution failure is fine
        # (the scratch workspace is in the background, and agents cannot switch the operator's workspace).
        opened = _cli(cli, ["feed", "open", ref, "--workspace", f.ws], env=env, check=False)
        merged = f"{opened.stdout}\n{opened.stderr}"
        _must("no longer resolves" not in merged and "Invalid" not in merged, f"feed open {ref} did not resolve: {merged!r}")
    print("PASS: --window scoped commands and feed open accept panel:/tab:/surface: refs (any case)")


def test_cli_env_vars_target_the_same_panel(c: cmux, cli: str, f: Fixture) -> None:
    ws = f.ws
    token = f"env-{uuid.uuid4().hex[:8]}"
    other = f"other-{uuid.uuid4().hex[:8]}"
    _set_title_metadata(c, ws, f.p2, token)
    _set_title_metadata(c, ws, f.p1, other)

    def title_for(env_extra: Dict[str, str]) -> Optional[str]:
        env = _cli_env({"C11_WORKSPACE_ID": ws, "CMUX_WORKSPACE_ID": ws, **env_extra})
        out = _cli_json(cli, ["get-metadata"], env=env)
        return (out.get("metadata") or {}).get("title")

    # Without a flag the command targets the panel named by the environment, whichever spelling it uses.
    for name in ("C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"):
        _same(title_for({name: f.p2}), token, f"{name} should target panel {f.p2}")

    # C11_PANEL_ID wins over a conflicting C11_TAB_ID / C11_SURFACE_ID; C11_TAB_ID wins over C11_SURFACE_ID.
    _same(title_for({"C11_PANEL_ID": f.p2, "C11_TAB_ID": f.p1}), token, "C11_PANEL_ID should win over a conflicting C11_TAB_ID")
    _same(title_for({"C11_PANEL_ID": f.p2, "C11_SURFACE_ID": f.p1}), token, "C11_PANEL_ID should win over a conflicting C11_SURFACE_ID")
    _same(title_for({"C11_PANEL_ID": f.p2, "C11_TAB_ID": f.p1, "C11_SURFACE_ID": f.p1}), token,
          "C11_PANEL_ID should win over both older spellings")
    _same(title_for({"C11_TAB_ID": f.p2, "C11_SURFACE_ID": f.p1}), token, "C11_TAB_ID should win over C11_SURFACE_ID")

    # Flags win over the environment, in every spelling.
    env = _cli_env({"C11_PANEL_ID": f.p1, "C11_WORKSPACE_ID": ws})
    for flag in ("--panel", "--tab", "--surface"):
        proc = _cli(cli, ["--json", "get-metadata", flag, f.p2], env=env, check=False)
        _must(proc.returncode == 0, f"get-metadata {flag} must be accepted: {proc.stdout!r} {proc.stderr!r}")
        out = json.loads(proc.stdout or "{}")
        _same((out.get("metadata") or {}).get("title"), token, f"{flag} did not override the environment")
    # Refs with any of the three prefixes work as flag values too.
    for prefix in ("panel", "tab", "surface"):
        out = _cli_json(cli, ["get-metadata", "--panel", f.panel_ref(prefix)], env=env)
        _same((out.get("metadata") or {}).get("title"), token, f"--panel {prefix}:N did not target the panel")

    # `c11 mailbox panel-name` and the older `tab-name` / `surface-name` print the same caller title.
    env = _cli_env({"C11_PANEL_ID": f.p2, "C11_WORKSPACE_ID": ws})
    names = [_cli(cli, ["mailbox", sub], env=env).stdout.strip() for sub in ("panel-name", "tab-name", "surface-name")]
    _must(names[0] == names[1] == names[2], f"mailbox panel-name/tab-name/surface-name disagree: {names}")

    # Metadata scope flags: --area and --pane address the same area.
    role = f"area-{uuid.uuid4().hex[:6]}"
    env = _cli_env({"C11_WORKSPACE_ID": ws})
    _cli(cli, ["set-metadata", "--area", f.area_a, "--key", "role", "--value", role], env=env)
    for flag in ("--area", "--pane"):
        out = _cli_json(cli, ["get-metadata", flag, f.area_a], env=env)
        _same((out.get("metadata") or {}).get("role"), role, f"{flag} did not read the area metadata")
    _cli(cli, ["clear-metadata", "--pane", f.area_a, "--key", "role"], env=env)
    print("PASS: C11_PANEL_ID / C11_TAB_ID / C11_SURFACE_ID / CMUX_* resolve the caller (panel wins), flags override, refs of any prefix work")


def test_terminal_exports_panel_env(c: cmux) -> None:
    """A live terminal exports C11_PANEL_ID/NUM beside every older twin."""
    ws = str(_call(c, "workspace.create").get("workspace_id") or "")
    _must(bool(ws), "workspace.create returned no workspace_id")
    try:
        time.sleep(0.4)
        panel_id = _focused_panel_id(c, ws)
        _must(bool(panel_id), "fresh workspace has no focused panel")
        names = ("C11_PANEL_ID", "C11_PANEL_NUM", "C11_TAB_ID", "C11_TAB_NUM", "C11_SURFACE_ID")
        # The echoed command contains a literal `$`, so only real output lines match ENVCHK_NAME=value.
        command = 'for v in ' + " ".join(names) + '; do eval "echo ENVCHK_$v=\\${$v}"; done\n'
        _call(c, "panel.send_text", {"workspace_id": ws, "panel_id": panel_id, "text": command})

        def parsed() -> Dict[str, str]:
            found: Dict[str, str] = {}
            for line in _screen_text(c, ws, panel_id).splitlines():
                m = re.fullmatch(r"ENVCHK_(C11_[A-Z_]+)=(\S+)", line.strip())
                if m:
                    found[m.group(1)] = m.group(2)
            return found

        _must(_wait_for(lambda: len(parsed()) == len(names), timeout=10.0),
              f"terminal did not print its panel env: {parsed()} screen={_screen_text(c, ws, panel_id)[-400:]!r}")
        env = parsed()
        for name in ("C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID"):
            _same(env[name].lower(), panel_id.lower(), f"{name} should hold the panel's id")
        _must(env["C11_PANEL_NUM"].isdigit(), f"C11_PANEL_NUM should be a number: {env['C11_PANEL_NUM']!r}")
        _same(env["C11_PANEL_NUM"], env["C11_TAB_NUM"], "C11_PANEL_NUM and C11_TAB_NUM should match")
    finally:
        try:
            _call(c, "workspace.close", {"workspace_id": ws})
        except Exception:
            pass
    print("PASS: a new terminal exports C11_PANEL_ID, C11_PANEL_NUM, C11_TAB_ID, C11_TAB_NUM and C11_SURFACE_ID")


def test_free_text_is_never_rewritten(c: cmux, cli: str, f: Fixture) -> None:
    """Text typed into a panel is data: flag-looking words arrive literally, old or new spelling."""
    ws = f.ws
    for token in ("--surface", "--pane", "--panel", "--tab", "--area"):
        # `send` refuses a bare flag-looking word before `--` (an empty target or an
        # unknown flag), so literal flag text always goes after `--`.
        for form in ("after --",):
            _cli(cli, ["send-key", "--workspace", ws, "--panel", f.p3, "ctrl+u"])
            if form == "after --":
                args = ["send", "--workspace", ws, "--panel", f.p3, "--no-submit", "--", token]
                env = None
            else:
                args = ["send", "--no-submit", token]
                env = _cli_env({"C11_PANEL_ID": f.p3, "C11_WORKSPACE_ID": ws})
            _cli(cli, args, env=env)
            deadline = time.time() + 6.0
            line = ""
            while time.time() < deadline:
                line = _last_screen_line(c, ws, f.p3)
                if line.endswith(token):
                    break
                time.sleep(0.15)
            _must(line.endswith(token), f"send ({form}) of {token!r} did not arrive literally; last line {line!r}")
    _cli(cli, ["send-key", "--workspace", ws, "--panel", f.p3, "ctrl+u"])
    print("PASS: flag-looking free text reaches the panel literally")


# ---------------------------------------------------------------------------

def main() -> int:
    cli = find_cli_binary()
    with cmux(SOCKET_PATH) as c:
        test_capabilities_advertise_panel_vocabulary(c)
        fixture = Fixture(c)
        try:
            test_read_methods_resolve_to_same_handlers(c, fixture)
            test_param_spellings_address_the_same_panel(c, fixture)
            test_write_methods_cross_over(c, fixture)
            test_notification_create_aliases(c, fixture)
            test_debug_method_aliases(c, fixture)
            test_panel_action_values(c, fixture)
            test_old_panel_presentation_methods(c, fixture)
            test_old_ref_params_and_caller_keys(c, fixture)
            test_results_carry_panel_and_tab_keys(c, fixture)
            test_tree_results(c, cli, fixture)
            test_browser_panel_aliases(c, fixture)
            test_flag_caller_metadata_keys(c, cli, fixture)
            test_cli_help_names_panels(cli)
            test_cli_read_command_aliases(cli, fixture)
            test_cli_env_vars_target_the_same_panel(c, cli, fixture)
            test_cli_action_command_aliases(c, cli, fixture)
            test_scoped_window_and_feed_refs(c, cli, fixture)
            test_free_text_is_never_rewritten(c, cli, fixture)
        finally:
            fixture.close()
        # These reshape the layout or need a fresh terminal, so each gets a workspace of its own.
        test_terminal_exports_panel_env(c)
        test_old_panel_layout_methods(c)
        test_old_area_methods(c)
        test_workspace_apply_ref_maps(c)
    print("PASS: vocabulary aliases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
