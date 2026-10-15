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

    def test_appends_each_measurement_as_one_json_line(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "records" / "perf.jsonl"
            records = [{"benchmark": item[0], "state": "success"} for item in perf.BENCHMARKS]
            perf.append_records(path, records)
            loaded = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual(loaded, records)


if __name__ == "__main__":
    unittest.main(verbosity=2)
