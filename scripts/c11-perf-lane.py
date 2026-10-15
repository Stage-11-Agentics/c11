#!/usr/bin/env python3
"""Run the non-gating c11 performance measurements on Atlas main."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime


REPO_URL = "https://github.com/Stage-11-Agentics/c11.git"
SLOT_RUNNER = Path.home() / "c11-poller" / "bin" / "atlas_build_slots.py"
DEVELOPER_DIR = "/Applications/Xcode-26.3.app/Contents/Developer"
TIMEOUT_S = 1800
MAX_FAILED_ATTEMPTS_PER_HEAD = 3
ARTIFACT_RETENTION_S = 30 * 24 * 60 * 60
ACQUIRED_SLOT = re.compile(r"\[atlas-slots\] acquired slot=([0-9]+)\b")
BENCHMARKS = (
    (
        "command-search",
        "c11LogicTests/CommandPaletteSearchEngineTests/testCommandSearchBenchmarkBeatsLegacyPipeline",
        re.compile(r"BENCH cmd\+shift\+p reference=([0-9.]+)ms optimized=([0-9.]+)ms"),
    ),
    (
        "switcher-search",
        "c11LogicTests/CommandPaletteSearchEngineTests/testSwitcherSearchBenchmarkBeatsLegacyPipeline",
        re.compile(r"BENCH cmd\+p reference=([0-9.]+)ms optimized=([0-9.]+)ms"),
    ),
    (
        "corpus-bridge-submission",
        "c11Tests/MarkdownWebRendererTests/testCorpusBridgeSubmissionCostOnC11Checkout",
        re.compile(
            r"CORPUS_PUBLISH_C11_CHECKOUT bytes=([0-9]+) "
            r"medianMainMs=([0-9.]+) samplesMs=([0-9.,]+)"
        ),
    ),
)


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(repo), *args],
        check=True, capture_output=True, text=True, timeout=120,
    )
    return result.stdout.strip()


def prepare_worktree(root: Path, ref: str) -> tuple[Path, str]:
    worktree = root / "worktree"
    if not worktree.exists():
        worktree.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["/usr/bin/git", "clone", "--no-tags", REPO_URL, str(worktree)],
            check=True, timeout=300,
        )
    if not (worktree / ".git").exists():
        raise RuntimeError(f"perf worktree is not a git checkout: {worktree}")
    origin = git(worktree, "remote", "get-url", "origin").removesuffix(".git")
    if origin != REPO_URL.removesuffix(".git"):
        raise RuntimeError(f"unexpected perf worktree origin: {origin}")
    if git(worktree, "status", "--porcelain"):
        raise RuntimeError("perf worktree has local changes; refusing to reset it")
    subprocess.run(
        ["/usr/bin/git", "-C", str(worktree), "fetch", "--no-tags", "origin", ref],
        check=True, timeout=300,
    )
    git(worktree, "checkout", "--detach", "--force", "FETCH_HEAD")
    head = git(worktree, "rev-parse", "HEAD")
    subprocess.run(
        ["/usr/bin/git", "-C", str(worktree), "submodule", "update", "--init", "--recursive",
         "ghostty", "vendor/bonsplit"],
        check=True, timeout=600,
    )
    return worktree, head


def prepare_ghosttykit(worktree: Path) -> None:
    gitlink = git(worktree, "rev-parse", "HEAD:ghostty")
    kit = Path.home() / ".cache" / "cmux" / "ghosttykit" / gitlink / "GhosttyKit.xcframework"
    if not kit.is_dir():
        kit.parent.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["GHOSTTY_SHA"] = gitlink
        env["GHOSTTYKIT_OUTPUT_DIR"] = str(kit)
        subprocess.run(
            [str(worktree / "scripts" / "download-prebuilt-ghosttykit.sh")],
            cwd=kit.parent, env=env, check=True, timeout=600,
        )
    if not kit.is_dir():
        raise RuntimeError(f"GhosttyKit cache is missing for {gitlink}")
    link = worktree / "GhosttyKit.xcframework"
    if link.is_symlink():
        if link.resolve() == kit.resolve():
            return
        link.unlink()
    elif link.exists():
        raise RuntimeError(f"refusing to replace a non-symlink {link}")
    link.symlink_to(kit)


def parse_metrics(log_text: str) -> dict[str, dict[str, object]]:
    values: dict[str, dict[str, object]] = {}
    for name, _selector, pattern in BENCHMARKS:
        match = pattern.search(log_text)
        if match is None:
            continue
        if name == "corpus-bridge-submission":
            values[name] = {
                "bytes": int(match.group(1)),
                "median_main_ms": float(match.group(2)),
                "samples_ms": [float(value) for value in match.group(3).split(",")],
            }
        else:
            values[name] = {
                "reference_ms": float(match.group(1)),
                "optimized_ms": float(match.group(2)),
            }
    return values


def xcresult_state(report: object) -> tuple[str, str]:
    if type(report) is not dict:
        return "error", "xcresult summary unavailable"
    if report.get("result") == "Failed":
        return "failure", "xcresult reports failed tests"
    total = report.get("totalTestCount")
    skipped = report.get("skippedTests")
    failed = report.get("failedTests")
    if type(total) is not int or type(skipped) is not int or type(failed) is not int:
        return "error", "xcresult summary is missing test counts"
    if total - skipped <= 0:
        return "failure", "xcresult reports zero executed tests"
    if failed > 0:
        return "failure", f"xcresult reports {failed} failed tests"
    if report.get("result") == "Passed":
        return "success", "xcresult passed"
    return "error", f"unrecognized xcresult result {report.get('result')!r}"


def classify_run_result(
    exit_code: int, lane_timed_out: bool, log_text: str, summary: object,
    summary_error: str | None, metrics: dict[str, dict[str, object]],
) -> tuple[str, str]:
    state_value, reason = xcresult_state(summary)
    if summary_error is not None:
        state_value, reason = "error", f"xcresult summary unavailable: {summary_error}"
    if exit_code == 75 and "[atlas-slots] admission timed out" in log_text:
        return "unavailable", "slot admission timed out"
    if lane_timed_out:
        return "error", f"lane timed out after {TIMEOUT_S} seconds"
    if exit_code != 0:
        return "failure", f"xcodebuild exited {exit_code}"
    if state_value == "success" and len(metrics) != len(BENCHMARKS):
        return "error", "one or more benchmark metrics were not emitted"
    return state_value, reason


def read_xcresult_summary(
    xcrun: Path, result_bundle: Path, env: dict[str, str]
) -> tuple[object, str | None]:
    try:
        result = subprocess.run(
            [str(xcrun), "xcresulttool", "get", "test-results", "summary",
             "--path", str(result_bundle), "--compact"],
            capture_output=True, text=True, timeout=30, env=env,
        )
    except (OSError, subprocess.SubprocessError) as error:
        return None, str(error)
    if result.returncode != 0:
        return None, f"xcresulttool exited {result.returncode}: {result.stderr.strip()}"
    try:
        return json.loads(result.stdout), None
    except ValueError as error:
        return None, f"xcresult summary is not JSON: {error}"


def append_records(path: Path, records: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as output:
        fcntl.flock(output.fileno(), fcntl.LOCK_EX)
        for record in records:
            output.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        output.flush()


def head_measurements(path: Path, head: str) -> tuple[bool, set[str]]:
    """Return whether this head passed and the unique failed run ids already recorded."""
    succeeded = False
    failed_runs: set[str] = set()
    try:
        records = path.open("r", encoding="utf-8")
    except FileNotFoundError:
        return False, failed_runs
    with records:
        for line in records:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if type(record) is not dict or record.get("head") != head:
                continue
            if record.get("state") == "success":
                succeeded = True
            elif record.get("state") == "failure" and isinstance(record.get("run_id"), str):
                failed_runs.add(record["run_id"])
    return succeeded, failed_runs


def load_average() -> list[float] | None:
    try:
        return [round(float(value), 2) for value in os.getloadavg()]
    except OSError:
        return None


def wait_for_slot_process(
    process: subprocess.Popen[bytes], slot_record: Path, timeout_s: float,
) -> tuple[int, float | None, float | None, list[float] | None, bool, float]:
    """Wait without spending the build/test budget before the fleet slot is acquired."""
    admission_started = time.monotonic()
    build_started = None
    slot_wait_seconds = None
    load = None
    while True:
        if slot_record.exists():
            if build_started is None:
                build_started = time.monotonic()
                load = load_average()
            try:
                row = json.loads(slot_record.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                row = {}
            value = row.get("slot_wait_seconds") if type(row) is dict else None
            if type(value) in (int, float):
                slot_wait_seconds = float(value)

        exit_code = process.poll()
        if exit_code is not None:
            return exit_code, build_started, slot_wait_seconds, load, False, admission_started
        if build_started is not None and time.monotonic() - build_started >= timeout_s:
            terminate_group(process)
            return 124, build_started, slot_wait_seconds, load, True, admission_started
        time.sleep(0.05)


def acquired_slot(log_text: str) -> int | None:
    match = ACQUIRED_SLOT.search(log_text)
    return int(match.group(1)) if match else None


def prune_artifacts(root: Path) -> None:
    cutoff = time.time() - ARTIFACT_RETENTION_S
    for directory in (root / "results", root / "logs"):
        if not directory.exists():
            continue
        for path in directory.iterdir():
            try:
                if path.stat().st_mtime >= cutoff:
                    continue
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            except FileNotFoundError:
                continue


def terminate_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=10)


def run_once(root: Path, ref: str, force: bool = False) -> int:
    root = root.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    state = root / "state"
    state.mkdir(exist_ok=True)
    with (state / "run.lock").open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("perf run skipped: another run holds the lock")
            return 0

        worktree, head = prepare_worktree(root, ref)
        records_path = root / "records" / "perf.jsonl"
        succeeded, failed_runs = head_measurements(records_path, head)
        if not force and succeeded:
            print(f"perf run skipped: {head} already measured")
            return 0
        if not force and len(failed_runs) >= MAX_FAILED_ATTEMPTS_PER_HEAD:
            print(f"perf run skipped: {head} failed {len(failed_runs)} times")
            return 0
        prepare_ghosttykit(worktree)
        results = root / "results"
        logs = root / "logs"
        results.mkdir(exist_ok=True)
        logs.mkdir(exist_ok=True)
        prune_artifacts(root)
        run_id = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z") + "-" + uuid.uuid4().hex[:8]
        result_bundle = results / (run_id + ".xcresult")
        log_path = logs / (run_id + ".log")
        slot_record = state / (run_id + ".slot.json")
        derived = root / "DerivedData"
        source_packages = root / "SourcePackages"
        source_packages.mkdir(exist_ok=True)
        xcodebuild = Path(DEVELOPER_DIR) / "usr" / "bin" / "xcodebuild"
        xcrun = Path("/usr/bin/xcrun")
        selectors = [f"-only-testing:{selector}" for _name, selector, _pattern in BENCHMARKS]
        argv = [
            str(SLOT_RUNNER), "c11-perf-lane", str(xcodebuild),
            "-project", str(worktree / "GhosttyTabs.xcodeproj"),
            "-scheme", "c11-unit", "-configuration", "Debug",
            "-destination", "platform=macOS",
            "-derivedDataPath", str(derived),
            "-clonedSourcePackagesDirPath", str(source_packages),
            "-resultBundlePath", str(result_bundle),
            "-parallel-testing-enabled", "NO",
            "-test-timeouts-enabled", "YES",
            "-default-test-execution-time-allowance", "60",
            "-maximum-test-execution-time-allowance", "60",
            *selectors,
            "COMPILER_INDEX_STORE_ENABLE=NO", "test",
        ]
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = DEVELOPER_DIR
        env["C11_PERF_LANE"] = "1"
        env["C11_ATLAS_SLOT_RECORD_PATH"] = str(slot_record)
        env["PATH"] = ":".join((str(Path.home() / "zig-0.15.2"), "/opt/homebrew/bin", "/usr/bin", "/bin"))
        env.pop("C11_BUILD_LOCK", None)
        admission_started = time.monotonic()
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                argv, cwd=worktree, env=env, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            exit_code, build_started, slot_wait_seconds, load, lane_timed_out, admission_started = \
                wait_for_slot_process(process, slot_record, TIMEOUT_S)
        finished = time.monotonic()
        elapsed_seconds = round(finished - build_started, 3) if build_started is not None else None
        if slot_wait_seconds is None:
            slot_wait_seconds = round(finished - admission_started, 3)
        if load is None:
            load = load_average()
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        slot = acquired_slot(log_text)
        metrics = parse_metrics(log_text)
        summary: object = None
        summary_error = None
        if result_bundle.exists():
            summary, summary_error = read_xcresult_summary(xcrun, result_bundle, env)
        state_value, reason = classify_run_result(
            exit_code, lane_timed_out, log_text, summary, summary_error, metrics
        )
        if state_value == "success" and result_bundle.exists():
            shutil.rmtree(result_bundle)
        timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
        records: list[dict[str, object]] = []
        for name, selector, _pattern in BENCHMARKS:
            record: dict[str, object] = {
                "timestamp": timestamp,
                "head": head,
                "run_id": run_id,
                "benchmark": name,
                "selector": selector,
                "state": state_value,
                "reason": reason,
                "elapsed_seconds": elapsed_seconds,
                "slot_wait_seconds": slot_wait_seconds,
                "slot": slot,
                "load_average": load,
                "log": str(log_path),
                "result_bundle": str(result_bundle) if result_bundle.exists() else None,
            }
            record.update(metrics.get(name, {}))
            records.append(record)
        append_records(root / "records" / "perf.jsonl", records)
        for record in records:
            print(json.dumps(record, sort_keys=True))
        return 0 if state_value == "success" else 1


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] != "run":
        print("usage: c11-perf-lane.py run --root <directory> [--ref main] [--force]", file=sys.stderr)
        return 2
    root = None
    ref = "main"
    force = False
    args = iter(argv[2:])
    for arg in args:
        if arg == "--root":
            try:
                root = Path(next(args))
            except StopIteration:
                print("--root requires a path", file=sys.stderr)
                return 2
        elif arg == "--ref":
            try:
                ref = next(args)
            except StopIteration:
                print("--ref requires a ref", file=sys.stderr)
                return 2
        elif arg == "--force":
            force = True
        else:
            print(f"unknown argument: {arg}", file=sys.stderr)
            return 2
    if root is None:
        print("--root is required", file=sys.stderr)
        return 2
    try:
        return run_once(root, ref, force=force)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"perf lane error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
