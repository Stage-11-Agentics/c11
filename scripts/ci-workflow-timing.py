#!/usr/bin/env python3
"""Report one completed Actions attempt, including setup, post steps and job gaps."""
import argparse
from datetime import datetime
import json
from pathlib import Path


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def report(run, pages):
    attempt = run["run_attempt"]
    jobs = []
    for page in pages:
        for job in page["jobs"]:
            # Never combine successful jobs retained from an earlier attempt.
            if job.get("run_attempt") != attempt:
                continue
            if job["status"] != "completed":
                raise ValueError("timing requires a completed attempt")
            if job["conclusion"] == "skipped" or not job.get("started_at"):
                continue
            start, end = instant(job["started_at"]), instant(job["completed_at"])
            if end < start:
                raise ValueError("job ended before it started")
            steps = []
            for step in job.get("steps", []):
                if step.get("started_at") and step.get("completed_at") and step.get("conclusion") != "skipped":
                    steps.append({"name": step["name"], "seconds": (instant(step["completed_at"]) - instant(step["started_at"])).total_seconds(), "conclusion": step.get("conclusion")})
            jobs.append({"name": job["name"], "id": job["id"], "start": start, "end": end,
                         "seconds": (end - start).total_seconds(), "conclusion": job["conclusion"], "steps": steps})
    first = min((j["start"] for j in jobs), default=None)
    last = max((j["end"] for j in jobs), default=None)
    for job in jobs:
        job["start_offset_seconds"] = (job.pop("start") - first).total_seconds()
        job.pop("end")
    return {"run_id": run["id"], "run_attempt": attempt, "workflow": run["name"],
            "workflow_head_sha": run["head_sha"], "conclusion": run["conclusion"], "url": run["html_url"],
            "wall_seconds": (last - first).total_seconds() if first else None,
            "queue_seconds": (first - instant(run["run_started_at"])).total_seconds() if first else None,
            "jobs": jobs}


def markdown(data):
    def cell(value):
        return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
    wall = data["wall_seconds"]
    lines = [f"Attempt {data['run_attempt']}: **{wall if wall is not None else 'no started jobs'} seconds** from first job start to last job end.",
             f"Queue before first job: {data['queue_seconds']} seconds. Result: {cell(data['conclusion'])}.",
             f"Workflow trigger head: `{data['workflow_head_sha']}`. A backstop may select a newer tip; its target log and commit status identify the tested head.",
             "", "| Job | Start offset (s) | Duration (s) | Result |", "|---|---:|---:|---|"]
    lines += [f"| {cell(j['name'])} | {j['start_offset_seconds']} | {j['seconds']} | {cell(j['conclusion'])} |" for j in data["jobs"]]
    for job in data["jobs"]:
        lines += ["", f"{cell(job['name'])} steps:", "", "| Step | Seconds | Result |", "|---|---:|---|"]
        lines += [f"| {cell(s['name'])} | {s['seconds']} | {cell(s['conclusion'])} |" for s in job["steps"]]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--jobs", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    args = parser.parse_args()
    data = report(json.loads(args.run.read_text()), json.loads(args.jobs.read_text()))
    args.output.write_text(json.dumps(data, indent=2) + "\n")
    with args.summary.open("a") as handle:
        handle.write(markdown(data))
    print(json.dumps(data))


if __name__ == "__main__":
    main()
