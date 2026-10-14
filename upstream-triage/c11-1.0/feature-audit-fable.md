# Feature audit: c11 1.0 (Fable)

Independent audit, 2026-10-01. Read-only. c11 citations are against `origin/main` at `0ff8887e5e` (the local checkout is 36 commits behind). cmux citations are against `upstream/main` at `920ff39ff7`. Anything I did not read in code is marked (inferred). Line counts are from `git show <ref>:<path> | wc -l`.

## 1. Verdict in five lines

1. Build the lifecycle **fold**, not the journal **file**. The three incidents behind the journal (blocked looks like finished, waiting dies on restart, a late hook leaves an agent stuck on working) are fixed by typed per-tab state with an app-assigned sequence, persisted in the session snapshot c11 already writes. The durable append-only file with a synchronous ack and a spool is the C11-188 attractor, and its unique value (replay from a log, 14-day history) has no named consumer that a snapshot verb and the existing events stream do not serve.
2. Agents on remote hosts is a 1.x product, not a 1.0 feature. #490 just removed the only command channel, the persistent PTY holder is a port of about 2,600 lines of Go that cmux is still patching, and option A builds a Hyperion-owned daemon on a machine that already runs a full c11.app. Ship the smoke test, status truth and reattach in 1.0; ship the holder once, as federation's first step, after 1.0.
3. The Feed is worth it in its small form: one typed ask per tab, a CLI list, oldest-first ⌥V, flags in the menu bar, and text replies that re-read the screen first. Menu-key answering and banner buttons are "if time". The screen classifier is 1.x.
4. The grab list's hardening batch (4.1, 4.3, 4.4, 4.7, `rpc`, `guide`), stable tab numbers (4.2) and restore on the right account (4.11) are core and cheap. Groups, Recently Closed, the URL allowlist and passkeys are the items to let slip.
5. Six weeks is enough for the above plus the bug harvest, provided C11-216 (builds on Atlas) lands in week one. It is still in backlog today (`lattice show C11-216`: "Status: backlog"). Without it the fleet throttles on Hyperion's one-build lock and the plan loses a week.

Totals: 22 core, 18 if time, 20 1.x, 2 cut.

## 2. Item table

Legend. Atin / Public: H, M, L. Size: my estimate, with the report's estimate in brackets where we differ. Verdict: `core`, `if time`, `1.x`, `cut`.

### Event journal (report 01)

| # | Item | Atin | Public | Size | Risk | Cheaper alternative | Verdict |
|---|---|---|---|---|---|---|---|
| J1 | Typed lifecycle state per tab: `working`, `waiting(reason)`, `idle`, `error`; a pure fold; an app-assigned ingest sequence; state persisted in the session snapshot; a `c11 agents --json` snapshot verb | H: "which of my 30 agents is blocked on me, versus done", and waiting that survives relaunch | H | M [M] | Migration: waiting is "has an unread notification" today (`Sources/TabLivenessDeriver.swift:13-16`) and that is read by the sidebar, ⌥V (`Sources/AppDelegate.swift:10829`), suppression and the menu bar. The fold must keep writing `activity` so none of them break. C11-188 shape only if the spec says "fail closed" across process boundaries; keep the acceptance criteria to the three incidents | This is the cheaper alternative to J2 | **core** |
| J2 | A separate durable NDJSON journal under App Support, with a synchronous ack returning the sequence, a client spool on failure, a startup drain, 14-day retention | L: no workflow moment needs replay from a log once J1 persists state | L | M [M], but the review cost is unbounded | **This is the C11-188 shape.** The AAR names the trap: absolute language across "shell-wrapper → Unix-socket → in-memory-store → autosaved-file" (`docs/aar-c11-188-attention-loop.md`, Root cause). A durable ack and a spool reintroduce exactly the marker and crash-durability findings of cycles 7 and 8. cmux never drained its own dead-letter file (report 01). Two file substrates next to `events/` is also a second storage style, which D3 was trying to avoid | J1 plus `lifecycle.changed` on the existing events stream (J8) | **1.x** |
| J3 | More Claude hooks in the launch-time `--settings` file: `StopFailure`, `PermissionRequest`, `PostToolUse` (async), `SubagentStart/Stop` | H: error and subagent states stop reading as working | H | S | None new. The rail exists (`Resources/bin/claude:205-236`); cmux's set is at `CLI/CMUXCLI+ClaudeHookSettings.swift:26-90` | | **core** |
| J4 | Codex per-process hooks | H: Codex shows working on every Return today (`Resources/bin/codex:173-233` injects only `notify`) | H | S to M [M] | The two reports disagree on mechanism. Report 01 proposes computing Codex's `trusted_hash`; report 03 proposes `--dangerously-bypass-hook-trust`. The installed 0.159.3 has that flag ("Run enabled hooks without requiring persisted hook trust for this invocation", `codex --help`) and `codex features list` shows `hooks stable true`. Use the flag: no private hash format to drift. It means c11 vouches for its own bundle scripts, which is fine. Keep the "no session.started within 5 s" canary regardless | | **core** |
| J5 | Transcript-derived `turn.started` / `turn.completed` / `turn.interrupted` at transcript confidence, for Codex and Grok | H: Grok shows working for its whole life today; Grok is a third of Atin's fleet | M | M [part of M] | The tail exists and runs off-main on the 10 s detector sweep (`Sources/AgentModelDetection.swift:18, 183-280`); it already parses Claude, Codex, pi, omp, Grok and OpenCode and excludes only kimi and copilot (`:132-138`). Risk is double-reporting when a hook and the transcript both fire; the source rank handles it. Esc-interrupt detection is (inferred) | | **core** |
| J6 | Gemini wrapper and agent kind, hooks via `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` | L: not in Atin's fleet | M | M | New wrapper, new kind, six-locale strings. The env var and merge behavior are unverified on both reports | | **if time** |
| J7 | omp `--hook` extension | L | L | S | Unverified whether omp loads `pi-lifecycle.ts` unchanged | | **1.x** |
| J8 | Consumers: `lifecycle.changed {tab, agent, from, to, reason}` on the events stream (closes C11-231), clocks from state, restore candidate list, skill update | H: Overwatch subscribes instead of polling `read-screen` (Overwatch's skill today: "`read-screen` + `c11 tree`/metadata ... universal, optical, fragile", `overwatch/skills/overwatch/SKILL.md:129`) | M | S to M [S to M] | The events stream drops appends past 4,096 pending and rotates at 8 MiB (`Sources/Events/EventLog.swift:51-52`). That is fine for telemetry; it is why J2 wanted its own file. For Overwatch the snapshot verb is the truth and the stream is the wake-up | | **core** |
| J9 | Screen observation tier for Kimi, Copilot and hookless TUIs | L: none in Atin's fleet once J5 covers Grok | M | L [M to L] | "Classify any TUI's screen" is an open-ended correctness target with no fixed point, the same class of hazard as C11-188 but on the input side. Needs a fixture corpus per TUI per version | J5 for agents with transcripts; nothing for the rest | **1.x** |
| J10 | The doctrine sentence (D5): per-process hooks carrying lifecycle and attention payloads are inside the wrapper rule; disk writes and decisions are not | H: stops every reviewer reopening the question | M | S | None | | **core** |

### Feed (report 03)

| # | Item | Atin | Public | Size | Risk | Cheaper alternative | Verdict |
|---|---|---|---|---|---|---|---|
| F0 | Phase 0 bugs. (a) Claude hooks clear the whole workspace: confirmed at `CLI/c11.swift:16852, 16934, 17042` (`clear_notifications --tab=<workspaceId>`). **Plus a fourth site the reports missed:** the stale-pid sweep clears every notification in the workspace when any one agent pid is gone (`Sources/WorkspaceManager.swift:1222`). (b) Menu bar extra ignores flags: confirmed, `MenuBarExtraController(notificationStore:)` is its only input (`Sources/AppDelegate.swift:8108-8138`). (c) Bypass-mode AskUserQuestion never enters waiting: the pre-tool-use handler saves the question and returns, trusting a Notification hook that (inferred from cmux #6606) never fires under bypass (`CLI/c11.swift:17006-17040`) | H: with six agents per workspace (a) fires constantly | H | S | None | | **core** |
| F1 | One typed ask per tab (`kind`, `prompt`, `options`, `source`, `opened_at`, `state`), `ask.opened` / `ask.closed` events, `c11 feed list / open / watch` | H: one cross-workspace list; Overwatch reads it as JSON | H | M [M] | This is the same field as J1's `waiting(reason)`. The plan counts it twice (journal phase 1 and Feed phase 1). One ticket. The "one record per tab" store already exists (`Sources/TerminalNotificationStore.swift:636-674`, in memory, not Codable) | | **core**, merged with J1 |
| F2a | ⌥V oldest-first everywhere; flags and open-ask count in the menu bar extra | M | M | S | None | | **core** |
| F2b | The ⌘I popover rebuilt as a keyboard-first quick view | M: Atin drives through agents and CLI more than through popovers | H | M [M] | Fixed-height rows, six-locale strings. Low risk | `c11 feed list` in a terminal tab | **if time** |
| F3a | `c11 feed answer <tab> --text` for turn-end, input and flag rows: `read-screen`, confirm the prompt line holds no unsent operator text, then `send`, then `lower-flag` with the answer attached | H: reply without switching panes, and the flag carries its answer (C11-184's unshipped "reply on lower") | M | S | Ghost auto-suggest reads as typed text (`skills/c11/references/api.md`); the empty-prompt check must know that. `read-screen` on never-shown tabs depends on bug track D and C11-235 | | **core** |
| F3b | Menu-key answering for question, plan and permission rows, with a per-agent, per-version fixture table | M to H: AskUserQuestion is the ask that actually reaches a bypass-mode fleet | M | M [M] | A wrong digit in a 30-agent fleet is a stop-ship. TUI drift. Each Claude release needs a fixture refresh. Verify-then-type with fail-to-jump bounds it | F3a plus jump | **if time** |
| F4 | Banners with buttons and text input, routed through F3 | M: Atin's phone path is ntfy, not macOS banners | M | S to M | UNNotification categories are routine; the 4-action ceiling applies | | **if time** |
| F5 | Codex, omp and Gemini attention hooks | | | | Same work as J4, J6, J7 | | merged |
| F6 | Screen classifier for hookless agents | L | L | M [M] | Same hazard as J9 | | **1.x** |

### Agents on remote hosts (report 02)

| # | Item | Atin | Public | Size | Risk | Cheaper alternative | Verdict |
|---|---|---|---|---|---|---|---|
| R0 | Smoke-test today's `c11 ssh` against Atlas; make the skill tell the truth | H: nothing has exercised it since the fork beyond CI's `remote-daemon-tests` (`.github/workflows/ci.yml:63`) and the docker suites in `tests_v2/test_ssh_remote_*.py` | M | S | May already be broken | | **core** |
| R1 | Persistent PTY holder in `c11d-remote`, harvested from cmux's Go daemon | H: survives a lid close | L: public users have no Atlas | L [M to L] | c11's daemon is 1,136 non-test lines (`daemon/remote/cmd/c11d-remote/main.go` 1,105, `cli.go` 31). cmux's is 14,299, with `ws_pty.go` at 2,637 and `main.go` at 3,251. `ws_pty.go` has carried fixes steadily from July to September (`git log upstream/main -- …/ws_pty.go`: #8643, #8677, #9111, 05f3e1a0a9, four September hardening commits). This is a port, not a cherry-pick. Replay-mid-escape artifacts, resize races and orphaned slots are the known failure classes | tmux on a c11-owned socket (R1b), which `Resources/bin/c11-spawn-agent` already does on Atlas (C11-37, done) | **1.x** |
| R1b | Interim holder: `tmux -L c11`, status off, no user config, reattached by `c11 ssh atlas` | H | L | S to M | The scrollback, mouse and escape-passthrough problems the Overwatch seat work hit. Acceptable for agents nobody types into | | **if time** |
| R2 | Command channel multiplexed over the ssh stdio link | M | L | M [M] | #490 removed the forwarding path; `WorkspaceRemoteCLIRelayServer` now refuses every command after auth (`Sources/Workspace.swift:3118-3130`). This is a rebuild of a security-sensitive surface in a public product. Head-of-line blocking behind proxy traffic | None if R1 is deferred: there is nothing to carry | **1.x** |
| R3 | Scoped, deny-by-default dispatch on the Mac | M | L | M [M] | 242 socket methods to classify (`Sources/SocketHandlers/SystemHandlers.swift:26-292`). cmux's `RemoteRelayCommandPolicy` is 233 lines plus a routing schema, and it took three PRs to land. New methods must default to denied or the hole reopens | Report-only verbs (`set-agent`, `set-status`, `set-description`, `raise-flag`, lifecycle hooks) is a six-method allowlist, S, if R1b ships | **1.x** |
| R4 | Remote CLI verbs generated from a shared table, wrappers uploaded to `~/.c11/bin`, the `--settings` merge | M | L | M [M] | Go and Swift CLIs drifting; Claude's last-`--settings`-wins | | **1.x** |
| R5 | Host-aware status: skip `kill(pid, 0)` eviction and `ps -t` detection for remote tabs; a "link down" state | H: today a remote agent's status is evicted by the Mac sweep (`Sources/WorkspaceManager.swift:1200-1225`; `Sources/AgentDetector.swift:7`) | M | S | Stale working after a silent remote death | | **core** |
| R6 | Persist remote workspaces, reconnect and reattach on restart | H: today they are dropped from the snapshot (`Sources/WorkspaceManager.swift:5639`, `.filter { !$0.isRemoteWorkspace }`) | M | M [M] | Restart while the link is down | Type the stored resume command when the holder is gone (already host-agnostic) | **if time** |
| R7 | Per-tab host model | M: `launch-agent --host atlas` is what an orchestrator wants | L | L [L] | Remote configuration is a `@Published` property of `Workspace` (`Sources/Workspace.swift:4998, 7602`) with its own session controller; moving it to the tab touches the model, sidebar, tree and skill right after the C11-248 rename and while the sidebar is under hang investigation (C11-197, C11-202 both backlog) | One remote workspace per host, which is what exists | **1.x** |
| R8 | `c11 move <tab> --to host` (Claude, then Codex) | M: rare moment | L | M + S [M + S] | cmux's mover is about 940 lines across `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentMove/` and ignores `CLAUDE_CONFIG_DIR`; Atin's three profiles and Atlas's different username are new ground. Code applied before data, no rollback, in cmux | `rsync` the transcript and `claude --resume` by hand on the other side | **1.x** |
| R9 | Prime transport override for Overwatch seats | M | L | S [S] | Needs R2 and R3 first; Prime's stdio quality is unverified | PR comments, which work today | **1.x** |
| R10 | Federation: Atlas's c11.app owns the agents, Hyperion attaches | H: this is the end state both reports name | L | XL | State-of-record inversion, cross-instance auth | | **1.x** |
| R11 | **New.** A read-only cross-host fleet view: Hyperion's c11 polls `c11 tree --report` and `flag.list` on Atlas's c11 over ssh and shows an "Atlas" section in the sidebar with marks, flags and jump-to-Screen-Sharing | H: Atlas already runs c11.app with full citizenship (`overwatch/SEAT-MODEL.md` §1, C11-244); the missing piece is one sidebar for both machines | L | M | Polling cost; read-only so no security surface | This is federation step 0 and what the phone rung 3 wants too | **if time** |

### The grab list (report 06)

| # | Item | Atin | Public | Size | Risk | Cheaper alternative | Verdict |
|---|---|---|---|---|---|---|---|
| 4.1 | Reject non-canonical routing keys | H: a misspelled key acts on the focused tab today | H | S [S] | Breaking an old script; the C11-248 alias seam already defines what is legal | | **core** |
| 4.2 | Stable tab numbers across restarts, never reused | H: tab numbers are spoken ("send that to 292") | M | M [M] | Counters start at 1 per launch (`Sources/TerminalController.swift:283-288`) and refs are re-minted by dictionary iteration (`:2632-2645`). The seed must run before any restore minting | cmux's reserved blocks, which break the spoken workflow | **core** |
| 4.3 | `--command` on `new-split`, `new-area`, `new-tab` | M | M | S [S] | `initial_input` arrives before rc files finish (inferred) | | **core** |
| 4.4 | `send --raw`, stdin, `paste` alias, reject unknown flags, document delivery | M | M | S [S] | `--raw` must be off by default. The result fields already exist (`Sources/SocketHandlers/SurfaceHandlers.swift:977-979`) | | **core** |
| 4.5 | `read-selection` (terminal) | M: "look at what I highlighted" | M | S [S] | Browser selection needs an injected script; keep it terminal-only | | **if time** |
| 4.6 | `resize-window` | L, except for computer-use runs in Tart guests (C11-244) | L | S [S] | None | | **if time** |
| 4.7 | `--window` routing without focus side effect | M: it is a focus-policy violation today | M | S [S] | Callers relying on the side effect | | **core** |
| 4.8 | Batch `reorder-workspaces --dry-run` | L | L | S [S] | Pinned segments | Only needed if groups ship | **1.x** |
| 4.9a | `c11 rpc` and `c11 guide` | H: `guide` fixes the stale-installed-skill problem that is a HARD RULE in `CLAUDE.md`; `rpc` replaces ad hoc `nc` | H | S [S to M] | None | | **core** |
| 4.9b | Feature flags in `capabilities` | M | M | S | The list drifts from dispatch unless generated (cmux #16460) | | **if time** |
| 4.10 | `c11 config doctor` | L | L | S [S] | Low value unless people hand-edit `agents.json` | | **1.x** |
| 4.11 | Restore on the right account; skip reasons; launcher routers | H: today the wrapper never captures `CLAUDE_CONFIG_DIR` (grep of `Resources/bin/claude` finds none) and resume types a bare `claude --resume` (`Sources/Conversation/Strategies/ClaudeCode.swift:57`), so a Bravo tab silently comes back on whichever call-sign is selected | M | M [M] | Quoting env into a typed command; an exhausted pinned account resumes worse than today (D14 says say so, never switch) | Pin the dir only, skip launchers (step 4) | **core** |
| 4.12 | Workspace groups, folder model | M: one group per Lattice run | M | L [L] | cmux's is about 2,300 lines across `Sources/*WorkspaceGroup*` plus a 582-line coordinator, and it needed about ten anchor fixes (the folder model avoids those). The SwiftUI sidebar is a `LazyVStack` / `ForEach` over every workspace (`Sources/ContentView.swift:8535-8536`) and is the subject of two open hang tickets; headers add rows and drop targets. Six-locale strings | Workspace color and pin, which exist | **if time** (ruled in scope; the likeliest slip) |
| 4.13 | Focus history on "seen" with a dwell threshold; `c11 history` readable by agents | M to H: D20's Overwatch signal is real | M | M [M] | cmux's `FocusHistoryModel` is 637 lines; c11's workspace-only history exists at `Sources/WorkspaceManager.swift:1085-1088, 3886-3943` and `TabSeenTracker` persists stamps (`Sources/TabSeenClock.swift:70, 165`). Shortcut churn (D16) | `c11 history --json` without the keys | **if time** |
| 4.14 | Recently Closed and Cmd+Shift+T for every tab kind | M | M | L [L] | cmux's store is about 1,500 lines (`ClosedItemHistory*.swift`, `DockSplitStore+ClosedItemHistory.swift`); persisted scrollback; double resume if the original tab also restores. #469's close confirmations and #467's ten session files already cover the loss case | Keep both safety nets | **1.x** |
| 4.15 | Browser profiles CLI | M: a clean login per agent task | M | S [S] | `BrowserProfileStore` exists (`Sources/Tabs/BrowserTab.swift:341, 436`) | `state.save/load` | **if time** |
| 4.16 | Browser import smoke test and a non-interactive path | L | M | S [S] | Never decrypt cookies without the Keychain prompt | | **if time** |
| 4.17 | Browser URL allowlist | L | M | M [M] | Only the insecure-HTTP allowlist exists (`:663`); subframes must be covered or it is cosmetic | The C11-140 C subframe fix on its own | **1.x** |
| 4.18 | Browser crash recovery | M | H: the macOS 26 crash took down every terminal for cmux users | S to M [S to M] | One shared `WKProcessPool` (`:1969`); the recovery hook exists (`webViewWebContentProcessDidTerminate`) | | **core**, via bug track E |
| 4.19 | Passkeys | L | M | L [L] | Blocked on Apple; inside-out signing touches the release skill | Apply for the entitlement now, zero code | **1.x** (apply now) |
| 4.20 | User/auto title lock plus derived workspace names | M | M | S to M [S to M] | The lock changes rename semantics everywhere titles are written | The lock alone (S) | **if time** |

### Phone (report 04)

| # | Item | Atin | Public | Size | Risk | Cheaper alternative | Verdict |
|---|---|---|---|---|---|---|---|
| P0 | Flag-notification fix: flags reach the menu bar; the Notification Command gets `C11_NOTIFICATION_WORKSPACE_ID`, `TAB_ID`, `KIND` (the `CMUX_` names kept as aliases); it fires for flags before the banner result | H: it makes every rung below better and corrects the skill | M | S [S] | `TerminalNotificationStore` is a busy path; today's env is three `CMUX_` vars (`Sources/TerminalNotificationStore.swift:516-521`) | | **core** |
| P0b | "Only when away": `C11_OPERATOR_PRESENT` in that env, from screen lock and `last_seen_at` | M | L | S | None; the signal exists (`Sources/TabSeenClock.swift:119`) | | **if time** |
| P1 | ntfy rung 1 (paste one `curl` into Settings) | H | L | none | Noisy until P0 lands | | **cut** from 1.0: Atin does it today, no code |
| P2 | ntfy rung 2 forwarder on `events tail` | M | L | S, outside c11 | Rotation handling | | **1.x**, in Overwatch |
| P3 | Tailnet web view | M | L | M, in Overwatch | A write path to agent PTYs on the tailnet | | **1.x**, in Overwatch |
| P4 | Native iOS app | L | L | XL | cmux's 1,800 commits | | **cut** |

### Items the plan bundles that deserve their own row

| # | Item | Atin | Public | Size | Risk | Verdict |
|---|---|---|---|---|---|---|
| X1 | C11-216: c11 builds on Atlas | H | none | M | Still "backlog" in Lattice; nothing started. Every other item queues behind Hyperion's build lock until it lands | **core**, week 1 |
| X2 | `send` draft guard: refuse to type when the prompt line holds unsent operator text or the agent is blocked on a dialog, with a clear error (cmux `surface.input_state`, `cmuxCLITests/CLISendDraftGuardTests.swift`) | H: Atin types in one pane while agents `send` into others | M | S | The same screen check F3a needs | **if time** |
| X3 | Events cursor that survives restart, with a `gap` flag (cmux #15030); c11's `seq` resets per process | M: Overwatch's heartbeat loop | L | S | None | **if time** |
| X4 | Mailbox delivery through hooks instead of PTY injection (cmux #15279) | H, but C11-257 is already in progress on this | M | M | Overlap with C11-257 | **1.x**, fold into C11-257 |

## 3. The six-week 1.0

Assumptions: 6 to 8 Codex and Grok workers, cross-family reviews, builds and soaks on Atlas, two Atin sign-off passes. The bug harvest takes about two workers for the first two weeks and tapers.

**What ships in 1.0.0:**
- Lifecycle truth: J1, J3, J4, J5, J8, J10, with F1 merged into J1.
- Feed: F0, F2a, F3a. F2b, F3b and F4 only if weeks 5 and 6 are clear.
- Remote: R0, R5. R6 and R1b if time. No daemon work.
- Grab list: 4.1, 4.2, 4.3, 4.4, 4.7, 4.9a, 4.11, 4.18 (via bugs). Then, in this order if time: 4.20 lock, 4.13, 4.15, 4.5, 4.6, 4.9b, 4.16. Groups last.
- P0, X1, and the bug harvest's tracks A to E.

**Week by week:**

| Week | Critical path | In parallel |
|---|---|---|
| 1 | **X1 Atlas builds.** Record real hook sequences from a tagged build (Claude in bypass and normal mode, Codex, Grok) as the fixture corpus for J1 | F0 and P0 as one bug batch (point release). Grab batch 1: 4.1, 4.3, 4.4, 4.7, 4.9a (3 or 4 PRs, Grok). R0 smoke test against Atlas. Bug track A (Ghostty patch set, Codex) |
| 2 | J1 design review (cross-family, before code), then J1 implementation. Acceptance criteria name the three incidents and nothing else | 4.2 stable refs. 4.11 restore accounts. Bug tracks B and C. J3 Claude hooks |
| 3 | J1 lands behind the existing `activity` writer, so nothing downstream changes until the fold is trusted. J4 Codex hooks, J5 transcript events | F2a. R5 and R6. Bug tracks D and E. J10 doctrine sentence and skill updates |
| 4 | J8 consumers: `lifecycle.changed`, `c11 agents --json`, clocks. F3a text replies. First integrated dev build on Atlas | 4.20 lock, 4.13 or 4.15 (one worker each). First 40-agent, 48-hour soak on Atlas with hang telemetry |
| 5 | **Atin sign-off pass 1.** Fixes from it | F2b or F3b if the pass is clean. R1b if time. Localization pass for every new string (six locales, parallel sub-agents) |
| 6 | Freeze. Second soak (72 h). **Sign-off pass 2.** Release engineering, skill sync (`scripts/sync-installed-skills.sh`), 1.0.0 | Groups do not start in week 6 |

**The critical path** is X1 → fixture corpus → J1 → J8 → sign-off. Everything else hangs off it or runs beside it. If J1 slips a week, drop F2b, F3b, F4 and R1b and the release still holds.

**What does not ship:** J2, J9, R1 to R4, R7 to R10, 4.8, 4.10, 4.14, 4.17, 4.19 (entitlement applied for), P2 to P4.

## 4. Red team

### Against the event journal

The strongest honest case:

1. Each motivating incident has a smaller fix. "Blocked looks like finished" is a reason enum on the notification record. "Waiting dies on restart" is persisting that record in the session snapshot, which already persists `activity` (`Sources/PersistedMetadata.swift:159-176`) and seen stamps. "A late PreToolUse lands after Stop" is a per-tab sequence the app assigns at ingest, because the app is already the single writer. None of those needs a file.
2. The file is where C11-188 lives. The AAR's root cause is absolute acceptance language across a wrapper, socket, store and file boundary. The proposal's "synchronous ack returning the sequence", "spool on failure" and "drain on next start" are the marker and transaction machinery of cycles 6 to 8, under new names. A thorough reviewer will find a crash window between the spool write and the ack, and will be right.
3. cmux's own history shows the hard part is semantics, not storage. With the journal in place they still shipped #15173, #15666, #15887 and #16257 for late tool results, pending background work and delayed reminders. The fold is 125 lines (`AgentLifecycleReducer.swift`); the package around it is 3,390. The package is where the time goes.
4. History has no consumer. Overwatch wants "who is blocked, on what, for how long", which is a snapshot verb. The phone wants the same. Nobody has asked to replay last Tuesday.
5. c11 already has a file-first stream. A second one next to `events/` is the "second storage style" D3 was trying to avoid, just in NDJSON instead of SQLite.

**Does it win?** Against the file, the ack and the spool: yes. Against the typed state, the fold, the ingest sequence and snapshot persistence: no. Those four are the fix for the incidents, they stay in memory plus the snapshot c11 already trusts, and their acceptance criteria can be stated as three fixture replays. The recommendation in section 1 is that split.

### Against agents on remote hosts

The strongest honest case:

1. The command channel was removed yesterday. #490 turned `WorkspaceRemoteCLIRelayServer` into a refusing endpoint (`Sources/Workspace.swift:3118-3130`). Slices 2 to 4 rebuild a remote-to-Mac command surface, deny by default, in a public product, inside the same release that just closed a hole in the old one. That deserves its own release and its own security review.
2. The holder is a port, and the source is still moving. c11's daemon is 1,136 non-test lines; cmux's is 14,299. The persistent PTY lives in a 2,637-line `ws_pty.go` with fixes landing through September. Nothing in c11 has exercised the daemon since the fork beyond unit tests.
3. It builds the wrong direction. Both reports say the end state is federation: Atlas's c11.app owns its agents and Hyperion attaches. Atlas already runs c11.app with full citizenship (the Overwatch seat model puts the orchestrator inside it; C11-244 runs Tart guests there). Option A spends L to XL on a Hyperion-owned daemon on Atlas, then federation retires it. The PTY holder gets built twice.
4. The public gets nothing. Public users have no Atlas and no tailnet; Linux hosts are a 1.0 stretch by D12. Every remote slice is Atin-only value in 1.0.
5. The per-tab host model (L) rewires `Workspace` while the C11-248 rename is a week old and the sidebar has two open hang tickets.
6. The interim already exists. `Resources/bin/c11-spawn-agent` runs Claude in `tmux -L agents` on Atlas today (C11-37 done). The gap is sidebar citizenship, and a read-only cross-host view (R11) closes most of it with no daemon and no security surface.

**Does it win?** For 1.0, yes. Ship R0, R5, R6 and the skill truth; put R11 in the "if time" lane; defer every daemon slice. It does not win for 1.x: Atin's direction is agents off Hyperion, a holder is needed eventually, and C11-186's detachable surfaces need the same component. Build it once, on the Atlas side, as federation's P1.

## 5. Dependencies and sequencing

**What unlocks what:**
- X1 (Atlas builds) unlocks the fleet. It is first and it has not started.
- The fixture corpus (recorded hook sequences from a tagged build) unlocks J1. The AAR's amplifier 2 was "no empirical oracle"; record before designing.
- J1 unlocks F1 (same field), F2a, F3a, J8, and the `c11 agents --json` verb Overwatch and the phone both read.
- J3, J4, J5 feed J1 but can land in any order behind it.
- 4.2 (stable refs) unlocks 4.13 (persisted history) and 4.14 (reopen with the old number).
- 4.11 (restore accounts) unlocks 4.14 (reopen on the right account) and R8 (`move` across profiles).
- Bug track D (`read-screen` on cold tabs) and C11-235 (PTY at creation) unlock F3a and F3b, which read the screen of background tabs before typing.
- R1 or R1b unlocks R2, R3, R4, R9. Without a holder there is nothing to carry.
- D21's sidebar measurement unlocks 4.12 (groups). Groups on a sidebar that is about to be rewritten is wasted work.

**Mis-sequenced in section 7:**
1. **Journal phase 1 (P1) and Feed phase 1 (P2) are one ticket.** The ask is the `waiting(reason)` state. Building them in different phases means two stores for one fact.
2. **Remote command channel and scoped dispatch (P2) before the terminal holder (P3).** The holder decides the transport (stdio multiplexing versus tmux) and gives the channel something to carry. The order is holder, then channel, or neither in 1.0.
3. **Sidebar measurement (P3) after groups are planned for P3.** Measure in P1 so groups know what they are built on.
4. **Feed phase 5 (Codex, omp, Gemini hooks) in P3** is journal phase 2 work scheduled in P2. Same tickets, two names.
5. **The doctrine sentence (D5) is not in any phase.** Land it in week 1 so no review of J3, J4 or J5 reopens it.
6. **Localization is not budgeted.** Feed, groups and the quick view add dozens of strings across six locales. Give it week 5.
7. **The fixture recording is not a step.** It is the oracle for everything in J1; it belongs in week 1 on a tagged build.

## 6. Decisions I would change

| # | Plan | I would answer | Why |
|---|---|---|---|
| D1 | Yes, build the journal under guardrails | Yes to the fold, typed state, ingest sequence and snapshot persistence. No to a separate durable file with ack and spool in 1.0 | Section 4. The file is the C11-188 attractor; the state is the fix |
| D2 | Codex hooks with a trusted-hash bypass and a canary | Yes, but with `--dangerously-bypass-hook-trust`, which 0.159.3 ships (`codex --help`), not a computed hash | No private format to drift; the canary stays as a cheap check |
| D3 | A plain NDJSON journal file | The session snapshot for state; the existing events stream for history (`lifecycle.changed`) | One file substrate, not two |
| D4 | Transcript reading yes, screen reading later | Transcript reading yes, scoped to turn edges for Codex and Grok. Do not promise screen reading in 1.0 docs | J9 is an open-ended target |
| D9 | A remote agent is a tab | One remote workspace per host in 1.0, which is what exists | Per-tab is L on a freshly renamed model; moot if federation is the end state |
| D10 | c11's Go daemon holds the terminals, ported from cmux | No holder work in 1.0. tmux on a c11-owned socket if time. The Go holder is built once, Atlas-side, after 1.0 | Section 4 |
| D11 | No federation in 1.0; build so it follows | Agree, and build the read-only cross-host view (R11) as federation step 0 instead of option A's channel | It is what Overwatch and the phone want, with no security surface |
| D16 | Cmd+[ and Cmd+] become focus history everywhere; browser Back and Forward move | Focus history on those keys except when a browser tab is focused | Cmd+[ is browser Back in every macOS browser; retraining public users for a feature they may not use is a cost. Context-dependent chords are normal on macOS |
| D21 | Measure the sidebar in P3 | Measure in P1 | Groups depend on the answer |
| D25 | Ship the small bug batch now | Agree, and add the fourth workspace-wide clear at `Sources/WorkspaceManager.swift:1222` | The reports missed it |
| D26 | C11-216 first | Agree, and say plainly that it has not started | The six weeks start when it lands |
| D27 | Codex and Grok only; the lead orchestrates | Keep, with one rule: J1's spec gets a cross-family plan review before code, and the review-cycle cap is three, hard | The AAR's amplifier 1 was the breaker being overridden |

Decisions I agree with and would not reopen: D5, D6, D7, D8, D12, D13, D14, D15, D17, D18, D19, D20, D22, D23, D24.

## 7. Missing

**cmux work the plan skipped that I would argue back in:**
1. **Draft guard on `send`** (X2). cmux's `surface.input_state` refuses to type over unsent operator text. For a 40-agent fleet where Atin is typing in one pane while agents `send` into others, this is the single cheapest safety improvement, and F3a needs the same screen check.
2. **A restart-surviving events cursor with a `gap` flag** (X3, cmux #15030). Atin ruled `cmux events` out, but this is a fix to c11's own stream, not the cmux command. Overwatch's heartbeat loop needs it; C11-230 to C11-233 are already filed.
3. **Agent messages through hooks, not keystrokes** (cmux #15279). c11's mailbox delivers by PTY push only at a shell prompt, so it almost never reaches a running agent. C11-257 is in progress on this; make sure it reads #15279 before inventing a second design.
4. **Replay policy** (cmux `AgentJournalReplayPolicy`, 41 lines): on relaunch repaint only blocked and error, never running. Already in the report; keep it when J2 is dropped, applied to the snapshot.
5. **"Only when away" delivery** (P0b). cmux's one push feature worth copying; c11 already has the signal.

**What 1.0 should have that cmux does not:**
1. **`c11 agents --json`**: one verb returning, per tab, kind, model, state, reason, since, flag, suppressed, host and `last_seen_at`. Overwatch, the phone view and any orchestrator read this instead of scraping `tree` plus `get-metadata` plus `read-screen`. cmux has no equivalent; its Feed and journal are two separate reads.
2. **A fleet soak as a release gate**: 40 agents, 72 hours, on Atlas, with hang telemetry and memory curves, before 1.0.0 is cut. Green tests are not a working product. cmux ships without this and its changelog shows it.
3. **The skill as the contract, verifiable**: `c11 guide` printing the skill that matches the running build, and the installed-copy check in `c11 doctor`. cmux has `guide`; c11 has the sync problem that makes it matter.
4. **Flags with answers**: `flag.lowered` carrying the reply text and `resolution: answered`. cmux has no flag model at all.
5. **A cross-host fleet view** (R11) that composes existing primitives over ssh, with no daemon, no account and no relay.

**One thing the plan should say out loud:** the clock does not start until C11-216 lands. Everything in section 3 assumes it does in week one.
