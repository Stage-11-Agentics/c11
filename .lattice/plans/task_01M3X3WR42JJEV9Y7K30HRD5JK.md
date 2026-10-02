# C11-264 plan: typed per-tab asks, `c11 feed list|open|watch`, `ask.opened`/`ask.closed`

Planning only. Implement after C11-273 and C11-263 merge. No second lifecycle reducer. Journal verbs, kinds, ranks, and fields stay as C11-272 / C11-273 specify them.

## Citations checked on `0ff8887e5e`

- `TerminalNotification` is `Sources/TerminalNotificationStore.swift:636`. `addNotification` at `:972` deletes every record for that workspace+surface, then inserts one. It is not a typed ask. At `:997` it also calls `TabLivenessDeriver.onAgentLifecycleChanged(..., .idle)`. That is the "unrelated notice erases the ask" incident. C11-273 already stops that idle write for a journal-managed owner. This ticket does not reimplement that guard.
- Flags are `TabAttentionSnapshot` / `TabAttentionIndex.oldestFlags` in `Sources/AttentionModel.swift:34` and `:179`. The ticket's `:375-429` range is `TabAttentionService`, not the flag store.
- `EventEmitter.emitWaiting` / `emitFlagRaised` are `Sources/Events/EventEmitter.swift:138-165`. No ask payload. The v1 type enum is closed in `spec/event-envelope.v1.schema.json:21` and `EventEnvelope.EventType`.
- `AppDelegate.jumpToLatestUnread` is `:10819`. `openNotification` is `:13423`. `WorkspaceManager.focusTabFromNotification` is `:3601`. A nil `surfaceId` substitutes `workspace.focusedPanelId` (`:3618`) and a later block marks the unread notification read (`:3642`). Feed open must not use that nil path.
- Ask text today is flattened by `CLI/c11.swift` `describeAskUserQuestion` (`:17117`) into session `lastBody`, including a fabricated `"Asking a question"` (`:17138`). Bypass PreToolUse returns before any notification (`:17006-17039`). `clear_notifications` at `:17042` is C11-263's bug. Do not edit those clear sites.
- No `Sources/Journal/` exists on this base. Consume C11-273's merged `JournalCoordinator` / current-row snapshot. Do not fork the schema.

## Authority

One row per tab, projected from three reads. None of them is a new fold.

1. Journal current row (C11-273): `phase`, blocked reason, `source`, rank, `since`, `request_id`, `turn_outcome`, `confirmation`, last applied sequence, fold effect. This is the only open/close authority.
2. `TabAttentionIndex` snapshot: flag reason, `flagRaisedAt`, caller tab, `suppressed`. A flag is a sibling fact on the row, never an ask kind and never a replacement of the ask.
3. Process-local display note: `prompt` and `options` only. See privacy.

Kind map, and only this map:

| Feed `kind` | Journal fact |
|---|---|
| `question` | current blocked request is `agent.question.requested` |
| `plan` | current blocked request is `agent.plan_review.requested` |
| `permission` | current blocked request is `agent.approval.requested` |
| `turn_end` | `phase=idle` and `turn_outcome=completed`, and the row is not blocked |

`input` is not emitted. The journal has no kind, tool class, or reason for generic input, and screen classification is out (ticket cut; screen rank stays parked). A snapshot whose blocked reason is anything else produces no ask. The test records that silence, not a fabricated `input` row. `source` is the journal source enum (`hook`, `plugin`, `transcript`, `shell`, `keypress`, `self_report`, `c11`, …) or null. Do not relabel it `hook` or `screen`. Rank is the journal rank, included so confidence is visible. `opened_at` is that request's blocked phase `since`, or the completed turn's idle phase `since`, in UTC milliseconds, or null. Never `Date()` at read time.

State:

- `open` while the fold still has that blocked request.
- `closed` only when the fold has left it.

Close fixtures, using the fold's own effects (this corrects report 03, which retired an ask on any same-tab tool start):

- Retire whenever the committed fold leaves or replaces this blocked request, including matching `agent.attention.resolved` (`resumed`, `cancelled`, or `unknown`) and a supported matching cancellation/turn boundary that the fold applies. A replaced request closes the old identity and opens the new one even if phase stays blocked. Feed does not reinterpret an advisory interrupt as a close.
- Do not retire: same-tab `state.changed` / `tool_activity`, generic `turn.completed` or `idle.observed` while blocked, a sibling owner's tool event, seen/unread, or `addNotification` of unrelated telemetry.
- A duplicate `event_id` (fold effect `duplicate_evidence`) does not open a second row and does not emit a second `ask.opened`.
- Replay on launch paints the current blocked/error baseline as `confirmation=unconfirmed`. It does not re-emit `ask.opened`.

Audit finding 2 is assigned: C11-274's amended plan emits `agent.attention.resolved/resumed` from the matching AskUserQuestion/ExitPlanMode PostToolUse `tool_use_id`, and its supported next-prompt continuation. C11-231 owns the separate body-free, request-correlated `state.changed/operator_response` observation. Feed consumes their committed fold outputs and adds neither producer nor reducer. Generic Stop/tool activity, seeing a tab, and generated keys remain non-resolutions/non-responses. If request identity or supported continuation is unavailable, retain blocked with its coverage/confirmation; do not synthesize an ID. C11-264 may implement after 263/273, but live answer/resume acceptance waits for merged 274 and 231. One Atlas bypass-question and plan trace must compare Feed, visible marks, agents JSON, resolution and the Q2 response observation before wave 2 passes.

Suppression: a suppressed tab with only a routine ask or `turn_end` is omitted from the attention projection. A flag on that tab stays. Suppression changes no journal row.

Default `feed list` is the attention projection: open blocking asks and flag rows, not `turn_end`. `feed list --scope all` adds non-suppressed `turn_end` rows so A4's filter has data. Both scopes call one projector.

## Privacy: where `prompt` and `options` live

They are shown only in the live `feed list` / `feed watch` JSON of this process.

- Not fields on `agent.event.append`. Unknown draft keys are rejected by C11-272, and the draft allowlist has no body slot.
- Not written to `lifecycle.sqlite3`, WAL, SHM, the spool, the event log, session `lastBody`, or tickets.
- `ask.opened` / `ask.closed` payload is structural only: `kind`, `source`, `source_rank`, `opened_at_ms`, `state`, `request_id`, `confirmation`, `blocking`, and on close `resolution` (`resumed` | `cancelled` | `unknown` | null). No prompt, options, plan text, tool command, cwd, or flag reason.
- After restart the journal row returns and `prompt` / `options` are null, with `prompt_available: false`. Null means unknown. Do not copy today's `"Asking a question"` fallback, and do not use `[]` to mean unknown options. `[]` is only a hook that actually extracted zero labels.

Display path: `feed.note_display` on the socket worker, separate from append. The hook adapter, at the existing PreToolUse branch C11-273 uses for AskUserQuestion and ExitPlanMode, copies a bounded note (prompt ≤ 1024 UTF-8 bytes, ≤ 12 option labels, each ≤ 128 bytes) and sends it with the append `event_id` after the structural append commits. Append plus note share the adapter's existing 250 ms delivery budget; a failed note is never spooled or retried on disk and never changes the append receipt. Oversize is rejected with a fixed code. The note is joined to the open ask by `event_id` / `request_id` and dropped if the fold has no matching open ask. OpenCode may forward text that `permission.asked` already carries. Do not widen plugin subscriptions or parse the screen. The cache is an in-memory lock on the app process, discarded on exit. Require the exact eligible owner plus target UUIDs and event/request identity; never join by tab number or timestamp alone. Drop notes on resolution, request replacement, session replacement, and tab close. Cap the aggregate at 256 notes / 512 KiB of accounted UTF-8 payload; reject overflow with a fixed code, leaving the structural ask intact. No cache eviction changes the fold. Missing, failed, or out-of-order note delivery simply leaves unknown display text. For managed asks the adapter bypasses today's `describeAskUserQuestion` -> session `lastBody` persistence and body-bearing notification path, forwarding display text only to this cache. Keep unmanaged legacy compatibility separate and document its existing storage; never promise that this PR erases previously persisted notification bodies. Inspect merged C11-263/273/274 before wiring that branch, so their scoped-clear and structural append mappings survive.

## Files and behavior

- `Sources/Feed/FeedProjector.swift` — pure `project(journalRows:attention:notes:scope:) -> [FeedRow]`. No I/O.
- `Sources/Feed/AskDisplayCache.swift` — memory map, bounds, drop-if-unmatched.
- `Sources/Feed/FeedProjectionBridge.swift` — journal/attention changes supply immutable snapshots; project and diff on a serial worker, then publish only changed values with `main.async`. Discard a stale per-owner sequence. Emit ask events from applied blocked-request changes, never from a scope/suppression/view filter; a flag-only row is not an ask. Request A -> B emits close(A), open(B); replay establishes a baseline without opening again. Display-note arrival refreshes the cached row without creating an ask event. Do not scan tabs on a timer.
- `Sources/SocketHandlers/FeedHandlers.swift`
  - `feed.list` and `feed.note_display` in `socketWorkerV2Methods`. Parse off main. No focus, no activation.
  - `feed.open` is focus intent. Require the row's workspace UUID and tab UUID. If `workspaces` has no such workspace or `panels` has no such tab, return `{ "error": "unavailable" }` and focus nothing. Resolve the owning window/context across all workspaces first and validate both UUIDs before any selection. Use `selectWorkspace` (`WorkspaceManager.swift:2808`) and `workspace.focusPanel` on that context, without activating or raising a window. Register `feed.open` in `focusIntentV2Methods`; add its dispatch route, while list/note remain worker verbs. Do not call `focusWorkspace` (`:3562` queues `NSApp.activate` and `makeKeyAndOrderFront`), `focusMainWindow` (can orderFront), `focusTabFromNotification`, `openNotification`, `markRead`, or `send`. Keep the exact resolver reusable by UI actions; in-app selection is the socket guarantee, not macOS foreground activation. Do not substitute the focused tab.
- `CLI/FeedCommand.swift` plus `case "feed"` in `CLI/c11.swift` `run()` (near `list-notifications`, `:3068`) and the help text (`:17947`, `:9761`).
  - `list [--json] [--scope attention|all]`. Human table and JSON. `--json` is the contract Overwatch reads.
  - `open <tab>` resolves the ref the way other commands do, then `feed.open`. Prints `unavailable` when the app does. Never sends an answer.
  - `watch [--json]` prints one list snapshot, then follows the event log for `ask.opened`, `ask.closed`, `flag.raised`, `flag.lowered`, `flag.suppressed`, `flag.unsuppressed`, `log.opened`, `log.rotated`, `log.dropped`. On a new instance, a seq gap, or `log.dropped`, print `{"continuity":"unavailable"}` and print a fresh snapshot. Bind the follower to the app instance/event-log identity returned by `feed.list` on the selected socket, never whichever production/tagged log has newest mtime. Every second re-read the cached projection and identity to detect app restart/reconnect, late display-note arrival, turn-end changes and an unreported tail drop; emit a snapshot only when it changes. This worker-side CLI reconciliation does not scan UI tabs. The existing `runEventsTail` (`CLI/c11.swift:19126`) holds one `logURL` forever and cannot be reused unchanged for reconnect. Buffer partial NDJSON lines, process sequence continuity before event filtering, and handle rotation/missing logs/socket-unavailable with explicit continuity status. Establish the follower before the initial snapshot and refresh once after subscription; do not claim an atomic snapshot/cursor transaction or durable history.
- Packaging/routing: add new Swift files to their actual app/CLI/test compile entry points; shared feed value types must compile in the CLI where used. Register handlers in `SocketDispatch`, execution-policy sets in `TerminalController`, and the landed capabilities registry (C11-284) for the shipped Feed commands. Verify the built CLI help and socket capabilities on Atlas, without source-grep tests.
- Event enum: add the two types to `EventEnvelope.EventType`, `spec/event-envelope.v1.schema.json`, and `EventEmitter`. Keep envelope `v = 1`.
- Skill: `skills/c11/references/api.md`, `references/events.md`, and one map line in `skills/c11/SKILL.md`. After the source edit lands, `scripts/sync-installed-skills.sh c11` and confirm the installed copy. Do not sync during planning.
- Tests compile in the app / `c11LogicTests` targets. Pure tests do not need a host. No new localized UI strings in this ticket, so no xcstrings keys. CLI prose stays with the existing English `CLIError` style. Machine codes (`unavailable`, `prompt_available`) are not product strings.

## Acceptance → oracle → proof

| AC | Oracle | Proof |
|---|---|---|
| 1. Typed JSON for question, plan, permission, turn completion; unknown source/options stay null | F3 bypass AskUserQuestion / ExitPlanMode shapes, plus a completed-turn current row | `FeedProjectorTests` in `c11LogicTests` feeds fold snapshots. `input` fixture asserts no row. Synthetic prompt appears in the row only when a note is attached, and is absent from a temp journal DB opened in the same test. |
| 2. Flag + question coexist; unrelated notice and sibling tool do not retire; matching resolution does | F3 sibling clear; `addNotification` replace; fold `attention.resolved` | Same tests. A flag snapshot plus a blocked question is one row with both facts. Sibling `tool_activity` and same-tab `tool_activity` leave `state=open`. |
| 3. `ask.opened` / `ask.closed` once, bounded payload | Journal duplicate-receipt case | Bridge test: applied transition emits one event; `duplicate_evidence` emits none. Request replacement emits close(A)/open(B); resolution=unknown follows the fold, and suppression/filter changes emit no false close. Encode emitted event bytes and verify the synthetic prompt/options are absent; fill the cache to its aggregate cap and confirm the next note is refused without erasing a structural ask. |
| 4. list and watch agree across open, close, suppression, restart | Restart-while-waiting; suppression doctrine | Projector cases for suppression and `confirmation=unconfirmed` with `prompt_available=false`. `tests_v2/test_feed_list_watch.py` on an isolated guest: list, suppress, reconnect, compare watch's snapshot. A dropped event line yields `continuity=unavailable` and a new snapshot. Restart changes the instance while the old log still exists; late display-note and completed-turn updates also appear. A partial line is held until complete; unrelated event types do not create false sequence gaps. |
| 5. open hits that tab; closed tab is unavailable; list/watch do not focus; no answer is sent | Jump substitution via nil surface (`focusTabFromNotification:3618`) | `tests_v2/test_feed_open.py`: two workspaces, open the non-focused tab, assert that tab is focused and the other got no input. Unknown UUID returns `unavailable` and the focused tab is unchanged. Add a second c11 window and an unrelated frontmost app: open selects the exact addressed context without macOS app activation/window raising; failure performs no selection. list/watch assert the focused tab is unchanged. |

Atlas, after BUILD MODE, through C11-216, tagged app, `C11_QA_LAUNCH=fresh`: two workspaces, one flag-plus-ask tab. Compare `feed list --json`, the event line, and the tab focused after `feed open`. Screenshot the focused tab. Computer use enumerates the display, has a hard timeout, and proves dismissal. Record the artifact SHA. Logic tests are not that proof.

Hot path: projection runs only from the journal changed-snapshot hop, off the keystroke path. No work in `hitTest`, `forceRefresh`, or sidebar `body`. On Atlas, compare typing and main-thread stalls to the C11-270 registered baseline. Do not invent a new threshold.

## Cut line

Out: automatic answering, `feed answer`, menu-key typing, banners, quick view (C11-266), attention ordering and menu-bar counts (C11-265), screen classification, new hook subscriptions, blocking waiters, workspace-wide clear repair, menu-bar flag repair, notification command IDs (C11-263), mailbox/`send` (C11-257), journal schema or fold changes, persisting prompt text anywhere.

## Dependencies

Depends on C11-273 (fold, current rows, append, replay) and C11-263 (scoped clears, bypass delivery, flag visibility, notification IDs). Implement only after both merge. C11-265 and C11-266 read this projector. C11-291 owns translations; this PR adds no UI strings.

Open decisions: none. Generic `input` stays unsupported because the attested journal has no such kind; state that limitation in Feed help and skill text. Do not extend the journal without its owner. Resolution/response acceptance uses C11-274/C11-231 as assigned, not P2 replies. Takeover verification: `agent:codex-feed`, base `0ff8887e5e965400b01645ef40b85fd0b2605cf2`; no builds/tests/product edits performed.

## Reset 2026-10-02 by agent:luna-264
