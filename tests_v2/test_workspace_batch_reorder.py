#!/usr/bin/env python3
"""C11-259 G-order: partial/full mixed-pin batch order, dry-run and atomic errors.

Same isolated-socket/candidate-CLI requirements as test_workspace_groups.py.
Event emission counts require the tagged validator's event capture; this script
does not mistake unchanged state for proof that no event was emitted.
"""

import uuid

from test_workspace_groups import Fixture, cmux, require, test_environment


def exercise_batch(f):
    a, b, c, d = f.workspaces
    for workspace in (a, c):
        f.c._call("workspace.action", {
            "window_id": f.window, "workspace_id": workspace, "action": "pin",
        })
    g = f.mutate("create", name="Mixed Pins")["group"]["id"]
    h = f.mutate("create", name="Empty Pinned")["group"]["id"]
    f.mutate("add", group_id=g, workspace_ids=[a, b, c, d])
    f.mutate("pin", group_id=h)
    before = f.ids()
    pinned = [row["id"] for row in f.rows() if row["pinned"]]
    unpinned = [row["id"] for row in f.rows() if not row["pinned"]]
    require(pinned == [a, c] or pinned == [c, a], "unexpected pin fixture")
    # Request a currently later pinned and later unpinned item first, interleaved.
    request = [unpinned[-1], pinned[-1]]
    expected = ([pinned[-1]] + pinned[:-1] +
                [unpinned[-1]] + unpinned[:-1])
    selection, identities = f.selection(), f.identities()
    membership = {r["id"]: r["group_id"] for r in f.rows()}
    folder_order = [r["id"] for r in f.groups()]
    state = f.snapshot()

    def batch(ids, dry_run=False):
        return f.c._call("workspace.reorder_batch", {
            "window_id": f.window, "ordered_workspace_ids": ids, "dry_run": dry_run,
        })

    def assert_result(result, original, final, ids, dry_run):
        require(result["window_id"] == f.window, "batch returned wrong window")
        require(result["dry_run"] is dry_run, "incorrect dry_run result")
        require(result["changed"] is (original != final), "incorrect changed result")
        require(result["final_workspace_ids"] == final, "incorrect predicted final order")
        require(result["moves"] == [
            {"workspace_id": ws, "from_index": original.index(ws), "to_index": final.index(ws)}
            for ws in ids
        ], "per-request move indexes/order incorrect")

    preview = batch(request, dry_run=True)
    assert_result(preview, before, expected, request, True)
    require(f.snapshot() == state, "dry-run mutated state")
    actual = batch(request)
    assert_result(actual, before, expected, request, False)
    require(f.ids() == expected, "apply diverged from prediction")
    unchanged = f.snapshot()
    noop = batch(request)
    assert_result(noop, expected, expected, request, False)
    require(f.snapshot() == unchanged, "identical apply mutated state")

    cases = [
        ("invalid_params", []),
        ("invalid_params", "not-an-array"),
        ("invalid_params", [42]),
        ("duplicate_workspace", [a, a]),
        ("workspace_not_found", [d, str(uuid.uuid4())]),
        ("wrong_window", [d, f.other_workspace]),
    ]
    for code, ids in cases:
        f.error(code, "workspace.reorder_batch", {"ordered_workspace_ids": ids})
    f.error("invalid_params", "workspace.reorder_batch", {
        "ordered_workspace_ids": [d], "dry_run": "not-a-bool",
    })

    # A full reverse preserves pin segments, reversing only within each one.
    previous = f.ids()
    reverse = list(reversed(previous))
    pin_set = set(pinned)
    final = [ws for ws in reverse if ws in pin_set] + [ws for ws in reverse if ws not in pin_set]
    actual = batch(reverse)
    assert_result(actual, previous, final, reverse, False)
    require(f.ids() == final, "full reverse violated pin segment ordering")
    require(f.selection() == selection and f.identities() == identities, "batch changed selection or tabs")
    require({r["id"]: r["group_id"] for r in f.rows()} == membership, "batch changed membership")
    require([r["id"] for r in f.groups()] == folder_order, "batch reordered folders")
    require({r["id"] for r in f.rows() if r["pinned"]} == pin_set, "batch toggled workspace pin")
    f.parity()

    # CLI uses workspace refs and returns the same plan as the socket.
    rows = f.rows()
    refs = ",".join(r["ref"] for r in reversed(rows))
    requested = [r["id"] for r in reversed(rows)]
    state = f.snapshot()
    cli_preview = f.cli("reorder-workspaces", "--window", f.window, "--order", refs, "--dry-run")
    require(cli_preview == batch(requested, dry_run=True), "CLI/socket batch plan mismatch")
    require(f.snapshot() == state, "CLI dry-run mutated state")
    cli_actual = f.cli("reorder-workspaces", "--window", f.window, "--order", refs)
    require(cli_actual["final_workspace_ids"] == cli_preview["final_workspace_ids"], "CLI apply mismatch")
    require(f.ids() == cli_actual["final_workspace_ids"], "CLI result differs from state")
    state = f.snapshot()
    f.cli("reorder-workspaces", "--window", f.window, "--order", f"{a},{a}", fail=True)
    require(f.snapshot() == state, "CLI invalid batch partially applied")


def main():
    socket_path, cli = test_environment()
    with cmux(socket_path) as client:
        with Fixture(client, socket_path, cli) as fixture:
            exercise_batch(fixture)
    print("PASS: mixed-pin atomic batch reorder, dry-run, selection and CLI parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
