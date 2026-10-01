#!/usr/bin/env python3
"""Vocabulary alias regression: workspace > area > tab.

The canonical names are `tab.*` / `area.*` socket methods, `tab_id` / `area_id`
params, `tab:N` / `area:N` refs, `new-tab` / `list-areas` CLI commands and
`C11_TAB_ID`. Every older spelling (`surface.*` / `pane.*`, `surface_id` /
`pane_id` / `panel_id`, `surface:N` / `pane:N`, `new-surface` / `list-panes`,
`--surface` / `--panel` / `--pane`, `C11_SURFACE_ID` / `CMUX_*`) must keep
resolving to the same object and behavior, and JSON responses carry both the
canonical keys and the older keys (older `*_ref` values keep their old prefix).

Runs against a live tagged build, like the rest of tests_v2.
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
from typing import Any, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError, find_cli_binary  # type: ignore[import]


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")

ID_ENV_KEYS = (
    "C11_TAB_ID", "C11_SURFACE_ID", "C11_PANEL_ID",
    "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID",
    "C11_WORKSPACE_ID", "CMUX_WORKSPACE_ID",
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


def _cli_env(extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    env = dict(os.environ)
    for key in ID_ENV_KEYS:
        env.pop(key, None)
    env["CMUX_SOCKET"] = SOCKET_PATH
    env.update(extra or {})
    if "C11_WORKSPACE_ID" in env:
        env["CMUX_WORKSPACE_ID"] = env["C11_WORKSPACE_ID"]
    return env


def _cli(cli: str, args: Sequence[str], env: Optional[Dict[str, str]] = None, check: bool = True) -> subprocess.CompletedProcess:
    cmd = [cli, "--socket", SOCKET_PATH, *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env or _cli_env())
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


def _tabs(c: cmux, ws: str) -> List[Dict[str, Any]]:
    return _rows(_call(c, "tab.list", {"workspace_id": ws}), "tabs")


def _areas(c: cmux, ws: str) -> List[Dict[str, Any]]:
    return _rows(_call(c, "area.list", {"workspace_id": ws}), "areas")


def _focused_area_id(c: cmux, ws: str) -> str:
    return str(_call(c, "tab.current", {"workspace_id": ws}).get("area_id") or "")


def _tab_row(c: cmux, ws: str, tab_id: str) -> Dict[str, Any]:
    for row in _tabs(c, ws):
        if row.get("id") == tab_id:
            return row
    raise cmuxError(f"tab {tab_id} is not in workspace {ws}")


def _focused_tab_id(c: cmux, ws: str) -> str:
    return str(_call(c, "tab.current", {"workspace_id": ws}).get("tab_id") or "")


def _metadata(c: cmux, ws: str, tab_id: str) -> Dict[str, Any]:
    res = _call(c, "tab.get_metadata", {"workspace_id": ws, "tab_id": tab_id})
    return dict(res.get("metadata") or {})


class Fixture:
    """A scratch workspace: area A holds tabs `t1`,`t2`; area B (a split) holds `t3`."""

    def __init__(self, c: cmux) -> None:
        self.c = c
        self.ws = c.new_workspace()
        c.select_workspace(self.ws)
        time.sleep(0.3)
        self.t1 = _focused_tab_id(c, self.ws)
        _must(bool(self.t1), "fresh workspace has no focused tab")
        self.t3 = str(_call(c, "tab.split", {"workspace_id": self.ws, "tab_id": self.t1, "direction": "right"}).get("tab_id") or "")
        _must(bool(self.t3), "tab.split returned no tab_id")
        time.sleep(0.3)
        areas = _areas(c, self.ws)
        _must(len(areas) == 2, f"expected 2 areas after split, got {areas}")
        self.area_a = next(a["id"] for a in areas if self.t1 in (a.get("tab_ids") or []))
        self.area_b = next(a["id"] for a in areas if self.t3 in (a.get("tab_ids") or []))
        self.t2 = str(_call(c, "tab.create", {"workspace_id": self.ws, "area_id": self.area_a}).get("tab_id") or "")
        _must(bool(self.t2), "tab.create returned no tab_id")
        time.sleep(0.2)

    def close(self) -> None:
        try:
            self.c.close_workspace(self.ws)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Socket methods and params
# ---------------------------------------------------------------------------

def test_read_methods_resolve_to_same_objects(c: cmux, f: Fixture) -> None:
    ws = f.ws
    pairs = [
        ("surface.list", "tab.list", ("surfaces", "tabs")),
        ("pane.list", "area.list", ("panes", "areas")),
        ("surface.health", "tab.health", ("surfaces", "tabs")),
    ]
    for old, new, (old_key, new_key) in pairs:
        old_rows = _rows(_call(c, old, {"workspace_id": ws}), old_key)
        new_rows = _rows(_call(c, new, {"workspace_id": ws}), new_key)
        _must(len(new_rows) > 0 and _ids(old_rows) == _ids(new_rows), f"{old} vs {new} disagree: {_ids(old_rows)} != {_ids(new_rows)}")

    old_cur = _call(c, "surface.current", {"workspace_id": ws})
    new_cur = _call(c, "tab.current", {"workspace_id": ws})
    _same(new_cur.get("tab_id"), old_cur.get("surface_id"), f"surface.current vs tab.current: {old_cur} {new_cur}")

    old_surfaces = _rows(_call(c, "pane.surfaces", {"workspace_id": ws, "pane_id": f.area_a}), "surfaces")
    new_tabs = _rows(_call(c, "area.tabs", {"workspace_id": ws, "area_id": f.area_a}), "tabs")
    _must(_ids(old_surfaces) == _ids(new_tabs) and len(new_tabs) == 2, f"pane.surfaces vs area.tabs: {old_surfaces} {new_tabs}")

    old_md = _call(c, "surface.get_metadata", {"workspace_id": ws, "surface_id": f.t1})
    new_md = _call(c, "tab.get_metadata", {"workspace_id": ws, "tab_id": f.t1})
    _must(isinstance(old_md.get("metadata"), dict) and isinstance(new_md.get("metadata"), dict),
          f"get_metadata must return a metadata object: {old_md} {new_md}")
    _same(new_md.get("metadata"), old_md.get("metadata"), "surface/tab get_metadata differ")

    old_pmd = _call(c, "pane.get_metadata", {"workspace_id": ws, "pane_id": f.area_a})
    new_pmd = _call(c, "area.get_metadata", {"workspace_id": ws, "area_id": f.area_a})
    _must(isinstance(old_pmd.get("metadata"), dict) and isinstance(new_pmd.get("metadata"), dict),
          f"area get_metadata must return a metadata object: {old_pmd} {new_pmd}")
    _same(new_pmd.get("metadata"), old_pmd.get("metadata"), "pane/area get_metadata differ")

    old_tb = _call(c, "surface.get_titlebar_state", {"workspace_id": ws, "surface_id": f.t1})
    new_tb = _call(c, "tab.get_titlebar_state", {"workspace_id": ws, "tab_id": f.t1})
    _must(len(new_tb) > 0 and sorted(old_tb) == sorted(new_tb), f"titlebar state keys differ: {sorted(old_tb)} {sorted(new_tb)}")

    old_rt = _call(c, "surface.read_text", {"workspace_id": ws, "surface_id": f.t1})
    new_rt = _call(c, "tab.read_text", {"workspace_id": ws, "tab_id": f.t1})
    _must("text" in old_rt and "text" in new_rt, f"read_text missing text: {sorted(old_rt)} {sorted(new_rt)}")
    print("PASS: read methods (surface.*/pane.* == tab.*/area.*)")


def test_old_param_names_address_the_same_tab(c: cmux, f: Fixture) -> None:
    ws = f.ws
    token = f"alias-{uuid.uuid4().hex[:8]}"
    _call(c, "tab.set_metadata", {
        "workspace_id": ws, "tab_id": f.t2, "mode": "merge", "source": "explicit",
        "metadata": {"title": token},
    })
    for key in ("tab_id", "surface_id", "panel_id"):
        res = _call(c, "tab.get_metadata", {"workspace_id": ws, key: f.t2})
        _must((res.get("metadata") or {}).get("title") == token, f"param {key} did not resolve tab {f.t2}: {res}")

    for key in ("area_id", "pane_id"):
        res = _call(c, "area.tabs", {"workspace_id": ws, key: f.area_a})
        _must(f.t2 in _ids(_rows(res, "tabs")), f"param {key} did not resolve area {f.area_a}: {res}")

    # Refs: tab:N and surface:N (and area:N / pane:N) are interchangeable on input.
    t2_row = next(r for r in _tabs(c, ws) if r["id"] == f.t2)
    ordinal = _ordinal(t2_row["ref"], "tab")
    for ref in (f"tab:{ordinal}", f"surface:{ordinal}"):
        res = _call(c, "tab.get_metadata", {"workspace_id": ws, "tab_id": ref})
        _must((res.get("metadata") or {}).get("title") == token, f"ref {ref} did not resolve tab {f.t2}: {res}")
    a_row = next(r for r in _areas(c, ws) if r["id"] == f.area_a)
    a_ordinal = _ordinal(a_row["ref"], "area")
    for ref in (f"area:{a_ordinal}", f"pane:{a_ordinal}"):
        res = _call(c, "area.tabs", {"workspace_id": ws, "area_id": ref})
        _must(f.t2 in _ids(_rows(res, "tabs")), f"ref {ref} did not resolve area {f.area_a}: {res}")
    print("PASS: old param names and ref prefixes address the same objects")


def test_write_methods_cross_over(c: cmux, f: Fixture) -> None:
    ws = f.ws
    # Metadata written through the old method is readable through the new one, and back.
    old_token = f"old-{uuid.uuid4().hex[:6]}"
    _call(c, "surface.set_metadata", {
        "workspace_id": ws, "surface_id": f.t3, "mode": "merge", "source": "explicit",
        "metadata": {"title": old_token},
    })
    _must(_metadata(c, ws, f.t3).get("title") == old_token, "surface.set_metadata not visible via tab.get_metadata")
    new_token = f"new-{uuid.uuid4().hex[:6]}"
    _call(c, "tab.set_metadata", {
        "workspace_id": ws, "tab_id": f.t3, "mode": "merge", "source": "explicit",
        "metadata": {"title": new_token},
    })
    res = _call(c, "surface.get_metadata", {"workspace_id": ws, "surface_id": f.t3})
    _must((res.get("metadata") or {}).get("title") == new_token, "tab.set_metadata not visible via surface.get_metadata")

    pane_token = f"pane-{uuid.uuid4().hex[:6]}"
    _call(c, "pane.set_metadata", {
        "workspace_id": ws, "pane_id": f.area_b, "mode": "merge", "source": "explicit",
        "metadata": {"role": pane_token},
    })
    res = _call(c, "area.get_metadata", {"workspace_id": ws, "area_id": f.area_b})
    _must((res.get("metadata") or {}).get("role") == pane_token, "pane.set_metadata not visible via area.get_metadata")
    _call(c, "area.clear_metadata", {"workspace_id": ws, "area_id": f.area_b, "keys": ["role"], "source": "explicit"})
    res = _call(c, "pane.get_metadata", {"workspace_id": ws, "pane_id": f.area_b})
    _must("role" not in (res.get("metadata") or {}), "area.clear_metadata not visible via pane.get_metadata")

    # Text sent through either method lands in the same tab.
    for method, key in (("surface.send_text", "surface_id"), ("tab.send_text", "tab_id")):
        token = f"echo vocab_{uuid.uuid4().hex[:8]}"
        _call(c, method, {"workspace_id": ws, key: f.t3, "text": token + "\n"})
        marker = token.split(" ", 1)[1]
        deadline = time.time() + 6.0
        seen = False
        while time.time() < deadline and not seen:
            text = str(_call(c, "tab.read_text", {"workspace_id": ws, "tab_id": f.t3}).get("text") or "")
            seen = marker in text
            if not seen:
                time.sleep(0.15)
        _must(seen, f"{method} text never reached tab {f.t3}")

    # Focus through the old and the new method.
    _call(c, "surface.focus", {"workspace_id": ws, "surface_id": f.t2})
    _must(_focused_tab_id(c, ws) == f.t2, "surface.focus did not focus the tab")
    _call(c, "tab.focus", {"workspace_id": ws, "tab_id": f.t1})
    _must(_focused_tab_id(c, ws) == f.t1, "tab.focus did not focus the tab")
    _call(c, "tab.focus", {"workspace_id": ws, "panel_id": f.t2})
    _must(_focused_tab_id(c, ws) == f.t2, "tab.focus with panel_id did not focus the tab")
    _call(c, "pane.focus", {"workspace_id": ws, "pane_id": f.area_b})
    _same(_focused_area_id(c, ws), f.area_b, "pane.focus did not focus the area")
    _must(_focused_tab_id(c, ws) == f.t3, "pane.focus should land on the area's only tab")
    _call(c, "area.focus", {"workspace_id": ws, "area_id": f.area_a})
    _same(_focused_area_id(c, ws), f.area_a, "area.focus did not focus the area")
    _call(c, "pane.focus", {"workspace_id": ws, "pane_id": f.area_b})
    _call(c, "area.focus", {"workspace_id": ws, "pane_id": f.area_a})
    _same(_focused_area_id(c, ws), f.area_a, "area.focus with the older pane_id key did not focus the area")

    # Create and close through the old and the new method.
    before = len(_tabs(c, ws))
    old_created = _call(c, "surface.create", {"workspace_id": ws, "pane_id": f.area_a, "focus": False})
    new_created = _call(c, "tab.create", {"workspace_id": ws, "area_id": f.area_a, "focus": False})
    _must(len(_tabs(c, ws)) == before + 2, "surface.create / tab.create should each add one tab")
    _call(c, "surface.close", {"workspace_id": ws, "surface_id": old_created["surface_id"]})
    _call(c, "tab.close", {"workspace_id": ws, "tab_id": new_created["tab_id"]})
    time.sleep(0.2)
    _must(len(_tabs(c, ws)) == before, "surface.close / tab.close should each remove one tab")
    print("PASS: write methods cross over (old and new share state)")


def test_notification_create_aliases(c: cmux, f: Fixture) -> None:
    ws = f.ws
    _call(c, "tab.focus", {"workspace_id": ws, "tab_id": f.t1})  # notify a tab that is not focused
    for method, key in (("notification.create_for_surface", "surface_id"), ("notification.create_for_tab", "tab_id")):
        # A tab holds one notification at a time, so check each alias on its own.
        title = f"vocab {method}"
        _call(c, method, {key: f.t3, "title": title, "subtitle": "", "body": "alias check"})
        items = list(_call(c, "notification.list").get("notifications") or [])
        mine = [n for n in items if n.get("title") == title]
        _must(len(mine) == 1, f"{method} should create a notification, got {mine}")
        _same(mine[0].get("tab_id"), f.t3, f"notification tab_id for {method}")
        _same(mine[0].get("surface_id"), f.t3, f"notification surface_id for {method}")
        try:
            c.clear_notifications()
        except Exception:
            pass
    try:
        c.clear_notifications()
    except Exception:
        pass
    print("PASS: notification.create_for_surface == notification.create_for_tab")


# ---------------------------------------------------------------------------
# Dual-key JSON
# ---------------------------------------------------------------------------

def _check_tab_row(row: Dict[str, Any], what: str) -> None:
    _same(row.get("area_id"), row.get("pane_id"), f"{what}: area_id/pane_id")
    _same_ref(row.get("area_ref"), "area", row.get("pane_ref"), "pane", f"{what} area_ref/pane_ref")
    _same(row.get("index_in_area"), row.get("index_in_pane"), f"{what}: index_in_area/index_in_pane")
    _same(row.get("selected_in_area"), row.get("selected_in_pane"), f"{what}: selected_in_area/selected_in_pane")
    _ordinal(row.get("ref"), "tab")


def test_dual_keys_in_list_responses(c: cmux, f: Fixture) -> None:
    ws = f.ws
    res = _call(c, "tab.list", {"workspace_id": ws})
    tabs, surfaces = _rows(res, "tabs"), _rows(res, "surfaces")
    _must(_ids(tabs) == _ids(surfaces) and len(tabs) == 3, f"tab.list tabs/surfaces arrays differ: {res}")
    for row in tabs:
        _check_tab_row(row, "tab.list row")
    for row in _rows(_call(c, "surface.list", {"workspace_id": ws}), "tabs", "surfaces"):
        _check_tab_row(row, "surface.list row")

    res = _call(c, "area.list", {"workspace_id": ws})
    areas, panes = _rows(res, "areas"), _rows(res, "panes")
    _must(_ids(areas) == _ids(panes) and len(areas) == 2, f"area.list areas/panes arrays differ: {res}")
    for row in areas:
        _same(row.get("tab_ids"), row.get("surface_ids"), "area row tab_ids/surface_ids")
        _must(len(row["tab_ids"]) > 0, f"area row should list its tabs: {row}")
        _must(len(row["tab_refs"]) == len(row["surface_refs"]) == len(row["tab_ids"]), f"area row refs mismatch: {row}")
        for new_ref, old_ref in zip(row["tab_refs"], row["surface_refs"]):
            _same_ref(new_ref, "tab", old_ref, "surface", "area row tab_refs/surface_refs")
        _same(row.get("tab_count"), row.get("surface_count"), "area row tab_count/surface_count")
        _same(row.get("tab_count"), len(row["tab_ids"]), "area row tab_count vs tab_ids")
        _same(row.get("selected_tab_id"), row.get("selected_surface_id"), "selected_tab_id/selected_surface_id")
        _same_ref(row.get("selected_tab_ref"), "tab", row.get("selected_surface_ref"), "surface", "selected refs")
        _ordinal(row.get("ref"), "area")

    res = _call(c, "area.tabs", {"workspace_id": ws, "area_id": f.area_a})
    _must(_ids(_rows(res, "tabs")) == _ids(_rows(res, "surfaces")), f"area.tabs tabs/surfaces differ: {res}")
    _same(res.get("area_id"), res.get("pane_id"), "area.tabs area_id/pane_id")
    _same(res.get("area_id"), f.area_a, "area.tabs area_id")
    _same_ref(res.get("area_ref"), "area", res.get("pane_ref"), "pane", "area.tabs area_ref/pane_ref")

    res = _call(c, "tab.current", {"workspace_id": ws})
    _same(res.get("tab_id"), res.get("surface_id"), "tab.current tab_id/surface_id")
    _same_ref(res.get("tab_ref"), "tab", res.get("surface_ref"), "surface", "tab.current refs")
    _same(res.get("area_id"), res.get("pane_id"), "tab.current area_id/pane_id")
    _same_ref(res.get("area_ref"), "area", res.get("pane_ref"), "pane", "tab.current area/pane refs")
    _same(res.get("tab_type"), res.get("surface_type"), "tab.current tab_type/surface_type")
    print("PASS: list/current responses carry canonical and older keys")


def test_dual_keys_in_create_split_identify(c: cmux, f: Fixture) -> None:
    ws = f.ws
    created = _call(c, "tab.create", {"workspace_id": ws, "area_id": f.area_a, "focus": False})
    _same(created.get("tab_id"), created.get("surface_id"), "tab.create tab_id/surface_id")
    _same_ref(created.get("tab_ref"), "tab", created.get("surface_ref"), "surface", "tab.create refs")
    _same(created.get("area_id"), created.get("pane_id"), "tab.create area_id/pane_id")
    _same(created.get("area_id"), f.area_a, "tab.create area_id")
    _same_ref(created.get("area_ref"), "area", created.get("pane_ref"), "pane", "tab.create area/pane refs")
    _call(c, "tab.close", {"workspace_id": ws, "tab_id": created["tab_id"]})

    split = _call(c, "tab.split", {"workspace_id": ws, "tab_id": f.t3, "direction": "down"})
    _same(split.get("tab_id"), split.get("surface_id"), "tab.split tab_id/surface_id")
    _call(c, "tab.close", {"workspace_id": ws, "tab_id": split["tab_id"]})
    time.sleep(0.2)

    ident = _call(c, "system.identify", {"caller": {"workspace_id": ws, "tab_id": f.t2}})
    for scope in ("focused", "caller"):
        block = ident.get(scope) or {}
        _same(block.get("tab_id"), block.get("surface_id"), f"identify.{scope} tab_id/surface_id")
        _same_ref(block.get("tab_ref"), "tab", block.get("surface_ref"), "surface", f"identify.{scope} tab refs")
        _same(block.get("area_id"), block.get("pane_id"), f"identify.{scope} area_id/pane_id")
        _same_ref(block.get("area_ref"), "area", block.get("pane_ref"), "pane", f"identify.{scope} area refs")
    _must((ident.get("caller") or {}).get("tab_id") == f.t2, f"identify did not resolve the caller tab: {ident}")

    # Older spelling of the caller block is still accepted on input.
    ident_old = _call(c, "system.identify", {"caller": {"workspace_id": ws, "surface_id": f.t2}})
    _must((ident_old.get("caller") or {}).get("tab_id") == f.t2, f"identify caller.surface_id not resolved: {ident_old}")
    print("PASS: create/split/identify carry canonical and older keys")


def _walk(value: Any):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk(child)


def test_dual_keys_in_tree_json(cli: str, f: Fixture) -> None:
    payload = _cli_json(cli, ["tree", "--workspace", f.ws])
    workspaces = [w for d in _walk(payload) for w in (d.get("workspaces") or []) if isinstance(w, dict)]
    ws_node = next((w for w in workspaces if w.get("id") == f.ws or w.get("ref") == f.ws), None)
    _must(ws_node is not None, f"tree --json has no node for workspace {f.ws}: {[w.get('id') for w in workspaces]}")
    areas, panes = ws_node.get("areas"), ws_node.get("panes")
    _must(isinstance(areas, list) and isinstance(panes, list) and len(areas) == len(panes) == 2,
          f"tree workspace node should carry both `areas` and `panes`: {sorted(ws_node)}")
    for area, pane in zip(areas, panes):
        tabs, surfaces = area.get("tabs"), area.get("surfaces")
        _must(isinstance(tabs, list) and isinstance(surfaces, list) and len(tabs) == len(surfaces) > 0,
              f"tree area node should carry both `tabs` and `surfaces`: {sorted(area)}")
        # `ref` has no legacy twin: both arrays hold the canonical `area:N` / `tab:N` value.
        _ordinal(area.get("ref"), "area")
        _same(area.get("id"), pane.get("id"), "tree areas/panes entries should be the same area")
        _same(area.get("ref"), pane.get("ref"), "tree areas/panes entries should share one ref")
        _same(area.get("tab_count"), area.get("surface_count"), "tree area tab_count/surface_count")
        _same(area.get("tab_count"), len(tabs), "tree area tab_count vs tabs")
        for tab, surface in zip(tabs, surfaces):
            _ordinal(tab.get("ref"), "tab")
            _same(tab.get("id"), surface.get("id"), "tree tabs/surfaces entries should be the same tab")
            _same(tab.get("ref"), surface.get("ref"), "tree tabs/surfaces entries should share one ref")
            _check_tab_row(tab, "tree tab")
            _check_tab_row(surface, "tree surface")
    print("PASS: tree --json carries areas/panes and tabs/surfaces")


def test_flag_caller_metadata_keys(c: cmux, cli: str, f: Fixture) -> None:
    env = _cli_env({"C11_TAB_ID": f.t2, "C11_WORKSPACE_ID": f.ws})
    try:
        _cli(cli, ["raise-flag", "--tab", f.t2, "vocabulary alias check"], env=env)
        md = _metadata(c, f.ws, f.t2)
        _must(md.get("flag_caller_tab_id") == f.t2, f"flag_caller_tab_id missing or wrong: {md}")
        _must(md.get("flag_caller_surface_id") == f.t2, f"flag_caller_surface_id missing or wrong: {md}")
        cli_md = _cli_json(cli, ["get-metadata", "--tab", f.t2], env=env)
        _must((cli_md.get("metadata") or {}).get("flag_caller_tab_id") == f.t2, f"get-metadata lost flag_caller_tab_id: {cli_md}")
    finally:
        lowered = _cli(cli, ["lower-flag", "--tab", f.t2], env=env, check=False)
    _must(lowered.returncode == 0, f"lower-flag failed: {lowered.stdout!r} {lowered.stderr!r}")
    md = _metadata(c, f.ws, f.t2)
    for key in ("flag", "flag_caller_tab_id", "flag_caller_surface_id"):
        _must(key not in md, f"lower-flag left {key} behind: {md}")
    print("PASS: flag_caller_tab_id and flag_caller_surface_id are both written, and both cleared by lower-flag")


# ---------------------------------------------------------------------------
# CLI commands, flags, env
# ---------------------------------------------------------------------------

def test_cli_read_command_aliases(cli: str, f: Fixture) -> None:
    ws = f.ws
    pairs: List[Tuple[List[str], List[str], Tuple[str, ...]]] = [
        (["list-areas", "--workspace", ws], ["list-panes", "--workspace", ws], ("areas", "panes")),
        (["list-tabs", "--workspace", ws], ["list-panels", "--workspace", ws], ("tabs", "surfaces")),
        (["tab-health", "--workspace", ws], ["surface-health", "--workspace", ws], ("tabs", "surfaces")),
        (["list-area-tabs", "--workspace", ws, "--area", f.area_a],
         ["list-pane-surfaces", "--workspace", ws, "--pane", f.area_a], ("tabs", "surfaces")),
    ]
    for new_args, old_args, keys in pairs:
        new_rows = _rows(_cli_json(cli, new_args, id_format="uuids"), *keys)
        old_rows = _rows(_cli_json(cli, old_args, id_format="uuids"), *keys)
        _must(_ids(new_rows) == _ids(old_rows) and new_rows, f"`{new_args[0]}` vs `{old_args[0]}` disagree: {new_rows} {old_rows}")
    _cli(cli, ["refresh-tabs"])
    _cli(cli, ["refresh-surfaces"])
    print("PASS: read-only CLI commands (new == old)")


def test_cli_action_command_aliases(c: cmux, cli: str, f: Fixture) -> None:
    ws = f.ws

    # new-tab / new-surface, close-tab / close-surface (+ --area/--pane, --tab/--surface/--panel).
    before = len(_tabs(c, ws))
    new_tab = _cli_json(cli, ["new-tab", "--workspace", ws, "--area", f.area_a, "--no-focus"], id_format="uuids")
    old_tab = _cli_json(cli, ["new-surface", "--workspace", ws, "--pane", f.area_a, "--no-focus"], id_format="uuids")
    _must(len(_tabs(c, ws)) == before + 2, f"new-tab / new-surface should each add a tab: {new_tab} {old_tab}")
    new_id = str(new_tab.get("tab_id") or new_tab.get("surface_id"))
    old_id = str(old_tab.get("tab_id") or old_tab.get("surface_id"))
    _cli(cli, ["close-tab", "--workspace", ws, "--tab", new_id])
    _cli(cli, ["close-surface", "--workspace", ws, "--surface", old_id])
    time.sleep(0.2)
    _must(len(_tabs(c, ws)) == before, "close-tab / close-surface should each remove a tab")
    extra = _cli_json(cli, ["new-tab", "--workspace", ws, "--area", f.area_a, "--no-focus"], id_format="uuids")
    _cli(cli, ["close-tab", "--workspace", ws, "--panel", str(extra.get("tab_id") or extra.get("surface_id"))])
    time.sleep(0.2)
    _must(len(_tabs(c, ws)) == before, "close-tab --panel should remove the tab")

    # focus-tab / focus-panel, focus-area / focus-pane.
    _cli(cli, ["focus-tab", "--workspace", ws, "--tab", f.t2])
    _must(_focused_tab_id(c, ws) == f.t2, "focus-tab --tab did not focus")
    _cli(cli, ["focus-panel", "--workspace", ws, "--panel", f.t1])
    _must(_focused_tab_id(c, ws) == f.t1, "focus-panel --panel did not focus")
    _cli(cli, ["focus-tab", "--workspace", ws, "--surface", f.t2])
    _must(_focused_tab_id(c, ws) == f.t2, "focus-tab --surface did not focus")
    _cli(cli, ["focus-area", "--workspace", ws, "--area", f.area_b])
    _must(_focused_tab_id(c, ws) == f.t3, "focus-area --area did not focus the area's tab")
    _cli(cli, ["focus-pane", "--workspace", ws, "--pane", f.area_a])
    _same(_focused_area_id(c, ws), f.area_a, "focus-pane --pane did not focus the area")
    _cli(cli, ["focus-area", f.area_b, "--workspace", ws])  # positional comes first
    _same(_focused_area_id(c, ws), f.area_b, "focus-area <area> (positional) did not focus the area")
    _cli(cli, ["focus-pane", f.area_a, "--workspace", ws])
    _same(_focused_area_id(c, ws), f.area_a, "focus-pane <area> (positional) did not focus the area")
    _cli(cli, ["focus-tab", f.t3, "--workspace", ws])
    _must(_focused_tab_id(c, ws) == f.t3, "focus-tab <tab> (positional) did not focus the tab")
    _cli(cli, ["focus-panel", f.t1, "--workspace", ws])
    _must(_focused_tab_id(c, ws) == f.t1, "focus-panel <tab> (positional) did not focus the tab")

    # send-tab / send-panel, send-key-tab / send-key-panel.
    for cmd, flag in (("send-tab", "--tab"), ("send-panel", "--panel")):
        token = f"vocab_{uuid.uuid4().hex[:8]}"
        _cli(cli, [cmd, "--workspace", ws, flag, f.t3, f"echo {token}\\n"])
        deadline = time.time() + 6.0
        seen = False
        while time.time() < deadline and not seen:
            seen = token in str(_call(c, "tab.read_text", {"workspace_id": ws, "tab_id": f.t3}).get("text") or "")
            if not seen:
                time.sleep(0.15)
        _must(seen, f"{cmd} text never reached the tab")
    _cli(cli, ["send-key-tab", "--workspace", ws, "--tab", f.t3, "enter"])
    _cli(cli, ["send-key-panel", "--workspace", ws, "--panel", f.t3, "enter"])

    # tab-color / surface-color.
    _cli(cli, ["--json", "tab-color", "set", "#336699", "--workspace", ws, "--tab", f.t2])
    got_new = _cli_json(cli, ["tab-color", "get", "--workspace", ws, "--tab", f.t2])
    got_old = _cli_json(cli, ["surface-color", "get", "--workspace", ws, "--surface", f.t2])
    _must(got_new.get("custom_color") == got_old.get("custom_color") == "#336699", f"tab-color/surface-color disagree: {got_new} {got_old}")
    _cli(cli, ["surface-color", "clear", "--workspace", ws, "--surface", f.t2])

    # move-tab / move-surface, reorder-tab / reorder-surface (+ --before-tab / --before-surface).
    _cli(cli, ["move-tab", "--workspace", ws, "--tab", f.t2, "--area", f.area_b, "--focus", "false"])
    row = next(r for r in _tabs(c, ws) if r["id"] == f.t2)
    _must(row["area_id"] == f.area_b, f"move-tab --area did not move the tab: {row}")
    _cli(cli, ["move-surface", "--workspace", ws, "--surface", f.t2, "--pane", f.area_a, "--before-surface", f.t1, "--focus", "false"])
    row = next(r for r in _tabs(c, ws) if r["id"] == f.t2)
    _must(row["area_id"] == f.area_a, f"move-surface --pane did not move the tab: {row}")
    _must(row["index_in_area"] == 0, f"move-surface --before-surface did not place the tab first: {row}")
    _cli(cli, ["reorder-tab", "--workspace", ws, "--tab", f.t2, "--after-tab", f.t1])
    row = next(r for r in _tabs(c, ws) if r["id"] == f.t2)
    _must(row["index_in_area"] == 1, f"reorder-tab --after-tab did not place the tab second: {row}")
    _cli(cli, ["reorder-surface", "--workspace", ws, "--surface", f.t2, "--before-surface", f.t1])
    row = next(r for r in _tabs(c, ws) if r["id"] == f.t2)
    _must(row["index_in_area"] == 0, f"reorder-surface --before-surface did not place the tab first: {row}")

    # new-area / new-pane, drag-tab-to-split / drag-surface-to-split.
    areas_before = len(_areas(c, ws))
    made_new = _cli_json(cli, ["new-area", "--workspace", ws, "--direction", "down"], id_format="uuids")
    made_old = _cli_json(cli, ["new-pane", "--workspace", ws, "--direction", "down"], id_format="uuids")
    _must(len(_areas(c, ws)) == areas_before + 2, f"new-area / new-pane should each add an area: {made_new} {made_old}")
    for made in (made_new, made_old):
        tab_id = str(made.get("tab_id") or made.get("surface_id"))
        _call(c, "tab.close", {"workspace_id": ws, "tab_id": tab_id})
    time.sleep(0.3)
    _must(len(_areas(c, ws)) == areas_before, "closing the new areas' tabs should remove them")

    # Each dragged tab needs a sibling in its area, or the drag has nothing to split off.
    _call(c, "tab.create", {"workspace_id": ws, "area_id": f.area_b, "focus": False})
    areas_before = len(_areas(c, ws))
    _cli(cli, ["drag-tab-to-split", "--tab", f.t2, "right"], env=_cli_env({"C11_WORKSPACE_ID": ws}))
    _must(len(_areas(c, ws)) == areas_before + 1, "drag-tab-to-split should create an area")
    _cli(cli, ["drag-surface-to-split", "--surface", f.t3, "down"], env=_cli_env({"C11_WORKSPACE_ID": ws}))
    _must(len(_areas(c, ws)) == areas_before + 2, "drag-surface-to-split should create an area")

    # area-confirm / pane-confirm open a modal; only check both names are recognized.
    for cmd in ("area-confirm", "pane-confirm"):
        proc = _cli(cli, [cmd, "--help"], check=False)
        _must(proc.returncode == 0, f"`{cmd} --help` should succeed: {proc.stdout!r} {proc.stderr!r}")
    print("PASS: action CLI commands and flags (new == old)")


def test_cli_env_vars_target_the_same_tab(c: cmux, cli: str, f: Fixture) -> None:
    ws = f.ws
    token = f"env-{uuid.uuid4().hex[:8]}"
    _call(c, "tab.set_metadata", {
        "workspace_id": ws, "tab_id": f.t2, "mode": "merge", "source": "explicit",
        "metadata": {"title": token},
    })
    # Without a flag the command targets the tab named by the environment.
    for name in ("C11_TAB_ID", "C11_SURFACE_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"):
        env = _cli_env({name: f.t2, "C11_WORKSPACE_ID": ws, "CMUX_WORKSPACE_ID": ws})
        out = _cli_json(cli, ["get-metadata"], env=env)
        _must((out.get("metadata") or {}).get("title") == token, f"{name} did not target tab {f.t2}: {out}")
    # Flags win over the environment, in every spelling.
    env = _cli_env({"C11_TAB_ID": f.t1, "C11_WORKSPACE_ID": ws})
    for flag in ("--tab", "--surface", "--panel"):
        proc = _cli(cli, ["--json", "get-metadata", flag, f.t2], env=env, check=False)
        _must(proc.returncode == 0, f"get-metadata {flag} must be accepted: {proc.stdout!r} {proc.stderr!r}")
        out = json.loads(proc.stdout or "{}")
        _must((out.get("metadata") or {}).get("title") == token, f"{flag} did not override the environment: {out}")

    # `c11 mailbox tab-name` and `surface-name` print the same caller title.
    env = _cli_env({"C11_TAB_ID": f.t2, "C11_WORKSPACE_ID": ws})
    new_name = _cli(cli, ["mailbox", "tab-name"], env=env).stdout.strip()
    old_name = _cli(cli, ["mailbox", "surface-name"], env=env).stdout.strip()
    _must(new_name == old_name, f"mailbox tab-name {new_name!r} != surface-name {old_name!r}")

    # Metadata scope flags: --area and --pane address the same area.
    pane_token = f"area-{uuid.uuid4().hex[:6]}"
    env = _cli_env({"C11_WORKSPACE_ID": ws})
    _cli(cli, ["set-metadata", "--area", f.area_a, "--key", "role", "--value", pane_token], env=env)
    for flag in ("--area", "--pane"):
        out = _cli_json(cli, ["get-metadata", flag, f.area_a], env=env)
        _must((out.get("metadata") or {}).get("role") == pane_token, f"{flag} did not read the area metadata: {out}")
    _cli(cli, ["clear-metadata", "--pane", f.area_a, "--key", "role"], env=env)
    print("PASS: C11_TAB_ID / C11_SURFACE_ID / CMUX_* and --tab/--surface/--panel/--area/--pane agree")


def _last_screen_line(c: cmux, ws: str, tab_id: str) -> str:
    text = str(_call(c, "tab.read_text", {"workspace_id": ws, "tab_id": tab_id}).get("text") or "")
    lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def test_free_text_is_never_rewritten(c: cmux, cli: str, f: Fixture) -> None:
    """Text typed into a tab is data: flag-looking words arrive literally, old or new spelling."""
    ws = f.ws
    for token in ("--surface", "--pane", "--panel", "--tab", "--area"):
        for form in ("after --", "positional"):
            _cli(cli, ["send-key", "--workspace", ws, "--tab", f.t3, "ctrl+u"])
            if form == "after --":
                args = ["send", "--workspace", ws, "--tab", f.t3, "--no-submit", "--", token]
                env = None
            else:
                args = ["send", "--no-submit", token]
                env = _cli_env({"C11_TAB_ID": f.t3, "C11_WORKSPACE_ID": ws})
            _cli(cli, args, env=env)
            deadline = time.time() + 6.0
            line = ""
            while time.time() < deadline:
                line = _last_screen_line(c, ws, f.t3)
                if line.endswith(token):
                    break
                time.sleep(0.15)
            _must(line.endswith(token), f"send ({form}) of {token!r} did not arrive literally; last line {line!r}")
    _cli(cli, ["send-key", "--workspace", ws, "--tab", f.t3, "ctrl+u"])
    print("PASS: flag-looking free text reaches the tab literally")


# ---------------------------------------------------------------------------
# Older socket methods, params and refs beyond the basics
# ---------------------------------------------------------------------------

def _wait_for(pred, timeout: float = 6.0, step: float = 0.15) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(step)
    return pred()


def _area_of(c: cmux, ws: str, tab_id: str) -> str:
    return str(_tab_row(c, ws, tab_id).get("area_id") or "")


def _index_of(c: cmux, ws: str, tab_id: str) -> int:
    value = _tab_row(c, ws, tab_id).get("index_in_area")
    _must(isinstance(value, int), f"tab {tab_id} has no index_in_area: {_tab_row(c, ws, tab_id)}")
    return int(value)


def _spare_tab(c: cmux, ws: str, area_id: str) -> str:
    created = _call(c, "tab.create", {"workspace_id": ws, "area_id": area_id, "focus": False})
    tab_id = str(created.get("tab_id") or "")
    _must(bool(tab_id), f"tab.create returned no tab_id: {created}")
    time.sleep(0.2)
    return tab_id


def test_tab_action_and_send_key_old_methods(c: cmux, f: Fixture) -> None:
    ws = f.ws
    # surface.action (routed to the Misc domain) and tab.action are one handler.
    old_title, new_title = f"old-{uuid.uuid4().hex[:6]}", f"new-{uuid.uuid4().hex[:6]}"
    res = _call(c, "surface.action", {"workspace_id": ws, "surface_id": f.t2, "action": "rename", "title": old_title})
    _same(res.get("tab_id"), f.t2, "surface.action result tab_id")
    _same(res.get("surface_id"), f.t2, "surface.action result surface_id")
    _same(_tab_row(c, ws, f.t2).get("title"), old_title, "surface.action rename should retitle the tab")
    res = _call(c, "tab.action", {"workspace_id": ws, "tab_id": f.t2, "action": "rename", "title": new_title})
    _same(res.get("surface_id"), f.t2, "tab.action result surface_id")
    _same(_tab_row(c, ws, f.t2).get("title"), new_title, "tab.action rename should retitle the tab")
    for method, key in (("surface.action", "surface_id"), ("tab.action", "tab_id")):
        pinned = _call(c, method, {"workspace_id": ws, key: f.t2, "action": "pin"})
        _must(pinned.get("pinned") is True, f"{method} pin: {pinned}")
        unpinned = _call(c, method, {"workspace_id": ws, key: f.t2, "action": "unpin"})
        _must(unpinned.get("pinned") is False, f"{method} unpin: {unpinned}")

    # Off-main methods under the old names: surface.send_key and surface.clear_history.
    # `$((6*7))` makes the marker appear only in the command's output, never in its echo.
    marker = f"vk{uuid.uuid4().hex[:6]}"
    _call(c, "surface.send_text", {"workspace_id": ws, "surface_id": f.t3, "text": f"echo $((6*7)){marker}"})
    _call(c, "surface.send_key", {"workspace_id": ws, "surface_id": f.t3, "key": "enter"})
    _must(
        _wait_for(lambda: f"42{marker}" in str(_call(c, "tab.read_text", {"workspace_id": ws, "tab_id": f.t3}).get("text") or "")),
        "surface.send_key enter never ran the typed command",
    )
    marker = f"vk{uuid.uuid4().hex[:6]}"
    _call(c, "tab.send_text", {"workspace_id": ws, "tab_id": f.t3, "text": f"echo $((6*7)){marker}"})
    _call(c, "tab.send_key", {"workspace_id": ws, "tab_id": f.t3, "key": "enter"})
    _must(
        _wait_for(lambda: f"42{marker}" in str(_call(c, "tab.read_text", {"workspace_id": ws, "tab_id": f.t3}).get("text") or "")),
        "tab.send_key enter never ran the typed command",
    )
    for method, key in (("surface.clear_history", "surface_id"), ("tab.clear_history", "tab_id")):
        res = _call(c, method, {"workspace_id": ws, key: f.t3})
        _same(res.get("tab_id"), f.t3, f"{method} result tab_id")
        _same(res.get("surface_id"), f.t3, f"{method} result surface_id")

    # pane.confirm is an off-main method that opens a modal; a call without a title fails
    # before any dialog, so reaching that error proves the old name routes to the handler.
    old_err = _error_of(c, "pane.confirm", {"workspace_id": ws, "pane_id": f.area_a})
    new_err = _error_of(c, "area.confirm", {"workspace_id": ws, "area_id": f.area_a})
    _must(old_err.startswith("invalid_params") and "title" in old_err, f"pane.confirm without a title: {old_err!r}")
    _same(new_err, old_err, "pane.confirm and area.confirm should fail the same way")
    print("PASS: surface.action / surface.send_key / surface.clear_history / pane.confirm resolve to the new handlers")


def test_old_tab_layout_methods(c: cmux) -> None:
    f = Fixture(c)
    try:
        ws = f.ws
        # surface.split / tab.split
        before = len(_areas(c, ws))
        old_split = _call(c, "surface.split", {"workspace_id": ws, "surface_id": f.t1, "direction": "down"})
        _same(old_split.get("tab_id"), old_split.get("surface_id"), "surface.split tab_id/surface_id")
        time.sleep(0.3)
        _must(len(_areas(c, ws)) == before + 1, "surface.split should add an area")
        _call(c, "surface.close", {"workspace_id": ws, "surface_id": old_split["surface_id"]})
        time.sleep(0.3)
        _must(len(_areas(c, ws)) == before, "closing the split's only tab should remove its area")

        # surface.reorder / tab.reorder with before/after anchors in both spellings.
        steps = [
            ("surface.reorder", {"surface_id": f.t2, "before_surface_id": f.t1}, 0),
            ("tab.reorder", {"tab_id": f.t2, "after_tab_id": f.t1}, 1),
            ("tab.reorder", {"tab_id": f.t2, "before_tab_id": f.t1}, 0),
            ("surface.reorder", {"surface_id": f.t2, "after_surface_id": f.t1}, 1),
            ("tab.reorder", {"surface_id": f.t2, "before_tab_id": f.t1}, 0),
            ("surface.reorder", {"tab_id": f.t2, "after_surface_id": f.t1}, 1),
        ]
        for method, params, want in steps:
            _call(c, method, {"workspace_id": ws, **params})
            _same(_index_of(c, ws, f.t2), want, f"{method} {sorted(params)} should place the tab at index {want}")

        # surface.move / tab.move across areas, with before/after anchors and old/new area keys.
        mover = _spare_tab(c, ws, f.area_b)
        _call(c, "surface.move", {"workspace_id": ws, "surface_id": mover, "pane_id": f.area_a,
                                  "before_surface_id": f.t1, "focus": False})
        _same(_area_of(c, ws, mover), f.area_a, "surface.move should move the tab into the area")
        _same(_index_of(c, ws, mover), 0, "surface.move before_surface_id should place the tab first")
        _call(c, "tab.move", {"workspace_id": ws, "tab_id": mover, "area_id": f.area_b, "focus": False})
        _same(_area_of(c, ws, mover), f.area_b, "tab.move should move the tab back")
        _call(c, "tab.move", {"workspace_id": ws, "tab_id": mover, "area_id": f.area_a,
                              "after_tab_id": f.t1, "focus": False})
        _same(_area_of(c, ws, mover), f.area_a, "tab.move with after_tab_id should move the tab")
        _same(_index_of(c, ws, mover), _index_of(c, ws, f.t1) + 1, "tab.move after_tab_id should place the tab after the anchor")
        _call(c, "surface.move", {"workspace_id": ws, "surface_id": mover, "pane_id": f.area_b, "focus": False})
        _same(_area_of(c, ws, mover), f.area_b, "surface.move should move the tab back")

        # surface.drag_to_split / tab.drag_to_split need a sibling in the source area.
        for method, key, direction in (("surface.drag_to_split", "surface_id", "right"), ("tab.drag_to_split", "tab_id", "down")):
            sibling = _spare_tab(c, ws, f.area_b)
            before = len(_areas(c, ws))
            _call(c, method, {"workspace_id": ws, key: sibling, "direction": direction})
            time.sleep(0.3)
            _must(len(_areas(c, ws)) == before + 1, f"{method} should split the tab off into a new area")
            _must(_area_of(c, ws, sibling) not in (f.area_a, f.area_b), f"{method} should leave the tab in a new area")
        print("PASS: surface.split / reorder / move / drag_to_split resolve to the new handlers")
    finally:
        f.close()


def test_old_tab_presentation_methods(c: cmux, f: Fixture) -> None:
    ws = f.ws
    for method, key in (("surface.trigger_flash", "surface_id"), ("tab.trigger_flash", "tab_id")):
        res = _call(c, method, {"workspace_id": ws, key: f.t1})
        _same(res.get("tab_id"), f.t1, f"{method} result tab_id")
        _same(res.get("surface_id"), f.t1, f"{method} result surface_id")
    for method, key in (("surface.cancel_flash", "surface_id"), ("tab.cancel_flash", "tab_id")):
        res = _call(c, method, {"workspace_id": ws, key: f.t1})
        _same(res.get("surface_id"), f.t1, f"{method} result surface_id")

    for method, key, hex_ in (("surface.set_custom_color", "surface_id", "#336699"), ("tab.set_custom_color", "tab_id", "#996633")):
        res = _call(c, method, {"workspace_id": ws, key: f.t2, "hex": hex_})
        _same(res.get("custom_color"), hex_, f"{method} custom_color")
        _same(res.get("tab_id"), f.t2, f"{method} result tab_id")
    cleared = _call(c, "surface.set_custom_color", {"workspace_id": ws, "surface_id": f.t2, "clear": True})
    _must(cleared.get("cleared") is True and cleared.get("custom_color") is None, f"clear through the old method: {cleared}")

    # Title bar: visibility is workspace-wide, collapsed is per tab.
    try:
        _call(c, "surface.set_titlebar_visibility", {"workspace_id": ws, "surface_id": f.t1, "visible": False})
        _must(_call(c, "tab.get_titlebar_state", {"workspace_id": ws, "tab_id": f.t1}).get("visible") is False,
              "surface.set_titlebar_visibility should hide the title bar")
        _call(c, "tab.set_titlebar_visibility", {"workspace_id": ws, "tab_id": f.t1, "visible": True})
        _must(_call(c, "surface.get_titlebar_state", {"workspace_id": ws, "surface_id": f.t1}).get("visible") is True,
              "tab.set_titlebar_visibility should show the title bar")
    finally:
        _call(c, "tab.set_titlebar_visibility", {"workspace_id": ws, "tab_id": f.t1, "visible": True})
    _call(c, "surface.set_titlebar_collapsed", {"workspace_id": ws, "surface_id": f.t3, "collapsed": False})
    _must(_call(c, "tab.get_titlebar_state", {"workspace_id": ws, "tab_id": f.t3}).get("collapsed") is False,
          "surface.set_titlebar_collapsed should expand the title bar")
    _call(c, "tab.set_titlebar_collapsed", {"workspace_id": ws, "tab_id": f.t3, "collapsed": True})
    _must(_call(c, "surface.get_titlebar_state", {"workspace_id": ws, "surface_id": f.t3}).get("collapsed") is True,
          "tab.set_titlebar_collapsed should collapse the title bar")

    # surface.clear_metadata / tab.clear_metadata
    for method, key in (("surface.clear_metadata", "surface_id"), ("tab.clear_metadata", "tab_id")):
        marker = f"clr-{uuid.uuid4().hex[:6]}"
        _call(c, "tab.set_metadata", {"workspace_id": ws, "tab_id": f.t3, "mode": "merge", "source": "explicit",
                                      "metadata": {"vocab_clear": marker}})
        _same(_metadata(c, ws, f.t3).get("vocab_clear"), marker, "metadata should be set before clearing")
        _call(c, method, {"workspace_id": ws, key: f.t3, "keys": ["vocab_clear"], "source": "explicit"})
        _must("vocab_clear" not in _metadata(c, ws, f.t3), f"{method} did not clear the key")
    print("PASS: surface.trigger_flash / set_custom_color / set_titlebar_* / clear_metadata resolve to the new handlers")


def test_old_area_methods(c: cmux) -> None:
    f = Fixture(c)
    try:
        ws = f.ws

        # pane.create / area.create
        before = len(_areas(c, ws))
        old_made = _call(c, "pane.create", {"workspace_id": ws, "direction": "down"})
        new_made = _call(c, "area.create", {"workspace_id": ws, "direction": "down"})
        time.sleep(0.3)
        _must(len(_areas(c, ws)) == before + 2, f"pane.create / area.create should each add an area: {old_made} {new_made}")
        for made in (old_made, new_made):
            _same(made.get("area_id"), made.get("pane_id"), "area create area_id/pane_id")
            _call(c, "tab.close", {"workspace_id": ws, "tab_id": str(made.get("tab_id") or made.get("surface_id"))})
        time.sleep(0.3)
        _must(len(_areas(c, ws)) == before, "closing the created areas' tabs should remove them")

        # pane.resize / area.resize: the divider between the two side-by-side areas moves.
        grown = _call(c, "pane.resize", {"workspace_id": ws, "pane_id": f.area_a, "direction": "right", "amount": 40})
        _same(grown.get("area_id"), f.area_a, "pane.resize result area_id")
        _same(grown.get("pane_id"), f.area_a, "pane.resize result pane_id")
        _must(float(grown["new_divider_position"]) > float(grown["old_divider_position"]), f"pane.resize right should grow the area: {grown}")
        shrunk = _call(c, "area.resize", {"workspace_id": ws, "area_id": f.area_a, "direction": "left", "amount": 40})
        _must(float(shrunk["new_divider_position"]) < float(shrunk["old_divider_position"]), f"area.resize left should shrink the area: {shrunk}")

        # pane.swap / area.swap with every spelling of the area and target keys. Each swap
        # trades the two areas' selected tabs, so the owner of a given tab flips every time.
        rows = {str(r["id"]): r for r in _areas(c, ws)}
        sel_a = str(rows[f.area_a].get("selected_tab_id"))
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
            _same(_area_of(c, ws, sel_a), expected_area, f"{method} {sorted(params)} should move the selected tab")
            _same(res.get("source_area_id"), res.get("source_pane_id"), f"{method} result source_area_id/source_pane_id")
            _same(res.get("target_area_id"), res.get("target_pane_id"), f"{method} result target_area_id/target_pane_id")
            _same(res.get("source_tab_id"), res.get("source_surface_id"), f"{method} result source_tab_id/source_surface_id")
            _same(res.get("target_tab_id"), res.get("target_surface_id"), f"{method} result target_tab_id/target_surface_id")

        # pane.join / area.join: surface_id or area_id picks the tab, target_* the destination.
        joiner = _spare_tab(c, ws, f.area_b)
        _call(c, "pane.join", {"workspace_id": ws, "surface_id": joiner, "target_pane_id": f.area_a, "focus": False})
        _same(_area_of(c, ws, joiner), f.area_a, "pane.join should move the tab into the target area")
        _call(c, "area.join", {"workspace_id": ws, "tab_id": joiner, "target_area_id": f.area_b, "focus": False})
        _same(_area_of(c, ws, joiner), f.area_b, "area.join should move the tab into the target area")
        _call(c, "pane.join", {"workspace_id": ws, "surface_id": joiner, "target_area_ref": area_ref[f.area_a], "focus": False})
        _same(_area_of(c, ws, joiner), f.area_a, "pane.join with target_area_ref should move the tab")
        _call(c, "area.join", {"workspace_id": ws, "tab_id": joiner, "target_pane_ref": old_ref[f.area_b], "focus": False})
        _same(_area_of(c, ws, joiner), f.area_b, "area.join with target_pane_ref should move the tab")

        # pane.break / area.break detach a tab into a new workspace.
        for method, key in (("pane.break", "surface_id"), ("area.break", "tab_id")):
            breaker = _spare_tab(c, ws, f.area_b)
            res = _call(c, method, {"workspace_id": ws, key: breaker, "focus": False})
            new_ws = str(res.get("workspace_id") or "")
            _must(bool(new_ws) and new_ws != ws, f"{method} should move the tab into another workspace: {res}")
            try:
                _must(breaker not in [r["id"] for r in _tabs(c, ws)], f"{method} left the tab in the source workspace")
            finally:
                try:
                    c.close_workspace(new_ws)
                except Exception:
                    pass

        # pane.last / area.last: with two areas the alternate one is the other area.
        _call(c, "area.focus", {"workspace_id": ws, "area_id": f.area_a})
        res = _call(c, "pane.last", {"workspace_id": ws})
        _same(res.get("area_id"), f.area_b, "pane.last should target the other area")
        _same(res.get("pane_id"), f.area_b, "pane.last result pane_id")
        _same(_focused_area_id(c, ws), f.area_b, "pane.last should focus the other area")
        res = _call(c, "area.last", {"workspace_id": ws})
        _same(res.get("area_id"), f.area_a, "area.last should target the other area")
        _same(_focused_area_id(c, ws), f.area_a, "area.last should focus the other area")
        print("PASS: pane.create / resize / swap / join / break / last resolve to the new handlers")
    finally:
        f.close()


def test_old_ref_params_and_caller_keys(c: cmux, f: Fixture) -> None:
    ws = f.ws
    token = f"ref-{uuid.uuid4().hex[:8]}"
    _call(c, "tab.set_metadata", {"workspace_id": ws, "tab_id": f.t2, "mode": "merge", "source": "explicit", "metadata": {"title": token}})
    t2_row = next(r for r in _tabs(c, ws) if r["id"] == f.t2)
    ordinal = _ordinal(t2_row["ref"], "tab")
    # *_ref params: the canonical name and the older one, with either ref prefix.
    for key, value in (("tab_ref", f"tab:{ordinal}"), ("surface_ref", f"surface:{ordinal}"),
                       ("tab_ref", f"surface:{ordinal}"), ("surface_ref", f"tab:{ordinal}"),
                       ("panel_ref", f"tab:{ordinal}")):
        res = _call(c, "tab.get_metadata", {"workspace_id": ws, key: value})
        _same((res.get("metadata") or {}).get("title"), token, f"{key}={value} should address tab {f.t2}")
    a_row = next(r for r in _areas(c, ws) if r["id"] == f.area_a)
    a_ordinal = _ordinal(a_row["ref"], "area")
    for key, value in (("area_ref", f"area:{a_ordinal}"), ("pane_ref", f"pane:{a_ordinal}"),
                       ("area_ref", f"pane:{a_ordinal}"), ("pane_ref", f"area:{a_ordinal}")):
        res = _call(c, "area.tabs", {"workspace_id": ws, key: value})
        _must(f.t2 in _ids(_rows(res, "tabs")), f"{key}={value} should address area {f.area_a}: {res}")

    # `area` is the older `pane` placement param (config.launch). Placement conflicts are
    # rejected before anything launches, so a throwaway saved config exercises the key safely.
    name = f"c11-vocab-{uuid.uuid4().hex[:8]}"
    _call(c, "config.save", {"name": name, "harness": "claude"})
    try:
        errors = {}
        for label, params in (("area", {"area": a_row["ref"]}), ("pane", {"pane": f"pane:{a_ordinal}"}),
                              ("area_id", {"area_id": f.area_a}), ("pane_id", {"pane_id": f.area_a})):
            errors[label] = _error_of(c, "config.launch", {"config": name, "new_workspace": True, **params})
            _must(errors[label].startswith("placement_conflict"),
                  f"config.launch with {label} and new_workspace should be a placement conflict: {errors[label]!r}")
    finally:
        try:
            _call(c, "config.rm", {"config": name})
        except cmuxError:
            pass

    # flag.raise takes the caller as caller_surface_id or caller_tab_id; both keys are
    # written, and flag.lower clears both.
    for caller_key in ("caller_surface_id", "caller_tab_id"):
        for tab_key in ("surface_id", "tab_id"):
            reason = f"vocab {caller_key} {tab_key}"
            raised = _call(c, "flag.raise", {"workspace_id": ws, tab_key: f.t2, "reason": reason, caller_key: f.t1})
            _same(raised.get("flag"), reason, "flag.raise result flag")
            _same(raised.get("caller_surface_id"), f.t1, f"flag.raise result caller_surface_id ({caller_key})")
            _same(raised.get("caller_tab_id"), f.t1, f"flag.raise result caller_tab_id ({caller_key})")
            md = _metadata(c, ws, f.t2)
            _same(md.get("flag_caller_surface_id"), f.t1, f"flag_caller_surface_id after raise ({caller_key}, {tab_key})")
            _same(md.get("flag_caller_tab_id"), f.t1, f"flag_caller_tab_id after raise ({caller_key}, {tab_key})")
            _call(c, "flag.lower", {"workspace_id": ws, tab_key: f.t2})
            md = _metadata(c, ws, f.t2)
            for key in ("flag", "flag_caller_surface_id", "flag_caller_tab_id"):
                _must(key not in md, f"flag.lower left {key} behind ({caller_key}, {tab_key}): {md}")
    print("PASS: *_ref params, area->pane, caller_surface_id/caller_tab_id, flag_caller_* clearing")


def test_workspace_apply_ref_maps(c: cmux) -> None:
    """workspace.apply returns tabRefs/areaRefs (canonical) beside surfaceRefs/paneRefs (older), value-converted."""
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
        maps = {name: res.get(name) for name in ("tabRefs", "surfaceRefs", "areaRefs", "paneRefs")}
        for name, value in maps.items():
            _must(isinstance(value, dict) and sorted(value) == ["a", "b"], f"workspace.apply {name} should map both plan ids: {value!r}")
        for plan_id in ("a", "b"):
            _same(_ordinal(maps["tabRefs"][plan_id], "tab"), _ordinal(maps["surfaceRefs"][plan_id], "surface"),
                  f"tabRefs/surfaceRefs ordinal for plan id {plan_id}")
            _same(_ordinal(maps["areaRefs"][plan_id], "area"), _ordinal(maps["paneRefs"][plan_id], "pane"),
                  f"areaRefs/paneRefs ordinal for plan id {plan_id}")
        _must(_ordinal(maps["tabRefs"]["a"], "tab") != _ordinal(maps["tabRefs"]["b"], "tab"), "the two tabs should have distinct refs")
        _same(maps["areaRefs"]["a"], maps["areaRefs"]["b"], "both plan tabs live in one area")
    finally:
        if ws_ref:
            try:
                _call(c, "workspace.close", {"workspace_id": ws_ref})
            except cmuxError:
                pass
    print("PASS: workspace.apply carries tabRefs/surfaceRefs and areaRefs/paneRefs with matching ordinals and prefixes")


# ---------------------------------------------------------------------------

def main() -> int:
    cli = find_cli_binary()
    with cmux(SOCKET_PATH) as c:
        fixture = Fixture(c)
        try:
            test_read_methods_resolve_to_same_objects(c, fixture)
            test_old_param_names_address_the_same_tab(c, fixture)
            test_write_methods_cross_over(c, fixture)
            test_notification_create_aliases(c, fixture)
            test_tab_action_and_send_key_old_methods(c, fixture)
            test_old_tab_presentation_methods(c, fixture)
            test_old_ref_params_and_caller_keys(c, fixture)
            test_dual_keys_in_list_responses(c, fixture)
            test_dual_keys_in_create_split_identify(c, fixture)
            test_dual_keys_in_tree_json(cli, fixture)
            test_flag_caller_metadata_keys(c, cli, fixture)
            test_cli_read_command_aliases(cli, fixture)
            test_cli_env_vars_target_the_same_tab(c, cli, fixture)
            test_cli_action_command_aliases(c, cli, fixture)
            test_free_text_is_never_rewritten(c, cli, fixture)
        finally:
            fixture.close()
        # These reshape the layout, so each gets a workspace of its own.
        test_old_tab_layout_methods(c)
        test_old_area_methods(c)
        test_workspace_apply_ref_maps(c)
    print("PASS: vocabulary aliases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
