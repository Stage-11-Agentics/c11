#!/usr/bin/env python3
"""Environment guard for tests that point the CLI at a fake socket server.

The CLI resolves its socket from C11_SOCKET, C11_SOCKET_PATH, CMUX_SOCKET_PATH and
CMUX_SOCKET (in that order of precedence) and its caller identity from the
C11_/CMUX_ TAB/SURFACE/PANEL/WORKSPACE ids. A test that sets only some of them can,
when run from inside c11, reach the live app and act on the operator's workspace.
Build the child environment with `fake_server_env` so that cannot happen.
"""

from __future__ import annotations

import os
from typing import Mapping, Optional

SOCKET_ENV_KEYS = ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH", "CMUX_SOCKET")

IDENTITY_ENV_KEYS = (
    "C11_TAB_ID", "C11_SURFACE_ID", "C11_PANEL_ID", "C11_WORKSPACE_ID",
    "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_WORKSPACE_ID",
    "C11_TAB_NUM", "C11_SURFACE_NUM", "CMUX_SURFACE_NUM",
    "TMUX", "TMUX_PANE",
)


def fake_server_env(
    socket_path: Optional[str],
    base: Optional[Mapping[str, str]] = None,
    *,
    scrub_identity: bool = True,
) -> dict[str, str]:
    """A copy of `base` (default: os.environ) whose every socket variable names `socket_path`.

    With `socket_path=None` the socket variables are removed instead (for tests that
    exercise discovery and set their own). Caller identity is scrubbed unless the test
    supplies its own afterwards.
    """
    env = dict(os.environ if base is None else base)
    for key in SOCKET_ENV_KEYS:
        env.pop(key, None)
        if socket_path is not None:
            env[key] = socket_path
    if scrub_identity:
        for key in IDENTITY_ENV_KEYS:
            env.pop(key, None)
    return env
