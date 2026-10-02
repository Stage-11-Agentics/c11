#!/usr/bin/env python3
"""C11-289 browser profile lifecycle and isolation smoke.

This scenario uses only synthetic profile names and example.com. It exercises
the CLI contract through the tagged build's socket, then uses the v2 socket
client for tab/cookie cleanup and live-profile assertions.
"""

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
PROFILE_A = "smoke-b3"
PROFILE_B = "smoke-b3b"
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


def _profile_rows(cli: str) -> list[dict[str, Any]]:
    payload = _run_cli_json(cli, ["browser", "profiles", "list"])
    rows = payload.get("profiles")
    _must(isinstance(rows, list), f"profiles.list returned no profiles array: {payload}")
    return [row for row in rows if isinstance(row, dict)]


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
                if name in {PROFILE_A, PROFILE_B}:
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
                cli, ["browser", "profiles", "rename", PROFILE_A, PROFILE_A]
            )
            assert_window("profile rename")
            _must(renamed["id"] == profile_ids[PROFILE_A], f"rename changed id: {renamed}")

            ident = c.identify()
            focused = ident.get("focused") or {}
            workspace_id = str(
                ident.get("workspace_id")
                or focused.get("workspace_id")
                or focused.get("workspace_ref")
                or ""
            )
            _must(bool(workspace_id), f"identify returned no workspace: {ident}")

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
                    PROFILE_B,
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
                cli, ["browser", "profiles", "delete", PROFILE_B, "--yes"], "in_use"
            )
            _must(
                any(row.get("id") == profile_ids[PROFILE_B] for row in _profile_rows(cli)),
                "in-use profile disappeared after refused delete",
            )
            _run_cli_expect_failure(
                cli, ["browser", "profiles", "delete", PROFILE_B], "confirmation_required"
            )
            assert_window("unconfirmed profile delete")

            # Cookie isolation is checked through the actual WKWebView data
            # stores. Close both tabs before clear, as required by the API.
            for tab_id in list(created_tabs):
                _close_tab(c, tab_id)
            created_tabs.clear()

            profile_a_tab = c._call(
                "browser.open_split",
                {"url": "https://example.com", "profile": PROFILE_A, "workspace_id": workspace_id},
            )
            profile_b_tab = c._call(
                "browser.open_split",
                {"url": "https://example.com", "profile": PROFILE_B, "workspace_id": workspace_id},
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
            c._call(
                "browser.cookies.set",
                {
                    "tab_id": tab_b,
                    "name": COOKIE_NAME,
                    "value": "profile-b",
                    "url": "https://example.com/",
                },
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
                {"url": "https://example.com", "profile": PROFILE_B, "workspace_id": workspace_id},
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
            _run_cli_json(cli, ["browser", "profiles", "delete", PROFILE_A, "--yes"])
            _run_cli_json(cli, ["browser", "profiles", "delete", PROFILE_B, "--yes"])
            _must(
                not any(row.get("name") in {PROFILE_A, PROFILE_B} for row in _profile_rows(cli)),
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
            for name in (PROFILE_A, PROFILE_B):
                try:
                    _run_cli_json(cli, ["browser", "profiles", "delete", name, "--yes"])
                except Exception:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
