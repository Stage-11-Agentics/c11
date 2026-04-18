#!/usr/bin/env python3
"""v2 regression: pane.confirm socket command.

Covers the error paths plus a timeout-driven round trip against a valid panel.
The happy-path "overlay appears → user accepts → ok" case requires UI input,
so it lives in the UI test suite (CloseTabPaneOverlayUITests) rather than here.
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


def _expect_error(c: cmux, method: str, params: dict, code: str, where: str) -> None:
    try:
        c._call(method, params)
    except cmuxError as exc:
        message = str(exc)
        if code in message:
            return
        raise cmuxError(f"{where}: expected error code '{code}', got: {message}")
    raise cmuxError(f"{where}: expected error '{code}' but call succeeded")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        ident = c.identify()
        caller = ident.get("caller") or {}
        panel_id = caller.get("surface_id")
        _must(bool(panel_id), f"identify should return caller.surface_id: {caller}")

        # 1) Missing panel_id → invalid_params
        _expect_error(c, "pane.confirm", {"title": "Test"},
                      code="invalid_params", where="missing panel_id")

        # 2) Missing title → invalid_params
        _expect_error(c, "pane.confirm", {"panel_id": str(panel_id)},
                      code="invalid_params", where="missing title")

        # 3) Unknown panel UUID → unknown_panel
        _expect_error(c,
                      "pane.confirm",
                      {"panel_id": "00000000-0000-0000-0000-000000000000", "title": "Test"},
                      code="unknown_panel",
                      where="unknown panel")

        # 4) Valid panel + short timeout → result=="dismissed".
        # The dialog briefly appears on the caller's own panel, then times out. The
        # socket thread blocks for the timeout window; keep it short so this test
        # remains fast even with many iterations.
        started = time.time()
        res = c._call(
            "pane.confirm",
            {
                "panel_id": str(panel_id),
                "title": "pane.confirm test",
                "message": "This should auto-dismiss.",
                "timeout": 0.5,
            },
        )
        elapsed = time.time() - started
        _must(isinstance(res, dict), f"pane.confirm should return dict: {res}")
        _must(res.get("result") == "dismissed",
              f"pane.confirm with short timeout should return dismissed, got: {res}")
        _must(elapsed >= 0.45, f"pane.confirm returned before timeout fired: {elapsed}s")
        _must(elapsed < 5.0, f"pane.confirm took too long: {elapsed}s")

    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
