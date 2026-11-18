# Should herdr-core become the basis of every c11 terminal?

Exploration, 2026-10-30, 02:55 to 04:15 PDT, by Cairn (Claude Fable) from the brief in `BRIEF.md`, revised after a fresh-context review; spike 0b's results folded in at 15:40 PDT (`SPIKE-0B.md`, run 13:32 to 15:25 by an Opus seat in the build-host guest). Nothing was pushed, published, installed into PATH or sent outward. Every hands-on run used an isolated hc session on the laptop or a throwaway Prime box, all stopped and deleted at the end.

Evidence beside this file: `experiments.md` (18 measured experiments, with method), `feature-map.md` (43 c11 features mapped onto hc, built from `terminal-special-cases.txt`, the 218 functions and 334 references in `Sources/` and `CLI/` that special-case terminals), `hc-federation-robustness.md` (called "the audit" below: hc's lifecycle, federation, security and limits, read from the source), `herdr-app-read.md` (how herdr's own desktop client consumes hc), `probe/` (the harness). **V** marks a claim verified by an experiment or a read of the code end to end; **I** marks an inference; **reported** marks a fact taken from a published source named in section 8.

## Needs you

**The answer, updated 15:40 PDT: spike 0b ran and passed every kill criterion (`SPIKE-0B.md`). Proceed to step 1 on hc in the fork posture. The Step 0 recommendation (a `c11d` around cmux-tui's terminal host) stays the fallback if step 1's own criteria fail.**

Why. hc has the right shape and it works today, better than the first pass and I expected: a raw attach stream built for exactly the manual-IO viewer c11 would be, a core that crashes and restarts without losing programs, federation that merged a Prime box into the local terminal list in 27 seconds, and a status channel (OSC 7501) that Claude Code already speaks. It is not yet the right substrate for a product with live users. Two verified findings decide the posture. One holder process owns every PTY in a session: kill it and every program in that session dies (experiment 10). One thread under one lock parses all output and serves all requests: under an output flood a keystroke's p99 rose to 3.7 ms, 2.9 ms above a direct PTY in the same harness (experiment 6). Holder isolation is a contained patch (I). The single parse thread needs a locking redesign for which there is no patch yet (I). The codebase is 24k lines of Apache-2.0 Rust, and its author is funded and, by the merge dates on outside pull requests, responsive (reported). The spike settled the two questions the exploration could not: c11's Ghostty renders hc's paints and stream like an exec panel once two c11-side bugs were fixed, and the hc hop adds 0.2 to 0.3 ms at p99 inside the real app, idle and under agent-output load (V, spike 0b).

1. **Proceed to step 1 (recommended: yes).** The hidden backend behind an off-by-default setting, on a Stage 11 fork of hc in bundle mode (decision 2), carrying the spike's c11-side fixes, with two measurements first because the spike could not make them: the 4 MiB flood repaint together with the core's memory under a flood (the core reached 288 MB RSS and no repaint was seen), and a real remote leg on a Prime box (about an hour; the spike's remote row ran on a loopback machine). What hangs on it: the first daemon terminals on your fleet, and the month of holder-crash data that decision 4 needs. Cost: the fork's first patches plus the feature map's sidecar rows, as Lattice tickets through the hosted orchestrator (I).
2. **Posture: fork and track, not depend (recommended).** A Stage 11 fork of herdr-core, pinned per c11 release, bundled inside c11.app and signed by Stage 11, in its own session, with `hc update` disabled in bundle mode, carrying the patch list in section 5 and offering each patch upstream. Where it lives is your call: a private mirror on Forgejo (recommended until the posture is public; a GitHub fork of a public repo cannot be private, and a public one is a new exception to the Forgejo rule). The alternatives: depend on the user's own hc (herdr-app's model, which ties c11 to herdr's update cadence and the shared default session), or a hard fork (we own the single-holder design and lose the upstream fix stream). What hangs on it: who maintains the daemon, and whether c11 terminals can interoperate with herdr's clients.
3. **Contact the maintainer (your call; recommended: after spike 0b passes).** The brief forbids outreach now. The patches that matter (holder isolation, bundle mode, palette in the display facts, keep-last-size when no viewer) are small and generic (I), and a second serious client is in their interest. Apache-2.0 grants no trademark rights (section 6 of the license), so a modified bundled binary should be renamed or carry their permission; that is one more reason to talk. What hangs on it: whether those patches stay ours forever, whether the bundled binary can keep its name, and whether the interop story (Heeler, herdr-app) is a feature or an accident.
4. **Holder isolation before default-on (recommended).** Accept one holder per session for the opt-in steps 1 and 2, so measurement starts; require a holder per terminal (or per workspace) in the fork or upstream before step 3 makes daemon terminals the default. What hangs on it: whether "terminals survive the app" is ever true for everyone.
5. **Keep agent state in c11 (recommended).** Use hc for terminals, status, foreground, labels and federation only. The sketch leaned on hc documents for metadata and flags; the evidence says no: no list call, 1 MiB each, every write rewrites and fsyncs all documents under the lock that typing takes, change events carry no value, and documents are not replicated across machines (the audit). Labels are the one hc channel worth using for agent-reported fields from remote hosts, because they federate with the record and arrive as events. What hangs on it: the shape of step 4 and of the skill.
6. **Add OSC 7501 to c11's Ghostty fork regardless (recommended, an independent ticket).** Claude Code 2.1.314 reported `idle` to hc the moment the terminal answered its probe (experiment 17; no prompt was sent, so `working` and `blocked` were not observed); c11's fork predates the protocol, so c11 never hears it. Upstream Ghostty has the parser; the work is a backport onto the fork's Zig 0.15.2 base (I). The value over today's hooks: status for Claude sessions started outside the wrapper or while c11 was down, and one status story on every path later. What hangs on it: a cheap, accurate lifecycle source, and consistency with the hc path.

## Spike 0b, in one screen

Run 2026-10-30, 13:32 to 15:25 PDT, in the build-host guest on a tagged Debug build, hc 0.1.14 isolated in the guest; the full report with evidence is `SPIKE-0B.md`. All V unless marked.

| Kill criterion | Result |
|---|---|
| c11's Ghostty mis-renders hc's paint or stream in a way c11 cannot fix | Not hit. First, reattach, core-restart and link-drop paints and the live stream rendered like an exec panel once two c11-side bugs were fixed. |
| Added keystroke p99 above 1 ms, idle | Not hit: +308 and +280 µs in two runs of 2,100 keys. |
| Added keystroke p99 above 1 ms with 20 panels replaying agent output | Not hit: +324 and +208 µs. |
| The vim-after-resize defect has no fix on this path | Not hit: fixed on the c11 side. |

The baseline for the latency rows is a direct-PTY backend on the same build, not exec, because exec mode gives Swift no point to time an echo; the true cost over exec is the measured delta or slightly more (I).

Passed: typing, resize, vim after resize, title and cwd and the git probe, mouse and kitty keys, OSC 52 write and read (the read answered by c11's Ghostty through the stream), child exit, find over 2,000 lines of attached history, splits, theme change through FACTS, Quit and `kill -9` of c11 (same pids, exact screens, history once, no resume typed), `kill -9` of the core (reconnect in 3.3 s, `inexact` screens correct after the nudge), exec fallback during an outage, a remote panel on a loopback machine with a link drop and repaint.

Defects, hc side: DA1 answered without the `52` c11's Ghostty reports; XTGETTCAP answered only for the names the core knows and the rest of the query stripped; XTVERSION answered without a version; new terminals start at the headless 200x120 because `terminal.run` takes no size; the core's RSS reached 288 MB during a 500 MB flood and the documented 4 MiB repaint was not observed. Defects, c11 side, all fixed or scoped: a first paint dropped before its channel registered; a stale frame on an unfocused panel after a resize (fixed by c11's display-id reassert and refresh after each forwarded resize, pending a Ghostty resize hook); the Quit dialog copy; no reaper for terminals of a previous session (the guest core ended with 373 live terminals).

Not proven: the flood repaint and the core's memory under floods; a real remote machine; IME and bell (not drivable in the guest); a light/dark slot switch; the cost of creating 200 panels at once (settling took over a minute at high CPU in the guest, steady state close to exec, cause not isolated). One of two idle runs showed a tail above 1 ms (p99.9 near 10 ms) that a fresh guest did not reproduce.

## 1. What hc is, corrected

The first pass described hc as "a holder process per terminal that owns the PTY and screen". That is wrong in two ways that matter.

- **One holder per core build holds every PTY of the session** (`runtime.rs:240-254`, `api/run.rs:124-134`; experiment 10; V). It is a 392-line process with no parsing and no policy: spawn, pump, resize, signal, reap, and a 1 MiB raw tail per terminal. A second holder exists only while an older build drains after an update.
- **The core keeps the screen** (`viewers.rs:86-143`; V). Every output byte goes holder → core, where one libghostty-vt instance per terminal parses it, answers queries, strips the answered ones, and fans the rest out to viewers. A crashed core rebuilds each screen from the holder's tail and marks it `inexact` (experiment 9); a planned restart restores a Ghostty snapshot and is exact, unless the snapshot was written by another Ghostty version (issue 13).

The rest of the first pass holds: the attach stream is raw after a rendered first paint (experiments 1 to 3), the round trip is cheap at idle (experiment 5), programs outlive the core (experiment 9), the VT is upstream Ghostty tip (`vendor/ghostty` at `1e5cdb86`, Zig 0.16, newer than c11's fork at `1b7bcf06`), and the core has no telemetry (the audit, G11). The holder also restarts a crashed core itself after 3 s, so the system self-heals without launchd (experiment 9).

hc's vocabulary: a **core** per host and session (Unix socket, JSON-RPC, a framed mode for streams), a **holder** per build, **terminals** addressed `t7` or `box/t7`, **machines** added over SSH (`hc connect` on the far side; the local core relays every remote byte), **labels**, **documents** (versioned JSON per core), **events** (snapshot plus ordered deltas, `missed` on fall-behind or reconnect), and **status** from OSC 7501 only.

## 2. The architecture, layer by layer

What c11 looks like with hc underneath, concretely.

**Processes.** c11.app starts its bundled `hc serve` as a child (setsid) on first use, in its own session (`HC_SESSION` and `HC_SOCKET` per build and per dev tag). Two cautions from the review: hc takes its state and config directories only from `XDG_STATE_HOME` and `XDG_CONFIG_HOME`, and programs inherit the core's whole environment, so isolating the core that way would push those variables into every user program; until the fork's bundle mode (section 5, patch 2) takes its paths from variables it strips from program env, c11 isolates by session only and shares the user's `~/.config/herdr-core/config.toml` (V). The core starts the holder; the holder starts programs. TCC follows: everything under a core that c11.app spawned is attributed to c11.app (experiment 15; V), with the quit-and-relaunch case open (I). c11 must raise `RLIMIT_NOFILE` before spawning the core: the holder keeps three descriptors per terminal and never raises the limit (the audit); the 200-terminal run passed only because c11 shells carry a limit of 1,048,576 while launchd's default soft limit is 256 (V).

**Bytes.** One framed connection from c11 to the core, one attach channel per terminal panel. Keystrokes: Ghostty encodes locally, `io_write_cb` enqueues into a bounded per-panel buffer, a writer thread sends DATA frames (never blocking the IO thread). Output: a reader thread demultiplexes channels and feeds `ghostty_surface_process_output` off main, crediting bytes after the VT consumed them (herdr-app's shape). c11 also sends RESIZE, FOCUS (converting Ghostty's `CSI I`/`CSI O` into frames, or programs see two reports) and FACTS (theme fg, bg, cursor, cell size; resent on a light/dark switch), and answers the queries the core leaves to viewers (XTGETTCAP, OSC 52 read, kitty graphics acks) through the same channel.

**Screens, twice.** The core's VT is the authority: first paint, `terminal.read`, status and title parsing, history for reattach. c11's Ghostty surface is the renderer and the local reader for the input guard, the doorbell composer check and find. The paint is the only sync point. Both are Ghostty, from different commits; the paint is plain VT (soft reset, mode list, tab stops, screen, cursor, title), which c11's fork should parse, but that is exactly what spike 0b must show (I until then).

**Control.**
- `terminal.run` with c11's env (`C11_PANEL_ID`, `C11_WORKSPACE_ID`, the socket path, PATH with the wrapper bin dir; hc adds `HC_TERMINAL_ID`, `HC_SCOPE`, `TERM`), labels `c11.panel=<uuid>`, and `no_parent` plus `no_notify`: c11 keeps lineage, because hc's parent link ends children with their parent and types notes into reporting agents.
- `events.subscribe` for created, finished, lost, restarted, status, turn, title, labels, size and foreground.
- `terminal.kill` on panel close after a grace period; Quit detaches; a separate Quit and End All kills.
- `terminal.read` for hidden and remote `read-screen`; the input guard and doorbell keep reading the local surface.
- Snapshots record machine, address and uuid; restore attaches instead of spawning and never types `claude --resume` into a live terminal.
- No secrets in `terminal.run.env`: hc stores that map in plaintext in `terminals.json` (the audit, G9).

**c11's own layers stay.** Windows, workspaces, areas, panels, the sidebar, flags and delegates, Feed, the mailbox, the journal and events, conversation refs, prompt cache and model detection, browser and markdown panels, the skill. The socket gate changes from "descendant of c11.app" to "env identity plus descent from a live hc terminal's pid", which restores attribution, not a security boundary (issue 9). The tty must be re-registered after a c11 restart, or detection, ports and CPU stop (`feature-map.md`, N5).

**Hosts.** `machine.add` for the build host (ssh over the tailnet) and Prime (`--via 'prime --plain sandbox ssh <id> --'`, experiment 18). Remote terminals are `studio/t7` in the same list and event stream; `hc exec` and `file.*` work there; the browser proxy stays on `c11d-remote` (hc has no proxy). Measured only through Prime's gateway: echo p50 167 ms, p99 193 ms (experiment 18); the build host over the tailnet is not measured (I). Line state is not in the event stream (poll `machine.list`), mirrors go stale while a line is down, and a remote attach stream survives a drop by writing a banner into the terminal and repainting on reconnect (the audit, C6). The core's redials run with `BatchMode=yes` over a shared SSH ControlMaster that persists 600 s after its last session, so hosts whose login needs a person (a code, a prompt) need `hc machine login` after a long drop; key-based hosts like the build host do not (the audit, C1; I). Sleep and wake were not run; the Prime link-drop test is the closest proxy (reconnect in 6 s).

**An option the architecture opens.** Because the core keeps every screen, c11 could stop holding a Ghostty surface for hidden panels and reattach on reveal (first paint 0.4 to 6 KB). That trades memory across hundreds of panels for: no local composer read for hidden agents (the doorbell fails closed), programs in hidden terminals waiting out their XTGETTCAP timeouts (experiment 4), kitty images lost on reveal, and a resize to the headless 200x120 whenever the last viewer leaves (experiment 12) unless the fork keeps the last size. Not for step 1; herdr-app keeps every pane attached for the same reasons.

## 3. The feature map

`feature-map.md` walks 43 features with file and line citations, grouped from the 334 references in `terminal-special-cases.txt`: 5 move to hc, 20 stay in c11 (most unchanged; four gain a remote caveat), 16 need a c11 sidecar, and 2 break in the map's sense (the socket gate's security meaning, and TCC's identity whenever something other than c11 starts the core; with c11 starting it, TCC is open, not broken, per experiment 15). Three more rows break for federated terminals: ports and CPU, the doorbell, and transcript reads. The hardest rows:

- **Restart semantics.** Restore would type `claude --resume` into an agent that is still running; Quit suspends live conversation refs; env frozen at spawn goes stale after a c11 restart (`C11_PANEL_NUM`, `CMUX_PORT`, possibly the socket path).
- **The input guard and the doorbell** read cell attributes and the cursor from the local surface; `terminal.read` returns plain text and cannot replace them. Remote panels fail closed.
- **Manual-IO plumbing** (non-blocking `io_write_cb`, an output thread, FOCUS and FACTS, resize ordering, child exit, splits inheriting `io_*`), of which the last three are needed on any daemon path.
- **tty and pid features** survive locally once the tty is re-registered; nothing in hc replaces them for remote hosts.

What the sketch got wrong, per the map: `terminal.read` for the composer check; mapping lineage onto hc's `parent`; "tty and pid features on every host"; "stops `ps -t`" (that sweep also runs liveness decay, prompt-cache retention and model detection); "OSC 7501 emitted by the wrappers" (they `exec` their agent; Claude Code emits it itself, which is better).

## 4. Issues, ranked by severity

Each with its evidence or the experiment that would settle it.

1. **One holder runs every program; it dies, they die.** V: experiment 10; `runtime.rs:240-254`; `holder.rs`. No signal handler, so `killall herdr-core`, or a `pkill -f` matching c11's bundle path (c11's own `scripts/rebuild.sh` runs `pkill -9 -f c11`), ends every terminal in the session. `keep` brings back a fresh shell, never the program. Today c11.app is that single point of failure, with a main thread, a renderer and 225k lines of Swift; the holder has none of those, so this is an improvement in practice (I) and not the per-terminal isolation cmux-tui's host gives. Fix: a holder per terminal or per workspace; the protocol already supports several holders by instance (I: a contained patch, not written). Settles: the fork patch plus a crash count on Atin's fleet.
2. **One thread, one lock.** V for the structure: `runtime.rs:463-467`, `server.rs:38`. All output of all terminals is parsed on one holder-reader thread under the global state mutex, which every RPC also takes; status-word changes rewrite and fsync `terminals.json` under it. Idle cost is nil (experiment 11). Under a flood from 8 terminals a keystroke's p99 rose to 3.7 ms and its max to 17.7 ms, against 0.9 ms and 2.5 ms for a direct PTY, unparsed, in the same harness (experiment 6). The cause is I: the baseline does not parse, and the hc holder ran at 264% CPU in that run. Real agent output is bursty and far below `yes`, so the practical question is jitter on a busy fleet, not throughput (110 MiB/s is plenty, experiment 7). Spike 0b measured the agent-output case inside the app: 20 panels replaying captured output at 50 KB/s each added 0.2 to 0.3 ms at p99 (V); during a 500 MB `yes` flood in another panel the typed panel's p99 was 8.4 ms with no baseline, and one idle run carried a tail above 1 ms that a fresh guest did not reproduce (I). No patch exists; the fix is per-terminal screen locks and status saves off the output path (section 5, patch 8). Settles: the same flood through today's c11 exec mode; the audit's experiment 5 (200 agents flipping status at 1 Hz, fsync rate); the core's memory under a flood (defect 9 in the spike).
3. **Semantics that differ from a plain terminal.** V, read in the source and partly run. c11 controls most of these by how it calls hc; the sweep is the one users would notice.
   - On exit or kill, hc sweeps every process still carrying the terminal's `HC_SCOPE` token and their descendants (`nohup`, `disown`, `setsid`, a tmux server) with HUP, TERM, KILL.
   - A terminal with no viewer snaps to 200x120 and the program gets SIGWINCH (experiment 12); any other hc client that attaches, types or resizes takes the size lead from under the operator.
   - Viewer output that falls 4 MiB behind is dropped and replaced by a repaint (experiment 8); exec mode never drops.
   - `terminal.send` waits 3 s of human quiet and refuses `blocked` (experiment 13); notes are typed into reporting parents; the default shell is `$SHELL` without `-l`.
   - Settles: a product decision on the sweep, then a test that a `nohup` job survives panel close if we want it to.
4. **Startup brittleness.** V: experiment 16; the audit A8 and B4. A corrupt `terminals.json`, `machines.json`, `peers.json` or `core.json` stops the core from starting; the holder keeps retrying with backoff while programs run unreachable. Not run: a core started with a different socket directory sweeps every live program it cannot find (I); a wedged holder blocks startup forever (I). The fork should quarantine every state file the way it does `docs.json`, and c11 must never start a core with a different env than the one that owns the holders.
5. **Fidelity gaps on the stream.** V: experiment 4 and spike 0b. The core answers DA1 without the `52` c11's Ghostty reports, XTVERSION without a version, and XTGETTCAP only for the names it knows, stripping the rest of the query (the exploration's earlier "passed through untouched" held for a single unknown name only); OSC 4 palette queries come from Ghostty's default palette, not c11's theme (FACTS carry only fg, bg, cursor and cell); new terminals start at the headless 200x120 because `terminal.run` takes no size, so zsh's first prompt line is drawn 200 columns wide; kitty images are not in a repaint, so they vanish on reattach. Proven in the spike: OSC 52 write and read, mouse, kitty keys, title and cwd, find over attached history, child exit, theme change through FACTS, and vim after a resize (RESIZE ahead of the mode-2048 report, plus c11's display-id reassert and refresh after each forwarded resize; a Ghostty resize hook would replace the latter). Not driven: IME, bell, a light/dark slot switch. Settles: the fork's query patches (section 5, patch 4) and the Ghostty hook.
6. **The two-Ghostty question.** Resolved by spike 0b (V). hc builds libghostty-vt from Ghostty tip (Zig 0.16); c11 renders with the Stage 11 fork (March 2026 base). c11's fork rendered hc's first paints, reattach paints, core-restart paints and the live stream like an exec panel beside it, once two c11-side bugs were fixed: a first paint dropped before its channel registered, and a stale frame on an unfocused panel after a resize. The differences that remain are query answers (issue 5), not rendering.
7. **Scrollback across restarts is bounded by hc.** V: experiment 14; `config.rs` (`history_mb`, 5 MB by default, settable in the bundled core's config). After a c11 restart a panel's scrollback is what hc kept, formatted, main screen only. Today c11 restores its own scrollback but loses the process; with hc it keeps the process and up to 5 MB of history. A fair trade, to be said out loud.
8. **The bundle, update and install story.** V: the audit A5, C3, G1; `cli/update.rs`; `client.rs:176`. Four holes.
   - `hc update` overwrites `current_exe()` in place, which would break a signed bundle's seal; a user typing `hc update` inside a c11 terminal targets c11's core, because terminals inherit `HC_SESSION`.
   - While c11's core is down, any `hc` binary run inside a c11 terminal starts that session's core from itself; the pin holds only if c11 checks the build on every connect and hands over to its bundled copy.
   - `machine add --install` writes `~/.local/bin/herdr-core` and an `hc` symlink on the remote host, the same binary a user's own herdr would run there; fine for Atin's build host and Prime boxes, not for users with herdr on their own servers, and against the "host and primitive" rule.
   - Upstream's macOS binaries are unsigned and unnotarized, and there is no launchd integration (the core is a plain setsid process, gone at logout, restarted by the next hc call or by the holder). The release pipeline must build the fork with Zig 0.16 next to c11's Zig 0.15.2 Ghostty, then sign and notarize the nested helper (I).
9. **Security is same-uid, by design.** V: `docs/security.md`; the audit D. Any process running as the user can drive every terminal, kill them, read screens, run `machine.exec` and `file.*` anywhere, and hijack a peer. The delta from today is real (I): writing to a PTY device puts text on a screen but does not type input, and c11's default gate admits only descendants of c11.app, so hc gives every same-uid process three new abilities: typing input with Enter into any terminal, reading every screen with its history, and reading the env map stored in plaintext for every terminal. Also new: a federated machine can `send` into and `read` any local terminal that ever started work on it (the audit, C8), which matters for Prime boxes that run less trusted code; c11 should never give a box a `parent` on the Mac. The gate's job (which panel is this caller) is served by env plus descent from the terminal's pid (`feature-map.md`, §A).
10. **Protocol maturity.** V: the audit F. Generation 1, "preview", one week old, 39 commits. The "API only grows" test covers OpenRPC params and results against the last release only; events, the framed wire, error kinds, CLOSE reasons and the holder protocol are unguarded, and the holder's `VERSION` is sent but never compared. Upgrades are tested only from the previous release, on Linux. A pinned fork removes the day-to-day risk and inherits the obligation to test each bump ourselves.
11. **Federation edges.** V: the audit C5 to C7; experiment 18. Reconnect is fast (6 s) and the far core keeps terminals through local restarts; but a dropped line writes `[line to X lost; reconnecting...]` into the terminal stream, drops keys typed meanwhile, reattaches with a full repaint and no history, keeps stale mirrors with no event for line state, and a local core restart while an `$/orphaned` message is queued leaks remote children (I). Dial options are not settable beyond `~/.ssh/config` and `--via`.
12. **TCC after c11 quits.** I. Experiment 15 proves attribution to c11.app while c11 runs. Whether tccd keeps charging c11.app after that pid exits, and whether a relaunched c11 inherits the grants, is the test that decides the bundle route; it needs a tagged build in a guest.
13. **Screens across an hc Ghostty bump.** I, from `crates/ghostty-vt/src/lib.rs:696` and `runtime.rs:398, 750-765`. A planned restart restores Ghostty snapshots; `restore` returns nothing for a snapshot written by another Ghostty version, and the holder's tail was cleared at the handover, so every shell comes back near-blank and `inexact` with its history gone (full-screen programs repaint after the nudge). A c11 release that bumps the fork's Ghostty pin could do that to every live terminal. The claim that terminals survive Sparkle updates is therefore untested. Settles: a step 1 test, an update across two Ghostty pins with 20 live terminals.
14. **Descriptor limits.** V for the code, I for the cap: the holder never raises `RLIMIT_NOFILE` and keeps three descriptors per terminal (the audit); under launchd's default soft limit of 256 it would fail spawns near 80 terminals. c11 raises the limit before spawning the core.

## 5. The fork patch list

Each marked for size: S is a contained change, M needs design. All offered upstream.

1. Holder isolation: one holder per terminal, or a `--holder-per` policy (S to M). Removes issue 1.
2. Bundle mode (S): no `hc update` and no in-place swap; a named session by default; state, config and socket paths from dedicated variables that are stripped from program env; the core refuses to serve a session whose owner build differs, so a stray `hc` cannot start c11's core from another binary.
3. Sizes (S): an initial size on `terminal.run` (spike defect 6), and keep the last size when no viewer is attached, or a per-terminal headless size.
4. Queries (S): FACTS with the palette (OSC 4 from the viewer's theme); DA1 answered with the viewer's capabilities, at least `52`, or left to the viewer; XTVERSION with a version, or the viewer's; XTGETTCAP never answered in part, either a full static table in the core or the whole query passed to the viewer (spike defects 3 to 5). Hidden terminals then stop stalling programs that probe at startup.
5. Quarantine every corrupt state file, not only `docs.json` (S).
6. A `size` and line-state field on the attach stream or events (S), so a viewer learns it lost the size lead and when a machine's line is down.
7. Structured logs with timestamps (S); today: `eprintln!` lines, never rotated.
8. Per-terminal screen locks, and registry saves off the output path (M). Addresses issue 2; no design yet.
9. Remote install to a c11-owned path (`~/.c11/bin`) instead of `~/.local/bin` (S). Addresses issue 8.
10. Flood backlog (S to M): bound and measure the per-viewer backlog, and confirm the 4 MiB repaint fires for a viewer that credits after parsing (spike defect 9: 288 MB core RSS under a flood, no repaint seen).

Everything else c11 needs is on c11's side (the feature map's sidecar rows) and is needed on any daemon path.

## 6. Against the alternatives

The axes from the brief: dependency risk, fork-ability, protocol stability, version coupling, naming, interop, and what c11 must still build. Once A carries patch 1, its process model converges on B's.

| | A. hc, fork-and-track (this recommendation) | B. Build `c11d` around cmux-tui's terminal host (the Step 0 recommendation) | C. Hard fork of hc | D. Own `c11d` from scratch |
|---|---|---|---|---|
| What exists today | Core, holder, attach, federation over SSH, exec and files on remotes, 7501 status, labels, documents, events, a CLI agents can use, Linux and Windows builds | A hardened per-terminal host with exact replay, viewer arbitration and adoption; no daemon, registry, transport, federation or agent layer | Same as A at fork time | Nothing |
| Isolation | One holder per session until patched | One process per terminal | We own the patch | Our choice |
| Memory, 200 idle terminals | 79 MB total (experiment 11, V) | About 1.5 GB in a debug build (`docs/c11v-design.md`, open question 9; I) | As A | Our choice |
| Keystroke p99 under an 8-terminal flood | +2.9 ms over a direct PTY (experiment 6, V) | Not measured | As A | Not measured |
| What c11 still writes | The manual-IO backend, lifecycle, snapshots, gate, tty re-registration, status mapping; the fork patches | All of that plus the daemon itself, a protocol, TLS or SSH transport, federation, and agent verbs | As A, plus we carry every fix | As B, plus the host |
| Protocol | Generation 1 preview; growth-only promise for RPC, unguarded elsewhere | CMTH v4, stable since 2026-08-04, local only | Frozen by us | Ours |
| License and lineage | Apache-2.0; a second client of a funded open runtime | GPL-3.0 subtree into AGPL c11 (allowed); our own lineage ("pull freely") | Apache-2.0 | n/a |
| Dependency risk | One author on the core; a YC F26 company with a $6M seed (reported) and 46.7k stars on the TUI | None after the extraction; upstream host fixes cherry-pickable, and the host files have had no commits for three weeks | None after the fork; all the maintenance | None |
| Interop | c11 terminals visible to herdr-app and Heeler if the session is shared (opt-in) | None | Lost over time | None |
| Time to a working opt-in daemon terminal on Atin's fleet (I) | Weeks: the daemon is done, the c11 side remains | Months: the daemon is the work | As A, then slower | Longest |

The c11-side work (the feature map's 16 sidecar rows and the Ghostty hooks) is the same on every path. hc removes the daemon, the transport and the agent primitives from the plan, at the price of issues 1 to 4 and a dependency on a competitor's runtime. cmux-tui's host removes issue 1 at the price of writing everything around it.

## 7. Product and users

**What c11 gains.** Terminals that survive Quit, crashes and hangs (the C11-186 deadlock would have killed nothing, I); survival across Sparkle updates once issue 13 is handled; terminals on the build host and Prime boxes as ordinary panels with a host badge, at the tailnet's latency for the build host (unmeasured) and about 170 ms through Prime's gateway; status straight from the agent (Claude Code today) and the foreground process, cwd and argv of every terminal on every host; `hc` as a second CLI for agents, with run, wait, send, read, exec and file verbs across machines that c11 never had; an interop option with herdr's clients.

**What c11 stops being good at, or changes.**
- Quit no longer means stop (a menu item and a one-time note).
- Scrollback across a restart is hc's history (5 MB by default).
- Output can be dropped under floods.
- `nohup`'d jobs die with their panel unless the sweep is changed.
- Per-panel CPU, memory and ports have no remote equivalent.
- "Panel closed means process gone" becomes "process killed after a grace period".
- Every keystroke crosses two sockets.
- Hidden terminals need a viewer, or programs in them wait out their XTGETTCAP timeouts and the terminal snaps to 200x120.
- A new dependency with its own cadence, and a user-visible process tree (`hc serve`, `hc hold`) that support will have to explain.

**Migration.** As `docs/c11v-design.md` says: exec stays the default; the daemon backend sits behind a setting; an unreachable core falls back to exec with a notice (the spike's fallback already works); a snapshot with hc terminals restores in an older c11 as fresh shells (Swift ignores unknown keys), which orphans the hc terminals until the next launch reaps `c11.panel` labels nobody claims. Opt-in order: Atin's fleet, then nightly, then a setting for everyone, then default after holder isolation.

**The skill.** Terminals carry `$HC_TERMINAL_ID` beside `$C11_PANEL_ID`. `read-screen` works for hidden and remote panels. `send` keeps c11's composer guard locally and uses hc's turn-based guard (`terminal.send … if: idle`) for remote panels. `new-area --host studio` becomes `terminal.run on:` plus a placement label, applied by whichever c11 attaches. Agents may call `hc` for raw terminal work on other machines; anything the sidebar must know about goes through c11 verbs, which wrap hc. Two CLIs is a cost; herdr's own skill is 170 lines, and the risk is an agent that bypasses c11 for things c11 needs to see.

## 8. Strategic read

The facts, each reported from the source named at the end of this section unless marked V:
- The herdr TUI launched 2026-03-27 and has 46.7k stars (V, GitHub). It does not use hc; hc's own skill calls it "the older terminal multiplexer" (V).
- Can (Ogulcan) Celik joined YC's F26 batch, announced 2026-08-06, and described himself then as the only person behind herdr.
- A $6M seed led by Bessemer, reported 2026-09-08; "the runtime stays open"; the runtime moved from AGPL to Apache-2.0.
- herdr-core and herdr-app: repos created 2026-10-16, first commits 2026-10-23, releases from 2026-10-23 (V); the announcement post on X, "a brand new core and a desktop app built on it", surfaced in search dated 2026-10-30.
- The core's 39 commits are 36 by Celik and 3 by one outside contributor whose pull requests were merged the day they were opened (V, GitHub). A phone client (Heeler) is being ported to hc (issue 15 on the tracker).
- OSC 7501 is Mitchell Hashimoto's specification, implemented in libghostty; its author reports testing it with Terraform, Claude Code, Codex and Homebrew. Claude Code 2.1.314 reports through it (V, experiment 17); Codex 0.165.0 carries no 7501 strings (V).

Status from the program is becoming a terminal standard, not a herdr-ism. herdr is not a hobby project with a bus factor of one, although its core's code is.

herdr-app competes with c11 head-on for the same operator: cross-platform, GPUI, mods in JavaScript, telemetry on by default, every pane attached, no attention model beyond working, blocked, done and idle, no mailbox, journal, flags, delegates or Feed, and no TCC story (`herdr-app-read.md`). c11's moat was never the PTY plumbing. It is the operator's command center: workspaces and areas, the attention model, the agent contract (the skill), the mailbox and the journal, conversation resume, browser and markdown panels, computer-use testability, and macOS-native quality. Sharing the runtime layer the way c11 already shares Ghostty frees engineering for those. The cost is tying the substrate to a competitor's cadence, which the fork posture bounds, and the bet that hc's design (one holder, one thread) is fixed or forked before it bites.

The interop option is real and double-edged. Shared session: c11's agents show in herdr-app and Heeler, and theirs in c11, for free; but any `hc update` from their side restarts c11's core, and the last active viewer wins the PTY size between two apps. Own session by default, shared as an explicit opt-in. Naming: Apache-2.0 grants no trademark rights, so a modified bundled binary is renamed or carries their permission; the notices stay; c11 does not call itself herdr-compatible without asking.

If this is a pivot, c11 becomes the macOS operator front for a shared agent runtime, and the runtime becomes a commodity the way the VT already is. If hc stalls or forks away, c11 holds a daemon of about 17k lines of Rust plus 6.5k lines of tests that it understands end to end (V, line counts), against the roughly 22k lines Step 0 estimated for a cmux-tui host extract plus the daemon that would still have to be written around it.

Sources: the herdr announcement on X (search snippet dated 2026-10-30; the post itself could not be fetched), runtimewire.com on the seed (2026-09-08), developersdigest.tech on YC F26 (2026-08-23), herdr.dev/core, LavX News on OSC 7501 (2026-10-06); all fetched 2026-10-30.

## 9. The path, with kill criteria

Adapted from `docs/c11v-design.md` (its steps and "Keeping c11 workable" rules stand). "Atin's normal load" means his usual fleet, 20 to 30 agents across workspaces, during a working day.

| Step | Scope | Done when | Kill criteria |
|---|---|---|---|
| 0b Spike | **Done 2026-10-30 (`SPIKE-0B.md`).** Manual-IO backend on hc's attach stream, tagged build, build-host guest, a loopback machine for the remote leg. | 18 of 20 rows passed; bell and IME not drivable; added p99 +308/+280 µs idle and +324/+208 µs with 20 replay panels, against a direct-PTY baseline. | None hit. |
| 1 Hidden backend | Bundled, Stage 11-signed hc in its own session, per-tag sessions, `RLIMIT_NOFILE` raised; the backend behind an off-by-default setting, grown from the spike's `C11vSpikeBackends.swift` with its early-frame buffer, resize refresh (until a Ghostty resize hook replaces it), RESIZE ahead of the 2048 report, FOCUS conversion and FACTS on theme change; `terminal.kill` on close with grace; the `c11.panel` label reaper; Quit and End All with correct dialog copy; exec fallback that re-adopts the core when it returns; snapshot compatibility; tty re-registration; no `claude --resume` into live terminals; the fork's bundle mode, build check and query patches. Measured first: the flood repaint and core memory; a real Prime remote leg; the cost of creating 200 panels. Tests in a guest: TCC quit-and-relaunch; a Sparkle update across two Ghostty pins with 20 live terminals. | Force-quit c11 with 20 agents on Atin's machine; relaunch; every agent still running with its exact screen, sidebar detection back within 10 s. | Shells lose c11's TCC grants after a relaunch and no bundle route fixes it; the Ghostty-pin update blanks screens and patch 8's design cannot avoid it; a holder crash on Atin's fleet within the first month; keystroke p99 under Atin's normal load >1 ms added. |
| 2 Hosts | The build host over the tailnet and Prime via `--via`; host badges; `--host`; events for machine lines; remote install to a c11-owned path; the browser proxy kept on `c11d-remote`. Tests: lid closed an hour; sleep and wake; a 2FA host after a long drop. | A workspace mixing the laptop and the build host terminals; lid closed an hour; reopen and it is live. | Remote attach echo over the tailnet >20 ms at p50; reconnect loses terminals; sleep and wake needs a manual `machine login` for a key-based host. |
| 3 Default | Daemon terminals by default after holder isolation (fork or upstream) and a release cycle on the opt-in with no regression traced to it. | A release cycle on the default with no regression reports that trace to it. | Holder isolation rejected upstream and too costly to carry; sweep semantics generate support load. |
| 4 Agent state | OSC 7501 and `foreground` feed lifecycle and detection; labels carry agent-reported fields from remote hosts; c11 metadata, flags, mailbox and journal stay in c11; checked input stays c11's. | The c11 skill works from the build host terminal for report verbs. | None new; this is c11 work. |

What I would not do: move c11's metadata into hc documents; share the default session; depend on a user-installed hc; map c11 lineage onto hc's `parent`; use `terminal.read` for the composer check; pass secrets through `terminal.run.env`.

## 10. Corrections made to `docs/c11v-herdr-core.md`

Applied in place today, each a sentence or two, with this file as the source:

1. "Each terminal is a holder process that owns the PTY and screen" → one holder per core build owns every PTY; the core keeps the screen; the holder keeps a 1 MiB tail.
2. "The core can crash, restart or update while programs keep running" → still true; added that the holder restarts a crashed core itself, that a crash leaves screens `inexact`, and that a holder crash ends every program.
3. Verified item 3 → the adopted screen was rebuilt from the tail, not kept; the nudge resize makes full-screen programs repaint.
4. "c11 needs no transport code of its own" → true for bytes; line state is not in events, mirrors go stale, remote attach repaints on reconnect.
5. Mapping rows: `terminal.read` for the composer check (no), lineage onto hc `parent` (no), 7501 from the wrappers (no; Claude Code emits it itself), documents for metadata and flags (no), `history: N` as full scrollback (main screen, 5 MB by default).
6. "Stops `ps -t` detection" → that sweep also runs liveness decay, prompt-cache retention and model detection.
7. Decision 1 (bundle) → add bundle mode, own session, our signature; upstream macOS binaries are unsigned.
8. Decision 4 (TCC) → verified attribution to c11.app while c11 runs; quit-and-relaunch open; launchd-started cores are their own identity.
9. Decision 5 → the maintainer is a funded company; the risks that matter are the single holder and the single thread, not the author count.
10. "Holders are children of the hc core" → children of the core that spawned them, setsid, reparented to launchd when it dies; the holder spawns the next core.
11. Verified item 2 ("well inside budget") → at idle; under an 8-terminal flood the p99 is 3.7 ms, 2.9 ms above a direct PTY.
12. The "Delegates, waiting for workers" row → c11 state; hc's `wait --children`, notes and parent `send` are for agents that use hc directly; c11-created terminals carry `no_parent`.
13. Decision 3 ("hc documents for metadata, flags and delegate state") → in c11; labels for agent-reported fields from remote hosts.
14. Decision 5's parenthetical ("a test fails on any change that would break a released client") → the growth test covers RPC params and results only.
15. Spike 0b item 3 ("every panel reattaches with its exact screen") → exact after Quit and `kill -9` c11; `inexact` after `kill -9` the core.
16. The "Spike 0b" section → a results line (ran 2026-10-30, no kill criterion hit, report `SPIKE-0B.md`).

## Appendix: the herdr family

| Repo | What | Size, age, authorship (V unless marked) |
|---|---|---|
| `herdrdev/herdr-core` | hc, the daemon | 23,880 lines of Rust in all, including a 1k-line libghostty-vt binding crate and 6.5k lines of tests; repo created 2026-10-16, first commit 2026-10-23; 39 commits, 36 by Ogulcan Celik; v0.1.10 to v0.1.14 in six days; 109 stars, 9 open issues and pull requests; builds need Rust and Zig 0.16 |
| `herdrdev/herdr-app` | their desktop client on hc | 20.7k lines of Rust in `src/` plus 462k vendored (GPUI forks, QuickJS); 114 commits since 2026-10-23, 101 by the same author; v0.1.4 to v0.1.9; 482 stars; telemetry on by default; does not bundle hc, installs it to `~/.local/bin` after consent |
| `herdrdev/herdr` | the TUI | 46.7k stars, created 2026-03-27, its own server, 22 agent-detection manifests, not built on hc; installed on the laptop at `~/.local/bin/herdr` (Atin's, untouched) |
| Ghostty pins | hc `1e5cdb86` (ghostty-org, Zig 0.16); herdr-app `291fd05`; c11 fork `1b7bcf06` (Zig 0.15.2) | three different commits of one parser |
