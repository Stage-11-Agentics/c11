#!/usr/bin/env python3
"""Hermetic tests for Atlas performance record parsing and admission results."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("c11-perf-lane.py")
SPEC = importlib.util.spec_from_file_location("c11_perf_lane", SCRIPT)
perf = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(perf)


class PerfLaneTests(unittest.TestCase):
    HEAD = "a" * 40

    def test_cold_ghosttykit_download_targets_the_gitlink_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "home"
            worktree = home / "c11-perf-lane" / "worktree"
            script = worktree / "scripts" / "download-prebuilt-ghosttykit.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\nexit 0\n")
            script.chmod(0o755)
            gitlink = "a" * 40
            expected_kit = home / ".cache" / "cmux" / "ghosttykit" / gitlink / "GhosttyKit.xcframework"

            def download(_argv, *, cwd, env, check, timeout):
                self.assertEqual(cwd, expected_kit.parent)
                self.assertEqual(env["GHOSTTY_SHA"], gitlink)
                self.assertEqual(env["GHOSTTYKIT_OUTPUT_DIR"], str(expected_kit))
                self.assertTrue(check)
                self.assertEqual(timeout, 600)
                extracted = cwd / "GhosttyKit.xcframework"
                extracted.mkdir()
                (extracted / "marker").write_text("verified")

            with patch.dict(os.environ, {"HOME": str(home)}), \
                    patch.object(perf, "git", return_value=gitlink), \
                    patch.object(perf.subprocess, "run", side_effect=download):
                perf.prepare_ghosttykit(worktree)

            self.assertEqual((expected_kit / "marker").read_text(), "verified")
            self.assertTrue((worktree / "GhosttyKit.xcframework").is_symlink())
            self.assertEqual((worktree / "GhosttyKit.xcframework").resolve(), expected_kit.resolve())

    def test_parses_all_three_benchmark_measurements(self):
        log = "\n".join((
            "BENCH cmd+shift+p reference=12.50ms optimized=3.25ms",
            "BENCH cmd+p reference=14.00ms optimized=4.75ms",
            "CORPUS_PUBLISH_C11_CHECKOUT bytes=140001 medianMainMs=2.350 samplesMs=2.1,2.3,2.4",
        ))
        metrics = perf.parse_metrics(log)
        self.assertEqual(len(metrics), 3)
        self.assertEqual(metrics["command-search"]["optimized_ms"], 3.25)
        self.assertEqual(metrics["switcher-search"]["reference_ms"], 14.0)
        self.assertEqual(metrics["corpus-bridge-submission"]["samples_ms"], [2.1, 2.3, 2.4])

    def test_xcresult_requires_pass_and_a_nonzero_executed_count(self):
        passed = {"result": "Passed", "totalTestCount": 3, "skippedTests": 1, "failedTests": 0}
        self.assertEqual(perf.xcresult_state(passed), ("success", "xcresult passed"))
        zero = dict(passed, totalTestCount=1, skippedTests=1)
        self.assertEqual(perf.xcresult_state(zero)[0], "failure")
        failed = dict(passed, result="Failed", failedTests=1)
        self.assertEqual(perf.xcresult_state(failed)[0], "failure")
        self.assertEqual(perf.xcresult_state(None)[0], "error")

    def test_missing_xcrun_can_be_recorded_as_an_error(self):
        summary, error = perf.read_xcresult_summary(
            Path("/missing/xcrun"), Path("result.xcresult"), {}
        )
        self.assertIsNone(summary)
        self.assertIsNotNone(error)

    def test_appends_each_measurement_as_one_json_line(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "records" / "perf.jsonl"
            records = [{"benchmark": item[0], "state": "success"} for item in perf.BENCHMARKS]
            perf.append_records(path, records)
            loaded = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual(loaded, records)

    def test_successful_head_skips_before_ghosttykit_or_slot(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "lane"
            records = root / "records" / "perf.jsonl"
            perf.append_records(records, [{"head": self.HEAD, "state": "success", "run_id": "prior"}])
            with patch.object(perf, "prepare_worktree", return_value=(Path(temp) / "worktree", self.HEAD)), \
                    patch.object(perf, "prepare_ghosttykit") as prepare_kit, \
                    patch.object(perf.subprocess, "Popen") as popen, \
                    patch("builtins.print") as output:
                self.assertEqual(perf.run_once(root, "main"), 0)
            prepare_kit.assert_not_called()
            popen.assert_not_called()
            output.assert_called_once_with(f"perf run skipped: {self.HEAD} already measured")

    def test_force_remeasures_a_successful_head(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "lane"
            records = root / "records" / "perf.jsonl"
            perf.append_records(records, [{"head": self.HEAD, "state": "success", "run_id": "prior"}])
            metrics = {name: {"sample": 1} for name, _selector, _pattern in perf.BENCHMARKS}

            def run_slot_runner(*_args, **kwargs):
                kwargs["stdout"].write("[atlas-slots] acquired slot=2 load=normal tag=c11-perf-lane\n")
                kwargs["stdout"].flush()
                return object()

            with patch.object(perf, "prepare_worktree", return_value=(Path(temp) / "worktree", self.HEAD)), \
                    patch.object(perf, "prepare_ghosttykit"), \
                    patch.object(perf.subprocess, "Popen", side_effect=run_slot_runner), \
                    patch.object(perf, "wait_for_slot_process",
                                 return_value=(0, 10.0, 0.25, [20.0, 21.0, 22.0], False, 9.75)), \
                    patch.object(perf, "parse_metrics", return_value=metrics), \
                    patch.object(perf, "xcresult_state", return_value=("success", "xcresult passed")), \
                    patch.object(perf.time, "monotonic", side_effect=(10.0, 11.0)):
                self.assertEqual(perf.run_once(root, "main", force=True), 0)
            loaded = [json.loads(line) for line in records.read_text().splitlines()]
            self.assertEqual(len(loaded), 4)
            self.assertEqual(len({row["run_id"] for row in loaded[1:]}), 1)
            self.assertNotEqual(loaded[1]["run_id"], "prior")
            for row in loaded[1:]:
                self.assertEqual(row["state"], "success")
                self.assertEqual(row["slot_wait_seconds"], 0.25)
                self.assertEqual(row["slot"], 2)
                self.assertEqual(row["load_average"], [20.0, 21.0, 22.0])
                self.assertEqual(row["elapsed_seconds"], 1.0)

    def test_three_failed_attempts_skip_but_errors_do_not_count(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "lane"
            rows = [
                {"head": self.HEAD, "state": "failure", "run_id": f"failed-{n}"}
                for n in range(perf.MAX_FAILED_ATTEMPTS_PER_HEAD)
            ]
            rows.append({"head": self.HEAD, "state": "error", "run_id": "infrastructure"})
            perf.append_records(root / "records" / "perf.jsonl", rows)
            with patch.object(perf, "prepare_worktree", return_value=(Path(temp) / "worktree", self.HEAD)), \
                    patch.object(perf, "prepare_ghosttykit") as prepare_kit, \
                    patch.object(perf.subprocess, "Popen") as popen, \
                    patch("builtins.print") as output:
                self.assertEqual(perf.run_once(root, "main"), 0)
            prepare_kit.assert_not_called()
            popen.assert_not_called()
            output.assert_called_once_with(
                f"perf run skipped: {self.HEAD} failed {perf.MAX_FAILED_ATTEMPTS_PER_HEAD} times"
            )

    def test_cli_force_flag_is_forwarded_to_manual_run(self):
        with patch.object(perf, "run_once", return_value=0) as run:
            self.assertEqual(perf.main([str(SCRIPT), "run", "--root", "/tmp/perf-lane", "--force"]), 0)
        run.assert_called_once_with(Path("/tmp/perf-lane"), "main", force=True)

    def test_admission_timeout_is_unavailable_and_lane_timeout_is_error(self):
        metrics = {}
        self.assertEqual(
            perf.classify_run_result(
                75, False, "[atlas-slots] admission timed out", None, None, metrics
            ),
            ("unavailable", "slot admission timed out"),
        )
        state, reason = perf.classify_run_result(124, True, "", None, None, metrics)
        self.assertEqual(state, "error")
        self.assertEqual(reason, f"lane timed out after {perf.TIMEOUT_S} seconds")

    def test_slot_wait_exceeding_lane_budget_does_not_timeout_until_acquired(self):
        with tempfile.TemporaryDirectory() as temp:
            slot_record = Path(temp) / "slot.json"
            now = [0.0]
            sleeps = [0]

            class RunningProcess:
                def poll(self):
                    return None

            def sleep(_seconds):
                sleeps[0] += 1
                now[0] += 100.0 if sleeps[0] == 1 else 1.0
                if sleeps[0] == 1:
                    slot_record.write_text('{"slot_wait_seconds": 100.0}\n')

            with patch.object(perf.time, "monotonic", side_effect=lambda: now[0]), \
                    patch.object(perf.time, "sleep", side_effect=sleep), \
                    patch.object(perf, "load_average", return_value=[25.0, 26.0, 27.0]), \
                    patch.object(perf, "terminate_group") as terminate:
                result = perf.wait_for_slot_process(RunningProcess(), slot_record, timeout_s=2.0)
            self.assertEqual(result[0], 124)
            self.assertEqual(result[1], 100.0)
            self.assertEqual(result[2], 100.0)
            self.assertEqual(result[3], [25.0, 26.0, 27.0])
            self.assertTrue(result[4])
            self.assertEqual(result[5], 0.0)
            terminate.assert_called_once()


if __name__ == "__main__":
    unittest.main(verbosity=2)
