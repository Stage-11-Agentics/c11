#!/usr/bin/env python3
"""M7: Precedence ladder explicit > declare > osc > heuristic for `title`.

Verifies the M2 per-key precedence gate across every adjacent pair, plus the
charter's OSC → declare → explicit transition scenario.
"""

import os
import sys
import time
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _set_title(c, surface_id: str, title: str, source: str) -> dict:
    return c._call(
        "surface.set_metadata",
        {
            "surface_id": surface_id,
            "mode": "merge",
            "source": source,
            "metadata": {"title": title},
        },
    ) or {}


def _titlebar_title(c, surface_id: str) -> tuple[Optional[str], Optional[str]]:
    state = c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}
    return state.get("title"), state.get("title_source")


def _fresh_surface(c) -> tuple[str, str]:
    created = c._call("workspace.create") or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    c._call("workspace.select", {"workspace_id": ws_id})
    current = c._call("surface.current", {"workspace_id": ws_id}) or {}
    surface_id = str(current.get("surface_id") or "")
    _must(bool(surface_id), f"surface.current returned no surface_id: {current}")
    return ws_id, surface_id


def _check_pair(c, higher: str, lower: str) -> None:
    """Higher source blocks lower; equal or higher lands."""
    ws_id, surface_id = _fresh_surface(c)
    try:
        higher_val = f"higher-{higher}-{int(time.time() * 1000)}"
        lower_val = f"lower-{lower}-{int(time.time() * 1000)}"

        res = _set_title(c, surface_id, higher_val, higher)
        _must(
            (res.get("applied") or {}).get("title") is True,
            f"initial {higher} write should apply: {res}",
        )

        # Lower source blocked.
        res = _set_title(c, surface_id, lower_val, lower)
        _must(
            (res.get("applied") or {}).get("title") is False,
            f"{lower} write should be rejected when {higher} holds: {res}",
        )
        reason = (res.get("reasons") or {}).get("title")
        _must(
            reason == "lower_precedence",
            f"expected reason=lower_precedence, got {reason!r} in {res}",
        )

        title, src = _titlebar_title(c, surface_id)
        _must(
            title == higher_val and src == higher,
            f"title should be unchanged: title={title!r} src={src!r}",
        )

        # Equal-source overwrite lands.
        equal_val = f"equal-{higher}-{int(time.time() * 1000)}"
        res = _set_title(c, surface_id, equal_val, higher)
        _must(
            (res.get("applied") or {}).get("title") is True,
            f"equal-source overwrite should apply: {res}",
        )
        title, src = _titlebar_title(c, surface_id)
        _must(
            title == equal_val and src == higher,
            f"title should equal {equal_val!r}: {title!r} {src!r}",
        )
    finally:
        c.close_workspace(ws_id)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must(
            "surface.set_metadata" in methods and "surface.get_titlebar_state" in methods,
            f"Required M2/M7 methods missing. methods={sorted(methods)[:60]}",
        )

        # Adjacent pairs along the ladder.
        _check_pair(c, higher="explicit", lower="declare")
        _check_pair(c, higher="declare", lower="osc")
        _check_pair(c, higher="osc", lower="heuristic")

        # Charter scenario: osc → declare → explicit transition.
        ws_id, surface_id = _fresh_surface(c)
        try:
            res = _set_title(c, surface_id, "OSC Title", "osc")
            _must((res.get("applied") or {}).get("title") is True, f"osc should apply on empty: {res}")
            title, src = _titlebar_title(c, surface_id)
            _must(title == "OSC Title" and src == "osc", f"want osc OSC Title; got {title!r}/{src!r}")

            res = _set_title(c, surface_id, "Agent Title", "declare")
            _must(
                (res.get("applied") or {}).get("title") is True,
                f"declare should overwrite osc: {res}",
            )
            title, src = _titlebar_title(c, surface_id)
            _must(
                title == "Agent Title" and src == "declare",
                f"want declare Agent Title; got {title!r}/{src!r}",
            )

            res = _set_title(c, surface_id, "User Title", "explicit")
            _must(
                (res.get("applied") or {}).get("title") is True,
                f"explicit should overwrite declare: {res}",
            )
            title, src = _titlebar_title(c, surface_id)
            _must(
                title == "User Title" and src == "explicit",
                f"want explicit User Title; got {title!r}/{src!r}",
            )

            # Backwards: osc cannot displace explicit.
            res = _set_title(c, surface_id, "should not land", "osc")
            _must(
                (res.get("applied") or {}).get("title") is False,
                f"osc must not overwrite explicit: {res}",
            )
            title, src = _titlebar_title(c, surface_id)
            _must(
                title == "User Title" and src == "explicit",
                f"explicit must persist: {title!r}/{src!r}",
            )
        finally:
            c.close_workspace(ws_id)

    print("PASS: M7 precedence ladder (explicit > declare > osc > heuristic)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
