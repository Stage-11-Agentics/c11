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
ARTIFACT_RETENTION_S = 30 * 24 * 60 * 60
BENCHMARKS = (
    (
        "command-search",
        "c11Tests/CommandPaletteSearchEngineTests/testCommandSearchBenchmarkBeatsLegacyPipeline",
        re.compile(r"BENCH cmd\+shift\+p reference=([0-9.]+)ms optimized=([0-9.]+)ms"),
    ),
    (
        "switcher-search",
        "c11Tests/CommandPaletteSearchEngineTests/testSwitcherSearchBenchmarkBeatsLegacyPipeline",
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


def append_records(path: Path, records: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as output:
        fcntl.flock(output.fileno(), fcntl.LOCK_EX)
        for record in records:
            output.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        output.flush()


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


def run_once(root: Path, ref: str) -> int:
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
        prepare_ghosttykit(worktree)
        results = root / "results"
        logs = root / "logs"
        results.mkdir(exist_ok=True)
        logs.mkdir(exist_ok=True)
        prune_artifacts(root)
        run_id = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z") + "-" + uuid.uuid4().hex[:8]
        result_bundle = results / (run_id + ".xcresult")
        log_path = logs / (run_id + ".log")
        derived = root / "DerivedData"
        source_packages = root / "SourcePackages"
        source_packages.mkdir(exist_ok=True)
        xcodebuild = Path(DEVELOPER_DIR) / "usr" / "bin" / "xcodebuild"
        xcrun = Path(DEVELOPER_DIR) / "usr" / "bin" / "xcrun"
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
        env["PATH"] = ":".join((str(Path.home() / "zig-0.15.2"), "/opt/homebrew/bin", "/usr/bin", "/bin"))
        env.pop("C11_BUILD_LOCK", None)
        started = time.monotonic()
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                argv, cwd=worktree, env=env, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                exit_code = process.wait(timeout=TIMEOUT_S)
            except subprocess.TimeoutExpired:
                terminate_group(process)
                exit_code = 124
        elapsed_seconds = round(time.monotonic() - started, 3)
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        metrics = parse_metrics(log_text)
        summary: object = None
        if result_bundle.exists():
            summary_result = subprocess.run(
                [str(xcrun), "xcresulttool", "get", "test-results", "summary",
                 "--path", str(result_bundle), "--compact"],
                capture_output=True, text=True, timeout=30, env=env,
            )
            if summary_result.returncode == 0:
                try:
                    summary = json.loads(summary_result.stdout)
                except ValueError:
                    summary = None
        state_value, reason = xcresult_state(summary)
        if exit_code != 0:
            state_value, reason = "failure", f"xcodebuild exited {exit_code}"
        elif state_value == "success" and len(metrics) != len(BENCHMARKS):
            state_value, reason = "error", "one or more benchmark metrics were not emitted"
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
        print("usage: c11-perf-lane.py run --root <directory> [--ref main]", file=sys.stderr)
        return 2
    root = None
    ref = "main"
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
        else:
            print(f"unknown argument: {arg}", file=sys.stderr)
            return 2
    if root is None:
        print("--root is required", file=sys.stderr)
        return 2
    try:
        return run_once(root, ref)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"perf lane error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
