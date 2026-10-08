#!/usr/bin/env python3
"""Vocabulary regression for the CLI side, against a fake socket server. Needs no app.

The bundled CLI is driven against an in-process fake that speaks the v2 socket protocol
(and the v1 text protocol), as three generations of app, one per version-skew tier:

- panel:   advertises the feature `vocabulary.workspace_area_panel`. Knows `panel.*` /
           `area.*` (and lists `tab.list` so a v0.67 CLI keeps its tab tier). Emits only
           `panel_*` / `area_*` keys, `panels` / `areas`, `panel:N` / `area:N` refs.
- tab:     v0.67.0 and pre-panel nightlies. Methods include `tab.list`, no panel feature.
           Knows `tab.*` / `area.*` and the `surface.*` / `pane.*` aliases, rejects `panel.*`
           with method_not_found, and silently IGNORES `panel_*` param keys (the danger the CLI
           must avoid). Emits `tab_*` + `surface_*` and `area_*` + `pane_*` keys, `tab:N` refs.
- surface: before the tab vocabulary. Knows only `surface.*` / `pane.*` (and `tab.action`),
           legacy keys and `surface:N` / `pane:N` refs.

For each tier the CLI must send the right method names, param keys (nested ones, and the
`target_` / `source_` / `before_` / `after_` / `caller_` families included), ref values and
`panel.action` action values; probe `system.capabilities` once; never retry a rejected
request; leave user data (metadata, free text, titles) untouched; and print canonical output
(`panel:N` refs, `panel_*` keys, `panels`) whatever the app emitted.

Also pinned, against the panel app (items from the original review):

- tmux format variables `#{pane_id}`, `#{pane_index}`, `#{surface_id}`, `#{panel_id}` keep
  rendering through `display-message` (the tmux shim keeps tmux vocabulary).
- `default-agent launch --in-panel` / `--in-tab` / `--in-surface` / `--area` / `--pane`
  compose the v1 wire the app understands (`--in-surface`, `--pane`).
- reorder/move flags (`--before-panel`, `--before-tab`, `--after-surface`, ...) reach the app as
  canonical params, in every spelling.

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
from typing import Any, Dict, Iterator, List, Optional, Sequence, Set, Tuple

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

# Areas: (uuid, ordinal, tmux index). Panels: (uuid, ordinal, area uuid, title).
AREAS = [(A1, 1, 7), (A2, 2, 8)]
PANELS = [(T1, 1, A1, "leader"), (T2, 2, A1, "second"), (T3, 3, A2, "teammate")]

ID_ENV_KEYS = (
    "C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID", "C11_WORKSPACE_ID",
    "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID",
    "C11_PANEL_NUM", "C11_TAB_NUM", "CMUX_PANEL_NUM", "CMUX_TAB_NUM",
    "TMUX", "TMUX_PANE",
)

TIERS = ("panel", "tab", "surface")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


# ---------------------------------------------------------------------------
# The wire contract, written out independently of the CLI (spec sections 1, 3, 5)
# ---------------------------------------------------------------------------

# (panel_*, tab_*, surface_*): the 37 triples. App output carries panel only; tab and surface are input only.
PANEL_KEYS: List[Tuple[str, str, str]] = [
    ("panel_id", "tab_id", "surface_id"),
    ("panel_ref", "tab_ref", "surface_ref"),
    ("panel_ids", "tab_ids", "surface_ids"),
    ("panel_refs", "tab_refs", "surface_refs"),
    ("source_panel_id", "source_tab_id", "source_surface_id"),
    ("source_panel_ref", "source_tab_ref", "source_surface_ref"),
    ("target_panel_id", "target_tab_id", "target_surface_id"),
    ("target_panel_ref", "target_tab_ref", "target_surface_ref"),
    ("before_panel_id", "before_tab_id", "before_surface_id"),
    ("after_panel_id", "after_tab_id", "after_surface_id"),
    ("created_panel_id", "created_tab_id", "created_surface_id"),
    ("created_panel_ref", "created_tab_ref", "created_surface_ref"),
    ("selected_panel_id", "selected_tab_id", "selected_surface_id"),
    ("selected_panel_ref", "selected_tab_ref", "selected_surface_ref"),
    ("focused_panel_id", "focused_tab_id", "focused_surface_id"),
    ("focused_panel_ref", "focused_tab_ref", "focused_surface_ref"),
    ("caller_panel_id", "caller_tab_id", "caller_surface_id"),
    ("flag_caller_panel_id", "flag_caller_tab_id", "flag_caller_surface_id"),
    ("affected_panel_ids", "affected_tab_ids", "affected_surface_ids"),
    ("panel_type", "tab_type", "surface_type"),
    ("panel_title", "tab_title", "surface_title"),
    ("panel_index", "tab_index", "surface_index"),
    ("panel_index_in_area", "tab_index_in_area", "surface_index_in_pane"),
    ("panel_selected_in_area", "tab_selected_in_area", "surface_selected_in_pane"),
    ("is_browser_panel", "is_browser_tab", "is_browser_surface"),
    ("panel_pinned", "tab_pinned", "surface_pinned"),
    ("panel_focused", "tab_focused", "surface_focused"),
    ("panel_created_at", "tab_created_at", "surface_created_at"),
    ("panel_age_seconds", "tab_age_seconds", "surface_age_seconds"),
    ("panel_context", "tab_context", "surface_context"),
    ("panel_view_first_responder", "tab_view_first_responder", "surface_view_first_responder"),
    ("runtime_panel_ready", "runtime_tab_ready", "runtime_surface_ready"),
    ("runtime_panel_created_at", "runtime_tab_created_at", "runtime_surface_created_at"),
    ("runtime_panel_age_seconds", "runtime_tab_age_seconds", "runtime_surface_age_seconds"),
    ("panel_count", "tab_count", "surface_count"),
    ("terminal_panels", "terminal_tabs", "terminal_panels"),
    ("panelRefs", "tabRefs", "surfaceRefs"),
]

# (area_*, pane_*): the 10 pairs. Tab-era apps already said area_*; only surface-era apps say pane_*.
AREA_KEYS: List[Tuple[str, str]] = [
    ("area_id", "pane_id"),
    ("area_ref", "pane_ref"),
    ("target_area_id", "target_pane_id"),
    ("target_area_ref", "target_pane_ref"),
    ("source_area_id", "source_pane_id"),
    ("source_area_ref", "source_pane_ref"),
    ("index_in_area", "index_in_pane"),
    ("selected_in_area", "selected_in_pane"),
    ("area_index", "pane_index"),
    ("areaRefs", "paneRefs"),
]

_PANEL_SET = {p for p, _, _ in PANEL_KEYS}
_TAB_SET = {t for _, t, _ in PANEL_KEYS}
_SURFACE_SET = {s for _, _, s in PANEL_KEYS}
_AREA_SET = {a for a, _ in AREA_KEYS}
_PANE_SET = {p for _, p in AREA_KEYS}

# Param keys an app of each tier does not understand (or understands only as a deprecated alias).
FORBIDDEN_KEYS: Dict[str, Set[str]] = {
    "panel": (_TAB_SET | _SURFACE_SET | _PANE_SET) - (_PANEL_SET | _AREA_SET),
    "tab": (_PANEL_SET | _SURFACE_SET | _PANE_SET) - (_TAB_SET | _AREA_SET),
    "surface": (_PANEL_SET | _TAB_SET | _AREA_SET) - (_SURFACE_SET | _PANE_SET),
}

# Param values that are user data: never rewritten, never walked.
OPAQUE_PARAM_KEYS = {"metadata", "value", "payload", "env", "text", "body", "title", "prompt"}

# `panel.action` action values, canonical -> tab spelling (tiers 2 and 3).
TAB_ACTIONS = {
    "reload_panel": "reload_tab",
    "duplicate_panel": "duplicate_tab",
    "new_terminal_panel_to_right": "new_terminal_tab_to_right",
    "new_browser_panel_to_right": "new_browser_tab_to_right",
    "close_other_panels": "close_other_tabs",
}

_HANDLE_RE = re.compile(r"^(panel|tab|surface|area|pane):(\d+)$")


def downgrade_method(method: str, tier: str) -> str:
    """The method name a tier's app knows for a canonical method."""
    if tier == "panel":
        return method
    if tier == "tab":
        if method.startswith("panel."):
            return "tab." + method[len("panel."):]
        if method == "area.panels":
            return "area.tabs"
        if method == "notification.create_for_panel":
            return "notification.create_for_tab"
        if method.startswith("browser.panel."):
            return "browser.tab." + method[len("browser.panel."):]
        return method
    if method == "panel.action":
        return "tab.action"
    if method.startswith("panel."):
        return "surface." + method[len("panel."):]
    if method == "area.panels":
        return "pane.surfaces"
    if method.startswith("area."):
        return "pane." + method[len("area."):]
    if method == "notification.create_for_panel":
        return "notification.create_for_surface"
    if method.startswith("browser.panel."):
        return "browser.tab." + method[len("browser.panel."):]
    return method


def _downgrade_key(key: str, tier: str) -> str:
    if tier == "tab":
        for panel, tab, _ in PANEL_KEYS:
            if key == panel:
                return tab
        return key
    if tier == "surface":
        for panel, tab, surface in PANEL_KEYS:
            if key in (panel, tab):
                return surface
        for area, pane in AREA_KEYS:
            if key == area:
                return pane
    return key


def _downgrade_ref(value: str, tier: str) -> str:
    m = _HANDLE_RE.match(value)
    if not m:
        return value
    prefix, n = m.group(1), m.group(2)
    if tier == "tab" and prefix == "panel":
        return f"tab:{n}"
    if tier == "surface":
        if prefix in ("panel", "tab"):
            return f"surface:{n}"
        if prefix == "area":
            return f"pane:{n}"
    return value


class OneOf:
    """An expectation that accepts any of several values (a user-typed alias the CLI may pass through)."""

    def __init__(self, *values: Any) -> None:
        self.values = values

    def matches(self, actual: Any) -> bool:
        return actual in self.values

    def __repr__(self) -> str:
        return "OneOf" + repr(self.values)


class Tiered:
    """A value that depends on the tier (already downgraded by the author)."""

    def __init__(self, panel: Any, tab: Any, surface: Any) -> None:
        self.by_tier = {"panel": panel, "tab": tab, "surface": surface}


def typed_ref(prefix: str, n: int) -> Tiered:
    """A ref the operator typed with a possibly old prefix, and what each tier's app must receive.

    The CLI may pass an old prefix through to a panel app (it resolves every spelling), so tier 1
    accepts the typed value or its canonical form. Older tiers get their own vocabulary."""
    typed = f"{prefix}:{n}"
    if prefix in ("panel", "tab", "surface"):
        return Tiered(
            panel=OneOf(typed, f"panel:{n}"),
            tab=OneOf(f"tab:{n}", typed) if prefix == "surface" else f"tab:{n}",
            surface=f"surface:{n}",
        )
    return Tiered(
        panel=OneOf(typed, f"area:{n}"),
        tab=OneOf(typed, f"area:{n}"),
        surface=f"pane:{n}",
    )


def ref_or_uuid(prefix: str, n: int, uuid: str) -> Tiered:
    """A canonical handle the CLI may pass through as a ref or resolve to the UUID first (tmux verbs)."""
    kind_old = "pane" if prefix == "area" else "surface"
    return Tiered(
        panel=OneOf(f"{prefix}:{n}", uuid),
        tab=OneOf(f"tab:{n}" if prefix == "panel" else f"{prefix}:{n}", uuid),
        surface=OneOf(f"{kind_old}:{n}", uuid),
    )


def text_of(text: str) -> OneOf:
    """Free text as typed, with or without the line ending a send command may append."""
    return OneOf(text, text + "\n", text + "\r")


def downgrade_params(value: Any, tier: str) -> Any:
    """Canonical params as the tier's app must receive them: keys at every depth (never inside
    user data), ref values, and `panel.action` action values."""
    if isinstance(value, Tiered):
        return value.by_tier[tier]
    if isinstance(value, OneOf):
        return value
    if isinstance(value, str):
        return _downgrade_ref(value, tier)
    if isinstance(value, list):
        return [downgrade_params(v, tier) for v in value]
    if isinstance(value, dict):
        out: Dict[str, Any] = {}
        for key, child in value.items():
            out[_downgrade_key(key, tier)] = child if key in OPAQUE_PARAM_KEYS else downgrade_params(child, tier)
        return out
    return value


def expected_call(method: str, params: Dict[str, Any], tier: str) -> Tuple[str, Dict[str, Any]]:
    out = downgrade_params(params, tier)
    if tier != "panel" and method == "panel.action" and isinstance(out.get("action"), str):
        out["action"] = TAB_ACTIONS.get(out["action"], out["action"])
    return downgrade_method(method, tier), out


def subset_mismatch(expected: Any, actual: Any, path: str = "") -> Optional[str]:
    """None when `actual` carries everything `expected` says; otherwise where it differs."""
    if isinstance(expected, OneOf):
        return None if expected.matches(actual) else f"{path or '<root>'}: {actual!r} not in {expected}"
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return f"{path or '<root>'}: expected an object, got {actual!r}"
        for key, child in expected.items():
            if key not in actual:
                return f"{path}.{key}: missing (have {sorted(actual)})"
            problem = subset_mismatch(child, actual[key], f"{path}.{key}")
            if problem:
                return problem
        return None
    return None if expected == actual else f"{path or '<root>'}: {actual!r} != {expected!r}"


def _walk_params(value: Any, path: str = "") -> Iterator[Tuple[str, Optional[str], Any]]:
    """(path, key, value) for every dict entry and (path, None, value) for every scalar,
    never entering user-data values."""
    if isinstance(value, dict):
        for key, child in value.items():
            yield (path, key, child)
            if key not in OPAQUE_PARAM_KEYS:
                yield from _walk_params(child, f"{path}.{key}")
    elif isinstance(value, list):
        for idx, child in enumerate(value):
            yield from _walk_params(child, f"{path}[{idx}]")
    else:
        yield (path, None, value)


def param_violations(tier: str, method: str, params: Dict[str, Any]) -> List[str]:
    out: List[str] = []
    for path, key, value in _walk_params(params):
        # The browsing-context key of `browser.*` commands is `surface_id` in every vocabulary.
        if key in FORBIDDEN_KEYS[tier] and not (method.startswith("browser.") and key == "surface_id"):
            out.append(f"{method}: a {tier} app does not take param key {path}.{key}")
        if key is None and isinstance(value, str):
            if tier == "tab" and re.match(r"^panel:\d+$", value):
                out.append(f"{method}: ref {value!r} at {path} on a tab app")
            if tier == "surface" and re.match(r"^(panel|tab|area):\d+$", value):
                out.append(f"{method}: ref {value!r} at {path} on a surface app")
    return out


# ---------------------------------------------------------------------------
# The fake app
# ---------------------------------------------------------------------------

GENERIC_PANEL_METHODS = {
    "panel.focus", "panel.move", "panel.reorder", "panel.send_text", "panel.send_key", "panel.action",
    "panel.close", "panel.set_metadata", "panel.get_metadata", "panel.clear_metadata", "panel.read_text",
    "panel.trigger_flash", "panel.cancel_flash", "panel.refresh", "panel.set_custom_color",
    "panel.drag_to_split", "panel.clear_history",
}
GENERIC_AREA_METHODS = {
    "area.swap", "area.join", "area.break", "area.focus", "area.resize", "area.last", "area.confirm",
}


class FakeApp:
    def __init__(self, tier: str, probe: str = "normal") -> None:
        assert tier in TIERS and probe in ("normal", "error", "empty")
        self.tier = tier
        self.probe = probe
        self.lock = threading.Lock()
        self.v2: List[Tuple[str, Dict[str, Any]]] = []
        self.v1: List[str] = []
        self.violations: List[str] = []
        self.unhandled: List[str] = []
        self.fail_once: Dict[str, str] = {}   # native method -> error code, consumed on first hit
        self.split_done = False

    # -- vocabulary ----------------------------------------------------------

    @property
    def panel_prefix(self) -> str:
        return {"panel": "panel", "tab": "tab", "surface": "surface"}[self.tier]

    @property
    def area_prefix(self) -> str:
        return "pane" if self.tier == "surface" else "area"

    def panel_fields(self, uuid: str, n: int, prefix: str = "") -> Dict[str, Any]:
        """The panel's id and ref keys the way this tier's app emits them."""
        if self.tier == "panel":
            return {f"{prefix}panel_id": uuid, f"{prefix}panel_ref": f"panel:{n}"}
        if self.tier == "tab":
            return {f"{prefix}tab_id": uuid, f"{prefix}tab_ref": f"tab:{n}",
                    f"{prefix}surface_id": uuid, f"{prefix}surface_ref": f"surface:{n}"}
        return {f"{prefix}surface_id": uuid, f"{prefix}surface_ref": f"surface:{n}"}

    def area_fields(self, uuid: str, n: int, prefix: str = "") -> Dict[str, Any]:
        if self.tier == "panel":
            return {f"{prefix}area_id": uuid, f"{prefix}area_ref": f"area:{n}"}
        if self.tier == "tab":
            return {f"{prefix}area_id": uuid, f"{prefix}area_ref": f"area:{n}",
                    f"{prefix}pane_id": uuid, f"{prefix}pane_ref": f"pane:{n}"}
        return {f"{prefix}pane_id": uuid, f"{prefix}pane_ref": f"pane:{n}"}

    def panel_list_payload(self, rows: List[Dict[str, Any]]) -> Dict[str, Any]:
        if self.tier == "panel":
            return {"panels": rows}
        if self.tier == "tab":
            return {"tabs": rows, "surfaces": rows}
        return {"surfaces": rows}

    def area_list_payload(self, rows: List[Dict[str, Any]]) -> Dict[str, Any]:
        if self.tier == "panel":
            return {"areas": rows}
        if self.tier == "tab":
            return {"areas": rows, "panes": rows}
        return {"panes": rows}

    # -- model ---------------------------------------------------------------

    def _areas(self) -> List[Tuple[str, int, int]]:
        return AREAS + ([(NEW_A, 3, 9)] if self.split_done else [])

    def _panels(self) -> List[Tuple[str, int, str, str]]:
        return PANELS + ([(NEW_T, 4, NEW_A, "split")] if self.split_done else [])

    def _panel_by_handle(self, handle: str) -> Tuple[str, int, str, str]:
        for panel in self._panels():
            if handle in (panel[0], f"panel:{panel[1]}", f"tab:{panel[1]}", f"surface:{panel[1]}"):
                return panel
        raise KeyError(handle)

    def _area_by_handle(self, handle: str) -> Tuple[str, int, int]:
        for area in self._areas():
            if handle in (area[0], f"area:{area[1]}", f"pane:{area[1]}"):
                return area
        raise KeyError(handle)

    def _panel_keys_read(self) -> Tuple[str, ...]:
        """The param keys an app of this tier reads for a panel handle."""
        if self.tier == "panel":
            return ("panel_id", "panel_ref", "tab_id", "tab_ref", "surface_id", "surface_ref")
        if self.tier == "tab":
            return ("tab_id", "tab_ref", "surface_id", "surface_ref")
        return ("surface_id", "surface_ref")

    def _area_keys_read(self) -> Tuple[str, ...]:
        return ("pane_id", "pane_ref") if self.tier == "surface" else ("area_id", "area_ref", "pane_id", "pane_ref")

    def _target_panel(self, params: Dict[str, Any]) -> Optional[Tuple[str, int, str, str]]:
        # A key this tier does not read is ignored, exactly like the real older apps do.
        for key in self._panel_keys_read():
            if params.get(key):
                try:
                    return self._panel_by_handle(str(params[key]))
                except KeyError:
                    return None
        return None

    def _target_area(self, params: Dict[str, Any]) -> Optional[Tuple[str, int, int]]:
        for key in self._area_keys_read():
            if params.get(key):
                try:
                    return self._area_by_handle(str(params[key]))
                except KeyError:
                    return None
        return None

    # -- rows ----------------------------------------------------------------

    def _panel_row(self, panel: Tuple[str, int, str, str]) -> Dict[str, Any]:
        uid, n, aid, title = panel
        area = self._area_by_handle(aid)
        row: Dict[str, Any] = {
            "id": uid, "ref": f"{self.panel_prefix}:{n}", "title": title,
            "index": n, "selected": uid == T1, "focused": uid == T1,
        }
        row.update(self.area_fields(aid, area[1]))
        return row

    def _area_row(self, area: Tuple[str, int, int]) -> Dict[str, Any]:
        aid, n, index = area
        panels = [p for p in self._panels() if p[2] == aid]
        row: Dict[str, Any] = {"id": aid, "ref": f"{self.area_prefix}:{n}", "index": index}
        uuids, ordinals = [p[0] for p in panels], [p[1] for p in panels]
        if self.tier == "panel":
            row.update({"panel_ids": uuids, "panel_refs": [f"panel:{o}" for o in ordinals]})
        elif self.tier == "tab":
            row.update({"tab_ids": uuids, "surface_ids": uuids,
                        "tab_refs": [f"tab:{o}" for o in ordinals], "surface_refs": [f"surface:{o}" for o in ordinals]})
        else:
            row.update({"surface_ids": uuids, "surface_refs": [f"surface:{o}" for o in ordinals]})
        return row

    def _focus_block(self, panel: Optional[Tuple[str, int, str, str]] = None) -> Dict[str, Any]:
        panel = panel or PANELS[0]
        area = self._area_by_handle(panel[2])
        block: Dict[str, Any] = {
            "workspace_id": WS, "workspace_ref": "workspace:1",
            "window_id": WIN, "window_ref": "window:1",
        }
        block.update(self.area_fields(area[0], area[1]))
        block.update(self.panel_fields(panel[0], panel[1]))
        if self.tier == "panel":
            block["panel_type"] = "terminal"
        elif self.tier == "tab":
            block.update({"tab_type": "terminal", "surface_type": "terminal"})
        else:
            block["surface_type"] = "terminal"
        return block

    # -- dispatch ------------------------------------------------------------

    def to_canonical(self, method: str) -> Optional[str]:
        """The canonical method an app of this tier maps `method` to; None when it does not know it."""
        t = self.tier
        if method.startswith("panel.") or method == "area.panels" or method == "notification.create_for_panel" \
                or method.startswith("browser.panel."):
            return method if t == "panel" else None
        if method == "tab.action" and t == "surface":
            return "panel.action"
        if method.startswith("tab."):
            return None if t == "surface" else "panel." + method[len("tab."):]
        if method.startswith("surface."):
            return "panel." + method[len("surface."):]
        if method in ("area.tabs", "pane.surfaces"):
            if method == "area.tabs" and t == "surface":
                return None
            return "area.panels"
        if method.startswith("area.") and t == "surface":
            return None
        if method.startswith("pane."):
            return "area." + method[len("pane."):]
        if method.startswith("browser.tab."):
            return "browser.panel." + method[len("browser.tab."):]
        if method in ("notification.create_for_tab", "notification.create_for_surface"):
            if method.endswith("_tab") and t == "surface":
                return None
            return "notification.create_for_panel"
        return method

    def capabilities(self) -> Dict[str, Any]:
        base = ["system.ping", "system.capabilities", "system.identify", "window.list",
                "workspace.list", "workspace.current", "workspace.select", "browser.url.get"]
        names = ["list", "current", "focus", "move", "reorder", "send_text", "split"]
        if self.tier == "panel":
            methods = base + [f"panel.{n}" for n in names] + ["area.list", "area.panels", "tab.list"]
            features = [{"id": "vocabulary.workspace_area_panel", "version": 1, "enabled": True},
                        {"id": "send.explicit_panel", "version": 1, "enabled": True}]
        elif self.tier == "tab":
            methods = base + [f"tab.{n}" for n in names] + ["area.list", "area.tabs"]
            # v0.67 advertised its own feature ids; none of them is the panel vocabulary.
            features = [{"id": "vocabulary.workspace_area_tab", "version": 1, "enabled": True},
                        {"id": "send.explicit_tab", "version": 1, "enabled": True}]
        else:
            methods = base + [f"surface.{n}" for n in names] + ["pane.list", "pane.surfaces", "tab.action"]
            features = []
        result: Dict[str, Any] = {"protocol": "cmux-socket", "version": 2, "methods": sorted(methods)}
        if features:
            result["features"] = features
            result["features_version"] = 1
        if self.probe == "empty":
            return {"protocol": "cmux-socket", "version": 2, "methods": []}
        return result

    def handle_v2(self, method: str, params: Dict[str, Any]) -> Tuple[bool, Any]:
        with self.lock:
            self.v2.append((method, params))
            code = self.fail_once.pop(method, None)
            if code:
                return False, {"code": code, "message": f"injected {code}"}
            if method == "system.capabilities" and self.probe == "error":
                return False, {"code": "method_not_found", "message": "Unknown method: system.capabilities"}

            canonical = self.to_canonical(method)
            if canonical is None:
                self.violations.append(f"method {method} is unknown to a {self.tier} app")
                return False, {"code": "method_not_found", "message": f"Unknown method: {method}"}
            if method != downgrade_method(canonical, self.tier):
                self.violations.append(f"{method} sent to a {self.tier} app; its spelling is {downgrade_method(canonical, self.tier)}")
            problems = param_violations(self.tier, method, params)
            self.violations.extend(problems)
            return self._dispatch(canonical, params)

    def _echo(self, params: Dict[str, Any]) -> Dict[str, Any]:
        out: Dict[str, Any] = {"workspace_id": WS, "workspace_ref": "workspace:1", "ok": True}
        panel = self._target_panel(params)
        if panel:
            out.update(self.panel_fields(panel[0], panel[1]))
        area = self._target_area(params)
        if area:
            out.update(self.area_fields(area[0], area[1]))
        return out

    def _dispatch(self, method: str, params: Dict[str, Any]) -> Tuple[bool, Any]:
        if method == "system.capabilities":
            return True, self.capabilities()
        if method == "system.ping":
            return True, {"pong": True}
        if method == "system.identify":
            result: Dict[str, Any] = {"focused": self._focus_block()}
            caller = params.get("caller")
            if isinstance(caller, dict):
                panel = self._target_panel(caller)
                result["caller"] = self._focus_block(panel)
            return True, result
        if method == "window.list":
            return True, {"windows": [{"id": WIN, "ref": "window:1", "workspace_id": WS, "workspace_ref": "workspace:1"}]}
        if method == "workspace.list":
            return True, {"workspaces": [{"id": WS, "ref": "workspace:1", "index": 1, "title": "demo", "selected": True}]}
        if method == "workspace.current":
            return True, {"workspace_id": WS, "workspace_ref": "workspace:1"}
        if method == "workspace.select":
            return True, {"workspace_id": WS, "workspace_ref": "workspace:1", "ok": True}
        if method in ("panel.list", "panel.health"):
            rows = [self._panel_row(p) for p in self._panels()]
            return True, {"workspace_id": WS, "workspace_ref": "workspace:1", **self.panel_list_payload(rows)}
        if method == "area.list":
            rows = [self._area_row(a) for a in self._areas()]
            return True, {"workspace_id": WS, "workspace_ref": "workspace:1", **self.area_list_payload(rows)}
        if method == "area.panels":
            area = self._target_area(params)
            if area is None:
                return False, {"code": "not_found", "message": f"area not found: {params}"}
            rows = [{"id": p[0], "selected": p[0] == T1} for p in self._panels() if p[2] == area[0]]
            return True, {**self.area_fields(area[0], area[1]), **self.panel_list_payload(rows)}
        if method == "panel.current":
            block = self._focus_block()
            block.pop("window_id", None)
            block.pop("window_ref", None)
            return True, block
        if method in ("panel.split", "panel.create"):
            self.split_done = True
            return True, {**self.panel_fields(NEW_T, 4), **self.area_fields(NEW_A, 3), "workspace_id": WS}
        if method in GENERIC_PANEL_METHODS or method in GENERIC_AREA_METHODS:
            out = self._echo(params)
            if method == "panel.action":
                out["action"] = params.get("action")
            if method == "panel.get_metadata":
                out["metadata"] = {}
            if method == "panel.read_text":
                out["text"] = ""
            return True, out
        if method == "browser.url.get":
            return True, {"url": "https://example.test/"}
        if method == "browser.panel.list":
            rows = [{"id": T3, "ref": f"{self.panel_prefix}:3", "title": "page", "url": "https://example.test/"}]
            return True, {"workspace_id": WS, **({"panels": rows} if self.tier == "panel" else {"tabs": rows})}
        if method.startswith("browser.panel.") or method == "notification.create_for_panel":
            return True, self._echo(params)
        self.unhandled.append(method)
        return False, {"code": "method_not_found", "message": f"fake app has no method {method}"}

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
            self.unhandled.clear()
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
    def __init__(self, name: str, tier: str, tmp: Path, probe: str = "normal") -> None:
        self.tier = tier
        self.app = FakeApp(tier, probe)
        self.path = str(tmp / f"{name}.sock")
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


def _no_violations(run: Running, what: str) -> None:
    _must(not run.app.violations, f"{what}: wrong wire for a {run.tier} app: {run.app.violations}")


# ---------------------------------------------------------------------------
# tmux format variables (every tier: results map forward before the shim reads them)
# ---------------------------------------------------------------------------

def test_tmux_format_variables(cli: str, run: Running) -> None:
    run.app.reset()
    target = f"%{A1}"
    expectations = [
        ("#{pane_id}", f"%{A1}"),
        ("#{pane_index}", "7"),
        ("#{surface_id}", T1),
        ("#{panel_id}", T1),
        ("#{tab_id}", T1),
        ("#{pane_uuid}", A1),
        ("#{window_id}", f"@{WS}"),
        ("#{session_name}:#{window_index}.#{pane_index}", "cmux:1.7"),
        ("#{pane_id} #{pane_title}", f"%{A1} leader"),
        ("#{pane_index}/#{surface_id}", f"7/{T1}"),
        ("#{pane_index}/#{panel_id}", f"7/{T1}"),
    ]
    for fmt, want in expectations:
        out = _tmux(cli, run, ["display-message", "-t", target, "-p", fmt])
        _must(out == [want], f"[{run.tier}] display-message -p {fmt!r} printed {out!r}, expected {[want]!r}")

    # Without -t the format resolves against the focused area.
    out = _tmux(cli, run, ["display-message", "-p", "#{pane_id}"])
    _must(out == [f"%{A1}"], f"[{run.tier}] display-message -p '#{{pane_id}}' (no -t) printed {out!r}")
    out = _tmux(cli, run, ["display-message", "-p", "#{panel_id}"])
    _must(out == [T1], f"[{run.tier}] display-message -p '#{{panel_id}}' (no -t) printed {out!r}")

    # The second area renders its own values.
    out = _tmux(cli, run, ["display-message", "-t", f"%{A2}", "-p", "#{pane_index} #{surface_id} #{panel_id}"])
    _must(out == [f"8 {T3} {T3}"], f"[{run.tier}] display-message for the second area printed {out!r}")

    # list-panes and split-window -P render through the same context.
    out = _tmux(cli, run, ["list-panes", "-F", "#{pane_index}:#{pane_id}"])
    _must(out == [f"7:%{A1}", f"8:%{A2}"], f"[{run.tier}] list-panes -F printed {out!r}")
    out = _tmux(cli, run, ["split-window", "-t", target, "-h", "-P", "-F", "#{pane_id}"])
    _must(out == [f"%{NEW_A}"], f"[{run.tier}] split-window -P -F '#{{pane_id}}' printed {out!r}")
    _no_violations(run, "tmux shim")
    print(f"PASS: [{run.tier}] tmux #{{pane_id}} / #{{pane_index}} / #{{surface_id}} / #{{panel_id}} render through display-message, list-panes, split-window")


# ---------------------------------------------------------------------------
# v1 wire for default-agent launch
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
        (["--in-panel", T1], f"default_agent launch --in-surface {T1}"),
        (["--in-panel", "panel:3"], f"default_agent launch --in-surface {T3}"),
        (["--in-tab", "tab:3"], f"default_agent launch --in-surface {T3}"),
        (["--in-surface", "surface:3"], f"default_agent launch --in-surface {T3}"),
        (["--agent", "claude", "--in-panel", T2], f"default_agent launch --agent claude --in-surface {T2}"),
        (["--agent", "claude", "--in-tab", T2], f"default_agent launch --agent claude --in-surface {T2}"),
        (["--area", A2], f"default_agent launch --pane {A2}"),
        (["--pane", A2], f"default_agent launch --pane {A2}"),
    ]
    for args, want in cases:
        got = _launch_wire(cli, run, args)
        _must(got == want, f"`default-agent launch {' '.join(args)}` composed {got!r}, expected {want!r}")
        _must("--in-tab" not in got and "--in-panel" not in got and "--area" not in got, f"v1 wire must stay closed: {got!r}")

    # --in-panel and --area (or their old spellings) are mutually exclusive: nothing reaches the app.
    for args in (["--in-panel", T1, "--area", A2], ["--in-tab", T1, "--area", A2], ["--in-surface", T1, "--pane", A2]):
        run.app.reset()
        proc = _run(cli, run, ["default-agent", "launch", *args], check=False)
        _must(proc.returncode != 0, f"`default-agent launch {' '.join(args)}` should fail: {proc.stdout!r}")
        _must("mutually exclusive" in (proc.stdout + proc.stderr), f"missing exclusivity error: {proc.stdout!r} {proc.stderr!r}")
        _must(not [line for line in run.app.v1 if line.startswith("default_agent")], f"launch reached the app: {run.app.v1}")
    print("PASS: default-agent launch --in-panel/--in-tab/--in-surface/--area/--pane compose the v1 wire (--in-surface, --pane)")


# ---------------------------------------------------------------------------
# reorder / move flag spellings (panel app)
# ---------------------------------------------------------------------------

def test_reorder_and_move_flags(cli: str, run: Running) -> None:
    placement: List[Tuple[List[str], str, str]] = [
        (["--before-panel", T1], "before_panel_id", T1),
        (["--before-tab", T1], "before_panel_id", T1),
        (["--before-surface", T1], "before_panel_id", T1),
        (["--after-panel", T1], "after_panel_id", T1),
        (["--after-tab", T1], "after_panel_id", T1),
        (["--after-surface", T1], "after_panel_id", T1),
        (["--before", T1], "before_panel_id", T1),
        (["--after", T1], "after_panel_id", T1),
    ]
    for command in ("reorder-panel", "reorder-tab", "reorder-surface"):
        for target_flag in ("--panel", "--tab", "--surface"):
            for flags, key, value in placement:
                run.app.reset()
                _run(cli, run, [command, target_flag, T2, *flags])
                calls = run.app.calls("panel.reorder")
                _must(len(calls) == 1, f"{command} {target_flag} {flags}: expected one panel.reorder, got {run.app.methods()}")
                _must(calls[0].get("panel_id") == T2, f"{command} {target_flag} {flags}: panel_id {calls[0]}")
                _must(calls[0].get(key) == value, f"{command} {target_flag} {flags}: {key} missing in {calls[0]}")
                _no_violations(run, f"{command} {target_flag} {flags}")

    for command in ("move-panel", "move-tab", "move-surface"):
        for area_flag in ("--area", "--pane"):
            for flags, key, value in placement[:6]:
                run.app.reset()
                _run(cli, run, [command, "--panel", T2, area_flag, A2, *flags])
                calls = run.app.calls("panel.move")
                _must(len(calls) == 1, f"{command} {area_flag} {flags}: expected one panel.move, got {run.app.methods()}")
                call = calls[0]
                _must(call.get("panel_id") == T2 and call.get("area_id") == A2 and call.get(key) == value,
                      f"{command} {area_flag} {flags} composed {call}")
                _no_violations(run, f"{command} {area_flag} {flags}")
    print("PASS: --before-panel/--after-panel/--before-tab/--after-tab/--before-surface/--after-surface (and --before/--after) reach the app as canonical params")


# ---------------------------------------------------------------------------
# Version skew, per tier
# ---------------------------------------------------------------------------

class Case:
    def __init__(self, name: str, args: Sequence[str], method: str, params: Dict[str, Any],
                 env: Optional[Dict[str, str]] = None, tmux: bool = False) -> None:
        self.name = name
        self.args = list(args)
        self.method = method
        self.params = params
        self.env = env or {}
        self.tmux = tmux


def _cases() -> List[Case]:
    cases: List[Case] = []

    # focus-* with every command, flag and ref-prefix spelling.
    for command, flag, prefix in (
        ("focus-panel", "--panel", "panel"), ("focus-tab", "--tab", "tab"), ("focus-panel", "--surface", "surface"),
        ("focus-tab", "--panel", "panel"), ("focus-panel", "--tab", "tab"), ("focus-tab", "--surface", "surface"),
    ):
        cases.append(Case(f"{command} {flag} {prefix}:2", [command, "--workspace", WS, flag, f"{prefix}:2"],
                          "panel.focus", {"panel_id": typed_ref(prefix, 2)}))
    cases.append(Case("focus-panel uuid", ["focus-panel", "--workspace", WS, "--panel", T2], "panel.focus", {"panel_id": T2}))

    # close / rename / new / list / send under every name.
    for command, flag, prefix in (("close-panel", "--panel", "panel"), ("close-tab", "--tab", "tab"),
                                  ("close-surface", "--surface", "surface")):
        cases.append(Case(f"{command} {flag}", [command, "--workspace", WS, flag, f"{prefix}:3"],
                          "panel.close", {"panel_id": typed_ref(prefix, 3)}))
    for command, flag, prefix in (("rename-panel", "--panel", "panel"), ("rename-tab", "--tab", "tab"),
                                  ("rename-tab", "--surface", "surface")):
        cases.append(Case(f"{command} {flag}", [command, "--workspace", WS, flag, f"{prefix}:2", "build logs"],
                          "panel.action", {"panel_id": typed_ref(prefix, 2), "action": "rename", "title": "build logs"}))
    for command, flag, prefix in (("new-panel", "--area", "area"), ("new-tab", "--area", "area"),
                                  ("new-surface", "--pane", "pane"), ("new-panel", "--pane", "pane")):
        cases.append(Case(f"{command} {flag}", [command, "--workspace", WS, flag, f"{prefix}:2", "--no-focus"],
                          "panel.create", {"area_id": typed_ref(prefix, 2)}))
    for command in ("list-panels", "list-tabs"):
        cases.append(Case(command, [command, "--workspace", WS], "panel.list", {}))
    for command in ("panel-health", "tab-health", "surface-health"):
        cases.append(Case(command, [command, "--workspace", WS], "panel.health", {}))
    for command, flag, prefix in (("list-area-panels", "--area", "area"), ("list-area-tabs", "--area", "area"),
                                  ("list-pane-surfaces", "--pane", "pane")):
        cases.append(Case(f"{command} {flag}", [command, "--workspace", WS, flag, f"{prefix}:2"],
                          "area.panels", {"area_id": typed_ref(prefix, 2)}))
    for command, flag, prefix in (("send-panel", "--panel", "panel"), ("send-tab", "--tab", "tab")):
        cases.append(Case(f"{command} {flag}", [command, "--workspace", WS, flag, f"{prefix}:1", "echo hello"],
                          "panel.send_text", {"panel_id": typed_ref(prefix, 1), "text": text_of("echo hello")}))
    for command, flag, prefix in (("send-key-panel", "--panel", "panel"), ("send-key-tab", "--tab", "tab")):
        cases.append(Case(f"{command} {flag}", [command, "--workspace", WS, flag, f"{prefix}:1", "enter"],
                          "panel.send_key", {"panel_id": typed_ref(prefix, 1), "key": "enter"}))
    # drag-panel-to-split speaks the v1 text protocol (drag_surface_to_split), which
    # the vocabulary rename leaves alone, so it is not part of this v2 matrix.

    # before / after / area keys: move and reorder, every spelling.
    cases.append(Case("move-panel", ["move-panel", "--workspace", WS, "--panel", T2, "--area", "area:2", "--before-panel", "panel:3"],
                      "panel.move", {"panel_id": T2, "area_id": "area:2", "before_panel_id": "panel:3"}))
    cases.append(Case("move-tab", ["move-tab", "--workspace", WS, "--tab", T2, "--pane", "pane:2", "--before-tab", "tab:3"],
                      "panel.move", {"panel_id": T2, "area_id": typed_ref("pane", 2), "before_panel_id": typed_ref("tab", 3)}))
    cases.append(Case("move-surface", ["move-surface", "--workspace", WS, "--surface", T2, "--pane", "pane:2", "--after-surface", "surface:3"],
                      "panel.move", {"panel_id": T2, "area_id": typed_ref("pane", 2), "after_panel_id": typed_ref("surface", 3)}))
    cases.append(Case("reorder-panel", ["reorder-panel", "--workspace", WS, "--panel", "panel:2", "--after-panel", T1],
                      "panel.reorder", {"panel_id": "panel:2", "after_panel_id": T1}))
    cases.append(Case("reorder-tab", ["reorder-tab", "--workspace", WS, "--tab", "tab:2", "--before-tab", "tab:1"],
                      "panel.reorder", {"panel_id": typed_ref("tab", 2), "before_panel_id": typed_ref("tab", 1)}))
    cases.append(Case("reorder-surface", ["reorder-surface", "--workspace", WS, "--surface", "surface:2", "--after-surface", "surface:1"],
                      "panel.reorder", {"panel_id": typed_ref("surface", 2), "after_panel_id": typed_ref("surface", 1)}))

    # panel.action action values: canonical, tab spelling and short forms.
    for typed, canonical in (
        ("close-other-panels", "close_other_panels"), ("duplicate-panel", "duplicate_panel"),
        ("reload-panel", "reload_panel"), ("new-terminal-panel-to-right", "new_terminal_panel_to_right"),
        ("new-browser-panel-to-right", "new_browser_panel_to_right"),
    ):
        cases.append(Case(f"panel-action {typed}", ["panel-action", "--workspace", WS, "--panel", "panel:2", "--action", typed],
                          "panel.action", {"panel_id": "panel:2", "action": canonical}))
    for typed, tab_spelling in (
        ("close-other-tabs", "close_other_tabs"), ("duplicate-tab", "duplicate_tab"),
        ("reload-tab", "reload_tab"), ("new-terminal-tab-to-right", "new_terminal_tab_to_right"),
        ("new-browser-tab-to-right", "new_browser_tab_to_right"),
    ):
        # An operator's tab spelling stays accepted everywhere: older tiers get it as typed, a panel
        # app gets it as typed or in its canonical spelling.
        canonical = next(k for k, v in TAB_ACTIONS.items() if v == tab_spelling)
        cases.append(Case(f"panel-action {typed}", ["tab-action", "--workspace", WS, "--tab", "tab:2", "--action", typed],
                          "panel.action", {"panel_id": typed_ref("tab", 2),
                                           "action": Tiered(OneOf(tab_spelling, canonical), tab_spelling, tab_spelling)}))
    for short in ("close-others", "duplicate", "reload", "pin", "unpin"):
        cases.append(Case(f"panel-action {short}", ["panel-action", "--workspace", WS, "--panel", "panel:2", "--action", short],
                          "panel.action", {"panel_id": "panel:2", "action": short.replace("-", "_")}))

    # Nested caller keys and the caller_* family from the environment.
    for flag, prefix in (("--panel", "panel"), ("--tab", "tab"), ("--surface", "surface")):
        cases.append(Case(f"identify {flag}", ["identify", "--workspace", WS, flag, f"{prefix}:2"],
                          "system.identify", {"caller": {"panel_id": typed_ref(prefix, 2)}}))
    for env_name in ("C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID"):
        cases.append(Case(f"select-workspace caller from {env_name}", ["select-workspace", "--workspace", WS],
                          "workspace.select", {"caller_panel_id": T1}, env={env_name: T1}))

    # Area commands (tmux verbs keep their own flags): area.* / pane.* and target_area_* keys.
    cases.append(Case("swap-pane", ["swap-pane", "--workspace", WS, "--pane", "area:1", "--target-pane", "area:2"],
                      "area.swap", {"area_id": ref_or_uuid("area", 1, A1), "target_area_id": ref_or_uuid("area", 2, A2)}, tmux=True))
    cases.append(Case("join-pane", ["join-pane", "--workspace", WS, "--pane", "area:1", "--surface", "panel:2",
                                    "--target-pane", "area:2"],
                      "area.join", {"area_id": ref_or_uuid("area", 1, A1), "panel_id": ref_or_uuid("panel", 2, T2),
                                    "target_area_id": ref_or_uuid("area", 2, A2)}, tmux=True))
    cases.append(Case("break-pane", ["break-pane", "--workspace", WS, "--pane", "area:1", "--surface", "panel:2"],
                      "area.break", {"area_id": ref_or_uuid("area", 1, A1), "panel_id": ref_or_uuid("panel", 2, T2)}, tmux=True))

    # User data is never rewritten: metadata keys and values, titles and free text that look like wire.
    cases.append(Case("set-metadata with wire-looking key and value",
                      ["set-metadata", "--workspace", WS, "--panel", "panel:2", "--key", "panel_id", "--value", "panel:3"],
                      "panel.set_metadata", {"panel_id": "panel:2", "metadata": {"panel_id": "panel:3"}}))
    cases.append(Case("send free text that looks like wire",
                      ["send-panel", "--workspace", WS, "--panel", "panel:1", "echo panel:3 tab_id surface:4 --panel"],
                      "panel.send_text", {"panel_id": "panel:1", "text": text_of("echo panel:3 tab_id surface:4 --panel")}))
    cases.append(Case("rename with wire-looking title",
                      ["rename-panel", "--workspace", WS, "--panel", "panel:2", "--title", "panel:3 and area:1"],
                      "panel.action", {"panel_id": "panel:2", "action": "rename", "title": "panel:3 and area:1"}))
    return cases


def test_request_matrix(cli: str, run: Running) -> None:
    app = run.app
    count = 0
    for case in _cases():
        app.reset()
        proc = _run(cli, run, case.args, extra_env=case.env, check=False)
        label = f"[{run.tier}] {case.name}"
        _must(proc.returncode == 0,
              f"{label}: CLI failed (exit {proc.returncode}): {proc.stdout!r} {proc.stderr!r}; saw {app.methods()}")
        native, expected = expected_call(case.method, case.params, run.tier)
        calls = app.calls(native)
        _must(len(calls) == 1, f"{label}: expected exactly one {native}, saw {app.methods()}")
        problem = subset_mismatch(expected, calls[0])
        _must(problem is None, f"{label}: {native} params {calls[0]} differ from expected {expected}: {problem}")
        _no_violations(run, label)
        _must(not app.unhandled, f"{label}: the fake has no handler for {app.unhandled}")
        probes = app.methods().count("system.capabilities")
        _must(probes == 1, f"{label}: capability probe should run exactly once per invocation, ran {probes}: {app.methods()}")
        _must(app.methods()[0] == "system.capabilities", f"{label}: the first request must be the capability probe: {app.methods()}")
        count += 1
    print(f"PASS: [{run.tier}] {count} CLI invocations sent the right methods, keys, refs and action values")


def test_tier_specific_wire(cli: str, run: Running) -> None:
    """A few exact shapes per tier, written out literally (the matrix above derives them from the spec)."""
    app, tier = run.app, run.tier
    wanted = {
        "panel": ("panel.focus", {"panel_id": "panel:2"}, "area.panels", {"area_id": "area:2"}),
        "tab": ("tab.focus", {"tab_id": "tab:2"}, "area.tabs", {"area_id": "area:2"}),
        "surface": ("surface.focus", {"surface_id": "surface:2"}, "pane.surfaces", {"pane_id": "pane:2"}),
    }[tier]
    app.reset()
    _run(cli, run, ["focus-panel", "--workspace", WS, "--panel", "panel:2"])
    calls = app.calls(wanted[0])
    _must(len(calls) == 1 and subset_mismatch(wanted[1], calls[0]) is None, f"[{tier}] focus-panel composed {calls} ({app.methods()})")
    _no_violations(run, "focus-panel")
    app.reset()
    _run(cli, run, ["list-area-panels", "--workspace", WS, "--area", "area:2"])
    calls = app.calls(wanted[2])
    _must(len(calls) == 1 and subset_mismatch(wanted[3], calls[0]) is None, f"[{tier}] list-area-panels composed {calls} ({app.methods()})")
    _no_violations(run, "list-area-panels")

    # panel.action: the method, and the action value, per tier.
    app.reset()
    _run(cli, run, ["panel-action", "--workspace", WS, "--panel", "panel:2", "--action", "close-other-panels"])
    method = {"panel": "panel.action", "tab": "tab.action", "surface": "tab.action"}[tier]
    action = {"panel": "close_other_panels", "tab": "close_other_tabs", "surface": "close_other_tabs"}[tier]
    calls = app.calls(method)
    _must(len(calls) == 1 and calls[0].get("action") == action, f"[{tier}] panel-action close-other-panels composed {calls} ({app.methods()})")
    _no_violations(run, "panel-action")

    # target_ / before_ / caller_ key families.
    app.reset()
    _run(cli, run, ["move-panel", "--workspace", WS, "--panel", "panel:2", "--area", "area:2", "--before-panel", "panel:3"])
    keys = {"panel": ("panel_id", "area_id", "before_panel_id", "panel:2", "area:2", "panel:3"),
            "tab": ("tab_id", "area_id", "before_tab_id", "tab:2", "area:2", "tab:3"),
            "surface": ("surface_id", "pane_id", "before_surface_id", "surface:2", "pane:2", "surface:3")}[tier]
    calls = app.calls(downgrade_method("panel.move", tier))
    want = {keys[0]: keys[3], keys[1]: keys[4], keys[2]: keys[5]}
    _must(len(calls) == 1 and subset_mismatch(want, calls[0]) is None, f"[{tier}] move-panel composed {calls}, wanted {want}")
    _no_violations(run, "move-panel")

    app.reset()
    _run(cli, run, ["select-workspace", "--workspace", WS], extra_env={"C11_TAB_ID": T1})
    key = {"panel": "caller_panel_id", "tab": "caller_tab_id", "surface": "caller_surface_id"}[tier]
    calls = app.calls("workspace.select")
    _must(len(calls) == 1 and calls[0].get(key) == T1, f"[{tier}] select-workspace should send {key}={T1}: {calls}")
    _no_violations(run, "select-workspace")
    print(f"PASS: [{tier}] literal method names, keys, refs, action values and caller_* key")


def _assert_canonical_refs(payload: Any, what: str) -> None:
    ref_keys = {"ref", "panel_ref", "area_ref", "selected_panel_ref", "created_panel_ref", "focused_panel_ref"}
    list_keys = {"panel_refs"}
    stack = [payload]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for key, child in node.items():
                if key in ref_keys and isinstance(child, str):
                    _must(re.match(r"^(panel|area|workspace|window):\d+$", child) is not None,
                          f"{what}: `{key}` should be a canonical ref, got {child!r}")
                if key in list_keys and isinstance(child, list):
                    for item in child:
                        _must(re.match(r"^panel:\d+$", str(item)) is not None, f"{what}: `{key}` item {item!r} is not a panel:N ref")
                if key not in ("metadata", "value"):
                    stack.append(child)
        elif isinstance(node, list):
            stack.extend(node)


def _assert_no_tab_keys(payload: Any, what: str) -> None:
    """Against a panel app the CLI prints no `tab_*` / `tabs` key of its own (C11-345)."""
    stack = [payload]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for key, child in node.items():
                _must(re.search(r"(^|_)tabs?(_|$)", key) is None and key not in ("tabRefs", "tabIds"),
                      f"{what}: output must not carry the old key `{key}`")
                if key not in ("metadata", "value"):
                    stack.append(child)
        elif isinstance(node, list):
            stack.extend(node)


def test_canonical_output(cli: str, run: Running) -> None:
    app, tier = run.app, run.tier
    app.reset()
    out = _json(cli, run, ["list-panels", "--workspace", WS])
    rows = out.get("panels")
    # Earlier invocations may have split a panel into the fake's state; the fixture panels must all be there.
    _must(isinstance(rows, list) and {p[0] for p in PANELS} <= {r.get("id") for r in rows},
          f"[{tier}] list-panels --json should expose the canonical `panels` key: {out}")
    for row in rows:
        _must(str(row.get("ref", "")).startswith("panel:"), f"[{tier}] list-panels row ref should be panel:N: {row}")
        _must(row.get("area_id") in (A1, A2, NEW_A) and str(row.get("area_ref", "")).startswith("area:"),
              f"[{tier}] list-panels row should carry area_id/area_ref (area:N): {row}")
    _assert_canonical_refs(out, f"[{tier}] list-panels --json")
    if tier == "panel":
        _assert_no_tab_keys(out, f"[{tier}] list-panels --json")
    _no_violations(run, "list-panels")

    app.reset()
    out = _json(cli, run, ["list-areas", "--workspace", WS])
    rows = out.get("areas")
    _must(isinstance(rows, list) and {A1, A2} <= {r.get("id") for r in rows}, f"[{tier}] list-areas --json: {out}")
    for row in rows:
        _must(str(row.get("ref", "")).startswith("area:"), f"[{tier}] list-areas row ref should be area:N: {row}")
        _must(isinstance(row.get("panel_ids"), list) and len(row["panel_ids"]) > 0, f"[{tier}] list-areas row should carry panel_ids: {row}")
        if "panel_refs" in row:
            _must(all(str(r).startswith("panel:") for r in row["panel_refs"]), f"[{tier}] panel_refs should be panel:N: {row}")
    _assert_canonical_refs(out, f"[{tier}] list-areas --json")
    if tier == "panel":
        _assert_no_tab_keys(out, f"[{tier}] list-areas --json")
    _no_violations(run, "list-areas")

    app.reset()
    out = _json(cli, run, ["list-area-panels", "--workspace", WS, "--area", "area:1"])
    _must(isinstance(out.get("panels"), list) and len(out["panels"]) == 2, f"[{tier}] list-area-panels --json should carry `panels`: {out}")
    _no_violations(run, "list-area-panels")

    app.reset()
    out = _json(cli, run, ["identify", "--workspace", WS, "--panel", "panel:2"])
    for scope in ("focused", "caller"):
        block = out.get(scope) or {}
        _must(block.get("panel_id") in (T1, T2), f"[{tier}] identify {scope} block should carry panel_id: {block}")
        _must(str(block.get("panel_ref", "")).startswith("panel:"), f"[{tier}] identify {scope} panel_ref should be panel:N: {block}")
        _must(str(block.get("area_ref", "")).startswith("area:"), f"[{tier}] identify {scope} area_ref should be area:N: {block}")
        _must(block.get("area_id") in (A1, A2), f"[{tier}] identify {scope} should carry area_id: {block}")
    _must((out.get("caller") or {}).get("panel_id") == T2, f"[{tier}] identify --panel panel:2 should resolve the caller to {T2}: {out}")
    _assert_canonical_refs(out, f"[{tier}] identify --json")
    if tier == "panel":
        _assert_no_tab_keys(out, f"[{tier}] identify --json")
    _no_violations(run, "identify")

    # Text output prints panel:N / area:N whatever the app minted.
    app.reset()
    proc = _run(cli, run, ["--id-format", "refs", "new-panel", "--workspace", WS, "--area", "area:1", "--no-focus"])
    text = proc.stdout
    _must(re.search(r"\bOK\b.*\bpanel:\d+", text) is not None, f"[{tier}] new-panel should print `OK panel:N ...`: {text!r}")
    _must(re.search(r"\b(tab|surface|pane):\d+", text) is None, f"[{tier}] new-panel output must not print old ref prefixes: {text!r}")
    _no_violations(run, "new-panel")

    app.reset()
    proc = _run(cli, run, ["--id-format", "refs", "list-panels", "--workspace", WS])
    _must(re.search(r"\bpanel:\d+", proc.stdout) is not None, f"[{tier}] list-panels text should print panel:N: {proc.stdout!r}")
    _must(re.search(r"\b(tab|surface|pane):\d+", proc.stdout) is None, f"[{tier}] list-panels text must not print old ref prefixes: {proc.stdout!r}")

    # Browser: the browsing-context ref reaches each tier in its own vocabulary.
    app.reset()
    proc = _run(cli, run, ["browser", "panel:3", "get-url"], check=False)
    calls = app.calls("browser.url.get")
    _must(len(calls) == 1, f"[{tier}] browser get-url sent {app.methods()} ({proc.stderr!r})")
    want = {"panel": "panel:3", "tab": "tab:3", "surface": "surface:3"}[tier]
    ctx = [v for k, v in calls[0].items() if k in ("panel_id", "tab_id", "surface_id") and isinstance(v, str)]
    _must(bool(ctx) and set(ctx) == {want}, f"[{tier}] browser get-url context ref should be {want!r}: {calls[0]}")
    _no_violations(run, "browser get-url")

    app.reset()
    _run(cli, run, ["browser", "panel:3", "panel", "switch", "panel:2"], check=False)
    native = downgrade_method("browser.panel.switch", tier)
    calls = app.calls(native)
    _must(len(calls) == 1, f"[{tier}] browser panel switch should send {native}: {app.methods()}")
    target_key = {"panel": "target_panel_id", "tab": "target_tab_id", "surface": "target_surface_id"}[tier]
    target_value = {"panel": "panel:2", "tab": "tab:2", "surface": "surface:2"}[tier]
    _must(calls[0].get(target_key) == target_value, f"[{tier}] browser panel switch target should be {target_key}={target_value}: {calls[0]}")
    _no_violations(run, "browser panel switch")
    app.reset()
    _run(cli, run, ["browser", "tab:3", "tab", "list"], check=False)
    _must(app.calls(downgrade_method("browser.panel.list", tier)), f"[{tier}] `browser <ref> tab list` should reach {downgrade_method('browser.panel.list', tier)}: {app.methods()}")
    print(f"PASS: [{tier}] CLI output is canonical: panel:N / area:N refs, panel_* keys, `panels` / `areas`")


def test_no_retry_and_single_probe(cli: str, run: Running) -> None:
    app, tier = run.app, run.tier
    native = downgrade_method("panel.focus", tier)
    for code in ("invalid_params", "missing_ref", "method_not_found"):
        app.reset()
        app.fail_once[native] = code
        proc = _run(cli, run, ["focus-panel", "--workspace", WS, "--panel", T2], check=False)
        _must(proc.returncode != 0, f"[{tier}] focus-panel should fail when the app answers {code}: {proc.stdout!r}")
        _must(code in (proc.stdout + proc.stderr), f"[{tier}] error should carry the app's code {code}: {proc.stdout!r} {proc.stderr!r}")
        attempts = [m for m in app.methods() if m.endswith(".focus") and not m.startswith(("area.", "pane."))]
        _must(attempts == [native], f"[{tier}] a rejected {native} ({code}) must not be retried under another spelling: {attempts}")
        _must(app.methods().count("system.capabilities") == 1, f"[{tier}] probe should run once: {app.methods()}")

    # The probe runs once per invocation, even for multi-request commands.
    app.reset()
    _run(cli, run, ["move-panel", "--workspace", WS, "--panel", "panel:2", "--area", "area:2"])
    _must(app.methods().count("system.capabilities") == 1, f"[{tier}] probe should run once per invocation: {app.methods()}")
    _no_violations(run, "move-panel")
    print(f"PASS: [{tier}] one capability probe per invocation, and no retry of a rejected request")


def test_probe_failure_sends_canonical(cli: str, tmp: Path) -> None:
    """A failed or empty capability probe is not evidence of an old app: send canonical panel names."""
    for probe in ("error", "empty"):
        run = Running(f"probe-{probe}", "panel", tmp, probe=probe)
        try:
            _run(cli, run, ["focus-panel", "--workspace", WS, "--panel", "panel:2"])
            _run(cli, run, ["list-area-panels", "--workspace", WS, "--area", "area:2"])
            _run(cli, run, ["panel-action", "--workspace", WS, "--panel", "panel:2", "--action", "close-other-panels"])
            methods = run.app.methods()
            for want in ("panel.focus", "area.panels", "panel.action"):
                _must(want in methods, f"probe {probe}: {want} should be sent as-is: {methods}")
            _must(not [m for m in methods if m.startswith(("tab.", "surface.", "pane."))],
                  f"probe {probe}: no old method names: {methods}")
            action = run.app.calls("panel.action")[0].get("action")
            _must(action == "close_other_panels", f"probe {probe}: action value should stay canonical, got {action!r}")
            focus = run.app.calls("panel.focus")[0]
            _must(focus.get("panel_id") == "panel:2", f"probe {probe}: focus composed {focus}")
            _no_violations(run, f"probe {probe}")
        finally:
            run.stop()
    print("PASS: a failed or empty capability probe leaves the CLI on canonical panel names")


# ---------------------------------------------------------------------------

def main() -> int:
    cli = _resolve_cli()
    with tempfile.TemporaryDirectory(prefix="c11vf-") as td:
        tmp = Path(td)
        apps = {tier: Running(tier, tier, tmp) for tier in TIERS}
        try:
            # The panel app: the original flag, launch-wire and tmux checks.
            test_default_agent_launch_wire(cli, apps["panel"])
            test_reorder_and_move_flags(cli, apps["panel"])
            for tier in TIERS:
                run = apps[tier]
                test_tmux_format_variables(cli, run)
                test_request_matrix(cli, run)
                test_tier_specific_wire(cli, run)
                test_canonical_output(cli, run)
                test_no_retry_and_single_probe(cli, run)
            test_probe_failure_sends_canonical(cli, tmp)
        finally:
            for run in apps.values():
                run.stop()
    print("PASS: vocabulary CLI fake-server checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
