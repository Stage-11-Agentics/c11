#!/usr/bin/env python3
"""M7 amendment: description pass-through round-trip.

Confirms the description string is stored and returned literally, even when it
contains markdown constructs that the render-time sanitizer drops (images,
fenced code blocks). The preprocessor runs at render time only; the store path
is untouched.

Cases:
1. Inline markdown (bold + inline code) round-trips verbatim.
2. Mixed paragraph + list round-trips verbatim (including `\n\n`).
3. Image syntax round-trips verbatim (sanitizer only strips at render time).
4. Fenced code block round-trips verbatim.
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


def _fresh_surface(c) -> tuple[str, str]:
    created = c._call("workspace.create") or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    c._call("workspace.select", {"workspace_id": ws_id})
    current = c._call("surface.current", {"workspace_id": ws_id}) or {}
    surface_id = str(current.get("surface_id") or "")
    _must(bool(surface_id), f"surface.current returned no surface_id: {current}")
    return ws_id, surface_id


def _set_description(c, surface_id: str, desc: str) -> dict:
    return c._call(
        "surface.set_metadata",
        {
            "surface_id": surface_id,
            "mode": "merge",
            "source": "explicit",
            "metadata": {"description": desc},
        },
    ) or {}


def _read_description(c, surface_id: str) -> str | None:
    state = c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}
    return state.get("description")


def main() -> int:
    stamp = int(time.time() * 1000)

    cases = [
        ("inline markdown", f"Running **10 shards** on `lat-{stamp}`"),
        ("paragraph + list", "Line one\n\nLine two\n\n- item a\n- item b"),
        ("image syntax", f"Deploy ![diagram](https://example.com/{stamp}.png) done"),
        ("fenced code", "before\n```swift\nlet x = 1\n```\nafter"),
    ]

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must(
            "surface.set_metadata" in methods
            and "surface.get_titlebar_state" in methods,
            f"Required M2/M7 methods missing. methods={sorted(methods)[:60]}",
        )

        for label, desc in cases:
            ws_id, surface_id = _fresh_surface(c)
            try:
                res = _set_description(c, surface_id, desc)
                _must(
                    (res.get("applied") or {}).get("description") is True,
                    f"[{label}] set_metadata did not apply: {res}",
                )
                got = _read_description(c, surface_id)
                _must(
                    got == desc,
                    f"[{label}] description round-trip mismatch:\n  expected: {desc!r}\n  got:      {got!r}",
                )
            finally:
                c.close_workspace(ws_id)

        # Tier 1 Phase 2 extension: user-set title + description must survive
        # an on-disk session round-trip with full source attribution. Uses
        # the DEBUG-only debug.session.save_and_load harness; the call is
        # wrapped in try/except so release builds (without the method)
        # skip the assertion cleanly.
        ws_id, surface_id = _fresh_surface(c)
        try:
            title_value = f"Shipping dashboard #{stamp}"
            description_value = "Backend refactor: Tier 1 Phase 2 persistence"
            res = c._call(
                "surface.set_metadata",
                {
                    "surface_id": surface_id,
                    "mode": "merge",
                    "source": "explicit",
                    "metadata": {
                        "title": title_value,
                        "description": description_value,
                    },
                },
            ) or {}
            applied = res.get("applied") or {}
            _must(
                applied.get("title") is True and applied.get("description") is True,
                f"[persist] set_metadata should apply title+description: {res}",
            )

            try:
                c._call("debug.session.save_and_load", {})
            except cmuxError as e:
                # DEBUG-only method; release builds do not have it. Skip.
                print(f"SKIP persist case: debug.session.save_and_load unavailable ({e})")
                return 0

            got_full = c._call(
                "surface.get_metadata",
                {"surface_id": surface_id, "include_sources": True},
            ) or {}
            md = got_full.get("metadata") or {}
            sources = got_full.get("metadata_sources") or {}
            _must(
                md.get("title") == title_value,
                f"[persist] title did not survive round-trip: {md}",
            )
            _must(
                md.get("description") == description_value,
                f"[persist] description did not survive round-trip: {md}",
            )
            title_src = sources.get("title") or {}
            desc_src = sources.get("description") or {}
            _must(
                title_src.get("source") == "explicit",
                f"[persist] title source should be 'explicit': {title_src}",
            )
            _must(
                desc_src.get("source") == "explicit",
                f"[persist] description source should be 'explicit': {desc_src}",
            )
        finally:
            c.close_workspace(ws_id)

    print("PASS: M7 description round-trip (inline, list, image, fenced code, persist)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
