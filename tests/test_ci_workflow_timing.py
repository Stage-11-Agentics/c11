#!/usr/bin/env python3
"""Behavioral checks for completed-attempt timing, including retries and failures."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("timing", Path(__file__).resolve().parents[1] / "scripts/ci-workflow-timing.py")
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)


class TimingTests(unittest.TestCase):
    def setUp(self):
        self.run = dict(id=123, run_attempt=2, name="CI", head_sha="a" * 40,
                        conclusion="failure", html_url="https://example.invalid/run/123",
                        run_started_at="2026-10-31T20:00:00Z")

    def job(self, name, start, end, attempt=2, result="success"):
        return dict(id=1, name=name, status="completed", conclusion=result, run_attempt=attempt,
                    started_at=f"2026-10-31T20:{start}Z", completed_at=f"2026-10-31T20:{end}Z", steps=[])

    def test_failed_attempt_includes_handoffs_but_not_prior_attempt(self):
        data = timing.report(self.run, [{"jobs": [self.job("old", "00:00", "09:00", 1),
                                                 self.job("guards", "00:05", "00:55")]},
                                       {"jobs": [self.job("aggregate", "01:00", "01:03", result="failure")]}])
        self.assertEqual(data["wall_seconds"], 58)
        self.assertEqual(data["queue_seconds"], 5)
        self.assertEqual([j["name"] for j in data["jobs"]], ["guards", "aggregate"])
        self.assertEqual(data["jobs"][1]["start_offset_seconds"], 55)
        self.assertIn("failure", timing.markdown(data))

    def test_no_started_jobs_is_not_zero_second_success(self):
        data = timing.report(self.run, [{"jobs": []}])
        self.assertIsNone(data["wall_seconds"])
        self.assertIn("no started jobs", timing.markdown(data))

    def test_incomplete_job_refuses_partial_measurement(self):
        job = self.job("running", "00:01", "00:02")
        job["status"] = "in_progress"
        with self.assertRaisesRegex(ValueError, "completed"):
            timing.report(self.run, [{"jobs": [job]}])


if __name__ == "__main__":
    unittest.main()
