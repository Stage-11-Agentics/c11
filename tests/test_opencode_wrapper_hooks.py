#!/usr/bin/env python3
"""Runtime contract checks for c11's PATH-scoped OpenCode wrapper."""

from __future__ import annotations

import hashlib
import json
import os
import pty
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "opencode"
SOURCE_PLUGIN = ROOT / "skills" / "opencode-plugins" / "c11-notify.js"
SOURCE_V2_PLUGIN = ROOT / "skills" / "opencode-plugins" / "c11-opencode-v2"
SOURCE_CONFIG_HELPER = ROOT / "Resources" / "bin" / "opencode-v2-config.py"


def executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines() if path.exists() else []


def claim_payloads(lines: list[str]) -> list[dict]:
    result = []
    for line in lines:
        if "rpc conversation.claim " in line:
            result.append(json.loads(line.split("rpc conversation.claim ", 1)[1]))
    return result


def merge_config(base: dict, overlay: dict) -> dict:
    """Mirror OpenCode's config merge so wrapper output is tested in context."""
    result = dict(base)
    for key, value in overlay.items():
        current = result.get(key)
        if isinstance(current, dict) and isinstance(value, dict):
            result[key] = merge_config(current, value)
        else:
            result[key] = value
    return result


def run_wrapper(
    *,
    live: bool,
    argv: list[str],
    existing_content: str | None = None,
    existing_config: str | None = None,
    in_c11: bool = True,
    ping_succeeds: bool = True,
    interactive: bool = False,
    existing_tui: str | None = None,
    native_disabled: bool = False,
    current_names: bool = False,
    version: str = "1.15.9",
    cli_content: str | None = None,
    cli_file: str | None = None,
    python_failure: bool = False,
    claim_succeeds: bool = True,
    claim_not_ready_attempts: int = 0,
    version_delay: float = 0,
    recovery_context: bool = False,
) -> tuple[int, list[str], dict, list[str], str]:
    with tempfile.TemporaryDirectory(prefix="c11-opencode-wrapper-test-") as td:
        tmp = Path(td)
        root = tmp / "c11 bundle"
        wrapper_dir = root / "bin"
        plugin_dir = root / "skills" / "opencode-plugins"
        real_dir = tmp / "real-bin"
        home = tmp / "isolated-home"
        wrapper_dir.mkdir(parents=True)
        plugin_dir.mkdir(parents=True)
        real_dir.mkdir()
        home.mkdir()
        shutil.copy2(SOURCE_WRAPPER, wrapper_dir / "opencode")
        shutil.copy2(SOURCE_PLUGIN, plugin_dir / "c11-notify.js")
        shutil.copy2(SOURCE_PLUGIN.with_name("c11-mailbox.mjs"), plugin_dir / "c11-mailbox.mjs")
        shutil.copytree(SOURCE_V2_PLUGIN, plugin_dir / "c11-opencode-v2")
        shutil.copy2(SOURCE_CONFIG_HELPER, wrapper_dir / SOURCE_CONFIG_HELPER.name)
        (wrapper_dir / "opencode").chmod(0o755)
        if python_failure:
            executable(wrapper_dir / "python3", "#!/bin/sh\nexit 1\n")

        args_log = tmp / "args.log"
        env_log = tmp / "env.json"
        c11_log = tmp / "c11.log"
        socket_path = str(tmp / "c11.sock")

        executable(
            real_dir / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$FAKE_ARGS_LOG"
/usr/bin/python3 -B -c 'import json,os
path = os.environ.get("OPENCODE_CONFIG")
config_file = config_reread = None
if path:
  with open(path) as source:
    config_file = source.read()
  with open(path) as source:  # OpenCode migration and server open separately.
    config_reread = source.read()
tui = os.environ.get("OPENCODE_TUI_CONFIG")
print(json.dumps({
  "content": os.environ.get("OPENCODE_CONFIG_CONTENT"),
  "config_path": path,
  "config_file": config_file,
  "config_reread": config_reread,
  "hook_cli": os.environ.get("C11_AGENT_HOOK_CLI"),
  "interactive_pid": os.environ.get("C11_AGENT_INTERACTIVE_PID"),
  "tui_path": tui,
  "tui_content": open(tui).read() if tui else None,
  "cli_content": os.environ.get("OPENCODE_CLI_CONFIG_CONTENT"),
  "resume_reserved": os.environ.get("C11_OPENCODE_RESUME_RESERVED"),
  "resume_reservation_failed": os.environ.get("C11_OPENCODE_RESUME_RESERVATION_FAILED"),
  "tui_claimed": os.environ.get("C11_OPENCODE_TUI_CLAIMED"),
  "tui_claim_failed": os.environ.get("C11_OPENCODE_TUI_CLAIM_FAILED"),
}))' > "$FAKE_ENV_LOG"
if [[ "${1:-}" == "--version" ]]; then
  sleep "$FAKE_VERSION_DELAY"
  [[ "$FAKE_VERSION" == "garbage" ]] || printf 'opencode %s\n' "$FAKE_VERSION"
  exit 0
fi
""",
        )
        executable(
            wrapper_dir / "c11",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_C11_LOG"
if [[ "${!#}" == "ping" && "$FAKE_PING_STATUS" != "0" ]]; then
  exit "$FAKE_PING_STATUS"
fi
if [[ "$*" == *"rpc conversation.claim"* ]]; then
  if [[ "$FAKE_CLAIM_STATUS" != "0" ]]; then
    printf 'unauthorized: claim denied\\n' >&2
    exit "$FAKE_CLAIM_STATUS"
  fi
  claim_count="$(awk '/rpc conversation.claim/ { count++ } END { print count + 0 }' "$FAKE_C11_LOG")"
  if (( claim_count <= FAKE_CLAIM_NOT_READY_ATTEMPTS )); then
    printf 'not_ready: restore in progress\\n' >&2
    exit 1
  fi
fi
""",
        )

        test_socket: socket.socket | None = None
        if live:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        # No caller identity, config source, or hook from the operator's session
        # may affect these fake-executable checks.
        for key in list(env):
            if key.startswith(("C11_", "CMUX_", "CMUXTERM_", "OPENCODE_")):
                env.pop(key)
        env.pop("XDG_DATA_HOME", None)
        env.update(
            {
                "HOME": str(home),
                "XDG_CONFIG_HOME": str(home / ".config"),
                "PATH": f"{wrapper_dir}:{real_dir}:/usr/bin:/bin",
                "CMUX_SOCKET_PATH": socket_path,
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "FAKE_ARGS_LOG": str(args_log),
                "FAKE_ENV_LOG": str(env_log),
                "FAKE_C11_LOG": str(c11_log),
                "FAKE_PING_STATUS": "0" if ping_succeeds else "1",
                "FAKE_CLAIM_STATUS": "0" if claim_succeeds else "1",
                "FAKE_CLAIM_NOT_READY_ATTEMPTS": str(claim_not_ready_attempts),
                "FAKE_VERSION": version,
                "FAKE_VERSION_DELAY": str(version_delay),
            }
        )
        if not in_c11:
            env.pop("CMUX_WORKSPACE_ID", None)
            env.pop("CMUX_SURFACE_ID", None)
        if current_names and in_c11:
            env["C11_SOCKET_PATH"] = env.pop("CMUX_SOCKET_PATH")
            env["C11_PANEL_ID"] = env.pop("CMUX_SURFACE_ID")
        env["C11_AGENT_INTERACTIVE_PID"] = "1"  # must never inherit a parent marker
        if native_disabled:
            env["C11_OPENCODE_NATIVE_MAIL_DISABLED"] = "1"
        if existing_content is not None:
            env["OPENCODE_CONFIG_CONTENT"] = existing_content
        else:
            env.pop("OPENCODE_CONFIG_CONTENT", None)
        config_path = tmp / "operator config ' dollar$;.json"
        if existing_config is not None:
            config_path.write_text(existing_config, encoding="utf-8")
            env["OPENCODE_CONFIG"] = str(config_path)
        else:
            env.pop("OPENCODE_CONFIG", None)
        if cli_content is not None:
            env["OPENCODE_CLI_CONFIG_CONTENT"] = cli_content
        if recovery_context:
            env["XDG_DATA_HOME"] = str(home / "data")
            env["OPENCODE_DB"] = "tenant-state/custom.sqlite"
        cli_config_path = home / ".config" / "opencode" / "cli.json"
        if cli_file is not None:
            cli_config_path.parent.mkdir(parents=True)
            cli_config_path.write_text(cli_file, encoding="utf-8")

        tui_path = tmp / "operator tui.json"
        if existing_tui is not None:
            tui_path.write_text(existing_tui)
            env["OPENCODE_TUI_CONFIG"] = str(tui_path)

        master, slave = pty.openpty() if interactive else (None, None)
        try:
            proc = subprocess.run(
                [str(wrapper_dir / "opencode"), *argv],
                env=env,
                stdin=slave,
                stdout=slave if interactive else subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                timeout=8,
            )
            deadline = time.monotonic() + 2
            while live and in_c11 and ping_succeeds and time.monotonic() < deadline:
                if any("agent-hook idle" in line for line in read(c11_log)):
                    break
                time.sleep(0.02)
        finally:
            if interactive:
                os.close(slave)
                os.close(master)
            if test_socket is not None:
                test_socket.close()

        state = json.loads(env_log.read_text(encoding="utf-8")) if env_log.exists() else {}
        runtime_path = state.get("config_path")
        if existing_config is None and runtime_path and runtime_path.startswith("/tmp/c11-opencode-config."):
            Path(runtime_path).unlink()  # This fake harness has now exited.
        state["tenant_paths"] = sorted(str(path.relative_to(home)) for path in home.rglob("*"))
        state["tenant_plugins_present"] = (home / ".config" / "opencode" / "plugins").exists()
        opencode_tenant_paths = [path for path in state["tenant_paths"] if path.startswith(".config/opencode/")]
        expected_opencode_paths = [".config/opencode/cli.json"] if cli_file is not None else []
        assert opencode_tenant_paths == expected_opencode_paths, state
        if existing_config is not None:
            assert config_path.read_bytes() == existing_config.encode("utf-8"), "operator config was rewritten"
            state["expected_config_path"] = str(config_path)
        if existing_tui is not None:
            assert tui_path.read_text() == existing_tui, "operator TUI config was rewritten"
            state["expected_tui_path"] = str(tui_path)
        if cli_file is not None:
            assert cli_config_path.read_text(encoding="utf-8") == cli_file, "operator cli.json was rewritten"
            state["cli_file_after"] = cli_config_path.read_text(encoding="utf-8")
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
    code, _, state, c11_log, stderr = run_wrapper(
        live=True,
        argv=[],
        existing_content=existing,
    )
    assert code == 0, stderr
    assert state["content"] == existing, state
    config = json.loads(state["config_file"])
    assert config["plugin"][0].endswith("/c11-notify.js"), config
    assert state["config_reread"] == state["config_file"], state


def test_missing_socket_and_subcommand_are_transparent() -> None:
    code, argv, state, c11_log, stderr = run_wrapper(live=False, argv=["--continue"])
    assert code == 0, stderr
    assert argv == ["--continue"], argv
    assert state["content"] is None, state
    assert state["config_path"] is None and state["hook_cli"] is None, state
    assert c11_log == [], c11_log

    code, argv, _, c11_log, stderr = run_wrapper(live=True, argv=["models"])
    assert code == 0, stderr
    assert argv == ["models"], argv
    assert not any("agent-hook" in line for line in c11_log), c11_log


def test_outside_c11_and_unreachable_socket_are_transparent() -> None:
    existing_content = ' {"theme":"operator δ"}\n'
    existing_config = ' {"model":"operator/model"}\n'
    arguments = ["--continue", "--model", "value with '$; whitespace"]
    for options in ({"live": True, "in_c11": False},
                    {"live": True, "ping_succeeds": False}):
        for content, config in ((None, None), (existing_content, existing_config)):
            code, argv, state, c11_log, stderr = run_wrapper(
                **options, argv=arguments,
                existing_content=content, existing_config=config,
            )
            assert code == 0, stderr
            assert argv == arguments, argv
            assert state["content"] == content, state
            assert state["config_path"] == state.get("expected_config_path"), state
            assert state["config_file"] == config, state
            assert state["hook_cli"] is None, state
            assert not state["tenant_plugins_present"], state
            assert not any("set-agent" in line or "agent-hook" in line for line in c11_log), c11_log
            if not options.get("in_c11", True):
                assert c11_log == [], c11_log
            else:
                assert len(c11_log) == 1 and c11_log[0].endswith(" ping"), c11_log


def test_both_runtime_config_sources_are_preserved_without_tenant_writes() -> None:
    existing_content = ' {"plugin":["operator-owned δ"],"theme":"custom"}\n'
    existing_config = ' {"plugin":["operator/file-plugin"],"model":"chosen"}\n'
    code, argv, state, c11_log, stderr = run_wrapper(
        live=True, argv=["--continue"],
        existing_content=existing_content, existing_config=existing_config,
    )
    assert code == 0, stderr
    assert argv == ["--continue"], argv
    assert state["content"] == existing_content, state
    assert state["config_path"] == state["expected_config_path"], state
    assert state["config_file"] == existing_config, state
    assert not state["tenant_plugins_present"], state
    assert state["hook_cli"].endswith("/bin/c11"), state
    assert any("set-agent --type opencode" in line for line in c11_log), c11_log
    assert any("agent-hook idle" in line for line in c11_log), c11_log


def test_native_tui_requires_interactive_launch_and_free_runtime_slot() -> None:
    for current in (False, True):
        code, _, state, _, stderr = run_wrapper(live=True, argv=[], interactive=True, current_names=current)
        assert code == 0, stderr
        assert int(state["interactive_pid"]) > 1, state
        assert json.loads(state["tui_content"])["plugin"][0].endswith("/c11-mailbox.mjs"), state
    for options, argv in [({}, []), ({"interactive": True}, ["run", "hello"]),
                          ({"interactive": True, "native_disabled": True}, []),
                          ({"interactive": True}, ["--version"])]:
        code, _, state, _, stderr = run_wrapper(live=True, argv=argv, **options)
        assert code == 0, stderr
        assert state["tui_path"] is None, state
        if not options.get("native_disabled"):
            assert state["interactive_pid"] is None, state
    existing = ' {"plugin":["operator-tui"],"theme":"private"}\n'
    code, _, state, _, stderr = run_wrapper(live=True, argv=[], interactive=True, existing_tui=existing)
    assert code == 0, stderr
    assert state["tui_path"] == state["expected_tui_path"], state
    assert state["tui_content"] == existing, state
    code, _, state, _, stderr = run_wrapper(live=True, argv=[], interactive=True,
        existing_content='{"plugin":["operator-plugin"]}', existing_config='{"model":"operator/model"}')
    assert code == 0, stderr
    assert state["tui_path"] is None, "no native route without the bundled lifecycle plugin"


def test_v2_composes_cli_plugins_and_reserves_exact_resume_before_launch() -> None:
    session_id = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
    cli_file = '{ // operator file config\n "plugins": ["file-plugin", "@operator/plugin@1.2.3"], "model": "file/model", }\n'
    cli_content = '{"plugins":["operator-env",{"package":"file:///private/plugin"}],"theme":"operator"}'
    code, argv, state, c11_log, stderr = run_wrapper(
        live=True, argv=["--session", session_id, "--model", "value with spaces"],
        interactive=True, version="2.0.25", cli_content=cli_content, cli_file=cli_file,
        recovery_context=True,
    )
    assert code == 0, stderr
    assert argv == ["--session", session_id, "--model", "value with spaces"], argv
    assert state["content"] is None and state["config_path"] is None, state
    assert state["tui_path"] is None, "v2 must not use the v1 TUI config override"
    assert state["resume_reserved"] == "1" and state["resume_reservation_failed"] is None, state
    assert state["tui_claimed"] == "1" and state["tui_claim_failed"] is None, state
    assert not any("agent-hook idle" in line for line in c11_log), c11_log
    claims = claim_payloads(c11_log)
    assert any(claim.get("expected_resume_id") == session_id and
               claim.get("interactive_pid") == int(state["interactive_pid"]) and
               claim.get("recovery_home", "").endswith("isolated-home") and
               claim.get("recovery_xdg_data_home", "").endswith("isolated-home/data") and
               claim.get("recovery_database_override") == "tenant-state/custom.sqlite" and
               claim.get("expires_at_epoch_ms", 0) > 0 for claim in claims), claims
    composed = json.loads(state["cli_content"])
    assert composed["theme"] == "operator", composed
    assert "model" not in composed, "file-only settings must remain in cli.json"
    assert composed["plugins"][:2] == ["operator-env", {"package": "file:///private/plugin"}], composed
    assert composed["plugins"][-1]["package"].endswith("/c11-opencode-v2"), composed
    effective = merge_config(
        {"plugins": ["file-plugin", "@operator/plugin@1.2.3"], "model": "file/model"},
        composed,
    )
    assert effective["model"] == "file/model" and effective["theme"] == "operator", effective
    # OpenCode returns merge(updated cli.json, content) after a config save.
    # A setting changed in the file must take effect while the wrapper runs.
    after_save = merge_config(
        {"plugins": ["file-plugin"], "model": "changed/file-model", "theme": "file-theme"},
        composed,
    )
    assert after_save["model"] == "changed/file-model" and after_save["theme"] == "operator", after_save
    assert state["cli_file_after"] == cli_file, state

    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=[], interactive=True, version="2.0.25",
    )
    assert code == 0, stderr
    assert state["tui_claimed"] == "1" and state["resume_reserved"] is None, state
    claims = claim_payloads(c11_log)
    assert any("expected_resume_id" not in claim and
               claim.get("interactive_pid") == int(state["interactive_pid"]) for claim in claims), claims

    file_config = '{ // preserve all operator CLI settings\n "plugins": ["operator-file"], "theme": "dark", "model": "operator/model", }\n'
    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=[], interactive=True, version="2.0.25", cli_file=file_config,
    )
    assert code == 0, stderr
    composed = json.loads(state["cli_content"])
    assert set(composed) == {"plugins"}, composed
    assert composed["plugins"][0] == "operator-file", composed
    assert composed["plugins"][-1]["package"].endswith("/c11-opencode-v2"), composed
    effective = merge_config(
        {"plugins": ["operator-file"], "theme": "dark", "model": "operator/model"},
        composed,
    )
    assert effective["theme"] == "dark" and effective["model"] == "operator/model", effective
    assert state["cli_file_after"] == file_config, state


def test_v2_composes_plugins_when_jsonc_trailing_comma_precedes_comment() -> None:
    cli_file = '{"plugins":["operator-file"], // valid JSONC trailing comma\n}\n'
    cli_content = '{"theme":"operator"}'
    code, _, state, _, stderr = run_wrapper(
        live=True, argv=[], interactive=True, version="2.0.25",
        cli_content=cli_content, cli_file=cli_file,
    )
    assert code == 0, stderr
    assert state["cli_file_after"] == cli_file, state
    composed = json.loads(state["cli_content"])
    assert composed["theme"] == "operator", composed
    assert composed["plugins"][0] == "operator-file", composed
    assert composed["plugins"][-1]["package"].endswith("/c11-opencode-v2"), composed


def test_v2_falls_back_for_invalid_config_and_failed_reservation() -> None:
    valid_session = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
    malformed = '{"plugins": ["operator"],'
    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=["--session", valid_session], interactive=True,
        version="2.0.25", cli_content=malformed,
    )
    assert code == 0, stderr
    assert state["cli_content"] == malformed, state
    assert state["resume_reserved"] == "1" and state["tui_claimed"] == "1", state
    claims = claim_payloads(c11_log)
    assert any(claim.get("expected_resume_id") == valid_session for claim in claims), claims
    assert not any("agent-hook idle" in line for line in c11_log), c11_log

    for malformed_plugins in ('{"plugins":[{"options":[]}]}',
                              '{"plugins":[{"package":"","options":{}}]}',
                              '{"plugins":[{"package":"operator/plugin","extra":true}]}'):
        code, _, state, c11_log, stderr = run_wrapper(
            live=True, argv=[], interactive=True, version="2.0.25",
            cli_content=malformed_plugins,
        )
        assert code == 0, stderr
        assert state["cli_content"] == malformed_plugins, state
        assert state["tui_claimed"] == "1", state
        assert claim_payloads(c11_log), c11_log
        assert not any("agent-hook idle" in line for line in c11_log), c11_log

    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=["-s", valid_session], interactive=True,
        version="2.0.25", claim_succeeds=False,
    )
    assert code == 0, stderr
    assert state["resume_reservation_failed"] == "1", state
    assert state["tui_claim_failed"] == "1" and state["tui_claimed"] is None, state
    assert state["cli_content"] is not None, "the TUI plugin stays loaded to retry the authenticated claim"
    assert claim_payloads(c11_log), c11_log
    assert not any("agent-hook idle" in line for line in c11_log), c11_log
    assert sum("rpc conversation.claim" in line for line in c11_log) == 1, c11_log

    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=["--continue"], interactive=True, version="2.0.25",
        claim_not_ready_attempts=1,
    )
    assert code == 0, stderr
    assert state["tui_claimed"] == "1" and state["tui_claim_failed"] is None, state
    assert sum("rpc conversation.claim" in line for line in c11_log) == 2, c11_log

    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=["--continue"], interactive=True,
        version="2.0.25", claim_not_ready_attempts=2,
    )
    assert code == 0, stderr
    assert state["tui_claim_failed"] == "1" and state["tui_claimed"] is None, state
    assert state["cli_content"] is not None, "the TUI plugin retries after the short wrapper window"
    assert sum("rpc conversation.claim" in line for line in c11_log) == 2, c11_log
    assert not any("agent-hook idle" in line for line in c11_log), c11_log


def test_v2_native_mail_disable_keeps_identity_capture_plugin() -> None:
    code, _, state, _, stderr = run_wrapper(
        live=True, argv=["--continue"], interactive=True, version="2.0.25", native_disabled=True,
    )
    assert code == 0, stderr
    assert state["tui_claimed"] == "1", state
    assert state["cli_content"] is not None, "disabling native mail must not disable exact route capture"
    assert json.loads(state["cli_content"])["plugins"][-1]["package"].endswith("/c11-opencode-v2"), state


def test_unknown_versions_keep_baseline_without_plugin_injection() -> None:
    for options in ({"version": "2.0.26"}, {"version": "2.0.25-beta"},
                    {"version": "2.0.25+build.1"}, {"version": "garbage"}):
        code, argv, state, c11_log, stderr = run_wrapper(
            live=True, argv=["--continue"], interactive=True, **options,
        )
        assert code == 0, stderr
        assert argv == ["--continue"], argv
        assert state["content"] is None and state["cli_content"] is None, state
        assert state["tui_path"] is None and state["hook_cli"].endswith("/bin/c11"), state
        assert int(state["interactive_pid"]) > 1, state
        assert any("set-agent --type opencode" in line for line in c11_log), c11_log
        assert any("agent-hook idle" in line for line in c11_log), c11_log
        if options.get("version") == "garbage" or options.get("version_delay"):
            assert "c11 could not verify the OpenCode version" in stderr, stderr


def test_v1_tui_plugins_survive_python_version_probe_failure() -> None:
    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=["--continue"], interactive=True,
        version="1.15.9", python_failure=True,
    )
    assert code == 0, stderr
    config = json.loads(state["content"])
    assert config["plugin"][0].endswith("/c11-notify.js"), config
    assert "c11-mailbox.mjs" in (state["tui_content"] or ""), state
    assert not any("conversation.claim" in line for line in c11_log), c11_log
    assert "version-specific plugin integration is disabled" not in stderr, stderr


def test_v1_tui_plugins_survive_slow_python_version_probe() -> None:
    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=["--continue"], interactive=True,
        version="1.15.9", version_delay=2,
    )
    assert code == 0, stderr
    config = json.loads(state["content"])
    assert config["plugin"][0].endswith("/c11-notify.js"), config
    assert "c11-mailbox.mjs" in (state["tui_content"] or ""), state
    assert "c11 could not verify the OpenCode version" not in stderr, stderr
    assert not any("conversation.claim" in line for line in c11_log), c11_log


def test_v2_plugin_recovers_when_python_version_probe_times_out() -> None:
    code, _, state, c11_log, stderr = run_wrapper(
        live=True, argv=["--continue"], interactive=True,
        version="2.0.25", version_delay=2,
    )
    assert code == 0, stderr
    assert state["tui_claimed"] == "1", state
    assert json.loads(state["cli_content"])["plugins"][-1]["package"].endswith("/c11-opencode-v2"), state
    assert any("rpc conversation.claim" in line for line in c11_log), c11_log
    assert not any("agent-hook idle" in line for line in c11_log), c11_log


def test_version_probe_ignores_stale_suffix_normalization_cache() -> None:
    cache_dir = Path("/tmp") / f"c11-opencode-version-{os.getuid()}"
    cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    for suffix in ("-beta", "+build.1"):
        with tempfile.TemporaryDirectory(prefix="c11-opencode-version-cache-test-") as td:
            binary = Path(td) / "opencode"
            executable(binary, f"#!/bin/sh\nprintf 'opencode v2.0.25{suffix}\\n'\n")
            real = binary.resolve(strict=True)
            info = real.stat()
            legacy_key = hashlib.sha256(
                f"{real}\0{info.st_mtime_ns}\0{info.st_size}".encode()
            ).hexdigest()
            legacy_cache = cache_dir / legacy_key
            legacy_cache.write_text("2.0.25\n", encoding="ascii")
            legacy_cache.chmod(0o600)
            try:
                result = subprocess.run(
                    ["python3", str(SOURCE_CONFIG_HELPER), "version", str(binary)],
                    capture_output=True, text=True, check=False, timeout=3,
                )
                assert result.returncode != 0, result.stdout
                assert not result.stdout, result.stdout
            finally:
                legacy_cache.unlink(missing_ok=True)


if __name__ == "__main__":
    test_live_tui_runtime_loads_plugin()
    test_existing_content_is_preserved_via_second_runtime_source()
    test_missing_socket_and_subcommand_are_transparent()
    test_outside_c11_and_unreachable_socket_are_transparent()
    test_both_runtime_config_sources_are_preserved_without_tenant_writes()
    test_native_tui_requires_interactive_launch_and_free_runtime_slot()
    test_v2_composes_cli_plugins_and_reserves_exact_resume_before_launch()
    test_v2_falls_back_for_invalid_config_and_failed_reservation()
    test_v2_native_mail_disable_keeps_identity_capture_plugin()
    test_unknown_versions_keep_baseline_without_plugin_injection()
    test_v1_tui_plugins_survive_python_version_probe_failure()
    test_v1_tui_plugins_survive_slow_python_version_probe()
    test_v2_plugin_recovers_when_python_version_probe_times_out()
    test_version_probe_ignores_stale_suffix_normalization_cache()
    print("PASS: OpenCode v1/v2 wrappers preserve tenant config and fail closed")
