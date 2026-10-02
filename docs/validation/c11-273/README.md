# C11-273 validation checkpoint

Implementation is pushed on `c11-1.0/C11-273-journal`. This checkpoint is not a performance PASS or a review handoff.

## Artifact and scope

The tagged Debug artifact has product source commit `52056252f3f30b3bf42af24fd1c69b5ab724bf0c`, based on main `43529df178a9cd8817fc092896efd2f3fcd63df5`, including C11-263 `6926fa05cf`. Build invocation `29e130da722a4f2081c0c873eac23944` succeeded. Its declared overlay contains test/probe files only; the sanitized build manifest is [runtime-build.json](runtime-build.json). Later commits through `e764720703` change tests and probes only. The executable hash in the manifest distinguishes the remote build from the retrieved, path-adjusted signed artifact used in the guest.

All packaged-app execution used a disposable guest, a tagged app, an explicit isolated socket and QA fresh/resume. The real hooks, socket, SQLite files, spool, terminal and UI were exercised. Provider inputs were synthetic structural events except the explicitly recorded C11-271 hook shape. This does not claim a live provider end-to-end run or unsupported interrupt coverage.

## Passed checks

- **25 journal logic tests**: reducer 9, store 11, spool 5; invocation `60875ef7f7a5431e8e4fd905577fd8e7`. Actual test action passed, including reopening the database and folding multiple historical events after the process changes. Prior targeted liveness/journal gate passed 45 tests before that additional store test. Four workspace-constructing liveness tests were excluded for the known no-host NSApp limitation. The two run-wide test exclusions were also applied.
- **Three guest runtime scripts**: `test_journal_append_replay.py`, `test_journal_restart.py`, and the unchanged `test_claude_attention_batch.py` passed. See [runtime-checks.txt](runtime-checks.txt). They cover sibling/seen/legacy isolation, blocked persistence across Stop/late tools, terminal ordering, recorded ExitPlanMode input, lost reply retry and conflicting draft rejection, child/stale ownership, structural privacy, crash/reopen and repeat drain. Offline append/spool took 13.6 ms in this run.
- **Real UI**: [report](journal-ui/report.json), 12.105 seconds. Journal-only attention enables the actual Jump menu without routine unread; actual key/menu navigation selects it; seeing does not resolve it; suppression excludes routine waiting and a flag retains precedence. A forced restart exposes Unconfirmed in actual accessibility help. Synthesized dismissal and readable one-area topology passed.
- **Compatibility**: packaged CLI transport/authentication checks, mailbox hook drain checks, five bounded transcript tests, and the OpenCode lifecycle test passed during implementation. They were not repeated as full suites after test-only edits.

The UI run uses an ordinary per-tag user shortcut binding for Option-V to exercise the spec's named gesture. The current shipped default is Control-Command-Return. Screenshots have neutral prompts and are cropped to the app/menu. No tenant tool configuration was written.

## Performance and remaining work

The required short matched comparison is **incomplete**. An early baseline probe failed glyph matching under hook traffic; it provides no valid candidate-versus-baseline latency conclusion. A later setup attempt found no window after launching the baseline; the runner now explicitly creates a window when needed. Failed samples are not represented as zero latency or a pass. The prior guest was deleted at the lease boundary.

The bounded final comparison uses the same 120 real key-to-glyph trials, eight structural hook producers, geometry and capture method on both artifacts. It records p95/p99, capture overhead, hook timing, CPU, RSS, physical footprint and host/guest load. The pre-registered C11-270 comparison thresholds are p95 `max(baseline * 1.20, baseline + 5 ms)`, p99 `max(baseline * 1.25, baseline + 15 ms)`, and peak footprint `max(baseline * 1.25, baseline + 2048 MiB)`. More than 5% unmatched glyphs invalidates the measurement. This short run cannot establish a fleet-soak memory slope or main-thread stall distribution.

A final committed-head Debug build, bounded comparison, durable results, draft PR and orchestrator-owned Fable review remain. No PR has been opened and no merge is authorized for this owner.

## Validator scenario

1. Build a tagged Debug app from the reviewed commit, start it fresh in a disposable guest, and run the three runtime scripts named above. All must pass; retain separate build and assertion outcomes.
2. In the tagged domain bind Jump to Option-V before launch, then run `journal_ui_probe.py` with its exact app, CLI, socket and process. Use one verified display and a fully visible main window. Expect journal-only Jump, suppression/flag precedence, persistent blocked state after seeing, and Unconfirmed after force-kill/resume. Expect `cleanup_ok: true` and inspect the cropped screenshots.
3. Run the same `journal_perf_probe.py` on a tagged main baseline and candidate under matching geometry and load. Retain calibration/miss counts and compare only valid samples using the registered thresholds. Report short-run scope separately from the deferred fleet soak.
4. Delete the run's guest and tag caches after retaining sanitized evidence. The merge owner syncs installed skill copies from merged main.
