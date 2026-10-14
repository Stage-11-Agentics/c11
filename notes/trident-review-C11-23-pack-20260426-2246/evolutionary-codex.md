## Evolutionary Code Review
- **Date:** 2026-04-27T02:58:12Z
- **Model:** Codex / GPT-5
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6d1089d45dafd5c4494ddfb37cbf5c0269b4a61c
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory
---

Scope note: the wrapper prompt required a read-only review and prohibited actions beyond writing this file, so I did not run `git fetch` or `git pull`. Local `origin/dev` is absent; I used the context document's base, `origin/main`, and reviewed `origin/main...HEAD`.

## What's Really Being Built

This is not just "AI usage in the sidebar." This branch is the first local **quota control plane** inside c11.

The shape is already there: `AIUsageProvider` defines a provider, credential schema, usage fetcher, status fetcher, help URL, and display metadata in one value (`Sources/AIUsage/AIUsageProvider.swift:54`). `AIUsagePoller` centralizes snapshots, fetch errors, incidents, refresh state, and lifecycle (`Sources/AIUsage/AIUsagePoller.swift:19`). The sidebar footer and settings page consume that state (`Sources/AIUsage/UI/AIUsageFooterView.swift:3`, `Sources/AIUsage/UI/AIUsageSettingsSection.swift:3`). The docs now catalog outbound endpoints (`docs/privacy-endpoints.md:11`).

The deeper capability is: c11 can know which AI providers are usable, degraded, exhausted, or nearing reset, without asking the agent or the operator. That can evolve into routing, launch guidance, budget-aware orchestration, status-aware panes, and eventually a first-class "resource layer" for agents.

## Emerging Patterns

**Provider descriptors are becoming product primitives.** `AIUsageProvider` is already more than UI config: it carries credential fields, network behavior, provider identity, docs, and status fetch behavior (`Sources/AIUsage/AIUsageProvider.swift:54`). The static registry is a hand-built list today (`Sources/AIUsage/AIUsageRegistry.swift:7`), but the pattern wants to become a small provider manifest system.

**Privacy is implemented, but the contract is distributed.** Usage endpoints live inside fetchers (`Sources/AIUsage/ClaudeAIUsageFetcher.swift:75`, `Sources/AIUsage/CodexAIUsageFetcher.swift:73`), status hosts live in the status poller allowlist (`Sources/AIUsage/AIUsageStatusPagePoller.swift:11`), and the public catalog lives in docs (`docs/privacy-endpoints.md:11`). That is good enough for two providers, but it will drift as soon as more providers or endpoint variants appear.

**The poller is acting like both scheduler and data plane.** `AIUsagePoller` owns timer lifecycle, visibility gating, account iteration, timeout wrapping, status cadence, errors, incidents, and published UI state (`Sources/AIUsage/AIUsagePoller.swift:76`, `Sources/AIUsage/AIUsagePoller.swift:151`). That concentration is useful for landing the feature, but it is also the main leverage point for the next phase.

**Temporal quota UX is half-born.** The domain model records reset times (`Sources/AIUsage/AIUsageProvider.swift:5`), fetchers parse or derive them (`Sources/AIUsage/ClaudeAIUsageFetcher.swift:126`, `Sources/AIUsage/CodexAIUsageFetcher.swift:131`), and `AIUsageResetLabel` exists (`Sources/AIUsage/UI/AIUsageResetLabel.swift:3`). The sidebar bar currently renders only label, bar, and percent (`Sources/AIUsage/UI/AIUsageFooterView.swift:150`), while the docs promise "the next reset window when known" (`docs/ai-usage-monitoring.md:15`). That is a product direction trying to surface.

**Settings integration is still app-root shaped.** The settings page adds AI usage state and sheet/dialog wiring directly into `cmuxApp` (`Sources/c11App.swift:4430`, `Sources/c11App.swift:4974`, `Sources/c11App.swift:6050`). This is consistent with nearby settings code, but it makes each future provider capability more expensive to mount.

## How This Could Evolve

The cleanest evolution is to split the feature into three layers:

1. **Provider Manifest Layer**: declarative provider identity, credential fields, endpoint declarations, status source, polling cadence, display traits, and docs anchors.
2. **Quota Telemetry Layer**: background scheduler that materializes usage/status snapshots, freshness, last-success cache, and failure classifications.
3. **Operator Surface Layer**: sidebar/settings/popover views, plus future CLI/socket/metadata exposure.

That would let c11 grow from two hardcoded providers to a small catalog without scattering privacy work, localization, tests, and UI wiring across unrelated files. It also matches c11's larger architecture: surfaces and agents should be addressable, and provider quota should become another addressable state source rather than a private footer concern.

## Mutations and Wild Ideas

**Budget-aware agent launching.** When a pane launches Codex or Claude, c11 could annotate that surface with provider pressure: normal, high, exhausted, status-degraded. The existing surface metadata culture makes this feel native. `AIUsagePoller.snapshots` already contains per-account session/week pressure (`Sources/AIUsage/AIUsagePoller.swift:19`); the missing piece is a derived pressure model and a route from poller to socket/sidebar metadata.

**The "provider traffic light" as workspace chrome.** Instead of burying usage in a footer section, c11 could show provider availability as a tiny workspace-level signal. This is especially valuable for the operator running many agents: the question is not "what is my exact percentage?" but "can I safely start another expensive loop?"

**Quota-aware pane templates.** Workspace blueprints could declare desired provider budgets: "needs Codex < 80% session" or "prefer Claude if OpenAI status is degraded." This branch creates the first local signal needed for that.

**Privacy ledger generated from code.** Provider manifests could generate `docs/privacy-endpoints.md`, a runtime privacy view in Settings, and endpoint assertions in tests from one source of truth. The hard guarantee in docs (`docs/privacy-endpoints.md:18`) would stop being prose and become a checked artifact.

**Local credential importers with explicit consent.** For Codex, the docs tell users to run `jq` against `~/.codex/auth.json` (`docs/ai-usage-monitoring.md:55`). A future importer trait could read known local auth files only after explicit operator action and show exactly what will be copied into Keychain. This must stay inside c11's "unopinionated about the terminal" boundary: read-only import by user request, no writing tenant config.

## Leverage Points

**Provider endpoint metadata.** Add endpoint declarations to `AIUsageProvider` while the provider count is still two. This creates a single place for allowlist, docs, tests, and privacy UI to converge.

**Derived quota status.** Add a small `AIUsagePressure` or `AIUsageAvailability` model above raw snapshots/incidents. Views, socket commands, and future launch guidance should not each decide what 96% session + minor incident + stale status means.

**Concurrent polling with freshness semantics.** The current serial account loop (`Sources/AIUsage/AIUsagePoller.swift:172`) is simple, but it ties total refresh time to account count and provider latency. A task-group fanout that returns immutable results would scale better and reduce UI ambiguity.

**Reset-time display.** Render the already-existing reset label path. It is small, directly user-visible, and turns the feature from a static meter into an actionable planning aid.

**Settings modularity.** Wrap the AI usage settings state/sheet/dialog wiring into a coordinator view or model so future provider controls do not keep expanding `c11App`.

## The Flywheel

The best flywheel is: more providers -> better quota/status confidence -> operators trust c11 to plan agent work -> agents can expose their intended provider use -> c11 can schedule and annotate work more intelligently -> more value from adding providers.

Right now, the first spin is available but not wired. The branch gathers provider usage and incident state, but that state only feeds a footer/settings UI. The next turn should expose a normalized provider availability primitive that other c11 systems can consume. Once that exists, each provider integration improves not just a widget, but the whole operator:agent command center.

## Concrete Suggestions

1. **High Value - Promote provider endpoints into explicit provider metadata.**  
   ✅ Confirmed — `AIUsageProvider` has room for additional immutable metadata alongside fields, status URL, help URL, and fetch closures (`Sources/AIUsage/AIUsageProvider.swift:54`). Usage URLs currently live in fetchers (`Sources/AIUsage/ClaudeAIUsageFetcher.swift:75`, `Sources/AIUsage/CodexAIUsageFetcher.swift:73`), status hosts are separately allowlisted (`Sources/AIUsage/AIUsageStatusPagePoller.swift:11`), and docs duplicate the endpoint list (`docs/privacy-endpoints.md:11`). Add something like:
   - `declaredEndpoints: [AIUsageEndpoint]`
   - `pollingCadence`
   - `privacyPurpose`
   - `credentialHeaders`
   
   Then generate or at least validate `docs/privacy-endpoints.md` from this descriptor. Dependency/risk: keep concrete request construction in fetchers so credential handling stays explicit; metadata should describe endpoints, not build secret-bearing requests.

2. **High Value - Make reset windows visible in the sidebar.**  
   ✅ Confirmed — reset information is already modeled (`Sources/AIUsage/AIUsageProvider.swift:5`), parsed (`Sources/AIUsage/ClaudeAIUsageFetcher.swift:126`, `Sources/AIUsage/CodexAIUsageFetcher.swift:131`), and classified by `providerUsageResetLabel` (`Sources/AIUsage/UI/AIUsageResetLabel.swift:10`). The sidebar bar currently stops at percent text (`Sources/AIUsage/UI/AIUsageFooterView.swift:150`), so the existing helper is unused. Add compact reset copy under or beside each bar, probably only for the session row at footer density and both rows in the popover. Dependency/risk: format with localized relative time and avoid a timer that updates every second; minute-level refresh is enough and keeps sidebar churn low.

3. **High Value - Split polling into fanout collection plus main-actor publication.**  
   ✅ Confirmed — `AIUsagePoller` is `@MainActor` (`Sources/AIUsage/AIUsagePoller.swift:15`) and loops accounts serially (`Sources/AIUsage/AIUsagePoller.swift:172`) before looping provider status serially (`Sources/AIUsage/AIUsagePoller.swift:211`). Provider fetch closures are `@Sendable` (`Sources/AIUsage/AIUsageProvider.swift:62`), keychain access is already off-main through detached tasks (`Sources/AIUsage/AIUsageKeychain.swift:131`), and the current code publishes dictionaries in one batch (`Sources/AIUsage/AIUsagePoller.swift:204`). Refactor `runTick` into:
   - snapshot inputs on main
   - load secrets
   - fan out provider fetches in a task group
   - return value-typed results
   - publish once on main if generation still matches
   
   Dependency/risk: do not mutate `@Published` values from child tasks; keep generation cancellation exactly as strict as today.

4. **Strategic - Introduce a normalized `AIUsageAvailability` layer.**  
   ✅ Confirmed — raw ingredients already exist: snapshots (`Sources/AIUsage/AIUsagePoller.swift:19`), account fetch errors (`Sources/AIUsage/AIUsagePoller.swift:20`), provider incidents (`Sources/AIUsage/AIUsagePoller.swift:21`), status ranking (`Sources/AIUsage/UI/AIUsageStatusRanking.swift:3`), and provider/account identity (`Sources/AIUsage/AIUsageAccount.swift:3`). Add a pure model that derives states such as `available`, `pressureHigh`, `exhausted`, `authExpired`, `statusDegraded`, and `stale`. Use it in footer, settings summaries, and future socket exposure. Dependency/risk: keep this pure and testable; avoid making views or the poller each invent slightly different interpretations.

5. **Strategic - Turn the provider registry into a small catalog contract.**  
   ✅ Confirmed — the registry is a static array today (`Sources/AIUsage/AIUsageRegistry.swift:7`) and tests only assert presence/uniqueness at the current level (`c11Tests/AIUsageTests.swift:401`). Keep it static for now, but formalize catalog invariants: unique provider IDs, unique keychain services, declared endpoint coverage, localized display strings, valid status allowlist entries, and at least one executable parser/fetcher test per provider. Dependency/risk: do not jump to dynamic plugins until the static catalog has a strong contract; dynamic loading would be premature for a credential-bearing feature.

6. **Strategic - Extract AI usage settings coordination out of `cmuxApp`.**  
   ✅ Confirmed — `cmuxApp` now owns AI usage store/poller/color state (`Sources/c11App.swift:4430`), editor sheet mounting (`Sources/c11App.swift:4974`), removal confirmation/error handling (`Sources/c11App.swift:4981`), section placement (`Sources/c11App.swift:6050`), and reset-all linkage (`Sources/c11App.swift:6417`). A coordinator view or `AIUsageSettingsCoordinator` could own editor/removal state and expose one `AIUsageSettingsEntryPoint`. Dependency/risk: follow existing settings patterns enough to avoid a style fork; the goal is containment, not a new settings framework.

7. **Strategic - Expose quota state to c11's agent-facing primitives.**  
   ❓ Needs exploration — the AI usage module is currently UI-only, and no socket command was added in this branch. The architectural fit is strong because c11 already treats surface metadata and CLI/socket state as agent-facing primitives, but the exact API needs design. A conservative first step: add a read-only socket command or metadata source that returns provider-level `AIUsageAvailability` without credentials or account identifiers. Dependency/risk: privacy surface is larger than the UI; default to aggregate status and redacted account labels.

8. **High Value - Add fixture-driven parser tests before adding more providers.**  
   ✅ Confirmed — tests exercise validators, keychain round trips, sessions, status allowlist, color settings, and poller lifecycle (`c11Tests/AIUsageTests.swift:21`, `c11Tests/AIUsageTests.swift:154`, `c11Tests/AIUsageTests.swift:179`, `c11Tests/AIUsageTests.swift:422`). The concrete fetcher parsers are private (`Sources/AIUsage/ClaudeAIUsageFetcher.swift:122`, `Sources/AIUsage/CodexAIUsageFetcher.swift:117`), so provider payload shape regressions are mostly covered indirectly only if network fetch is mocked later. Add local JSON fixture tests through an injectable transport or parser seam. Dependency/risk: keep tests behavioral; do not add source-text or project-file assertions, per repo policy.

9. **High Value - Replace sleep-based poller lifecycle tests with a deterministic tick hook.**  
   ✅ Confirmed — the lifecycle test sleeps for 50 ms twice (`c11Tests/AIUsageTests.swift:476`, `c11Tests/AIUsageTests.swift:481`). This is not a 60-second timer sleep, but it is still a small source of flake. The poller already has a `tickBody` seam (`Sources/AIUsage/AIUsagePoller.swift:35`), so the test can wait on an XCTest expectation/continuation signaled by `tickBody` instead of sleeping. Dependency/risk: keep the test under `@MainActor`; avoid introducing a local run-loop dependency.

10. **Experimental - Build a "quota forecast" view.**  
    ❓ Needs exploration — the model currently knows utilization and reset windows, not burn rate. If c11 stores recent samples locally, it could estimate "at current pace, session hits 95% in 42 min." This is useful for long loopy tasks. Risk: forecasts can be misleading with bursty human/agent behavior; mark it explicitly as an estimate.

11. **Experimental - Add provider-aware workspace badges.**  
    ❓ Needs exploration — once `AIUsageAvailability` exists, workspace tabs or pane titlebars could show tiny provider indicators. The sidebar footer mount is confirmed (`Sources/ContentView.swift:9468`), but workspace chrome has its own performance constraints. This should wait until the derived state is cheap and stable.

12. **Experimental - Local credential importers as opt-in one-shot actions.**  
    ❓ Needs exploration — Codex setup currently requires manual shell commands from docs (`docs/ai-usage-monitoring.md:55`). A user-invoked importer could reduce setup friction. Risk: c11's principle says it should not configure other TUIs or write tenant config, so this must be read-only, explicit, previewed, and Keychain-only.

## Closing Direction

The strongest next move is not adding more UI polish. It is naming and extracting the primitive this branch has already created: provider quota and availability. If C11-23 lands with a small `AIUsageAvailability` layer plus provider endpoint metadata, the next ten features become easier: more providers, safer privacy review, status-aware launching, quota badges, and eventually budget-aware agent orchestration.
