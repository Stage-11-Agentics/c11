# C11-275: Codex stays on notify

Planning only. Implement after BUILD MODE and after C11-273 has merged. The trust probe below already ran in planning, under a throwaway `CODEX_HOME`, model `gpt-5.6-luna`, and a sandbox that denied writes to `~/.codex`. It did not load the operator's `hooks.json` or `config.toml`.

## Probe result (codex-cli 0.159.3; previous-owner reported)

Isolation fails. Ship the notify fallback. Do not ship `--enable hooks`, `-c hooks.*`, `--dangerously-bypass-hook-trust`, or a computed `trusted_hash`.

Throwaway home, synthetic SessionStart commands only (each `touch`es its own marker):

| Invocation | Tenant hook | Project `.codex/hooks.json` | Session `-c` hook |
|---|---|---|---|
| `--enable hooks --dangerously-bypass-hook-trust` plus a session `-c` hook | ran | ran | ran |
| `--enable hooks` plus the same `-c` hook, no bypass | did not run | did not run | did not run |

Codex printed: enabled hooks may run without review for this invocation. The flag drops the trust check for every enabled hook in the process. It does not limit trust to the session layer. That is the previous owner's reported counterexample. This takeover verified upstream layering/bypass code at 920ff39ff7, but has not rerun the probe or received its raw marker artifact; it does not claim independent runtime proof. Retain notify unless the isolated versioned Atlas probe supplies contrary proof and this plan is revised.

Re-run this probe before any later change that would inject Codex hooks. A newer Codex that still runs the tenant marker under the flag is still a failed proof.

## Verified citations

- `Resources/bin/codex:47` is the `__c11-notify` child. It base64s the payload and calls `c11 notify` with a 0.75 s timeout. Empty payload becomes `{}` so a missing `thread-id` stays visible to the guard. `:222`–`:233` prepends `-c notify=[wrapper,"__c11-notify"]` and then execs the operator argv, so a later operator `-c notify=...` wins. `:160`–`:209` is the launch-boundary file plus `conversation claim`, including `--expected-resume-id` for exactly one resume UUID. `:110` passes through when the socket is down. Do not add work before `exec`.
- `NotificationHandlers.swift:15` `shouldDeliverLegacyCodexNotification`: no payload key returns true; a captured alive runtime root with a missing or different `thread-id` returns false; no captured root keeps today's legacy fallback. C11-273 journals a root completion only after that same decision. This ticket does not edit the guard.
- Upstream `emitCodexWrapperInjectArgs` documents the same layering (user `hooks.json`, `config.toml`, project `.codex/hooks.json`, then session `-c`) and still puts `--dangerously-bypass-hook-trust` on the argv. The probe confirms that comment on 0.159.3. The ticket's line numbers 181 and 220 are that function, not a separate mechanism. Do not import the argv, the `~/.cmux/hooks` scripts, or the message companion handlers.

## What ships

The wrapper keeps today's notify prepend, claim, boundary marker, idle seed, and pass-through. No new Codex arguments.

Use C11-273's existing app-enriched adapter capability set to declare the actual Codex mode: notify completion is available, hook SessionStart/permission observations are unavailable, and hook coverage is degraded. Bind this profile when an exact eligible Codex owner is established through the existing ConversationStore capture/claim integration. No wrapper session.started is fabricated. A wrapper placeholder is not exact ownership.

The previous plan's sessionless background adapter_gap cannot meet that requirement: C11-272 §2 records missing identity as unattributed and excludes it from live projection. Remove that append from the wrapper. If C11-273 needs a control observation when its exact-owner capability profile is registered, use agent.state.changed / adapter_gap, source c11 rank 0, with that exact owner, in its existing off-main coordinator. It changes health/capability only, never phase, blocked, or turn counts. No new event kind, capability payload field, or reducer. If the merged coordinator cannot register/read back this contract-defined capability profile, send BLOCKED with the missing seam; a ticket comment is not a substitute for runtime degraded readback.

There is no 5 s launch wait. The canary deadline in the contract is 5 s, and it applies only to an adapter that actually subscribed to `session.started`. This adapter does not subscribe. Degraded is true at launch because the probe failed, which is the AC3 outcome without blocking startup. Notify remains the completion path.

Notify mapping stays C11-273's: after the existing root decision, an exact root match appends `agent.turn.completed`. A known-root mismatch appends nothing and does not notify. A missing root keeps the legacy notification and an unattributed journal row. A second completion for the same owner while already idle is `duplicate_evidence` and does not count another turn. No hook completion exists, so there is nothing to double-count against notify.

## Files

- `Resources/bin/codex`: preserve notify argv, ownership boundary, and pass-through; no new hook flags or sessionless capability append.
- Landed `Sources/Journal/JournalCoordinator.swift` / adapter capability definition in `JournalEvent.swift`: register the notify-only degraded profile through the existing exact-owner integration, using the app-enriched capability set. Inspect the landed seam first; no second capability store or phase writer.
- `tests/test_codex_wrapper_hooks.py`: live argv is still exactly one leading `-c notify=...` and contains neither `--enable`, `hooks.`, nor `--dangerously-bypass-hook-trust`. Operator argv still follows that `-c`. Callback still notifies once and does not exec Codex. Add a temp `HOME` assertion that the wrapper creates no `hooks.json` and no `config.toml`.
- `scripts/probe-codex-hook-trust.sh` (new, not part of unit CI): reproduce the reported probe with an installed version, a bounded timeout, cleanup trap, and public structural marker results only. An authentication/network failure or missing session marker is inconclusive, never an isolation success or counterexample. The probe below runs after BUILD MODE on Atlas; no new Codex run in this takeover. It refuses to run if `CODEX_HOME` is unset or is `~/.codex`, uses a fresh temp home, writes only synthetic hook commands, copies `auth.json` for the API call, deletes that copy before exit, and runs under a write deny for the real `~/.codex`. Model is `gpt-5.6-luna`. Exit 0 only when the bypass run shows the tenant or project marker, which means isolation failed and the wrapper must stay on notify. Exit 2 when isolation holds (tenant and project markers absent, session marker present); that result is not an implementation license until this plan is revised.
- Journal tests, after C11-273: one root notify with a matching synthetic `thread-id` becomes one `turn.completed`; the GAF-13 child id does not; a repeat is `duplicate_evidence`. Use the reducer and the real guard decision, not a string search.

No new Swift file or pbxproj change is expected for the existing adapter registration seam. No skill edit (C11-278). No transcript parser (C11-276). No `~/.codex` write. No permission-mode flag.

## Acceptance

| AC | Incident | Oracle | Atlas proof |
|---|---|---|---|
| 1 | Bypass would also trust tenant and project hooks (report 03, upstream layering comment). | The probe table above, codex-cli 0.159.3. | Re-run `scripts/probe-codex-hook-trust.sh` on Atlas against the installed Codex. Record the version. Same marker result means the wrapper diff still has no hook flags. |
| 2 | Failed proof must not ship a bypass or a private hash (ticket scope). | `tests/test_codex_wrapper_hooks.py` argv assertion. | Same script against the built wrapper in the tagged app. |
| 3 | Missing `session.started` is degraded, notify still completes (report 01 canary). | An exact eligible runtime capture makes the notify-only degraded adapter capability readable; a placeholder or sessionless gap remains unattributed. A phase-neutral owner-correlated adapter_gap is allowed only through the existing capability seam. No sleep. Missing runtime readback is BLOCKED, not satisfied by a comment. A matching root notify still becomes one `turn.completed`. A later notify does not start a new turn. | Tagged Codex turn: mark returns idle from notify, journal source is C11-273's registered source enum for the notify adapter, not a new `notify` source, capability reads degraded, no `session.started` row. |
| 4 | GAF-13 child notify finished the root (C11-189). Resume must keep the exact id (`Resources/bin/codex:136`). | Existing guard plus one fold case: child `thread-id` does not change the root row. Wrapper test: one resume UUID sets `--expected-resume-id`; `--last` and two UUIDs do not. | Tagged child-callback smoke from C11-273's fixture. Wrapper script on the built binary. |
| 5 | No tenant write, operator notify and permission mode stay in control, socket failure must not hold launch (`:110`, `:222`). | Temp `HOME` gains nothing under `.codex`. An operator `-c notify=` later in argv is what Codex sees. Stale socket execs the real binary with the original argv and does not ping past 0.75 s. | Same wrapper tests on Atlas. Before/after stat of a fixture home, not the operator's live `~/.codex`. |

## Hot path, strings, persistence

The notify child and the claim stay bounded at 0.75 s. Nothing new runs on `hitTest`, `forceRefresh`, or the sidebar. The capability append is off the exec path and uses C11-273's worker. No `main.sync`, no `runModal`. No new localized strings. No schema change. No snapshot field.

## Cut line

Out: hook injection of any kind, trusted-hash calculation, redirecting `CODEX_HOME`, copying the operator's config into the probe, answers, approval UI, transcript edges (C11-276), doctrine text (C11-278), and mailbox/send.

## Dependencies

C11-273 for append, fold, app-enriched exact-owner capability registration/readback, and the notify-to-`turn.completed` route. If that route is missing at the authorized base refresh, send BLOCKED rather than journaling notify through `report_agent_activity` as a second writer. C11-276 may add transcript edges later; they stay rank 40 and do not clear this adapter's degraded hook capability. C11-271 fixtures replace synthetic thread ids when present.

## Decisions

None for Atin. The failed probe selects the fallback the ticket already requires.

Review cap: three cycles, then DECISION to the Orchestrator.

## Reset 2026-10-02 by agent:codex-producers
