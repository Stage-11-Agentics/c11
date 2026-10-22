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
)


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name, filename, old, new, test in MUTANTS:
        with tempfile.TemporaryDirectory(prefix="c11-backstop-mutant-") as directory:
            target = Path(directory)
            for source in ("c11-main-backstop.py", "c11-main-backstop-test.py", "c11-main-backstop-service.py",
                           "c11-pr-swift-poller.py", "host_test_quarantine.py", "atlas_build_slots.py"):
                shutil.copy2(HERE / source, target / source)
            changed = target / filename
            text = changed.read_text()
            if text.count(old) != 1:
                raise RuntimeError("mutation anchor changed: " + name)
            changed.write_text(text.replace(old, new))
            with (output / (name + ".log")).open("w") as log:
                result = subprocess.run([sys.executable, str(target / "c11-main-backstop-test.py"),
                                         "Acceptance." + test], stdout=log, stderr=log, timeout=90)
            if result.returncode == 0:
                raise RuntimeError("mutant survived: " + name)
            print("RED", name, flush=True)
    with (output / "restored-green.log").open("w") as log:
        result = subprocess.run([sys.executable, str(HERE / "c11-main-backstop-test.py")],
                                stdout=log, stderr=log, timeout=90)
    if result.returncode:
        raise RuntimeError("restored suite failed")
    print("GREEN restored acceptance", flush=True)


if __name__ == "__main__":
    main()
