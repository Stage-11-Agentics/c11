#!/usr/bin/env python3
"""Runtime contract checks for c11's PATH-scoped OpenCode wrapper."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "opencode"
SOURCE_PLUGIN = ROOT / "skills" / "opencode-plugins" / "c11-notify.js"


def executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines() if path.exists() else []


def run_wrapper(
    *,
    live: bool,
    argv: list[str],
    existing_content: str | None = None,
) -> tuple[int, list[str], dict, list[str], str]:
    with tempfile.TemporaryDirectory(prefix="c11-opencode-wrapper-test-") as td:
        tmp = Path(td)
        root = tmp / "c11 bundle"
        wrapper_dir = root / "bin"
        plugin_dir = root / "skills" / "opencode-plugins"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True)
        plugin_dir.mkdir(parents=True)
        real_dir.mkdir()
        shutil.copy2(SOURCE_WRAPPER, wrapper_dir / "opencode")
        shutil.copy2(SOURCE_PLUGIN, plugin_dir / "c11-notify.js")
        (wrapper_dir / "opencode").chmod(0o755)

        args_log = tmp / "args.log"
        env_log = tmp / "env.json"
        c11_log = tmp / "c11.log"
        socket_path = str(tmp / "c11.sock")

        executable(
            real_dir / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$FAKE_ARGS_LOG"
/usr/bin/python3 -c 'import json,os
path = os.environ.get("OPENCODE_CONFIG")
config_file = open(path).read() if path else None
print(json.dumps({
  "content": os.environ.get("OPENCODE_CONFIG_CONTENT"),
  "config_file": config_file,
  "hook_cli": os.environ.get("C11_AGENT_HOOK_CLI"),
}))' > "$FAKE_ENV_LOG"
""",
        )
        executable(
            wrapper_dir / "c11",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_C11_LOG"
""",
        )

        test_socket: socket.socket | None = None
        if live:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{wrapper_dir}:{real_dir}:/usr/bin:/bin",
                "CMUX_SOCKET_PATH": socket_path,
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "FAKE_ARGS_LOG": str(args_log),
                "FAKE_ENV_LOG": str(env_log),
                "FAKE_C11_LOG": str(c11_log),
            }
        )
        if existing_content is not None:
            env["OPENCODE_CONFIG_CONTENT"] = existing_content
        else:
            env.pop("OPENCODE_CONFIG_CONTENT", None)
        env.pop("OPENCODE_CONFIG", None)

        try:
            proc = subprocess.run(
                [str(wrapper_dir / "opencode"), *argv],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            deadline = time.monotonic() + 2
            while live and time.monotonic() < deadline:
                if any("agent-hook idle" in line for line in read(c11_log)):
                    break
                time.sleep(0.02)
        finally:
            if test_socket is not None:
                test_socket.close()

        state = json.loads(env_log.read_text(encoding="utf-8")) if env_log.exists() else {}
        return proc.returncode, read(args_log), state, read(c11_log), proc.stderr.strip()


def test_live_tui_runtime_loads_plugin() -> None:
    code, argv, state, c11_log, stderr = run_wrapper(live=True, argv=["--continue"])
    assert code == 0, stderr
    assert argv == ["--continue"], argv
    config = json.loads(state["content"])
    assert len(config["plugin"]) == 1, config
    assert config["plugin"][0].endswith("/skills/opencode-plugins/c11-notify.js"), config
    assert state["hook_cli"].endswith("/bin/c11"), state
    assert any("set-agent --type opencode" in line for line in c11_log), c11_log
    assert any("agent-hook idle" in line for line in c11_log), c11_log


def test_existing_content_is_preserved_via_second_runtime_source() -> None:
    existing = '{"theme":"operator-owned"}'
    code, _, state, _, stderr = run_wrapper(
        live=True,
        argv=[],
        existing_content=existing,
    )
    assert code == 0, stderr
    assert state["content"] == existing, state
    config = json.loads(state["config_file"])
    assert config["plugin"][0].endswith("/c11-notify.js"), config


def test_missing_socket_and_subcommand_are_transparent() -> None:
    code, argv, state, c11_log, stderr = run_wrapper(live=False, argv=["--continue"])
    assert code == 0, stderr
    assert argv == ["--continue"], argv
    assert state["content"] is None, state
    assert c11_log == [], c11_log

    code, argv, _, c11_log, stderr = run_wrapper(live=True, argv=["models"])
    assert code == 0, stderr
    assert argv == ["models"], argv
    assert not any("agent-hook" in line for line in c11_log), c11_log


if __name__ == "__main__":
    test_live_tui_runtime_loads_plugin()
    test_existing_content_is_preserved_via_second_runtime_source()
    test_missing_socket_and_subcommand_are_transparent()
    print("PASS: OpenCode lifecycle loads at runtime without tenant config writes")
