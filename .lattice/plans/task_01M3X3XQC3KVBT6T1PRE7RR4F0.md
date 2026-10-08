# C11-277: lifecycle analytics query and NDJSON export

Owner: `agent:codex-history`. Planning only. Implementation waits for `BUILD MODE` and for C11-273 to be on `origin/main`. Branch, created only then: `c11-1.0/C11-277-journal-analytics` from that `origin/main`. If that merge is absent, send `BLOCKED` and stop. No product edits have been made for this plan.

## Contract check

Binding specs, not reopened:

- C11-272 `.lattice/plans/task_01M3X3XPJSSY6XSPBYGP6VCSRR.md`, SHA256 `53e75e66167e359f13aeb1621d1c1e44088552619e08f15a0f514658403c156c`. Section 7 is the metric and export contract.
- C11-273 `.lattice/plans/task_01M3X3XPNP88K5250NDJPYK02S.md`, SHA256 `2f3298bb67f8bc78574c71935cb97825b4521c4fb2c87ce7c93d394549d78ba8`. `readPage` is the read seam. Query, export, and clear are this ticket.

The schema serves every named question. Live Q2 is the wait from a blocked request id to a later same-owner `state.changed` with `signal=operator_response` for that open ask, joining the response's request_id to `(ask.request_id ?? ask.event_id)`. The event-id fallback supports an ask with no native request id. C11-231 records that observation from an operator-originated submit (Return, text-box Send or the named fixture's option-commit key), once per applied open ask; pre-submit typing and synthetic keys are not responses. This ticket reads those events. It does not append them. A window with no such event reports `status=unavailable` and null waits. That is the no-observation case for that window, not a missing producer. Do not invent a response from seen, from `c11 send`, from a focus/selection click, or from the agent resuming. A real text-box Send click is a supported submission. A fixture may contain the structural event so the formula is tested without the live key path. That is not a schema gap.

## Verified baseline

On `0ff8887e5e965400b01645ef40b85fd0b2605cf2`:

- `Sources/AgentLaunchStats.swift:5` and `:130` are launch counts. `c11 config stats` (`CLI/ConfigCommand.swift:133`, socket `config.stats`) reads them. This ticket does not change those files or that JSON.
- `Sources/Events/EventLog.swift:51` and `:74` are the lossy telemetry log. Analytics does not read it.
- No top-level `c11 stats` and no `c11 journal` command exist.
- `CLI/c11.swift:1887` handles `config` before socket connect. `c11 journal query` and `export` follow that app-down pattern. `clear` uses the socket when this namespace's app is running, because the in-memory fold has to reset.
- `system.identify` returns `bundle.identifier` (`SystemHandlers.swift:417`). The journal path is C11-273's `journal/<bundle-id>/lifecycle.sqlite3`.

## CLI

`c11 journal query|export|clear`. Not `c11 stats`, so it does not sit beside C11-178.

The command resolves a live namespace from `--socket` via `system.identify`. Offline query/export/clear require explicit `--bundle-id <identifier>` (or an injected test layout); an absent socket cannot identify its tagged bundle. Validate through C11-273's layout helper; a live identify/explicit-id mismatch is an error. Document an app-down example, and reject before writes if the selected namespace is ambiguous. It connects on its own and never sends `window.focus`, even if a global `--window` is present (`CLI/c11.swift:1950` must not run for this verb). Tests abort when the resolved directory is the production bundle `com.stage11.c11`.

| Verb | Behavior |
|---|---|
| `query` | Read-only WAL connection, 500-row pages, autoreleasepool per page, separate from the writer's queue. App-down. Flags: `--agent`, `--model`, `--workspace`, `--from`, `--to` (epoch ms or ISO8601), `--stall-ms` (default `900000`). `--json` before or after the verb. |
| `export` | Same read seam. NDJSON to stdout, or to `--output` when the path has no URL scheme. Never uploads. |
| `clear` | Requires `--yes`. With the app up, socket `journal.clear` on the writer queue. With the app down, delete this namespace's history, current, and spool only. Does not delete conversations, snapshots, launch stats, or tenant files. Without `--yes`, delete nothing and exit with a fixed message. |

Implement the public read product in the CLI's own read-only connection. Advertise only socket methods actually implemented: `journal.clear` joins both `socketWorkerV2Methods` and `socketWorkerV2Response` plus capabilities; this plan does not invent unimplemented `journal.query`/`journal.export` socket capabilities. Query and export prefer the CLI's own read-only connection so a long read cannot sit on the writer queue. `journal.clear` is the one that must run on the writer. None are focus-intent. Advertise them in `v2Capabilities`.

## Interval math

Walk `fold_effect=applied` transitions in committed sequence. Do not reorder by native occurrence time. Native times stay on the exported event and are not the metric clock.

An interval begins at the committed transition in sequence order. Within the same `app_instance_id`, compute elapsed duration from `observed_tick_ns`, as C11-272 §7 requires; wall committed time locates/clips the requested time window but is not the duration oracle. Apply phase boundaries plus connection, health, confirmation and recorded model/workspace-control boundaries even when `from_phase == to_phase`; an observation can split attribution/coverage without creating a turn. End a prior-run interval at the last writer observation belonging to that process/owner and mark the following crash gap censored. Never extend a prior-run interval to the new process's latest global journal_meta observation. Never charge the time until relaunch as working or as operator wait. A clock rollback is an unknown gap; durations are never negative.

Clip to the intersection of `[from, to)` and retained coverage. A start before that intersection is left-censored and contributes only the overlap. A current live confirmed row that still occupies the phase is `ongoing`, not a finished response. Unconfirmed and disconnected rows end at the last writer observation.

Confirmed phase totals exclude unconfirmed, disconnected, degraded, and unknown time. Those four have their own counters. Unknown model is the group `"unknown"`, not a dropped row. Workspace and model splits follow the app control observations recorded on the events, not today's metadata.

## Metrics

Units live on the JSON: durations in milliseconds; blocked minutes are `ms/60000` beside the ms value; rates are counts per covered hour. Covered hours are the covered window length in hours. Zero covered hours makes `per_hour` null.

| Question | Definition |
|---|---|
| Q1 time in state | Sum clipped applied intervals per phase. Restart-while-waiting and the late-hook trace must not add working time. The seq-10 Stop / seq-11 stale PreToolUse case stays completed. |
| Q2 operator response | Applied ask-open to a later same-owner `signal=operator_response` for `(ask.request_id ?? ask.event_id)`: **wait = response.ts - ask.opened**, the event C11-231 appends. Milliseconds. No input text. Mere typing, seen, `c11 send`, and focus/selection clicks are not responses. Terminal Return, text-box Send and fixture-proven picker option-commit keys are the supported C11-231 UI-submit observations; text-box Send can originate from the Send button. No such event in the window: `status=unavailable` and waits null. Separately report request-to-resume (`attention.resolved` resumed, or the next working turn for that request) and never label it operator response. Oracle: bypass ask, seen (no Q2 sample), one actual operator submit, then resumed. Use **J6-bypass-AskUserQuestion-operator-submit**: no sample for view/draft input; one sample at Return/option commitment; repeat submit adds none. The same native request id in a new ask is correlated to its applied open event, not an older resolved ask. Resume is the other number. |
| Q3 blocked minutes | Confirmed blocked ms grouped by `approval`, `question`, `plan_review`. Unconfirmed historical blocked is its own number. Suppression does not change either number. Oracle: the old open ask that retention keeps. |
| Q4 turns per hour | Applied root `turn.started` boundaries, not tool hooks and not children. The same native turn id from hook and transcript is one turn. A second start while already working, with no new id, is duplicate evidence. If two turns cannot be separated, report the lower bound and `ambiguous`. Also report completed and interrupted counts. Oracle: late hook plus the hook/transcript duplicate. |
| Q5 errors and interrupts | Unique applied root `error.reported` boundaries and applied root `turn.interrupted` boundaries. Child and tool diagnostics are a separate count. Esc-only advisory input is not an interrupt. A C11-189 child completion is not a parent error. |
| Q6 stalls | Working intervals longer than `--stall-ms` (default 15 minutes) with last evidence age, source, coverage, and censored. This lists outliers. It does not interrupt, flag, or focus. Oracle: long working plus disconnected, censored at the last writer observation. |

Default JSON has the overall object plus `by_agent`, `by_model`, and `by_workspace`, each entry using the same metric object. Build the complete bounded owner timeline before filtering. Include the retained predecessor/baseline at `from` and the boundary needed to end an interval. First close/split intervals using every relevant transition/control observation; then clip and apply agent/model/workspace filters to the attributed intervals/counts. Filtering event rows first would drop a phase-ending event after a model/workspace change and inflate old attribution. Group keys are the event-time values, never current metadata.

```json
{
  "schema_version": 1,
  "units": {"duration": "ms", "blocked_minutes": "ms/60000", "rate": "per covered hour", "window": "[from,to)"},
  "window": {"from_ms": 0, "to_ms": 0},
  "coverage": {
    "retained_from_ms": null, "first_available_sequence": null, "high_water_sequence": null,
    "incomplete": false, "uncertain_count": 0, "censored_count": 0,
    "sources": {}
  },
  "time_in_state_ms": {"working": 0, "blocked": 0, "idle": 0, "error": 0, "unknown": 0, "disconnected": 0, "unconfirmed": 0, "degraded": 0},
  "operator_response": {"status": "unavailable", "wait_ms": null, "wait_count": 0, "resume_ms": null, "resume_count": 0},
  "blocked_ms": {"approval": 0, "question": 0, "plan_review": 0, "unconfirmed": 0},
  "turns": {"started": 0, "completed": 0, "interrupted": 0, "ambiguous": 0, "covered_hours": 0, "per_hour": null},
  "errors": {"root": 0, "interrupts": 0, "child_or_tool_diagnostic": 0},
  "stalls": [{"duration_ms": 0, "threshold_ms": 900000, "last_evidence_age_ms": 0, "source": "", "censored": false, "ongoing": false}]
}
```

When the window contains correlated UI-submit observations, `operator_response.status` is `available`. `wait_ms` sums request-to-submit durations for responses in `[from,to)`, including a retained request start before `from`; latency is not the clipped blocked-overlap metric. A missing/pruned start or intervening unknown crash/clock gap makes that sample censored/unavailable, rather than fabricating a full response time. Report its count separately. Blocked minutes still use clipped overlap. The object above is the no-observation shape. The human report prints the same fields in that order, with the units on the first line. No narrative paragraph. A dashboard reads the JSON. `tests_v2/journal_analytics_reader.py` is the sample consumer: it parses JSON only and prints the six numbers. It does not scrape the human report.

## NDJSON export

First line is the manifest `{record_type, export_version:1, fold_version:1, from, to, first_available_sequence, high_water_sequence, coverage, filters}`. Freeze `high_water_sequence` at start. Then event rows at or below the frozen high-water in sequence order, then optional `current_state` rows sorted by `(tab_id, agent_kind, session_id)` and labeled `record_type=current_state`, with their `last_applied_sequence`. A baseline advanced beyond the frozen high-water cannot describe that cutoff: omit that row and emit explicit `baseline_unavailable_at_cutoff` coverage, rather than mixing later state into the earlier events. These pages are inspection/analytics, not a transactionally frozen backup. Unchanged-file exports remain byte-identical. If retention removes a sequence the cursor still expects, emit one `gap` record and continue. Release each 500-row read. Do not pin WAL.

Each event row carries `sequence, event_id, kind, fold_effect, source, adapter, tab_id, workspace_id, agent_kind, model_id, session_id, turn_id, request_id, tool_class, reason_code, signal, resolution, from_phase, to_phase, from_since_ms, occurred_at_ms, time_quality, committed_at_ms, observed_tick_ns, app_instance_id`. The encoder's allowlist is those fields plus the manifest and gap fields. `fold_effect` is how a consumer tells a recorded stale PreToolUse from an applied transition. No prompt, tool body, cwd, account, or free-form detail. No `generated_at`, so two exports of an unchanged file match byte for byte.

`journal.clear` resets coverage. Later queries say the retained window starts at the clear. They do not pretend the deleted interval is complete.

## Files

- `Sources/Journal/JournalQuery.swift` — pure function from decoded rows and current baselines to the JSON object. Injected clock only in tests.
- `Sources/Journal/JournalExport.swift` — NDJSON encoder with the allowlist.
- `CLI/JournalQueryCommand.swift` — read-only store open, query, export, and the app-down half of clear. Share C11-273's layout and draft types; add those sources to the CLI target if the merge did not.
- `Sources/SocketHandlers/JournalHandlers.swift`, `Sources/TerminalController.swift`, `Sources/SocketHandlers/SocketDispatch.swift` worker switch, and `SystemHandlers.swift` capabilities — `journal.clear` only, serialized after C11-257's file barrier and the C11-273 integration.
- `CLI/c11.swift` — verb branch before the focus preamble.
- `skills/c11/references/api.md` — the three verbs and the JSON keys. Sync with `scripts/sync-installed-skills.sh c11` in build mode. C11-278 still owns doctrine.
- Tests: `c11Tests/JournalQueryTests.swift`, `JournalExportTests.swift` registered in `c11LogicTests`; `tests_v2/test_journal_analytics.py` and `journal_analytics_reader.py`.

Hand-computed expected totals live next to the fixture, in the test, not as prose. Synthetic ids only. C11-271's normalized corpus replaces the matching synthetic cases when it arrives; do not relabel synthetic rows as captures.

pbxproj membership for the new files. No submodule edits. No `dlog`.

## Acceptance

| AC | Incident / question | Proof |
|---|---|---|
| 1 | Atin's question: where the time went. Q1–Q6. | `JournalQueryTests` on one multi-agent, multi-model, multi-workspace SQLite fixture. JSON and the human report both match the hand-computed totals, units, and denominators. |
| 2 | A wait that starts before the window, and a wait that is still open. | Clipped overlap equals the fixture's partial ms. The open wait is `ongoing` and is not a completed response sample. Filters for agent, model, workspace, and window each change the totals to the precomputed slice. Add one ongoing phase with a model/workspace change, a same-phase disconnect, and a response whose request start precedes `from`; independently compute each segment and full response latency. A wall-clock rollback with advancing monotonic ticks yields no negative or fabricated duration. |
| 3 | F3 seen-but-not-answered; one real submitted response; late hook; hook-plus-transcript duplicate; coverage gaps. | Seen adds no operator-response sample and does not shrink blocked ms. One stored `operator_response` for that applied open ask yields one `wait_ms` sample equal to response.ts - ask.opened and does not clear the blocked interval. A `c11 send` keystroke adds no sample. Seq 11 does not add a turn or working time. Duplicate delivery counts one turn and increments `ambiguous` when ids are absent. Disconnected, gap, and unconfirmed ranges show `incomplete` or `censored` and are outside the confirmed totals. |
| 4 | Export must be greppable and safe for a dashboard. | Two exports of one unchanged file are byte-identical, sequence-ordered, and parse as NDJSON. During a concurrent append, event rows remain at/below captured high-water and a newer current baseline is omitted with explicit coverage loss. A sentinel body key is absent. The reader script consumes the query JSON and does not read the human report. |
| 5 | F2 volume must not stall append or typing. Retention has a window. | Paged export while `agent.event.append` still returns its receipt, using the spec's existing 100 ms busy timeout and 250 ms hook budget as the already-registered limits. Typing comparison consumes C11-270 milestone M1's published baseline/budgets; it does not wait for M2 or completion of that ticket. If the baseline, the budget, or the sample is missing, record `ac5: unverified` and name the missing piece. Do not invent a millisecond target. A retention-clipped result sets `coverage.incomplete` and reports `retained_from_ms`. |

Hot path: the CLI process does the scan, not the app main thread and not the writer queue. No work in `hitTest`, `forceRefresh`, or the sidebar body. Clear is rare and runs on the writer queue inside one transaction. Each page drains an autoreleasepool.

Localization: no new UI strings. Human CLI text is English, like `c11 config stats`. Machine codes stay unlocalized.

## Cut line

No hosted dashboard, no billing or token prices, no change to C11-178 launch stats, no stall intervention, no automatic flags, no focus history, no operator-response producer (C11-231 appends the observation; this ticket only reads it), no NDJSON import, no upload, no Feed, no producer widening, no tenant-config writes, no C11-257 send/mailbox files. Fold defects go back to C11-273.

## Dependencies and handoff

C11-273 merged is the start gate. C11-216 is the Atlas route. C11-270 milestone M1 supplies the published baseline/budgets. Its M2 final candidate is a later release gate. C11-231 is not a start gate. Field names come from C11-272. Fixture events prove the Q2 formula. The live tagged Q2 sample is unverified until C11-231's observation is on that build. C11-278 documents doctrine around the verb section this ticket adds.

Open human decisions: none. Review cap: three cycles, then Atin. Do not merge, do not mark done.

## Codex takeover verification

Verified base `0ff8887e5e965400b01645ef40b85fd0b2605cf2` and unchanged attested C11-272/273 hashes. Corrected first-key versus submitted-response semantics, monotonic elapsed-time contract, filter-before-interval loss, same-phase attribution/coverage boundaries, offline namespace selection and socket capabilities that had no handler. Bounded export declares baselines unavailable when newer than its frozen event cutoff; it does not claim a frozen backup. Audit findings 2/4 remain integrated proof gates: live Q2 needs C11-231 plus C11-274's answer/resume trace; performance uses M1. No new human decision; no builds/tests/product edits.

Orchestrator submit repair: Q2 uses J6-bypass-AskUserQuestion-operator-submit, same-owner request/event-id correlation and response.ts minus ask.opened, once per ask. Pre-submit typing, viewing and c11 send produce no sample; resumed is separate. No runtime proof performed.

Shared fixture oracle: ask.opened=1,000 ms, seen=2,000, draft=3,000, submitted response.ts=5,500, repeat submit=6,000, resumed=7,000 gives wait_ms=4,500 and wait_count=1, with separate resume_ms=6,000. The interval remains blocked until resolution/continuation; no sample from seen, draft, repeated submit or synthetic keys. Capture-backed proof is pending.

## Reset 2026-10-02 by agent:luna-277

## Reset 2026-10-02 by agent:luna-277
