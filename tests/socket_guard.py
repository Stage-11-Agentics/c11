#!/usr/bin/env python3
"""Stop a Python test from opening the operator's c11 socket.

``install()`` is the one guard every ``tests/test_*.py`` goes through. It
scrubs inherited socket and panel/workspace identity, pins the socket
variables to an unroutable sentinel, and refuses any AF_UNIX connect or CLI
subprocess aimed at a socket this process did not create.

The sentinel is not an implicit CLI default, so a child ``c11`` does not
auto-discover ``~/Library/Application Support/c11/c11.sock`` or ``/tmp/c11*.sock``.
"""

from __future__ import annotations

import errno
import os
import socket
import subprocess
import sys
import tempfile
import threading
from contextlib import contextmanager
from typing import Iterator, Mapping, Optional, Sequence

SENTINEL = "/c11-unroutable/socket.sock"

SOCKET_ENV_KEYS = (
    "C11_SOCKET",
    "C11_SOCKET_PATH",
    "CMUX_SOCKET_PATH",
    "CMUX_SOCKET",
)

IDENTITY_ENV_KEYS = (
    "C11_TAB_ID",
    "C11_SURFACE_ID",
    "C11_PANEL_ID",
    "C11_WORKSPACE_ID",
    "CMUX_TAB_ID",
    "CMUX_SURFACE_ID",
    "CMUX_PANEL_ID",
    "CMUX_WORKSPACE_ID",
    "C11_TAB_NUM",
    "C11_SURFACE_NUM",
    "C11_PANEL_NUM",
    "C11_WORKSPACE_NUM",
    "CMUX_TAB_NUM",
    "CMUX_SURFACE_NUM",
    "CMUX_PANEL_NUM",
    "CMUX_WORKSPACE_NUM",
    "TMUX",
    "TMUX_PANE",
)

# Paths the app and CLI treat as a shared default. Binding one would replace
# a live listener. Connecting to one reaches whatever is already running.
_WELL_KNOWN_EXACT = {
    "/tmp/c11.sock",
    "/tmp/c11-debug.sock",
    "/tmp/c11-nightly.sock",
    "/tmp/c11-staging.sock",
    "/tmp/cmux.sock",
    "/tmp/cmux-debug.sock",
    "/tmp/cmux-staging.sock",
}
_APP_SUPPORT_SUFFIXES = (
    "/Library/Application Support/c11/c11.sock",
    "/Library/Application Support/c11mux/cmux.sock",
)


class SocketGuardError(OSError):
    """A test tried to use a socket it did not create."""


_lock = threading.Lock()
_installed = False
_allowed: set[str] = set()
_temp_roots: list[str] = []
_captured_sockets: list[str] = []
_captured_identity: dict[str, str] = {}
_discovery_depth = 0

_orig_connect = socket.socket.connect
_orig_connect_ex = socket.socket.connect_ex
_orig_bind = socket.socket.bind
_orig_popen = subprocess.Popen
_orig_mkdtemp = tempfile.mkdtemp


# These scripts pkill, open, or quit an app, take the shared build lock, or
# send the close-tabs shortcut. The socket scrub does not stop that. A normal
# host must not start them. A sandbox guest exports the opt-in.
LIVE_APP_ENV = "C11_TEST_ALLOW_LIVE_APP"
LIVE_APP_SCRIPTS = frozenset(
    {
        "test_atlas_build_slots.py",
        "test_cmd_option_t_close_other_tabs_in_pane.py",
        "test_session_restore_unfocused_workspace_multi_window_cycle.py",
        "test_session_restore_unfocused_workspace_relaunch_cycle.py",
        "test_socket_access.py",
    }
)


def red_proof_requested() -> bool:
    """True only for the canary's deliberate unguarded run."""
    return (
        os.environ.get("C11_SOCKET_GUARD_RED_PROOF") == "1"
        and os.environ.get("C11_SOCKET_GUARD_DISABLED") == "1"
    )


def refuse_live_app(script_name: str) -> None:
    """Exit before a host-affecting script can start, unless a guest opted in."""
    if script_name not in LIVE_APP_SCRIPTS:
        return
    if os.environ.get(LIVE_APP_ENV) == "1":
        return
    print(
        f"refusing to start {script_name} on a normal host. "
        f"Set {LIVE_APP_ENV}=1 in a sandbox guest.",
        file=sys.stderr,
    )
    raise SystemExit(2)


def install() -> None:
    """Scrub the environment and arm the connect and subprocess refusals."""
    global _installed
    script = os.path.basename(sys.argv[0]) if sys.argv else ""
    refuse_live_app(script)
    if red_proof_requested():
        return
    with _lock:
        if _installed:
            return
        _capture_and_scrub()
        socket.socket.connect = _guard_connect  # type: ignore[method-assign]
        socket.socket.connect_ex = _guard_connect_ex  # type: ignore[method-assign]
        socket.socket.bind = _guard_bind  # type: ignore[method-assign]
        subprocess.Popen = _GuardedPopen  # type: ignore[misc]
        tempfile.mkdtemp = _guard_mkdtemp  # type: ignore[assignment]
        _installed = True


def allow(path: str) -> None:
    """Mark a socket path this test created, so connect and children may use it."""
    normalized = _normalize(path)
    with _lock:
        _allowed.add(normalized)
        _allowed.add(path)


def register_temp_root(path: str) -> None:
    """Allow every socket under a temp directory this process created."""
    normalized = _normalize(path)
    with _lock:
        if normalized not in _temp_roots:
            _temp_roots.append(normalized)


@contextmanager
def permit_implicit_discovery() -> Iterator[None]:
    """Let one child keep an implicit-default socket env so tag discovery can run.

    Captured operator sockets are still refused. The autodiscovery test is the
    only caller: its tagged socket is accepting before the CLI probes anything
    else.
    """
    global _discovery_depth
    with _lock:
        _discovery_depth += 1
    try:
        yield
    finally:
        with _lock:
            _discovery_depth -= 1


def _capture_and_scrub() -> None:
    for key in SOCKET_ENV_KEYS:
        value = os.environ.get(key, "").strip()
        if value:
            _captured_sockets.append(value)
        os.environ[key] = SENTINEL
    for key in IDENTITY_ENV_KEYS:
        value = os.environ.get(key)
        if value:
            _captured_identity[key] = value
        os.environ.pop(key, None)
    # A tag selects /tmp/<app>-debug-<tag>.sock. An inherited tag would point
    # discovery at the operator's dev app. Tests that need a tag set it themselves.
    os.environ.pop("C11_TAG", None)
    os.environ.pop("CMUX_TAG", None)


def _normalize(path: str) -> str:
    return os.path.realpath(path)


def _is_sentinel(path: str) -> bool:
    return path == SENTINEL or _normalize(path) == _normalize(SENTINEL)


def _is_allowed(path: str) -> bool:
    if _is_sentinel(path):
        return True
    normalized = _normalize(path)
    with _lock:
        if path in _allowed or normalized in _allowed:
            return True
        roots = list(_temp_roots)
    return any(
        normalized == root or normalized.startswith(root + os.sep) for root in roots
    )


def _is_captured_live(path: str) -> bool:
    normalized = _normalize(path)
    with _lock:
        captured = list(_captured_sockets)
    for live in captured:
        if path == live or normalized == _normalize(live):
            return True
    return False


def _is_well_known(path: str) -> bool:
    normalized = _normalize(path)
    if path in _WELL_KNOWN_EXACT or normalized in _WELL_KNOWN_EXACT:
        return True
    for suffix in _APP_SUPPORT_SUFFIXES:
        if path.endswith(suffix) or normalized.endswith(suffix):
            return True
    return _is_captured_live(path)


def _unix_path(address: object) -> Optional[str]:
    if isinstance(address, str):
        return address
    if isinstance(address, bytes):
        if not address or address.startswith(b"\0"):
            return None
        return os.fsdecode(address.split(b"\0", 1)[0])
    if isinstance(address, tuple) and address:
        return _unix_path(address[0])
    return None


def _refuse_unless_allowed(address: object) -> None:
    path = _unix_path(address)
    if path is None:
        raise SocketGuardError("refusing an unnamed unix socket")
    if _is_allowed(path):
        return
    # A path that does not exist cannot be a live listener. Missing-socket
    # tests connect there and get the CLI's own error. A canary or the
    # operator socket exists, so it is refused before the syscall.
    if not os.path.exists(path):
        return
    raise SocketGuardError(f"refusing to connect {path}: not a socket this test created")


def _guard_connect(self: socket.socket, address: object) -> None:
    if self.family == socket.AF_UNIX:
        _refuse_unless_allowed(address)
    _orig_connect(self, address)


def _guard_connect_ex(self: socket.socket, address: object) -> int:
    if self.family == socket.AF_UNIX:
        try:
            _refuse_unless_allowed(address)
        except SocketGuardError:
            return errno.EPERM
    return _orig_connect_ex(self, address)


def _guard_bind(self: socket.socket, address: object) -> None:
    if self.family == socket.AF_UNIX:
        path = _unix_path(address)
        if path is None:
            raise SocketGuardError("refusing to bind an unnamed unix socket")
        if _is_well_known(path) and not _is_allowed(path):
            raise SocketGuardError(f"refusing to bind well-known socket {path}")
        _orig_bind(self, address)
        allow(path)
        return
    _orig_bind(self, address)


def _guard_mkdtemp(*args: object, **kwargs: object) -> str:
    path = _orig_mkdtemp(*args, **kwargs)
    register_temp_root(path)
    return path


def _argv_socket_paths(args: Sequence[object]) -> list[str]:
    paths: list[str] = []
    for index, arg in enumerate(args):
        if not isinstance(arg, str):
            continue
        if arg == "--socket" and index + 1 < len(args):
            nxt = args[index + 1]
            if isinstance(nxt, str):
                paths.append(nxt)
        elif arg.startswith("--socket="):
            paths.append(arg.split("=", 1)[1])
    return paths


def _must_refuse(path: str) -> bool:
    if _is_allowed(path) or not os.path.exists(path):
        return False
    return True


def _sanitize_env(env: Mapping[str, str]) -> dict[str, str]:
    out = dict(env)
    with _lock:
        captured_identity = dict(_captured_identity)
        discovering = _discovery_depth > 0
    for key, captured in captured_identity.items():
        if out.get(key) == captured:
            out.pop(key, None)
    values = []
    for key in SOCKET_ENV_KEYS:
        raw = out.get(key, "").strip()
        if raw:
            values.append(raw)
    if discovering:
        for path in values:
            if _is_captured_live(path):
                raise SocketGuardError(
                    f"refusing to pass the operator socket {path} to a child"
                )
        return out
    for path in values:
        if _must_refuse(path):
            raise SocketGuardError(
                f"refusing to pass {path} to a child: not a socket this test created"
            )
    chosen: Optional[str] = None
    allowed_real = [path for path in values if _is_allowed(path) and not _is_sentinel(path)]
    allowed_norm = {_normalize(path) for path in allowed_real}
    if len(allowed_norm) > 1:
        raise SocketGuardError("a child env names more than one test socket")
    if allowed_real:
        chosen = allowed_real[0]
    else:
        missing = [path for path in values if not _is_sentinel(path) and not os.path.exists(path)]
        missing_norm = {_normalize(path) for path in missing}
        if len(missing_norm) > 1:
            raise SocketGuardError("a child env names more than one missing socket")
        chosen = missing[0] if missing else SENTINEL
    for key in SOCKET_ENV_KEYS:
        out[key] = chosen
    return out


def _prepare_child(args: object, env: Optional[Mapping[str, str]]) -> tuple[object, dict[str, str]]:
    base = dict(os.environ if env is None else env)
    if isinstance(args, (list, tuple)):
        for path in _argv_socket_paths(args):
            if _must_refuse(path):
                raise SocketGuardError(
                    f"refusing --socket {path}: not a socket this test created"
                )
    elif isinstance(args, str):
        with _lock:
            captured = list(_captured_sockets)
        for live in captured:
            if live and live in args:
                raise SocketGuardError(
                    f"refusing a shell command that names the operator socket {live}"
                )
    return args, _sanitize_env(base)


class _GuardedPopen(_orig_popen):  # type: ignore[misc, valid-type]
    def __init__(self, args: object, *args_rest: object, **kwargs: object) -> None:
        env = kwargs.get("env")
        mapped: Optional[Mapping[str, str]]
        if env is None:
            mapped = None
        else:
            mapped = env  # type: ignore[assignment]
        prepared, sanitized = _prepare_child(args, mapped)
        kwargs["env"] = sanitized
        super().__init__(prepared, *args_rest, **kwargs)


def install_for_test_argv() -> None:
    """Used by ``cmux.py`` so an import from a test cannot probe first."""
    if red_proof_requested():
        return
    main = os.path.basename(sys.argv[0]) if sys.argv else ""
    if main.startswith("test_") and main.endswith(".py"):
        install()
