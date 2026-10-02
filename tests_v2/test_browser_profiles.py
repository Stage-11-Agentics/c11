#!/usr/bin/env python3
"""C11-289 browser profile lifecycle and isolation smoke.

This scenario uses only synthetic profile names and example.com. It exercises
the CLI contract through the tagged build's socket, then uses the v2 socket
client for tab/cookie cleanup and live-profile assertions.
"""

import json
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
PROFILE_A = "smoke-b3"
PROFILE_B = "smoke-b3b"
PROFILE_MULTIWORD = "smoke-b3 extra"
COOKIE_NAME = "c11_profile_cookie"


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _cli() -> str:
    from cmux import find_cli_binary

    return find_cli_binary()


def _run_cli_json(cli: str, args: list[str]) -> dict[str, Any]:
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "--json", "--id-format", "both", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    try:
        payload = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise cmuxError(f"Invalid CLI JSON for {' '.join(args)}: {proc.stdout!r}") from exc
    _must(isinstance(payload, dict), f"Expected object from {' '.join(args)}: {payload}")
    return payload


def _run_cli_expect_failure(cli: str, args: list[str], code: str) -> None:
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "--json", "--id-format", "both", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    _must(proc.returncode != 0, f"Expected failure for {' '.join(args)}")
    merged = f"{proc.stdout}\n{proc.stderr}"
    _must(code in merged, f"Expected {code} for {' '.join(args)}, got: {merged}")


def _tab_ids(c: cmux, workspace_id: str) -> set[str]:
    payload = c._call("tab.list", {"workspace_id": workspace_id}) or {}
    tabs = payload.get("tabs") or []
    _must(isinstance(tabs, list), f"tab.list returned malformed tabs: {payload}")
    return {str(tab["id"]) for tab in tabs if isinstance(tab, dict) and tab.get("id")}


def _expect_cli_failure_without_tab(
    c: cmux,
    cli: str,
    workspace_id: str,
    args: list[str],
    expected: str,
) -> None:
    before = _tab_ids(c, workspace_id)
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "--json", "--id-format", "both", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    merged = f"{proc.stdout}\n{proc.stderr}"
    _must(proc.returncode != 0, f"Expected CLI failure for {args}, got: {merged}")
    _must(expected in merged, f"Expected {expected} for {args}, got: {merged}")
    after = _tab_ids(c, workspace_id)
    _must(after == before, f"Invalid CLI profile selection created a tab for {args}: {before} -> {after}")


def _expect_socket_profile_failure_without_tab(
    c: cmux,
    method: str,
    params: dict[str, Any],
    workspace_id: str,
    expected: str = "invalid_params",
) -> None:
    before = _tab_ids(c, workspace_id)
    try:
        c._call(method, params)
    except cmuxError as exc:
        _must(expected in str(exc), f"Expected {expected} for {method} {params}, got: {exc}")
    else:
        raise cmuxError(f"Expected {expected} for {method} with explicit profile {params.get('profile')!r}")
    after = _tab_ids(c, workspace_id)
    _must(after == before, f"Invalid socket profile selection created a tab for {method}: {before} -> {after}")


def _assert_invalid_profile_selection(c: cmux, cli: str, workspace_id: str) -> None:
    socket_endpoints = (
        ("browser.open_split", {"url": "https://example.com"}),
        ("tab.create", {"type": "browser", "url": "https://example.com"}),
        ("area.create", {"type": "browser", "direction": "right", "url": "https://example.com"}),
    )
    invalid_values: list[Any] = ["", " \t\n", 17, None, {"name": PROFILE_A}]
    for method, base in socket_endpoints:
        for value in invalid_values:
            _expect_socket_profile_failure_without_tab(
                c,
                method,
                {**base, "workspace_id": workspace_id, "profile": value},
                workspace_id,
            )
        _expect_socket_profile_failure_without_tab(
            c,
            method,
            {**base, "workspace_id": workspace_id, "profile": "does-not-exist"},
            workspace_id,
            expected="not_found",
        )

    cli_endpoints = (
        ["browser", "open", "https://example.com", "--workspace", workspace_id],
        ["new-tab", "--type", "browser", "--workspace", workspace_id],
        ["new-area", "--type", "browser", "--direction", "right", "--workspace", workspace_id],
    )
    for base in cli_endpoints:
        for value in ("", " \t\n", "--dry-run"):
            _expect_cli_failure_without_tab(
                c, cli, workspace_id, [*base, "--profile", value], "--profile"
            )
        _expect_cli_failure_without_tab(c, cli, workspace_id, [*base, "--profile"], "--profile")
        _expect_cli_failure_without_tab(c, cli, workspace_id, [*base, "--profile=bad"], "--profile")
        _expect_cli_failure_without_tab(
            c,
            cli,
            workspace_id,
            [*base, "--profile", "does-not-exist"],
            "not_found",
        )


def _profile_rows(cli: str) -> list[dict[str, Any]]:
    payload = _run_cli_json(cli, ["browser", "profiles", "list"])
    rows = payload.get("profiles")
    _must(isinstance(rows, list), f"profiles.list returned no profiles array: {payload}")
    return [row for row in rows if isinstance(row, dict)]


def _profile_history_snapshot(cli: str, profile_id: str) -> bytes:
    cli_path = Path(cli).absolute()
    app_bundle = next((parent for parent in cli_path.parents if parent.suffix == ".app"), None)
    _must(app_bundle is not None, f"could not find the tagged app bundle for CLI: {cli}")
    try:
        with (app_bundle / "Contents" / "Info.plist").open("rb") as info_file:
            bundle_id = str(plistlib.load(info_file)["CFBundleIdentifier"])
    except (OSError, KeyError, plistlib.InvalidFileException) as exc:
        raise cmuxError(f"could not identify the tagged app bundle for CLI {cli}: {exc}") from exc

    if bundle_id.startswith("com.stage11.c11.debug."):
        namespace = "com.stage11.c11.debug"
    elif bundle_id.startswith("com.stage11.c11.staging."):
        namespace = "com.stage11.c11.staging"
    else:
        namespace = bundle_id
    history_path = (
        Path.home()
        / "Library"
        / "Application Support"
        / namespace
        / "browser_profiles"
        / profile_id.lower()
        / "browser_history.json"
    )

    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            snapshot = history_path.read_bytes()
            entries = json.loads(snapshot)
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(0.1)
            continue
        _must(
            isinstance(entries, list) and bool(entries),
            f"expected persisted history for profile {profile_id} at {history_path}",
        )
        return snapshot
    raise cmuxError(f"timed out waiting for profile history at {history_path}")


def _current_window(c: cmux) -> str:
    payload = c._call("window.current") or {}
    return str(payload.get("window_id") or payload.get("window_ref") or "")


def _close_tab(c: cmux, tab_id: Optional[str]) -> None:
    if not tab_id:
        return
    try:
        c._call("tab.close", {"tab_id": tab_id})
    except cmuxError:
        # Cleanup must not hide the assertion that caused the test to fail.
        pass


def main() -> int:
    cli = _cli()
    created_tabs: list[str] = []
    profile_ids: dict[str, str] = {}

    with cmux(SOCKET_PATH) as c:
        try:
            baseline_window = _current_window(c)
            _must(bool(baseline_window), "window.current returned no window")

            def assert_window(label: str) -> None:
                current = _current_window(c)
                _must(current == baseline_window, f"{label} changed key window from {baseline_window} to {current}")

            # Start from a clean synthetic namespace when a prior interrupted
            # run left unused fixtures behind.
            for row in _profile_rows(cli):
                name = str(row.get("name") or "")
                if name in {PROFILE_A, PROFILE_B, PROFILE_MULTIWORD}:
                    _must(not row.get("in_use"), f"stale profile is still in use: {row}")
                    _run_cli_json(cli, ["browser", "profiles", "delete", name, "--yes"])
            assert_window("stale profile cleanup")

            added_a = _run_cli_json(cli, ["browser", "profiles", "add", PROFILE_A])
            added_b = _run_cli_json(cli, ["browser", "profiles", "add", PROFILE_B])
            assert_window("profile add")
            profile_ids[PROFILE_A] = str(added_a["id"])
            profile_ids[PROFILE_B] = str(added_b["id"])
            _must(added_a["name"] == PROFILE_A, f"add returned wrong profile: {added_a}")
            _must(added_b["name"] == PROFILE_B, f"add returned wrong profile: {added_b}")

            _run_cli_expect_failure(cli, ["browser", "profiles", "add", PROFILE_A], "already_exists")
            _run_cli_expect_failure(
                cli, ["browser", "profiles", "rename", PROFILE_A, PROFILE_B], "already_exists"
            )
            same_name_rows = [row for row in _profile_rows(cli) if row.get("name") == PROFILE_A]
            _must(len(same_name_rows) == 1, f"duplicate add/rename changed profile count: {same_name_rows}")
            renamed = _run_cli_json(
                cli, ["browser", "profiles", "rename", PROFILE_B, PROFILE_MULTIWORD]
            )
            assert_window("profile rename")
            _must(renamed["id"] == profile_ids[PROFILE_B], f"rename changed id: {renamed}")
            _must(renamed["name"] == PROFILE_MULTIWORD, f"rename did not change the name: {renamed}")
            rows_after_rename = _profile_rows(cli)
            _must(
                not any(row.get("name") == PROFILE_B for row in rows_after_rename)
                and any(row.get("name") == PROFILE_MULTIWORD and row.get("id") == profile_ids[PROFILE_B] for row in rows_after_rename),
                f"rename did not replace the old name while preserving the id: {rows_after_rename}",
            )

            ident = c.identify()
            focused = ident.get("focused") or {}
            workspace_id = str(
                ident.get("workspace_id")
                or focused.get("workspace_id")
                or focused.get("workspace_ref")
                or ""
            )
            _must(bool(workspace_id), f"identify returned no workspace: {ident}")

            _assert_invalid_profile_selection(c, cli, workspace_id)
            assert_window("invalid profile selection refusal")

            _run_cli_expect_failure(
                cli,
                ["browser", "open", "https://example.com", "--workspace", workspace_id, "--profile", PROFILE_B],
                "not_found",
            )

            _run_cli_expect_failure(
                cli,
                [
                    "browser",
                    "open",
                    "https://example.com",
                    "--workspace",
                    workspace_id,
                    "--profile",
                    "does-not-exist",
                ],
                "not_found",
            )

            # Record the normal selection first. Explicit selection must not
            # rewrite this preference for the following unscoped creation.
            baseline_open = _run_cli_json(
                cli,
                ["browser", "open", "https://example.com", "--workspace", workspace_id],
            )
            baseline_tab = str(baseline_open.get("tab_id") or baseline_open.get("surface_id") or "")
            baseline_profile_id = str(baseline_open.get("profile_id") or "")
            _must(baseline_tab and baseline_profile_id, f"baseline open returned incomplete profile data: {baseline_open}")
            _close_tab(c, baseline_tab)

            # Explicit profile selection is returned by the creation response.
            explicit = _run_cli_json(
                cli,
                [
                    "browser",
                    "open",
                    "https://example.com",
                    "--workspace",
                    workspace_id,
                    "--profile",
                    PROFILE_MULTIWORD,
                ],
            )
            explicit_tab = str(explicit.get("tab_id") or explicit.get("surface_id") or "")
            _must(bool(explicit_tab), f"profile open returned no tab: {explicit}")
            created_tabs.append(explicit_tab)
            _must(
                explicit.get("profile_id") == profile_ids[PROFILE_B],
                f"explicit profile was not selected: {explicit}",
            )
            assert_window("explicit profile open")

            unscoped = _run_cli_json(
                cli,
                ["browser", "open", "https://example.com", "--workspace", workspace_id],
            )
            unscoped_tab = str(unscoped.get("tab_id") or unscoped.get("surface_id") or "")
            _must(bool(unscoped_tab), f"unscoped open returned no tab: {unscoped}")
            created_tabs.append(unscoped_tab)
            _must(
                unscoped.get("profile_id") == baseline_profile_id,
                f"explicit --profile changed next unscoped profile: expected {baseline_profile_id}, got {unscoped}",
            )
            assert_window("unscoped browser open")

            # A live tab blocks destructive lifecycle operations, and the
            # refusal leaves the definition visible.
            _run_cli_expect_failure(
                cli, ["browser", "profiles", "delete", PROFILE_MULTIWORD, "--yes"], "in_use"
            )
            _must(
                any(row.get("id") == profile_ids[PROFILE_B] for row in _profile_rows(cli)),
                "in-use profile disappeared after refused delete",
            )
            _run_cli_expect_failure(
                cli, ["browser", "profiles", "delete", PROFILE_MULTIWORD], "confirmation_required"
            )
            assert_window("unconfirmed profile delete")

            # Cookie isolation is checked through the actual WKWebView data
            # stores. Close both tabs before clear, as required by the API.
            for tab_id in list(created_tabs):
                _close_tab(c, tab_id)
            created_tabs.clear()

            history_url_a = "https://example.com/?c11-profile-history=smoke-a"
            history_url_b = "https://example.com/?c11-profile-history=smoke-b"
            profile_a_tab = c._call(
                "browser.open_split",
                {"url": history_url_a, "profile": PROFILE_A, "workspace_id": workspace_id},
            )
            profile_b_tab = c._call(
                "browser.open_split",
                {"url": history_url_b, "profile": PROFILE_MULTIWORD, "workspace_id": workspace_id},
            )
            tab_a = str(profile_a_tab.get("tab_id") or profile_a_tab.get("surface_id") or "")
            tab_b = str(profile_b_tab.get("tab_id") or profile_b_tab.get("surface_id") or "")
            created_tabs.extend([tab_a, tab_b])
            _must(tab_a and tab_b, f"cookie setup tabs missing: {profile_a_tab}, {profile_b_tab}")

            c._call(
                "browser.cookies.set",
                {
                    "tab_id": tab_a,
                    "name": COOKIE_NAME,
                    "value": "profile-a",
                    "url": "https://example.com/",
                },
            )
            for tab_id in (tab_a, tab_b):
                _run_cli_json(
                    cli,
                    ["browser", tab_id, "wait", "--load-state", "complete", "--timeout-ms", "15000"],
                )
            history_before_rejections = {
                profile_ids[PROFILE_A]: _profile_history_snapshot(cli, profile_ids[PROFILE_A]),
                profile_ids[PROFILE_B]: _profile_history_snapshot(cli, profile_ids[PROFILE_B]),
            }
            c._call(
                "browser.cookies.set",
                {
                    "tab_id": tab_b,
                    "name": COOKIE_NAME,
                    "value": "profile-b",
                    "url": "https://example.com/",
                },
            )

            # Leave the profiles unused so a parser bug cannot be masked by
            # the server's in-use guard on destructive operations.
            for tab_id in list(created_tabs):
                _close_tab(c, tab_id)
            created_tabs.clear()

            # Malformed destructive invocations must be rejected before the
            # socket sees a truncated target or an ignored unknown flag.
            malformed_destructive = (
                ["browser", "profiles", "delete", PROFILE_A, "extra", "--yes"],
                ["browser", "profiles", "delete", PROFILE_A, "--yes", "--dry-run"],
                ["browser", "profiles", "clear", PROFILE_A, "extra", "--yes"],
                ["browser", "profiles", "clear", PROFILE_MULTIWORD, "--yes", "--dry-run"],
                ["browser", "profiles", "delete", "--profile", PROFILE_A, PROFILE_MULTIWORD, "--yes"],
            )
            for args in malformed_destructive:
                _run_cli_expect_failure(cli, args, "exactly one profile target")
                assert_window("malformed destructive profile command")
            rows_after_rejected_commands = _profile_rows(cli)
            _must(
                any(row.get("id") == profile_ids[PROFILE_A] for row in rows_after_rejected_commands)
                and any(row.get("id") == profile_ids[PROFILE_B] for row in rows_after_rejected_commands),
                f"malformed delete removed a profile: {rows_after_rejected_commands}",
            )
            history_after_rejections = {
                profile_ids[PROFILE_A]: _profile_history_snapshot(cli, profile_ids[PROFILE_A]),
                profile_ids[PROFILE_B]: _profile_history_snapshot(cli, profile_ids[PROFILE_B]),
            }
            _must(
                history_after_rejections == history_before_rejections,
                "malformed clear/delete changed synthetic profile history",
            )

            # Verify malformed clear attempts left both profiles' synthetic
            # cookie data intact before issuing the one valid clear below.
            malformed_recheck_a = c._call(
                "browser.open_split",
                {"url": "https://example.com", "profile": PROFILE_A, "workspace_id": workspace_id},
            )
            malformed_recheck_b = c._call(
                "browser.open_split",
                {"url": "https://example.com", "profile": PROFILE_MULTIWORD, "workspace_id": workspace_id},
            )
            check_a = str(malformed_recheck_a.get("tab_id") or malformed_recheck_a.get("surface_id") or "")
            check_b = str(malformed_recheck_b.get("tab_id") or malformed_recheck_b.get("surface_id") or "")
            created_tabs.extend([check_a, check_b])
            _must(check_a and check_b, "could not reopen profiles after rejected destructive commands")
            preserved_a = c._call("browser.cookies.get", {"tab_id": check_a}).get("cookies") or []
            preserved_b = c._call("browser.cookies.get", {"tab_id": check_b}).get("cookies") or []
            _must(
                any(cookie.get("name") == COOKIE_NAME and cookie.get("value") == "profile-a" for cookie in preserved_a),
                f"rejected clear changed profile A cookie data: {preserved_a}",
            )
            _must(
                any(cookie.get("name") == COOKIE_NAME and cookie.get("value") == "profile-b" for cookie in preserved_b),
                f"rejected clear changed profile B cookie data: {preserved_b}",
            )
            for tab_id in list(created_tabs):
                _close_tab(c, tab_id)
            created_tabs.clear()

            _run_cli_json(cli, ["browser", "profiles", "clear", PROFILE_A, "--yes"])
            assert_window("profile clear")

            reopened_a = c._call(
                "browser.open_split",
                {"url": "https://example.com", "profile": PROFILE_A, "workspace_id": workspace_id},
            )
            reopened_b = c._call(
                "browser.open_split",
                {"url": "https://example.com", "profile": PROFILE_MULTIWORD, "workspace_id": workspace_id},
            )
            tab_a = str(reopened_a.get("tab_id") or reopened_a.get("surface_id") or "")
            tab_b = str(reopened_b.get("tab_id") or reopened_b.get("surface_id") or "")
            created_tabs.extend([tab_a, tab_b])
            _must(tab_a and tab_b, "reopen after clear returned no tabs")

            cookies_a = c._call("browser.cookies.get", {"tab_id": tab_a}).get("cookies") or []
            cookies_b = c._call("browser.cookies.get", {"tab_id": tab_b}).get("cookies") or []
            _must(
                not any(cookie.get("name") == COOKIE_NAME for cookie in cookies_a),
                f"clear did not remove profile A cookie: {cookies_a}",
            )
            _must(
                any(cookie.get("name") == COOKIE_NAME and cookie.get("value") == "profile-b" for cookie in cookies_b),
                f"clear touched profile B cookie: {cookies_b}",
            )

            # Built-in refusal does not open or remove anything.
            for tab_id in list(created_tabs):
                _close_tab(c, tab_id)
            created_tabs.clear()
            _run_cli_json(cli, ["browser", "profiles", "delete", PROFILE_MULTIWORD, "--yes"])
            _must(
                any(row.get("id") == profile_ids[PROFILE_A] for row in _profile_rows(cli)),
                "quoted multiword delete removed the wrong profile",
            )
            _run_cli_expect_failure(
                cli,
                ["browser", "open", "https://example.com", "--workspace", workspace_id, "--profile", PROFILE_MULTIWORD],
                "not_found",
            )
            _run_cli_json(cli, ["browser", "profiles", "delete", PROFILE_A, "--yes"])
            _must(
                not any(row.get("name") in {PROFILE_A, PROFILE_B, PROFILE_MULTIWORD} for row in _profile_rows(cli)),
                "profile delete after tab close left a synthetic definition behind",
            )
            default_row = next(row for row in _profile_rows(cli) if row.get("built_in") is True)
            _run_cli_expect_failure(
                cli,
                ["browser", "profiles", "delete", str(default_row["id"]), "--yes"],
                "built_in",
            )
            assert_window("built-in profile refusal")

            print("PASS: browser profile lifecycle, one-shot selection, and cookie isolation")
            return 0
        finally:
            for tab_id in list(created_tabs):
                _close_tab(c, tab_id)
            for name in (PROFILE_A, PROFILE_B, PROFILE_MULTIWORD):
                try:
                    _run_cli_json(cli, ["browser", "profiles", "delete", name, "--yes"])
                except Exception:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
