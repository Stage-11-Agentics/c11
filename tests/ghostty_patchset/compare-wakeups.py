#!/usr/bin/env python3
"""C11-302 preliminary paired gate; consumes unchanged runtime-fixture results."""
import argparse
import json
from pathlib import Path


def compare(baseline, candidate):
    errors = []
    for label, run in (("baseline", baseline), ("candidate", candidate)):
        if run.get("status") != "PASS_FOR_REPORTED_SCENARIOS":
            errors.append(f"{label}: incomplete runtime run")
        if run.get("input_mode") != "appkit-quartz-pid-scoped":
            errors.append(f"{label}: real PID-scoped input required")
        if run.get("responsiveness", {}).get("missed") != 0:
            errors.append(f"{label}: missed or missing input results")
        if run.get("workload", {}).get("samples") != 100 or run.get("workload", {}).get("streams") != 30:
            errors.append(f"{label}: requires 100 samples and 30 streams")
    for key in ("fixture_sha256", "measurement_version", "engine_sha_claim", "guest_hardware", "workload"):
        if baseline.get(key) != candidate.get(key):
            errors.append(f"unmatched {key}")
    if baseline.get("ui_driver", {}).get("sha256") != candidate.get("ui_driver", {}).get("sha256"):
        errors.append("unmatched UI driver")

    measurements = {}
    for metric in ("key_to_pty_ms", "key_to_read_screen_ms"):
        before = baseline.get("responsiveness", {}).get(metric) or {}
        after = candidate.get("responsiveness", {}).get(metric) or {}
        measurements[metric] = {"baseline": before, "candidate": after}
        if metric == "key_to_pty_ms":
            for percentile in ("p95", "p99"):
                if percentile not in before or percentile not in after:
                    errors.append(f"missing {metric}.{percentile}")
                    continue
                ceiling = before[percentile] + max(5, before[percentile] * .20)
                measurements[metric][percentile + "_ceiling_ms"] = ceiling
                if after[percentile] > ceiling:
                    errors.append(f"{metric}.{percentile} exceeds predeclared margin")

    snapshots = [observation["stats"]["tickScheduling"]
                 for sample in candidate.get("responsiveness", {}).get("samples", [])
                 for observation in (sample.get("readiness") or {}).get("observations", [])
                 if "tickScheduling" in observation.get("stats", {})]
    if not snapshots:
        errors.append("missing production tick scheduling snapshots")
    else:
        if any(s["maxPending"] != 1 or s["pending"] > 1 for s in snapshots):
            errors.append("pending tick bound violated")
        if snapshots[-1]["drained"] <= snapshots[0]["drained"]:
            errors.append("no observed tick progress during sample")
        if snapshots[-1]["requests"] <= snapshots[-1]["enqueued"]:
            errors.append("no observed coalescing")
    return {
        "status": "FAIL" if errors else "PASS_PRELIMINARY_PAIRED_SAMPLE",
        "errors": errors,
        "budget": "zero misses; Return-to-PTY p95/p99 <= baseline + max(5ms, 20%)",
        "measurements": measurements,
        "tick_scheduling_first": snapshots[0] if snapshots else None,
        "tick_scheduling_last": snapshots[-1] if snapshots else None,
        "load_average_start": {"baseline": baseline.get("load_average_start"),
                               "candidate": candidate.get("load_average_start")},
        "limits": "Not fleet-soak or physical keyboard latency proof. Final-sentinel, scrollbar, color/config and teardown scenarios are recorded separately.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    result = compare(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()))
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(result["status"])
    raise SystemExit(bool(result["errors"]))
