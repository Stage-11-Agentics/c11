# C11H-293 Phase 1: Cmd+digit main hold, Release vs Debug (2026-11-13, 22:54 to 23:18)

**Outcome (c11-captain's ruling, 2026-11-14 00:59).**
- The hold's cause is named below: about 350 ms of SwiftUI chrome rebuilt per switch.
- Neither cheap fix helps; both are measured and rejected in Phase 2b.
- The structural work is C11H-295, gated on a week of real numbers.
- C11H-293's PR adds that seam, `workspace-switch.jsonl` in c11's logs folder (`c11 guide troubleshooting`). It also fixes the tab-bar hint's no-op `@Published` reset (bonsplit), which ran on every keystroke and inside every mount.

**Measurement builds.** They live on branch `c11h/C11H-293-measure`, not on main:
- `4e229c2d`: v1, `frame_watch` in Release.
- `17e819a1`: v2, run-loop and span timeline.
- `88a02457`: v3, mount-cap and key-view toggles.
- `851d1db2`: v4, hidden-update counters, release and focus checks.
- `62839bcd`: soak `--switch-probe` tooling.

Rebuild one with `scripts/remote-build.sh --mode release` from that commit, then run `scripts/c11-memory-soak-guest.sh <run> <label> -- --switch-probe 2` in a `sandbox-up.sh` guest.

## Setup

- **Apps.** One commit, `4e229c2d` (main `65d6e5fe` plus a measurement-only change that compiles C11H-255's `frame_watch` into Release). Release `c11 STAGING c11-orch2.app` (build-host invocation `5fa55fab`) and Debug `c11 DEV c11-orch2.app` (`e8f99cd8`).
- **Guests.** Each app ran in its own fresh clone of `c11-sandbox-golden` on the build host: 4 vCPU, 8 GB, a 1440x900 display at scale 1 (`sandbox-up.sh` always uses that size). Both clones were deleted afterwards.
- **Load.** The same as C11H-255's soak: 8 workspaces of 6 split terminals; 12 spinners (title at 10 Hz), 6 printers and 12 idle agents; `--visit 3 --warmup 120 --steady 60`.
- **Probe.** `scripts/c11-memory-soak.py --switch-probe 3` types Cmd+digit with cliclick in the guest. Each switch arms `debug.terminal.frame_watch` with `stall_after_select_ms=1`.
  - **Main hold** is measured from the selection (`storedSelectedWorkspaceId.didSet`) until a 1 ms block queued on main at that moment starts.
  - **First frame** is when each terminal's layer first shows a new IOSurface, as seen by a 4 ms main-thread timer.
  - **Cold** means the target was hidden at least 40 s (past the 30 s kept-frame grace). **Warm** means hidden about 5 s.

## Result (app clock, ms)

| | Release cold (n=24) | Release warm (n=6) | Debug cold (n=24) | Debug warm (n=6) |
|---|---|---|---|---|
| main hold, median | **428** | **437** | **672** | **656** |
| main hold, min to max | 362 to 476 | 393 to 480 | 582 to 727 | 634 to 683 |
| first frame, all 6 terminals, median | 508 | 505 | 799 | 778 |
| `list-windows` round trip after the switch, median | 21 | 22 | 25 | 24 |

- **Release holds main about 430 ms per switch,** over the 250 ms line, so Phase 2 applies. Debug holds about 1.55 times as long.
- **Cold and warm cost the same.** Frame release and rebuild don't drive the hold.
- **All six terminals' first frames land at the same 4 ms tick,** about 70 to 130 ms after the hold ends.
- **This run's Debug hold is 672 ms, not C11H-255's 1845 ms.** That run (`notes` in PR #307) had a longer warm-up, screen recordings and a 400 ms stall control in the same session. Which of those accounts for the difference is not measured. (PR #307 also reports a 2880x1800 guest; `sandbox-up.sh` sets 1440x900.)
- No failures or missing frames in either run. Exit 0 both.

## What main does: Phase 1 sample (superseded; it missed the switch)

One extra cold switch per app ran under `/usr/bin/sample <pid> 6 1` (6 s at 1 ms, the switch about 2 s in). Sampling slows main, so that switch's hold was 693 ms in Release and 723 ms in Debug; it is not in the table.

| main-thread samples over the 6 s | Release | Debug |
|---|---|---|
| total / idle in the run loop / busy | 3655 / 3234 / 421 | 3783 / 3171 / 612 |
| `HCAgentRecoveryController.receive` (on main) | 123 | 194 |
| `HCRecoveredTerminalController` inventory `reconcile` | 103 | 198 |
| of which `AppDelegate.workspaceContainingPanel` / `hcPanelClaims` | 62 / 39 | 99 / 76 |
| SwiftUI `NSHostingView` transaction flush | 52 | 52 |
| CA / update-cycle commit (`UC::DriverCore`) | 44 | 31 |
| key event dispatch, `WorkspaceManager` | 0 / 0 | 0 / 9 |

- **Correction (Phase 2):** these samples contain no `sendEvent` and no layout pass, so they missed the switch: `sample` was most likely still attaching when the key went in, which slowed the switch without recording it. The hc work below is steady background load, not the hold.
- **Most busy main samples are hc inventory work:** `HCAgentRecoveryController.receive` and `HCRecoveredTerminalController.reconcile`, each fed by inventory snapshots. Each snapshot does a full scan over every panel (`workspaceContainingPanel` per observation, `hcPanelClaims`). This is the work that grows in Debug. View work (SwiftUI, CA) is flat across builds.
- **The selection itself is cheap.** The key event and the selection setter don't appear in either sample.
- **Not yet established (Phase 2):** a whole-window sample can't show whether that hc work falls inside the hold, so the hold's cause is not named yet. Guess, unmeasured: the switch changes visibility and grid for 12 terminals, hc publishes inventory snapshots, and the full reconciles they trigger keep main busy. Phase 2 times each of those main-thread entries against the selection on the app clock.

## Files

- Release: `build-remote/memory/c11h293-release/memory-release.json` (`switch_probe`), `memory-release-switch-sample.txt`
- Debug: `build-remote/memory/c11h293-debug/memory-debug.json`, `memory-debug-switch-sample.txt`
- Runner: `guest-turn.sh`, attached to C11H-293 (a fresh clone per app, the soak above, then deletion).

# Phase 2: what holds main (2026-11-13, 23:24 to 23:51)

## Setup

- **App.** Release at `17e819a1`, the measurement build v2. `DebugFrameWatch` adds:
  - spans around every hc main-thread entry (agent recovery, recovered-terminal reconcile, fan-out drain);
  - spans around the selection's `applyPanelVisibility` calls and its async block;
  - run-loop activity from two common-mode observers, one at order 0 and one at the maximum order. The latter marks the moment main goes to sleep.
- **Runs.** Each ran in a fresh 1440x900 guest, deleted afterwards:
  - `rel2load`: 8x6 terminals under the soak load;
  - `rel2idle`: the same layout with no spinners, printers or agents;
  - `rel2samp`: no load, three switches under `sample`. `sample` was started first and the key typed about 2.3 s in; all three land inside the 4 s window.

## Result

| | `rel2load` (n=20) | `rel2idle` (n=20) |
|---|---|---|
| main hold, median ms | 431 | 412 |
| main asleep during the hold | 0 ms | 0 ms |
| hc spans inside the hold (all kinds) | about 1 ms | none |
| selection's own visibility work (hide 6 + show 6) | 0.3 ms | 0.3 ms |
| selection to main's next run-loop entry, median (min to max) | 366 ms (341 to 395) | 345 ms (319 to 374) |
| that entry to the marker, median | 67 ms | 64 ms |

- **Load does not cause the hold.** It is about the same with no load at all. hc reconciliation runs a few times every 20 ms in the background (0.3 to 0.6 ms each) and sits outside the hold.
- **The selection itself is cheap.** The selection runs inside the key event (`sendEvent` → shortcut monitor → `handleCustomShortcut` → `selectWorkspace(at:)`, stack in `memory-rel2load.json` `switch_probe.selection_stack`). Its own work, visibility included, takes under 15 ms.

## Named cause (measured)

**Every Cmd+digit rebuilds the shown workspace's SwiftUI chrome, and AppKit lays it out recursively and synchronously, about 350 ms in Release.**

1. `WorkspaceMountPolicy.maxMountedWorkspaces = 1` (`Sources/ContentView.swift`, from upstream cmux `ed7f6301`, Feb 2026) keeps only the selected workspace's `WorkspaceContentView` mounted. A switch unmounts the old one and mounts the new one.
2. On the next run-loop entry, the update-cycle observer commits the CA transaction: `UC::DriverCore` → `CA::Transaction::commit` → `NSDisplayCycleFlush` → `-[NSWindow layoutIfNeeded]`. That is 373 of the 389 hold samples in `memory-rel2samp-switch-sample-2.txt`; the layout-pass subtree including its observer frames is 375, the base used in Phase 2b. (The observer runs before the order-0 entry observer, which is why the timeline showed this as time outside the run loop.)
3. In that pass, SwiftUI's `NSHostingView.layout` renders the new workspace and inserts its platform views (`swiftui_addManagedSubview`).
   - Each inserted `AppKitPlatformViewHost` runs `viewDidMoveToSuperview` → `-[NSView _setDefaultKeyViewLoop]` → `-[NSView layoutSubtreeIfNeeded]`. That synchronously lays out the nested `NSHostingView` under it.
   - That nested view inserts its own platform views, and the pattern repeats about five levels deep (142 → 113 → 100 → 61 → 55 samples) through the bonsplit split and tab-bar hosts.
4. All six terminals' frames land at the next 4 ms tick after this pass. The terminals' kept or released frames play no part, which is why cold and warm switches cost the same.

# Phase 2b: the two candidate fixes, measured (2026-11-14, 00:16 to 00:58)

## Setup

- **App and runs.** Release at `851d1db2`, measurement build v4. Each run used a fresh 1440x900 guest under the 8x6 load, deleted afterwards. Toggles were set at launch.
  - `C11_PROBE_MOUNT_LIMIT=4`: option 1, the last four workspaces stay mounted and AppKit-hidden.
  - `C11_PROBE_KEYVIEW_AUTORECALC=flip`: option 2. The windows launch with `autorecalculatesKeyViewLoop = true`; the flip sets `false`.
- **Each run also records:**
  - two 10 s no-switch windows: main awake fraction, `WorkspaceContentView` bodies per second by visibility, and hidden-wrapper updates while hidden;
  - C11H-238's `GraphChurnMeter` log;
  - the kept-frame release (every workspace hidden 40 s or more, read from the layers);
  - footprint;
  - a Tab and Shift-Tab focus check through AX.

## Result

| | baseline | option 1: mount cap 4 | option 2: key-view flip |
|---|---|---|---|
| cold hold, median (n=16) | 454 ms | **754 ms** | 533 ms |
| warm hold, median (n=4) | 432 ms | **550 ms** | 519 ms |
| steady main awake | 21% | 22 to 26% | 19 to 21% |
| hidden `WorkspaceContentView` bodies, steady | 0/s | up to 1.4/s | 0/s |
| hidden-wrapper updates while hidden, steady | 0/s | up to 1.1/s | 0/s |
| `GraphChurnMeter` `hidden_wrapper_update`, median | 0.5/s | 1.6/s | 0.5/s |
| terminals still holding a frame 40 s after hiding | 0 of 42 | 0 of 42 | 0 of 42 |
| footprint at steady | 0.263 GiB | 0.331 GiB | 0.263 GiB |
| focus change | none | none seen | the find field's Tab now leaves to the terminal; Shift-Tab doesn't return |

- **Option 1 is rejected.**
  - Cold switches get 66% slower: mounting a workspace costs more with other hidden workspaces mounted.
  - Warm switches get slower too, even though the target stayed mounted and was only unhidden.
  - Hidden workspaces start evaluating SwiftUI bodies, C11H-238's defect class, and the footprint grows 68 MB.
- **Option 2 is rejected.** The hold is no shorter (the key-view loop decides only when the layout runs, not whether it runs), and the find overlay's Tab behaviour changes.
- **Focus check caveat.** In the baseline, Tab and Shift-Tab do not move focus in any of the four contexts. The address bar, rename field and find field keep it. In the Settings context, focus never left the main window: Cmd+, did not open Settings, or did not take focus. So the check could only detect a change, as it did for option 2. It could not show that focus "still moves".
- **Both options together are the worst:** cold 1034 ms, warm 729 ms (n=16/4), footprint 0.329 GiB, release still 0 of 42.
- **C11H-255's release fires in every variant.**

## What the hold is made of (timed sample, `rel2samp` sample 2)

c11 frames inside the 375-sample layout pass:

| c11 frame | samples |
|---|---|
| `TabBarView.horizontalBar` | 39 |
| `TabControlShortcutKeyMonitor.start` → `cancelPendingHintShow`, a `@Published` set inside `withAnimation` mid-render that forces a nested synchronous graph flush | 20 |
| `GhosttyTerminalView.updateNSView` | 13 |
| portal binds | 12 |
| `PanelTitleBarView` | 8 |

The rest is SwiftUI and AppKit building, rendering and laying out the newly mounted workspace's view graph. Self time is spread across AttributeGraph, the Swift runtime and the display list, with no single hot leaf.
