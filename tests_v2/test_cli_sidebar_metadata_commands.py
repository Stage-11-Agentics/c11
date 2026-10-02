#!/usr/bin/env python3
"""Regression: sidebar metadata commands never fall back to selected workspace."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    from cmux import find_cli_binary

    return find_cli_binary()


def _run_cli_process(
    cli: str,
    args: list[str],
    *,
    extra_env: dict[str, str] | None = None,
    clear_workspace_env: bool = False,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    if clear_workspace_env:
        env.pop("C11_WORKSPACE_ID", None)
        env.pop("CMUX_WORKSPACE_ID", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [cli, "--socket", SOCKET_PATH, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


def _run_cli(
    cli: str,
    args: list[str],
    *,
    extra_env: dict[str, str] | None = None,
    clear_workspace_env: bool = False,
) -> str:
    proc = _run_cli_process(
        cli,
        args,
        extra_env=extra_env,
        clear_workspace_env=clear_workspace_env,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    return proc.stdout.strip()


def _send_v1(command: str) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5.0)
        sock.connect(SOCKET_PATH)
        sock.sendall((command + "\n").encode("utf-8"))
        chunks: list[bytes] = []
        while True:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)
            sock.settimeout(0.1)
    return b"".join(chunks).decode("utf-8", errors="replace").strip()


def _send_v2(method: str, params: dict[str, object]) -> dict[str, object]:
    request = json.dumps({"id": 1, "method": method, "params": params})
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5.0)
        sock.connect(SOCKET_PATH)
        sock.sendall((request + "\n").encode("utf-8"))
        chunks: list[bytes] = []
        while True:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
    return json.loads(b"".join(chunks).split(b"\n", 1)[0].decode("utf-8"))


def main() -> int:
    cli = _find_cli_binary()
    created_workspaces: list[str] = []

    try:
        with cmux(SOCKET_PATH) as client:
            selected_workspace = client.new_workspace()
            created_workspaces.append(selected_workspace)
            env_workspace = client.new_workspace()
            created_workspaces.append(env_workspace)
            client.select_workspace(selected_workspace)

            status_response = _run_cli(cli, ["set-status", "selected", "keep", "--workspace", selected_workspace])
            _must(status_response.startswith("OK"), f"set-status should succeed, got {status_response!r}")

            progress_response = _run_cli(
                cli,
                ["set-progress", "0.25", "--workspace", selected_workspace, "--label", "selected"],
            )
            _must(progress_response.startswith("OK"), f"set-progress should succeed, got {progress_response!r}")

            log_response = _run_cli(cli, ["log", "--workspace", selected_workspace, "--", "selected log"])
            _must(log_response.startswith("OK"), f"log should succeed, got {log_response!r}")

            status_response = _run_cli(cli, ["set-status", "env", "clear-me", "--workspace", env_workspace])
            _must(status_response.startswith("OK"), f"set-status should succeed, got {status_response!r}")

            progress_response = _run_cli(
                cli,
                ["set-progress", "0.75", "--workspace", env_workspace, "--label", "env"],
            )
            _must(progress_response.startswith("OK"), f"set-progress should succeed, got {progress_response!r}")

            log_response = _run_cli(cli, ["log", "--workspace", env_workspace, "--", "env log"])
            _must(log_response.startswith("OK"), f"log should succeed, got {log_response!r}")

            window_id = client.current_window()
            targetless_cases = [
                ["clear-status", "selected"],
                ["clear-progress"],
                ["clear-log"],
                ["list-status"],
                ["list-log"],
                ["sidebar-state"],
                ["sidebar-state", "--json"],
            ]
            missing_target_cases = targetless_cases + [
                ["--window", window_id, *args] for args in targetless_cases
            ]
            for args in missing_target_cases:
                proc = _run_cli_process(cli, args, clear_workspace_env=True)
                merged = f"{proc.stdout}\n{proc.stderr}".strip()
                _must(
                    proc.returncode != 0
                    and ("requires --workspace" in merged or "C11_WORKSPACE_ID" in merged),
                    f"{' '.join(args)} without a target should fail explicitly, got rc={proc.returncode} output={merged!r}",
                )

            window_scoped_status = _run_cli(
                cli,
                ["--window", window_id, "list-status", "--workspace", selected_workspace],
                clear_workspace_env=True,
            )
            _must(
                "selected=keep" in window_scoped_status,
                f"an explicit workspace should work within --window scope: {window_scoped_status!r}",
            )

            raw_v1_cases = [
                "clear_status selected",
                "clear_progress",
                "clear_log",
                "list_status",
                "list_log",
                "sidebar_state",
            ]
            for command in raw_v1_cases:
                response = _send_v1(command)
                _must(
                    response.startswith("ERROR:") and "missing_ref" in response,
                    f"raw socket {command!r} should reject a missing target, got {response!r}",
                )

            raw_v2_state = _send_v2("sidebar.state", {})
            raw_v2_error = raw_v2_state.get("error")
            _must(
                raw_v2_state.get("ok") is False
                and isinstance(raw_v2_error, dict)
                and raw_v2_error.get("code") == "missing_ref",
                f"raw sidebar.state without a target should reject, got {raw_v2_state!r}",
            )
            raw_v2_targeted_state = _send_v2("sidebar.state", {"workspace_id": selected_workspace})
            _must(
                raw_v2_targeted_state.get("ok") is True,
                f"raw sidebar.state with an explicit workspace should succeed, got {raw_v2_targeted_state!r}",
            )

            selected_state = _run_cli(cli, ["sidebar-state", "--workspace", selected_workspace])
            _must("status_count=1" in selected_state, f"selected status should be preserved: {selected_state!r}")
            _must("progress=0.25 selected" in selected_state, f"selected progress should be preserved: {selected_state!r}")
            _must("[info] selected log" in selected_state, f"selected log should be preserved: {selected_state!r}")

            env = {"C11_WORKSPACE_ID": env_workspace}
            status_list = _run_cli(cli, ["list-status"], extra_env=env, clear_workspace_env=True)
            _must("env=clear-me" in status_list, f"C11_WORKSPACE_ID should target its status list: {status_list!r}")
            _must("selected=keep" not in status_list, f"C11_WORKSPACE_ID should not read the selected workspace: {status_list!r}")

            explicit_status_list = _run_cli(
                cli,
                ["list-status", "--workspace", selected_workspace],
                extra_env=env,
                clear_workspace_env=True,
            )
            _must("selected=keep" in explicit_status_list, f"--workspace should override env targeting: {explicit_status_list!r}")

            log_list = _run_cli(cli, ["list-log", "--limit", "5"], extra_env=env, clear_workspace_env=True)
            _must("env log" in log_list, f"list-log should resolve C11_WORKSPACE_ID: {log_list!r}")
            _must("selected log" not in log_list, f"list-log should not read the selected workspace: {log_list!r}")

            sidebar_state = _run_cli(cli, ["sidebar-state"], extra_env=env, clear_workspace_env=True)
            _must(f"tab={env_workspace}" in sidebar_state, f"sidebar-state should target C11_WORKSPACE_ID: {sidebar_state!r}")
            _must("progress=0.75 env" in sidebar_state, f"sidebar-state should include env progress: {sidebar_state!r}")

            json_state = json.loads(
                _run_cli(
                    cli,
                    ["--id-format", "uuids", "sidebar-state", "--json"],
                    extra_env=env,
                    clear_workspace_env=True,
                )
            )
            _must(json_state.get("workspace_id") == env_workspace, f"JSON sidebar-state should target C11_WORKSPACE_ID: {json_state!r}")

            alias_status_list = _run_cli(
                cli,
                ["list-status"],
                extra_env={"CMUX_WORKSPACE_ID": selected_workspace},
                clear_workspace_env=True,
            )
            _must("selected=keep" in alias_status_list, f"CMUX_WORKSPACE_ID compatibility alias should remain: {alias_status_list!r}")

            clear_status_response = _run_cli(cli, ["clear-status", "env"], extra_env=env, clear_workspace_env=True)
            _must(clear_status_response.startswith("OK"), f"clear-status should use C11_WORKSPACE_ID: {clear_status_response!r}")

            clear_progress_response = _run_cli(cli, ["clear-progress"], extra_env=env, clear_workspace_env=True)
            _must(clear_progress_response.startswith("OK"), f"clear-progress should use C11_WORKSPACE_ID: {clear_progress_response!r}")

            clear_log_response = _run_cli(cli, ["clear-log"], extra_env=env, clear_workspace_env=True)
            _must(clear_log_response.startswith("OK"), f"clear-log should use C11_WORKSPACE_ID: {clear_log_response!r}")

            cleared_env_state = _run_cli(cli, ["sidebar-state", "--workspace", env_workspace])
            _must("status_count=0" in cleared_env_state, f"C11 target status should clear: {cleared_env_state!r}")
            _must("progress=none" in cleared_env_state, f"C11 target progress should clear: {cleared_env_state!r}")
            _must("log_count=0" in cleared_env_state, f"C11 target log should clear: {cleared_env_state!r}")

            selected_after = _run_cli(cli, ["sidebar-state", "--workspace", selected_workspace])
            _must("status_count=1" in selected_after, f"clears should not touch selected workspace: {selected_after!r}")
            _must("progress=0.25 selected" in selected_after, f"selected progress should survive env clears: {selected_after!r}")
            _must("[info] selected log" in selected_after, f"selected log should survive env clears: {selected_after!r}")

            for workspace_id in created_workspaces:
                client.close_workspace(workspace_id)
            created_workspaces.clear()
    finally:
        if created_workspaces:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    for workspace_id in created_workspaces:
                        cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: sidebar metadata CLI commands dispatch and update workspace state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
