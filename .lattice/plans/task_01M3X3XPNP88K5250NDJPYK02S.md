# C11-273: append, SQLite store, fold and replay

Owner: `agent:astra-journal`. Mode: planning only. Implementation waits for the Orchestrator's `BUILD MODE` and C11-216's Atlas route. No builds, tests or product edits have run for this plan.

## Binding contract and scope

Implement C11-272's amended plan, `.lattice/plans/task_01M3X3XPJSSY6XSPBYGP6VCSRR.md`, SHA256 `53e75e66167e359f13aeb1621d1c1e44088552619e08f15a0f514658403c156c`, also `docs/c11-lifecycle-journal-spec.md` in this worktree. Grok's one-cycle review is `ev_01M3X6A1ZSCXEED76X4HF599T5`; the Orchestrator authorized the five sentence-level repairs and attests the unchanged architecture. Its numeric budgets, schema, ordering rules and explicit loss limits are binding here; this plan does not reopen them.

Deliver one SQLite writer and pure fold, `agent.event.append`, the bounded CLI spool/startup drain, retention and current-state baseline, and the minimal activity/attention/replay bridge needed to exercise them. Migrate signals already emitted by Claude, OpenCode, pi and root-guarded Codex notify. Preserve unknown/degraded/disconnected evidence and the six analytics questions' structural fields.

Cut line: no new Claude hook subscriptions (C11-274), Codex hook/trust integration (C11-275), transcript producer (C11-276), agents roster or journal clocks (C11-231), query/export/clear CLI (C11-277), Feed replies or operator-response capture, tenant configuration writes, remote federation, auto-resume, screen inference, or mailbox/send changes. The workspace-wide `clear_notifications` repair belongs to C11-263/A1. Existing notification content stays in its current notification subsystem and never enters the journal.

## Verified baseline and corrections

Code inspection is against this seat's clean product baseline `0ff8887e5e965400b01645ef40b85fd0b2605cf2`; build-mode integration will refresh the base and the exact affected diff.

- `SocketDispatch.swift:426` returns before its async legacy activity write; add a separate worker append handler with a committed receipt, not another async-ack v1 verb.
- `TabLivenessDeriver.onAgentLifecycleChanged` is reached by hooks, Return/submission and `TerminalNotificationStore.swift:997`; suppress **all** competing derived writers for a journal-managed owner, not just shell fallback. A fold test alone cannot prove the late-hook mark is fixed.
- `CLI/c11.swift:1923` eagerly connects before `runClaudeHook`; on an unreachable socket it returns at `:1936`. The new adapter must normalize its bounded structural draft and establish event_id before that failure path, or offline spooling never happens.
- Ordinary PreToolUse at `CLI/c11.swift:17048` writes working today. Managed hooks must no longer do this after appending. AskUserQuestion is currently special-cased at `:17006` and returns before a notification arrives; map both blocking tool classes immediately from this existing PreToolUse input.
- OpenCode's implementation is `skills/opencode-plugins/c11-notify.js`, runtime-loaded by `Resources/bin/opencode`; the bundled path is not the source path. It already observes session.created/status/idle/error, permission.asked and chat.message. Pi currently emits only agent_start/agent_settled through `Resources/bin/pi-lifecycle.ts`; do not invent Pi permission or interruption coverage.
- Normal restore already preserves tab UUIDs (`Workspace.restoreSessionSnapshot`, `Sources/Workspace.swift:278`). Use that existing identity mapping plus the exact ConversationRef. The spec's optional `journal_owner_tab_id` remains a single original-owner pointer for paths that need one; normal restore must not manufacture a new tab identity or build an alias chain.
- `AppDelegate.jumpToLatestUnread` checks flags then eligible unread notifications. `Workspace.resolvedSurfaceTabActivityState` supplies tab marks; `SidebarActivityProjector.swift` supplies immutable tooltip/census projections. These existing seams can carry blocked evidence without SQLite reads or new observed objects in SwiftUI bodies.

## Implementation sequence and files

### 1. Value types and pure fold

Add `Sources/Journal/JournalEvent.swift` for draft validation/canonical encoding, kind/source/capability enums, owner key, receipt, immutable snapshot and fold effect. Add `JournalReducer.swift` implementing `fold(previous:event:context:)`. Context contains captured ownership and live/historical admission mode; it is an input value, never an I/O dependency.

Implement the spec's native-time stale check, terminal barrier, request/turn correlation, capability-specific confidence, child exclusion and uncertainty fields. Ordinary tool_activity only refreshes an already working turn. Native prompt-submit opens a new turn; uncorrelated rank-40 transcript start cannot reopen a higher-ranked terminal barrier. Transcript edges never set/clear blocked. A missed/unsupported Esc signal stays unknown/advisory rather than a fabricated success. Keep fold order equal to committed sequence and record why an event did not apply.

### 2. Store and bounded maintenance

Add `Sources/Journal/JournalStore.swift` and `JournalStorageLayout.swift`. Use system SQLite3, prepared statements, WAL/FULL, 0700/0600 paths and transactional schema versioning. Implement `append(draft:context:) -> receipt + changedSnapshot`, `current(owner:)`, `readPage(after:through:limit:)`, `prune(now:)`, and bounded health snapshots. ReadPage is the seam for J7, not its query/export product.

The writer queue owns insert, fold, `journal_current`, transition/effect fields and commit in one transaction. Compare canonical draft content before returning an original receipt. Mutate in-memory state only after commit; on an ambiguous commit reload the affected baseline before accepting another event. Returning a receipt does not await main. SQLite transactions do not include ConversationStore calls, socket I/O or spool file claims.

Apply §6 budgets literally: 4 KiB events, queue 256/1 MiB, 100 ms SQLite busy timeout, 14-day history, 24-hour receipt floor, protected 16 MiB current state, 256 MiB total physical storage, prune/reclaim thresholds and WAL checkpoint limits. Use injected clocks/paths/budgets in tests, production defaults otherwise. Prune resolves inactive owners first and never erases an old open ask to make a capacity test pass. Each maintenance batch has an autoreleasepool. Capacity/disk/schema errors yield fixed health codes and preserve the last committed evidence; do not add a durable failure-marker subsystem.

### 3. Coordinator, ownership and socket seam

Add `Sources/Journal/JournalCoordinator.swift`, `JournalReplayPolicy.swift`, and `Sources/SocketHandlers/JournalHandlers.swift`. Route `agent.event.append` through `TerminalController.socketWorkerV2Methods` and `SocketDispatch.socketWorkerV2Response`; advertise it in `SystemHandlers.v2Capabilities`. Do not route through default main-actor dispatch or `asyncAckV1Commands`.

Resolve exact ownership through `ConversationStore.active` / its immutable snapshot and `ConversationRef.isEligibleCausalOwner`, off main. Main-owned tab creation/move/close supplies small immutable target facts to the coordinator, without synchronous main acquisition inside an append. Recheck current eligible owner when applying a queued UI projection, so a removed/replaced tab does not receive it. Reuse existing capture/claim/clear lifecycle APIs in `Sources/Conversation/Store.swift`; no new launch markers, leases or ownership epochs. Unknown attribution is recorded without a focused-tab fallback.

Queue only changed projection values onto main.async; discard older per-owner sequences. The small reserved journal snapshot contains phase/reason/source/since/confirmation/connection/health for existing metadata readback and J6 consumption, without source bodies. Keep journal health observable through that readback even when storage is unavailable. EventLog remains lossy telemetry and is never read to recover journal truth.

### 4. CLI, spool and existing producer migration

Add `CLI/JournalCommand.swift` and shared `JournalSpool.swift` alongside the journal value types; include the shared draft/layout/spool sources in the CLI target. Add `c11 agent-event append --stdin` as the structural entry point, with offline help and an input-size limit before decoding. It returns the receipt as JSON; hook adapters swallow only advisory delivery/storage errors. Fixed error codes never echo raw input.

Refactor `CLI/c11.swift` before eager connect so journal-aware hook paths construct one event ID and safe draft, then use `SocketClient.sendV2` within the total 250 ms delivery budget. Reuse the existing `CMUX_BUNDLE_ID` environment (exported by the host at `GhosttyTerminalView.swift:3545`) / actual enclosing app bundle for namespace resolution. Unknown namespace never falls back to production storage. An explicit unsupported-method response may use the old app's legacy path; timeout, busy, storage failure or ambiguous outcome must not trigger a second legacy activity write. The old app has no journal-managed owner; keep that compatibility distinct.

The spool follows the approved one-event `.open` → `.ready` convention, bounded nonblocking directory lock, 25 ms best-effort budget and unchanged canonical draft/event_id. Implement startup claiming, abandoned claim recovery, complete-line parsing, partial-tail discard, expiry and count-only diagnostics. Drain feeds the **same** store append/fold transaction for the original owner. Its changed projection is historical/unconfirmed blocked/error only; it cannot supersede newer live evidence. Unknown ownership stays unattributed. Same-ID retries after lost ack or crash-before-file-delete return the original receipt; no second application lane.

Producer mappings, using only existing input boundaries:

| Existing seam | Journal route |
|---|---|
| runClaudeHook session-start/session-end | Preserve current conversation capture/end rail; append session observation for the exact owner. Do not retain cwd/body from those existing operations in the draft. |
| prompt-submit; stop | turn.started; turn.completed. Preserve existing completion notification policy; no parallel derived working/idle write. |
| PreToolUse | AskUserQuestion → question.requested; ExitPlanMode → plan_review.requested; ordinary tools → state.changed/tool_activity. Missing source time remains missing. Keep C11-263's separate clear-notification fix out of this diff. |
| Claude Notification | Map only supported structural notification type; generic notification is observation, not invented blocked or completed evidence. |
| OpenCode plugin | Replace reportActivity with typed append from its existing event switch, retaining root/child checks and exact conversation push. session.status busy/retry is activity, not another prompt; permission.asked and session.error use supported semantic kinds. |
| Pi agent_start/agent_settled | Pass native event identity at plugin rank; resolve an already established exact session. Missing exact identity remains legacy/unattributed, never guessed from cwd. |
| Codex legacy notify | After `NotificationHandlers.shouldDeliverLegacyCodexNotification`'s existing root decision, enqueue an allowlisted root completion only if the exact captured root matches. Child mismatch neither journals root completion nor notifies; missing root retains the existing legacy fallback with unattributed journal coverage. Do not journal arbitrary `notify` as root completion. |

`Resources/bin/opencode` and `pi-lifecycle.ts`, `skills/opencode-plugins/c11-notify.js`, and `CLI/c11.swift` are the migration files. No subscription widening in `Resources/bin/claude`. Source rank cannot be inferred from a caller's arbitrary integer. Optional agent-hook compatibility remains for unmanaged/older clients; a managed owner's v1 activity writes cannot bypass the fold.

### 5. Compatibility projection and restart

In `TabLivenessDeriver.swift`, separate the journal projection entry from legacy `onAgentLifecycleChanged`; gate shell/legacy/reconcile writes for managed owners before activity mutation. All accepted changes to derived activity for those owners come from the committed fold. This covers notification and Return callers without adding I/O to their hot paths. Explicit metadata precedence remains intact.

In `Workspace.swift`, cache immutable per-tab journal projections and feed blocked-or-unread into `TabActivityResolver.resolve`; use the existing activity refresh/census seams. `TerminalNotificationStore.swift` must not force a managed owner idle merely because an unrelated notification is added. Seeing/removing unread does not clear blocked. Preserve flag/suppression precedence in `AttentionModel.swift` and existing projectors; do not redesign those policies. Existing ⌥V routing in `AppDelegate.jumpToLatestUnread` includes eligible blocked candidates without converting them to unread notifications; flags still win, suppression still excludes routine attention, and reading an ask is not answering it.

Provide the minimal unconfirmed/error/blocked evidence in `Workspace.resolvedAgentActivityHelp` and `Sidebar/SidebarActivityProjector.swift` tooltip/accessibility projection, reusing the current mark. Detailed roster, clocks and Feed UI stay J6/A2. Avoid `ContentView` body observers and layout changes.

Wire off-main open/replay into `AppDelegate.prepareStartupSessionSnapshotIfNeeded` / startup's existing async conversation-seed path. Use `SessionPersistence.SessionTabSnapshot` plus `Workspace.restoreSessionSnapshot` for the one optional original-owner pointer, maintaining the normal stable UUID path. Clear stale journal-managed derived working during restore before displaying restored metadata. Blocked/error baselines paint unconfirmed; other prior phases do not assert current liveness. Deduplicate restored owner claims through existing exact conversation ownership. Startup can show unknown/degraded while the journal is opening; it does not wait on main. Begin bounded drain after baseline load; live appends need not wait for full drain.

### 6. Packaging, docs and localization

Add sources and meaningful test classes to `GhosttyTabs.xcodeproj/project.pbxproj`, with pure model/store/spool tests in `c11LogicTests`; host-dependent projection tests stay `c11Tests`. Verify built CLI/app membership and system SQLite linkage on Atlas. Avoid submodule changes. No new persistent tenant configuration.

Document the shipped append command, receipt, limits and compatibility in `skills/c11/references/api.md` and journal semantics in `references/conversation.md`; add a concise map link in `skills/c11/SKILL.md`. Run `scripts/sync-installed-skills.sh c11` after source changes land and verify the installed copy; C11-278 owns the later broad doctrine pass. The OpenCode plugin is bundled runtime code, not permission to update a tenant-installed plugin.

English call-site keys for the minimal bridge: `journal.state.unknown` = Unknown; `journal.state.disconnected` = Disconnected; `journal.state.degraded` = Degraded; `journal.evidence.unconfirmed` = Unconfirmed; `journal.reason.approval` = Approval; `journal.reason.question` = Question; `journal.reason.planReview` = Plan review; `journal.state.error` = Error. Reuse an existing equivalent localization when available. C11-291 supplies six locales; no manual translation work in this ticket.

## Acceptance and evidence

Every case below is an observed incident, an audit's concrete retry/retention example, or a J7 question from the binding spec. New tests exercise real functions, temporary SQLite files, CLI subprocesses and isolated sockets, never source text. C11-271 captures are pending; import its finalized normalized corpus and provenance when delivered, without labeling synthetic variants as real captures.

| Ticket AC | Named oracle | Behavioral checks and Atlas runtime proof |
|---|---|---|
| 1: fold/mark correctness | F3 bypass AskUserQuestion/ExitPlanMode; late PreToolUse; Esc; sibling; C11-189 child | `JournalReducerTests` replays the corpus and compares each step. Seq10 Stop/seq11 tool must stay completed with native, missing and hook-start-only times; a real prompt starts the next turn. Root and child callbacks exercise the actual ingest guard. Tagged real hook/UI flows verify blocked versus unread and the late mark, not just fold state. Supported interrupt fixtures exercise the store seam now; unavailable native interrupt coverage remains explicit until producer tickets deliver it. |
| 2: committed receipts | Audit ambiguous ack and content conflict | `JournalStoreTests` commits then reopens, retries identical/different drafts, and observes one event/original receipt or conflict. Isolated CLI/socket run drops the reply after commit, retries through spool, and reads the same sequence. No UI-ack claim. |
| 3: bounded drain | Offline hook; truncated tail; stale tab/session; repeated drain | `JournalSpoolTests` uses private directories and real file operations. Tagged CLI runs with its socket unavailable, creates a sanitized record, then app restart drains it. Include a spool-only blocked ask, crash-after-commit-before-delete, stale ownership, and live-newer-than-drain cases. Unknown owner never paints; spool-only known ask paints unconfirmed. |
| 4: restart/retention | Restart while waiting; 15-day open ask | `JournalReplayTests` / store tests force time and byte pruning with injected clock/budget, then reopen: ask baseline survives, expired history coverage shrinks, old working does not return. Force-kill tagged app after receipt and relaunch with QA resume; screenshots and current snapshot show unconfirmed blocked/error, then fresh supported reconciliation. |
| 5: responsiveness/bounds | F3 burst; audit resource/privacy; C11-270 soak | Fault-inject SQLite busy/full/unavailable and queue/spool saturation; fixed degraded state, bounded buffers and protected baseline. On Atlas compare registered baseline/candidate typing, main-thread stalls, CPU, memory and physical DB/WAL/spool sizes. No thresholds invented after measuring. Run drain/prune under the same trace with autorelease pools. |
| 6: compatibility/privacy | F3 sibling/seen; suppression/flag/⌥V; audit §7 | Extend `TabLivenessDeriverTests` and host projection tests: B cannot change A's journal row or blocked projection, seen clears only unread, suppressed routine waiting stays out of counts/jumps, flags retain precedence. A1 owns the workspace clear repair. Tagged computer use proves these paths. Sentinel input bodies never reach DB/WAL/spool or diagnostics; public evidence contains only synthetic IDs. |
| Schema readiness | Q1..Q6 time/state/wait/blocked/turns/errors/stalls | Hand-computed structural timelines assert stored effects, dimensions, duration boundaries, censoring, duplicate counts and retained coverage through store/readPage APIs. Test seen without response produces no operator-response event; queries without that evidence must later return unavailable. J7 owns metric calculations and NDJSON product tests. |

New files: `c11Tests/JournalReducerTests.swift`, `JournalStoreTests.swift`, `JournalSpoolTests.swift`, `JournalReplayTests.swift`, `JournalProjectionTests.swift`; `tests_v2/test_journal_append_replay.py` for the isolated socket/CLI sequence. Share fixture decoding rather than generating a second corpus. Use injection only in unit tests; the packaged tagged smoke must traverse real hooks/socket/SQLite/UI without in-process mocks or dev-only seeds. Provider gaps and deferred producer validation are reported separately from passing injected seam tests.

All execution is after BUILD MODE on Atlas, through C11-216's supplied commands and machine-wide build lock. Tests_v2 live work uses the isolated guest/sandbox runner, never the operator's session; full E2E stays on its approved workflow route. Computer-use validation gets a verified Atlas display, tagged bundle/PID, hard timeout, proven dismissal and screenshots; inspect area readability. A compiled test bundle is not an executed assertion.

## Dependencies and handoff

1. C11-272 amended spec is the resolved design gate. C11-271 is the real capture oracle; absence does not block writing this plan, but is recorded before claiming runtime acceptance.
2. C11-216 unlocks builds/tests; C11-270 supplies pre-registered performance budgets. No Hyperion test/build exception.
3. Integrate C11-263's independent sibling-clear repair through the Orchestrator; do not duplicate it. Coordinate the shared blocked projection with A2/J6 through the plan, preserving one fold.
4. Keep J3–J7's producer/consumer interfaces small. Missing provider signal remains unavailable, not authority inferred from silence. Retention does not fabricate analytics before coverage.
5. At BUILD MODE use the assigned worktree, refresh/rebase as directed, and create/link the C11-273 implementation branch before review. Commit implementation and evidence, validate the exact head on Atlas, push/open a non-empty PR, and send HANDOFF REVIEW. Merge Captain merges; this seat never merges or releases.

Open human decisions: none. Remaining gates: BUILD MODE, real fixture delivery, Atlas validation and the normal code review. Review cap: three unsuccessful cycles, then Orchestrator escalation. The current task ends at PLANNED/STANDBY; implementation has not started.


## Build-mode integration correction (2026-10-02)

C11-257 has landed since the planning baseline. Its mailbox stdin gate uses the existing interactive PID on native lifecycle reports (`TerminalController.reportedAgentLifecycleSource` and `Workspace.noteMailboxAgentLifecycle`). Dropping that provenance while replacing managed hook reports with append would regress waiting-agent push. Preserve it as an optional **transport-only** `interactive_pid` alongside the `event` object on `agent.event.append`; it is validated like the existing report PID, never included in the canonical draft/hash/database/spool or analytics. Only a fresh, applied root native turn boundary may update the existing mailbox gate after current-owner recheck. Blocked/error projection is not a prompt edge; replay, duplicate receipts, stale events and transcript observations cannot open the stdin gate. This reuses the existing foreground ownership check and adds no mailbox protocol, subscription, persistent marker, or tenant configuration.

The owner will integrate only after the Orchestrator's C11-263 MERGED signal. Targeted core tests pass at 1652acb59f (Atlas invocation ed584e4878154381b5d576031e80fd82); this correction and all app integration still require their own validation.

## Reset 2026-10-02 by agent:astra-journal


## Integration corrections after C11-263 merged (2026-10-02)

The journal consumes immutable owner facts published by the existing ConversationStore actor only when exact identity/eligibility changes. No actor wait or disk lookup occurs on the main/typing path. Tab registration follows the existing Workspace panel lifecycle; startup spool drain waits for both the existing seed/audit chain and restored tab registration. Stable tab UUIDs require no second restore alias in the shipped path.

The existing liveness queue serializes journal, legacy and reconcile writes, and queued main mirrors recheck the current cached projection. Coalescing may skip a native start before its ask paints: a current working/blocked/error projection therefore also closes a prior mailbox prompt gate. This never opens stdin. Opening still requires a fresh applied native turn-completed boundary and the existing interactive PID/foreground check; transport PID never enters SQLite or spool.

C11-263's tab-scoped unread clears remain in place. Blocked state is independent; generic/late PreToolUse cannot publish a parallel Running state. Permanent invalid/conflicting/expired append rejection is returned rather than spooled. Timeout/busy/unavailable still attempt the bounded spool.

Run instruction supersedes the original installed-skill paragraph: only the Merge Captain syncs installed skills from merged main. This lane edits source only. Tagged baseline for the short same-scenario comparison is origin/main 43529df178; this is not the deferred fleet soak.
