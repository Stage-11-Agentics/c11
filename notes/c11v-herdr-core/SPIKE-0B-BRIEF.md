# Spike 0b: c11 terminals on herdr-core's attach stream

Authorized by Atin 2026-10-30 ("run the spike now, you're authorized"). Launched by the exploration seat (panel "c11v Pivot Exploration", mailbox address `c11v-pivot-exploration`), which answers questions by mailbox. Atin reads your panel directly.

## The question this spike answers

Can c11's Ghostty renderer run every terminal panel on herdr-core ("hc") through Ghostty's manual-IO mode, with the fidelity, latency and restart behavior the c11v design needs? The exploration (`EXPLORATION.md`) says the shape is right and names the kill criteria. You produce the evidence, in a throwaway tagged build, and a report. Nothing merges.

## Read first

1. `EXPLORATION.md`: section 2 (the architecture: bytes, screens, control), section 4 issues 5, 6 and 13 (fidelity, the two Ghosttys, snapshots across pins), section 9 (the step 0b row: scope, done-when, kill criteria).
2. `experiments.md`: what was measured with the Python harness and how. Your numbers replace those for the in-app path.
3. `probe/hcx.py`: a working framed-protocol client (hello, attach, DATA, CREDIT, RESIZE, FOCUS, FACTS, CLOSE, terminal.run, events). Port its logic to Swift; do not reinvent the framing.
4. On the branch you are on (`spike/c11v-hc`, cut from `spike/c11v-manual-io`): `spike/c11v/prototype.md` (the Step 0 manual-IO prototype: desk-check table, missing Ghostty hooks, threading rules, the guest checklist and how it was run), `spike/c11v/tools/spike-guest.sh`, and the stub backend in `Sources/GhosttyTerminalView.swift` (`SpikeDaemonConnection`, gated on `C11_SPIKE_DAEMON_SOCKET`). You replace the stub's protocol with hc's and keep the Ghostty-side plumbing.
5. `docs/c11v-design.md`, "Step 0 results" items 4 to 7 (hooks, threading, broken assumptions, raw replay).
6. `CLAUDE.md` (builds on the build host through `scripts/remote-build.sh`, one reused tag, admission, never `open` an untagged app, guests for anything visible), `skills/c11-hotload/SKILL.md`, `skills/c11-computer-use/SKILL.md`.
7. herdr-core source, for reference only: `schema/README.md` (the wire format and events), `crates/herdr-core/src/{viewers,relay,wire,input,api/run}.rs`, `crates/ghostty-vt/src/lib.rs` (`paint`). A full clone may still be at `/private/tmp/claude-501/-Users-demo-Projects-Stage11-code-c11/724b9223-616b-4ef7-822f-32cd9dd2bd67/scratchpad/src/herdr-core`; if it is gone, `git clone https://github.com/herdrdev/herdr-core` into your own scratchpad and check out `v0.1.14`.

## hc facts you need (verified 2026-10-30, hc 0.1.14)

- **Binary.** Pin 0.1.14: `https://releases.herdr.dev/core/0.1.14/herdr-core-macos-aarch64.tar.gz`, SHA-256 `ca524329d2e0630219550055dcc71f42aafd85fba356e0d543d6f51244487970`. Never run the installer script. Keep the binary in your scratchpad (and the guest's share), never on PATH. The macOS binary is unsigned; that is fine in a guest.
- **Isolation.** Every core you start: `HC_SESSION=<unique>`, `XDG_RUNTIME_DIR=/tmp/<short>` (0700; socket paths are capped at 103 bytes), `XDG_STATE_HOME` and `XDG_CONFIG_HOME` under your scratch. Note the leak: programs inherit the core's whole environment, so a test that cares about `XDG_*` in user programs should isolate by `HC_SESSION` and `HC_SOCKET` only. Stop every core you start (`hc server stop` kills its programs) and remove its socket dir. Never start a core in Atin's default session.
- **Process model.** One core per session; one holder process per core build owns every PTY; the core keeps the screens (libghostty-vt per terminal) and answers most queries itself. `kill -9` the core: the holder restarts one within 3 s, screens come back `inexact`. `kill -9` the holder: every program dies.
- **Plain mode.** Newline JSON-RPC 2.0 on the Unix socket. `hello {framed: true, generation: 1}` switches to framed mode after its reply.
- **Framed mode.** Frame: `[channel u32 LE][kind u8][len u32 LE][payload]`. Kinds: 0 DATA, 1 CREDIT (u32 LE bytes consumed), 2 CLOSE, 3 RESIZE (u16 LE cols, u16 LE rows), 4 FOCUS (1 byte), 5 FACTS (JSON `{fg, bg, cursor, cell:[w,h]}`). Channel 0 carries JSON-RPC both ways; each attach gets its own channel. A stream starts with 256 KiB of credit; send CREDIT after the VT consumed the bytes; more than 4 MiB behind gets a repaint instead of the backlog.
- **`terminal.run`** `{argv | line, cwd, env, name, labels, no_parent: true, no_notify: true}` returns the record (`address`, `pid`, `cols`, `rows`). Pass c11's env map (ids, socket path, PATH with the wrapper bin dir, TERM, the shell integration vars) and labels `c11.panel=<uuid>`, `c11.workspace=<uuid>`. Use `no_parent` and `no_notify` always. argv runs the program directly; use `/bin/zsh -l` (the default shell is `$SHELL` without `-l`). hc adds `HC_TERMINAL_ID`, `HC_SCOPE`, `TERM=xterm-256color` and `TERM_PROGRAM=ghostty` when absent. Do not put secrets in `env`: hc stores it in plaintext.
- **`terminal.attach`** `{terminal, cols, rows, history, display, observe:false}` on a framed connection returns `{channel}`. The first frames on the channel are the first paint: `CSI !p`, a mode list, tab stops, the screen with its modes, cursor and title, then `CSI ?9001h|l` and any stored OSC 7501 reports. Then raw program output minus queries the core answered. Feed all of it to `ghostty_surface_process_output` off main.
- **Sizes.** The newest active viewer (typed, resized or gained focus) sets the PTY size. With no viewer the terminal snaps to 200x120. Send RESIZE whenever Ghostty's grid changes; after each RESIZE, send the mode-2048 in-band resize report Ghostty produces as the first input (herdr-app's fix for full-screen programs redrawing late). A `size` event tells you another viewer took the lead.
- **Focus.** Ghostty writes `CSI I` / `CSI O` to `io_write_cb` when a program set mode 1004; convert those two sequences into FOCUS frames instead of sending them as DATA, or the program gets two reports.
- **Queries.** The core answers DA1, DA2, XTVERSION, DSR, OSC 10/11/4, kitty `?u`, DECRQSS, `CSI 14/16/18 t`, DECRQM, `?996n`, OSC 7501 `?` itself, using the FACTS you sent (send fg, bg, cursor and cell size at attach and again on a theme switch). It leaves XTGETTCAP, OSC 52 read, XTSMGRAPHICS and kitty graphics acks to you: whatever Ghostty answers through `io_write_cb` goes out as DATA.
- **Lifecycle.** `events.subscribe {}` (plain or framed; frames on its own channel need CREDIT too) gives a snapshot then `created`, `finished`, `lost`, `restarted`, `status`, `turn`, `title`, `labels`, `size`, `foreground` events, `heartbeat` every 15 s, `missed` with a fresh snapshot when you fell behind or after a core restart (seq restarts at 0). `finished` carries exit code and signal: that is your child-exit signal. Closing a panel: `terminal.kill {terminal}`. Detach: CLOSE on the channel. Every core restart drops every client connection with no CLOSE: reconnect, re-subscribe, reattach every panel (expect a full repaint).
- **Reads.** `terminal.read {terminal, lines}` returns plain text (screen plus history); with `lines > 0` on an alternate-screen app it scrolls the app to stitch history, so pass 0 for those.
- **Threading (from Step 0, holds here).** `io_write_cb` runs on Ghostty's IO thread, sometimes under the renderer lock: enqueue into a bounded buffer and return; no allocation per keystroke, no `ghostty_surface_*` call, no hop to main. `ghostty_surface_process_output` from a background thread, never main, never inside `io_write_cb`. Userdata outlives `ghostty_surface_free` (it joins the IO thread). Splits inherit `io_mode`, `io_write_cb` and `io_write_userdata`: set all three on every surface you create.
- **CLI gotchas.** `hc run … <program> --json` hands `--json` to the program; use the API or put flags before the program. `cp`, `mv`, `rm` are `-i` aliases in Atin's shells: scripts use `/bin/cp -f` and friends.

## The work, in order

1. **Branch and build.** You are in a worktree on `spike/c11v-hc` (cut from `spike/c11v-manual-io`, which carries the stub backend, the root `ghostty.h` declaration and the 40 ms resize debounce). `git submodule update --init --recursive ghostty vendor/bonsplit` first. Builds go to the build host: `./scripts/remote-build.sh --tag c11v-hc` (reuse this tag for every build; prune it when you finish, per `c11-hotload` tag hygiene). First build cold, about five minutes.
2. **The backend.** Replace the stub's wire protocol with hc's: a `HCCoreClient` (connect, hello framed, JSON-RPC on channel 0 with request ids, a reader thread that demultiplexes channels, a writer thread fed by a bounded queue, credit accounting), and a per-panel `HCTerminalBackend` (run, attach, DATA, RESIZE plus the 2048 report, FOCUS conversion, FACTS, CLOSE, kill, finished → child exit via the existing `closePanelAfterChildExited` path, reattach by `c11.panel` label after a core restart). Gate it on `C11_SPIKE_HC_SOCKET=<path>`; with it unset, or the core unreachable, the exec path runs unchanged (the stub's fallback already does this). Keep it a backend seam, not a branch inside `createSurface`, if the branch's shape allows it in the time you have. Keep the stub's debug logging shape (`key=value`, local time) so a run can be read afterwards.
3. **Latency instrumentation.** Behind `C11_SPIKE_HC_LATENCY_LOG=<file>`: for a one-byte write that enters `io_write_cb`, record the monotonic time; when the echo of that byte arrives in the output thread, record the delta. Report p50, p90, p99 and max over at least 2,000 samples, driven by synthesized keystrokes in the guest (System Events key codes worked in Step 0 where cliclick did not). Do the same with 20 other panels each replaying a captured ANSI log at about 50 KB/s (`cat` through a rate limiter; `pv -L 50k` if present, else a small Python loop). The exec path on the same build is the baseline for both runs.
4. **Guest validation.** Start an isolated hc core inside the guest (download or copy the pinned binary there; verify the SHA-256), launch the tagged app with `C11_SPIKE_HC_SOCKET` set, `--qa fresh`, and run the checklist below with screenshots and logs under `notes/c11v-herdr-core/evidence/`. Two guest slots exist on the build host and only the primary golden image is provisioned; check before relying on the second.
5. **Remote leg.** From the guest's core, `hc machine add --name box --temp --install --via 'prime --plain sandbox ssh <id> --'` to a Prime box you create (`prime --plain sandbox create buildpack-deps:bookworm-scm --yes --name c11v-spike-0b --label fleet=c11v --cpu-cores 2 --memory-gb 4 --disk-size-gb 10 --timeout-minutes 180 --region us`; delete it when done). The guest needs the `prime` CLI and its key; if that is more than an hour of plumbing, run the remote leg from the laptop against an isolated core instead and say so. Not the build host: Atin has not approved installing hc there.
6. **Report.** `notes/c11v-herdr-core/SPIKE-0B.md`: open with "Needs you:", then the checklist table (row, pass or fail, evidence file), the numbers against the kill criteria, defects found (with the cause where you have it), what the fork must patch from what you saw, and your recommendation in three sentences. Mark every claim verified or inferred. Post the same in your panel and send `c11 mailbox send --to c11v-pivot-exploration "<path and headline>"`.

## The checklist

Every row runs in the guest on the tagged build unless marked. Pass means the behavior matches an exec panel beside it.

| Row | What | Pass |
|---|---|---|
| 1 | Typing and echo in a zsh panel | Real keystrokes echo; `ps` shows the shell's parent is `hc hold` |
| 2 | Resize: `stty size` after `c11 resize-window` | Matches the new grid |
| 3 | vim after a resize (Step 0's defect) | vim redraws correctly without Ctrl-L, with the 2048 report sent after RESIZE and the debounce removed or kept, whichever works; say which |
| 4 | Title, OSC 7 cwd, git probe | Panel title and cwd follow the shell |
| 5 | Mouse in vim (`mouse=a`), kitty keyboard query and Escape with flags pushed, DA1, DSR | As Step 0 |
| 6 | OSC 52 write; OSC 52 read; XTGETTCAP (`infocmp`-style query from a script) | Clipboard set; read answered by Ghostty, not timed out; XTGETTCAP answered |
| 7 | Bell and IME | Best effort; say what you could drive |
| 8 | Child exit closes the panel | `exit` in a split removes the panel within a second |
| 9 | Find overlay over attached history (`history: 2000`) | Cmd+F finds text from before the attach |
| 10 | Splits: a split of an hc panel is its own hc terminal, starts in the parent's cwd | No cross-typing between panels |
| 11 | Flood: `yes \| head -c 500M` in one panel while typing in another | The typed panel stays responsive; the flooding panel repaints after the 4 MiB drop; the app does not stall |
| 12 | Theme switch (light/dark) | OSC 11 query from a script returns the new background |
| 13 | Quit c11, relaunch with `--qa resume` | Every hc panel reattaches to the same pid with its exact screen; no `claude --resume` typed; scrollback not duplicated |
| 14 | `kill -9` c11, relaunch | Same as 13 |
| 15 | `kill -9` the core while vim and a shell run | Panels reattach after the holder restarts the core; screens `inexact` but correct after the nudge |
| 16 | Exec fallback | With the socket env var unset or the core down, a new panel is an exec terminal with a notice in the log |
| 17 | Latency, idle (step 3) | Added p99 ≤1 ms against the exec path |
| 18 | Latency with 20 panels replaying agent output (step 3) | Added p99 ≤1 ms |
| 19 | Remote: a panel on the Prime box in the same workspace as local ones; typing; resize; link drop (kill the ssh child) and reconnect | The panel repaints and keeps working; keys typed during the drop are lost (expected); the remote process survives |
| 20 | 200 hc panels (shells) in one workspace, hidden except a few | App memory and CPU against 200 exec panels; `c11 tree` responsive; switching panels instant |

## Kill criteria (from `EXPLORATION.md` section 9)

- c11's Ghostty fork mis-renders hc's paint or stream in a way you cannot fix on the c11 side within the spike (say exactly what and where).
- Added keystroke p99 above 1 ms in row 17 or row 18.
- The vim-after-resize defect (row 3) has no fix on this path.

If one is hit, say so plainly in "Needs you"; the exploration's fallback (a `c11d` around cmux-tui's host) is Atin's decision, not yours.

## Rules

- Local branch only: no push, no PR, no tag, no release. Nothing outward: no issues, comments or messages to herdr or anyone.
- Never touch Atin's c11 session or the laptop's display: all visible checks run in a guest. The laptop may run isolated hc cores and the Python harness for the non-visual rows if a guest slot is unavailable; say which rows ran where.
- build-host builds only through `scripts/remote-build.sh` with the one tag; prune the tag and both the build host caches when you finish. Do not install hc on the build host.
- Do not edit `docs/c11v-design.md`, `docs/c11v-herdr-core.md` or `EXPLORATION.md`; your findings go in `SPIKE-0B.md`, and the exploration seat folds them back.
- No tenant config writes anywhere (`~/.claude`, `~/.codex`, rc files), no PATH installs of hc, on any machine or guest.
- Delete every Prime box you create; stop every core; remove socket dirs. The last section of your report lists what was left behind, if anything.

## Working rhythm

- Name your panel (`C11v Spike 0b`) and keep your description current at each phase (c11 skill: title is identity, description is the live subtitle).
- Checkpoints in your panel at each phase, local time, so Atin never has to ask; mirror each with `c11 mailbox send --to c11v-pivot-exploration "<one line>"`.
- Questions the exploration seat can answer (hc behavior, what was measured, where something is): mailbox it. Questions only Atin can answer (approve the build host install, accept a kill, spend beyond a Prime box): raise a c11 flag with the reason.
- Three failed attempts at the same thing means the problem is elsewhere: step up a level and say so.
