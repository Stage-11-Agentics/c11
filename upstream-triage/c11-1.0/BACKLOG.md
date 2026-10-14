# c11 1.0 backlog

2026-10-01. The prioritized work list for c11 1.0. It comes from Atin's rulings on D1 to D27, the two feature audits (Fable, Astra) and the six research reports. Each item is researched lightly: enough for a ticket writer to turn it into a full Lattice ticket without redoing the research.

**Tiers:**
- **P0:** first, because everything else leans on it.
- **P1:** core 1.0.
- **P2:** 1.0 if time. Each P2 item must be individually releasable and never hold the release.

**Sizes:** relative effort for one agent: S small, M medium, L large. The run is planned in waves, not calendar time; Atin expects it close to overnight.

**Sources:**
- Reports `01` to `06` in this folder.
- `feature-audit-fable.md` and `feature-audit-astra.md`.
- c11 at `origin/main` (`0ff8887e5e`), and cmux at `upstream/main` (`920ff39ff7`).

## Rulings that shaped this list

| Decision | Ruling |
|---|---|
| D1 | **Build the journal**, with strong analytics. This overrides both auditors, and analytics answers their objection that the journal had no consumer. The C11-188 guardrails stay. |
| D2 | Codex per-process hooks: yes. |
| D3 | Deferred to the lead. Decision: a **SQLite journal** (WAL, system `libsqlite3`, which c11 already links) with an NDJSON export. Analytics needs queries and deduplication, and NDJSON would mean rebuilding a database. |
| D4 | Transcript status for hookless agents: yes. |
| D5 | Doctrine rule: yes. |
| D6 | No blocking bridge. |
| D7 | Flags first, then oldest. |
| D8 | Turn-ends sit behind a filter. |
| D17 | **Workspace groups are core.** Test them carefully. |
| D20 | **Agents can read `c11 history`,** so focus history is core. |
| D26 | Atlas builds first. |
| D27 | Workers are Codex and Grok only. |
| Out | D11 (federation; maybe Overwatch). D12 (Linux). D13 (call-signs are not a c11 concept). D14 (restore accounts). D15 (stable tab numbers). D16 (keybinding change). D18 (naming). D21 (sidebar rewrite). D23 (upstream Ghostty offer). D24 (phone). D25 (separate point releases: everything ships in 1.0). |
| Later | D19, passkeys, in a later release. D22, GPU reclaim, only if the soak shows a clear bug. |
| 1.1 | D9: remote hosts and Prime sandboxes as c11 tabs. Both the design spike and the build move to 1.1. |
| Agreed | D10: no lid-close work in 1.0. Long-lived agents go in Atlas's own c11, and Atin keeps Macs awake with Caffeine. The terminal holder is 1.1. |

---

## Foundation (P0)

**F1. c11 builds on Atlas.** Existing ticket **C11-216** (backlog). P0, M.
- Move tagged builds, test runs and release builds off Hyperion.
- Build mode starts when this lands. Until then the run stays in planning mode, with no builds on Hyperion.
- Acceptance: a delegator gets a tagged artifact from Atlas without building on Hyperion.

**F2. Fleet soak harness as the 1.0 release gate.** P0, M.
- **What it runs:** 40 mixed agents (Claude, Codex, Grok) for an overnight run on Atlas.
- **What it records:** hang telemetry, memory and IOSurface curves, a typing-latency baseline, and restart cycles.
- **16 GB run:** one run on a 16 GB Mac (or a constrained host).
- **Also answers D21 and D22:** sidebar and GPU memory get measured here, with no separate work.
- **Baseline first:** produce a baseline on current `main` in wave 1. Pre-register the budgets before any candidate is measured.

**F3. Hook fixture corpus.** P0, S.
- Record real hook and lifecycle sequences from tagged builds as replayable fixtures:
  - Claude in bypass mode and in normal mode;
  - Codex;
  - Grok;
  - OpenCode.
- The fixtures include the known incidents:
  - bypass-mode AskUserQuestion and ExitPlanMode;
  - a late async PreToolUse after Stop;
  - Esc interrupts;
  - restart while waiting;
  - one sibling's tool start clearing another's waiting state.
- This is the test oracle for the journal and Feed. Sources: report 01 "Effort and risk"; Fable §3 week 1.

## Journal and analytics (P1)

Guardrail for this whole workstream: every acceptance criterion names an observed incident or an analytics question. No absolute "fail closed across every boundary" language. Review cycles are capped at three. Source: `docs/aar-c11-188-attention-loop.md`.

**J1. Journal spec and cross-family plan review (spike).** P1, M. Depends on F3.

The spec covers:
- **Vocabulary:** cmux's kinds plus `turn.interrupted`, and a `source` with a confidence rank.
- **Ordering:** app-assigned sequence plus the source's occurrence time. Astra's counterexample must pass: Stop gets 10, a late PreToolUse gets 11, and the agent must not flip back to working.
- **Store:** SQLite WAL in App Support, with idempotent `event_id`s.
- **Retention:** by time and by byte budget.
- **Privacy:** no prompt or tool bodies.
- **Honest states:** `unknown`, `disconnected`, `degraded`.
- **Replay policy:** on relaunch, repaint only blocked and error, shown unconfirmed.
- **Migration:** keep writing `activity` so the sidebar, ⌥V and suppression are untouched.

Sources: report 01 §"Proposed c11 1.0 shape"; Astra §4 "Against the event journal"; Fable §4; upstream `Packages/macOS/CmuxAgentJournal/`.

**J2. Journal store, append verb, fold, replay.** P1, L. Depends on J1.
- The `agent.event.append` socket verb runs off main and writes on a serial queue.
- The fold is pure, and its result is applied on main asynchronously.
- If the socket is down, the client spools and the app drains the spool at startup.
- Acceptance: F3's fixtures replay to the expected marks.

**J3. Claude producer widening.** P1, S to M. Depends on J2.
- Add `StopFailure`, `PermissionRequest` (observe only), async `PostToolUse`, `SubagentStart` and `SubagentStop`, and `PreCompact` to the per-process `--settings` file in `Resources/bin/claude`.
- AskUserQuestion and ExitPlanMode at PreToolUse become blocked asks in bypass mode.
- Source: report 01 producer table.

**J4. Codex per-process hooks.** P1, M. Depends on J2.
- Use `--enable hooks` with `-c hooks.*`.
- Decide trust with a probe:
  - **The proof required:** `--dangerously-bypass-hook-trust` trusts only c11's own hooks, and nothing from the operator's `~/.codex`.
  - **If that can't be proven,** stay on `notify`.
- A canary marks the adapter degraded if no `session.started` arrives.
- Sources: report 03 §"Lead's hypothesis"; Astra D2.

**J5. Transcript producers.** P1, M. Depends on J2.
- Emit `turn.started`, `turn.completed` and `turn.interrupted` at `transcript` confidence for Codex and Grok, from the existing `AgentModelDetection` tailer.
- These are advisory: shown with their source, and never treated as proof that an agent is blocked.
- Handle the tailer's 4 MiB backlog skip honestly.

**J6. Journal consumers.** P1, M. Depends on J2.
- `c11 agents --json`, per tab: kind, model, state, reason, since, source, freshness, flag, suppressed, `last_seen_at`.
- `lifecycle.changed {tab, agent, from, to, reason}` on the existing events stream. This closes C11-231.
- Waiting gains a reason, with "blocked" kept separate from "unread completion".
- The tab-sheet clocks read from the journal.
- A list of sessions that were live at crash, for restore.

**J7. Analytics.** P1, M. Depends on J2. Atin's explicit ask.
- `c11 stats`, or `c11 journal query`, answers by agent, model, workspace and time window:
  - time in each state;
  - how long agents wait before the operator responds;
  - blocked minutes;
  - turns per hour;
  - errors and interrupts;
  - stall outliers.
- Output as JSON and a readable report.
- Overwatch and Glideslope-style dashboards must be able to consume it.
- An NDJSON export lets the data be grepped.

**J8. Doctrine and skill.** P1, S.
- **The bounded per-process hook rule (D5),** in both `CLAUDE.md` and `PHILOSOPHY.md`: optional, non-blocking observations; no tool bodies, no answers, no trust broadening.
- **Skill updates for the new verbs.**
- **Doc drift fixes:**
  - `references/metadata.md`: `activity` is persisted.
  - `references/events.md`: `seq` starts at 1.

## Attention and Feed (P0/P1)

**A1. Attention bug batch.** P0, S to M. These bugs were found during research and ship with 1.0 (D25).
- **Workspace-wide notification clears,** at four sites:
  - `CLI/c11.swift:16852, 16934, 17042` (on origin/main);
  - `Sources/WorkspaceManager.swift:1222`.

  Scope each clear to the tab.
- **Bypass-mode questions and plans never enter waiting.**
- **The menu bar extra ignores flags.**
- **Notification Command carries no IDs:** add `C11_NOTIFICATION_WORKSPACE_ID`, `_TAB_ID` and `_KIND`, and keep the `CMUX_*` names as aliases.
- Source: report 03 "Bugs a Feed would expose"; report 04 question 3.

**A2. Typed ask per tab and `c11 feed`.** P1, M. Depends on J2, or ships on the existing notification record first.
- **The ask:** `kind`, `prompt`, `options`, `source`, `opened_at`, `state`.
- **Commands:** `c11 feed list|open|watch`.
- **Events:** `ask.opened` and `ask.closed`.
- **Read-only:** no automatic answering.
- Source: report 03 "Data: an ask on each surface".

**A3. One attention order.** P1, S.
- ⌥V and the Feed share one order: flags first, then oldest.
- The menu bar extra shows flags and the open-ask count.

**A4. ⌘I quick view.** P1, M. Depends on A2.
- A keyboard-first Feed view, with fixed row geometry so nothing jumps.
- Finished turns sit behind a second filter (D8).

**A5. Draft guard.** P2, S to M.
- An input-state check that tells the operator's unsent draft apart from Claude's faint auto-suggest. It ports the idea of cmux's `surface.input_state`.
- `send` reports or refuses when a draft is present.

**A6. Text replies.** P2, S. Depends on A5.
- `c11 feed answer <tab> --text` for turn-end, input and flag rows.
- `flag.lowered` carries the answer text.

## CLI and socket (P1)

**C1. Reject non-canonical routing keys.** P1, S to M.
- Use C11-248's `LegacyWireAliases` seam.
- An unknown routing key returns `invalid_params` with the canonical name.
- Source: report 06 §1a; cmux #13214.

**C2. `--command` on `new-split`, `new-area` and `new-tab`.** P1, S.
- Pass it through Ghostty's `initial_input`.
- Move `new-workspace --command` onto the same path.
- Source: §1c; cmux #9614.

**C3. `send` delivery contract.** P1, S.
- `--raw`, `-` for stdin, and a `paste` alias.
- Reject unknown flags.
- Document `delivered`, `queued` and `submitted`.
- Source: §1d.

**C4. `read-selection` for terminals.** P1, S.
- Off main, using cmux's response shape.
- Source: §1e; cmux #10022.

**C5. `--window` routing without a focus side effect.** P1, S.
- Source: §1g; `CLI/c11.swift:1950`.

**C6. `c11 guide`, `--skill` and capability feature flags.** P1, S to M.
- Print the skill bundled with the running build, plus build identity.
- A versioned `features` list in `capabilities`.
- Source: §1i.

**C7. `c11 rpc` and `resize-window`.** P2, S.

**C8. `launch-agent` long-prompt stall.** P1, S, bug.
- A long `--prompt-file` launch left the shell at a `>` continuation prompt for 40 minutes on 2026-10-01 (tab:113).
- Find out whether it is quoting or the bracketed-paste split (bug harvest top-10 #4).
- Deliver long prompts by file reference.

**C9. Small doctrine and process fixes.** P1, S.
- `claude-teams` hands Claude an ignored SIGPIPE: reset it before exec (`CLI/c11.swift:17639`).
- Stop writing `c11-notify.js` into `~/.config/opencode/plugins/` (`Sources/SkillInstaller.swift:58-61`). The wrapper already loads it per process.

## Workspaces and navigation (P1)

**W1. Workspace groups: model, persistence, CLI.** P1, L.
- **Model:** `WorkspaceGroup {id, name, color, icon, isCollapsed, isPinned}` and `Workspace.groupId`.
- **Persistence:** saved in the session snapshot.
- **CLI:** `c11 workspace-group list|create|rename|delete|ungroup|add|remove|move|collapse|expand|pin|unpin|set-color|set-icon|focus`, with `--json`.
- **`tree`** shows groups.
- **Batch move:** `reorder-workspaces --order --dry-run`, folding in 4.8.
- **No auto-filing by root** (cut).
- Source: report 06 §3; cmux #4815, #5018.

**W2. Workspace groups: sidebar.** P1, L. Depends on W1.
- **Header:** chevron, icon, name, member count.
- **Attention badge:** violet if any member is flagged, plus the waiting count excluding suppressed tabs, plus unread. A flag inside a collapsed group must stay visible.
- **Interaction:** drag to join or leave, and a context menu.
- **Strings:** six locales.
- **Model:** keep the folder model. Avoid cmux's anchor-workspace model and its follow-up bugs (#5253, #8925, #9176, #13688, #15892).

**W3. Workspace groups: validation.** P1, M. Depends on W1 and W2. Atin asked for careful testing.
- 50+ workspaces with no typing-latency regression, measured against F2's baseline.
- Drag-and-drop edge cases, pinned segments, and restore round-trips.
- A computer-use pass on a tagged build that drives the real sidebar.
- Written as a numbered script for Atin's sign-off pass.

**W4. Focus history and `c11 history`.** P1, M.
- Built on "seen" (`TabSeenTracker`, C11-243) with a dwell threshold, not on raw focus.
- `c11 history [--json] [--limit]` is readable by agents (D20). Back and forward are commands.
- Keys are rebindable, and the browser's Cmd+[ and Cmd+] stay as they are (D16 is out of scope).
- History persists across restart, keyed by UUID.
- Source: report 06 §4a.

## Browser (P1/P2)

**B1. Browser crash recovery.** P1, S to M.
- Harden the existing `webViewWebContentProcessDidTerminate` path (`Sources/Tabs/BrowserTab.swift`, about line 3515):
  - no WebView swap inside the callback;
  - no forced synchronous layout.
- Coordinate with bug track E.
- Source: report 06 §5; bug report top-10 #10.

**B2. Browser import smoke test.** P1, S. Chrome, Arc and Safari, on a tagged build.

**B3. Browser profiles CLI.** P2, S to M.
- `c11 browser profiles list|add|rename|clear|delete` and `--profile`.

## Remote (P1, plus pending)

**R1. `c11 ssh` smoke test and the truth in the skill.** P1, S.
- After #490, validate `c11 ssh atlas` on a tagged build: shell, browser proxy, and refusal of remote commands.
- Fix `skills/c11/references/api.md:431`.

**R2. Moved to 1.1 (D9).** Remote hosts and Prime sandboxes, spike and build both. Not ticketed for 1.0.

## Bug harvest (P0/P1, ticketed after the bug audits)

These are ticketed from `05-bug-sweep-data/LEDGER.md` plus the Fable and Astra bug audits. Must-dos become P0 or P1, nice-to-haves become P2, and "not a priority" stays in the ledger.

| Track | Contents |
|---|---|
| H-A | Ghostty patch set: bounded mailbox drain, atomic paste, the `setSelection` use-after-free, the Ghostty side of the autosave deadlock, plus **B2: the 08-25 freeze root** (abortable pushes, larger mailbox). One submodule bump. |
| H-B | App hangs and crashes: autosave renderer-lock path, cold background terminals (C11-130, C11-169, C11-235), restore-time socket crash, focus re-entrancy, pane-close bugs. |
| H-C | Session safety: re-check the snapshot-history claim first, since `SessionPersistence.swift:586-632` has startup history. |
| H-D | Socket reads for the fleet: `read-screen` on cold tabs, scrollback formatting off main. |
| H-E | Browser automation correctness. |
| H-F | Main thread, only where F2 measures it (D21). |
| H-G | Memory, only on a clear bug (D22). |

## Release (P1)

**X1. Locale pass.** Every new string, in six locales.

**X2. One integrated sign-off build** and one numbered validation script for Atin. His pass is the merge approval.

**X3. 1.0.0 release engineering.**
- Ship #490's fix.
- Changelog.
- Skill sync (`scripts/sync-installed-skills.sh`).
- The release goes out only with Atin's named approval.

## Parked (not in 1.0)

Not ticketed now; listed so nothing is lost:
- The Go terminal holder, command channel, scoped dispatch, remote CLI, per-tab hosts, `c11 move`, the Prime override, and federation.
- Gemini and omp adapters, and screen observation or classification.
- Menu-key answering and banner actions.
- Recently Closed.
- Browser URL allowlist, passkeys, `config doctor`.
- Restore accounts (D14), stable tab numbers (D15), automatic naming (D18).
- GPU reclaim, unless F2 shows a clear bug.
- The phone ladder, possibly in Overwatch.
