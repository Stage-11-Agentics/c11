# C11-270 fleet soak

Pre-registered protocol for the 1.0 gate. Planned budgets version `soak-budgets-3`.
Planned workload version `soak-workload-2`. The inherited scripts still use
versions 2/1. Build mode must align them with this protocol and the six concrete
corrections in `C11-270-plan.md` before M1; they are not ready for a live gate.
A candidate is scored only against a baseline
that used these versions. The deltas below are the budgets. They are fixed
before any candidate is measured. The baseline records the absolute
distributions. It does not invent a new threshold afterward.

This harness does not change product code. Sampling runs in another
process. The one on-main touch is the app's own CLI, and only at the
prescribed events (launch, a ping every 30 minutes, a storm).

## Where it runs

Fleet roles run on Atlas only. The constrained role needs an explicitly
designated Atlas-hosted macOS guest or physical 16 GB host, actual RAM evidence
and working terminal rendering. A `--constraint` label does not provision it.
Hyperion is refused even if `SOAK_HOST` is set. The tagged app comes from
C11-216. This seat does not build it or prepare Atlas.

Launch is `scripts/launch-tagged-automation.sh <tag> --qa fresh` for the
first boot and `--qa resume` for a prescribed restart. The driver adds
`C11_TAG` and a fresh run-owned `C11_HANG_LOG` under `/tmp`. The socket is
`/tmp/c11-debug-<slug>.sock`. The CLI is the tagged app's
`Contents/Resources/bin/c11` with `C11_SOCKET_PATH` set to that socket, and with
inherited `C11_*` / `CMUX_*` variables stripped so a driver shell cannot
point at another c11.

`Contents/MacOS/c11` is the GUI executable, never the CLI transport. Parse
complete pretty-printed launch JSON and retain the returned UUIDs and TTYs.
Quit is `osascript` to the tagged bundle id, then a bounded signal to the
verified GUI PID if needed. The driver never signals a generic `c11`.

`caffeinate -dimsu -w <driver pid>` is held for the run. That is a process,
not a settings write.

## First boot on Atlas

This soak validates its own isolated tagged instance on Atlas. Before the clock starts:

1. The tagged app exists at the DerivedData path `launch-tagged-automation.sh` prints.
2. The screen is unlocked. A locked screen makes `ghostty_surface_new` fail with `OutOfMemory` (C11-238). The driver stops. It does not reboot the Mac.
3. `NSScreen` reports at least one display. The run records the display count. The probe posts events only to the soak app's pid.
4. The hang log path is the explicit `C11_HANG_LOG`. `MainThreadHangMonitor.resolveLogURL` checks that variable first (`Sources/MainThreadHangMonitor.swift:785`). Retain run-owned rotations and events for every restart PID; pair hang records by PID and retain separate capture stacks.
5. A 30-trial glyph-present calibration on the probe shell must show the expected input glyph inside the bounded region. A change in the cursor, the title, or unrelated output does not count. If the expected glyph is absent, the run is incomplete and the role clock does not start.
6. Prove one initial turn and one follow-up for each provider and prove dismissal with synthesized input. A separate watchdog owns a 20-minute preflight/g60 deadline and, after the role starts, its duration plus 120s cleanup deadline. All subprocesses have timeouts; SIGTERM and exceptions atomically write partial evidence and quit the tagged app. Verify its PID/window is gone afterward.

## Workload

51 workspaces. The window's first workspace is `soak-probe`, a normal shell,
and it is the only place keys are typed. Ten `soak-idle-N` workspaces run
`cat`. Forty workspaces are real CLIs:

| Kind | Count | Model |
|---|---|---|
| claude-code | 14 | `claude-haiku-4-5-20251001`, effort `low` |
| codex | 13 | cheapest available subscription model passing the two-turn preflight |
| grok | 13 | cheapest available subscription model passing the two-turn preflight |

The proposed Claude slug comes from `c11Tests/Fixtures/agent-models/claude-session.jsonl`; it still needs live account proof. Codex and Grok are chosen on Atlas and passed as `--codex-model` and `--grok-model`. Lock the accepted model/effort mix before M1 and reuse it for comparison. The inherited price ceilings are historical estimates, not admission gates: Atin chose subscription and removed usage management as a blocker.

Each agent gets one launch prompt, then a ping every 30 minutes and a storm prompt every 3 hours:

- Ping: `Reply with the single word pong. Do not use tools. Do not read files.`
- Storm: `Reply with the single word waiting. Do not use tools. Do not read files.`

Sends go only to captured workspace/tab UUIDs, re-resolved after restart. A missing ref, exited provider or missing synthetic reply is a turn failure. CLI send success alone proves submission. Only response observed/timeout and timestamps are retained; replies and transcripts are not copied into the run directory.

There is no workspace-group command on this SHA (`CLI/c11.swift` has `new-workspace` and no group verb). The fleet layout stays `flat-51`. The baseline also collects g60: 60 workspaces, the tab types and pins of C11-261 fixture `g60-v1`, ungrouped on this SHA. That control is the grouped-capable baseline. It is taken in the same reserved window, before any candidate measurement, and it does not replace the 3h fleet. Missing g60 samples means the baseline is not published.

## Timeline

The same timeline, cut at the role duration (`scripts/soak/schedule.py`).

| Role | Duration | Restarts inside the run |
|---|---|---|
| baseline | 3h | `restart-30m` |
| candidate | 10h overnight | `restart-30m`, `restart-3h`, `restart-7h` |
| constrained | 2.5h | `restart-30m` |

- t=5 min: glyph-present `terminal-input` on `control-1` (the probe shell alone).
- t=10 min: expand to flat-51 and launch the forty agents.
- t=15 min, then every 3h: attention storm. `select-workspace` by index across all 51, then the storm prompt to captured refs.
- t=20 min, then every 30 min: terminal-input, sidebar-body, and switch-present on flat-51.
- t=30 min, then every 30 min: ping.
- Memory sample every 60s via `footprint --pid <soak> -j`.

A restart is the launch script with `--qa resume`. The shared comparison is `restart-30m` socket time.

Each role runs in a reserved Atlas window. During that window Atlas has no other build and no other UI driver. A shared window is incomplete. The reservation is not a new lock.

## Probes

**glyph-present** counts a trial when a bounded region shows the expected input glyph. Resolve the real window/display and terminal geometry, explicitly select/focus the captured probe shell, and use a stable synthetic line with an expected glyph region. Sidebar-body resolves the actual visible row rectangle and requires its intended scroll result. Cursor/title/output repaint is not a sample. The expected result must arrive within 500ms; late matches are errors too. Probe errors over 5% make the run incomplete. The script still accepts any changed crop; build mode aligns the check. Keep one capture implementation and record its overhead, display scale and refresh.

**switch-present** resolves a visible sidebar row and times its expected selection in a bounded region. It never clicks an assumed row outside the verified display. Re-establish probe-shell focus afterward. Cursor/title/output changes do not count. The storm's model-side switches are not scored click latencies.

g60 uses the same probe and budgets. Before the fleet clock, collect the matched C11-261 `g60-v1` tabs/pins with no folders on baseline; the candidate uses its six folders, two empty. Three 60s phases: no-churn, workspace reorder at 10/s (candidate group/reorder mutations at the same rate), quiescence. Each phase runs four 30-trial terminal bursts and two 30-trial bursts each for sidebar and switching. Require 100/40/40 valid samples per phase and record achieved mutation count/rate. Missing/overrun phases are incomplete. Compare each phase's p95/p99 with the fleet deltas. Phase memory snapshots/hangs are descriptive; the fleet owns slopes. Restore flat-51 afterward. A pointer-drag burst remains C11-261's descriptive proof.

The control burst is 30 keys. Later bursts are 30 trials each. The floors are 100 terminal-input samples, 40 sidebar-body, 40 switch-present, and 20 control samples before a within-run D21 comparison is scored.

## Collection

| Metric | Source |
|---|---|
| Hangs | `C11_HANG_LOG`. Parser in `hanglog.py`. Headers are `hang.begin` / `hang.persist` / `hang.end` (`MainThreadHangMonitor.swift:516` and `:546`). Duration is `totalMs` on `hang.end`. An unclosed episode makes the run incomplete. |
| phys_footprint | `footprint -j`, `processes[0].auxiliary.phys_footprint`. |
| IOSurface | The footprint category whose name contains `IOSurface`: `regions` and dirty+clean+swapped+wired. A missing category is `None`, not zero. More than 10% missing makes the run incomplete. |
| Events | Retain `~/Library/Application Support/c11/events/events-<instance>.ndjson` and its rotation for every verified GUI PID (`EventLogLayout.makeInstanceId`), aligned with the run's hang interval. No unrelated production logs. |
| Population | Captured UUID/TTY mapping plus batched TTY process observations every 60s; saved refs alone are not population. Median floor 38, with the intended 40-slot 14/13/13 mix recorded. |
| Turns | Submission and synthetic completion/timeout counts. No provider reply or transcript storage. |

Warmup is one hour, or ten percent of a shorter run. Slopes need 30 points. A memory gap over 300s, including post-expansion leading/trailing gaps, is incomplete. Retain raw footprint JSON instead of deleting it. Artifact identity comes from C11-216's manifest plus GUI/CLI hashes, not only `--sha`; provider versions/model mix and host/display/capture protocol must match for the overnight comparison. The constrained run explicitly records its different host/RAM/display and uses the candidate artifact and model mix: score the same budgets but label it cross-host, without substituting for the matched overnight verdict. Screen/display flags are observed through the run. Reserved-window violations make coverage incomplete.

## Budgets

`over_budget` means the candidate is worse than both the ratio and the absolute epsilon. A 4ms baseline moving to 8ms stays inside the 5ms epsilon. A 10ms baseline moving to 20ms does not.

| Metric | Fail when |
|---|---|
| terminal-input, sidebar-body, switch-present p95 | candidate > max(baseline × 1.20, baseline + 5ms) |
| same, p99 | candidate > max(baseline × 1.25, baseline + 15ms) |
| g60 terminal-input, sidebar-body and switch-present per phase | same deltas; both runs must contain the matched fixture phases |
| watched hang, clean baseline | any episode ≥ 5000ms, or a rate of ≥2000ms episodes above 1 per 10h |
| watched hang, baseline had some | rate > max(baseline × 2, baseline + 1/10h), or max > max(baseline × 1.5, baseline + 3000ms) |
| any hang | total ≥ 30000ms, watched or not |
| footprint slope, matched window and the candidate's tail after the baseline duration | > max(baseline × 1.5, baseline + 50 MiB/h) |
| footprint peak in the matched window | > max(baseline × 1.25, baseline + 2048 MiB) |
| IOSurface count slope | > max(baseline × 1.25, baseline + 2/h) |
| restart-30m socket time | > max(baseline × 1.5, baseline + 15s) |

Matched window is the overlap of the two runs, after the same warmup. On these durations the warmup is 18 minutes (ten percent of the 3h baseline). The candidate's hours past the baseline are the tail. The tail uses the baseline slope.

Coverage, not deltas: baseline ≥ 3h, candidate ≥ 10h, constrained ≥ 2.5h, every restart from the role schedule present, live median agents ≥ 38, completion failures ≤ 10%, screen unlocked, display verified, calibration/control and g60 present, workload/budgets versions and artifact provenance exact. Exclude shutdown time from duration. A shorter run is `incomplete`; a stopped/runaway run is `interrupted`. Unexpected GUI death is recorded. `classify` exposes baseline registration and exits nonzero for failure/incomplete/interrupted/killed. None is a pass.

## D21 and D22

These flags do not by themselves fail the gate, and the harness does not rewrite the sidebar or reclaim GPU memory.

D21 follow-up is warranted when a watched hang frame names `WorkspaceSidebar`, `WorkspaceRowView`, or the stale comment name `VerticalTabsSidebar`, or flat-51 terminal-input p95 misses the typing budget against the control-1 burst, or sidebar-body p95 is more than twice flat-51 terminal-input p95. The walk is `WorkspaceSidebar.body` at `ContentView.swift:8535-8640`: every workspace, then `unreadCount`, `tabTitleBarState`, and `attentionSnapshot`. `VerticalTabsSidebar` is not a type on this SHA.

## C11-310 verdict

C11-310 asks whether a registered hang-budget miss has its top Swift frame in that body. `classify` adds `sidebar_verdict` to the gate JSON.

- `measured` is true only when a registered baseline was compared with the exact registered overnight candidate. Incomplete, interrupted, killed and constrained-only evidence cannot close C11-310.
- `convicted` requires a longest episode contributing to a registered hang-budget miss whose top Swift frame is in `WorkspaceSidebar.body`, or one of that body's reads with the body present in the same capture stack. Helper names alone do not establish the caller. Keep recaptures separate and demangle the target executable/debug-dylib symbols off-process. Missing relevant symbols leave `attribution_verified: false`; they cannot establish a not-convicted close.
- `budget` is the hang-budget line. `budgets` is every missed budget. `frame` is that top symbol, or the longest watched hang's symbol when no hang budget missed.
- A pixel miss, a `WorkspaceRowView` frame, or a memory miss does not convict. A shorter body hang does not explain a longer miss whose own top frame is elsewhere.

The snapshot and the ride-alongs (B001, B029, B043, B060, B188) are not in this harness. They wait on `convicted: true`. No separate C11-310 plan.

D22 follow-up is warranted when, after warmup, IOSurface count grows by more than the one visible terminal, the byte growth exceeds 1 GiB, and the last quarter is still rising. A flat plateau is reported (`plateau_count`) and is not a follow-up. The missing reclaim is already described at `GhosttyTerminalView.swift:3929` (`setOcclusion` calls `ghostty_surface_set_occlusion` and does not release the swap chain).

## 16 GB

The constellation's Macs are 128 GB. The constrained run is a virtual machine with 16 GB of RAM unless a physical 16 GB Mac is named. Pass `--constraint vm_ram_16gb` or `--constraint physical_16gb`. A VM does not emulate unified-memory GPU, so its IOSurface numbers are not a physical D22 claim. A kill on a VM is status `killed`. A kill on a physical 16 GB Mac is a fail. Neither replaces the overnight Atlas candidate.

## Cost

Nominal subscription capacity estimate. 40 agents × 2.5 turns/hour × 3000 input tokens and 50 output tokens:

- 100 turns/hour, 300,000 input tokens, 5,000 output tokens
- a 3h baseline, a 10h candidate and a 2.5h constrained run are 15.5h plus preflight/g60; one candidate retry totals 25.5h plus overhead.
- 3000 input tokens is an estimate, not a verified cap on a provider CLI's full context. Retain numeric usage where available, without retaining provider content. Historical dollar ceilings are not admission gates or current price claims.

`execute` stops the run when sends exceed 3× the planned hourly rate (`ABORT_IF_TURN_RATE_EXCEEDS`). The first hour is scored against one full hour, so the launch burst and the first storm stay under the limit, and 301 sends in that hour abort. The run is `interrupted`. It is not a pass. Hour 1 carries the launch burst; later hours are the pings and storms. Capacity is about 100 short turns an hour across forty resident sessions.

## Auth

Atin chose subscription. It is the default and the only planned mode. `driver.py run` uses it when `--auth` is omitted. No API key is required for any role.

The launch environment has `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and `XAI_API_KEY` removed, so a leftover value cannot move the CLIs off the logged-in call-sign. Nothing is written under `~/.claude`, `~/.codex`, or `~/.grok`. The turn-rate abort is the stop. The `api` branch remains in the driver and is not a planned run.

## What a run writes

`driver.py run` writes one JSON document: sha, role, wall hours, probes, memory samples, parsed hangs, restart socket times, turn counts, and the agent refs. `driver.py classify baseline.json candidate.json` prints the gate. Keep the raw footprint JSON and the event log next to it on Atlas. Do not copy provider transcripts into the ticket.
