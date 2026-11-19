#!/usr/bin/env python3
"""Fault tests for the portal check in scripts/c11-load-soak.py.

The portal proof must fail closed: a terminal the tree shows with no portal
entry, no portal at all, or an entry off its anchor is a problem. No app runs;
a fake app answers `debug.portal.snapshot`.
"""

import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("soak", ROOT / "scripts" / "c11-load-soak.py")
soak = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(soak)

WS = "11111111-1111-4111-8111-111111111111"
PANEL = "22222222-2222-4222-8222-222222222222"
FRAME = {"x": 10, "y": 20, "width": 400, "height": 300}


class FakeApp:
    def __init__(self, portal):
        self.portal = portal

    def run(self, *args, check=True):
        assert args[:2] == ("rpc", "debug.portal.snapshot"), args
        return json.dumps({"selected_workspace_id": WS, "terminal_portal": self.portal})


def entry(hosted_frame=FRAME, hidden=False, orphan=False):
    return {"identity": {"workspace_id": WS, "panel_id": PANEL}, "visible_in_ui": True, "orphan": orphan,
            "hosted": {"frame_in_window": hosted_frame, "hidden": hidden, "hidden_by_ancestor": False},
            "anchor": {"frame_in_window": FRAME}}


class PortalProblemsTests(unittest.TestCase):
    def test_a_terminal_on_its_anchor_passes(self):
        checked, problems = soak.portal_problems(FakeApp({"present": True, "entries": [entry()]}), [PANEL])
        self.assertEqual((checked, problems), (1, []))

    def test_no_portal_fails_when_the_tree_shows_a_terminal(self):
        _, problems = soak.portal_problems(FakeApp({"present": False}), [PANEL])
        reasons = {why for p in problems for why in p["why"]}
        self.assertIn("no_terminal_portal", reasons)
        self.assertIn("no_visible_portal_entry", reasons)

    def test_a_shown_terminal_without_an_entry_fails(self):
        _, problems = soak.portal_problems(FakeApp({"present": True, "entries": []}), [PANEL])
        self.assertEqual([p["why"] for p in problems], [["no_visible_portal_entry"]])

    def test_a_stale_hidden_or_orphaned_entry_fails(self):
        stale = dict(FRAME, y=FRAME["y"] - 40)
        _, problems = soak.portal_problems(
            FakeApp({"present": True, "entries": [entry(hosted_frame=stale, hidden=True, orphan=True)]}), [PANEL])
        why = problems[0]["why"]
        self.assertIn("orphan", why)
        self.assertIn("hosted_hidden", why)
        self.assertTrue(any(w.startswith("stale_frame") for w in why))


SRC, DST = "ws-src", "ws-dst"


class ActionLandedTests(unittest.TestCase):
    """A close, move or resize whose command succeeded but changed nothing
    must fail the proof, as must one that landed in the wrong place."""

    def setUp(self):
        self.before = {"a": SRC, "b": SRC, "c": SRC, "d": DST}

    def test_a_close_that_happened_passes(self):
        self.assertIsNone(soak.close_problem(self.before, {"b": SRC, "c": SRC, "d": DST}, "A", SRC))

    def test_a_close_that_changed_nothing_fails(self):
        self.assertIn("still in workspace", soak.close_problem(self.before, dict(self.before), "a", SRC))

    def test_a_close_of_a_panel_the_tree_never_had_fails(self):
        self.assertIsNotNone(soak.close_problem(self.before, dict(self.before), "zz", SRC))

    def test_a_move_that_happened_passes(self):
        after = {"a": DST, "b": SRC, "c": SRC, "d": DST}
        self.assertIsNone(soak.move_problem(self.before, after, "a", SRC, DST))

    def test_a_move_that_changed_nothing_fails(self):
        self.assertIn("not the destination", soak.move_problem(self.before, dict(self.before), "a", SRC, DST))

    def test_a_move_that_closed_the_panel_instead_fails(self):
        after = {"b": SRC, "c": SRC, "d": DST}
        self.assertIsNotNone(soak.move_problem(self.before, after, "a", SRC, DST))

    def test_a_resize_that_happened_passes_with_a_nudged_origin(self):
        before = {"x": 0, "y": 40, "width": 900, "height": 640}
        requested = {"x": 0, "y": 40, "width": 1400, "height": 860}
        after = {"x": 0, "y": 25, "width": 1400, "height": 860}
        self.assertIsNone(soak.resize_problem(requested, before, after))

    def test_a_resize_that_changed_nothing_fails(self):
        before = {"x": 0, "y": 40, "width": 900, "height": 640}
        requested = {"x": 0, "y": 40, "width": 1400, "height": 860}
        self.assertIsNotNone(soak.resize_problem(requested, before, dict(before)))

    def test_a_resize_to_the_wrong_size_fails(self):
        before = {"x": 0, "y": 40, "width": 900, "height": 640}
        requested = {"x": 0, "y": 40, "width": 1400, "height": 860}
        self.assertIn("width", soak.resize_problem(requested, before, {"x": 0, "y": 40, "width": 1200, "height": 860}))

    def test_membership_and_frames_read_from_cli_json(self):
        tree = {"windows": [{"workspaces": [
            {"id": "WS-1", "ref": "workspace:1", "areas": [{"panels": [{"id": "P-1"}, {"id": "P-2"}]}]},
            {"id": "WS-2", "ref": "workspace:2", "areas": [{"panels": [{"id": "P-3"}]}]}]}]}
        self.assertEqual(soak.panel_membership(tree), {"p-1": "ws-1", "p-2": "ws-1", "p-3": "ws-2"})
        self.assertEqual(soak.workspace_id(tree, "workspace:2"), "ws-2")
        frame = {"x": 1, "y": 2, "width": 3, "height": 4}
        self.assertEqual(soak.window_frame([{"ref": "window:1", "frame": frame}]), frame)


if __name__ == "__main__":
    unittest.main()
