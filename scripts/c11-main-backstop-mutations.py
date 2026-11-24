#!/usr/bin/env python3
"""Prove each acceptance guard goes red in disposable copies, then rerun restored green."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
MUTANTS = (
    ("install-main", "c11-main-backstop-service.py", 'URL, "refs/heads/main"', 'URL, "refs/heads/feature"', "test_service_stages_main_bytes_even_from_a_feature_checkout"),
    ("main-rewrite", "c11-main-backstop.py", "if previous and previous != sha:", "if False:", "test_main_history_coalesces_and_refuses_rewrites"),
    ("fork-pr", "c11-main-backstop.py", "if not admitted:", "if False:", "test_fork_never_queues_and_missing_status_yields"),
    ("post-preparation", "c11-main-backstop.py", "if pr_work_pending() or remote_tip() != sha:", "if False:", "test_child_revalidates_after_preparation"),
    ("build-failure", "c11-main-backstop.py", 'state = "failure" if code else "success"', 'state = "success"', "test_gate_runs_all_stages_and_classifies_real_exit_and_zero_tests"),
    ("zero-tests", "c11-pr-swift-poller.py", "if total - skipped <= 0 or failed > 0:", "if failed > 0:", "test_gate_runs_all_stages_and_classifies_real_exit_and_zero_tests"),
    ("slot-one", "c11-main-backstop.py", '"astra-466", "--poller", "/usr/bin/python3",', '"astra-466", "/usr/bin/python3",', "test_slot_contention_and_dry_run_no_posts"),
    ("dry-status", "c11-main-backstop.py", "if publish:\n        post(result)", "if True:\n        post(result)", "test_slot_contention_and_dry_run_no_posts"),
    ("running-pr-yield", "c11-main-backstop.py", "if pr_work_pending():\n                        interruption", "if False:\n                        interruption", "test_running_backstop_yields_to_pr_demand"),
    ("status-context", "c11-main-backstop.py", 'CONTEXT = "c11/main-atlas"', 'CONTEXT = "CI main (macOS)"', "test_status_context_and_elapsed_are_not_failure"),
    ("service-stop", "c11-main-backstop-service.py", '        stop()\n        if args.mode == "teardown":', '        pass\n        if args.mode == "teardown":', "test_service_install_update_rollback_teardown_leaves_poller"),
    ("backstop-stale-cache", "c11-main-backstop.py", "if stale is None or run == 2:", "if True:", "test_quick_link_or_codesign_failure_rebuilds_once_from_a_clean_cache"),
    ("backstop-rerun-bundle", "c11-main-backstop.py", "        if result is not None and run > 1:\n", "        if False:\n", "test_quick_link_failure_in_the_logic_stage_reruns_with_a_new_bundle"),
    ("backstop-error-reason", "c11-main-backstop.py", "                return stage[\"description\"][:140]\n", "                pass\n", "test_unreadable_result_retries_once_then_errors_never_failure"),
    ("backstop-summary-retry", "c11-main-backstop.py", "time.sleep, tries=2)", "time.sleep, tries=1)", "test_unreadable_result_retries_once_then_errors_never_failure"),
    ("backstop-sweep-removed", "c11-main-backstop.py", "            last_sweep = sweep_results(root, last_sweep)\n", "", "test_supervise_loop_sweeps_old_results_hourly_with_the_poller_rule"),
    ("backstop-sweep-running", "c11-main-backstop.py", 'return {(poller.read_running(root) or {}).get("attempt_id")}', "return set()", "test_supervise_loop_sweeps_old_results_hourly_with_the_poller_rule"),
    ("backstop-sweep-record", "c11-main-backstop.py", ', "attempt_id": attempt.name}', "}", "test_running_record_names_the_attempt_the_sweep_must_keep"),
)
# C11-561 guards in the PR poller, run against its own suite.
POLLER_MUTANTS = (
    ("poller-stale-cache", "if kind and elapsed < STALE_CACHE_S:", "if False:", "test_quick_link_failure_wipes_the_key_cache_and_rebuilds_once"),
    ("poller-stale-cache-codesign", "if kind and elapsed < STALE_CACHE_S:", "if kind == 'link' and elapsed < STALE_CACHE_S:", "test_quick_codesign_failure_twice_posts_the_real_failure"),
    ("poller-stale-cache-under-a-minute", "if kind and elapsed < STALE_CACHE_S:", "if kind:", "test_slow_or_ordinary_failure_keeps_the_cache"),
    ("poller-summary-retry", "def read_summary(read, sleep, tries=2):", "def read_summary(read, sleep, tries=1):", "test_unreadable_summary_retries_once_then_posts_error_never_failure"),
    ("poller-summary-reason", "        if unreadable:\n", "        if False:\n", "test_unreadable_summary_retries_once_then_posts_error_never_failure"),
    ("poller-summary-timeout", "SUMMARY_TIMEOUT_S = 120", "SUMMARY_TIMEOUT_S = 30", "test_summary_read_allows_a_slow_xcresulttool"),
    ("poller-guest-clock-idle", "        if not feature_waiting:\n", "        if False:\n", "test_guest_wait_clock_starts_only_for_a_waiting_feature_head"),
    ("poller-guest-clock-cycle", "        feature_waiting = any(not release_head(item) for item in self.queue)\n        guests = self._guest_blocks_features(self.world.guests(), feature_waiting)\n        if not self.queue:\n            return \"idle\"\n", "        if not self.queue:\n            return \"idle\"\n        feature_waiting = any(not release_head(item) for item in self.queue)\n        guests = self._guest_blocks_features(self.world.guests(), feature_waiting)\n", "test_guest_wait_clock_does_not_carry_over_an_idle_gap"),
    ("poller-lookup-queued", 'if reason == "revoked" and str(_detail).startswith("lookup_failed"):', "if False:", "test_failed_pr_lookup_at_queue_time_keeps_the_head"),
    ("poller-guest-one-budget", "        if not guests:\n            return False\n        now = self.world.monotonic()", "        if not guests:\n            self.guest_wait_since = None\n            return False\n        now = self.world.monotonic()", "test_guests_that_come_and_go_share_one_ten_minute_budget"),
    ("poller-guest-wait", "        if waited < GUEST_WAIT_S:\n", "        if True:\n", "test_feature_head_waits_at_most_ten_minutes_for_a_guest"),
    ("poller-revoke-silent", '            self.delivered = False\n            self.log(decision="revoked"', '            self.delivered = self._post(sha, "failure", "revoked", pr=record.get("pr"))\n            self.log(decision="revoked"', "test_pr_merged_or_closed_mid_build_posts_nothing"),
    ("poller-superseded-error", 'self._post(sha, "error", "superseded"', 'self._post(sha, "failure", "superseded"', "test_new_push_mid_build_posts_error_superseded_never_failure"),
    ("poller-lookup-unknown", 'elif reason == "revoked" and (str(_detail).startswith("lookup_failed") or _detail == "ls_remote"):', "elif False:", "test_failed_pr_lookup_mid_build_keeps_the_build"),
    ("poller-sweep-removed", "        self._sweep_results()\n        if self.world.time() < self.not_before:\n", "        if self.world.time() < self.not_before:\n", "ResultSweepTests.test_cycle_sweeps_at_most_hourly"),
    ("poller-sweep-every-cycle", "    if last is not None and 0 <= now - last < SWEEP_INTERVAL_S:\n", "    if False:\n", "ResultSweepTests.test_cycle_sweeps_at_most_hourly"),
    ("poller-sweep-removed-real-supervise", "        self._sweep_results()\n        if self.world.time() < self.not_before:\n", "        if self.world.time() < self.not_before:\n", "RuntimeIntegrationTests.test_real_supervise_sweeps_old_results_and_still_posts_the_build"),
    ("poller-sweep-before-recover", '            return "disarmed"\n        if recover(self.root', '            return "disarmed"\n        self._sweep_results()\n        if recover(self.root', "ResultSweepTests.test_a_stuck_recovery_sweeps_nothing"),
    ("poller-sweep-in-build", '        command = slot_command(self.root, argv)\n', '        self.last_sweep = None\n        self._sweep_results()\n        command = slot_command(self.root, argv)\n', "ResultSweepTests.test_a_build_in_progress_is_never_swept_under_itself"),
    ("poller-sweep-live-attempts", 'return {recorded.get("attempt_id")} | {item.get("attempt_id") for item in self.queue}', "return set()", "ResultSweepTests.test_old_entries_go_recent_and_queued_or_running_attempts_stay"),
    ("poller-sweep-age", ".st_mtime >= cutoff or names_attempt", ".st_mtime >= cutoff + 1e12 or names_attempt", "ResultSweepTests.test_old_entries_go_recent_and_queued_or_running_attempts_stay"),
    ("poller-sweep-follows-links", "entry.stat(follow_symlinks=False).st_mtime", "entry.stat().st_mtime", "ResultSweepTests.test_symlinks_go_as_links_and_nothing_outside_is_touched"),
    ("poller-sweep-link-as-dir", "elif entry.is_dir(follow_symlinks=False):", "elif entry.is_dir():", "ResultSweepTests.test_symlinks_go_as_links_and_nothing_outside_is_touched"),
    ("poller-sweep-root-link", "        if os.path.islink(results):\n", "        if False:\n", "ResultSweepTests.test_a_symlinked_results_root_is_refused"),
    ("poller-sweep-entry-failure", "        except Exception as error:\n            failed(entry.name, error)\n", "        except ZeroDivisionError as error:\n            failed(entry.name, error)\n", "ResultSweepTests.test_a_permission_error_is_one_line_and_the_build_still_posts"),
    ("poller-sweep-scan-failure", "    except OSError as error:\n        failed(os.path.basename(results), error)\n        return outcome\n", "", "ResultSweepTests.test_an_unreadable_results_directory_is_one_line_and_the_cycle_continues"),
    ("poller-sweep-log-failure", "    try:\n        log(**outcome)\n    except Exception:\n        pass\n", "    log(**outcome)\n", "ResultSweepTests.test_a_failed_attempt_read_or_log_write_never_raises"),
    ("poller-sweep-attempt-failure", "    try:\n        outcome = sweep_results(results, now, attempts())\n    except Exception as error:\n        outcome = {\"removed\": 0, \"kept\": 0, \"failed\": 1, \"error\": \"sweep: %s\" % type(error).__name__}\n", "    outcome = sweep_results(results, now, attempts())\n", "ResultSweepTests.test_a_failed_attempt_read_or_log_write_never_raises"),
    ("poller-sweep-prefix", 'name.startswith((attempt + "-", attempt + "."))', "name.startswith(attempt)", "ResultSweepTests.test_an_attempt_prefix_protects_only_that_attempt"),
    ("poller-pull-404", '        if status != 200:\n            raise LookupUnavailable', '        if status != 200:\n            return None\n            raise LookupUnavailable', "test_production_pull_treats_only_404_as_missing"),
)
COPIED = ("c11-main-backstop.py", "c11-main-backstop-test.py", "c11-main-backstop-service.py",
          "c11-pr-swift-poller.py", "c11-pr-swift-poller-test.py", "host_test_quarantine.py", "atlas_build_slots.py")


def mutate(output, name, filename, old, new, suite, test):
    with tempfile.TemporaryDirectory(prefix="c11-backstop-mutant-") as directory:
        # A scripts/ directory, as in the repo: the poller suite builds from its parent.
        target = Path(directory) / "scripts"
        target.mkdir()
        for source in COPIED + ("host-test-quarantine.tsv",):
            shutil.copy2(HERE / source, target / source)
        shutil.copytree(HERE / "launchd", target / "launchd")
        changed = target / filename
        text = changed.read_text()
        if text.count(old) != 1:
            raise RuntimeError("mutation anchor changed: " + name)
        changed.write_text(text.replace(old, new))
        with (output / (name + ".log")).open("w") as log:
            result = subprocess.run([sys.executable, str(target / suite), test],
                                    stdout=log, stderr=log, timeout=90)
        if result.returncode == 0:
            raise RuntimeError("mutant survived: " + name)
        print("RED", name, flush=True)


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name, filename, old, new, test in MUTANTS:
        mutate(output, name, filename, old, new, "c11-main-backstop-test.py", "Acceptance." + test)
    for name, old, new, test in POLLER_MUTANTS:
        mutate(output, name, "c11-pr-swift-poller.py", old, new, "c11-pr-swift-poller-test.py",
               test if "." in test else "CacheResultGuestRevokeTests." + test)
    with (output / "restored-green.log").open("w") as log:
        result = subprocess.run([sys.executable, str(HERE / "c11-main-backstop-test.py")],
                                stdout=log, stderr=log, timeout=90)
    if result.returncode:
        raise RuntimeError("restored suite failed")
    with (output / "restored-poller-green.log").open("w") as log:
        result = subprocess.run([sys.executable, str(HERE / "c11-pr-swift-poller-test.py"), "CacheResultGuestRevokeTests", "ResultSweepTests"],
                                stdout=log, stderr=log, timeout=90)
    if result.returncode:
        raise RuntimeError("restored poller guards failed")
    print("GREEN restored acceptance", flush=True)


if __name__ == "__main__":
    main()
