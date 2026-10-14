# 01 · Event journal as the source of agent status

**Needs you:**

1. **Do we reopen a lifecycle reducer, given C11-188?** A journal is a reducer: semantic events in, marks out. The C11-188 reducer ran eight failing review cycles and was reverted (`docs/aar-c11-188-attention-loop.md`), and our standing rule is to escalate before that shape comes back.
   - **Yes:** build the journal under the guardrails in "Effort and risk": acceptance criteria tied to recorded incidents, recorded hook sequences as the test oracle, and no epochs, fences or transactions.
   - **No:** ship the "small version" instead: richer hooks, a reason on waiting, and waiting that survives restart, all on today's in-memory model. That fixes most visible bugs but gives no history, no replay and no fleet query.
   - **My recommendation:** yes.
2. **Codex: may the wrapper trust its own hooks on the command line?** Codex 0.159 reads hooks from `-c` flags, but it only runs hooks whose hash is marked trusted. That trust mark can also be passed with `-c`, so c11 can give Codex the same hooks as Claude with nothing written to disk.
   - **The catch:** c11 has to compute a hash in Codex's private format. When Codex changes that format, the hooks silently stop firing and c11 falls back to today's `notify` signal.
   - **Yes:** Codex gets turn start, approval and subagent events.
   - **No:** Codex stays at "Return key means working, notify means idle" plus transcript reading.
   - **My recommendation:** yes, with a canary that detects the fallback.
3. **Where does the journal live?**
   - **(a) A dedicated append-only NDJSON journal**, separate from today's events log. **My recommendation.** It is file-first and greppable like the rest of c11.
   - **(b) A SQLite journal like cmux's.** It is proven upstream and easy to query, but it is a second storage style in c11.
   - **(c) Extend today's events log.** It is one substrate, but that log drops events under load and rotates at 8 MiB, so it is too lossy to be the source of truth.
4. **Should c11 1.0 include an outside-observation tier for agents with no hooks?** This affects Kimi, Copilot, and Grok until its hook path is verified. The tier reads the terminal screen and transcript.
   - **Yes:** those agents get honest working, idle and blocked marks instead of "working for the whole life of the TUI". It is the PHILOSOPHY-preferred shape.
   - **No:** they keep today's shell-state heuristic until a later release.
   - **My recommendation:** yes for transcript reading; screen reading later.
5. **Should CLAUDE.md say plainly that lifecycle hooks injected per process are allowed?**
   - **Today's wording:** the wrapper exception allows "lifecycle status where the TUI exposes it". Claude, OpenCode and pi already rely on that.
   - **Yes:** one sentence settles that per-process flags and environment variables are inside the line, and disk writes stay outside it. Future agents stop reopening the question.
   - **No:** it stays implied.
   - **My recommendation:** yes, as part of this work.

**Recommendation in one line:** build a c11 lifecycle journal. Feed it only from per-process hooks (flags, environment variables and plugins at launch, never config files), from transcript reading, and from the existing shell signals. Derive working, waiting, idle and error from it with a small pure fold. Scope it to recorded incidents so it cannot become C11-188 again.

---

## Answer to the lead's hypothesis

> If c11 injected hooks only through the launch command line, would that give cmux-grade lifecycle events with zero tenant config writes?

**Mostly yes, and c11 already does this for four agents.** cmux's own Claude integration works the same way: its wrapper injects a `--settings` blob per launch and writes no Claude config (`CLI/CMUXCLI+ClaudeHookSettings.swift` on upstream/main). cmux writes tenant config only for Codex (`~/.codex/hooks.json` plus a flag in `config.toml`), Gemini, Grok, Cursor and the rest (`docs/agent-hooks.md`).

Verified per CLI:
- Every CLI below was checked against `--help` from the version installed on Hyperion.
- Where the mechanism lives in source, I read the source too.
- Rows marked unverified were not run.

| Agent (installed) | Per-process hook path | Zero disk writes? | c11 uses it today? |
|---|---|---|---|
| Claude Code 2.1.287 | `--settings <file>` merges with the user's settings. Inline JSON drops hooks on 2.1.x, so use a temp file (`Resources/bin/claude:207-236`). | Yes (temp file only) | Yes, 6 events (`Resources/bin/claude:205`) |
| Codex 0.159.3 | `-c hooks.<Event>=[...]` lands in the session-flags config layer. Trust comes from `-c 'hooks.state."<key>".trusted_hash="..."'`, which Codex also reads from session flags (openai/codex `codex-rs/hooks/src/config_rules.rs:15-50`, `engine/discovery.rs:666-720, 796-813`). Hooks feature is `stable true` (`codex features list`). | Yes | No: `-c notify=...` only (`Resources/bin/codex:157-217`) |
| OpenCode | Plugin passed via the `OPENCODE_CONFIG_CONTENT` env var | Yes | Yes (`Resources/bin/opencode:73-92`) |
| pi | `--extension <file>` | Yes | Yes, 2 events (`Resources/bin/pi-lifecycle.ts:33-34`) |
| omp | `--hook=<file>` and `-e/--extension=<file>` (`omp --help`) | Yes | No (`Resources/bin/omp` has no hook) |
| Gemini 0.26.0 | `GEMINI_CLI_SYSTEM_DEFAULTS_PATH=<file>`. Hook arrays merge with `CONCAT` across settings layers (`settingsSchema.js:1519+`). Hooks are on by default (`:998`, `hooksConfig.enabled`). Only project hooks are trust-gated. | Yes | No wrapper, and no Gemini agent kind at all |
| Grok 1.0.46 | `--plugin-dir <dir>` ("for this process only... always trusted: hooks... activate without a prompt"), but `--help` lists it only under `grok agent`, not the interactive TUI. The `GROK_CONFIG` env overlay may carry hooks, but it has a key allowlist. **Unverified.** | Unknown | No (identity and conversation id only) |
| Kimi 2.1.0 | Has hooks (the binary carries Stop, UserPromptSubmit and others). The only path override found is `KIMI_CODE_HOME`, which relocates the whole home and hides the user's config. **No clean path found.** | No | No wrapper |
| Copilot | Not installed here. **Unverified.** | Unknown | Wrapper declares identity only |

So:
- **Claude, OpenCode and pi** already sit at cmux grade on the input side. Their gap is what c11 does with the events, not how it gets them.
- **Codex, Gemini and omp** can reach cmux grade with no disk writes.
- **Grok, Kimi and Copilot** cannot today. They need the observation tier (question 4).

---

## What cmux built

Everything here was read from `upstream/main` at `920ff39ff7` (2026-10-01), mainly `Packages/macOS/CmuxAgentJournal/` and `Sources/AgentJournalLifecycleCenter*.swift`.

### The pipeline (#10490, merged 2026-08-22)

1. **Hooks emit.** Every hook action in the CLI (`runClaudeHook`, `runGenericAgentHook`) sends exactly one semantic event over a new synchronous socket verb, `agent_journal_append` (#10490 body; `CLI/CMUXCLI+AgentJournalEmission.swift`).
   - The reply is the committed sequence number, a durable acknowledgement.
   - If the CLI cannot prove which pane it belongs to, it sends the event as **unattributed** and never guesses.
   - If delivery fails, the event goes to `~/.cmuxterm/agent-journal-dead-letter.jsonl`. Nothing ever reads that file back (follow-up never built).
2. **Mapping.** `AgentSemanticEventMapper` turns a native hook name into one of 15 semantic kinds (`AgentJournalEventKind.swift`). There were 12 at launch; `idle.observed`, `attention.resolved` and `message.published` came later.
   - Names are normalized: lowercase, alphanumerics only, so `SubagentStop`, `subagent_stop` and `on-subagent-stop` collapse to one key.
   - `AskUserQuestion` and `ExitPlanMode` on PreToolUse become question and plan-review events.
   - Per-agent special cases cover opencode, antigravity, hermes, and the copilot/codebuddy/factory trio.
   - Anything else becomes `agent.state.changed`, which never moves state by itself (`AgentSemanticEventMapper.swift`).
3. **Store.** One SQLite table, `agent_journal`, with an `AUTOINCREMENT` sequence and a unique `event_id` (`AgentJournalStore+Schema.swift`).
   - `UPDATE` and `DELETE` are blocked by triggers.
   - It runs WAL with `synchronous=FULL`.
   - At open it prunes to 100,000 rows once the table exceeds 200,000 (`AgentJournalStore.swift:34-36`).
   - Alias tables map old surface and workspace IDs to new ones after session restore.
   - The file is `~/Library/Application Support/cmux/agent-journal-<bundle-id>.sqlite3`.
4. **Fold.** `AgentLifecycleReducer` is a pure function (`AgentLifecycleReducer.swift`).
   - For each session, the newest event by sequence wins. Duplicates and stale arrivals drop.
   - Subagent events never change the host pane.
   - A pane shows the most demanding live session: `running > backgroundWorkPending > needsInput > error > unknown > idle` (`AgentLifecyclePhase.swift`).
   - `session.ended` clears the session.
5. **Single writer, single consumer.** The app commits appends on the socket worker, then applies results on one FIFO queue in journal order. A replay can never land after a newer live event (`AgentJournalLifecycleCenter.swift:4-16`).
6. **Replay on launch.** `AgentJournalReplayPolicy` repaints only `needsInput` and `error`, because those stay true across a restart. `running` is dropped, since a relaunch killed the PTYs. `idle` and `unknown` are dropped so dead agents don't become hibernation-eligible.
7. **The text heuristics are gone.** The old classifier fabricated "needs your attention" for empty notifications. That path was deleted.

### What grew on it since (follow-up PRs)

| PR | What it added |
|---|---|
| #11976 | Notification admission goes through the journal (`AgentNotificationReconciler`), deduping repeated attention events. |
| #14870 | Crash recovery: `cmux session restore [--list]` finds sessions with a `started` but no `ended` whose process is gone (`AgentJournalSessionTail.swift`). |
| #15232 | Claude `StopFailure` journals `agent.error.reported`. |
| #15666, #15887 | A `backgroundWorkPending` phase. PreToolUse and PostToolUse keep a turn running, and `Task` shows as "subagents". |
| #15173, #16257 | Fixes for late events: a late tool result reopened a finished turn, and a delayed reminder flipped idle back to needs-input. |
| #15216 | Workspace auto-reorder on meaningful lifecycle transitions (`AgentLifecycleActivity.swift`). |
| #15373 | Auto-resume: types `continue` after retryable upstream failures, backing off 20 s, 45 s, 90 s, 3 min, 5 min (`AgentAutoResumePolicy.swift`). |
| #15279 | Agent-to-agent messages delivered through hooks, never keystrokes (`AgentMessageStore.swift`). |

Still not done: a sidebar error rendering (error still shows as needs-input, per `AgentJournalLifecycleCenter+Projection.swift`), draining the dead-letter file, and retiring `set_agent_lifecycle`.

### Agents with no hooks

On the Mac app the journal gets nothing for them. This is a deliberate rule: "No unreliable fallback... never terminal-title string matching" (`docs/agent-session-tracking-spec.md`). They get only `cmux notify` and OSC notifications.
- Two PRs that would add screen and process sources are open: #15276 (`AgentActivityClassifier` with sources hook, transcript, screen and process) and #10952.
- The cmux-tui daemon does have screen detection, ranked "hook > plugin > detected" (#13299, #14902).

### How `cmux events` relates

It is **not** a view of the journal.
- `cmux events` streams the in-process `CmuxEventBus` over a socket subscription (#3629, `Sources/CmuxEventBus.swift`). Its cursor is a global sequence that now survives restarts (#15030).
- Clients persist the cursor with `--cursor-file`, and a `gap` flag says "resync from snapshot".
- `--reconnect` retries every second.
- The journal's semantic kinds never appear on that stream. Only journal health diagnostics (`agent.journal.append_failed` and similar) do.
- Automations (#10654) also consume the bus, not the journal.

So cmux has two substrates: a durable journal for truth and a bus for telemetry. That split is the useful idea. The `events` command itself is out of scope per Atin's ruling (README).

### The SSH wrinkle

Agents on SSH hosts take two other routes.
- **Default `cmux ssh` (#14902):** a daemon on the host folds the hooks and projects badges straight into the sidebar, bypassing the Mac journal (`Sources/RemoteTui/SSHTuiAgentStatusProjector.swift`).
- **Relay-backed `cmux ssh` (#14974):** Claude lifecycle hooks are forwarded through the relay into the Mac's hook queue. (Inferred) those then journal like local hooks.

Topic 02 owns this. The point here is that a journal designed now should accept events from a remote producer.

---

## What c11 has today

### How the mark is computed

`SurfaceTabActivityResolver.resolve` (`Sources/SurfaceLivenessDeriver.swift:4-35`) checks in this order:
1. An unread notification on the surface means **waiting**. If the surface is suppressed and not flagged, it means idle instead.
2. A non-agent terminal gets no mark.
3. `cold` means idle with no touch for 600 s (`Sources/SidebarStalenessSettings.swift:99-127`). It is recomputed on a 10 s sweep.
4. Otherwise the persisted `activity` metadata value applies: `working` or `idle`.

So **waiting is not a state. It is "has an unread notification."**

### What moves `activity`

All inputs end in `SurfaceLivenessDeriver.onAgentLifecycleChanged` (`SurfaceLivenessDeriver.swift:155-189`).

| Input | Effect | Where |
|---|---|---|
| `c11 agent-hook working\|idle` (socket `report_agent_activity`) | Exact edge, sent by wrappers and plugins | `CLI/c11.swift:3189, 16136`; `SocketDispatch.swift:425-454` |
| **Any Return keypress** in a terminal, any kind | Sets working | `GhosttyTerminalView.swift:5627-5636` (and `:4059` for text-box and socket submit) |
| Any notification added for a surface | Sets idle (and makes it waiting while unread) | `TerminalNotificationStore.swift:990-1001` |
| OSC 9/777 desktop notification | Becomes a notification, so waiting plus idle | `GhosttyTerminalView.swift:2248-2281` |
| Shell integration preexec and precmd | Running or prompt. An agent TUI keeps the shell "running" for its whole life. | `cmux-zsh-integration.zsh:207-217` |
| 45 s no-activity decay | Plain shells only. **Agent kinds are exempt.** | `SurfaceLivenessDeriver.swift:250-258` |

### Per agent

| Agent | Working comes from | Idle comes from | Blocked on human |
|---|---|---|---|
| Claude | `UserPromptSubmit` and `PreToolUse` hooks | `Stop` and `Notification` hooks | Indistinguishable from "finished": both are idle plus a notification |
| Codex | **Return key only** | `notify` callback (thread-id guarded, C11-189) | Not seen |
| OpenCode | Plugin `chat.message`, `session.status` | Plugin `session.idle` | Plugin `permission.asked` sends a notification |
| pi | Extension `agent_start` | Extension `agent_settled` | Not seen |
| Grok, omp, Copilot, Kimi | Shell "running" for the TUI's whole life, plus the Return key | Return key or OSC only | Invisible unless the TUI emits OSC |
| Gemini | No agent kind exists | | |

### Delivery semantics

- **Fire and forget.** Hooks are separate `c11` processes with a 0.75 s timeout. The v1 status verbs ack before running (`asyncAckV1Commands`, `TerminalController.swift:2141-2144`, from the C11-156 main-thread stall). Claude's `PreToolUse` is `async:true`.
- **No ordering.** Nothing orders events across hook processes. (Inferred) a late async `PreToolUse` can land after `Stop` and leave a finished agent marked working. cmux hit the same class of bug in #15173 and #15887.
- **Persistence is partial.** `activity` is persisted (`PersistedMetadata.swift:130-176`), although `references/metadata.md:38,281` says it is not. Notifications are not persisted (inferred, since `TerminalNotification` has no save path), so **waiting does not survive a restart**. A persisted `working` survives for agents with no launch-time idle reset (Grok, Kimi, Copilot, omp).
- **No replay.** Nothing rebuilds marks from history.

### The events stream (`c11 events tail`)

- **Format.** File-first NDJSON at `~/Library/Application Support/c11/events/events-<instance>.ndjson`, one file per app process (`Sources/Events/EventLogLayout.swift:96-110`).
- **Rotation and loss.** One rotation at 8 MiB (`EventLog.swift:169-204`). Appends are dropped when more than 4,096 are pending (`EventLog.swift:72-137`).
- **Kinds.** There are 16 (`EventEnvelope.swift:46-65`).
  - Lifecycle appears only as `liveness.derived {state}` on a real change, plus workspace-level `waiting.entered|left`, which **carry no surface**.
  - `cold` and the final presented mark are never evented.
- **Reading.** The CLI polls every 0.25 s and handles rotation. Consumers keep their own `seq`, which resets per process. The app never reads the stream back.
- **Open tickets:** C11-230 (no agent identity on envelopes), C11-231 (waiting lacks surface and reason), C11-232 (retention by time; title churn erased six hours of history), C11-233 (no heartbeat on long gaps).

### Transcript reading already exists (origin/main, #463)

`Sources/AgentModelDetection.swift` tails Claude, Codex, pi, omp, Grok and OpenCode session files every 10 s, reading only newly appended bytes. It finds turn starts (`task_started`, user prompts), assistant and tool events, and tokens (`:342-448`). It feeds only the tab sheet's clocks, never the mark. It is a ready-made observation source.

---

## The gap

| Concern | cmux | c11 |
|---|---|---|
| Input vocabulary | 15 semantic kinds, normalized mapping, error and blocked as first-class | Two verbs (`working`, `idle`) plus "a notification exists" |
| Finished vs blocked on human | Distinct (`turnCompleted` vs `approval/question/planReview`) | Same mark (C11-231 backlog) |
| Error | Journaled (StopFailure) | Not modeled |
| Interrupt (Esc) | Not modeled either | (Inferred) stays working: Claude's documented `Stop` does not fire on user interrupt, and agent kinds never decay |
| Ordering | Single writer, sequence order, newest per session wins | None across hook processes |
| Late or duplicate events | Dropped by the fold, plus later semantic fixes (#15173) | Last writer wins |
| Subagent isolation | Structural (`is_subagent` field) | Codex thread-id guard only (C11-189) |
| Survives restart | needsInput and error replay | Waiting is lost and stale working survives |
| History | 100k events, queryable | Telemetry log, lossy, per process |
| Codex | Hooks via `~/.codex/hooks.json` (tenant write) | Return key plus notify |
| Hookless agents | Nothing on the Mac app | Shell state plus Return key plus OSC |

c11 is **not** behind on inputs for Claude, OpenCode and pi. It is behind on what happens after an input arrives.

---

## Proposed c11 1.0 shape

### Doctrine fit, stated plainly

- **The input side sits inside the existing wrapper exception.** CLAUDE.md allows wrappers to capture "lifecycle status where the TUI exposes it" (`CLAUDE.md:82`), and Claude, OpenCode and pi already do. Widening it to Codex, Gemini and omp uses the same per-process mechanism, with no disk writes.
- **It is still an exception to PHILOSOPHY.md's "observe from outside" principle**, and it now covers seven agents instead of four. I think that is the right call: exact edges like "blocked on approval" cannot be observed reliably from outside. But it is a widening, so it is question 5.
- **No agent text goes in.** The journal stores kinds, IDs, timestamps and a bounded detail string, so c11 still never knows what the agent is thinking.
- **Codex self-trust is the one new judgment** (question 2). It writes nothing, but it steps around a gate Codex built.

### Components

**1. One semantic vocabulary.** Adopt cmux's kinds nearly verbatim: `session.started|ended`, `turn.started|completed`, `approval|question|plan_review.requested`, `attention.resolved`, `error.reported`, `child.spawned|completed`, `idle.observed`, `state.changed`.
- Add one kind cmux lacks: `turn.interrupted`.
- Add a `source` field with a confidence rank: `hook > plugin > transcript > screen > shell > keypress`.
- Using the same names as cmux keeps future comparisons and imports cheap.

**2. Producers, per agent.** All are per process; nothing touches tenant config.

| Agent | Producer | Notes |
|---|---|---|
| Claude | Extend the `--settings` hook file with `StopFailure`, `PermissionRequest`, `PostToolUse` (async), `SubagentStart/Stop`, `PreCompact` | Mirrors cmux's set (`CMUXCLI+ClaudeHookSettings.swift`) |
| Codex | `-c hooks.*` plus `-c hooks.state.*.trusted_hash` for SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, Stop, Interrupt, SubagentStart/Stop. Keep `notify` as the fallback. | Canary: if no `session.started` arrives within ~5 s of launch, mark the adapter degraded and use notify plus transcript |
| OpenCode | Existing plugin, re-pointed at the new append verb | Already has permission and error events |
| pi | Existing extension, plus tool and error events if pi exposes them | |
| omp | Pass the pi extension via `--extension` (inferred compatible, since omp is a pi fork; verify) | |
| Gemini | New wrapper and agent kind. Hooks file via `GEMINI_CLI_SYSTEM_DEFAULTS_PATH`. Events: BeforeAgent, AfterAgent, Notification, SessionStart/End. | If the operator already sets that variable, merge their file into ours rather than replace it |
| Grok | Verify `--plugin-dir` on the TUI and `GROK_CONFIG` hooks; otherwise the observation tier | Grok also reads Claude's hook files (`compat.claude.hooks`); worth checking that c11's Claude hooks don't double-fire under Grok |
| Kimi, Copilot | Observation tier | |
| Any agent | Transcript tail (exists on origin/main) emits `turn.started/completed` and `turn.interrupted` at `transcript` confidence | Fills Codex and Grok gaps; also catches interrupts (inferred: Claude writes an interrupt marker line to the transcript) |
| Any agent | Agent self-report: `c11 agent-event <kind>`, a thin skill-documented verb | The doctrine's standard pattern; optional, never relied on |
| Plain shells | Existing shell integration | Unchanged |

The Return key drops from "sets working" to a `keypress`-confidence hint. It counts only for agents with no stronger source.

**3. Store.** A dedicated append-only NDJSON journal under `~/Library/Application Support/c11/journal/` (question 3).
- **One writer, the app.** It assigns a global sequence that survives restarts.
- **Idempotent.** Each event carries its own `event_id`, and the fold drops duplicate IDs.
- **Retention by time:** 14 days. That answers C11-232 for this stream.
- **Durability bar, stated honestly:** survives an app crash. It may lose the last write on a kernel panic. That bounded promise, not "fail closed on every edge", is what keeps us out of C11-188.

**4. Append verb.** `agent.event.append` is handled off main on the socket worker. It writes to the file on a serial queue, returns the sequence, and applies the fold result with `main.async`, consistent with c11's socket threading policy.
- The hook CLI waits briefly for the sequence.
- On failure it writes to a local spool, and the app drains that spool on the next start. cmux never built that drain; it is a few dozen lines.

**5. Fold.** A pure function, ported in spirit from `AgentLifecycleReducer`.
- Newest event per session by sequence. Subagents excluded. A pane shows its most demanding live session.
- It produces one of `working`, `waiting(reason)`, `idle` or `error` per agent per pane.
- `cold` stays a time projection on top, now computed from the last event's timestamp.

**6. Waiting changes meaning.**
- **Blocked** (approval, question, plan review) comes from the fold. It stays set until the agent moves on, even if the operator looks at the tab.
- **Unread completion** stays a notification and clears on view.
- Both render as waiting, but they carry a `reason`. That closes C11-231 and fixes "viewing a blocked tab clears waiting".

**7. Replay.** On launch, repaint only blocked and error, as cmux does. The fold also answers "which sessions were live when we died", which feeds restore.

**8. Telemetry stays separate.** The events stream keeps its role. The fold emits `lifecycle.changed {surface, agent, from, to, reason}` into it, so `c11 events tail` consumers see per-surface marks. That partly closes C11-231.

### Alternatives

| Option | Pros | Cons |
|---|---|---|
| **A. Full journal (above)** | Fixes ordering, blocked vs finished, restart, history, and Overwatch queries in one substrate. Matches cmux's vocabulary. | Size L. Reopens a reducer (question 1). |
| B. Small version: more hooks, a reason enum, persist waiting, no journal | Size M. Fixes the most visible bugs. | No ordering, history, replay or fleet query. Overwatch keeps scraping. We would likely build A later anyway. |
| C. Port cmux's package wholesale (SQLite, reconciler, auto-resume, messages) | Fastest path to parity. | It is 3.4k lines in the package plus the app wiring, with a Feed and CodeRouter-shaped surface c11 does not want. It also brings policy (auto-typing `continue`) into the host. |

**Recommendation: A**, built in the phases below, with C used as a reference for test cases rather than as code.

---

## What the journal unlocks

- **Overwatch.** "Who is blocked, on what, for how long" becomes one fold over a file. A `c11 agents --json` snapshot (or a journal tail) replaces screen scraping. The phone view in topic 04 and Overwatch's attention router both read the same truth.
- **Accurate clocks.** `turn` is `turn.started` to `turn.completed`. The time-in-state labels ("waiting 6m") come from event timestamps instead of app memory, so they survive restart. `Active` gets a provider-neutral source.
- **Restore.** Crash recovery can list sessions with a start and no end, like cmux #14870. That feeds C11-25 hibernation and the restore hardening already in scope.
- **Notifications.** Admission becomes a fold. That dedupes repeats, explains the GAF-13 class structurally, and gives topic 03 (replies from banners) a clean "blocked on what" payload.
- **Send safety.** `c11 send` can refuse to type into a pane whose agent is blocked on a dialog, like cmux's Draft Guard (`docs/cli-contract.md`, `surface.input_state`).
- **Flags.** A flag could auto-raise when an agent sits blocked past a threshold. That is policy, so it is left for later.

---

## Effort and risk

| Phase | Size | Content |
|---|---|---|
| 1. Vocabulary, store, append verb, fold, replay | M | Map today's existing signals (Claude hooks, OpenCode, pi, Codex notify) into it. Blocked vs finished split. |
| 2. Producer widening | M | Claude extra hooks, Codex session-flag hooks with canary, Gemini wrapper and kind, omp extension, transcript events |
| 3. Consumers | S to M | `lifecycle.changed` events, an agents snapshot verb, clocks from the journal, restore candidate list, skill updates |
| 4. Observation tier | M to L | Screen and process sources for Kimi, Copilot and Grok. Can trail 1.0. |

**What could go wrong**

1. **C11-188 again.** That loop came from absolute acceptance criteria applied across a wrapper, socket and file boundary.
   - Guardrails:
     - Every acceptance criterion names an observed incident (GAF-13, stale working after Esc, waiting lost on restart, Stop vs permission).
     - The oracle is **recorded real hook sequences** from tagged builds, replayed as fixtures through the pure fold.
     - There is one ordering mechanism, the writer's sequence: no epochs, fences, markers or transactions.
     - The review cycle cap is a hard stop.
   - cmux needed later semantic fixes too (#15173, #16257). Expect some, and fix them as fixture cases, not new machinery.
2. **Codex hash drift.** It fails silently, which is why the canary exists. Each Codex update needs one smoke test.
3. **Hook latency.** Synchronous append on every hook. C11-156 showed a mass resume can stall main. The worker-lane design plus a short client timeout plus the spool keep this off main. Claude's PreToolUse stays async.
4. **Double events.** For example Grok reading Claude's hooks, or transcript and hook both reporting a turn. The fold must prefer the higher-confidence source per session; the `source` rank handles this.
5. **Migration.** Today's `activity` metadata, `liveness.derived` events and notification-as-waiting all have readers (sidebar, tab sheet, skill docs). Phase 1 keeps writing `activity` from the fold so nothing downstream breaks.
6. **Doc drift found on the way:**
   - `references/metadata.md:38,281` says `activity` is not persisted, but it is.
   - `references/events.md` says `seq` starts at 0, but the first line is 1.
   - Fix both regardless.

---

## Open questions

1. Reopen a reducer under the C11-188 guardrails? (Needs you, question 1.)
2. Codex self-trust via `-c` hash? (Needs you, question 2.)
3. Journal storage: NDJSON, SQLite, or the events log? (Needs you, question 3.)
4. Observation tier in 1.0? (Needs you, question 4.)
5. Write the per-process hook rule into CLAUDE.md? (Needs you, question 5.)
6. Does `grok` (the TUI) honor `--plugin-dir` or `GROK_CONFIG` hooks? This needs a one-off test in a scratch pane. If yes, Grok moves from the observation tier to hooks.
7. Does omp load `pi-lifecycle.ts` unchanged? One test. Same consequence for omp.
8. Should the journal accept events from a remote producer from day one, for agents on Atlas over SSH? It shapes the append verb's attribution rules, so it should be settled with topic 02 before phase 1.
9. Auto-resume after capacity errors (cmux #15373): leave it out of 1.0 as policy that belongs above the host? I'd leave it out. The journal would make it a small add later.
10. Mailbox delivery through hooks instead of keystrokes (cmux #15279): this is a real c11 mailbox improvement that the producer layer enables. Is it in scope here or in a separate topic?
