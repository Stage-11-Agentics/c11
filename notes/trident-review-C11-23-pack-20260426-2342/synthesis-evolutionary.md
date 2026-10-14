## Evolutionary Synthesis — C11-23 AI Usage Monitoring
- **Date:** 2026-04-26
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** e7987ee9
- **Source Reviews:** evolutionary-claude.md (Claude Sonnet 4.6), evolutionary-codex.md (Codex / GPT-5), evolutionary-gemini.md (Gemini 1.5 Pro)
- **Review Type:** Evolutionary Synthesis

---

## Executive Summary: Biggest Opportunities

Three models independently reached the same insight: this branch is not a usage dashboard. It is the first version of a **generalized external signal substrate** for c11 — a pluggable, credentialed, polling engine that can surface any external service state into the operator's peripheral vision. The progress bars are the demo. The pattern is the point.

The biggest opportunities, ranked by leverage:

1. **Generalize the credential and keychain layer into a shared `C11CredentialVault` / `C11Keychain`.** All three models flagged this as the single most immediately actionable, zero-risk, high-return move. The current implementation is already generic; it just lives inside the wrong package boundary.

2. **Expose usage snapshots as a socket-readable signal.** All three models converged on this as the strategic unlock: once agents can query provider health via socket, the system shifts from passive display to active scheduling input. This is the core flywheel step.

3. **Formalize the provider descriptor with endpoint/privacy declarations and credential normalizers.** Two of three models called this the highest-leverage near-term addition. It prevents registration drift, keeps privacy review mechanical, and directly improves onboarding UX today.

4. **Extract the generic poll-loop mechanics** so the next monitoring module doesn't re-solve scheduling, occlusion, coalescing, timeout racing, and stale-result rejection.

5. **Threshold alerting and sparkline history** as UI evolutions that compound value on the existing infrastructure with minimal new complexity.

---

## 1. Consensus Direction

All three models identified these evolutionary paths independently:

1. **"This is a substrate, not a feature."** The AIUsage module is the first instance of a general pattern: credential schema + background poll loop + normalized snapshot + sidebar render. Every model framed this as bigger than quota bars. Claude called it "agent observability substrate." Codex called it "local operator signal substrate." Gemini called it "Generalized Background Polling and Credential Management Engine."

2. **Generalize the credential/keychain layer first.** All three flagged `AIUsageKeychain` as having zero AIUsage-specific logic and being directly promotable to a shared `C11Keychain` / `C11CredentialVault`. This is confirmed by code inspection: the type operates only on `UUID`, `String`, and `Data`. Moving it costs nothing and enables every subsequent feature that needs credential storage.

3. **Socket exposure is the strategic unlock.** Claude proposed `c11 aiusage status` and `c11 aiusage wait --below 80`. Codex proposed socket-readable signal exposure with credential redaction. Gemini proposed injecting state as environment variables or socket metadata. All three reached the same conclusion: usage snapshots leaving c11's UI and becoming queryable by agents is the step that turns this from a display widget into an orchestration primitive.

4. **Provider self-registration / reduced registration drift.** Claude proposed `AIUsageRegistry.register(_:)`. Codex described the multi-file edit burden as "manageable for two providers and brittle at five." Both identified this as an architectural gate for the ecosystem to grow without friction.

5. **The flywheel is agents querying their own health.** All three models described a compounding loop where more providers make monitoring more valuable, monitoring data enables routing decisions, routing decisions reduce human intervention, and reduced human intervention makes adding providers worth the effort. The loop is not yet closed; socket exposure is the missing link.

---

## 2. Best Concrete Suggestions

Ordered by confidence and immediacy:

1. **Promote `AIUsageKeychain` to `C11Keychain` in `Sources/Security/`.** (Claude: High Value / Confirmed; Gemini: High Value / Confirmed.) Move `Sources/AIUsage/AIUsageKeychain.swift` to `Sources/Security/C11Keychain.swift`, rename the type, update call sites in `AIUsageAccountStore`. Zero behavioral change, zero risk, enables the next credential-needing feature. Test coverage already exists.

2. **Add `normalize: (@Sendable (String) -> String)?` to `AIUsageCredentialField`.** (Codex: High Value / Confirmed.) Apply trim-then-normalize in `AIUsageEditorSheet.save()` before building `AIUsageSecret`. Claude's `strippedSessionKey` (currently applied only at fetch time) moves to stored value. Codex can accept pasted `Bearer ...` blobs. Directly improves onboarding friction for both current providers.

3. **Fix redundant type-checks in `AIUsagePoller.localizedFetchErrorMessage(_:)`.** (Claude: High Value / Confirmed.) The specific guards for `AIUsageStoreError` and `AIUsageFetchTimeoutError` are subsumed by the `C11AppOwnedError` check below them. Both types already conform. Removing the specific cases is a behavior-identical cleanup that future error types benefit from automatically.

4. **Promote `runWithTimeout` to `Sources/Utilities/TaskTimeout.swift`.** (Claude: High Value / Confirmed.) A clean `withThrowingTaskGroup` wrapper that cancels the losing task. Already used within the poller; will be needed by any future polling subsystem. Pure extraction.

5. **Add provider endpoint/privacy declarations to `AIUsageProvider`.** (Codex: High Value / Confirmed.) Extend the descriptor with `networkEndpoints: [AIUsageEndpointDeclaration]` carrying host, path, purpose, cadence, and credential-bearing flag. Makes privacy review a runtime property of the registry rather than a parallel manual document. Enables a unit test over `AIUsageRegistry.all` that asserts internal consistency of declarations vs. the status poller allowlist -- without grep-style source tests.

6. **Introduce a typed `AIUsageAccountStatus` / `AIUsageSignalState` enum.** (Codex: Strategic / Confirmed.) Replace the current pattern of branching over `fetchErrors`, `snapshots`, and `isRefreshing` in multiple UI files with a single typed state: `.fresh`, `.stale`, `.degraded`, `.authExpired`, `.providerIncident`. Prevents divergent interpretations as new renderers land. Introduce as a derived computed map first to preserve existing `@Published` fields during migration.

7. **Add socket read commands for AI usage state.** (Claude: Strategic; Codex: Strategic; Gemini: Strategic.) New socket commands `aiusage.status` (JSON snapshot) and `aiusage.providers` (registered provider list). Follow the CLAUDE.md threading policy: off-main parsing, `DispatchQueue.main.async` only for UI reads. Expose only derived utilization/status, never raw credential fields. This is the single step that closes the flywheel loop.

8. **Self-registering providers via `AIUsageRegistry.register(_:)`.** (Claude: Strategic / Confirmed.) Replace the hardcoded `AIUsageRegistry.all` array with an append-only registry. Providers call `register` at file-level extension. Startup `ensureRegistered()` call in AppDelegate makes initialization order explicit. Removes the need to touch a central file when a third provider lands.

9. **Consent-gated local credential importer.** (Codex: Experimental; Gemini: implied.) A manual "Import from Codex auth.json" button that reads a user-selected file and writes only to c11's Keychain item. Does not auto-scan, does not watch files, does not write back. Eliminates the `jq` copy-paste step in the onboarding docs while respecting the "unopinionated about the terminal" principle.

---

## 3. Wildest Mutations

Ranked by ambition:

1. **Operator Budget Ledger.** (Codex.) Treat every account as a budget source, every agent/session as a budget consumer. Show not just current quota but projected burn rate per workspace. Requires agent telemetry wired to provider accounts, but the signal substrate starts here. The AIUsage module is the balance sheet; the ledger is a view on top.

2. **"Bring Your Own Key" Primitive / C11 Credential Vault.** (Gemini.) Scripts or plugins running inside c11 surfaces could request a named token from a central `C11CredentialVault` with user approval, eliminating scattered `export OPENAI_API_KEY` in dotfiles. The vault is the generalized evolution of `AIUsageAccountStore` + `AIUsageKeychain`. c11 becomes the secure credential broker for the entire shell environment.

3. **Quota-Aware Agent Launch / Dependency Weather.** (Codex + Gemini.) When c11 launches or orchestrates agents, it warns if the chosen provider is near threshold or in incident. Routes decisions: "Use Codex work account -- Claude personal is at 96%." Codex framed this as a "dependency weather strip" per workspace. No blocking; a routing suggestion in the launch flow.

4. **Provider Health as a Lattice Task Constraint.** (Claude.) Lattice task attribute: `requires_provider: claude, max_utilization: 80`. Agent scheduler checks AIUsage before starting a ticket and defers it if provider is above threshold. Usage monitoring becomes a scheduling primitive, not just a display widget. The pieces are close: Lattice knows tasks, c11 knows provider health, the socket layer connects them.

5. **Temporal Usage Fingerprinting / Sparkline History.** (Claude.) Store a rolling window of snapshots (60 entries, one hour at 60s tick). Overlay a faint line-chart path behind the fill bar using the existing `GeometryReader`. The operator sees whether usage is climbing, stable, or falling -- without any new UI chrome. This is the highest-signal-to-complexity mutation on this list.

6. **Status-Aware Environment Variables.** (Gemini.) Inject poller state as environment variables when spawning a pane: `C11_AI_CLAUDE_STATUS=degraded`, `C11_AI_CLAUDE_UTILIZATION=92`. CLI tools running inside c11 can dynamically adapt without reading the socket. No new UI; one hook in pane creation.

7. **Synthetic Usage Provider for Local Models.** (Claude.) Ollama / LM Studio have no usage API, but c11 could synthesize one: time inference requests, estimate utilization from queue depth or response latency. `credentialFields` would be `[]`, `fetchUsage` would call localhost. Makes c11 useful for self-hosted operators and expands the monitoring surface beyond managed APIs.

8. **From Monitoring to Active Brokering.** (Gemini.) Provision temporary tokens, rotate keys, set cost limits. c11 acts as a gateway for all terminal-based AI requests, abstracting provider choice from the operator and agents entirely. This is the farthest evolution on the roadmap -- the substrate being built now is the precondition.

---

## 4. Leverage Points and Flywheel Opportunities

### Leverage Points

1. **Generalize the keychain layer (HIGH, immediate).** Confirmed by all three models. One file move + rename. Every subsequent feature needing credential storage builds on this rather than reinventing it. The test patterns in `AIUsageTests.swift` (unique service per test, deterministic teardown) are also worth extracting as a test utilities file.

2. **Provider endpoint manifest on `AIUsageProvider` (HIGH, near-term).** Single source of truth for privacy review. Enables runtime consistency tests (registry vs. allowlist). Eliminates the parallel manual doc. Codex identified this as the highest-leverage near-term move.

3. **Typed signal state before more UI consumers land (STRATEGIC).** Introducing a typed `AIUsageSignalState` now costs less than migrating three or four renderers later. The current divergent branching across `AIUsageFooterView`, `AIUsageSettingsSection`, and `AIUsagePopover` is already a maintenance surface.

4. **Generic poll loop mechanics (STRATEGIC).** The scheduling shell in `AIUsagePoller` -- timer start/stop, occlusion observer, in-flight coalescing, generation discard, timeout racing -- is not quota-specific. Naming the pattern in comments costs nothing. Extracting it to a private helper within the poller is the low-risk version. Full extraction when the second signal module appears.

5. **`C11AppOwnedError` as a documented pattern (MEDIUM).** All three models noted the error taxonomy is the right foundation. The anti-pattern forming -- specific type-checks that are subsumed by the general protocol check -- should be removed now before a fourth error type lands and the confusion compounds.

6. **`AIUsageColorSettings` generalization (MEDIUM).** The hex-based color storage, threshold-segmented mapping, and smooth interpolation in `AIUsageColorSettings` is exactly what any future health indicator in c11 would need. Renaming to `C11ThresholdColorMap` or moving `Color.usageInterpolate` to `Color.thresholdInterpolate` signals codebase-wide availability.

### The Flywheel

All three models described the same compounding loop with slightly different framing. The canonical version:

1. **Provider descriptor added.** One file, no central edits (once self-registration lands).
2. **c11 fetches its state safely.** Privacy declarations are part of the descriptor; review is mechanical.
3. **Operator sees state without context switching.** Sidebar, sparkline, threshold badge -- peripheral vision, no alt-tab.
4. **State informs agent routing and work timing.** Socket API lets agents query their own health before spawning heavy tasks.
5. **More providers become worth adding.** The marginal cost of a new provider is low; the marginal value to the cockpit is high.
6. **Each new provider strengthens the whole loop.** Adding Gemini monitoring also adds Gemini to the scheduling and routing logic.

The loop is currently open at step 4. The socket read API is the link that closes it. Once closed, every step compounds.

**The reactive loop today:** agents do work → services rate-limit → operator notices red bars → operator intervenes. Human latency in the middle.

**The flywheel version:** agents do work → services approach limits → c11 emits socket event → agents self-throttle or reschedule → limits stabilize → agents resume at full speed. Human is out of the loop for routine management.

---

## Implementation Sequencing

**Do now (confirmed, low risk):**
- 1. Promote `AIUsageKeychain` to `C11Keychain` in `Sources/Security/`
- 3. Fix redundant type-checks in `localizedFetchErrorMessage(_:)`
- 4. Promote `runWithTimeout` to `Sources/Utilities/TaskTimeout.swift`
- 2. Add `normalize` closure to `AIUsageCredentialField`

**Do next (strategic, medium complexity):**
- 5. Provider endpoint/privacy declarations on `AIUsageProvider`
- 6. Typed `AIUsageSignalState` before more UI consumers land
- 8. Self-registering providers via `AIUsageRegistry.register(_:)`

**Do when ready (flywheel unlock):**
- 7. Socket read commands for AI usage state (`aiusage.status`, `aiusage.providers`)
- 9. Consent-gated local credential importer

**Explore later (high ambition):**
- Sparkline history overlay
- Threshold breach events and sidebar alerting
- Quota-aware agent launch routing
- Lattice task constraints on provider health
- C11 Credential Vault / BYOK primitive
