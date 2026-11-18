#!/usr/bin/env python3
"""Fail-closed checks of the memory soak's --kept-frame-check readings (C11H-255).

Runs with fakes only: no app, socket, guest or process is touched.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().with_name("c11-memory-soak.py")
SPEC = importlib.util.spec_from_file_location("c11_memory_soak", SCRIPT)
soak = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(soak)


class FakeApp:
    def __init__(self, close_error=None, windows=None):
        self.close_error = close_error
        self.windows = windows if windows is not None else {"windows": [{"ref": "window:1"}]}
        self.calls = []

    def run(self, *args, check=True, timeout=60):
        self.calls.append(args)
        if args[0] == "close-panel" and self.close_error:
            raise self.close_error
        return ""

    def json(self, *args):
        if isinstance(self.windows, Exception):
            raise self.windows
        return self.windows


class ClosePanelVerifiedTests(unittest.TestCase):
    def test_a_close_that_removes_the_panel_passes(self):
        with patch.object(soak, "workspace_panels", return_value=["panel:1", "panel:2"]):
            self.assertIsNone(soak.close_panel_verified(FakeApp(), "workspace:6", "panel:3", settle_s=0))

    def test_a_refused_close_fails(self):
        app = FakeApp(close_error=RuntimeError("c11 close-panel failed: invalid_state"))
        with patch.object(soak, "workspace_panels", return_value=["panel:1"]):
            error = soak.close_panel_verified(app, "workspace:6", "panel:3", settle_s=0)
        self.assertIn("close-panel panel:3 failed", error)

    def test_a_close_that_reports_success_but_leaves_the_panel_fails(self):
        with patch.object(soak, "workspace_panels", return_value=["panel:1", "panel:3"]):
            error = soak.close_panel_verified(FakeApp(), "workspace:6", "panel:3", settle_s=0)
        self.assertIn("still in workspace:6", error)

    def test_an_unreadable_inventory_fails(self):
        with patch.object(soak, "workspace_panels", side_effect=TimeoutError("tree timed out")):
            error = soak.close_panel_verified(FakeApp(), "workspace:6", "panel:3", settle_s=0)
        self.assertIn("unreadable", error)


class MainLatencySamplesTests(unittest.TestCase):
    def test_good_replies_have_no_failures(self):
        times, failures = soak.main_latency_samples(FakeApp(), n=3)
        self.assertEqual(len(times), 3)
        self.assertTrue(all(isinstance(t, int) for t in times))
        self.assertEqual(failures, [])

    def test_a_timeout_is_a_failure(self):
        times, failures = soak.main_latency_samples(FakeApp(windows=TimeoutError("timed out")), n=2)
        self.assertEqual(times, [None, None])
        self.assertEqual(len(failures), 2)

    def test_a_nonzero_exit_is_a_failure(self):
        # App.json runs with check=True, so a nonzero exit raises.
        error = RuntimeError("c11 --json list-windows failed: socket not found")
        _, failures = soak.main_latency_samples(FakeApp(windows=error), n=1)
        self.assertEqual(len(failures), 1)

    def test_a_malformed_reply_is_a_failure(self):
        _, failures = soak.main_latency_samples(FakeApp(windows={}), n=1)
        self.assertIn("malformed", failures[0])


def kept(long_ms, control=None):
    probe = {"failures": [], "long_hidden_shows": [
        {"digit": 4, "show": {"show_to_frame_ms": {"panel:1": long_ms, "panel:2": long_ms - 1},
                              "read": {"selections": [{"at_ms": 1000}], "stall": None}}}]}
    if control:
        selected, frame, stall_start = control
        probe["delayed_frame_control"] = {
            "show_to_frame_ms": {"panel:9": frame - selected},
            "read": {"selections": [{"at_ms": selected}], "stall": {"start_ms": stall_start}}}
    return probe


class KeptFrameTimingTests(unittest.TestCase):
    def test_within_the_slack_of_the_release_disabled_reference_passes(self):
        self.assertEqual(soak.kept_frame_timing_failures(kept(2125), kept(2079)), [])

    def test_later_than_the_reference_by_more_than_the_slack_fails(self):
        failures = soak.kept_frame_timing_failures(kept(2200), kept(2100))
        self.assertEqual(len(failures), 1)
        self.assertIn("100 ms later than the release-disabled reference", failures[0])

    def test_no_reference_and_no_first_main_turn_fails(self):
        failures = soak.kept_frame_timing_failures(kept(2125))
        self.assertIn("no release-disabled reference", failures[0])

    def test_a_frame_by_the_first_main_turn_passes_without_a_reference(self):
        probe = kept(2125, control=(1825, 3656, 3670))
        failures = soak.kept_frame_timing_failures(probe)
        self.assertEqual([f for f in failures if f.startswith("control-7")], [])

    def test_a_frame_after_the_first_main_turn_needs_the_reference(self):
        probe = kept(2125, control=(1825, 3700, 3670))
        failures = soak.kept_frame_timing_failures(probe)
        self.assertTrue(any(f.startswith("control-7") for f in failures))

    def test_evaluate_drops_the_superseded_250_ms_bound_only(self):
        result = {"kept_frame_probe": dict(kept(2125), failures=[
            "long-4: panel:1 first frame 2125 ms after selection (bound 250)",
            "2 rehidden past the grace: panel:51 still holds a frame"])}
        reference = {"kept_frame_probe": kept(2100)}
        self.assertEqual(soak.evaluate_kept_frame(result, reference),
                         ["2 rehidden past the grace: panel:51 still holds a frame"])


class KeptFrameExitCodeTests(unittest.TestCase):
    check = SimpleNamespace(kept_frame_check=True)

    def test_failures_exit_3(self):
        result = {"kept_frame_probe": {"failures": ["close with the release timer pending: refused"]}}
        self.assertEqual(soak.kept_frame_exit_code(self.check, result), 3)

    def test_a_probe_that_did_not_run_exits_3(self):
        self.assertEqual(soak.kept_frame_exit_code(self.check, {}), 3)

    def test_a_clean_probe_exits_0(self):
        self.assertEqual(soak.kept_frame_exit_code(self.check, {"kept_frame_probe": {"failures": []}}), 0)

    def test_recording_mode_never_fails_the_run(self):
        result = {"kept_frame_probe": {"failures": ["anything"]}}
        self.assertEqual(soak.kept_frame_exit_code(SimpleNamespace(kept_frame_check=False), result), 0)


if __name__ == "__main__":
    unittest.main()
