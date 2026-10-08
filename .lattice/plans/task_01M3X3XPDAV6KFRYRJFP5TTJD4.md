# C11-270 plan

Design and pre-register the 40-agent fleet soak. Execution waits for build mode and a tagged Atlas app from C11-216. Auth is settled: subscription, with no API keys. No product source changes in this ticket.

Protocol and budgets: `docs/soak/C11-270-harness.md`. Build mode must align `scripts/soak/` to `soak-budgets-3`, `soak-workload-2` before M1. All numeric deltas and the 3h/10h/2.5h durations remain fixed; the new versions bind corrected observation and coverage. The inherited scripts still implement versions 2/1 and are not ready for a live gate. The earlier 12h/72h wording is superseded by the recorded run decision.

## Architecture

An out-of-process Python driver on Atlas launches one tagged c11, builds a flat layout of 51 workspaces (1 probe shell, 10 idle shells, 40 real CLIs), and walks one timeline. `driver.py run` exits 2 on any ComputerName that contains Hyperion.

- `schedule.py` is the timeline. Baseline is the first 3h. The candidate is the overnight run and is complete at 10h. Constrained keeps the first 2.5h. Restarts at 30 min, 3h, and 7h, each included only when it falls strictly inside the role. The 3h baseline therefore keeps `restart-30m` only. The candidate keeps all three.
- `atlas_transport.py` calls `scripts/launch-tagged-automation.sh` with `--qa fresh` or `--qa resume`, `C11_TAG`, and a fresh run-owned `C11_HANG_LOG`. Socket `/tmp/c11-debug-<slug>.sock`. CLI is the tagged `Contents/Resources/bin/c11`; `Contents/MacOS/c11` identifies the GUI process only. Quit targets that bundle id and verified GUI PID only. Parse the complete CLI stdout JSON document, not the last line beginning with `{`.
- `probe.py` is **glyph-present**: `CGWindowListCreateImage` of the soak window, `CGEventPostToPid` for a key (terminal-input), a scroll (sidebar-body), or a sidebar click (switch-present). A trial counts only when a bounded region shows the expected input glyph or the expected selected-workspace result. The region excludes the cursor, the title, and unrelated output. The first changed frame is not a sample. Timeouts stay errors. The current script still accepts any changed crop; build mode aligns it. No second capture implementation.
- `hanglog.py` parses `hang.begin` / `hang.end`, preserving each recapture stack separately and pairing by GUI PID. Collect the run-owned current log and its rotations, plus events for every restart PID. `samples.py` reads `footprint -j`; retain raw samples. A missing IOSurface category stays null.
- `gate.py` scores coverage, then deltas. Statuses: `registered`, `pass`, `fail`, `incomplete`, `interrupted`, `killed`.

## Files

New, no product edits:

- `scripts/soak/budgets.py`, `workload.py`, `cost.py`, `schedule.py`
- `scripts/soak/hanglog.py`, `samples.py`, `gate.py`, `probe.py`
- `scripts/soak/driver.py`, `atlas_transport.py`, `test_soak.py`, `README.md`
- `docs/soak/C11-270-harness.md`, `docs/soak/C11-270-plan.md`

## Milestones

One ticket. Astra whole-plan audit, must-fix 4. Publishing M1 does not complete C11-270.

- **M1 — budgets and baseline published.** `soak-budgets-3` and the 3h baseline JSON on the then-current main SHA. Coverage status `registered`. The JSON includes flat-51 and a collected g60 control. M1 gates wave 1 → wave 2. C11-259, C11-260, and C11-261 take it for their groups proof. C11-262, C11-294, C11-295, C11-302, and C11-303 take it where they wait on this ticket for a baseline. They do not wait for M2.
- **M2 — final candidate passed.** The 10h overnight candidate classified against that baseline, and the 2.5h constrained run. M2 gates release. The candidate can include what those consumers land after M1. Incomplete is not M2.

**g60.** The baseline registers and collects a 60-workspace grouped-capable control, not only flat-51. Population, tab types, and pins match C11-261 fixture `g60-v1`. This SHA has no group command, so the control is ungrouped. It is collected in the baseline's reserved window, before any candidate measurement, and it does not replace the 3h flat-51 fleet. Same probe, same budgets. C11-261's baseline half is this control: no-churn, then workspace reorder at 10 per second for 60 seconds. Missing g60 samples means M1 is not published.

**Windows.** The baseline, the candidate, and the constrained run each have a reserved Atlas window. During a window there is no other Atlas build and no other UI driver. A shared window is incomplete. This is a reservation, not a new lock.

## Build-mode corrections required before M1

These are static takeover findings, not executed failures. Implement in the existing files above; no Swift changes.

1. **Real launch and lifecycle evidence (F2 fleet fixture).** Fix `driver.launch_paths` and `SystemTransport._cli/expand/_last_json/sample`. The bundled CLI path is established by `AppDelegate.swift:1527-1535` and `scripts/reload.sh:460`; `CLI/c11.swift:5370-5380,15032-15035` emits pretty-printed JSON. Record UUIDs and TTYs at launch, then batch `ps` on those TTYs every 60s to count live provider processes, rather than `len(self.agents)`. Use the existing TTY query (`TerminalController.swift:2259`) and process approach (`AgentDetector.swift:219-249`), not full argv or provider transcripts. Verify each CLI can complete the initial synthetic turn and one follow-up before the role clock starts; later record only response observed/timeout and timestamps for the known synthetic replies. Successful `send` means submitted, not completed. Count completion timeouts in the existing 10% turn-failure budget. After restart, re-resolve the saved UUIDs and TTYs before sends and prove sessions resume; stale/missing tabs remain failures. Test multiline launch JSON, an exited CLI behind a retained ref, a send that succeeds without a reply, and restore with changed short refs. Atlas proof: all three providers answer two turns, population curves reflect an intentionally stopped synthetic slot, then restore returns the mixed fleet.

2. **Calibrated input and bounded display (audit finding 4).** Fix `probe.measure_once` and `SystemTransport.probe/_post_*`. Resolve the actual window/display and visible row rectangles, not a 220px sidebar or 40 rows at assumed 28px pitch. Select and focus the dedicated probe shell by captured UUID before terminal trials; storms leave a different workspace selected. Use a stable synthetic line and expected-glyph region, excluding the cursor/title; switch/scroll trials require the intended row/selection result. Re-establish probe focus after switching. Test unrelated repaint, glyph timeout, wrong selection, and an intended frame after the 500ms deadline. Calibrate 30 successful trials before the clock starts, record capture overhead/display scale/refresh, and retain screenshots of expected results and dismissal. A separate watchdog terminates at the role deadline plus 120s even if a CLI, capture or footprint subprocess stalls; subprocesses have timeouts. SIGTERM and exceptions write an atomic partial `interrupted`/`incomplete` artifact and quit only the tagged GUI. Demonstrate dismissal with synthesized input during preflight, then assert the tagged PID/window is gone at finish. No Hyperion input.

3. **Matched g60 phases (audit finding 4; C11-261 AC5).** Add the control to `schedule.py`, transport and gate. Before the fleet clock, provision the C11-261 `g60-v1` population in a separate chapter of the same tagged app/window: w01-w60, browser tabs at w04/w33, markdown at w05/w34, the specified idle terminal tabs, and pins w01/w02/w29-w32. Baseline has no folders. Preserve fixture composition explicitly; do not invent the unlanded group commands. Collect no-churn, 60s of workspace reorder at 10/s, then 60s quiescence. Each phase has four 30-trial terminal bursts, two 30-trial sidebar bursts, and two 30-trial switching bursts; no-churn lasts 60s too. If the bursts cannot finish inside the phase, mark that phase incomplete. Store phase names, mutation rate/count, probe trials, memory snapshots and hang interval. Restore the flat-51 chapter afterward. Candidate repeats this control with the same tabs/pins and C11-261's six-folder state (two empty) after C11-259/260 land. g60 has its own fixture version and grouping field, while workload/probe versions match. Gate paired terminal/sidebar/switch p95/p99 by phase using the unchanged deltas; minimum 100/40/40 valid samples per phase. Short-phase memory/hangs remain descriptive, since the fleet's slope needs 30 points. Test missing control/phase, mismatched fixture and a g60-only regression. Grouped pointer-drag is C11-261's descriptive proof, not a new paired budget. M1 cannot publish without g60, and M2 cannot skip its grouped comparison.

4. **Coverage and artifact provenance (F2 AC1-4).** Fix `driver.main/execute`, `gate.coverage/evaluate` and `samples.py`. The report must bind the C11-216 artifact/build manifest, source SHA, GUI/CLI hashes, app and provider versions, model/effort mix, host/display, budget/workload/probe/fixture versions, and reserved-window attestation. A user-supplied `--sha`, hard-coded `screen_unlocked/display_ok`, saved refs or elapsed time including shutdown are not proof. Require observed 40-slot mix (14/13/13), live-population samples, the control/calibration, scheduled stimuli, and every prescribed restart from `schedule.restart_ids(role)`, not a requirement list supplied by the run JSON. Check first/last as well as interior memory gaps within the post-expansion measurement interval, >=30 usable points per scored slope, and all registered latency sample floors. Clock ends at role deadline before cleanup; unexpected app death is recorded. Verify lock/display conditions through the run and record invalid intervals. Candidate comparison rejects changed provider/model mix, versions, host/display or capture protocol. The constrained role is the explicit host/RAM exception: reuse the candidate artifact and model mix, report host/display differences and evaluate the same numeric budgets, while labeling its comparison cross-host and its GPU evidence non-physical for a VM. It never substitutes for the matched overnight verdict. `classify` must expose baseline registration and return a nonzero exit for failure/incomplete/interrupted/killed; only registered-baseline or candidate pass is success. Test forged restart lists, an empty/late-ending sample series, a wrong artifact identity, lost display, killed GUI and interrupted output. Atlas proof uses the retained manifest/raw curves, not an owner assertion.

5. **C11-310 attribution (B059).** Fix `hanglog.py` and `gate.top_swift_frame/is_sidebar_body/_sidebar_verdict`. A generic `tabTitleBarState`/`attentionSnapshot`/`unreadCount` symbol is used elsewhere and does not identify its caller. Conviction requires the longest episode contributing to a registered hang-budget miss to have a top Swift frame in `WorkspaceSidebar.body`, or one of its reads with that body present in the *same capture stack*. Keep begin/recapture stacks separate; do not combine unrelated frames. Resolve the target's own executable/debug-dylib modules and demangle Swift symbols off-process before attribution. Unknown/symbolication-missing stacks make the attribution unverified and cannot close C11-310 as not convicted. A constrained run cannot substitute for the exact overnight candidate verdict. Test a helper called outside the sidebar, a row frame, separate captures that would falsely combine, a symbolicated DEBUG frame, and unknown symbols. Real Atlas evidence remains required. No conditional snapshot or ride-along implementation is admitted now; if convicted, send the artifact to the Orchestrator for that separately gated scope.

6. **Constrained host (F2 AC4).** The inherited `execution_allowed` accepts Atlas names only, so `--constraint vm_ram_16gb` on Atlas does not create a constraint. In build mode, obtain the Orchestrator's designated Atlas-hosted macOS guest or physical 16 GB host, record actual RAM/guest configuration, prove its display and terminal renderer work, and transfer the same tagged artifact through the C11-216 route. Keep Hyperion refused; host admission is an explicit manifest, never a `SOAK_HOST` bypass. Missing provisioned host/usable rendering leaves AC4 incomplete and prompts BLOCKED to the Orchestrator. No Atlas preparation by this seat. A 16 GB guest remains non-physical GPU evidence.

## Acceptance criteria

1. **M1, baseline before any candidate.** Wave-1 run is `driver.py run baseline` for 3h on the then-current main SHA, plus the g60 control in that same window. It gates wave 1 to wave 2. Budgets are `soak-budgets-3`. The run's own status must be `registered` from `gate.coverage`, and the JSON must contain the g60 samples. Incident answered: short green tests cannot show memory or typing drift (F2, Astra example 6). Proof: the published JSON. Do not mark the ticket done. Atlas computer-use: the calibration burst shows the expected glyph in the bounded region, on a verified display, and the driver quits the tagged app at the end.

2. **M2, overnight mixed fleet.** `run candidate` for 10h with 14 Claude, 13 Codex, 13 Grok, the storms, and restarts at 30 min, 3h, and 7h. The seat brief and BACKLOG F2 call this an overnight run. The ticket's 72h sentence is superseded. A shorter run is `incomplete`. Population median below 38, turn failures over 10%, or a memory gap over 300s is `incomplete`. Incident: fleet hangs and restart loss (C11-197/202/205, the stress test at `tests_v2/test_socket_reliability_stress.py:105` which only creates surfaces). Proof: candidate JSON's `wall_hours`, `agents` (40, three types), `restarts_done`, and a `pass` or `fail` from `classify`. Not a pass on a partial file. This milestone gates release.

3. **The report is the gate.** `classify` emits hang failures, footprint slope and peak, IOSurface slope, glyph-present p95/p99, and switch-present p95/p99. A sample is the expected glyph or the expected selected workspace in the bounded region. Missing any of those is a failure or incomplete, not a silent skip. Proof: `test_soak.py` traces for each branch, then the Atlas JSON.

4. **16 GB run.** `run constrained --constraint vm_ram_16gb` or `physical_16gb`, same workload, 2.5h, including `restart-30m`. The JSON names the constraint. A VM kill is `killed` and is not physical GPU evidence. A physical kill is `fail`. Proof: the constraint field and the classify status. The constellation Macs are 128 GB, so the default host is a 16 GB RAM VM.

5. **D21 / D22 evidence only.** The JSON carries `d21_followup` and `d22`. Growth past 1 GiB with a rising last quarter, a sidebar hang frame, or a flat-51 vs control-1 typing miss sets the flag. The harness does not edit `ContentView.swift` or the occlusion path. Proof: the flags in the classify output, and a diff that does not touch those files.

6. **C11-310's measurement, same artifact.** `classify` adds `sidebar_verdict`: `measured`, `attribution_verified`, `convicted`, `budget`, `budgets`, `frame`, `body`. Conviction requires the same-stack attribution in correction 5, not a helper name alone. Incomplete coverage, a constrained-only run, or missing relevant symbols cannot produce a not-convicted close. M1 alone is not a verdict. Incident: B059 is a pattern with no stack yet (Fable §9 item 8; the trusted stacks are the 2026-08-25 teardown join and the 2026-08-12 browser pump). Proof: the named behavioral traces, then exact-candidate Atlas frames. No Swift diff.

## Hot path and threading

No edits to `hitTest`, `forceRefresh`, `WorkspaceRowView`, or socket dispatch. glyph-present runs out of process. `footprint` runs out of process every 60s. Hang capture stays on the existing watchdog thread. The driver's CLI calls are the prescribed launches, pings, and storms, not a poll. Consumers measure glyph-present `terminal-input` on flat-51 and on the g60 control published at M1.

## Strings, persistence, submodules

No new `String(localized:)` keys. No migration. No submodule bump. Logs stay in `/tmp` and the run directory. No tenant config writes. Prompts in `workload.py` are the synthetic sentences above. No account emails, no session ids, no transcripts in the ticket.

## Cut line

Sidebar rewrite, the C11-310 snapshot, and ride-alongs B001, B029, B043, B060, and B188. Those start only after `sidebar_verdict.convicted` is true, which this plan does not assume. Also out: GPU reclaim, hang bug fixes, PTY bug fixes, release publishing, groups implementation, journal work, and any fleet on Hyperion. Hang findings are comments that name C11-197, C11-202, C11-205. PTY findings name C11-130, C11-169, C11-235. This ticket does not patch them. There is no separate C11-310 plan.

## Dependencies

C11-216 must produce the tagged Atlas app before M1. M1 does not wait for groups or for the integrated candidate. C11-259, C11-260, and C11-261 consume M1, including g60. C11-262, C11-294, C11-295, C11-302, and C11-303 consume M1 for a baseline. Release consumes M2. None of those tickets block this plan, and this ticket stays open after M1.

## Corrections to the ticket's citations

Verified on `0ff8887e5e`:

- Detector default is `stallThresholdMs: 2000` at `MainThreadHangMonitor.swift:248`. The 2s comment is at `:331`. The 32 MiB cap is `logCapBytes` at `:375`.
- Occlusion is `setOcclusion` at `GhosttyTerminalView.swift:3929`, not `:3925`.
- The sidebar body walk is `WorkspaceSidebar.body` at `ContentView.swift:8535-8640`. The call is `tabTitleBarState`, not `surfaceTitleBarState`. `VerticalTabsSidebar` remains only in comments.
- `test_socket_reliability_stress.py:105` is `test_no_cli_hangs_under_rapid_surface_creation`.

## Inherited validation claim; not rerun at takeover

The prior owner reported `python3 -m unittest test_soak.py` in `scripts/soak`. The existing tests exercise synthetic schedule, parsing and gate cases, including first-changed-crop behavior and absence of groups. They do not prove the corrected expected-result oracle, g60, real CLI transport, live population or tagged runtime. No tests, builds, runs or pushes were performed by the Codex takeover in planning mode. Implement the corrections and run their behavioral tests on Atlas in build mode before M1.

Atlas still has to run the tagged fleet, the calibration burst, and `classify` on the real JSON. That is the runtime proof, in build mode.

## Auth

Atin chose subscription. It is the default and the only planned mode for the baseline, the overnight candidate, and the constrained run. `driver.py run` uses it when `--auth` is omitted. The launch drops `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and `XAI_API_KEY` if they were inherited. The CLIs use the call-sign already logged in on Atlas, at about 100 short turns an hour. No API key is required. Nothing is written under `~/.claude`, `~/.codex`, or `~/.grok`.

The `api` branch remains in `auth_environ`. The plan does not use it.

## Cost

Nominal capacity estimate: about 100 short turns, 300k input tokens and 5k output tokens per fleet hour (3k/50 per turn). This is not a measured upper bound on a CLI's full context. The baseline, candidate and constrained run total 15.5h plus preflight/g60; one candidate retry totals 25.5h plus that overhead. Record model versions and numeric usage where the CLI exposes it without saving transcripts. Atin chose subscription and explicitly removed usage management as a launch blocker; the inherited dollar/model-price ceilings are not admission gates. Keep the existing 3x turn-rate abort to catch a runaway driver. Propose fixture Haiku/low for Claude and the cheapest subscription model on each installed Codex/Grok CLI that successfully completes the two-turn preflight; lock that exact mix before M1 and reuse it. A fixture slug proves syntax history, not current account availability. No API keys and no new model-price claims.

## Reset 2026-10-03 by agent:orchestrator-c11-1.0
