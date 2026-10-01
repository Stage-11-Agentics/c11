#!/usr/bin/env python3
"""Exercise SSH startup from the CLI through isolated bash, zsh and fish shells.

Uses a fake app socket and SSH executable; it never connects to an app or host.
Set C11_CLI_BIN to the CLI built from the current checkout.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
import shlex
import shutil
import socketserver
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env
from test_cli_socket_deadline import resolve_c11_cli

MESSAGE = "c11 commands are not available over c11 ssh in this version"
SOCKET_KEYS = ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH", "CMUX_SOCKET_PASSWORD", "CMUX_RELAY_TOKEN")
WORKSPACE = "11111111-1111-4111-8111-111111111111"


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
                    result = {"methods": ["tab.list", "area.list", "workspace.create", "workspace.remote.configure"]}
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
            ssh.write_text("#!/usr/bin/env python3\n" + '''import os, subprocess, sys
args = sys.argv[1:]
remote = next(arg[len("RemoteCommand="):] for arg in args if arg.startswith("RemoteCommand="))
assert "-R" not in args
raise SystemExit(subprocess.call([os.environ["SHELL"], "-c", remote.replace("%%", "%")]))
''')
            ssh.chmod(0o700)
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


if __name__ == "__main__":
    main()
