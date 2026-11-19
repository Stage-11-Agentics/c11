#!/usr/bin/env python3
"""Exercise SSH startup from the CLI through isolated bash, zsh and fish shells, and the
master socket's ControlPath: a private 0700 folder of this user's, never shared /tmp.

Uses a fake app socket and SSH executable; it never connects to an app or host.
Set C11_CLI_BIN to the Debug CLI built from the current checkout (the ControlPath checks
plant hostile folders under C11_SSH_CONTROL_DIR_TEST_BASE, which only Debug honours).
"""
from __future__ import annotations
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

import json
import os
import re
from pathlib import Path
import shlex
import shutil
import socketserver
import subprocess
import stat
import tempfile
import threading

from fake_server_env import fake_server_env
from test_cli_socket_deadline import resolve_c11_cli

MESSAGE = "c11 commands are not available over c11 ssh in this version"
SOCKET_KEYS = ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH", "CMUX_SOCKET_PASSWORD", "CMUX_RELAY_TOKEN")
WORKSPACE = "11111111-1111-4111-8111-111111111111"
# OpenSSH binds the master at "<ControlPath>.<16 random>" before renaming it; sun_path holds 103 bytes.
OPENSSH_BIND_SUFFIX = 17
SUN_PATH_MAX = 103
REFUSAL = "is not a private folder you own"

SSH_STUB = """#!/usr/bin/env python3
import json, os, stat, subprocess, sys
args = sys.argv[1:]
control = next((a[len("ControlPath="):] for a in args if a.startswith("ControlPath=")), None)
record = {"control_path": control}
if control:
    folder = os.path.dirname(control)
    try:
        info = os.lstat(folder)
        record.update(is_link=stat.S_ISLNK(info.st_mode), is_dir=stat.S_ISDIR(info.st_mode),
                      uid=info.st_uid, mode=stat.S_IMODE(info.st_mode))
    except FileNotFoundError:
        record["missing"] = True
if os.environ.get("C11_TEST_SSH_RECORD"):
    with open(os.environ["C11_TEST_SSH_RECORD"], "a") as out:
        out.write(json.dumps(record) + "\\n")
if os.environ.get("C11_TEST_SSH_EXIT_EARLY") == "1":
    raise SystemExit(0)
remote = next(arg[len("RemoteCommand="):] for arg in args if arg.startswith("RemoteCommand="))
assert "-R" not in args
raise SystemExit(subprocess.call([os.environ["SHELL"], "-c", remote.replace("%%", "%")]))
"""


def control_path_of(options: list[str]) -> str:
    return next(option.split("=", 1)[1] for option in options if option.lower().startswith("controlpath="))


def assert_private_folder(folder: Path) -> None:
    info = os.lstat(folder)
    assert stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode), folder
    assert info.st_uid == os.getuid(), (folder, info.st_uid)
    assert stat.S_IMODE(info.st_mode) == 0o700, (folder, oct(info.st_mode))


def assert_fits_sun_path(control_path: str) -> None:
    assert len(control_path.encode()) + OPENSSH_BIND_SUFFIX <= SUN_PATH_MAX, (len(control_path), control_path)


def main() -> None:
    cli = resolve_c11_cli()
    requests: list[dict] = []

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                if not line.startswith(b"{"):
                    self.wfile.write(b"OK\n")
                    continue
                request = json.loads(line)
                requests.append(request)
                method = request["method"]
                result = {"workspace_id": WORKSPACE, "remote": {"state": "connecting"}}
                if method == "system.capabilities":
                    result = {"methods": ["panel.list", "area.list", "workspace.create", "workspace.remote.configure"],
                              "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}
                self.wfile.write((json.dumps({"id": request["id"], "ok": True, "result": result}) + "\n").encode())

    with tempfile.TemporaryDirectory(prefix="c11-ssh-shell-", dir="/tmp") as temp:
        root = Path(temp)
        socket_path = str(root / "app.sock")
        server = socketserver.ThreadingUnixStreamServer(socket_path, Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            result = subprocess.run([cli, "--socket", socket_path, "--json", "ssh", "shell-fixture"], env=fake_server_env(socket_path), text=True, capture_output=True, timeout=20)
            assert result.returncode == 0, result.stderr
            payload = json.loads(result.stdout)
            configure = next(r["params"] for r in requests if r["method"] == "workspace.remote.configure")
            assert not ({"relay_id", "relay_token", "local_socket_path"} & configure.keys()), configure
            assert "remote_relay_port" not in payload, payload
            assert payload["ssh_session_id"] == configure["relay_port"]
            initial = next(r["params"]["initial_command"] for r in requests if r["method"] == "workspace.create")
            later = configure["terminal_startup_command"]
            startup_paths = [Path(shlex.split(command)[0]) for command in (initial, later)]
            stub = root / "bin"
            stub.mkdir()
            ssh = stub / "ssh"
            ssh.write_text(SSH_STUB)
            ssh.chmod(0o700)

            # The default master socket lives in this user's private temp folder, not /tmp,
            # and the app's batch helpers and every terminal name the same path.
            control_path = control_path_of(configure["ssh_options"])
            user_temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], text=True, capture_output=True, check=True).stdout.strip().rstrip("/")
            assert control_path.startswith(user_temp + "/c11-ssh/"), (control_path, user_temp)
            assert not control_path.startswith(("/tmp/", "/private/tmp/")), control_path
            assert_fits_sun_path(control_path)
            assert_private_folder(Path(control_path).parent)
            assert f"ControlPath={control_path}" in payload["ssh_command"], payload["ssh_command"]
            print("PASS: default ControlPath sits in the per-user 0700 c11-ssh folder and fits sun_path")
            control_path_checks(cli, root, socket_path, requests, stub, control_path)
            shells = [path for path in ("/bin/bash", "/bin/zsh", shutil.which("fish")) if path and Path(path).exists()]
            assert len(shells) >= 2, "bash and zsh are required"
            for shell in shells:
                for index, command in enumerate((initial, later)):
                    home = root / f"{Path(shell).name}-{index}"
                    home.mkdir()
                    stale = 'export CMUX_SOCKET_PATH=old-socket\nexport PATH="/usr/bin:/bin:$PATH"\nalias c11="echo STALE_COMMAND"\nalias cmux="echo STALE_COMMAND"\n'
                    for name in (".bash_profile", ".bashrc", ".zshrc", ".zlogin"):
                        (home / name).write_text(stale)
                    fish_config = home / ".config/fish"
                    fish_config.mkdir(parents=True)
                    (fish_config / "config.fish").write_text('set -gx CMUX_SOCKET_PATH old-socket\nset -gx PATH /usr/bin /bin $PATH\nfunction c11; echo STALE_COMMAND; end\nfunction cmux; echo STALE_COMMAND; end\n')
                    env = fake_server_env(None)
                    env.update(HOME=str(home), SHELL=shell, PATH=f"{stub}:{os.environ['PATH']}", XDG_CONFIG_HOME=str(home / ".config"))
                    env.pop("ZDOTDIR", None)
                    for key in SOCKET_KEYS:
                        env[key] = "old-socket"
                    # Explicitly pass no real caller identity; session-end cannot reach the operator.
                    probe = "c11 ping\ncmux ping\n/bin/sh -c 'c11 ping; printf \"C11_STATUS=%s\\n\" \"$?\"; cmux ping; printf \"CMUX_STATUS=%s\\n\" \"$?\"'\n/usr/bin/env\n/bin/sh -c 'printf UMASK=; umask'\nprintf 'SHELL_OK\\n'\nexit\n"
                    run = subprocess.run(["/bin/sh", "-c", "umask 022; exec " + command], input=probe, env=env, text=True, capture_output=True, timeout=15)
                    assert run.returncode == 0, (shell, run.stdout, run.stderr)
                    assert "SHELL_OK" in run.stdout and "C11_STATUS=1" in run.stdout and "CMUX_STATUS=1" in run.stdout, (shell, run.stdout)
                    assert re.search(r"^UMASK=0*22$", run.stdout, re.MULTILINE), (shell, run.stdout)
                    assert run.stderr.count(MESSAGE) == 4, (shell, run.stderr)
                    assert "STALE_COMMAND" not in run.stdout, (shell, run.stdout)
                    for key in SOCKET_KEYS:
                        assert not any(line.startswith(key + "=") for line in run.stdout.splitlines()), (shell, key, run.stdout)
                    print(f"PASS: {Path(shell).name} {'initial' if index == 0 else 'split'} shell and command refusal")
            if not shutil.which("fish"):
                print("SKIP: fish executable unavailable")
            for path in startup_paths:
                path.unlink(missing_ok=True)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


def run_ssh_cli(cli: str, socket_path: str, base: Path) -> subprocess.CompletedProcess:
    env = fake_server_env(socket_path)
    env["C11_SSH_CONTROL_DIR_TEST_BASE"] = str(base)
    return subprocess.run([cli, "--socket", socket_path, "--json", "ssh", "shell-fixture"], env=env, text=True, capture_output=True, timeout=20)


def run_startup(command: str, stub: Path, record: Path) -> subprocess.CompletedProcess:
    env = fake_server_env(None)
    env.update(PATH=f"{stub}:{os.environ['PATH']}", C11_TEST_SSH_RECORD=str(record), C11_TEST_SSH_EXIT_EARLY="1")
    return subprocess.run(["/bin/sh", "-c", "exec " + command], env=env, text=True, capture_output=True, timeout=15)


def control_token(control_path: str) -> str:
    # "<relay port>-<10 random [a-z0-9]>": another account cannot predict the name.
    match = re.fullmatch(r"(\d+)-([a-z0-9]{10})", Path(control_path).name)
    assert match, control_path
    return match.group(2)


def control_path_checks(cli: str, root: Path, socket_path: str, requests: list[dict], stub: Path, first_control_path: str) -> None:
    # Another account may have planted the folder (here: a world-readable one, and a symlink).
    for name, plant in (("loose", "mode"), ("link", "symlink")):
        base = root / f"ctl-{name}"
        base.mkdir()
        folder = base / "c11-ssh"
        if plant == "mode":
            folder.mkdir()
            folder.chmod(0o755)
        else:
            target = root / f"ctl-{name}-target"
            target.mkdir(mode=0o700)
            folder.symlink_to(target)
        before = len(requests)
        refused = run_ssh_cli(cli, socket_path, base)
        assert refused.returncode != 0 and REFUSAL in refused.stderr, (name, refused.returncode, refused.stderr)
        assert not any(r["method"] == "workspace.create" for r in requests[before:]), (name, requests[before:])
        print(f"PASS: c11 ssh refuses a {name} control socket folder before creating a workspace")

    base = root / "ctl-fresh"
    base.mkdir()
    before = len(requests)
    created = run_ssh_cli(cli, socket_path, base)
    assert created.returncode == 0, created.stderr
    configure = next(r["params"] for r in requests[before:] if r["method"] == "workspace.remote.configure")
    control_path = control_path_of(configure["ssh_options"])
    folder = base / "c11-ssh"
    assert Path(control_path).parent == folder, (control_path, folder)
    assert control_token(control_path) != control_token(first_control_path), (control_path, first_control_path)
    print("PASS: each c11 ssh run draws its own random ControlPath token")
    assert_fits_sun_path(control_path)
    assert_private_folder(folder)
    startup = configure["terminal_startup_command"]
    record = root / "ssh-calls.jsonl"

    # A cleaned temp folder is recreated owner-only before ssh binds there.
    folder.rmdir()
    ran = run_startup(startup, stub, record)
    assert ran.returncode == 0, (ran.stdout, ran.stderr)
    calls = [json.loads(line) for line in record.read_text().splitlines()]
    assert calls and calls[-1]["control_path"] == control_path, calls
    assert calls[-1].get("is_dir") and not calls[-1].get("is_link") and calls[-1]["uid"] == os.getuid() and calls[-1]["mode"] == 0o700, calls[-1]
    print("PASS: the startup script recreates the 0700 control socket folder before ssh runs")

    # A folder that stopped being private makes the startup script stop before ssh.
    folder.chmod(0o777)
    count = len(calls)
    stopped = run_startup(startup, stub, record)
    assert stopped.returncode != 0 and REFUSAL in stopped.stderr, (stopped.returncode, stopped.stderr)
    assert len(record.read_text().splitlines()) == count, "ssh ran against a non-private control folder"
    folder.chmod(0o700)
    print("PASS: the startup script refuses a non-private control socket folder")
    for command in (startup, json.loads(created.stdout).get("ssh_startup_command")):
        if command:
            Path(shlex.split(command)[0]).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
