#!/usr/bin/env python3
"""Stop a Python test from opening the operator's c11 socket.

``install()`` is the one guard every ``tests/test_*.py`` goes through. It
scrubs inherited socket and panel/workspace identity, pins the socket
variables to an unroutable sentinel, and refuses any AF_UNIX connect or child
process aimed at a socket this process did not create. Children started through
``subprocess``, ``os.exec*``, ``os.spawn*``, ``os.posix_spawn*`` and ``os.system``
are all checked, including ``--socket`` and socket variables inside a shell string.

This stops a test that picks up the live socket by accident or by a plain
spelling. It cannot read a path computed at run time inside a child, such as
``$(cat file)`` or a script file's contents; the scrubbed environment is the
protection there.

The sentinel is not an implicit CLI default, so a child ``c11`` does not
auto-discover ``~/Library/Application Support/c11/c11.sock`` or ``/tmp/c11*.sock``.
"""

from __future__ import annotations

import errno
import inspect
import os
import re
import shlex
import signal
import socket
import stat
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
_TAGGED_SOCKET = re.compile(r"^(?:/private)?/tmp/(?:c11|cmux)[^/]*\.sock$")
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
_orig_execve = os.execve
_orig_system = os.system
# The l-forms (spawnl, execlp, ...) and execvp/execvpe call these through
# module globals, so wrapping the v-forms covers them too.
_SPAWN_NAMES = ("spawnv", "spawnve", "spawnvp", "spawnvpe")
_orig_spawn = {name: getattr(os, name) for name in _SPAWN_NAMES if hasattr(os, name)}
_POSIX_SPAWN_NAMES = ("posix_spawn", "posix_spawnp")
_orig_posix_spawn = {
    name: getattr(os, name) for name in _POSIX_SPAWN_NAMES if hasattr(os, name)
}


# These scripts pkill, open, or quit an app, or send the close-tabs shortcut.
# The socket scrub does not stop that. A normal host must not start them.
# A sandbox guest exports the opt-in. The Atlas slot suite is not in this set:
# it keeps its locks under C11_ATLAS_SLOTS_DIR and CI runs it with no opt-in.
LIVE_APP_ENV = "C11_TEST_ALLOW_LIVE_APP"
LIVE_APP_SCRIPTS = frozenset(
    {
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


def _entry_script_names(caller_file: Optional[str]) -> list[str]:
    """Every name the running test could go by.

    ``python3 tests/test_x.py`` puts it in ``argv[0]``. ``-m unittest`` and
    pytest put a runner there, so the file that called ``install()`` and
    ``__main__.__file__`` are checked too.
    """
    names = []
    candidates = [
        sys.argv[0] if sys.argv else None,
        caller_file,
        getattr(sys.modules.get("__main__"), "__file__", None),
    ]
    for candidate in candidates:
        if isinstance(candidate, str) and candidate:
            name = os.path.basename(candidate)
            if name not in names:
                names.append(name)
    return names


def install() -> None:
    """Scrub the environment and arm the connect and subprocess refusals."""
    global _installed
    caller_file = sys._getframe(1).f_globals.get("__file__")
    for script in _entry_script_names(caller_file):
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
        os.execv = _guard_execv  # type: ignore[assignment]
        os.execve = _guard_execve  # type: ignore[assignment]
        os.system = _guard_system  # type: ignore[assignment]
        for name, original in _orig_spawn.items():
            make_guard = _make_spawn_env_guard if name.endswith("e") else _make_spawn_guard
            setattr(os, name, make_guard(name, original))
        for name, original in _orig_posix_spawn.items():
            setattr(os, name, _make_posix_spawn_guard(original))
        _installed = True


def allow(path: str) -> None:
    """Mark a socket path this test created, so connect and children may use it.

    Only the resolved path is kept, so a symlink swapped in later does not
    inherit the allowance. A path that resolves to the operator socket, to an
    existing well-known socket, or through a symlink to an existing socket this
    test did not create is refused.
    """
    normalized = _normalize(path)
    if _is_captured_live(path):
        raise SocketGuardError(f"refusing to allow the operator socket {path}")
    if _is_socket_file(normalized) and not _is_allowed(normalized):
        if os.path.islink(path):
            raise SocketGuardError(
                f"refusing to allow {path}: it resolves to {normalized}, "
                "a socket this test did not create"
            )
        if _is_well_known(normalized):
            raise SocketGuardError(
                f"refusing to allow {path}: a shared default socket that already exists"
            )
    _allow_resolved(normalized)


def _allow_resolved(normalized: str) -> None:
    with _lock:
        _allowed.add(normalized)


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
            # A relative value means the directory it was inherited in, not a later one.
            _captured_sockets.append(value if os.path.isabs(value) else _normalize(value))
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


def _is_socket_file(path: str) -> bool:
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except (OSError, ValueError):
        return False


def _is_sentinel(path: str) -> bool:
    return _normalize(path) == _normalize(SENTINEL)


def _is_allowed(path: str) -> bool:
    """Decide on the resolved path only. A link inherits nothing from its name."""
    if _is_sentinel(path):
        return True
    normalized = _normalize(path)
    if _is_captured_live(normalized):
        return False
    with _lock:
        if normalized in _allowed:
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


def _names_shared_socket(path: str) -> bool:
    """A default socket, or a tagged one the CLI's ``/tmp`` discovery would find."""
    normalized = _normalize(path)
    if _is_well_known(path):
        return True
    return _TAGGED_SOCKET.match(path) is not None or _TAGGED_SOCKET.match(normalized) is not None


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
        _allow_resolved(_normalize(path))
        return
    _orig_bind(self, address)


def _guard_mkdtemp(*args: object, **kwargs: object) -> str:
    path = _orig_mkdtemp(*args, **kwargs)
    register_temp_root(path)
    return path


def _as_arg(arg: object) -> Optional[str]:
    """Render one Popen argument. Path and bytes are ordinary argv values."""
    if isinstance(arg, str):
        return arg
    if isinstance(arg, bytes):
        return os.fsdecode(arg)
    try:
        rendered = os.fspath(arg)  # type: ignore[arg-type]
    except TypeError:
        return None
    if isinstance(rendered, str):
        return rendered
    if isinstance(rendered, bytes):
        return os.fsdecode(rendered)
    return None


_SHELL_MARKERS = re.compile(r"[\s;&|<>()`$'\"=]")
_ENV_REFERENCE = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
_ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.DOTALL)
_MAX_NESTING = 4
_MAX_DIRECTORIES = 16
_DIRECTORY_CHANGERS = frozenset({"cd", "pushd", "chdir", "-C"})
_SHELL_OPERATOR_CHARS = frozenset("();<>|&")
# A path character on either side makes it a different path: live.sock.backup.
_PATH_CHARS = r"[\w./~-]"
_MAX_PATH_TOKEN = 1024


def _shell_tokens(text: str) -> list[str]:
    """Split a command string the way a POSIX shell would, near enough."""
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        return text.split()


def _expand(token: str, env: Mapping[str, str]) -> str:
    """Expand ``$VAR``, ``${VAR}`` and a leading ``~`` from the child's env."""
    def lookup(match: "re.Match[str]") -> str:
        name = match.group(1) or match.group(2)
        return env.get(name, match.group(0))

    expanded = _ENV_REFERENCE.sub(lookup, token)
    if expanded == "~" or expanded.startswith("~/"):
        home = env.get("HOME")
        if home:
            expanded = home + expanded[1:]
    return expanded


def _resolve_candidate(token: str, cwd: str) -> Optional[str]:
    if not token or len(token) > _MAX_PATH_TOKEN or "\0" in token:
        return None
    if os.path.isabs(token):
        return token
    if "/" in token or token.endswith(".sock"):
        return os.path.join(cwd, token)
    return None


def _token_candidates(token: str) -> list[str]:
    """The token, and what follows ``=`` or ``:`` (``K=/x``, ``unix:/x``)."""
    out = [token]
    for sep in ("=", ":"):
        if sep in token:
            out.append(token.split(sep, 1)[1])
    return out


def _effective_cwd(cwd: Optional[object]) -> str:
    """The directory a child starts in. A deleted cwd must not break the launch."""
    try:
        base = os.fspath(cwd) if cwd is not None else os.getcwd()  # type: ignore[arg-type]
        return os.path.abspath(os.fsdecode(base))
    except (TypeError, OSError):
        return os.sep


def _command_directories(
    tokens: Sequence[str],
    env: Mapping[str, str],
    directories: Sequence[str],
) -> tuple[list[str], bool]:
    """Every directory these words may run in, and whether one could not be read.

    A string can branch (``cd a || cd b``) or use a subshell, so a relative path
    is checked against all of them rather than by following the shell's order.
    """
    known = list(directories)
    unreadable = False
    for index, token in enumerate(tokens):
        target: Optional[str] = None
        if token.startswith("--chdir="):
            target = token.split("=", 1)[1]
        elif token in _DIRECTORY_CHANGERS:
            for word in tokens[index + 1 :]:
                if set(word) <= _SHELL_OPERATOR_CHARS:
                    break
                if word.startswith("-") and word != "-":
                    continue
                target = word
                break
            else:
                target = None
            if target is None:
                target = env.get("HOME")
        else:
            continue
        if target is None or target == "-":
            continue
        expanded = _expand(target, env)
        if any(char in expanded for char in "$`*?["):
            unreadable = True
            continue
        for base in list(known):
            changed = os.path.join(base, expanded)
            if changed not in known:
                known.append(changed)
        if len(known) > _MAX_DIRECTORIES:
            return known, True
    return known, unreadable


def _named_socket_refusal(
    value: str,
    env: Mapping[str, str],
    directories: Sequence[str],
    unreadable: bool,
    how: str,
) -> None:
    """``--socket X`` or ``C11_SOCKET_PATH=X``: refuse X unless this test made it."""
    expanded = _expand(value, env)
    if not expanded or len(expanded) > _MAX_PATH_TOKEN or "\0" in expanded:
        return
    if unreadable and not os.path.isabs(expanded):
        raise SocketGuardError(
            f"refusing {how} {expanded}: relative, after a directory change this guard cannot read"
        )
    for directory in directories:
        path = os.path.join(directory, expanded)
        if _must_refuse(path):
            raise SocketGuardError(f"refusing {how} {path}: not a socket this test created")


def _check_tokens(
    tokens: Sequence[str],
    env: Mapping[str, str],
    directories: Sequence[str],
    unreadable: bool,
    depth: int,
) -> None:
    # `D=/x; c11 --socket $D/s.sock` sets its own variable before using it.
    env = dict(env)
    for token in tokens:
        match = _ASSIGNMENT.match(token)
        if match:
            env[match.group(1)] = _expand(match.group(2), env)
    directories, changed_unreadable = _command_directories(tokens, env, directories)
    unreadable = unreadable or changed_unreadable
    # `cd /x; c11 ping` with C11_SOCKET_PATH=s.sock reaches /x/s.sock.
    for key in SOCKET_ENV_KEYS:
        value = env.get(key, "").strip()
        if value and not os.path.isabs(value):
            _named_socket_refusal(value, env, directories, unreadable, f"{key}=")
    for index, token in enumerate(tokens):
        if token == "--socket" and index + 1 < len(tokens):
            _named_socket_refusal(tokens[index + 1], env, directories, unreadable, "--socket")
        elif token.startswith("--socket="):
            _named_socket_refusal(token.split("=", 1)[1], env, directories, unreadable, "--socket")
        if "=" in token:
            key, value = token.split("=", 1)
            if key in SOCKET_ENV_KEYS:
                _named_socket_refusal(value, env, directories, unreadable, f"{key}=")
        for candidate in _token_candidates(_expand(token, env)):
            for directory in directories:
                path = _resolve_candidate(candidate, directory)
                if path is None:
                    continue
                if _is_captured_live(path):
                    raise SocketGuardError(
                        f"refusing a command that names the operator socket {path}"
                    )
                # A bare word only mentions a path, and a helper's fixture socket is
                # fine to mention. Refuse it only when it names a shared c11 socket.
                if _names_shared_socket(path) and _is_socket_file(path) and not _is_allowed(path):
                    raise SocketGuardError(
                        f"refusing a command that names the shared socket {path}"
                    )
        if depth < _MAX_NESTING and _SHELL_MARKERS.search(token):
            nested = _shell_tokens(token)
            if nested and nested != [token]:
                _check_tokens(nested, env, directories, unreadable, depth + 1)


def _names_captured_endpoint(text: str, captured: Sequence[str]) -> Optional[str]:
    """A captured path as a complete endpoint inside a word: ``UNIX-CONNECT:/x,retry=1``."""
    for live in captured:
        for spelling in {live, _normalize(live)}:
            if spelling and re.search(
                rf"(?<!{_PATH_CHARS}){re.escape(spelling)}(?!{_PATH_CHARS})", text
            ):
                return live
    return None


def _check_command(args: object, env: Mapping[str, str], cwd: Optional[object] = None) -> None:
    """Refuse an argv list or a shell string that would hand a child a foreign socket.

    List items are argv words. Any word that could be a shell command
    (``sh -c "..."``, ``env K=V cmd``, ``shell=True``) is tokenized again,
    so ``--socket`` or ``C11_SOCKET_PATH=`` inside the string is seen.
    """
    if not isinstance(args, list):
        rendered = _as_arg(args)
        if rendered is None:
            return
        texts = [rendered]
        tokens = _shell_tokens(rendered)
    else:
        texts = [arg for arg in (_as_arg(item) for item in args) if arg is not None]
        tokens = texts
    with _lock:
        captured = list(_captured_sockets)
    for text in texts:
        live = _names_captured_endpoint(text, captured)
        if live is not None:
            raise SocketGuardError(f"refusing a command that names the operator socket {live}")
    _check_tokens(tokens, env, [_effective_cwd(cwd)], False, 0)


def _must_refuse(path: str) -> bool:
    if _is_allowed(path) or not os.path.exists(path):
        return False
    return True


def _sanitize_env(env: Mapping[object, object], cwd: Optional[object] = None) -> dict[str, str]:
    # Popen and execve take bytes keys too. Decode them, or b"C11_SOCKET_PATH"
    # would pass unseen beside the sanitized str key.
    out = {os.fsdecode(key): os.fsdecode(value) for key, value in env.items()}  # type: ignore[arg-type]
    with _lock:
        captured_identity = dict(_captured_identity)
        discovering = _discovery_depth > 0
    for key, captured in captured_identity.items():
        if out.get(key) == captured:
            out.pop(key, None)
    # A relative value means a path under the child's directory, not this process's.
    directory = _effective_cwd(cwd)

    def in_child(path: str) -> str:
        return os.path.join(directory, path)

    values = []
    for key in SOCKET_ENV_KEYS:
        raw = out.get(key, "").strip()
        if raw:
            values.append(raw)
    if discovering:
        for path in values:
            if _is_captured_live(in_child(path)):
                raise SocketGuardError(
                    f"refusing to pass the operator socket {path} to a child"
                )
        return out
    for path in values:
        if _must_refuse(in_child(path)):
            raise SocketGuardError(
                f"refusing to pass {path} to a child: not a socket this test created"
            )
    chosen: Optional[str] = None
    allowed_real = [
        path
        for path in values
        if _is_allowed(in_child(path)) and not _is_sentinel(in_child(path))
    ]
    allowed_norm = {_normalize(in_child(path)) for path in allowed_real}
    if len(allowed_norm) > 1:
        raise SocketGuardError("a child env names more than one test socket")
    if allowed_real:
        chosen = allowed_real[0]
    else:
        missing = [
            path
            for path in values
            if not _is_sentinel(in_child(path)) and not os.path.exists(in_child(path))
        ]
        missing_norm = {_normalize(in_child(path)) for path in missing}
        if len(missing_norm) > 1:
            raise SocketGuardError("a child env names more than one missing socket")
        chosen = missing[0] if missing else SENTINEL
    for key in SOCKET_ENV_KEYS:
        out[key] = chosen
    return out


def _prepare_child(
    args: object,
    env: Optional[Mapping[str, str]],
    cwd: Optional[object] = None,
) -> tuple[object, dict[str, str]]:
    sanitized = _sanitize_env(os.environ if env is None else env, cwd)
    # Popen takes any iterable. Read it once here, or the scan would see nothing
    # (or use up a generator the child still needs).
    if not isinstance(args, (str, bytes, os.PathLike)):
        args = list(args)  # type: ignore[call-overload]
    _check_command(args, sanitized, cwd)
    return args, sanitized


# Popen(args, bufsize, executable, stdin, stdout, stderr, preexec_fn, close_fds,
# shell, cwd, env, ...), counted after args.
_POPEN_CWD_INDEX = 8
_POPEN_ENV_INDEX = 9


class _GuardedPopen(_orig_popen):  # type: ignore[misc, valid-type]
    def __init__(self, args: object, *args_rest: object, **kwargs: object) -> None:
        rest = list(args_rest)
        cwd = rest[_POPEN_CWD_INDEX] if len(rest) > _POPEN_CWD_INDEX else kwargs.get("cwd")
        positional_env = len(rest) > _POPEN_ENV_INDEX
        env = rest[_POPEN_ENV_INDEX] if positional_env else kwargs.get("env")
        prepared, sanitized = _prepare_child(args, env, cwd)  # type: ignore[arg-type]
        if positional_env:
            rest[_POPEN_ENV_INDEX] = sanitized
        else:
            kwargs["env"] = sanitized
        super().__init__(prepared, *rest, **kwargs)


def _guard_execv(path: object, argv: Sequence[object]) -> None:
    """``execv`` inherits ``os.environ``. Exec with the sanitized copy instead."""
    _, sanitized = _prepare_child(list(argv), None)
    _orig_execve(path, argv, sanitized)


def _guard_execve(path: object, argv: Sequence[object], env: Mapping[str, str]) -> None:
    # A bad env is the original's TypeError. None must not mean "inherit" here.
    if not isinstance(env, Mapping):
        _orig_execve(path, argv, env)
        return
    _, sanitized = _prepare_child(list(argv), env)
    _orig_execve(path, argv, sanitized)


def _guard_system(*args: object, **kwargs: object) -> int:
    """Run ``/bin/sh -c`` as ``system(3)`` does, but with the sanitized environment.

    ``os.system`` can only inherit ``os.environ``. Spawning keeps that process-wide
    mapping untouched, and the return value is the same raw wait status. The
    parameter's name differs by Python version, so the original's signature binds it.
    """
    bound = _SYSTEM_SIGNATURE.bind(*args, **kwargs)
    command = next(iter(bound.arguments.values()))
    _, sanitized = _prepare_child(command, None)
    blocked = {signal.SIGINT, signal.SIGQUIT, signal.SIGCHLD}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        pid = _orig_posix_spawn["posix_spawn"](
            "/bin/sh",
            ["sh", "-c", os.fsdecode(command)],  # type: ignore[arg-type]
            sanitized,
            setsigmask=previous,
        )
        _, status = os.waitpid(pid, 0)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    return status


_SYSTEM_SIGNATURE = inspect.signature(_orig_system)
_guard_system.__signature__ = _SYSTEM_SIGNATURE  # type: ignore[attr-defined]


def _make_spawn_guard(name: str, original: object) -> object:
    """``spawnv`` and ``spawnvp``. The child's guarded execv passes the sanitized env."""

    def guard(mode: int, file: object, args: Sequence[object]) -> int:
        _prepare_child(list(args), None)
        return original(mode, file, args)  # type: ignore[operator]

    guard.__name__ = name
    return guard


def _make_spawn_env_guard(name: str, original: object) -> object:
    """``spawnve`` and ``spawnvpe``, whose ``env`` is a required argument."""

    def guard(mode: int, file: object, args: Sequence[object], env: Mapping[str, str]) -> int:
        # A bad env fails in the original's child. None must not mean "inherit" here.
        if not isinstance(env, Mapping):
            return original(mode, file, args, env)  # type: ignore[operator]
        _, sanitized = _prepare_child(list(args), env)
        return original(mode, file, args, sanitized)  # type: ignore[operator]

    guard.__name__ = name
    return guard


def _make_posix_spawn_guard(original: object) -> object:
    def guard(path: object, argv: Sequence[object], env: Mapping[str, str], *rest: object, **kwargs: object) -> int:
        # Since Python 3.13, None means inherit. Before that it is a TypeError.
        if env is None and sys.version_info >= (3, 13):
            env = os.environ
        if not isinstance(env, Mapping):
            return original(path, argv, env, *rest, **kwargs)  # type: ignore[operator]
        _, sanitized = _prepare_child(list(argv), env)
        return original(path, argv, sanitized, *rest, **kwargs)  # type: ignore[operator]

    guard.__name__ = getattr(original, "__name__", "posix_spawn")
    return guard


def install_for_test_argv() -> None:
    """Used by ``cmux.py`` so an import from a test cannot probe first."""
    if red_proof_requested():
        return
    main = os.path.basename(sys.argv[0]) if sys.argv else ""
    if main.startswith("test_") and main.endswith(".py"):
        install()
