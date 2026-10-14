## Evolutionary Code Review
- **Date:** 2026-04-26T22:46:00Z
- **Model:** Claude (claude-opus-4-7)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** d5d99f609fd9575b3435aa47dcb1e80ded667587
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory
---

## What's Really Being Built

The stated feature is "show me how much Claude/Codex quota I have left in the sidebar." That framing undersells what's actually landing in this branch.

What's really being built is **c11's first piece of operator telemetry infrastructure** — an in-app, allowlisted, Keychain-rooted, ephemeral-session HTTP polling subsystem with a typed provider registry and an opt-in UI surface. Read the file list with that lens and the shape becomes obvious:

- `AIUsageProvider` is not a "Claude/Codex thing." It's a **provider plugin protocol** with credentials, a fetch closure, an optional status closure, a keychain service, and a help URL. Anything that fits that shape can be added in ~100 lines (the entire `ClaudeAIProvider.swift` is 103 lines, `CodexAIProvider.swift` is 91).
- `AIUsageHTTP` + `AIUsageStatusPagePoller.allowedHosts` is **c11's first hard-allowlisted egress lane.** Until now, c11 didn't have a single canonical answer to "what hosts can the chrome talk to?" Now there's a documented file (`docs/privacy-endpoints.md`) and an enforced set (`allowedHosts` + the slash/colon rejection) that newcomers must extend deliberately. That convention is more important than the feature.
- `AIUsageKeychain` is **c11's first proper Keychain abstraction** — `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`, `Task.detached` off-main, isolated test services. It's the credential primitive c11 has been quietly missing.
- `AIUsageSecret` (`description`/`debugDescription`/`customMirror` all elide the value, with a test that verifies `dump()` output) is **a redaction pattern** that should be the template for any other secret type that ever lands in this repo.
- `AIUsagePoller` is **c11's first occlusion-aware background polling primitive** with generation-tagged cancellation, a scheduled tick + manual `refreshNow` + status-page sub-rhythm (every 5th tick), and an `XCTest` start gate at the call site.

In short: this branch isn't shipping a quota meter. It's shipping the **connector substrate** — credential vault, provider protocol, allowlisted HTTP, occlusion-aware poller, secret-safe logging, redacted test pattern — and using "Claude/Codex usage" as the proof-of-concept.

That makes the review stakes higher than the feature suggests. Get the seams right and c11 has a clean spine for everything an operator might want telemetry on. Bake in the wrong abstractions and you get N copies of subtly different polling/keychain/HTTP code as features accrete.

---

## Emerging Patterns

### Patterns worth formalizing now

1. **Provider-as-value with a `Providers` namespace.** `AIUsageRegistry.all = [Providers.claude, Providers.codex]` plus `extension Providers { static let claude = ... }` per file is a crisp, file-local registration pattern. Each provider is a `let`, not a singleton class. Adding a new one is a single file. **Formalize this** — the next telemetry/connector subsystem should adopt the same shape (`SomethingRegistry.all` + `extension Somethings`).

2. **`AIUsageAppOwnedError` marker protocol.** This is the unsung hero of the diff. The poller has a deliberate rule: **only error descriptions from app-owned, intentionally-localized error types are ever shown to the user**. Everything else falls back to the generic catalog string. This is exactly the boundary that prevents `URLError`'s raw "The Internet connection appears to be offline" from leaking into your UI. Promote this to a top-level `c11AppOwnedError` and adopt it everywhere user-facing errors are surfaced.

3. **Generation-tagged async tasks.** `AIUsagePoller.taskGeneration &+= 1` + `if generation != taskGeneration { return }` after each await is the right pattern for "the world may have moved on while I was waiting on the network." This is going to need to exist for browser fetches, status checks, every async sidebar widget. Lift it into a small helper.

4. **Per-tick visibility gate via `NSApp.occlusionState`.** A polling subsystem that respects window visibility is the first place c11 has codified "don't burn quota/CPU when nobody is looking." Other timer-driven subsystems (notifications, background browser refreshes, anything you build later) should reach for the same primitive. Extract `OcclusionAwareTimer` — `AIUsagePoller` becomes its first consumer.

5. **Test seam via constructor injection of a `tickBody` closure.** `AIUsagePoller.init(... tickBody: (@MainActor (Bool) async -> Void)? = nil)` is how the lifecycle tests count ticks without sleeping for 60 seconds. **This is exactly the kind of seam CLAUDE.md's test policy is asking for.** Memorialize this technique in the testing doc/skill: any timer-driven class gets a closure seam in its initializer; tests provide the closure and assert on its invocation count.

6. **Hard-allowlisted egress.** `allowedHosts` + slash/colon rejection + `docs/privacy-endpoints.md` as a documented contract is c11's first formal **egress policy**. Treat it as architecturally load-bearing. Every future feature that does outbound HTTP from the chrome should land its host(s) in `privacy-endpoints.md` in the same PR, and ideally route through a shared "is this host allowed?" check.

### Anti-patterns to catch early

1. **`AIUsageAccountStore.shared` and `AIUsagePoller.shared` are global singletons reaching for `AIUsageRegistry.all` directly.** The non-test inits hard-bind to globals. Every other feature is going to want the same shape, and you'll end up with a constellation of `XSettings.shared` / `XStore.shared` / `XPoller.shared` singletons each doing their own boot dance. The DI seam exists in the test inits — it just needs a non-test home (a small `AIUsageContainer` or app-level composition root).

2. **UserDefaults keys scattered across files.** `c11.aiusage.color.low`, `c11.aiusage.collapsed.<providerId>`, `c11.aiusage.accounts.index` are all string literals at point of use. As soon as a third file wants to read or migrate one of these, the typo risk lands. Centralize in an `AIUsageDefaultsKeys` enum.

3. **Per-provider `keychainService` constants.** `"com.stage11.c11.aiusage.claude-accounts"` is repeated literally in `ClaudeAIProvider.swift`, `AIUsageAccountStore.defaultResolver`, and the test for the registry. Three sources of truth. One should be canonical (the provider value), and the registry tests should read it from there.

4. **The popover does its own collapsed-state persistence inline** (`AIUsageFooterView.providerSection` reads/writes `UserDefaults.standard` from inside `@ViewBuilder`). It works, but the body re-evaluates every time the poller publishes. Move the collapsed map into an `@StateObject` view model so each tick doesn't trigger a defaults read.

5. **Reset-to-defaults conflates colors with scope.** `SettingsView.applyResetSettings()` calls `AIUsageColorSettings.shared.resetToDefaults()` but explicitly does NOT remove accounts (correct). The doc spells this out. Good — but as more telemetry providers land, the global "Reset Settings" will need a clearly-defined contract about what it touches; consider a registry-level `resetVisualPreferences()` so each subsystem owns its own definition.

---

## How This Could Evolve

### 1. Promote the provider protocol from "AI usage" to "operator connectors"

`AIUsageProvider` already has fetch + status + keychain + UI fields + display name. Rename and generalize:

```
protocol C11Connector {
    var id: String { get }
    var displayName: String { get }
    var keychainService: String { get }
    var credentialFields: [ConnectorCredentialField] { get }
    var statusPageURL: URL? { get }
}

protocol UsageProducingConnector: C11Connector {
    func fetchUsage(_ secret: ConnectorSecret) async throws -> UsageWindows
}

protocol StatusProducingConnector: C11Connector {
    func fetchStatus() async throws -> [Incident]
}
```

Today's two providers stay; tomorrow's `GitHubConnector` (PR notifications, action minutes), `ZulipConnector` (unread mentions), `LatticeConnector` (open task counts) all slot in. The **footer becomes a connector grid**, not an AI-usage panel.

### 2. Expose connectors to agents via the c11 socket/CLI

This is where it gets interesting. An agent inside a c11 pane can already call `c11 set-status`. What if it could call `c11 read-connector claude.session-window` and get `{utilization: 67, resetsAt: 2026-04-26T18:00Z}`? Suddenly the operator's quota awareness becomes the *agent's* quota awareness. An agent that knows it's at 92% utilization could:
- pause non-urgent work
- compress context proactively
- ask the operator before launching another loopy iteration
- queue a status broadcast: "I'm slowing down; quota reset in 47m."

The poller already publishes `snapshots`, `fetchErrors`, `incidents`, `statusFetchFailed` as `@Published` properties. A small socket command (`aiusage.snapshot`) would expose this read-only. **This is the highest-leverage move in the whole branch** because it transforms a UI feature into a coordination primitive for the operator:agent pair, which is exactly what CLAUDE.md says c11 is *for*.

### 3. Local time-series so utilization gets a memory

Today the poller is a stateless display: each tick replaces the snapshot. But the data is already arriving at 60-second granularity. Persist it. A small append-only ring buffer (last 24h, ~1440 points per account) on disk gives you:

- **Sparkline next to each bar** ("you spent quota faster than usual this hour").
- **"Will I run out before reset?"** — a trivial linear extrapolation.
- **Cross-account budgeting** — when "Personal" Claude is at 95% but "Work" is at 30%, suggest the swap.
- **Agent-readable history** via the same socket — agents can see their own consumption curve.

This is a 200-300 LOC addition (a `AIUsageHistory` actor + a sparkline view) but it changes the product from "current state" to "trend awareness."

### 4. Status-page poller as a generic "incident watcher"

The hosts are allowlisted; the parser is generic statuspage.io JSON. Open it up: any operator-relevant service that runs on statuspage.io (GitHub, Cloudflare, Stripe — c11/Stage 11 already touches these) could get an "incidents" tile. Same `Incident` shape, same severity ranking, same component filter. Add hosts to the allowlist, add a `StatusFeed` registry, render in the footer below the AI section. Total cost: tiny. Total operator value: high — one place to see "is anything in my stack broken right now."

### 5. Browser-based credential capture

The Claude flow today: open DevTools, find a cookie, find a UUID in a request URL, paste both into a sheet. That's a four-step user-extracts-from-browser dance.

c11 has an embedded WKWebView browser. The natural mutation: **"Sign in to Claude" button opens the embedded browser, navigates to claude.ai, lets the user log in, then a JS bridge hands the cookie + orgId back to the editor sheet automatically.** Same for `~/.codex/auth.json` — c11 could just read it directly with user permission rather than asking the user to run `jq`. This collapses onboarding from "DevTools spelunking" to "click and go." The c11-browser skill already exposes the substrate.

### 6. Skill primitive: agent self-awareness

If snapshots are exposed via socket, the next step is the c11 skill teaching agents: "Before starting a long loop, check `c11 aiusage snapshot` and report your starting quota; pause and report when you cross 80%/95% thresholds." That makes quota a first-class concern in agent etiquette, the way `c11 set-status` made progress reporting a first-class concern.

---

## Mutations and Wild Ideas

1. **Self-throttling agents.** With socket access to live utilization, an agent's launcher could refuse to spawn a new clear-Claude when the operator's account is over a threshold. The skill teaches the rule; the connector enforces it. A budget-aware swarm.

2. **Quota-aware model routing.** `cc` (or whatever launches the agent) reads the connector and picks Claude vs Codex based on which has more quota right now. Operator-side load balancing without operator involvement.

3. **"Burn rate" sparkline overlay on tab titles.** When a c11 tab is running an agent on a known provider and that provider is under load, paint a thin colored stripe along the tab. The footer is where the data lives; the tabs are where the agent activity lives. Connect them.

4. **Connector marketplace shape.** The provider-as-value pattern + Keychain abstraction + allowlist is *almost* a plugin manifest. A `connector.json` (id, display, fields, fetch URL template, JSON path expressions for utilization/resetsAt, allowlisted hosts) and a generic interpreter could let users add a connector for any statuspage-like service without recompiling. Risky — interpreter complexity, security surface — but worth naming because it's where this architecture is naturally pointing.

5. **"What's my cheapest hour?" report.** With time-series, c11 knows when the operator has been most productive on the cheapest quota. Show a weekly digest: "You shipped 4 PRs Tuesday morning at 23% quota. Worth cloning that schedule."

6. **Cross-machine sync via a c11 hub.** Right now Keychain is `ThisDeviceOnly` (correctly — never iCloud sync raw secrets). But the *snapshots* (already redacted, just numbers) could be broadcast to a c11 mesh so an operator running on laptop + desktop sees a unified view. Useful when the agent is running in cloud and the operator is on the road.

7. **Footer slot abstraction.** The sidebar footer is becoming a stack of widgets: dev panel, footer buttons, AI usage. Generalize to a `SidebarFooterRegistry` where any subsystem can register a small view. AI usage becomes the first opt-in widget. Other widgets follow (build status, current branch sync, mempool of pending agent broadcasts).

---

## Leverage Points

Where small effort creates outsized future value:

1. **Expose `AIUsagePoller.snapshots` over the socket.** ~50 LOC. Unlocks every agent-coordination idea above.

2. **Extract `OcclusionAwareTimer` from `AIUsagePoller`.** ~80 LOC refactor. Makes every future polling subsystem free of timer/visibility/cancellation boilerplate.

3. **Centralize the egress allowlist.** A single `C11EgressAllowlist` consulted by every outbound URLSession in chrome. Today it's only enforced for status pages; the AI usage fetchers themselves (`claude.ai`, `chatgpt.com`) hardcode the URL but don't check against a registry. Make the registry the source of truth and `privacy-endpoints.md` the rendered output.

4. **Promote `AIUsageAppOwnedError` to `C11AppOwnedError`** and adopt it as the rule for every user-facing error path. Stops raw `URLError` text from ever reaching the UI.

5. **Add a single `Defaults.AIUsage` enum** for the half-dozen UserDefaults keys. Trivial; saves one grep-and-replace exercise per migration.

6. **Generation-tagged-await helper.** `await poller.run(generation: \.taskGeneration) { ... }` — a 30-line utility that any future async/UI binding can use to bail early.

7. **Test fixture for fetcher contract.** A `MockProvider` value with configurable `fetchUsage` outcomes, so future provider PRs come with a 5-minute fetcher test instead of a from-scratch HTTP test harness.

---

## The Flywheel

**The flywheel that exists today, latent:**

1. Operator adds an account → footer renders their quota.
2. Footer renders their quota → operator notices when they're throttled.
3. Operator notices throttling → operator wants the *agents* to also notice.
4. Agents notice via socket → agents self-throttle, route around saturation, broadcast quota state.
5. Agents broadcasting quota state → c11 becomes the operator's air-traffic-controller view.
6. ATC view is more useful than just "pretty numbers" → operator adds more connectors.
7. More connectors → richer ATC view → more reasons for agents to read the connectors.

**To set it spinning, you need step 4** — socket exposure. Once an agent can read its own quota, the loop starts compounding because every new connector becomes a new sense for the swarm. Without it, the feature stalls at "pretty numbers in the corner."

The other flywheel is **community/upstream-friendly:**

1. The provider protocol is small and clean.
2. Keep it small and clean → external contributors can add connectors with one file.
3. Each new connector → more reason for cmux to merge it back upstream.
4. Upstream-friendly improvements → operator base for c11 grows.
5. Larger operator base → more demand for connectors.

This loop only works if you resist the temptation to bake provider-specific code into the central poller. Right now the discipline is good (`fetchUsage`/`fetchStatus` are closures; `AIUsageProvider` knows nothing about Claude or Codex specifically). Keep it that way.

---

## Concrete Suggestions

### High Value (do now)

1. **Extract `OcclusionAwareTimer` from `AIUsagePoller`. ✅ Confirmed**
   `Sources/AIUsage/AIUsagePoller.swift:79-105` — the `DispatchSource.makeTimerSource` + `NSWindow.didChangeOcclusionStateNotification` + `inFlightTask`/`hasPendingTick` machinery is generic. Lift to `Sources/Concurrency/OcclusionAwareTimer.swift`. AIUsagePoller becomes a 70-line subscriber. Pays for itself the next time someone adds a polling subsystem (browser refresh, Lattice sync, build watcher).
   *Compatibility:* No external API changes; pure refactor. Risk: low.

2. **Centralize UserDefaults keys for AI usage in one enum. ✅ Confirmed**
   `Sources/AIUsage/AIUsageColorSettings.swift:16-21`, `Sources/AIUsage/AIUsageAccountStore.swift:10`, `Sources/AIUsage/UI/AIUsageFooterView.swift:48` all define keys as inline strings or `static let` per-class. Add `enum AIUsageDefaultsKeys { static let lowColor = "c11.aiusage.color.low" ... }`, point each call site at the enum. Three files, ~15 lines of churn, eliminates one whole class of "renamed in one place but not another" bugs.

3. **Make `keychainService` a single source of truth from `AIUsageProvider`. ✅ Confirmed**
   `Sources/AIUsage/AIUsageAccountStore.swift:33-36` repeats the format `"com.stage11.c11.aiusage.\(providerId)-accounts"` as a fallback when `AIUsageProvider.keychainService` is the canonical value. Either drop the fallback (provider is required, fail fast if missing) or compute the fallback from `provider.keychainService` only. The current code makes it possible for the registry value and the resolver value to drift.

4. **Promote `AIUsageAppOwnedError` to `C11AppOwnedError`. ✅ Confirmed**
   `Sources/AIUsage/AIUsagePoller.swift:275-277` defines the marker; only AI usage errors adopt it. Move to a top-level `Sources/Errors/C11AppOwnedError.swift` and make it the standard rule for any user-facing async pipeline. This is *the* pattern that prevents OS-level error text from leaking through localization.

5. **Add a `nonisolated` helper for "is the host allowed?" and route every chrome-side `URLSession.data` call through it. ❓ Needs exploration**
   `AIUsageStatusPagePoller.allowedHosts` is the only enforcement point today; the AI fetchers themselves hardcode `claude.ai` and `chatgpt.com` but don't validate. Future-proof: a single `C11EgressAllowlist.contains(_:URL)` that every chrome-originated request consults. This is *strategic* if you keep chrome-only egress; it's *required* if you ever consider extension/connector-loaded egress.

### Strategic (sets up future advantages)

6. **Expose `AIUsagePoller.snapshots` (and incidents) over the c11 socket. ❓ Needs exploration**
   Add `aiusage.snapshot --account <id-or-name>` and `aiusage.incidents --provider <id>` socket commands. Read-only, no auth needed (it's localhost). Per the threading policy in CLAUDE.md, parse args off-main, snapshot the dictionary on main, return. This unlocks every agent-coordination flywheel below. The biggest single move you can make on this branch.
   *Risk:* Need to think about how snapshot-of-`@Published` works without forcing a `DispatchQueue.main.sync`. An `@MainActor`-isolated read scheduled via `Task { @MainActor in ... }` returning a value over the socket should be fine; verify against the no-`main.sync` rule.

7. **Generalize `AIUsageProvider` → `C11Connector` with optional `Usage` and `Status` capability protocols. ❓ Needs exploration**
   Pure naming + protocol-extraction work. AI usage stays the first concrete consumer. Doors open: GitHub PRs, Lattice tickets, build minutes, anything operator-relevant.
   *Risk:* Resist pre-generalizing; only do this once you have a second concrete consumer in flight (otherwise it's speculative scaffolding).

8. **Local time-series persistence (last 24h ring buffer per account). ❓ Needs exploration**
   New file `Sources/AIUsage/AIUsageHistory.swift`, an `actor` that the poller calls `record(snapshot:)` on after each tick. Write to `~/Library/Application Support/c11/aiusage-history/<accountId>.bin` as a fixed-size ring of `(Date, Int, Int)`. Sparklines + extrapolation in the popover. Estimated 250-400 LOC.

9. **`SidebarFooterRegistry` so future widgets compose into the footer cleanly. ⬇️ Lower priority than initially thought**
   The current ad-hoc VStack is fine for now. Revisit when there's a third widget.

### Experimental (worth exploring)

10. **Browser-based credential capture via the embedded WKWebView.** Use `c11-browser` substrate to drive a sign-in flow that hands the cookie back. Removes DevTools onboarding step. Risk: the auth flow is fragile and provider-specific; might be more pain than the onboarding it eliminates.

11. **Quota-aware launcher for clear agents.** Wrap "launch a clear Claude" in a check against `aiusage.snapshot`. If the operator's primary account is over 90%, refuse and suggest Codex (or wait). Lives in the cmux/c11 skill, not in the chrome — the chrome just exposes the data.

12. **Status-page module promoted from "AI usage support code" to "c11 incident feed."** Hosts already allowlisted. Add `status.github.com`, `www.cloudflarestatus.com`, etc. Render below AI usage. One-screen view of "is anything in my stack on fire."

13. **Egress evidence dump for releases.** A small script that scans the codebase for outbound `URL(string:)` literals + `URLSession.data(for:)` call sites, intersects against `docs/privacy-endpoints.md`, and yells if a host appears in code but not in the doc. Cheap, audit-friendly, makes the "privacy-endpoints.md is the contract" claim enforceable rather than aspirational.

14. **Sparkline-on-tab indicator** (when a c11 tab is running an agent on a known provider, paint a thin stripe colored by current utilization). High visual impact, low code cost — but only after the time-series exists.

---

## Summary: What to do tomorrow morning

If I had to pick **one move** to make this branch maximally future-proofing, it's #6: expose snapshots over the c11 socket. Everything else is polish or extension. That single move turns "an opt-in panel in the sidebar" into "a coordination primitive the swarm can read." That's the c11-shaped thing to do here.

If I had to pick **three small refactors** to land alongside the feature: extract `OcclusionAwareTimer` (#1), centralize defaults keys (#2), promote `AIUsageAppOwnedError` (#4). All confirmed feasible, all isolate primitives that are clearly going to be reused.

Everything else can wait for the second connector to arrive — at which point the right abstractions will be obvious because you'll have two concrete consumers instead of one.
