# Spike 0b: c11 terminals on herdr-core's attach stream

Run 2026-10-30, 13:32 to 15:25 PDT, by Cairn (Claude Opus 5.5) from `SPIKE-0B-BRIEF.md`. Branch `spike/c11v-hc` (local only, never pushed), commit `dd0d4e75a9f`, which holds the Swift code of the last build-host build (the one rows 5, 11, 12, 13 to 20 ran on; earlier rows ran on builds without the late fixes, as each row says). Visible checks ran in the build host Tart guest (a clone of `c11-sandbox-golden`, macOS 26.6.2, slot 1) on the tagged Debug build `c11v-hc`. The hc core was an isolated hc 0.1.14 in that guest (tarball SHA-256 verified, `HC_SESSION=c0b`, sockets in `/tmp/c0b`).

Guest logs are stamped UTC (PDT = UTC minus 7). Evidence files keep the raw UTC stamps; times in this text are PDT.

**V** = verified by a run here. **I** = inferred. A fresh-context review (Sonnet) checked every number against the evidence files. The latency figures recomputed exactly; its other findings are folded in below.

## Needs you

**Nothing blocks. No kill criterion was hit.** One optional call:

1. **Run the real Prime remote leg? (Recommended: not now.)**
   - **What ran instead.** Row 19 ran against a second isolated core in the same guest, reached through `--via`. That covers the relay, attach through two cores, link drop and repaint paths, but not a real network.
   - **Why.** Getting `prime` and its key into the guest looked like more than the hour the brief allows. The brief's other fallback (the laptop, an isolated core and a real Prime box) was not run either.
   - **Already known.** The exploration measured Prime's echo over the network with Python (experiment 18).
   - **What hangs on it.** The claim that c11 renders a terminal on a real remote machine correctly, and the "keys typed during a drop are lost" case. About an hour.

## Verdict against the kill criteria

| Kill criterion | Result |
|---|---|
| c11's Ghostty fork mis-renders hc's paint or stream in a way c11 cannot fix | **Not hit.**<br>Paints (first, reattach, core restart, link drop) and the live stream rendered the same as an exec panel once two c11-side bugs were fixed (defects 1, 2) (V).<br>The differences left are queries hc answers itself (defects 3 to 5). Those are hc behavior, not rendering, and fixable in the fork (I). |
| Added keystroke p99 above 1 ms, idle (row 17) | **Not hit (V).** +308 µs and +280 µs in two runs on two guests (n = 2,100 each). |
| Added keystroke p99 above 1 ms with 20 panels replaying agent output (row 18) | **Not hit (V).** +324 µs and +208 µs in two runs. |
| The vim-after-resize defect has no fix on this path (row 3) | **Not hit (V).** Fixed on the c11 side, see row 3 and defect 2. |

**Caveat on the baseline.** Both latency rows are measured against a direct-PTY backend on the same build, not against exec as the brief asked; see Latency. The exec path is probably at least as fast as that baseline, so the true cost over exec is the measured delta or a little more (I).

## The checklist

| Row | What | Result | Evidence (`evidence/`) |
|---|---|---|---|
| 1 | Typing and echo | **Pass (V).** System Events keystrokes echoed `typed-42 xterm-ghostty t1`. The shell's parent is pid 1981, `hc hold --socket …`. | `01-typing-echo-hold-parent.png`, `row01-ps-hold.txt` |
| 2 | `stty size` after `resize-window` | **Pass (V).** 19x55, then 16x43, each equal to the RESIZE c11 sent.<br>In a later shrink, hc and exec panels both print 35x43 and wrap a width ruler identically. | `row02-stty.txt`, `02b-ruler-after-shrink.png` |
| 3 | vim after a resize | **Pass after a fix (V).**<br>**Before:** an unfocused hc panel kept its pre-resize frame (Step 0's defect, see defect 2), and its grid stuck 4 columns narrow until the next key.<br>**After:** vim redraws correctly on shrink and grow without Ctrl-L.<br>**Debounce:** kept at 40 ms. Debounce 0 also rendered once (`03j`), but Step 0's race is timing-dependent.<br>**Mode 2048:** RESIZE goes out ahead of each in-band report, at Ghostty's reflow, outside the debounce. All 13 reports matched the PTY size at arrival. | before `03d`, `03e`, `03h-*`; after `03i-*`; `row03-mode2048-report-vs-pty.txt` |
| 4 | Title, OSC 7 cwd, git probe | **Pass (V).** | `row04-title-osc7-git.txt` |
| 5 | Mouse in vim, kitty query and Escape with flags, DA1, DSR | **Pass except DA1 (V).**<br>Mouse: two clicks in vim with `mouse=a` moved the ruler to 21,22, then 11,22.<br>Kitty: Escape with flags 1 pushed arrived as `ESC [ 2 7 u`; `?u` answered.<br>DSR: answered.<br>**DA1 differs:** the core answers `?62;22c`, exec answers `?62;22;52c` (defect 3). | `row05-kitty-mouse.txt`, `05-vim-mouse-click.png`, `row05-06-queries.txt` |
| 6 | OSC 52 write, OSC 52 read, XTGETTCAP | **Write and read pass (V).** The read was answered by c11's Ghostty through the stream, not timed out.<br>**XTGETTCAP fails (V):** a `TN;colors` query returns only `colors`, and two separate queries come back in reverse order (defect 4). | `row05-06-queries.txt` |
| 7 | Bell and IME | **Not driven.** c11 rings with `NSSound` and logs nothing. IME composition cannot be synthesized in the guest, as in Step 0. | none |
| 8 | Child exit closes the panel | **Pass (V).** `exit` in a split; hc sent `CLOSE {reason: exited}`; c11 closed the panel 3 ms later. | `row08-child-exit.txt` |
| 9 | Find over attached history | **Pass (V).** Cmd+F found `hist-0100`, which existed only in the 2,000 lines hc sent at attach.<br>This ran before defect 1 was fixed; that panel's paint happened to arrive after its channel registered. | `09-find-attached-history.png`, `09b-find-jump.png` |
| 10 | Splits | **Pass (V).** The split is its own terminal (`t13`; parent `t9`), starts in the parent's `/tmp/gr`, no cross-typing. | `10-split-own-terminal.png` |
| 11 | Flood while typing in another panel | **Partial (V).**<br>The app did not stall, and the typed panel kept echoing, but slowly: p50 1.1 ms, p99 8.4 ms during a 500 MB `yes` (n = 500, no baseline).<br>**The 4 MiB repaint was not observed.** c11's Debug Ghostty in the VM paced the flood: 100 MB took 103 s on hc and 81 s on exec, run side by side.<br>The core's RSS reached 288 MB (defect 9). | `latency-hc-flood.log`, `row11-flood-100MB-hc-vs-exec.txt`, `defects-misc.txt` |
| 12 | Theme switch | **Pass for a theme change (V).** After `c11 terminal-theme set`, OSC 11 returns `#090300` (previously `#282c34`) in the hc panel, equal to exec; FACTS went out on the change.<br>The guest's light/dark appearance flip did not switch c11's slot for either panel, so a slot switch was not exercised. | `row12-theme-osc11.txt` |
| 13 | Quit, relaunch with `--qa resume` | **Pass after a fix (V).**<br>Same pids (1559, 2151). All 300 history lines appear exactly once. Ticker lines printed while c11 was down are present. No resume command was typed.<br>The first attempt lost a panel's paint (defect 1). The Quit dialog copy is wrong (defect 7). | `row13-*.txt`, `13d-quit-dialog.png`, `13e-after-resume-fixed.png` |
| 14 | `kill -9` c11, relaunch | **Pass (V).** Same pids, 300 history lines once, 109 continuous ticks. | `row14-after-kill9.txt`, `14-after-kill9-resume.png` |
| 15 | `kill -9` the core with vim and a shell running | **Pass (V).**<br>The holder restarted the core. c11 reconnected after 14 attempts in 3.3 s and reattached both panels (`screen: inexact`).<br>vim was correct after the nudge; the ticker kept its pid. | `row15-core-kill.txt`, `15-after-core-kill.png` |
| 16 | Exec fallback | **Pass (V).** A panel opened during the 3 s outage logged `fallback_exec reason=core_unreachable` and runs under `/usr/bin/login` with no `HC_TERMINAL_ID`. It stays exec afterwards (defect 11). | `row16-fallback.txt` |
| 17 | Latency, idle | **Pass against the direct-PTY baseline (V).** | latency table |
| 18 | Latency, 20 replay panels | **Pass against the direct-PTY baseline (V).**<br>All 21 panels were live, but forced in with `--allow-undersized`, so several were a few columns wide. | latency table, `18-replay20-hc.png` |
| 19 | Remote panel: typing, resize, link drop | **Pass on a loopback machine, not Prime (V).**<br>A panel on `box/t1` sat beside a local one. Real keystrokes worked; `stty` went 42x65 → 35x43 after a resize.<br>After the via child was killed, hc repainted the panel on its existing channel (838 bytes, 14:50:52) and the remote shell kept pid 2594. The line read `connected` again at the first poll, about 1 s after the kill.<br>Not exercised: keys lost during a drop. The loopback link was back before the keys were sent. | `row19-*.txt`, `19-remote-after-link-drop.png` |
| 20 | 200 panels in one workspace | **Mixed (V); see the notes below the table.** | `row20-200-hc.txt`, `row20-200-hc-rerun.txt`, `row20-200-exec.txt` |

**Row 20, read with care.**

- **Memory.** c11 used 3.56 GB (top MEM) in both modes. The core used 71 MB and the holder 31 MB with 373 live hc terminals (`hc ls`). `c11 tree` took 0.29 to 0.57 s in both.
- **Focus time.** `focus-panel` took 1.10 to 2.74 s on hc in the two measured runs, against 0.52 to 1.12 s on exec. A third hc reading, 2 minutes later, gave 0.56 and 1.13 s.
- **CPU.** hc read 108% (`ps`) and 56% (a `top` sample) after a 60 s settle. A `sample` and `top` 2 minutes later showed c11 idle (0.7 to 14%), core 3%, holder 1.4%. Exec read 0.1 to 0.7%.
- **Not like for like.** The runs had unequal process loads (321, 605 and 500 zsh processes), because nothing reaps old terminals (defect 8).

So the steady state is close to exec. Settling after creating 200 hc panels is slower and costs CPU for over a minute, cause not isolated (I).

## Latency

**Method (V).**

- **Probe.** `C11_SPIKE_HC_LATENCY_LOG` arms when a one-byte printable write enters `io_write_cb`. It records the delta when that byte comes back on the panel's output queue, just before `ghostty_surface_process_output`.
- **Probe panel.** It runs `cat > /dev/null`, so the echo is the tty's own.
- **Keys.** System Events `keystroke "a"` every 12 ms, Return every 80.
- **Replay panels.** Each runs `replay0b.py` on a 600 KB capture of `git log -p --color`, which holds 26,566 escape sequences (`evidence/replay-agent-ansi.log`), at 50 KB/s.

**Baseline: the same build with `C11_SPIKE_DIRECT_PTY=1`, not exec.** This deviates from the brief.

- **Why not exec.** Exec mode has no point where Swift sees a keystroke's echo, so it cannot be timed in-app without a Ghostty patch.
- **What the direct backend does.** It runs the same manual-IO plumbing (ring, writer thread, output queue, probe), but c11 owns the PTY.
- **What the delta measures.** The hc hop: socket, core, holder, core, socket.

| Run (µs) | n | p50 | p90 | p99 | p99.9 | max | > 1 ms |
|---|---|---|---|---|---|---|---|
| hc, idle, run 1 | 2,100 | 173 | 258 | 417 | 9,287 | 11,978 | 16 |
| direct, idle, run 1 | 2,100 | 52 | 78 | 109 | 218 | 233 | 0 |
| hc, idle, run 2 (fresh guest) | 2,100 | 192 | 262 | 389 | 525 | 776 | 0 |
| direct, idle, run 2 | 2,100 | 50 | 72 | 109 | 135 | 187 | 0 |
| **added, idle** | | **+122 / +142** | **+180 / +190** | **+308 / +280** | | | |
| hc, replay, run 1 | 2,000 | 106 | 157 | 391 | 10,807 | 17,328 | 7 |
| direct, replay, run 1 | 2,100 | 33 | 44 | 67 | 128 | 298 | 0 |
| hc, replay, run 2 (fresh guest) | 2,100 | 114 | 158 | 292 | 667 | 870 | 0 |
| direct, replay, run 2 | 2,100 | 44 | 57 | 84 | 197 | 843 | 0 |
| **added, replay** | | **+73 / +70** | **+113 / +101** | **+324 / +208** | | | |
| hc, typed panel during a 500 MB flood | 500 | 1,140 | 2,522 | 8,354 | | 12,825 | 309 |

**How to read it (I).**

- **Environment.** A guest VM on a shared the build host, the Debug app build, one session per row.
- **Margin.** The p99 margin to the 1 ms budget is about 3x.
- **The tail.** Run 1's tail (16 and 7 samples above 1 ms, p99.9 near 10 ms) did not recur on a fresh guest (0 and 0). Run 1's guest had been through floods, a core kill and hundreds of orphaned terminals.
- **Load.** The replay load lowered hc's p50 instead of raising it, so 20 × 50 KB/s is light work, not a stress test.

## Defects found

1. **Paint dropped before its channel registered (my spike client; fixed, V).**
   - **Cause.** The core sends the first paint right behind the attach reply. The reader thread saw those frames before the control queue had registered the channel, and dropped them as "unknown channel".
   - **Effect.** A reattached panel lost its history and screen. hc's paint carried 117 ticks; the panel showed none before 14:15:23. The pre-fix dumps hold only zsh's redraw, with no `CSI !p`.
   - **Fix.** Frames for a channel newer than any registered one are held, then replayed in order, under the same lock, when it registers. After the fix: `early_frames_replayed … bytes=1834`.
2. **Stale frame after a resize on an unfocused manual-IO panel (c11 and Ghostty; worked around, V for the fix, I for the cause).**
   - **What happened.** The terminal state was current: vim at 57x42 in `read-screen` and in the core. The frame showed the pre-resize picture until the next key. Because no frame rendered, c11's scroller stayed reserved and the grid stayed 4 columns narrow.
   - **What was tried.** A build with `ghostty_surface_refresh` plus `ghostty_surface_draw` at 60, 200 and 500 ms did not fix it (`03h`). The same build with c11's `forceRefresh` in place of the plain refresh did (`03i`). `forceRefresh` reasserts the display id before refreshing.
   - **What the shipped code runs.** `forceRefresh` and `draw` three times per forwarded resize, per panel. Its cost across many panels was not measured, and whether `draw` is still needed was not isolated.
   - **Likely cause.** Ghostty's renderer skips `drawFrame` while it believes its vsync display link owns drawing. For this surface the link does not deliver frames until the display id is reasserted, which is the "stuck vsync" state c11 already works around on focus.
3. **DA1 answered by the core without `52` (hc, V).** Programs that read DA1 to decide whether OSC 52 works see no clipboard, though c11 supports it.
4. **XTGETTCAP partly answered by the core (hc; behavior V, cause I).**
   - **Behavior.** The core answers the names it knows (`colors`) and strips the query, so names only the viewer knows (`TN`) are lost. When the queries are separate, the core's answer overtakes the viewer's and the order flips.
   - **Cause.** Read from `relay.rs`, which strips any query its screen answered.
   - **Correction to the exploration.** It recorded XTGETTCAP as passed through untouched; that holds for one name only.
5. **XTVERSION answered by the core as `ghostty`, without a version (hc, V).** Exec answers `ghostty 1.3.0-HEAD+1b7bcf0`.
6. **New terminals start at hc's headless 200x120 (hc, V).** zsh's first prompt-mark filler is drawn for 200 columns before the attach resize, which leaves a long blank `%` line. `terminal.run` takes no size.
7. **The Quit dialog copy (c11, V).** "Quit c11? This closes every window and workspace." On this path, terminals survive Quit. Same as Step 0.
8. **No reaper (spike scope, V).**
   - **Effect.** A fresh launch leaves the previous session's hc terminals running. By the end the guest core held 373 terminals, and the guest hit its process limit (`fork failed`).
   - **Fix.** Step 1 needs the `c11.panel` label reaper.
9. **Core memory under a flood (hc; numbers V, meaning I).**
   - **Observed.** During a 500 MB flood the core's RSS reached 288 MB, and hc was no faster than exec.
   - **Reading.** Either the core buffered far more than the documented 4 MiB before repainting, or credit kept the viewer under the threshold while the backlog sat in the core. Not instrumented.
10. **Keystroke tail on hc (I).** Above 1 ms in run 1 only (see Latency). Not reproduced on a clean guest, cause not isolated. The candidates are the core's global lock (exploration issue 2) and guest state.
11. **Panels opened during a core outage stay exec (spike design, V).**
12. **Reconnect gives up after 90 s (spike design).** Panels then stay detached, with a notice in the panel.

## What the fork must patch, from this run

These add to `EXPLORATION.md` section 5.

1. **DA1.** Answer with the viewer's capabilities, at least `52`, or leave DA1 to the viewer.
2. **XTGETTCAP.** Never answer part of a query. Either keep a full static table (patch 4 there) or pass the whole query to the viewer.
3. **XTVERSION.** Use the viewer's answer, or the core's with its version.
4. **Initial size.** Let `terminal.run` take an initial size; this pairs with patch 3 (keep the last size).
5. **Flood backlog.** Bound and measure the backlog per viewer under a flood, and confirm the 4 MiB repaint fires for a viewer that credits after parsing.

**c11 side, needed on any daemon path:**

- the early-frame buffer (defect 1);
- a display-id reassert and refresh after each forwarded resize (defect 2), ideally replaced by a Ghostty resize hook;
- RESIZE ahead of the 2048 report;
- CSI I/O converted to FOCUS;
- FACTS on theme change;
- the reaper;
- the Quit copy;
- re-checking the cost of creating 200 panels.

## Recommendation

On every kill criterion spike 0b passes:

- c11's Ghostty renders hc's paints and stream like an exec panel once two c11-side bugs are fixed;
- the hc hop adds 0.2 to 0.3 ms at p99, idle and under agent-output load (measured against a direct PTY, not exec);
- vim redraws after a resize without Ctrl-L.

Proceed to step 1 on hc in the fork posture. Carry the query fixes (DA1, XTGETTCAP, XTVERSION) as the fork's first patches beside holder isolation.

Two things are not proven and should be measured before default-on:

- the 4 MiB flood repaint, with the core's memory under a flood;
- a real remote leg.

## How it was built

**`Sources/C11vSpikeBackends.swift` (new)** holds three types.

- **`HCCoreClient`**, one framed connection for the app:
  - plain-mode `hello`, then JSON-RPC on channel 0 with request ids;
  - a reader thread demultiplexes channels into per-panel serial output queues, which call `process_output` and then return credit;
  - a writer thread drains one 4 MiB ring that `io_write_cb` appends to without blocking;
  - early frames are held per new channel until it registers;
  - after a lost connection it reconnects every 250 ms for 90 s, then reattaches every panel with no history.
- **`HCTerminalBackend`**, one per panel:
  - finds a live terminal by its `c11.panel` label, or calls `terminal.run` with c11's env, labels, `no_parent` and `no_notify`;
  - attaches with 2,000 lines of history on reattach;
  - sends RESIZE ahead of the 2048 report, converts CSI I/O to FOCUS, and sends FACTS (theme colors and cell size, again on a theme change);
  - takes child exit from the attach CLOSE or the `finished` event;
  - detaches when its surface is freed, and calls `terminal.kill` 1.5 s later unless the panel reattached or the app is quitting. Only close and quit were exercised.
- **`DirectPTYBackend`**, the latency baseline.

**The seam.** A backend seam in `createSurface`, gated on `C11_SPIKE_HC_SOCKET` or `C11_SPIKE_DIRECT_PTY`. With neither set, the exec path is unchanged.

**Known rough edge.** The first connect runs on main; a core that accepts but never answers `hello` stalls main for up to 1.5 s.

**Knobs:**

- `C11_SPIKE_HC_LOG`;
- `C11_SPIKE_HC_LATENCY_LOG`;
- `C11_SPIKE_HC_DUMP_DIR`;
- `C11_SPIKE_HC_RESIZE_DEBOUNCE_MS` (default 40);
- `C11_SPIKE_HC_RESIZE_FORCE`, `_REFRESH`, `_DRAW`;
- `C11_SPIKE_HC_HISTORY`;
- marker files `/tmp/c11-spike-exec-next` and `/tmp/c11-spike-on-next`.

**Guest tools** in `spike/c11v/tools/`: `hc-guest.sh`, `q0b.py`, `r2048.py`, `lat0b.sh`, `replay0b.py`, `p200.sh`, `via-box.sh`.

## What was left behind

- **Deleted:**
  - the sandbox guest `c11-sb-c11v-hc`;
  - the build-host tag caches `c11v-hc` in the remote build folder and `~/Library/Developer/Xcode/DerivedData/c11-c11v-hc`, and the staged app;
  - the isolated hc core on the laptop (stopped), its `/tmp/c0b` socket dir, and its scratch state.
- **Never created:** no Prime box; nothing installed on the build host; no PATH installs; no tenant config written.
- **Kept on the laptop:**
  - the retrieved app at `~/Library/Developer/Xcode/DerivedData/c11-c11v-hc/` and `build-remote/` in the worktree (never launched on the laptop);
  - the worktree `c11-worktrees/c11v-hc-spike` on `spike/c11v-hc`.
