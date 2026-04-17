#!/usr/bin/env python3
"""M7: OSC 2 title escape routes into M2 metadata with source='osc'.

Uses the shell's `printf` to emit the OSC sequence on PTY output (which Ghostty
parses). That matches real-world OSC-from-TUI behavior more faithfully than
injecting bytes into PTY input.

Covers:
1. `printf '\\033]2;OSC Title\\007'` → title="OSC Title", title_source="osc".
2. `printf '\\033]2;\\007'` (empty payload) → title cleared (source was osc).
3. Explicit set-title via surface.set_metadata upgrades source to "explicit";
   subsequent OSC emit is dropped (lower_precedence) and title stays.
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


def _wait_for(pred, timeout_s: float, step_s: float = 0.05):
    start = time.time()
    while time.time() - start < timeout_s:
        try:
            result = pred()
        except Exception:
            result = None
        if result:
            return result
        time.sleep(step_s)
    return None


def _wait_title(c, surface_id: str, predicate, timeout_s: float = 5.0) -> dict:
    def check():
        s = _state(c, surface_id)
        return s if predicate(s) else None

    got = _wait_for(check, timeout_s)
    if got is None:
        raise cmuxError(f"Timed out waiting for title condition; last state: {_state(c, surface_id)}")
    return got


def _emit_osc(c, surface_id: str, payload: str) -> None:
    # Build the OSC 2 sequence via printf. Using \033 octal for ESC and \007 for BEL.
    escaped = payload.replace("\\", "\\\\").replace("'", "'\\''")
    cmd = f"printf '\\033]2;{escaped}\\007'"
    c.send_surface(surface_id, cmd + "\n")


def main() -> int:
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must(
            "surface.set_metadata" in methods
            and "surface.get_titlebar_state" in methods
            and "surface.send_text" in methods,
            f"Required methods missing. methods={sorted(methods)[:80]}",
        )

        c.activate_app()
        time.sleep(0.2)

        ws_id = c.new_workspace()
        c.select_workspace(ws_id)
        time.sleep(0.5)

        current = c._call("surface.current", {"workspace_id": ws_id}) or {}
        surface_id = str(current.get("surface_id") or "")
        _must(bool(surface_id), f"surface.current returned no surface_id: {current}")

        try:
            osc_title = f"OSC Title {stamp}"
            _emit_osc(c, surface_id, osc_title)

            state = _wait_title(
                c, surface_id,
                lambda s: s.get("title") == osc_title and s.get("title_source") == "osc",
                timeout_s=6.0,
            )
            _must(
                state.get("title") == osc_title and state.get("title_source") == "osc",
                f"OSC 2 did not land as source=osc: {state}",
            )

            # Empty OSC clears (current source is osc, so precedence-gated clear succeeds).
            _emit_osc(c, surface_id, "")
            state = _wait_title(
                c, surface_id,
                lambda s: s.get("title") is None,
                timeout_s=6.0,
            )
            _must(state.get("title") is None, f"empty OSC should clear title: {state}")

            # Re-set via OSC so we have something to protect.
            osc2 = f"OSC Again {stamp}"
            _emit_osc(c, surface_id, osc2)
            _wait_title(c, surface_id, lambda s: s.get("title") == osc2, timeout_s=6.0)

            # Explicit write upgrades source.
            explicit_title = f"User Title {stamp}"
            res = c._call(
                "surface.set_metadata",
                {
                    "surface_id": surface_id,
                    "mode": "merge",
                    "source": "explicit",
                    "metadata": {"title": explicit_title},
                },
            ) or {}
            _must(
                (res.get("applied") or {}).get("title") is True,
                f"explicit set should apply over osc: {res}",
            )

            # Further OSC emissions are dropped (lower_precedence).
            _emit_osc(c, surface_id, f"Should be ignored {stamp}")

            # Give the OSC a chance to propagate (and be dropped).
            time.sleep(0.5)
            state = _state(c, surface_id)
            _must(
                state.get("title") == explicit_title and state.get("title_source") == "explicit",
                f"OSC must not displace explicit: {state}",
            )
        finally:
            c.close_workspace(ws_id)

    print("PASS: M7 OSC 2 title binding (set, clear, precedence-blocked by explicit)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
