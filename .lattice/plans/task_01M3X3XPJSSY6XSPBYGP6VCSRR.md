# C11-272: SQLite lifecycle journal contract

Status: amended after the independent Grok review; the Orchestrator attests this sentence-level delta without re-review and authorizes C11-273 planning. Owner: `agent:astra-journal`. This document is the C11-272 plan. No implementation or runtime validation is claimed here.

## 1. Scope, evidence and decisions

Baseline: c11 `0ff8887e5e965400b01645ef40b85fd0b2605cf2`; upstream reference `920ff39ff7cd6166434c12b9c2f167d4284fe6b2`. BACKLOG.md D1/D3 are settled: SQLite WAL, analytics, NDJSON export. The older reports' journal-deferral and NDJSON-storage recommendations are superseded.

Verified seams at that c11 baseline:

- `Sources/TabLivenessDeriver.swift:5` (`TabActivityResolver.resolve`) treats an exact unread notification as waiting; `:155` (`onAgentLifecycleChanged`) writes derived activity off main and mirrors it asynchronously.
- `Sources/SocketHandlers/SocketDispatch.swift:426` (`reportAgentActivityWorker`) accepts two states but has neither causal time nor a durable receipt. `Sources/TerminalController.swift:2060` declares worker-dispatched v2 methods.
- `CLI/c11.swift:16641` (`runClaudeHook`) receives native hook data; `:17006` recognizes AskUserQuestion but waits for Notification; `:17042` clears workspace notifications on ordinary PreToolUse. These are the bypass and sibling incidents' integration seams.
- `Resources/bin/claude:207` makes PreToolUse asynchronous. `Sources/SocketHandlers/NotificationHandlers.swift:15` guards Codex notify against an exact captured root when available; it deliberately permits the legacy path when none is captured. Do not describe that fallback as exact identity.
- `Sources/PersistedMetadata.swift:136` preserves activity across restore. `Sources/Events/EventLog.swift:70` can drop saturated telemetry; it remains a separate wake-up stream, not journal storage. `Sources/AgentModelDetection.swift:2` already imports system SQLite3.
- Upstream `Packages/macOS/CmuxAgentJournal/`: read EventKind, EventDraft, Store, Store+Schema, SemanticEventMapper, LifecycleReducer and ReplayPolicy. Adopt kind spelling and local transaction/dedupe ideas; do not import its free-form detail, messaging, auto-resume, alias chains, or claim that old blocked evidence proves a live prompt. Its reducer's sequence AND occurrence-time check explains the late-arrival counterexample.

Read report 01, both audits' §4, Astra §7, and `docs/aar-c11-188-attention-loop.md` twice. Mechanism is one local database writer, one pure fold, one bounded best-effort spool. A successful receipt describes the SQLite commit, not UI repaint, notification delivery, producer completion, or exactly-once delivery across failures.

Decisions (owner defaults, no open Atin choices):

1. Keep cmux's full `agent.*` kind names on wire and disk; human documentation may abbreviate them. Add `agent.turn.interrupted`.
2. Use app sequence for reproducible processing and cursors, source occurrence evidence for stale rejection, and semantic restrictions on tool activity. Sequence does not establish causality.
3. Store structural fields only. Retain 14 days, with a byte budget and a protected current-state baseline. Analytics reports its coverage and uncertainty.
4. Replay blocked/error as unconfirmed history. Existing `activity`, unread, suppression and flag policies remain compatibility outputs, not independent lifecycle authorities.

## 2. Vocabulary, provenance and ownership

Wire v1 accepts cmux kinds: `agent.session.started|ended`, `agent.turn.started|completed`, `agent.child.spawned|completed|failed`, `agent.approval.requested`, `agent.question.requested`, `agent.plan_review.requested`, `agent.error.reported`, `agent.state.changed`, `agent.idle.observed`, `agent.attention.resolved`, `agent.message.published`; plus `agent.turn.interrupted`. `message.published` is diagnostic-only with no body; delivery is C11-257, outside this work.

`source` rank is fixed by the app's adapter mapping: hook 60 > plugin 50 > transcript 40 > screen 30 > shell 20 > keypress 10. Screen producers remain parked. Optional self-report uses `source=self_report`, rank 10; c11's own lifecycle/connection/response observations use `source=c11`, rank 0 and only their specific control meaning. Neither is an escape hatch for an arbitrary phase assertion. Ranks describe evidence, not authentication against other same-UID clients. Record adapter name/version and capability flags; do not let a caller pick an integer rank.

The owner key is `(tab UUID, agent kind, exact session ID)`. Reuse `ConversationStore` and `ConversationRef.isEligibleCausalOwner`; no new ownership protocol. Child rows carry `is_child=true` and optional parent ID and never project onto the parent's mark. Compare a Codex callback's thread ID to the captured root BEFORE generating a root journal event. A missing exact root makes that callback journal evidence `unattributed`, while the existing legacy notification fallback stays as it is. C11-189's known-root mismatch must still be rejected.

Unknown attribution never selects the focused tab, matches by cwd, or resolves a short tab number from a different run. Missing identity is stored as a bounded diagnostic, excluded from state and per-session metrics. Plugin/transcript events can be advisory only when tied to an already established session; otherwise expose unavailable coverage. Session replacement ends the old owner's eligibility; it does not rewrite history. A tab move changes the workspace dimension on subsequent events, not the owner key.

## 3. Event and storage schema

JSON uses canonical `tab_id` / `workspace_id` UUIDs, UTC integer milliseconds, explicit nulls, `schema_version=1`. A producer creates `event_id` (UUID) and `emitted_at_ms` once, before its first attempt; retry/spool keeps them unchanged. Native occurrence time is optional and is NEVER filled from CLI start time and called causal. A native turn/request ID is optional; unavailable IDs stay null.

Draft allowlist (maximum canonical UTF-8 encoding 4 KiB):

| Fields | Contract |
|---|---|
| `schema_version,event_id,kind,emitted_at_ms` | Required; emitted time bounds retry eligibility, not semantic ordering. |
| `occurred_at_ms,time_quality` | Nullable; quality `native_local`, `observed`, or `missing`. Only fixture-verified native local timestamps compare causally within the same adapter/session clock. |
| `tab_id,workspace_id,session_id,agent_kind,is_child,parent_session_id` | Owner and grouping; both target UUIDs or neither. Agent slug <=64 bytes, opaque native IDs <=128 ASCII bytes, no paths. |
| `source,adapter,adapter_version,native_event` | Enums/registered slugs; version <=64 bytes. Unknown native names become `other`, never raw text. |
| `turn_id,request_id,tool_class,reason_code` | Optional structural correlation. Tool class `ask_user_question`, `exit_plan_mode`, `other`; reason is an enum, never a message. |
| `signal` | For state.changed only: `tool_activity`, `operator_response`, `connection_lost`, `adapter_gap`, `adapter_recovered`, `legacy_working`, `legacy_idle`, or `observation`; no general declared-phase override. |
| `resolution` | attention.resolved only: `resumed`, `cancelled`, `unknown`; with matching request ID. |

App-enriched fields: `sequence INTEGER PRIMARY KEY AUTOINCREMENT`, `committed_at_ms`, monotonic `observed_tick_ns` and `app_instance_id`, normalized draft hash, attribution result, confidence rank, capability set, model ID from existing bounded metadata (null if unavailable), `fold_version=1`, fold effect/reason, and optional transition (`from_phase,to_phase,from_since_ms`). A caller cannot supply these. Hash the normalized draft, excluding app-enriched values; retries return the originally captured enrichment.

SQLite tables:

1. `journal_events`: columns above; unique event_id; normalized canonical draft bytes retained for exact conflict comparison, not raw request bytes. Immutable by API except retention/clear. Index `(tab_id,session_id,sequence)` and `(committed_at_ms,agent_kind,model_id,workspace_id)`.
2. `journal_current`: one bounded row per owner, containing phase, reason/request, turn status/ID, winning evidence/source/time, last applied sequence, phase start, confirmation/connection/health, and last terminal barrier. This is the complete serialized pure-fold state, updated in the SAME transaction as each event and its recorded effect. It survives history pruning; it is not a second authority. Maximum 8 KiB per row and 16 MiB total.
3. `journal_meta`: schema/fold version, coverage low-water mark, last writer observation, and aggregate drop/gap counters (no payloads). Keep only the latest health counters, not another append log.

Path: `~/Library/Application Support/c11/journal/<bundle-id>/lifecycle.sqlite3`, with spool below the same instance namespace. Directory 0700; DB/WAL/SHM/spool 0600. Tagged builds use their own bundle namespace, never production. System `libsqlite3`, WAL, `synchronous=FULL`, foreign keys enabled, `user_version=1`; initial creation enables incremental auto-vacuum. One utility serial queue owns writes, fold and retention. Prepared statements; each append transaction inserts the event, folds the candidate, writes current state and commits. Rollback leaves in-memory fold unchanged. Reload that row after ambiguous SQLite commit failure. No transaction spans a socket, UI operation or a producer file.

Unknown schema/fold version: expose degraded/unavailable, keep the file, do not silently recreate it. A new schema needs an explicit transactional migration. No pre-1.0 historical events are invented from existing snapshots or telemetry files.

Privacy: reject unknown draft keys and oversize/invalid values before disk; adapters extract the allowlist without retaining their input JSON. No prompt, question, plan, command, arguments, output, transcript line, cwd, account, email, notification body, arbitrary error string, or free-form detail in DB/WAL/spool/export/error logs. Native IDs are local structural identifiers; all public fixtures and ticket examples use synthetic IDs. Diagnostics contain fixed codes and counts only.

## 4. Fold and ordering rules

Pure function: `fold(previousOwnerState, committedEvent) -> nextState + effect`. Replay is in ascending committed sequence; no promise of permutation invariance. Diagnostic/stale/child events advance the read cursor but not the owner's semantic watermark. Fold effects are `applied`, `duplicate_evidence`, `stale`, `unattributed`, `child`, `advisory`, or `observation` with fixed reason codes.

Apply these rules in order:

1. Require current exact owner eligibility for live projection; record but do not project other sessions, children or unknown attribution. Drained lines use the normal append/fold transaction for their original owner; painting its result stays unconfirmed blocked/error only, drain never overwrites a newer live observation already applied to that owner, and unknown owners stay unattributed. History still belongs to its original owner; there is no second apply path.
2. Within a comparable native clock, occurrence time older than the applied semantic watermark is stale even with a larger app sequence. Equal time with conflicting kinds cannot reopen terminal/blocked state via tool activity; otherwise sequence breaks a tie. Future time over five minutes ahead of commit time, clock discontinuity, or an unverified clock is downgraded to observed/missing and flagged as timing uncertainty. Cross-source clocks do not establish causal precedence.
3. Native turn/request IDs, where present, prevent evidence for a different known turn/request changing the active one. Without them use the explicitly limited rules below, never fabricate an ID from arrival order and call it native.
4. A lower-ranked observation cannot clear a higher-ranked blocked/error assertion. Authority is capability-specific: an adapter that does not support interrupts does not suppress a supported transcript interrupt. Conflicting/missing evidence is retained with `degraded` coverage; silence never proves completion. Repeated same-kind evidence does not restart the state clock or count another turn.

| Kind / supported mapping | State effect |
|---|---|
| session.started | New exact owner starts unknown. Repeating it for the same session is observation, not a reset of blocked/completed. |
| turn.started: UserPromptSubmit / native turn-start | Starts working, clears previous terminal barrier. A native earlier time/old known turn remains stale. Without causal time, an explicitly observed new-turn boundary may start work; this is a bounded assumption, not arbitrary out-of-order safety. |
| state.changed/tool_activity: ordinary Pre/PostToolUse | Refreshes an already working turn only. NEVER starts a turn after completed/interrupted/error/unknown and NEVER clears blocked without a matching resolution or verified resumed-turn evidence. |
| question/plan_review.requested: PreToolUse AskUserQuestion / ExitPlanMode | Sets blocked immediately, including bypass mode; does not wait for a Notification. Retains structural request ID if available. A late uncorrelated ask after a terminal barrier is advisory, not a reopened ask. |
| approval.requested | Sets blocked when the adapter actually exposes the request. No permission inference from shell or keypress. |
| attention.resolved | Matching same-owner request becomes working for resumed, idle for cancelled, unknown otherwise. A late resolution of request A cannot clear request B. Without request IDs, require fixture-proven same-session resumed-turn evidence, otherwise retain blocked and show uncertainty. |
| turn.completed / idle.observed | Sets idle with outcome completed/observed. If blocked, generic Stop/idle alone does not prove the ask resolved; require matching resolution or verified continuation of that turn. Stop after a genuinely working turn completes it. |
| turn.interrupted | Supported hook/transcript interruption closes working to idle with outcome interrupted. If it demonstrably cancels a matching ask, clear that ask; otherwise blocked evidence remains unconfirmed. Esc key alone is advisory and cannot claim interruption succeeded. |
| error.reported | Sets error only for session/turn failure evidence; tool failure that the agent continues handling is a diagnostic. |
| session.ended / connection_lost | Connection becomes disconnected; preserve last phase as history. No auto-resume, auto-answer, or activation. |
| child.*, message.published, unknown native events | No parent lifecycle effect. |

**Required counterexample:** working → Stop(occurred 200, seq 10) → ordinary PreToolUse(occurred 100, seq 11) stays idle/completed; seq 11 is stale. Repeat with null or hook-start-only time: tool activity still cannot reopen it. A subsequent genuine UserPromptSubmit can start the next turn. This is the small semantic rule that fixes the observed incident without a spool marker/epoch protocol.

Source overlap counts state transitions, not producer messages. Same native turn ID from hook and transcript is one turn; absent IDs, a second start while already working is duplicate evidence. If evidence cannot distinguish two turns, report observed lower-bound counts and an ambiguity count, not invented precision. For an established session, transcript turn.started/completed/interrupted apply at rank 40 and never set or clear blocked; after a higher-ranked terminal barrier, transcript turn.started without newer comparable native time or a new native turn ID is duplicate/ambiguous evidence and does not restart working, while a new native turn ID or newer comparable native time can start the next turn.

## 5. Honest state, restart and compatibility

Snapshot contract keeps independent fields: `phase=unknown|working|blocked|idle|error`, `turn_outcome=completed|interrupted|null`, `connection=live|disconnected|unknown`, `health=ok|degraded`, `confirmation=confirmed|unconfirmed`, `source`, `observed_at`, `since`, `freshness`, `coverage`. Thus disconnected and degraded are explicit machine states, not euphemisms for idle. Fresh means evidence age <=30 seconds; older is stale (not false); a current blocked claim persists until resolved. A 10-second reconcile sweep updates freshness only; it does not invent turn events.

On startup, load current rows on the writer queue before admitting new appends. All prior-run rows become unconfirmed/disconnected projections. Only blocked/error can paint historical attention, with an unconfirmed label; old working/idle never becomes present liveness or resume eligibility. Read current baseline rather than scanning 14 days. If startup storage is unavailable, start UI with unknown/degraded; do not block main waiting for storage.

Reattach a historical projection only through the existing session restore mapping from snapshot tab UUID to new tab UUID plus matching exact ConversationRef; no alias chains, cwd matches or number matches. Retain `journal_owner_tab_id` as one optional snapshot field for this mapping across subsequent restarts; duplicate restores never get two live owners for one historical row. An ambiguous match stays an unattached restore candidate. Fresh supported evidence for the mapped owner confirms current state; a new session starts separately. Freshness alone never confirms an old ask. Startup drain remains historical and cannot overwrite a newer live observation.

Compatibility projection uses existing activity precedence and `TabLivenessDeriver`: confirmed working → working; idle/blocked/error → idle; unknown/disconnected → no derived working assertion. Preserve explicit operator metadata precedence. Journal-managed hook adapters submit `agent.event.append` only, and the fold's main.async projection is the sole derived activity writer for that session; ordinary PreToolUse no longer calls `report_agent_activity working`, and prompt-submit/turn.started starts the next turn through the same projection. Only journal-managed agent sessions stop accepting competing derived writes from shell lifetime/Return key; shells and unmanaged sessions retain their existing fallback. Existing snapshot activity remains readable for old versions, but journal-managed restore clears stale derived working before repaint.

Blocked attention is separate from unread completion. Seeing a tab can clear unread, never the blocked record. The shared attention resolver combines blocked-or-unread using existing suppression/flag rules; suppressed ordinary waiting remains idle and outside ⌥V counts, while a flag still escalates. No global notification clear is part of journal projection. Completion notifications retain their existing delivery policy. A1/Feed/J6 consume this same contract; they must not create a second blocked reducer. Socket append does not focus or activate anything.

## 6. Receipts, retry spool and resource bounds

`agent.event.append` runs on the socket worker, not the fire-and-forget v1 telemetry path. Response after commit: `{event_id,sequence,committed_at_ms,replayed,projection_effect}`. It does not wait for main.async repaint. Same ID + same normalized draft returns the original receipt; different draft gives `idempotency_conflict`, no replacement. Unknown outcomes are retried with the original ID. Stale semantic events may still have a successful durable receipt.

One bounded append queue: 256 entries (<=1 MiB draft bytes). Admission failure returns `journal_busy`; SQLite busy timeout 100 ms. Hook client total delivery budget 250 ms, then attempts spool and exits without blocking the agent. A timeout may follow a commit. Normalized event and current state survive an app force-kill after receipt; power loss, filesystem failure, a crash before commit, and a producer dying before its spool write are not promised lossless. UI may lag or miss an acknowledged repaint until replay. No durable failure markers, two-phase ack or rollback across processes.

Spool: c11-owned NDJSON per producer PID plus a random suffix, O_EXCL/NOFOLLOW, 0600; one file writer. Write one bounded event to a `.open` file, close and rename to `.ready`; this is file readiness, not a delivery acknowledgement. Same bounded draft; no raw hook input. Aggregate admission is serialized with a short nonblocking spool-directory lock, used only for count/size/write, never while contacting the socket. Spool work has a 25 ms best-effort budget, without waiting for a lock. If lock unavailable, full or unwritable, skip spooling and increment an in-memory diagnostic where possible; event loss is an explicit limitation. No guarantee a failure counter survives the same failure.

At startup, drain only `.ready` files or abandoned `.open` files whose producer has exited, owned by the current UID in the expected bundle directory. Claim by atomic rename in that directory; retry abandoned claims on next startup. Do not follow symlinks; cap file and line reads. Active or PID-reuse-ambiguous writers' files wait for a later scan or expire at 24 hours. Valid complete lines retry by event_id; an incomplete final line is discarded and counted, never executed. Invalid lines produce fixed counters, not content logs. Delete a consumed file after receipts; a crash before deletion simply repeats dedupe on next startup. Conflict/expired/unattributed records are counted then removed, not retried indefinitely. Missing/stale tab or session may be stored as historical/unattributed evidence, never rebound to current focus. A new live event always has priority over historical spool projection.

| Budget | Default / outcome |
|---|---|
| History | 14 days by committed time; prune in batches of 1,000 on open and every minute/1,000 appends. Never prune active current rows merely because the originating ask is old. |
| Receipt window | Keep event rows for at least 24 hours after commit. New drafts with emitted time >24 hours old are expired; lookup an existing event_id first so a retained retry returns its receipt. No guarantee of dedupe after its retained receipt expires. |
| Spool | 24-hour age, 16 MiB aggregate, 1,024 files, 64 KiB/file, 4 KiB/line. Reject new spool records at cap; do not silently evict acknowledged history. |
| Startup drain | At most 1,000 rows or 2 seconds before yielding; continue background batches of 100 with a 100 ms pause. App/live admission does not wait for complete drain. |
| State baseline | 16 MiB / 8 KiB per owner. Evict resolved inactive owners older than 14 days first; retain open blocked/error evidence. If protected state alone fills the cap, reject new owner admission and expose degraded instead of erasing an ask. |
| Total owned storage | 256 MiB DB + WAL + SHM + spool, measured physical bytes. Start pruning/reclaim at 192 MiB toward 128 MiB; retain 24-hour receipts and protected current state even if this requires rejecting new appends. |
| WAL / readers | Checkpoint at 4 MiB; at 16 MiB stop new appends until checkpoint/reclaim succeeds. No long-lived export transaction; 500-row read pages, release snapshot each page. Incremental vacuum/reclaim off main. |

Before a batch, reserve 1 MiB below the total cap for SQLite page/WAL growth; configure database max pages to respect its share. If budget recovery cannot complete, return `journal_full`/`storage_unavailable`, preserve the old baseline, expose degraded. The cap is an operational budget with at most one bounded transaction's growth before the next measurement, not a guarantee against external file writes or arbitrary filesystem behavior. A 40-agent workload that exhausts the receipt floor is an observed capacity failure to report, not grounds to erase the floor silently.

`journal.clear` (J7, explicit operator action) deletes history/current/spool in this namespace and resets coverage without pretending old analytics remain complete. It never deletes conversations, snapshots or tenant files. It does not create a blocked replay from cleared data.

## 7. Analytics and NDJSON export contract (C11-277 / J7)

Default metrics describe **observed state**, using committed transition time within a process and monotonic ticks for elapsed duration. Native occurrence timestamps are separately queryable; do not reorder the store or retroactively revise live intervals. End a prior-run observed interval at the last recorded writer observation and mark the crash gap censored. Never charge shutdown/relaunch time as confirmed working or operator wait. Clock rollback creates an unknown gap; no negative durations.

Every result carries requested window, actual retained coverage, source/capability breakdown, uncertain/censored counts and units. Group by agent, model, workspace-at-event and time window; unknown model remains unknown. Split open intervals at recorded model/workspace changes (app control observations), not today's metadata. Clip intervals to `[from,to)` and coverage. Current baseline supplies ongoing state, but cannot reconstruct expired history; an old open ask is reported with original since plus left-censored coverage.

| Analytics question | Fields / definition / fixture oracle |
|---|---|
| Q1 time in each state | Applied from/to transitions and from_since; sum clipped intervals, keep unknown/disconnected/degraded/unconfirmed durations separate. Restart-while-waiting and late-hook trace must not invent working time. |
| Q2 wait before operator response | Blocked request ID to `state.changed/operator_response` from an actual user UI submit or Feed response action tied to that same request. No input text stored. View/seen and socket-generated keystrokes are not responses. Null if no observed correlated response. Separately report request-to-agent-resume latency; never label that operator response time. Bypass ask + seen + response + resumed trace is the oracle. |
| Q3 blocked minutes | Sum confirmed blocked intervals, grouped by approval/question/plan_review; report unconfirmed historical blocked separately. Suppression affects attention presentation, not underlying blocked duration. Old-open-ask retention trace is the oracle. |
| Q4 turns/hour | Count applied root turn-start boundaries per covered hour, not tool hooks; expose completed/interrupted counts and duplicate/ambiguous evidence. Late-hook + hook/transcript duplicate trace is the oracle. |
| Q5 errors/interrupts | Count unique root failure/interruption boundaries; separate child/tool diagnostic counts. Esc and C11-189 child-completion traces are the oracles. |
| Q6 stall outliers | List working intervals exceeding a configurable threshold (default 15 minutes), last evidence age/source/coverage, censored flag. This is an outlier query, not proof an agent hung or authorization to interrupt. Long-working + disconnected trace is the oracle. |

Q2 producer coverage belongs to Feed/J6; absent positive response observation is reported unavailable, not fabricated in J2. No terminal body parsing is added to infer it.

J7 NDJSON export is versioned structural records: first a manifest `{export_version,fold_version,from,to,first_available_sequence,high_water_sequence,coverage}`, then typed event rows in sequence order and optional `current_state` rows explicitly labeled as baselines. Freeze high-water sequence at export start; paginated reads do not pin WAL. If retention overtakes a page, emit a `gap` record and coverage loss. Export is an inspection/analytics format, not an import or a promise of a transactionally frozen full backup. The same privacy allowlist applies; no extra debug payloads. Output goes to stdout or an explicitly chosen local path, never an upload. Raw event output must distinguish recorded from applied events so a consumer cannot count a stale PreToolUse as a new working interval.

## 8. Work boundaries and planned validation

C11-272 changes this local spec and its Lattice plan only. No product code, builds or tests in planning mode. The independent review is one Grok cycle routed by the Orchestrator; address its findings once, re-review only if architecture changes. Escalate at three unsuccessful cycles. No reviewer is asked to prove arbitrary crash/order correctness beyond these named cases.

C11-273's later implementation plan will bind these integration points (not an authorization to implement now):

- New `Sources/Journal/{JournalEvent,JournalStore,JournalReducer,JournalCoordinator,JournalReplayPolicy}.swift` and CLI spool helper; system SQLite linkage/project membership.
- `Sources/SocketHandlers/SocketDispatch.swift` worker routing and `Sources/TerminalController.swift` execution-policy set; new journal handler. `CLI/c11.swift` runClaudeHook/runAgentHook/reportAgentActivity adapters and append CLI. `Resources/bin/opencode`, `pi-lifecycle.ts` migrate existing signals only.
- `Sources/TabLivenessDeriver.swift` compatibility projection; `Sources/TerminalNotificationStore.swift` and `Sources/SocketHandlers/NotificationHandlers.swift` retain notification/known-root semantics. Ownership snapshots come from `Sources/Conversation/Store.swift`; `Sources/SessionPersistence.swift`, `Sources/Workspace.swift` and startup in `Sources/AppDelegate.swift` carry the one restore mapping and seed replay.
- C11-231/J6 and Feed own visible reason/clocks/roster and response capture; C11-274..276 own producer widening. C11-277 owns query/export/clear. C11-278 owns doctrine and installed-skill sync; J2 documents any new live append verb in `skills/c11/` and syncs it when shipped. No C11-257 send/mailbox files are touched before that lane lands.

No new product strings in this spec. Consumer key reservations: `journal.state.unknown` (Unknown), `journal.state.disconnected` (Disconnected), `journal.state.degraded` (Degraded), `journal.evidence.unconfirmed` (Unconfirmed), `journal.reason.approval` (Approval), `journal.reason.question` (Question), `journal.reason.planReview` (Plan review). Owning UI tickets use `String(localized:defaultValue:)`; C11-291 supplies six locales. Machine enum/error codes are not UI strings.

Parsing, SQLite, spool, fold, aggregation and retention stay off main. Each drain, prune and export batch drains an autoreleasepool per batch, without a new thread. One queued main.async projection updates only changed owner state, discarding an older sequence for that owner; no synchronous main wait for receipts. No filesystem work in hitTest, forceRefresh, Return/Esc handling or sidebar body. If a later consumer observes UI input, it queues a small structural value and measures impact against C11-270's registered baseline.

Acceptance/proof matrix. Incident names below are the C11-271 list, not claims that captures already exist. Import the finalized corpus from the fixtures worktree when delivered; synthetic cases are labeled synthetic. All executable validation occurs later on Atlas through C11-216, against an isolated tagged app/socket with `C11_QA_LAUNCH`; never the operator's session.

| AC | Incident / question | Behavioral oracle and later runtime proof |
|---|---|---|
| 1 | Bypass AskUserQuestion and ExitPlanMode | F3 replay enters blocked before any Notification; seen does not resolve it. Tagged bypass/normal flows and computer-use evidence of persistent attention. |
| 2 | Late async PreToolUse after Stop | Pure fold includes seq 10/11 with native and missing time, then a real next turn. Tagged delayed-hook injection stays completed until next prompt. |
| 3 | Esc interrupt | Replay supported interrupt and keypress-only variants; supported variant ends work, key-only remains uncertain. Tagged real interrupt plus source/coverage readback. |
| 4 | Restart while waiting; old open ask after 15 days | Temporary SQLite commit/force-kill/reopen, prune time and bytes; baseline retains ask, old working not painted. Tagged restart screenshot shows unconfirmed blocked/error and fresh reconciliation. |
| 5 | Sibling tool start clearing another tab's waiting | Two owners: B's tool activity leaves A's ask unchanged; seen/unread, suppression, flag and ⌥V regression checks on tagged UI. J2's oracle is A's journal row and blocked projection; the workspace-wide clear_notifications repair stays on C11-263/A1. |
| 6 | C11-189 child completion | Known-root mismatching callback cannot change parent state or notify; accepted root path still works. Missing-root fallback labeled legacy/unattributed. Existing guard fixture plus tagged callback smoke. |
| 7 | Audit §4 ambiguous ack, duplicate drain, truncated tail, stale ownership | Temporary-DB same-ID same/different draft cases; tagged lost-reply → spool → two drains yields one row/original receipt; stale ownership never targets a replacement tab. Explicit producer-before-spool loss is a documented limit. |
| 8 | Audit §7 resource/privacy; Q1..Q6 coverage | Synthetic sentinel bodies rejected before DB/spool/export; saturation, disk error, clock jump, byte-prune and gap tests preserve honest degraded/coverage results. F3 burst plus C11-270 baseline/candidate CPU, memory, I/O and typing comparisons on Atlas, using its pre-registered budgets. |
| 9 | Q1..Q6 above | Hand-computed structural timelines with source overlap, model/workspace move, seen-without-response, gap and clipping; verify six results and NDJSON round-trip parsing in J7. J2 verifies fields/interval effects through actual store APIs, not source-grep. |
| 10 | C11-188 review-loop incident | Independent Grok verdict on this exact plan and fixture/question matrix before J2 planning. Record findings and their disposition in Lattice; do not count this document as runtime proof. |

For visual proofs the validation brief must enumerate the Atlas display/window, impose a hard timeout, prove dismissal with synthesized input, and retain screenshots; inspect readable area sizes. No test runs, builds, UI launches, source edits or production changes have been performed for C11-272. Open decision count: zero; fixture delivery remains pending, and the Orchestrator has authorized C11-273 planning after these amendments.

## Review resolution: one cycle, architecture unchanged

Grok review `ev_01M3X6A1ZSCXEED76X4HF599T5` returned FAIL on plan SHA256 `2b4a43e839eb76e932bc7d02f228f53e3dd96a7a44ca5065c994d9a008bca5f4`. The Orchestrator directed sentence-level amendments, attests the delta without re-review, and authorized the next plan. No new mechanism was introduced.

1. Blocking 1, legacy hook activity bypass: §5 now makes append the managed hook path and the fold projection the sole derived activity writer; ordinary PreToolUse cannot independently set working.
2. Blocking 2, drain ambiguity: §4 rule 1 now folds drained lines through the normal transaction for their original owner, with unconfirmed blocked/error painting, newer live evidence taking priority, and unknown ownership unattributed.
3. Non-blocking 1, transcript overlap: §4 explicitly keeps rank-40 turn edges away from blocked and prevents an uncorrelated transcript start reopening a higher-ranked terminal barrier.
4. Non-blocking 2, autorelease lifetime: §8 requires an autoreleasepool for each drain, prune and export batch.
5. Non-blocking 3, sibling-clear ownership: AC5 limits J2's oracle to the journal row/blocked projection and keeps the workspace-wide clear repair on C11-263/A1.
