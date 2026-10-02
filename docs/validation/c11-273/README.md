# C11-273 validation checkpoint

Implementation is pushed on `c11-1.0/C11-273-journal`. This checkpoint is not a performance PASS or a review handoff.

## Artifact and scope

The tagged Debug artifact has product source commit `52056252f3f30b3bf42af24fd1c69b5ab724bf0c`, based on main `43529df178a9cd8817fc092896efd2f3fcd63df5`, including C11-263 `6926fa05cf`. Build invocation `29e130da722a4f2081c0c873eac23944` succeeded. Its declared overlay contains test/probe files only; the sanitized build manifest is [runtime-build.json](runtime-build.json). Later commits through `e764720703` change tests and probes only. The executable hash in the manifest distinguishes the remote build from the retrieved, path-adjusted signed artifact used in the guest.

All packaged-app execution used a disposable guest, a tagged app, an explicit isolated socket and QA fresh/resume. The real hooks, socket, SQLite files, spool, terminal and UI were exercised. Provider inputs were synthetic structural events except the explicitly recorded C11-271 hook shape. This does not claim a live provider end-to-end run or unsupported interrupt coverage.

## Passed checks

- **25 journal logic tests**: reducer 9, store 11, spool 5; invocation `60875ef7f7a5431e8e4fd905577fd8e7`. Actual test action passed, including reopening the database and folding multiple historical events after the process changes. Prior targeted liveness/journal gate passed 45 tests before that additional store test. Four workspace-constructing liveness tests were excluded for the known no-host NSApp limitation. The two run-wide test exclusions were also applied.
- **Three guest runtime scripts**: `test_journal_append_replay.py`, `test_journal_restart.py`, and the unchanged `test_claude_attention_batch.py` passed. See [runtime-checks.txt](runtime-checks.txt). They cover sibling/seen/legacy isolation, blocked persistence across Stop/late tools, terminal ordering, recorded ExitPlanMode input, lost reply retry and conflicting draft rejection, child/stale ownership, structural privacy, crash/reopen and repeat drain. Offline append/spool took 13.6 ms in this run.
- **Real UI**: [report](journal-ui/report.json), 10.219 seconds on the clean committed-head build `e764720703889d0f962c5e84f4fc944412d37dcb` (the earlier product-source run also passed in 12.105 seconds). Journal-only attention enables the actual Jump menu without routine unread; actual key/menu navigation selects it; seeing does not resolve it; suppression excludes routine waiting and a flag retains precedence. A forced restart exposes Unconfirmed in actual accessibility help. Synthesized dismissal and readable one-area topology passed.
- **Compatibility**: packaged CLI transport/authentication checks, mailbox hook drain checks, five bounded transcript tests, and the OpenCode lifecycle test passed during implementation. They were not repeated as full suites after test-only edits.

The UI run uses an ordinary per-tag user shortcut binding for Option-V to exercise the spec's named gesture. The current shipped default is Control-Command-Return. Screenshots have neutral prompts and are cropped to the app/menu. No tenant tool configuration was written.

## Performance and remaining work

The required short comparison remains **INCOMPLETE**, not PASS. One final baseline/candidate pair ran on the same guest with the same probe and initial window geometry. Both passed all 30 calibration trials and completed their packaged hooks, then failed the requirement that at least 95% of 120 glyphs match within 500 ms. The capture failure exists on the main baseline as well as the candidate. This establishes neither a candidate latency regression nor acceptable latency.

| Recorded quantity | Main baseline `43529df178` | Candidate `e764720703` |
|---|---:|---:|
| Unmatched glyphs / 120 | 103 | 109 |
| p95/p99 of matched subset only, ms (invalid comparison) | 193.85 / 193.85 | 96.83 / 96.83 |
| Capture p95, ms | 34.02 | 37.02 |
| Packaged hooks completed | 176 | 263 |
| Hook process p95, ms | 456.08 | 350.03 |
| Duration, seconds | 73.37 | 75.77 |
| Sampled app CPU peak, percent | 82.6 | 88.5 |
| Sampled RSS peak, MiB | 306.00 | 286.41 |
| Physical footprint peak, MiB | 377.75 | 369.54 |
| Host load before run, 1/5/15 min | 3.73 / 5.33 / 7.96 | 6.00 / 5.77 / 7.71 |
| Guest load after run, 1/5/15 min | 3.50 / 11.96 / 8.09 | 2.90 / 8.32 / 7.22 |

Raw samples and check lists: [baseline](perf-baseline.json), [candidate](perf-candidate.json). The serial producer loop targets at most 10 hooks/second but achieved different lower rates; this is not a fixed-rate stress comparison. The matched-subset percentiles must not be used as performance evidence. Both reports also record `cleanup_ok: false`; the owning guest was subsequently stopped and deleted successfully, independently of probe cleanup.

The first failed captures show a dimmed app window while retaining the glyph: [baseline capture](perf-baseline-first-miss.png), [candidate capture](perf-candidate-first-miss.png). A read-only foreground check during the candidate run still identified the exact tagged process. The reason for the RGB template mismatch is not established. The next small validation task is to diagnose window key/focus and captured pixel stability across the hook burst, then run one valid matched pair. Further exploratory reruns stopped under the run's capacity instruction.

The pre-registered C11-270 thresholds remain p95 `max(baseline * 1.20, baseline + 5 ms)`, p99 `max(baseline * 1.25, baseline + 15 ms)`, and peak footprint `max(baseline * 1.25, baseline + 2048 MiB)`. More than 5% unmatched glyphs invalidates measurement. No threshold was relaxed. This short run cannot establish a fleet-soak memory slope or main-thread stall distribution.

The final clean Debug build passed with no overlay; see [final-build.json](final-build.json), invocation `7e81965b42794cd18775c4215c280a46`. Core runtime and actual key/menu UI checks pass. The remaining performance gate prevents a review-ready claim: no draft PR or HANDOFF has been sent. Fable review remains orchestrator-owned. Only evidence files changed after that build. The UI restart evidence is a window capture plus accessibility help; restored window bounds were not normalized, so it is state proof, not a restore-geometry gate.

Cleanup: both completed tag caches and their remote DerivedData directories were removed. The final guest was deleted after the bounded run, within its lease. Retained public evidence contains no account names, home paths or session identifiers.

## Validator scenario

1. Build a tagged Debug app from the reviewed commit, start it fresh in a disposable guest, and run the three runtime scripts named above. All must pass; retain separate build and assertion outcomes.
2. In the tagged domain bind Jump to Option-V before launch, then run `journal_ui_probe.py` with its exact app, CLI, socket and process. Use one verified display and a fully visible main window. Expect journal-only Jump, suppression/flag precedence, persistent blocked state after seeing, and Unconfirmed after force-kill/resume. Expect `cleanup_ok: true` and inspect the cropped screenshots.
3. Run the same `journal_perf_probe.py` on a tagged main baseline and candidate under matching geometry and load. Retain calibration/miss counts and compare only valid samples using the registered thresholds. Report short-run scope separately from the deferred fleet soak.
4. Delete the run's guest and tag caches after retaining sanitized evidence. The merge owner syncs installed skill copies from merged main.
