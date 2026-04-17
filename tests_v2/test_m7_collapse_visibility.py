#!/usr/bin/env python3
"""M7: Collapse / expand / visibility behaviors.

1. New surface defaults to collapsed=true.
2. First description set auto-expands (collapsed → false).
3. A user-initiated collapse latches per-surface; subsequent description writes
   do NOT auto-expand.
4. Workspace-level visibility toggle: visible=false hides the bar but title
   writes still land and reappear when visibility is restored.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _state(c, surface_id: str) -> dict:
    return c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}


def _set_description(c, surface_id: str, desc: str, auto_expand: bool = True) -> dict:
    params = {
        "surface_id": surface_id,
        "mode": "merge",
        "source": "explicit",
        "metadata": {"description": desc},
    }
    if not auto_expand:
        params["auto_expand"] = False
    return c._call("surface.set_metadata", params) or {}


def _set_title(c, surface_id: str, title: str) -> dict:
    return c._call(
        "surface.set_metadata",
        {
            "surface_id": surface_id,
            "mode": "merge",
            "source": "explicit",
            "metadata": {"title": title},
        },
    ) or {}


def _fresh_surface(c) -> tuple[str, str]:
    created = c._call("workspace.create") or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    c._call("workspace.select", {"workspace_id": ws_id})
    current = c._call("surface.current", {"workspace_id": ws_id}) or {}
    surface_id = str(current.get("surface_id") or "")
    _must(bool(surface_id), f"surface.current returned no surface_id: {current}")
    return ws_id, surface_id


def main() -> int:
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must(
            "surface.set_metadata" in methods
            and "surface.get_titlebar_state" in methods
            and "surface.set_titlebar_collapsed" in methods
            and "surface.set_titlebar_visibility" in methods,
            f"Required M2/M7 methods missing. methods={sorted(methods)[:80]}",
        )

        # Case 1: new surface → collapsed=true, visible=true.
        ws_id, surface_id = _fresh_surface(c)
        try:
            s = _state(c, surface_id)
            _must(s.get("collapsed") is True, f"new surface must start collapsed: {s}")
            _must(s.get("visible") is True, f"new surface must start visible: {s}")

            # Case 2: auto-expand on first description set.
            res = _set_description(c, surface_id, f"first desc {stamp}")
            _must(
                (res.get("applied") or {}).get("description") is True,
                f"first description write should apply: {res}",
            )
            s = _state(c, surface_id)
            _must(s.get("collapsed") is False, f"first description should auto-expand: {s}")

            # Case 3: user-initiated collapse latches; subsequent description writes
            # should NOT auto-expand.
            c._call(
                "surface.set_titlebar_collapsed",
                {"surface_id": surface_id, "collapsed": True, "user": True},
            )
            s = _state(c, surface_id)
            _must(s.get("collapsed") is True, f"user collapse should stick: {s}")

            res = _set_description(c, surface_id, f"second desc {stamp}")
            _must(
                (res.get("applied") or {}).get("description") is True,
                f"second description write should apply: {res}",
            )
            s = _state(c, surface_id)
            _must(
                s.get("collapsed") is True,
                f"after user-collapse, further descriptions must NOT auto-expand: {s}",
            )
        finally:
            c.close_workspace(ws_id)

        # Case 4: visibility toggle at workspace scope.
        ws_id, surface_id = _fresh_surface(c)
        try:
            c._call("surface.set_titlebar_visibility", {"surface_id": surface_id, "visible": False})
            s = _state(c, surface_id)
            _must(s.get("visible") is False, f"after hide, visible should be False: {s}")

            # Title write still lands even with bar hidden.
            hidden_title = f"Hidden title {stamp}"
            res = _set_title(c, surface_id, hidden_title)
            _must(
                (res.get("applied") or {}).get("title") is True,
                f"title write should still apply while hidden: {res}",
            )
            s = _state(c, surface_id)
            _must(s.get("title") == hidden_title, f"title should land: {s}")
            _must(s.get("visible") is False, f"visibility should remain False: {s}")

            # Re-show; title should reappear.
            c._call("surface.set_titlebar_visibility", {"surface_id": surface_id, "visible": True})
            s = _state(c, surface_id)
            _must(s.get("visible") is True, f"after show, visible should be True: {s}")
            _must(s.get("title") == hidden_title, f"title should remain after toggle: {s}")
        finally:
            c.close_workspace(ws_id)

    print("PASS: M7 collapse/expand/visibility (default, auto-expand, user-latch, toggle)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
