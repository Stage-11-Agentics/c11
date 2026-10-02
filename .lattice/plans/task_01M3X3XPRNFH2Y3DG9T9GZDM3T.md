# C11-274: Widen Claude lifecycle observations

Planning only. Implement after BUILD MODE and after C11-273 has merged. Base for citations: `0ff8887e5e`. Preserve the inherited branch and any local commits; refresh the implementation base only as directed by the Orchestrator, without resetting, rebasing, or force-pushing inherited work. Line numbers below are the pre-journal file.

## Verified citations

- `Resources/bin/claude:207` is one `HOOKS_JSON` with exactly six events: SessionStart, Stop, SessionEnd, Notification, UserPromptSubmit, PreToolUse (`async: true`). The per-PID settings file is `:226` (`${TMPDIR}/c11-claude-hooks-$$.json`). Outside c11, hooks disabled, or a dead socket, `:101` execs the real binary with the original argv. Agent View subcommands pass through at `:133`.
- `CLI/c11.swift:17006` caches AskUserQuestion text and returns at `:17038` before any blocked event. The comment at `:17037` waits for Notification. Ordinary PreToolUse at `:17042` still calls workspace-wide `clear_notifications` and `:17048` reports working. That clear stays C11-263. `runClaudeHook` is `:16641`. Eager socket connect is `:1922`; a connectivity failure on `claude-hook` returns at `:1936` with no spool today. C11-273 moves event_id creation before that return.
- Upstream `CLI/CMUXCLI+ClaudeHookSettings.swift` at `920ff39ff7`: StopFailure is line 20, and it is aliased to the `stop` subcommand. The blocking bridge is the PermissionRequest group near lines 70–75 (`hooks feed --source claude`, timeout 125), not line 85. That file has no PreCompact, no SubagentStart, and PostToolUse only for PushNotification. Do not import feed, inbox-wait, inbox-drain, auto-name, CronCreate, or PushNotification.

C11-306 owns `readTranscriptSummary` (`CLI/c11.swift` near `:17366`), the full-file Stop read. This ticket does not edit that function and does not add a transcript read on any new hook.

## Takeover verification (agent:codex-producers)

Audit finding 2 is retained: this ticket owns correlated ask resolution; C11-231 owns actual human response observation. The current C11-271 manifest is a production-c11 corpus, not a tagged run. Its bypass AskUserQuestion has a native tool_use_id on PreToolUse, but its PermissionRequest does not. The normal Bash capture has tool_use_id on Pre/PostToolUse; no answer-to-PostToolUse capture is present. ExitPlanMode, restart, and Codex child notify are declared gaps. Preserve observed, derived-reorder, synthetic, and missing labels when importing this shared corpus. PermissionRequest without an id cannot be correlated by assuming one; normal approval answer/continuation needs an Atlas fixture with a native id or fixture-proven same-session resumed evidence supported by the landed fold. If neither exists, report that exact resolution gap to the Orchestrator instead of allowing ordinary tool_activity or generic Stop to clear it.

## Contract used, not extended

Kinds, ranks, and fields are C11-272. Source is `hook` (rank 60), chosen by the adapter, never by the caller. Adapter slug `claude`. `native_event` is `other` when the name is not in the landed allowlist. No new kind, no second fold, no prompt, tool body, plan text, cwd, or path in the draft. Occurrence time stays null unless the stdin carries a fixture-verified native timestamp. Hook start time is not causal.

C11-273 already maps the six current hooks: prompt-submit → `agent.turn.started`; stop → `agent.turn.completed`; PreToolUse AskUserQuestion → `agent.question.requested`; ExitPlanMode → `agent.plan_review.requested`; other PreToolUse → `agent.state.changed` / `tool_activity`; Notification → observation unless it is an already-supported structural type. This PR does not re-decide those. It adds subscriptions and fails if the inherited AskUserQuestion / ExitPlanMode mapping starts waiting on PermissionRequest or Notification again.

## Mapping

New wrapper commands, all `c11 claude-hook <subcommand>`, same tempfile merge as today. Claude keeps merging operator settings. The wrapper never writes `~/.claude`.

| Stdin event | Subcommand | Settings | Draft |
|---|---|---|---|
| StopFailure | `stop-failure` | timeout 10, sync | `agent.error.reported`. Not the `stop` alias. `reason_code` null. `is_child` false. Session id from stdin. |
| PermissionRequest, tool_name not AskUserQuestion or ExitPlanMode | `permission-request` | timeout 1, not async | `agent.approval.requested`, `tool_class` `other`, `request_id` = `tool_use_id` when it is ≤128 ASCII bytes, else null. Stdout is `{}` and exit 0. No `decision`, `behavior`, `allow`, or `deny`. |
| PermissionRequest for AskUserQuestion or ExitPlanMode | `permission-request` | same | No append. Those reasons stay on PreToolUse. Stdout `{}`, exit 0. |
| PostToolUse for AskUserQuestion or ExitPlanMode | `post-tool-use` | timeout 5, `async: true` | `agent.attention.resolved`, `resolution` `resumed`, `request_id` = that same `tool_use_id` when it is ≤128 ASCII bytes. Not `tool_activity`. Drop `tool_response` and any answer text. No `signal=operator_response`. |
| PostToolUse for any other tool | `post-tool-use` | timeout 5, `async: true` | `agent.state.changed` / `tool_activity`, same tool class and `tool_use_id` rules as PreToolUse. Drop `tool_response`. This does not clear blocked. |
| SubagentStart | `subagent-start` | timeout 5, `async: true` | `agent.child.spawned`, `is_child` true, `session_id` = `agent_id`, `parent_session_id` = parent `session_id`. Missing `agent_id` is unattributed, not the parent session. |
| SubagentStop | `subagent-stop` | timeout 5, `async: true` | `agent.child.completed` with the same identity. Do not infer failure from assistant text. `agent.child.failed` only if the landed draft has a structural non-text failure flag and the payload sets it. |
| PreCompact | `pre-compact` | timeout 5, `async: true` | `agent.state.changed` / `observation`. Drop `custom_instructions`. Phase does not change. |

`tool_name` maps only to the existing tool class enum: AskUserQuestion → `ask_user_question`, ExitPlanMode → `exit_plan_mode`, anything else → `other`. `tool_input` is not copied.

Ask resolution is this ticket. Operator response is not. C11-272 already maps `attention.resolved` with `resolution` `resumed|cancelled|unknown` and a matching request id: resumed becomes working, a late resolution of request A does not clear request B, and generic Stop does not clear blocked. Continuation emits `resumed` only.

- PostToolUse of the same AskUserQuestion or ExitPlanMode tool use is that resolution. The request id is the `tool_use_id` on that hook. A missing or over-long id emits nothing; the fold keeps blocked and shows uncertainty. Do not mint an id.
- UserPromptSubmit retains C11-273's existing `turn.started` mapping, a genuine new-turn boundary under C11-272 §4. Do not read a current blocked row and copy its request id into a fabricated resolution: that hook does not identify which prior request it answered. PostToolUse supplies the request-correlated `attention.resolved` path. Verify the actual answer/resume trace on Atlas; absent its native request correlation, keep that resolution capability uncertain rather than minting an id or claiming operator response.
- Create a fresh event_id and emitted_at_ms for each distinct native observation before connect; retry/spool preserves that entire draft. PostToolUse and UserPromptSubmit are different drafts and must never share an event_id: C11-272 §6 returns idempotency_conflict for same-ID/different-content. Semantic duplication belongs to the existing fold. Test a repeated matching resolution after completion: it must not reopen the terminal barrier; if the landed fold lacks that rule, send BLOCKED instead of changing it here.
- `cancelled` is not inferred. Stop while the ask is still unresolved stays blocked. `state.changed` / `operator_response` is C11-231's observation. Seen, a socket keystroke, and this resume are not that signal, and this ticket does not claim Q2.

Owner tab is the session store's surface for that `session_id`, which C11-273 already resolves. Never the focused tab. Child rows do not use the parent owner key.

Delivery uses C11-273's path: one event_id before connect, `agent.event.append`, 250 ms budget, then the existing spool, then exit. Timeout, busy, or unreachable socket must not fall through to `report_agent_activity`. PermissionRequest must not wait for a human or for a socket.

StopFailure must not call `summarizeClaudeHookStop` or `readTranscriptSummary`.

## Files

- `Resources/bin/claude`: extend `HOOKS_JSON` only. Leave the pass-through gate, Agent View case, session-id injection, and tempfile fallback in place.
- `Sources/Journal/ClaudeHookMapping.swift` (new): pure `map(subcommand:object:) -> Draft?`. App and CLI target membership. `runClaudeHook` calls it for the new subcommands, the PreToolUse tool-class choice, the PostToolUse ask-versus-ordinary choice. UserPromptSubmit keeps the inherited new-turn mapping; the pure mapper performs no owner-state query. Do not move `conversation.push`, notification text, or the Stop transcript summary into it.
- `CLI/c11.swift`: new switch cases; help lines at `:17075` and `:10158`. PermissionRequest prints `{}` only. No new `clear_notifications`.
- `tests/test_claude_wrapper_hooks.py`: the executable fake must be named `c11`, matching `find_c11_bin`, rather than only `cmux`. Have the fake Claude load/record the settings file while the temp directory still exists; `run_wrapper` destroys that directory before returning argv, so loading the returned path later is too late. Cover the inline fallback separately. These are executable wrapper checks, not source searches.
- `c11LogicTests/ClaudeHookMappingTests.swift` (new): call the mapper, then `JournalReducer.fold` from C11-273. Synthetic stdin, labeled synthetic until C11-271's F3 corpus is imported. Share that corpus when it arrives; do not keep a second copy.

No `project.pbxproj` hand edit beyond adding the two Swift files. Expect gem reformat. No submodule, no skill edit (C11-278), no C11-257 files, no `~/.claude` write.

## Acceptance

Each row is one named incident. Tests call the mapper and fold, the wrapper subprocess, or a tagged socket. No source-grep tests.

| AC | Incident | Oracle | Atlas proof |
|---|---|---|---|
| 1 | Bypass AskUserQuestion / ExitPlanMode never reach waiting (report 03, #6606). F3 normal vs bypass. The same ask stays blocked through Stop until the agent continues past it. | Mapper+fold: PreToolUse AskUserQuestion → blocked `question.requested` with no Notification event in the trace. ExitPlanMode → `plan_review.requested`. Stop after a working turn → idle `completed`. Stop while that ask is still unresolved stays blocked. PostToolUse of the same `tool_use_id` → `attention.resolved` `resumed` and working, then Stop → idle completed. A different request id, an ordinary tool's PostToolUse, and a missing id leave the ask blocked. No draft carries `operator_response`. A genuine UserPromptSubmit maps to the inherited `turn.started`; it does not copy a prior request id into a new resolution. Distinct hooks have different event_ids; a lost-reply retry reuses byte-identical draft content. Repeated matching resolution after completion must not restart working. | Tagged Claude, normal and `--dangerously-skip-permissions`: the ask stays blocked with no PermissionRequest and no Notification. One bypass question answered in the TUI so the agent continues: the journal row is `attention.resolved` `resumed` with that request id, then Stop leaves the mark not blocked. No `operator_response` row. Record `claude --version`. Verified display, timer, dismissal. |
| 2 | StopFailure is an error, not a finished turn (#15232). Child work must not finish the root (#15666). PreCompact must not look like completion. | StopFailure fold → `error`. Parent state unchanged after child spawned and child completed. PreCompact → effect `observation`, same phase. | Tagged run: one provoked StopFailure if the recorded Claude version can fire it; otherwise the fixture result stands and the gap is named. One real subagent start/stop. Parent mark unchanged. PreCompact observation read back from the journal row. |
| 3 | Late async PreToolUse after Stop (C11-272 seq 10/11). Sibling tool start clearing another tab (C11-272 AC5). | PostToolUse and PreToolUse `tool_activity` after Stop, with native time, missing time, and hook-start-only time, stay idle/completed. Drafts for tab A and tab B: B's tool_activity leaves A's blocked row unchanged. | Tagged delayed hook on a finished turn stays completed until the next UserPromptSubmit. Two live tabs: B's tool does not clear A's ask. |
| 4 | PermissionRequest must not become cmux's decision bridge (report 03). Socket-down hook must not hold the agent (`CLI/c11.swift:1932`). | Wrapper JSON: PermissionRequest timeout ≤ 1, no `async`, command is `c11 claude-hook permission-request`. A fake Claude reads the hook stdout and sees no decision keys. Unreachable socket: process exit 0 inside the 250 ms budget, spool file has the structural draft only. | Tagged normal-mode Bash approval: native Claude permission UI still appears, journal row is `approval.requested`, c11 does not answer it. |
| 5 | Operator settings merge and outside-c11 pass-through (`Resources/bin/claude:94`). No bodies in the journal (C11-272 privacy). | Extend `tests/test_claude_wrapper_hooks.py`: live socket settings contain the old six plus the six new events; missing and stale sockets pass argv through; a temp `HOME` gains no `~/.claude/settings.json`. Mapper given sentinel question text, `tool_input`, `tool_response`, `last_assistant_message`, and `custom_instructions` produces canonical bytes without those sentinels. | Same wrapper script on Atlas against the built wrapper. Tagged spool/journal query shows no sentinel. |

## Hot path, strings, persistence

Hook processes are outside `hitTest`, `forceRefresh`, and the sidebar body. Append stays on C11-273's socket worker and writer queue. No `DispatchQueue.main.sync`, no `runModal`, no new thread. New hooks do not read the transcript, so they do not add the C11-306 cost. No new `String(localized:)` keys. No schema or snapshot change. Retention and spool budgets stay C11-273's.

## Cut line

Out: blocking PermissionRequest output, upstream feed/inbox/auto-name/cron/push hooks, answers, tool bodies, workspace-wide notification clears (C11-263), the Stop transcript reader (C11-306), Codex and Grok (C11-275, C11-276), skill and doctrine text (C11-278), mailbox/send (C11-257), a new journal kind, any rank other than hook, and `operator_response` (C11-231).

## Dependencies

C11-273 must be merged first. The pure fold for `tool_activity`, `observation`, `error.reported`, `child.*`, and `attention.resolved` is that ticket's. If the merged fold treats `signal=observation` as a phase change, has no `approval.requested` apply rule, or has no `attention.resolved` apply rule, stop and send BLOCKED with that gap. Do not add a local reducer.

C11-271's F3 corpus replaces synthetic stdin when the fixtures worktree publishes it. C11-306 may land in `CLI/c11.swift` first; preserve inherited commits and refresh the base as directed by the Orchestrator, without editing `readTranscriptSummary`. C11-263 owns scoping `clear_notifications`.

## Decisions

None for Atin. Owner defaults, already applied above: StopFailure is its own subcommand; PermissionRequest does not append a second ask for AskUserQuestion or ExitPlanMode; PreCompact is `state.changed` / `observation`; SubagentStop is `child.completed` unless a structural failure flag exists; PermissionRequest stays synchronous with timeout 1 and stdout `{}`. PostToolUse continuation of a blocked AskUserQuestion or ExitPlanMode is `attention.resolved` `resumed` with that native request id. UserPromptSubmit remains a new-turn boundary and does not fabricate a resolution. Neither is `operator_response`.

If the Atlas permission probe shows that `{}` suppresses Claude's own dialog, switch that process to empty stdout. That is a recorded probe result, not a new kind.

Review cap: three cycles, then DECISION to the Orchestrator.

## Reset 2026-10-02 by agent:luna-274

## Reset 2026-10-02 by agent:luna-274

## Reset 2026-10-02 by agent:luna-274
