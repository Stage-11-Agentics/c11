## Evolutionary Code Review
- **Date:** 2026-04-27T03:46:47Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** e7987ee9
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory
---

Note: the wrapper prompt constrained this pass to a read-only review and writing only this file, so I did not run `git fetch`, `git pull`, local tests, or any build. I reviewed the local branch against `origin/main...HEAD` and the second-pass context.

## What's Really Being Built

This is not just "show Claude/Codex quota in the sidebar." It is the first version of a **local operator signal substrate**: authenticated, user-opted external service state gets pulled into c11, normalized into small typed snapshots, rendered in the operator's persistent field of view, and backed by privacy boundaries.

The important primitive is visible in `AIUsageProvider`: credential schema, status URL, help URL, usage fetch closure, and status fetch closure all live together as a provider descriptor (`Sources/AIUsage/AIUsageProvider.swift:31`, `Sources/AIUsage/AIUsageProvider.swift:54`). `AIUsagePoller` then turns those descriptors into a steady signal loop with snapshots, fetch errors, incidents, and visibility-aware scheduling (`Sources/AIUsage/AIUsagePoller.swift:21`, `Sources/AIUsage/AIUsagePoller.swift:130`).

That is bigger than usage bars. It is a pattern for bringing the operator's dependency graph into c11: model quotas, provider outages, CI health, Lattice queue pressure, account expiry, deploy windows, maybe even local agent saturation. The branch creates the shape of a "cockpit instrument" system.

## Emerging Patterns

The strongest pattern is **provider-as-data with behavior closures**. Claude and Codex are added as static provider values, not subclasses or switch cases (`Sources/AIUsage/ClaudeAIProvider.swift:48`, `Sources/AIUsage/CodexAIProvider.swift:36`). That is the right direction. It keeps future providers cheap, and it makes settings/UI code mostly provider-agnostic.

The second pattern is **privacy as code plus docs**. The implementation hard-codes ephemeral sessions (`Sources/AIUsage/AIUsageHTTP.swift:10`), Keychain-only storage (`Sources/AIUsage/AIUsageKeychain.swift:89`), status host allowlisting (`Sources/AIUsage/AIUsageStatusPagePoller.swift:10`), and an endpoint catalog (`docs/privacy-endpoints.md:1`). That combination should become a convention for every feature that calls out to the network.

The third pattern is **UI surfaces consuming a shared signal stream**. Settings, popover, and sidebar all observe the same store/poller state (`Sources/AIUsage/UI/AIUsageFooterView.swift:3`, `Sources/AIUsage/UI/AIUsageSettingsSection.swift:3`, `Sources/AIUsage/UI/AIUsagePopover.swift:4`). That is already close to a reusable app-internal signal model.

The main anti-pattern forming early is **manual registration drift**. Adding one provider currently means editing at least the provider file, `AIUsageRegistry.all`, `AIUsageStatusPagePoller.allowedHosts` when needed, docs, translations, tests, and the Xcode project (`Sources/AIUsage/AIUsageRegistry.swift:3`, `Sources/AIUsage/AIUsageStatusPagePoller.swift:10`, `docs/privacy-endpoints.md:11`). That is manageable for two providers and brittle at five.

## How This Could Evolve

The highest-value evolution is to promote `AIUsageProvider` into a more explicit **provider capability manifest**. Today it describes fields and closures. Add declared endpoint metadata, cadence, data classification, and optional status host to the provider itself. Then the privacy endpoint inventory, settings help, and maybe debug diagnostics can be generated or validated from the runtime registry.

The poller wants to become a generic **SignalPoller**. Its state machine already handles start/stop, coalescing force refreshes, visibility gating, generation checks, timeout wrapping, and stale account filtering (`Sources/AIUsage/AIUsagePoller.swift:79`, `Sources/AIUsage/AIUsagePoller.swift:139`, `Sources/AIUsage/AIUsagePoller.swift:239`). Those are not quota-specific. If this becomes reusable, the next background status module should not re-solve scheduling, occlusion, timeout, stale result rejection, and "keep last good status" behavior.

The credential model wants **normalizers**, not just validators. `AIUsageCredentialField` exposes `validate` (`Sources/AIUsage/AIUsageProvider.swift:31`), while the editor globally trims all fields before save (`Sources/AIUsage/UI/AIUsageEditorSheet.swift:157`). Claude already has `strippedSessionKey` because users paste a cookie segment (`Sources/AIUsage/ClaudeAIProvider.swift:36`), and Codex docs ask users to run `jq` (`docs/ai-usage-monitoring.md:59`). The field contract should let providers normalize pasted blobs into canonical stored values. That would turn onboarding from "copy exact internals" into "paste the thing you have."

The user-facing status model wants richer semantics. `AIUsageWindow` is currently percent, reset date, and duration (`Sources/AIUsage/AIUsageProvider.swift:3`). That works for bars, but the architecture could carry state such as `.fresh`, `.stale`, `.degraded`, `.authExpired`, `.unknownWindow`, and `.providerIncident`. The UI could then explain uncertainty without collapsing everything into either a percent bar or a generic fetch error.

## Mutations and Wild Ideas

**Operator Budget Ledger.** Treat every account as a budget source and every agent/session as a budget consumer. c11 could show not just current quota, but projected burn rate by workspace. This would need agent telemetry, but the signal substrate starts here.

**Dependency Weather.** Generalize the status polling path into a small status strip per workspace: provider incidents, GitHub Actions health, Lattice health, local socket health. The `AIUsageStatusRanking` severity model (`Sources/AIUsage/UI/AIUsageStatusRanking.swift:3`) is already a tiny weather model.

**Quota-Aware Agent Launch.** When c11 launches or orchestrates agents, it could warn if the chosen provider account is near threshold or in an incident. This should not block the operator, but it could route decisions: "Use Codex work account, Claude personal is at 96%."

**Local Auth Import, Consent Only.** Without becoming a configurator or writing another tool's files, c11 could offer an explicit one-shot import flow from known local auth files. The docs already tell users to read `~/.codex/auth.json` (`docs/ai-usage-monitoring.md:59`). A consent-gated import button would reduce error-prone token copying while respecting the repo principle that c11 does not mutate tenant configs.

**Signal Surfaces.** The sidebar footer is one renderer. The same snapshots could be exposed to markdown surfaces, socket metadata, titlebar badges, or Lattice handoffs. The architecture is close because snapshots are already provider/account keyed and side-effect free (`Sources/AIUsage/AIUsageProvider.swift:14`).

## Leverage Points

The smallest high-leverage move is adding a `normalize` closure to `AIUsageCredentialField`. It has a narrow API surface, improves both providers immediately, and reduces future provider-specific editor hacks.

The next is putting endpoint declarations on `AIUsageProvider`. This creates a single source of truth for privacy review. It also gives tests a behavioral seam: instantiate providers and verify that status hosts and documented endpoint declarations are internally consistent, without grep-style source tests.

The largest strategic lever is extracting the poll loop mechanics. Keep `AIUsagePoller` as the product-facing object, but move the reusable scheduling/coalescing/timeout shell behind it. The payoff compounds when the next external signal arrives.

Another leverage point is status/error taxonomy. `C11AppOwnedError` is a good top-level move (`Sources/Errors/C11AppOwnedError.swift:3`), but errors are still flattened into strings for UI state (`Sources/AIUsage/AIUsagePoller.swift:22`, `Sources/AIUsage/AIUsagePoller.swift:255`). A typed status layer would make UI, automation, and future telemetry cleaner.

## The Flywheel

The flywheel is:

1. Add a provider descriptor.
2. c11 can fetch its state safely.
3. The operator sees that state without context switching.
4. The state informs agent routing and work timing.
5. More provider descriptors become worth adding.
6. Each new descriptor strengthens the cockpit.

To set it spinning, make provider addition mostly declarative and make the signal loop reusable. If adding the next provider requires editing seven places, the flywheel stalls. If it requires one descriptor plus a fetcher, it accelerates.

## Concrete Suggestions

1. **High Value - Add provider endpoint/privacy declarations.** ✅ Confirmed - compatible with the current descriptor architecture.

   Extend `AIUsageProvider` with a small endpoint manifest, for example `networkEndpoints: [AIUsageEndpointDeclaration]`, containing host, path template, purpose, cadence, credential-bearing flag, and privacy classification. Claude/Codex providers already know this information at declaration time (`Sources/AIUsage/ClaudeAIProvider.swift:89`, `Sources/AIUsage/CodexAIProvider.swift:77`), and the docs duplicate it (`docs/privacy-endpoints.md:11`). This would make privacy review part of provider registration rather than a parallel manual checklist.

   Dependencies/risks: avoid tests that read checked-in docs directly, per project policy. Prefer a runtime unit test over `AIUsageRegistry.all` that asserts every credential-bearing provider declares endpoints and every declared status host is accepted by the status poller allowlist.

2. **High Value - Add field normalizers to `AIUsageCredentialField`.** ✅ Confirmed - the editor already centralizes save-time transformation.

   Add `normalize: (@Sendable (String) -> String)?` beside `validate` (`Sources/AIUsage/AIUsageProvider.swift:31`). In `AIUsageEditorSheet.save()`, trim first, then apply the provider normalizer per field before building `AIUsageSecret` (`Sources/AIUsage/UI/AIUsageEditorSheet.swift:157`). Claude can store the stripped session key instead of stripping only at fetch time (`Sources/AIUsage/ClaudeAIProvider.swift:70`), and Codex can accept a pasted JSON token blob or `Bearer ...` value if desired.

   Dependencies/risks: make normalization visible in tests so redaction remains intact and secrets do not leak through validation messages. Keep normalizers pure; no file reads in the field contract.

3. **High Value - Split reusable poll orchestration from usage-specific state.** ✅ Confirmed - the mechanics are concentrated enough to extract incrementally.

   `AIUsagePoller` owns quota-specific dictionaries, but its scheduling shell is generic: timer start/stop (`Sources/AIUsage/AIUsagePoller.swift:79`), occlusion observer (`Sources/AIUsage/AIUsagePoller.swift:93`), in-flight coalescing (`Sources/AIUsage/AIUsagePoller.swift:130`), generation discard (`Sources/AIUsage/AIUsagePoller.swift:194`), and timeout racing (`Sources/AIUsage/AIUsagePoller.swift:239`). Extract a small internal helper only after the next signal module appears, or do it now if C11-23 is expected to seed more provider-health work.

   Dependencies/risks: avoid over-abstracting before the second consumer. The low-risk version is to name the pattern in comments/docs and isolate the generic parts in private methods so the eventual extraction is mechanical.

4. **Strategic - Introduce typed signal state before more UI consumers appear.** ✅ Confirmed - current public state is still simple dictionaries and strings.

   Add a typed `AIUsageAccountStatus` or `AIUsageSignalState` that wraps snapshot/error/loading/stale/auth-expired/degraded. Today the UI branches over `fetchErrors`, `snapshots`, and `isRefreshing` (`Sources/AIUsage/UI/AIUsageFooterView.swift:229`), while settings separately summarizes snapshots/errors (`Sources/AIUsage/UI/AIUsageSettingsSection.swift:235`). A single typed state would prevent divergent interpretations as more renderers land.

   Dependencies/risks: this is a data-shape migration. It should preserve the existing `@Published` fields until both current UIs are converted, or it should be introduced as a derived computed map first.

5. **Strategic - Expose AI usage snapshots as a c11 surface/socket-readable signal.** ❓ Needs exploration - architecture supports it, but the product boundary needs a decision.

   The branch already normalizes account/provider usage into `AIUsageSnapshot` (`Sources/AIUsage/AIUsageProvider.swift:14`). The next evolution is letting agents query aggregate usage through a socket command or read-only metadata surface so orchestration can route work with quota awareness. This matches c11's "every handle is scriptable" mission, but credentials and account names need careful redaction.

   Dependencies/risks: only expose derived utilization/status, never raw credential fields. Consider user opt-in and workspace scoping before making this visible to arbitrary local socket clients.

6. **Strategic - Make status polling a shared provider-health layer.** ✅ Confirmed - the status implementation is already independent of quota fetchers.

   `AIUsageStatusPagePoller` fetches Statuspage incidents with host allowlisting (`Sources/AIUsage/AIUsageStatusPagePoller.swift:10`) and `AIUsageStatusRanking` maps incidents to severity text (`Sources/AIUsage/UI/AIUsageStatusRanking.swift:3`). This can become a general `ProviderHealth` subsystem consumed by AI usage, browser/cloud features, update checks, or Lattice integrations.

   Dependencies/risks: keep the status host allowlist explicit. If generalized, the provider endpoint manifest should own allowlist contributions so new status hosts stay reviewable.

7. **Experimental - Add consent-gated local credential importers.** ❓ Needs exploration - useful, but it touches a sensitive product principle.

   Codex onboarding currently asks users to run `jq` on `~/.codex/auth.json` (`docs/ai-usage-monitoring.md:59`). c11 could offer a read-only, user-triggered import button that parses known files and writes only to c11's Keychain item. That would not install hooks or mutate other tools, so it can respect the "unopinionated about the terminal" principle if scoped carefully.

   Dependencies/risks: do not auto-scan silently. Do not watch files. Do not write back. A manual file picker or explicit "Import from Codex auth.json" button is the clean boundary.

8. **Experimental - Add quota-aware workspace badges.** ⬇️ Lower priority than initially thought.

   The sidebar footer is enough for C11-23, and adding more chrome could clutter the operator field. Still, once `AIUsageSnapshot` is exposed as a typed signal, workspaces with active agents could opt into subtle quota badges or warnings based on their selected provider/account.

   Dependencies/risks: needs a mapping from workspace/agent to provider account, which this branch does not yet have. This should wait for agent launch metadata or Lattice integration.

## Highest-Leverage Next Step

Add the provider capability manifest first: endpoint declarations plus credential field normalizers. That single move formalizes the branch's best pattern, reduces provider drift, improves onboarding, gives privacy review a runtime source of truth, and sets up the future signal substrate without prematurely extracting a generic poller.
