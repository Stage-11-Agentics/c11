#!/usr/bin/env python3
"""Behavioral failure-injection checks for the g60 identity/restore oracles."""
import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_workspace_groups_scale import assert_identity, assert_move, compare_sessions, shell_pids


def snapshot():
    return {"workspace_order": ["one", "two"], "workspaces": {
        wid: {"group_id": None, "pinned": False, "tab_ids": [wid + "-tab"], "tabs": [{"id": wid + "-tab", "type": "terminal",
              "tty": "synthetic-tty", "shell_pids": [123], "metadata": {}}]}
        for wid in ("one", "two")}}


class ScaleOracleTests(unittest.TestCase):
    def test_tty_shell_roots_ignore_transient_descendant_shells(self):
        initial = "101 1 -zsh\n202 1 /bin/bash\n"
        transient = initial + "303 101 /bin/zsh\n404 303 /bin/sh\n505 202 helper\n606 505 /bin/bash\n"
        with patch("test_workspace_groups_scale.subprocess.run", side_effect=[
                SimpleNamespace(stdout=initial), SimpleNamespace(stdout=transient)]):
            self.assertEqual(shell_pids("/dev/synthetic-tty"), [101, 202])
            self.assertEqual(shell_pids("/dev/synthetic-tty"), [101, 202])

    def test_transfer_noop_is_rejected_at_intermediate_state(self):
        state = {"window_id": "window", "workspaces": {"source": {"id": "one"}}}
        with patch("test_workspace_groups_scale.workspace_snapshot", return_value=snapshot()), \
                patch("test_workspace_groups_scale.move_workspace"):
            with self.assertRaises(AssertionError):
                assert_move(None, state, "source", "destination")

    def test_relative_reorder_noop_is_rejected(self):
        state = {"window_id": "window", "workspaces": {"source": {"id": "two"}, "target": {"id": "one"}}}
        with patch("test_workspace_groups_scale.workspace_snapshot", return_value=snapshot()), \
                patch("test_workspace_groups_scale.move_workspace"):
            with self.assertRaises(AssertionError):
                assert_move(None, state, "source", None, before="target")

    def test_surviving_tab_replacement_is_rejected(self):
        before, after = snapshot(), snapshot()
        after["workspaces"]["one"]["tabs"][0]["id"] = "replacement"
        with self.assertRaises(AssertionError):
            assert_identity(before, after)

    def test_surviving_shell_replacement_is_rejected(self):
        before, after = snapshot(), snapshot()
        after["workspaces"]["one"]["tabs"][0]["shell_pids"] = [456]
        with self.assertRaises(AssertionError):
            assert_identity(before, after)

    def test_extra_workspace_removal_is_rejected(self):
        before, after = snapshot(), snapshot()
        after["workspace_order"] = []
        with self.assertRaises(AssertionError):
            assert_identity(before, after, removed={"one"})

    def test_missing_process_identity_is_unverified(self):
        before, after = snapshot(), snapshot()
        for record in before["workspaces"].values():
            record["tabs"][0]["shell_pids"] = []
        self.assertEqual(len(assert_identity(before, after)), 2)

    def test_compatibility_restore_rejects_replacement_ids_and_wrong_group_properties(self):
        source = {"version": 1, "windows": [{"tabManager": {"selectedWorkspaceIndex": 0,
            "workspaces": [{"id": "original", "panels": [{"id": "tab", "type": "terminal"}]}],
            "workspaceGroups": [{"id": "folder", "name": "Empty", "color": "#123456",
                                 "icon": "folder.fill", "isPinned": True, "isCollapsed": True}]}}]}
        with tempfile.TemporaryDirectory() as root:
            expected, actual = Path(root) / "expected.json", Path(root) / "actual.json"
            for mode in ("pre-group", "empty-group"):
                fixture = copy.deepcopy(source)
                if mode == "pre-group":
                    del fixture["windows"][0]["tabManager"]["workspaceGroups"]
                expected.write_text(json.dumps(fixture))
                actual.write_text(json.dumps(fixture))
                self.assertEqual(compare_sessions(expected, actual, mode)["status"], "PASS")
                replacement = copy.deepcopy(fixture)
                replacement["windows"][0]["tabManager"]["workspaces"][0]["id"] = "fallback"
                actual.write_text(json.dumps(replacement))
                with self.assertRaises(AssertionError):
                    compare_sessions(expected, actual, mode)
                if mode == "empty-group":
                    replacement = copy.deepcopy(fixture)
                    replacement["windows"][0]["tabManager"]["workspaceGroups"][0]["isPinned"] = False
                    actual.write_text(json.dumps(replacement))
                    with self.assertRaises(AssertionError):
                        compare_sessions(expected, actual, mode)


if __name__ == "__main__":
    unittest.main()
