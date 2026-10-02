# C11-303 round 1 repair evidence

Candidate: `cc53a0d392e5a49f59866768d3683783dcef4326`.
PR: https://github.com/Stage-11-Agentics/c11/pull/543 (draft; no merge or release).

## Honest oracle

Every actual `flushWorkspaceWindowLayouts()` entry emits a DEBUG-only
`ws.layoutFollowUp.flush` record, with workspace ID, monotonic workspace count,
window count, flush duration and initiating reason. The deferred logger runs
on all returns, including immediate convergence. The older nonconverged-attempt
log is not used as the flush counter. Release contains neither the counter nor
the duration formatting/logging.

## Exact-head gates

- Atlas host tests, invocation `dccc6c4771964ca8b1d6a9defa0ec29a`: 7 tests,
  0 failures, 4.540 seconds. Real deferred begin does not flush synchronously;
  immediate convergence is counted; detached unusable geometry retries and
  expires; attachment with usable bounds converges before expiry; clear/rearm
  rejects the stale attempt; three existing background/owner focus tests pass.
- Atlas Debug build, invocation `9a73b0aa03484cdb9dee17a41f344ecd`: passed.
  Identity reports this exact head, clean tree, no overlay, tag `c11-303`.
- Earlier production-scheduler logic gate at ancestor `8213e118`: 2,377 tests,
  3 skips, 0 failures, invocation `5163fc2c547349edacbaef75d5b40674`.
  WorkspaceRemoteConnectionTests was not skipped; only SSH-incompatible
  SocketControlPasswordStoreTests was excluded. Repair adds DEBUG diagnostics
  and host fixtures, not another production scheduling change.

## Paired runtime method

Baseline `4f0366a84a54f0ffb8cfa19a2070fc08b2e5f9d4` is frozen main
`1e7d47ae70bbd1a7ae5868ad4c257d3eef1ceb5f` plus the identical DEBUG flush
oracle only. Baseline Debug invocation `443a1bb2e7b14c198ebcfa3aaa2dab9b` passed.
Candidate and baseline share this main base, Ghostty and Bonsplit revisions.
Both use tag `c11-303`, sequential disposable Atlas guests, and identical
synthetic six-window scenes. No Hyperion UI or operator session is driven.

Both successful runs used a fresh c11 process after first-launch preflight,
six real windows and up to 27 synthetic terminals, plus the browser tab added in the
mixed-layout phase. Every measured flush reports `windows=7` (six document
windows plus c11's auxiliary window). Setup Assistant and failed harness
preflights are excluded. In particular, an earlier duplicated scene retained
closed NSWindows and was discarded rather than compared with this candidate.
The native executable hashes inside the guests match their Atlas manifests:

- Baseline: `937f8ad1c348df0f6f9e095efa2fe12dc7a7b0159f1648e237496e0fe7cacbcb`.
- Candidate: `9d08eb4b483b617df7d0bbbdf69d897e8ed070cf963ed7d7c5b315848fdffc9d`.

Atlas host load averages (1/5/15 minutes): baseline `24.24/34.41/28.76`;
candidate `19.43/22.52/24.66`. Guest loads: baseline `11.38/17.52/13.07`;
candidate `18.19/17.68/8.09`. This is one preliminary paired sample, not a
controlled claim about the fleet latency distribution.

## Complete flush measurements

Each tuple below is **count / total milliseconds / maximum milliseconds**,
from the new actual-flush records, including successful attempts.

| Same workload phase | Baseline | Candidate |
| --- | --- | --- |
| Settled wheel-scroll up, 120 events | 0 / 0 / 0 | 0 / 0 / 0 |
| Four real window resizes, 120 scroll events, typing in other pane | 9 / 1.916 / 0.347 | 3 / 39.885 / 19.398 |
| New split while a concurrent 150-event scroll is running | 4 / 405.740 / 378.202 | 2 / 0.241 / 0.143 |
| Quartz divider drag, 30 motion events, then settlement | 47 / 25.693 / 15.652 | 5 / 74.753 / 18.133 |
| Mixed browser insertion, terminal zoom/unzoom, workspace next/previous | 14 / 655.202 / 413.580 | 18 / 13.916 / 8.197 |
| Final settled wheel-scroll to bottom, 150 events | 0 / 0 / 0 | 0 / 0 / 0 |
| Actual scrollbar knob dragged to top and back to bottom | 0 / 0 / 0 | 0 / 0 / 0 |
| Six core phases combined | 74 / 1088.551 / 413.580 | 28 / 128.795 / 19.398 |

The resize and divider phases are structural changes, not pure-scroll counts.
The bounded retry adds legitimate attempts in the mixed switch phase (18
instead of 14); it does not aim to eliminate repair work. Pure settled scroll
already measures zero on the baseline too. Do not reinterpret that equality
as a reproduced baseline scroll storm or a universal performance claim.

## Pending work, expiry and final UI

The candidate's actual mixed-switch log shows stalled geometry retries at
`17:50:11.647`, `.662`, `.686`, `.732`, `.814`, `.982`, and
`17:50:12.256`, with `stalled=1...7`, rather than AppKit update-paced
immediate retries. The retained log continues through the bounded episode;
the final settled scrolling then records zero flushes. Host fixtures provide
the controlled unavailable-bound expiry and subsequent no-flush assertion,
delayed attachment before expiry, and clear/rearm fencing. The deferred-begin
fixture checks that the flush count does not change until its main callback
yields. These are executable runtime checks, not source-pattern tests.

Inspected guest screenshots show the tagged app menu, the red DEV footer,
the explicit `C11-303-candidate` window title, and the synthetic scene:

1. `candidate-scrolled-up.png`: wheel input changes the rendered viewport
   into the middle of the numbered fixture, rather than injecting shell text.
2. `candidate-divider-settled.png`: the real divider drag changes the left
   area from 387 to 424.55 logical pixels. After zoom/unzoom and workspace
   switching, the final layout retains that boundary, about 55%/45%.
3. `candidate-browser-zoom.png`: despite the historical filename, this is
   **the focused terminal zoomed in the mixed terminal/browser workspace**,
   not a browser-zoom claim. `candidate-mixed-switch-settled.png` shows the
   restored three-area terminal/browser layout.
4. `candidate-final-bottom.png`: final wheel scrolling renders fixture line
   0600 and the shell prompt. All four typed output markers, 010/040/070/100,
   remain visible in the separate upper-right terminal.
5. `candidate-scrollbar-top.png` and `candidate-scrollbar-bottom.png`: actual
   Quartz knob drags render line 0001 at the top and line 0600 plus the prompt
   at the bottom. Socket text snapshots independently match the screenshots.

The final snapshot has all three selected views attached, visible and with
usable bounds: left terminal `424×610`, upper-right terminal `349×289.5`,
browser `349×255.5` logical pixels. The terminal header/divider spacing
accounts for their differing area and terminal-view heights. Screenshots were
taken before the final layout snapshot, so its diagnostic layout pass is not
the sole convergence proof. `tree --all --no-layout` is retained; the main
three areas are readable, not placeholder-sized. Both owned guests were
deleted immediately after each run; no Hyperion UI was used.

## Typing and responsiveness: measured limits

Four Quartz-typed commands execute in the non-scrolling terminal during the
resize/scroll phase. Output-line observation latencies (ms): baseline
`298,270,270,272`; candidate `311,367,319,283`. These include spawning the
read-screen CLI and observing shell output, and are not key-to-pixel latency.
The four observations are too small a sample for fleet p95/p99 sign-off.

An independent persistent socket probe asks for terminal focus every 10 ms;
that handler takes a synchronous main-thread snapshot. During resize/scroll
and typing its p50/p95/p99 response times were `0.47/6.74/38.04` ms baseline
and `1.76/29.56/71.30` ms candidate (nearest-rank quantiles); maxima were `77.35` and `126.58` ms.
No multi-hundred-ms responsiveness gap was observed in that typing phase.
This measures sampled main-thread responsiveness, not every main-thread task.

**Do not claim that all structural main-thread stalls are gone.** Split
responsiveness maxima were `400.00` ms baseline and `426.74` ms candidate;
mixed zoom/switch maxima were `511.45` and `666.73` ms. Candidate all-window
flush maxima in those same phases were only `0.143` and `8.197` ms, so these
response gaps are not time spent inside the measured all-window flush. Their
precise remaining stack/cause is not established by this probe. Divider
response maxima were `390.61` and `187.99` ms. Settled scroll-up maxima were
`8.42` and `25.65` ms; final-scroll maxima `6.43` and `132.14` ms. The raw
samples and all complete flush records are retained, including the outliers.
No borrowed upstream 254–512 ms number is represented as a c11 measurement.

## Repeatable validation scenario

1. Use the retained exact-head tagged app in an isolated Atlas guest, within
   the two-slot reservation rules. Begin with one fresh-process window.
2. Run the attached `guest-scenario.py` with run ID and variant. It creates a
   `/tmp` workspace, seeds 600 numbered lines, splits a typing pane and opens
   five additional windows. It refuses input unless the target PID is frontmost
   and sets a 20-minute self-termination timer for that app.
3. It posts real Quartz wheel, keyboard and divider input, plus PID-scoped
   window resize and Area/Workspace menu actions. The socket supplies scene
   setup and text/layout oracles, not the measured input gestures.
4. After the six phases, run the script's shared prelude plus
   `scrollbar-tail.py` for the two actual knob drags. Expect the fixture's
   first/final lines, zero settled follow-up flushes, readable settled bounds
   and the four typed output markers. Retrieve screenshots/logs and delete
   the guest immediately. No tagged app is opened on Hyperion.

## Sign-off boundary

C11-302's scrollbar-drag residual under ongoing output remains a separate
sign-off item. Static-fixture scrollbar correctness or wheel scrolling does
not sign off that streaming residual. This is a short paired sample, not the
deferred C11-270 fleet soak or its population p95/p99 budget.
