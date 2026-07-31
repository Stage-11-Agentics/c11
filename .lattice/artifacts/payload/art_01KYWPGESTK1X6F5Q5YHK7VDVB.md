# Code Review: C11-189 — Guard legacy Codex notify by root thread

Reviewed branch `fix/c11-189-notify-guard` (commit `2cdc466c0`, PR #399) against origin/main. Note: the diff embedded in the review prompt was computed against a stale base and is dominated by unrelated `.lattice` artifact churn; the actual branch diff is 5 files, +296/−1 — `CLI/c11.swift`, `Resources/bin/codex`, `Sources/SocketHandlers/NotificationHandlers.swift`, `c11Tests/NotificationAndMenuBarTests.swift`, `tests/test_codex_wrapper_hooks.py`. That is what this review covers.

## 1. Verdict

**PASS** — with minor issues listed below, and two explicit merge gates that remain outside the diff: (a) the CI `build` job (which runs the new host-required Swift tests) was still **pending** at review time and must go green; (b) acceptance criterion 4 (tagged-build smoke of a real Codex child completion, operator-approval-gated) has no evidence in the diff or PR yet and must be completed before merge per the ticket's own closed list.

## 2. Summary

The implementation is a clean, minimal, correctly-scoped guard at exactly the seam the ticket specified: the wrapper forwards the previously-discarded notify payload (base64, command-scoped env var), the CLI attaches it as a v2 param, and a single private predicate in `NotificationHandlers.swift` gates all three `notification.create*` variants before `addNotification` (which is the sole call that forces idle, fires the waiting edge, and creates the notification). Fail-open/fail-closed behavior matches the spec precisely: no captured root, non-codex kind, quarantined/dead ref, or store-sync timeout → current behavior (AC3); live runtime-env-captured codex root plus missing/unparseable/mismatched `thread-id` → attention untouched (AC1); match → unchanged behavior (AC2). None of the forbidden C11-188 machinery appears, and the diff (296 lines including tests) is inside the ~300-line budget. I verified `ConversationStore` semantics directly (quarantine sets `state = .unknown`, so the `.alive` check correctly excludes quarantined refs) and ran the hermetic Python wrapper suite locally: **PASS**.

## 3. Issues

**[MINOR] Resources/bin/codex:63, tests/test_codex_wrapper_hooks.py:75 — Newly authored env var uses the `CMUX_` prefix**
The wrapper sets only `CMUX_CODEX_NOTIFY_PAYLOAD_B64`, and the Python test asserts that name. Project convention (code/CLAUDE.md naming rules) is explicit: never write `CMUX_*` in anything we author; the dual-read belongs on the consumer side only. The CLI already reads `C11_CODEX_NOTIFY_PAYLOAD_B64` as fallback, so the fix is one-sided.
**Fix:** Set `C11_CODEX_NOTIFY_PAYLOAD_B64` in the wrapper (flip CLI read precedence to C11-first for consistency) and update the Python assertion.

**[MINOR] Sources/SocketHandlers/NotificationHandlers.swift:44 — Exact, case-sensitive thread-id comparison**
`callbackThreadId == rootThreadId` is byte-exact. If the runtime-env-captured id and the notify payload's `thread-id` ever differ in UUID casing (or gain/lose a prefix across Codex versions), the guard fails closed and silently suppresses **all** root-completion notifications on every captured Codex surface — an AC2 regression with no visible error. Both values originate from the same Codex process so they are likely consistent today, but the only proof is the AC4 smoke run, which hasn't happened yet.
**Fix:** Normalize both sides (e.g., `lowercased()` before compare, appropriate for UUID-shaped ids), or treat AC4's tagged-build smoke as the blocking verification of format identity before merge — ideally both.

**[MINOR] c11Tests/NotificationAndMenuBarTests.swift — Missing test for the fail-closed missing/unparseable branch**
The wrapper deliberately forwards `e30=` (`{}`) when Codex omits the payload, and the spec explicitly requires "missing, or unparseable thread-ids leave attention state untouched" — but no Swift test exercises a captured-root surface receiving a payload with no `thread-id` or garbage base64. The three tests cover mismatch, match, and no-capture only. This is the branch most likely to regress silently (e.g., someone later "fixes" the parse-failure guard to return `true`).
**Fix:** Add two small cases mirroring `testLegacyCodexNotifyMismatchDoesNotMutateAttention`: payload `{}` and an invalid-base64 string, both asserting suppression while a root is captured.

**[MINOR] Sources/SocketHandlers/NotificationHandlers.swift:24 — Guard blocks the main thread on the ConversationStore bridge**
`shouldDeliverLegacyCodexNotification` runs inside `v2MainSync` and calls `conversationStoreSync`, which parks the calling thread on a semaphore with a 2 s timeout. The C11-24 `Task.detached` design means this cannot deadlock (verified against the bridge's implementation at TerminalController.swift:3703), and on timeout the guard fails open — but a busy/hung store now stalls the main thread up to 2 s per notify. Frequency is low (one call per Codex turn completion), so this is acceptable for an incident-scoped fix; flagging it because this is the first `conversationStoreSync` call site that runs on main rather than the off-main v2 dispatch thread its doc comment describes.
**Fix:** None required now. If this pattern spreads, resolve the captured root off-main before entering `v2MainSync`.

**[MINOR] c11Tests/NotificationAndMenuBarTests.swift:250,343 — Tests leave captured refs in `ConversationStore.shared`**
The `defer` blocks meticulously restore `TerminalNotificationStore` and `AppDelegate` state, but the `captureRuntimeEnv` writes into the shared conversation store are never cleaned up. Blast radius is bounded (fresh random surface UUIDs, quarantine audit won't collide), but the singleton-hygiene pattern applied to the notification store isn't mirrored.
**Fix:** Remove or tombstone the captured surface entries in the `defer`, using whatever testing/removal seam the store exposes.

**[INFO] Acceptance criterion 4 not yet evidenced**
The tagged-build smoke (real Codex child completion, surface stays `working`) is operator-approval-gated and has no artifact on the branch or PR. It is part of the ticket's closed acceptance list and doubles as the real-world verification for the case-sensitivity risk above. Also noting: the spec's optional "bounded debug log line" on suppression was not implemented — permitted ("is fine" ≠ required), but a single gated log line would make future field diagnosis of suppressed callbacks much cheaper.

## 4. Positive Observations

- **Exactly incident-scoped.** The guard lives at the existing ingest seam (wrapper → CLI param → the three `v2NotificationCreate*` handlers), with zero new subsystems. No reducers, epochs, markers, adapters, or coordinators — the C11-188 failure signature is fully absent, and the diff lands at 296 lines, inside budget.
- **Fail-open discipline is thorough and correct.** Every infra-degradation path (no payload param, store-sync timeout, no captured conversation, non-codex kind, non-runtimeEnv capture, placeholder, dead or quarantined ref — I verified quarantine forces `state = .unknown`) falls back to pre-guard behavior, which is what keeps Claude/Kimi/shell and uncaptured Codex surfaces untouched (AC3). Fail-closed applies only in the precise incident configuration.
- **The wrapper's `e30=` default is a thoughtful touch:** it preserves "this came from the legacy Codex notify path" even when Codex sends no payload, so the guard can honor the spec's missing-thread-id rule instead of losing provenance. The comment explains the constraint, not the mechanics.
- **Suppressed responses are wire-shape-identical to delivered ones** in all three handlers, so no socket client can distinguish (and thus grow a dependency on) suppression — and the wrapper's fire-and-forget call is unaffected.
- **Test quality is high where coverage exists:** the Swift tests drive the real `v2DispatchNotification` path end-to-end through `ConversationStore.captureRuntimeEnv`, `SurfaceLivenessDeriver`, `SurfaceMetadataStore`, and the waiting-edge seam — behavior, not implementation shape — with careful save/restore of every piece of shared singleton state they touch (modulo the conversation-store note above). The Python harness now asserts payload forwarding byte-for-byte and passes locally.
- The three-state `String??` handling of the sync bridge (timeout vs. no-capture vs. captured id) is easy to get wrong and is done correctly here.

## Merge gates restated

1. CI `build` job green (it runs `c11Tests` — the new Swift tests have not yet been proven in this run; they were pending at review time).
2. AC4 tagged-build smoke completed with operator approval, evidence attached to the ticket/PR.
3. Recommended before merge, cheap: the `C11_` env-var rename and the two missing fail-closed test cases.
