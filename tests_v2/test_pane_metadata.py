#!/usr/bin/env python3
"""CMUX-11 Phase 2: pane.set_metadata / .get_metadata / .clear_metadata.

Verifies the pane-metadata RPC family added in Phase 2:

- Set/get/clear round-trip with source-precedence gating
- set response includes `prior_values` (substrate for the
  read-then-write-by-convention norm)
- Cap enforcement (64 KiB per pane)
- CLI `--pane pane:N` short-ref targeting
- CLI `--surface` + `--pane` together → usage error

No UI assertions — this is a mechanism-layer test. Requires a running
c11 instance; set CMUX_SOCKET to target a tagged build's socket
(e.g. /tmp/c11-debug-<tag>.sock).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")

CLI_PATH = os.environ.get("CMUX_CLI") or "cmux"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _cli(args: list[str], check: bool = True, env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["CMUX_SOCKET"] = SOCKET_PATH
    if env_extra:
        env.update(env_extra)
    result = subprocess.run(
        [CLI_PATH, *args],
        capture_output=True,
        text=True,
        env=env,
    )
    if check and result.returncode != 0:
        raise cmuxError(
            f"cli {args} exited {result.returncode}: "
            f"stdout={result.stdout.strip()!r} stderr={result.stderr.strip()!r}"
        )
    return result


def _fresh_workspace_and_pane(c: cmux) -> tuple[str, str]:
    """Create a workspace and split once so we have a second pane to target."""
    workspace_id = c.new_workspace()
    # surface.split always creates a new pane; grab the new pane's id.
    split_res = c._call("surface.split", {"workspace_id": workspace_id, "direction": "right"}) or {}
    pane_id = split_res.get("pane_id")
    _must(bool(pane_id), f"surface.split returned no pane_id: {split_res}")
    return workspace_id, str(pane_id)


def _test_roundtrip_and_prior_values(c: cmux) -> None:
    workspace_id, pane_id = _fresh_workspace_and_pane(c)

    # Fresh pane — get_metadata should return empty.
    got = c._call("pane.get_metadata", {"workspace_id": workspace_id, "pane_id": pane_id}) or {}
    _must(got.get("metadata") == {}, f"fresh pane metadata should be empty: {got}")

    # First set: prior_values empty (key was unset).
    set_a = c._call("pane.set_metadata", {
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "metadata": {"title": "Parent :: Child"},
    }) or {}
    _must(set_a.get("applied", {}).get("title") is True,
          f"first set title not applied: {set_a}")
    _must(set_a.get("prior_values", None) == {},
          f"first set should have empty prior_values: {set_a}")
    _must(set_a.get("metadata", {}).get("title") == "Parent :: Child",
          f"post-op metadata wrong: {set_a}")

    # Second set: prior_values should contain the previous title string.
    set_b = c._call("pane.set_metadata", {
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "metadata": {"title": "Parent :: Code Review"},
    }) or {}
    _must(set_b.get("applied", {}).get("title") is True,
          f"second set title not applied: {set_b}")
    prior = set_b.get("prior_values", {})
    _must(prior.get("title") == "Parent :: Child",
          f"second set should return prior title in prior_values: {set_b}")

    # get_metadata reflects the latest write.
    got2 = c._call("pane.get_metadata", {
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "include_sources": True,
    }) or {}
    _must(got2.get("metadata", {}).get("title") == "Parent :: Code Review",
          f"get_metadata after second set wrong: {got2}")
    src = got2.get("metadata_sources", {}).get("title", {})
    _must(src.get("source") == "explicit",
          f"title source should be explicit, got: {src}")

    # Clear a specific key.
    clr = c._call("pane.clear_metadata", {
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "keys": ["title"],
    }) or {}
    _must(clr.get("applied", {}).get("title") is True,
          f"clear title not applied: {clr}")

    got3 = c._call("pane.get_metadata", {"workspace_id": workspace_id, "pane_id": pane_id}) or {}
    _must("title" not in got3.get("metadata", {}),
          f"title should be absent after clear: {got3}")

    c._call("workspace.close", {"workspace_id": workspace_id})


def _test_source_precedence(c: cmux) -> None:
    workspace_id, pane_id = _fresh_workspace_and_pane(c)

    # Set with source=explicit (highest precedence).
    c._call("pane.set_metadata", {
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "metadata": {"title": "Explicit"},
        "source": "explicit",
    })

    # Attempt to overwrite with source=declare (lower precedence) — should soft-reject.
    lower = c._call("pane.set_metadata", {
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "metadata": {"title": "Declare"},
        "source": "declare",
    }) or {}
    _must(lower.get("applied", {}).get("title") is False,
          f"lower-precedence write should be rejected: {lower}")
    _must(lower.get("reasons", {}).get("title") == "lower_precedence",
          f"rejection reason should be lower_precedence: {lower}")

    # Verify the higher-precedence value is still in place.
    got = c._call("pane.get_metadata", {"workspace_id": workspace_id, "pane_id": pane_id}) or {}
    _must(got.get("metadata", {}).get("title") == "Explicit",
          f"value should remain Explicit after rejected write: {got}")

    c._call("workspace.close", {"workspace_id": workspace_id})


def _test_cap_enforcement(c: cmux) -> None:
    workspace_id, pane_id = _fresh_workspace_and_pane(c)

    # 128 KiB string — well above the 64 KiB cap.
    huge = "x" * (128 * 1024)
    try:
        c._call("pane.set_metadata", {
            "workspace_id": workspace_id,
            "pane_id": pane_id,
            "metadata": {"bulk": huge},
        })
    except cmuxError as exc:
        msg = str(exc)
        _must("payload_too_large" in msg, f"expected payload_too_large, got: {msg}")
        c._call("workspace.close", {"workspace_id": workspace_id})
        return
    raise cmuxError("over-cap write should have raised payload_too_large")


def _test_replace_mode_requires_explicit(c: cmux) -> None:
    workspace_id, pane_id = _fresh_workspace_and_pane(c)

    try:
        c._call("pane.set_metadata", {
            "workspace_id": workspace_id,
            "pane_id": pane_id,
            "metadata": {"title": "X"},
            "mode": "replace",
            "source": "declare",
        })
    except cmuxError as exc:
        msg = str(exc)
        _must("replace_requires_explicit" in msg,
              f"expected replace_requires_explicit, got: {msg}")
        c._call("workspace.close", {"workspace_id": workspace_id})
        return
    raise cmuxError("replace with source=declare should have been rejected")


def _test_cli_pane_short_ref(c: cmux) -> None:
    """`cmux set-metadata --pane pane:N --key title --value ...` round-trip."""
    workspace_id, pane_id = _fresh_workspace_and_pane(c)

    # Figure out which pane index corresponds to our pane_id.
    panes = (c._call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes", [])
    pane_index = None
    for p in panes:
        if str(p.get("id")) == pane_id:
            pane_index = int(p.get("index", -1))
            break
    _must(pane_index is not None and pane_index >= 0,
          f"could not find pane index for {pane_id} in {panes}")
    short_ref = f"pane:{pane_index + 1}"  # pane:N refs are 1-indexed in the CLI.

    set_res = _cli([
        "set-metadata",
        "--workspace", workspace_id,
        "--pane", short_ref,
        "--key", "title",
        "--value", "ShortRef",
        "--json",
    ])
    _must('"ShortRef"' in set_res.stdout,
          f"cli set-metadata stdout missing title: {set_res.stdout!r}")

    # Read back via CLI.
    get_res = _cli([
        "get-metadata",
        "--workspace", workspace_id,
        "--pane", short_ref,
        "--key", "title",
    ])
    _must("ShortRef" in get_res.stdout,
          f"cli get-metadata stdout missing value: {get_res.stdout!r}")

    c._call("workspace.close", {"workspace_id": workspace_id})


def _test_cli_surface_and_pane_mutually_exclusive() -> None:
    """`--surface` + `--pane` on metadata commands must error."""
    res = _cli([
        "set-metadata",
        "--surface", "surface:1",
        "--pane", "pane:1",
        "--key", "title",
        "--value", "nope",
    ], check=False)
    _must(res.returncode != 0,
          f"expected non-zero exit, got {res.returncode} (stdout={res.stdout!r})")
    combined = (res.stdout + res.stderr).lower()
    _must("mutually exclusive" in combined,
          f"expected 'mutually exclusive' in output, got: {combined!r}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        _test_roundtrip_and_prior_values(c)
        _test_source_precedence(c)
        _test_cap_enforcement(c)
        _test_replace_mode_requires_explicit(c)
        _test_cli_pane_short_ref(c)

    # CLI-only test (doesn't need a persistent connection).
    _test_cli_surface_and_pane_mutually_exclusive()

    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
