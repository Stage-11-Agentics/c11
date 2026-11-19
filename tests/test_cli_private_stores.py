#!/usr/bin/env python3
"""C11H-364 L15-L18: the built CLI's own private-store writers.

`c11 snapshot --out`, `c11 restore <file>`, the tmux-compat store
(`set-buffer`) and Claude hook state (`claude-hook session-start`) write in the
CLI process, and no CLI file compiles into a test target. Each case runs the
built CLI with umask 022 in its own temporary home against a hermetic Unix
peer. No app, no live socket.

Requires an explicit C11_CLI_BIN.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

import json
from pathlib import Path
import socketserver
import stat
import subprocess
import tempfile
import threading
import time
import uuid

from fake_server_env import fake_server_env

TIMEOUT_SECONDS = 10
PASSWORD = "c11-fixture-only"
SNAPSHOT_BYTES = b'{"snapshot_id":"01C11H364SNAP","plan":{"panels":[]},"note":"token url"}\n'
CAPS = {
    "methods": ["panel.list", "snapshot.create", "snapshot.restore", "snapshot.restore_set",
                "agent.event.append", "conversation.push"],
    "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}],
}


class Peer:
    """A same-user Unix peer that answers each method from `answers` (default `{}`)."""

    def __init__(self, address: str):
        self.address = address
        self.answers: dict[str, dict] = {}
        peer = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                while True:
                    raw = self.rfile.readline()
                    if not raw:
                        return
                    line = raw.decode(errors="replace").strip()
                    if line.startswith("{"):
                        message = json.loads(line)
                        method = message.get("method")
                        result = CAPS if method == "system.capabilities" else peer.answers.get(method, {})
                        reply = (json.dumps({"id": message.get("id"), "ok": True, "result": result}) + "\n").encode()
                    else:
                        reply = b"OK\n"  # the auth prelude and v1 lines
                    try:
                        self.wfile.write(reply)
                        self.wfile.flush()
                    except BrokenPipeError:
                        return

        self.server = socketserver.ThreadingUnixStreamServer(address, Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def mode(path: Path) -> int:
    return stat.S_IMODE(os.lstat(path).st_mode)


def make_home(root: Path, name: str) -> Path:
    home = root / f"home-{name}"
    home.mkdir(mode=0o755)
    return home


def run(cli: str, peer: Peer, home: Path, *args: str, stdin: str | None = None,
        extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    base = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_", "TMUX"))}
    env = fake_server_env(peer.address, base=base)
    env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
               CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
               C11_QUIET_DISCOVERY="1")
    env.update(extra_env or {})
    return subprocess.run([cli, "--socket", peer.address, "--password", PASSWORD, *args],
                          input=stdin, env=env, capture_output=True, text=True, timeout=TIMEOUT_SECONDS)


def plant_store_snapshot(peer: Peer, home: Path) -> Path:
    """The file `snapshot.create` reports: 0600 in a 0700 store, as the app writes it."""
    store = home / ".c11-snapshots"
    store.mkdir(mode=0o700, exist_ok=True)
    os.chmod(store, 0o700)
    source = store / "01C11H364SNAP.json"
    source.write_bytes(SNAPSHOT_BYTES)
    os.chmod(source, 0o600)
    peer.answers["snapshot.create"] = {"snapshot_id": "01C11H364SNAP", "path": str(source),
                                       "panel_count": 1, "workspace_ref": "workspace:1"}
    return source


def case_a_snapshot_out_refuses_non_empty_folder(cli, peer, root):
    home = make_home(root, "a")
    source = plant_store_snapshot(peer, home)
    out = home / "Documents" / "snapshots"
    out.mkdir(parents=True)
    (out / "keep.txt").write_text("operator file")

    result = run(cli, peer, home, "snapshot", "--out", str(out))

    assert result.returncode != 0, f"exit 0: {result.stdout!r}"
    assert (out / "keep.txt").read_text() == "operator file", "keep.txt changed"
    assert out.is_dir() and not out.is_symlink(), "--out folder replaced"
    assert source.read_bytes() == SNAPSHOT_BYTES, "store snapshot lost"
    assert "is a folder that is not empty" in result.stderr, result.stderr
    assert str(source) in result.stderr, f"kept path not named: {result.stderr}"
    assert "destinationIsNonEmptyDirectory(" not in result.stderr, result.stderr


def case_b_snapshot_out_new_folders_0700_file_0600(cli, peer, root):
    home = make_home(root, "b")
    source = plant_store_snapshot(peer, home)
    desktop = home / "Desktop"
    desktop.mkdir(mode=0o755)
    os.chmod(desktop, 0o755)
    out = desktop / "new" / "dir" / "ws.json"

    result = run(cli, peer, home, "snapshot", "--out", str(out))

    assert result.returncode == 0, result.stderr
    assert mode(desktop / "new") == 0o700, oct(mode(desktop / "new"))
    assert mode(desktop / "new" / "dir") == 0o700, oct(mode(desktop / "new" / "dir"))
    assert mode(out) == 0o600, oct(mode(out))
    assert out.read_bytes() == SNAPSHOT_BYTES
    assert mode(desktop) == 0o755, "existing parent changed"
    assert not source.exists(), "store file kept after a written copy"


def write_outside(root: Path, name: str, payload: dict) -> tuple[Path, bytes]:
    folder = root / f"downloads-{name}"
    folder.mkdir()
    path = folder / "handoff.json"
    data = json.dumps(payload).encode()
    path.write_bytes(data)
    os.chmod(path, 0o644)
    return path, data


def case_c_restore_stages_into_new_private_store(cli, peer, root):
    home = make_home(root, "c")
    source, data = write_outside(root, "c", {"snapshot_id": "01C11H364RESTC", "plan": {}})
    peer.answers["snapshot.restore"] = {"workspaceRef": "workspace:2", "panelRefs": {}, "areaRefs": {}}

    result = run(cli, peer, home, "restore", str(source))

    assert result.returncode == 0, result.stderr
    store = home / ".c11-snapshots"
    staged = store / "01C11H364RESTC.json"
    assert mode(store) == 0o700, oct(mode(store))
    assert mode(staged) == 0o600, oct(mode(staged))
    assert staged.read_bytes() == data


def case_d_restore_tightens_existing_0755_store(cli, peer, root):
    home = make_home(root, "d")
    store = home / ".c11-snapshots"
    store.mkdir(mode=0o755)
    os.chmod(store, 0o755)
    source, _ = write_outside(root, "d", {"snapshot_id": "01C11H364RESTD", "plan": {}})
    peer.answers["snapshot.restore"] = {"workspaceRef": "workspace:2", "panelRefs": {}, "areaRefs": {}}

    result = run(cli, peer, home, "restore", str(source))

    assert result.returncode == 0, result.stderr
    assert mode(store) == 0o700, oct(mode(store))
    assert mode(store / "01C11H364RESTD.json") == 0o600


def case_e_restore_set_stages_into_private_sets(cli, peer, root):
    home = make_home(root, "e")
    source, data = write_outside(root, "e", {"set_id": "01C11H364SETE", "snapshots": []})
    peer.answers["snapshot.restore_set"] = {"set_id": "01C11H364SETE", "workspaces": []}

    result = run(cli, peer, home, "restore", str(source))

    assert result.returncode == 0, result.stderr
    sets = home / ".c11-snapshots" / "sets"
    staged = sets / "01C11H364SETE.json"
    assert mode(home / ".c11-snapshots") == 0o700, oct(mode(home / ".c11-snapshots"))
    assert mode(sets) == 0o700, oct(mode(sets))
    assert mode(staged) == 0o600, oct(mode(staged))
    assert staged.read_bytes() == data


def case_f_refusal_prints_its_sentence(cli, peer, root):
    home = make_home(root, "f")
    (home / ".cmuxterm").write_text("not a folder")

    result = run(cli, peer, home, "set-buffer", "--", "captured pane text")

    assert result.returncode != 0, f"exit 0: {result.stdout!r}"
    assert "must be a folder owned by the current user" in result.stderr, result.stderr
    assert "unsafeDirectory(" not in result.stderr, result.stderr


def case_g_tmux_compat_store_private(cli, peer, root):
    home = make_home(root, "g")
    result = run(cli, peer, home, "set-buffer", "--", "captured pane text")
    assert result.returncode == 0, result.stderr
    folder, store = home / ".cmuxterm", home / ".cmuxterm" / "tmux-compat-store.json"
    assert mode(folder) == 0o700, f"new folder {oct(mode(folder))}"
    assert mode(store) == 0o600, f"new store {oct(mode(store))}"

    # A 1.x store: a 0755 folder and a 0644 file.
    loose = make_home(root, "g-loose")
    folder, store = loose / ".cmuxterm", loose / ".cmuxterm" / "tmux-compat-store.json"
    folder.mkdir(mode=0o755)
    os.chmod(folder, 0o755)
    store.write_text('{"buffers":{},"hooks":{}}')
    os.chmod(store, 0o644)
    result = run(cli, peer, loose, "set-buffer", "--", "captured pane text")
    assert result.returncode == 0, result.stderr
    assert mode(folder) == 0o700, f"existing folder {oct(mode(folder))}"
    assert mode(store) == 0o600, f"existing store {oct(mode(store))}"


def case_h_claude_hook_state_private(cli, peer, root):
    home = make_home(root, "h")
    session = str(uuid.uuid4())
    result = run(cli, peer, home, "claude-hook", "session-start",
                 stdin=json.dumps({"session_id": session, "cwd": str(home), "source": "startup"}),
                 extra_env={"CMUX_BUNDLE_ID": "com.stage11.c11.debug.private-stores",
                            "CMUX_SURFACE_ID": str(uuid.uuid4()), "CMUX_WORKSPACE_ID": str(uuid.uuid4()),
                            "CMUX_CLAUDE_PID": "12345", "C11_AGENT_INTERACTIVE_PID": "12345",
                            "C11_AGENT_NOTE_SENT": "1"})
    assert result.returncode == 0, result.stderr
    folder, state = home / ".c11", home / ".c11" / "claude-hook-sessions.json"
    assert state.exists(), f"no hook state written: {sorted(p.name for p in folder.iterdir()) if folder.exists() else 'no ~/.c11'}"
    assert session in state.read_text(), "session not recorded"
    assert mode(folder) == 0o700, f"folder {oct(mode(folder))}"
    assert mode(state) == 0o600, f"state file {oct(mode(state))}"


CASES = [
    case_a_snapshot_out_refuses_non_empty_folder,
    case_b_snapshot_out_new_folders_0700_file_0600,
    case_c_restore_stages_into_new_private_store,
    case_d_restore_tightens_existing_0755_store,
    case_e_restore_set_stages_into_private_sets,
    case_f_refusal_prints_its_sentence,
    case_g_tmux_compat_store_private,
    case_h_claude_hook_state_private,
]


def main() -> int:
    cli = os.environ.get("C11_CLI_BIN")
    if not cli or not Path(cli).is_absolute() or not os.access(cli, os.X_OK):
        raise RuntimeError("C11_CLI_BIN must name an explicit absolute executable")
    os.umask(0o022)
    failures = []
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="c11-364-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        peer = Peer(str(root / "s"))
        try:
            for case in CASES:
                try:
                    case(cli, peer, root)
                    print(f"PASS: {case.__name__}", flush=True)
                except Exception as exc:
                    failures.append(case.__name__)
                    print(f"FAIL: {case.__name__}: {exc}", flush=True)
        finally:
            peer.close()
    print(f"{len(CASES) - len(failures)}/{len(CASES)} passed in {time.monotonic() - started:.1f} s", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
