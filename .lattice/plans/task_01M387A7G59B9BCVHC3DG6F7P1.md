# C11-231: journal-backed agents snapshot, lifecycle edges, clocks, restore candidates

Owner: `agent:codex-history`. Planning only. Implementation waits for `BUILD MODE` and for C11-273 to be on `origin/main`. Branch, created only then: `c11-1.0/C11-231-agents-json` from that `origin/main`. If that merge is absent, send `BLOCKED` and stop. No product edits have been made for this plan.

## Contract check

Binding specs, read against this plan and not reopened:

- C11-272 `.lattice/plans/task_01M3X3XPJSSY6XSPBYGP6VCSRR.md`, SHA256 `53e75e66167e359f13aeb1621d1c1e44088552619e08f15a0f514658403c156c` (the hash C11-273 attests).
- C11-273 `.lattice/plans/task_01M3X3XPNP88K5250NDJPYK02S.md`, SHA256 `2f3298bb67f8bc78574c71935cb97825b4521c4fb2c87ce7c93d394549d78ba8`.

No field this ticket needs is missing. These readings are bindings, not new design:

- Live `state` is journal `phase` (`unknown|working|blocked|idle|error`). JSON key is `state` because J6 names it that. Values are the phase enum, not a second vocabulary.
- `reason` is the journal reason enum (`approval|question|plan_review`) or null. The 2026-09-23 list `agent_prompt|permission|flag|unknown` is not the wire vocabulary. A flag is attention state, not a waiting reason.
- `since` is the current row's phase start. The turn clock is the applied `turn.started` time for the current `turn_id` (`occurred_at_ms` when `time_quality=native_local`, otherwise `committed_at_ms`). That time is already on the event. This ticket caches it in memory. It does not add a SQLite column.
- Model is the `model_id` already stored on events (null when the existing bounded metadata had none). The reserved J6 snapshot does not carry it; this ticket joins it. It does not scrape today's metadata over the event-time value.
- The correlated human submit response for Q2 is this ticket's observation. C11-272 §7 named Feed/J6; this repair assigns the observation to J6. Seeing a tab updates `last_seen_at` only and appends nothing. This ticket does not append `attention.resolved` and does not clear `blocked`. C11-274 still owns continuation and resolution.
- `active`, `seen`, `launched`, `touched`, `tools`, and `tokens` stay on their current sources. The schema has no tool-count or token-count field, and AC4 names state and turn clocks. Tools and tokens stay transcript-derived.

## Verified baseline

Citations checked on `0ff8887e5e965400b01645ef40b85fd0b2605cf2`.

- `Sources/Events/EventEmitter.swift:138` `emitWaiting` takes a bool and an optional surface and sends no reason.
- `Sources/Events/EventEnvelope.swift:51`–`:52` names are `waiting.entered` and `waiting.left`. There is no `waiting.exited`.
- `Sources/TerminalNotificationStore.swift:781` emits those two on the workspace unread 0↔1 edge, with `surface: nil`.
- `Sources/TabLivenessDeriver.swift:13` returns `.waiting` for an exact unread notification. That conflation stays the attention projection. Journal blocked state stays a separate field.
- `Sources/TabSheetDetail.swift:33` is `stateEnteredAt`; `:50` is `turnStartedAt`. The ticket's `:32` and `:49` are off by one. The `Workspace` extension in **`Sources/TabSheetDetail.swift:292-353`** fills them at `:339` and `:348`, not `Sources/Workspace.swift:339`. That is the clock-wiring edit site.
- `Sources/TabSeenClock.swift:151` is `lastSeenAt`. `storedLastSeenAt` is `:157`.
- `Sources/Events/EventLog.swift:51` caps the file at 8 MiB; `:74` drops when `maxPending` (4096) is saturated. That log is not journal truth.
- No `c11 agents` or `c11 journal` command exists. `CLI/c11.swift:1950` focuses a window before the command switch when `--window` is set. These commands must connect on their own path and never send `window.focus`.
- `system.identify` returns `bundle.identifier` (`SystemHandlers.swift:417`).

## What ships

One read model over C11-273's committed snapshot plus existing flag, suppression, and seen stores. No second fold and no change to `TabActivityResolver` precedence.

### `c11 agents` and `agents.list`

CLI: `c11 agents [--json]`. `--json` is accepted before or after the verb, same as other commands. Human output is fixed columns, English, like `c11 config stats`. No new localized UI strings.

Socket method `agents.list` is a worker method (`socketWorkerV2Methods`), advertised in `v2Capabilities`. It is not focus-intent. Parse off main. Copy the reserved per-tab snapshot, flag, suppressed, and `storedLastSeenAt` with one short main hop. Do not open SQLite on main and do not activate the app.

When the app is down, `tabs` is `[]` and `live_identity` is `unavailable`. Restore candidates still come from a read-only open of that bundle's journal. Resolve a live namespace with `system.identify`; for offline use require explicit `--bundle-id <identifier>` (or an injected test layout). Do not guess a tagged bundle id from an absent socket. Validate the identifier with C11-273's layout helper; documentation includes one offline example. If a live identify and explicit bundle id disagree, reject rather than reading a different namespace. Tests resolve the bundle with `system.identify` on the tagged socket and abort if the path is `~/Library/Application Support/c11/journal/com.stage11.c11/`.

JSON, schema 1, explicit nulls (ISO8601 seconds for times):

```json
{
  "schema_version": 1,
  "live_identity": "available|unavailable",
  "coverage": {"health": "ok|degraded", "storage": "ok|unavailable"},
  "tabs": [{
    "tab_id": null, "workspace_id": null, "session_id": null,
    "kind": null, "model": null,
    "state": null, "reason": null, "since": null, "source": null,
    "freshness": null, "confirmation": null, "connection": null, "health": null,
    "turn_outcome": null, "turn_started_at": null,
    "flag": false, "suppressed": false, "last_seen_at": null
  }],
  "restore_candidates": [{
    "tab_id": "", "agent_kind": "", "session_id": "",
    "label": "historical_candidate|ended|unknown",
    "state": null, "reason": null, "since": null,
    "confirmation": "unconfirmed", "connection": "disconnected|unknown",
    "coverage": "retained|event_pruned"
  }]
}
```

`source` uses the journal source enum (`hook|plugin|transcript|screen|shell|keypress|self_report|c11`). `freshness` is `fresh` or `stale` by the spec's 30-second rule. A tab with no journal row has `state` and the journal fields null, and still reports flag, suppressed, and `last_seen_at` from the existing stores.

`session_id` is the opaque owner id the journal already stores. Fixtures and tickets use synthetic ids only.

### `lifecycle.changed`

Add `lifecycle.changed` to `EventEnvelope.EventType` and to the v1 list in `spec/event-envelope.v1.schema.json`. Do not bump the envelope version and do not rename `waiting.left`.

Emit from C11-273's changed-projection callback only when the committed fold effect is `applied` and `from_phase != to_phase`. Payload is exactly `{tab, agent, from, to, reason}` plus envelope `surface` = tab UUID and `workspace`. `duplicate_evidence`, `stale`, `advisory`, `observation`, `child`, and `unattributed` emit nothing. Enqueue onto `EventLog`; do not wait for the write. A saturated EventLog may drop the line. `agents.list` is the recovery read. Never reconstruct a snapshot by tailing the event log.

Compatibility, written into `skills/c11/references/events.md`: `waiting.entered` / `waiting.left` stay the unread 0↔1 edges from `emitWaitingEdges`, still without a journal reason. They are not blocked asks. Blocked asks are `lifecycle.changed` rows whose `to` or `from` is `blocked`, with the journal reason. Do not emit a second `waiting.entered` for blocked, or the 154/492 workspace counts gain a second meaning.

### Clocks

For a journal-managed tab, `Workspace`'s tab-sheet builder reads the in-memory cache, not SQLite:

- State clock: `since` (phase start).
- Turn clock: cached `turn_started_at` for the current `turn_id`.
- Fill the cache off main when that transition is applied, and once during the existing startup replay, from the retained `turn.started` row. If that row is outside coverage, the clock is nil and the sheet shows the existing em dash. Do not estimate.
- Unconfirmed or disconnected: the displayed turn elapsed time ends at the snapshot's `observed_at`, not at `Date()`. Add an optional explicit turn-end input to `TabSheetDetailBuilder` so a legacy `.running` activity cannot force the `input.now` branch (`TabSheetDetail.swift:72`); leave unrelated clocks on their existing sources. For unconfirmed phase timing, omit a live `Status.since` and show the reused `journal.evidence.unconfirmed` qualification, retaining historical `since` in agents JSON. A nil since avoids a renderer ticking through the crash gap; do not substitute a shifted fake date. Confirmed phase clocks use journal since only when the displayed state represents that phase. A flag retains its flag-raise clock; unread-only waiting retains its notification clock, since neither is a journal blocked phase. No bonsplit API or submodule change is required.
- Unmanaged tabs keep today's `AgentModelDetector` clocks.

Opening the tab still goes through `TabSeenTracker`. It must not append a journal event.

### Operator response (Orchestrator repair)

Fixture **J6-bypass-AskUserQuestion-operator-submit**: on the pinned Claude Code version, a bypass-mode root asks AskUserQuestion; the operator looks at its tab, types/edits without submitting, then submits an answer. Repeat with the fixture's option picker: changing the highlighted option is not a response; a positively observed option-commit key is. Follow the submitted answer with C11-274's correlated agent continuation/resolution. Use synthetic question/options/answer only. Record harness version and which physical key actually committed the selection; do not assume digit/arrows/Space commit rather than edit, highlight or toggle. Reuse C11-271's normalized captured case when available, preserving its provenance.

Cache the current applied open ask off main: owner, native request id (if present), **ask event id**, ask-opened timestamp, and the bounded provider/ask-mode submit policy. Keep this value available for one constant-time input lookup. The ask event id is the per-ask identity: repeated request strings in different asks or sessions do not share a dedupe slot.

While this tab has an open ask, an **operator-originated submit** enqueues one structural observation for that ask. Submit means terminal Return/keypad Enter outside IME composition, a text-box Send/submit, or a menu/option commitment key positively established by the provider's named picker fixture. For picker shortcuts, C11-231 owns the small submission-key policy over structural ask mode; test both a committing key and an editing/highlight key. Do not add terminal-body classification or infer a submitted answer from arbitrary input. Capture no key character, answer, option label or text. Unknown picker modes have no guessed response and report the supported coverage honestly.

- `GhosttyTerminalView.keyDown`, Return/Enter submission at `Sources/GhosttyTerminalView.swift:5666-5676`: require `!isSynthesizingKey`, `!event.isARepeat`, and no marked-text composition. Ordinary Return submission excludes command/control/option/shift combinations unless the named fixture proves a combination commits the relevant picker. A fixture-proven picker option-commit key uses the same guarded path. Do not append from the touched stamp at :5646.
- `Sources/TextBoxInput.swift:844` `submit()` handles the Send button and `.submit`. Observe once there; not on arbitrary `onKeyEvent` (:783), draft `.onChange` (:832), or generated Return in `TextBoxSubmit.send`.
- `sendSyntheticKey` (:4069) marks `isSynthesizingKey`; `c11 send`/send-key never append a response. Seeing a tab, typing/editing, highlight/navigation, repeated key events, and focus/selection clicks append nothing. A Send-button click is an actual UI submission.

The writer creates `state.changed`, `signal=operator_response`, `source=c11`, with the same owner and correlation key. Use the open ask's request id when present; otherwise put its existing ask event id in the response's `request_id` as the documented fallback. Thus J7 joins `response.request_id` to `(ask.request_id ?? ask.event_id)` under the same owner without adding a schema field or altering the immutable ask. Store the ask's event id in the bounded in-memory submission/dedupe record; the durable correlation is recoverable from existing event fields. Do not fabricate an unrelated request id.

Emit once per `(owner, ask.event_id)`. Suppress another enqueue for that tuple while its bounded admission is pending; mark recorded only after admission and leave a rejected observation retryable. Duplicate native delivery and an additional submit for the same still-open ask do not produce another sample. A new applied ask re-arms the observation. If no open ask can be positively identified, append nothing. No SQLite, key/text capture, formatting, or general event aggregation on the keystroke path.

`source=c11` is observational rank 0. This response event does not clear blocked, lower flags itself, resume an agent or emit `lifecycle.changed`; C11-274 owns the correlated continuation/resolution. Preserve the existing Return-to-working call under C11-273's journal-authority guard, so a legacy activity write cannot clear a managed ask. Existing direct-interaction flag/notification policy remains separate.

C11-277 Q2 pairs the same-owner response with the applied ask via that correlation key and computes **`wait = response.ts - ask.opened`**. Both are journal observation timestamps in the named fixture, using `observed_tick_ns` for elapsed time within an app instance, with committed timestamps defining the query window. Seeing/typing events add no sample; agent resume is a separate latency. If ask/response evidence is missing, pruned or crosses an unobserved gap, report unavailable/censored instead of a fabricated full wait.

Hand-computed structural variant of J6-bypass-AskUserQuestion-operator-submit: ask.opened=1,000 ms; viewed=2,000; draft input=3,000; actual submit response.ts=5,500; repeated submit=6,000 (no second event); resumed=7,000. Q2 wait is 4,500 ms, count 1; request-to-resume is separately 6,000 ms. Viewing/draft input leave blocked unchanged and contribute no Q2 sample. These synthetic fixture values test the formula; the captured bypass run supplies real runtime evidence later.

### Restore candidates

Add `JournalStore.listCurrent()`, a read of the existing `journal_current` columns. No new column and no migration.

A prior-run row that is still unconfirmed is classified from the stored terminal/lifecycle evidence and a bounded retained owner timeline, not merely the kind at `last_applied_sequence`: later connection/control observations may replace that pointer while preserving a prior session end.

- established `session.ended` after the latest recorded session start → `ended`
- recorded start with no later recorded end, consistent with the retained baseline → `historical_candidate` (not proof the process is currently live)
- needed start/end evidence pruned or unreadable, or no known start → `unknown`, with coverage loss explicit

Use bounded owner-indexed reads off main; do not add a new state authority or schema column. Fixture: session.started → session.ended → connection observation still labels ended, not candidate.

Unattributed rows stay out of the list (the spec excludes them from state). Report only their count inside `coverage`. Ambiguous `journal_owner_tab_id` matches stay candidates; C11-273 owns the mapping. This command never launches, resumes, or focuses.

## Files

- `Sources/Journal/AgentRoster.swift` — pure snapshot join. No I/O.
- `Sources/SocketHandlers/AgentRosterHandlers.swift` — `agents.list`.
- `Sources/Events/EventEnvelope.swift`, `EventEmitter.swift`, `spec/event-envelope.v1.schema.json`, `spec/README.md` — the one new type.
- Projection callback in C11-273's `JournalCoordinator.swift` — emit `lifecycle.changed`, refresh the turn-start cache, and append the one `operator_response` draft from the guarded submit enqueue. No fold change.
- `Sources/Journal/JournalStore.swift` — `listCurrent()` and bounded retained owner-lifecycle read only; no fold/schema change.
- `Sources/TabSheetDetail.swift` Workspace extension (`:292-353`) and builder turn-duration branch (`:72`) — journal-managed phase/turn clocks and explicit historical end from the cache. Extend existing `c11Tests/TabSheetDetailBuilderTests.swift` with executable frozen-clock and flagged/unread cases.
- `Sources/GhosttyTerminalView.swift` Return submission (`:5666-5676`) and `Sources/TextBoxInput.swift` `submit()` (`:844`) — enqueue the struct. No response work at touched stamps (:5646/:783/:832). Not `mouseDown` (`:6418`).
- `CLI/c11.swift` — `agents` branch before the `--window` focus preamble (`:1950`), including offline `--bundle-id`. `Sources/TerminalController.swift`, `Sources/SocketHandlers/SocketDispatch.swift` worker switch and `SystemHandlers.swift` capabilities route/advertise implemented `agents.list`; serialize these shared integrations through the Orchestrator after C11-257.
- `skills/c11/references/events.md` and `references/api.md` — compatibility plus the verb. Run `scripts/sync-installed-skills.sh c11` in build mode. C11-278 still owns the doctrine pass.
- Tests: `c11Tests/AgentRosterTests.swift` registered in `c11LogicTests`; `tests_v2/test_agents_roster.py` on the tagged socket.

pbxproj membership for the new Swift files. Review membership, not the gem's whitespace. No submodule edits. No `dlog`.

## Acceptance

| AC | Incident / question | Proof |
|---|---|---|
| 1 | F3 two-tab shape: A blocked, B working. Probe could not name the waiting tab. | `AgentRosterTests` on a synthetic two-owner snapshot: A's `reason` and `source` are the journal values, B's `state` is `working`, missing model is null. Tagged `c11 agents --json` matches. |
| 2 | Seen-but-not-answered, an actual operator submit while an ask is open, and unread completion vs blocked. Flag and suppression routing stays. | Store test: seen changes `last_seen_at` and appends nothing. Typing/editing/navigation/IME composition append nothing. One operator-originated Return, text-box Send or fixture-proven picker option-commit while an ask is open appends one `state.changed` `signal=operator_response` for that request and leaves `state=blocked`. A repeated key and a second submit for the same owner/ask event append nothing. A new ask event (including reuse of a native request string in the same or another session) produces its own observation. An ask without native request id correlates through its ask event id. `c11 send` of a key, and a focus/selection click, append nothing. A blocked row lacking both identifiable open ask event and request appends nothing; a real open ask lacking native request id uses its event id. Clearing unread leaves `state=blocked`. Existing flag/suppress precedence still decides the attention mark. Tagged computer use: open the blocked tab and type nothing, confirm the ask is still blocked and no response row exists; type/edit an answer without submitting and confirm no observation; then submit Return through macOS input (not `c11 send`) and confirm exactly one observation while phase remains blocked. Repeat using text-box Send; record supported submit coverage. Repeat J6-bypass-AskUserQuestion-operator-submit using the captured picker commitment key: selection navigation emits nothing; commitment emits exactly one response for the open ask. A TUI choice with no positively identified submit remains unavailable for Q2. Open an unread completion and confirm only the unread mark clears. |
| 3 | 2026-09-23 waiting events had no surface or reason (154 and 492). | Tagged run: one applied blocked transition produces one `lifecycle.changed` with tab, agent, from, to, reason. A repeat of the same observation produces none. `events tail` still shows `waiting.left`, never `waiting.exited`. The events.md paragraph is the compatibility record. |
| 4 | F3 state/turn timestamps; restart must not invent work across a gap. | Fixture timestamps equal `since` and `turn_started_at` after reopen. Unconfirmed elapsed excludes the gap. A pruned turn row yields null, not a guess. Tagged computer use reads the sheet clock against the JSON `since`. C11-271's corpus replaces the synthetic timestamps when it arrives; until then the fixture is labeled synthetic. |
| 5 | Upstream crash listing (#14870): start without end, without launching. | Three rows label `historical_candidate`, `ended`, and `unknown`. The command's process list does not gain a launched agent, and it sends no focus or launch method. |
| 6 | EventLog drop (`EventLog.swift:74`) and a disconnected/degraded journal. | Saturate the event log, then `agents --json` still returns the journal phase, source, freshness, connection, and health. The focused tab is unchanged. |

Computer use: enumerate the display, name the tagged bundle and socket, hard stop 20 minutes, prove quit, crop to the tagged window, synthetic titles only. `c11 tree --no-layout` before success.

Hot path: no work in `hitTest`, `forceRefresh`, or `WorkspaceRowView`. `keyDown` adds one in-memory open-ask read only on a real submit and, only for a new open ask event, one structural enqueue for the current open ask. No SQLite and no string work there. The sheet reads the cache. SQLite and EventLog stay off main. Typing comparison uses C11-270's registered budgets during a snapshot refresh; if those budgets or the baseline are absent, record `soak: unverified` and do not invent milliseconds.

Localization: no new `String(localized:)` keys. Reuse C11-273's `journal.*` keys. CLI text stays unlocalized, like existing command errors.

## Cut line

No Feed UI, no key or prompt text, no `attention.resolved`, no auto-resume, no sidebar or ⌥V redesign, no suppression-policy change, no focus history, no analytics query or NDJSON export (C11-277), no producer widening (C11-274..276), no token or tool columns, no tenant-config writes, no C11-257 send/mailbox files, no second blocked reducer. Defects in the fold go back to C11-273; this seat does not patch them unless the Orchestrator assigns that repair.

## Dependencies and handoff

C11-273 merged is the start gate. C11-216 is the Atlas route. C11-270 milestone M1 supplies the published baseline/budgets; do not wait for M2 or ticket completion. C11-263 owns the workspace-wide notification clear; do not duplicate it. C11-278 documents doctrine; this ticket only adds the verb and the waiting-compatibility paragraph its AC3 requires. C11-291 has nothing to translate unless a later repair adds a string.

Open human decisions: none. Review cap: three cycles, then Atin. Do not merge, do not mark done, and do not fill a sign-off.

## Codex takeover verification

Verified clean base `0ff8887e5e965400b01645ef40b85fd0b2605cf2`; attested C11-272/273 hashes still match. Audit finding 2 assigned the response producer here, but the inherited first-keystroke implementation contradicted Q2's actual UI-submit contract. Corrected submit-only capture, per-owner dedupe, the misplaced TabSheetDetail wiring citation, frozen historical clocks, offline namespace resolution and ended-session classification after control observations. The live answer/resume trace must compare agents, journal, Feed and visible attention on one integrated build with C11-274; submission alone is an observation and does not resolve the ask. Builds/tests/CUA remain unperformed; no human decision.

Orchestrator submit repair: supersedes the inherited first-key wording. Named bypass AskUserQuestion fixture, request/event correlation, once-per-ask admission, actual Return/option-commit/text-box submits, synthetic-key exclusion and Q2 wait formula are bound above. No product code, tests or builds performed.

## Reset 2026-10-02 by agent:codex-history
