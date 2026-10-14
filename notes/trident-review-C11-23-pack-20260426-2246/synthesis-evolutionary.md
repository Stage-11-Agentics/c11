## Evolutionary Synthesis — C11-23 (AI Usage Monitoring)

- **Date:** 2026-04-26
- **Sources:** evolutionary-claude.md, evolutionary-codex.md, evolutionary-gemini.md
- **Branch:** c11-23-ai-usage-monitoring

---

## Executive Summary — Biggest Opportunities

All three reviewers independently arrive at the same headline conclusion: **this branch is not actually shipping a quota meter — it is shipping c11's first telemetry/connector substrate.** The proof-of-concept happens to be Claude/Codex usage, but the load-bearing primitives are the provider protocol, the Keychain abstraction, the egress allowlist, the redaction pattern, and the occlusion-aware poller. Get the seams right and c11 has a clean spine for every future operator-telemetry feature.

The single highest-leverage move, named explicitly by all three models: **expose `AIUsagePoller.snapshots` (and incidents) over the c11 socket.** That move alone converts a sidebar widget into a coordination primitive for the operator:agent pair — which is exactly what the CLAUDE.md mission statement says c11 is for. Without it, the feature stalls at "pretty numbers in the corner." With it, the flywheel of budget-aware agents, quota-aware launching, and circuit-breaking begins to compound.

The second-biggest opportunity is a **derived availability/pressure model** (`AIUsageAvailability`) sitting above raw snapshots+incidents — a single normalized verdict ("available", "high pressure", "exhausted", "auth expired", "status degraded", "stale") that views, socket commands, agent skills, and future launch logic all consume instead of each re-deriving it.

Everything else is polish, hardening, or extension that should follow these two moves.

---

## 1. Consensus Direction — Where All Three Models Converge

1. **This branch is a substrate, not a feature.** Claude, Codex, and Gemini all explicitly reframe the work: it's the *connector substrate* (Claude), the *quota control plane* (Codex), and the *localized telemetry sidecar* (Gemini). Same architecture, three names. The provider protocol, Keychain abstraction, allowlisted egress, redaction pattern, and occlusion-aware poller are the real product.

2. **Expose poller state over the c11 socket.** Unanimous and emphatic. Claude calls it "the highest-leverage move in the whole branch." Codex flags it as `AIUsageAvailability` over a socket command. Gemini frames it as "Autonomous Resilience" via `c11 provider-status` or `provider.status_changed` events. Read-only, localhost-only, aggregate-or-redacted to start. This is the move that turns operator awareness into agent awareness.

3. **Generalize the provider protocol toward "connectors."** Claude proposes `C11Connector` with optional `UsageProducingConnector` / `StatusProducingConnector` capability protocols. Codex proposes a three-layer split (Manifest / Telemetry / Operator Surface) with explicit endpoint metadata on the manifest. Gemini calls it the "Pluggable Provider Model" and notes the abstraction can extend to model capabilities, token limits, and routing preferences. Same destination: provider-as-value with a small, declarative manifest.

4. **Extract the occlusion-aware poller as a reusable primitive.** All three models flag the timer + `NSWindow.didChangeOcclusionStateNotification` + generation-tagged-cancellation machinery as a generic primitive. Claude names it `OcclusionAwareTimer`; Gemini names it `OcclusionAwareScheduler`; Codex notes the same lifecycle concentration as the next refactor target. Lifting it pays back on the next polling subsystem (browser refresh, Lattice sync, build watcher, notifications).

5. **Surface reset-window times in the UI.** The model already records reset timestamps; fetchers parse them; `AIUsageResetLabel` exists. The footer just doesn't render them. Codex names it directly; Claude implies it via the time-series/extrapolation idea; Gemini implies it via the "Budget-Aware Agent" wild idea. Cheap to land, immediate operator value, turns a static meter into a planning aid.

6. **The egress allowlist is c11's first formal privacy contract.** Claude calls it "architecturally load-bearing." Codex flags that the contract is currently distributed (URLs in fetchers, hosts in status poller, prose in docs) and must converge before more providers land. Gemini implies the same via the "circuit breaker" mutation. The fix: a single source of truth (`C11EgressAllowlist`) that every chrome-side outbound `URLSession` call routes through, with `docs/privacy-endpoints.md` as a generated/validated artifact rather than hand-maintained prose.

7. **Promote `AIUsageAppOwnedError` to a c11-wide pattern.** Claude and Gemini both call this out as the unsung hero of the diff — the marker protocol that prevents `URLError`'s "The Internet connection appears to be offline" from leaking into product UI. Move to `Sources/Errors/C11AppOwnedError.swift` and adopt as the rule for every user-facing async pipeline.

8. **The flywheel is "agent self-awareness via socket."** All three models articulate the same loop: more providers → richer signal → operator trusts c11 to plan agent work → agents read the signal → agents self-throttle, route around saturation, broadcast quota state → c11 becomes the operator's air-traffic-control view → operator adds more connectors. The first turn requires socket exposure. Without it, the loop never starts.

---

## 2. Best Concrete Suggestions — Most Actionable Across All Three

### 2A. Land Now (low cost, high consensus, confirmed feasible)

1. **Extract `OcclusionAwareTimer` (or `OcclusionAwareScheduler`) from `AIUsagePoller`.** ~80 LOC refactor. `Sources/AIUsage/AIUsagePoller.swift:79-105` is the lift target. AIUsagePoller becomes a 70-line subscriber. Pure refactor, no API surface change, immediate reuse value.

2. **Centralize UserDefaults keys in an `AIUsageDefaultsKeys` enum.** Three files (`AIUsageColorSettings.swift:16-21`, `AIUsageAccountStore.swift:10`, `UI/AIUsageFooterView.swift:48`) currently inline the same string-keyed constants. ~15 lines of churn, eliminates a whole class of rename-drift bugs.

3. **Make `keychainService` a single source of truth.** Today the literal `"com.stage11.c11.aiusage.<id>-accounts"` appears in the provider value, the resolver fallback, and the registry tests. Drop the resolver fallback or compute it strictly from `provider.keychainService`. Three-source-of-truth → one.

4. **Promote `AIUsageAppOwnedError` to `C11AppOwnedError`.** Move marker protocol to `Sources/Errors/`. Adopt as the rule for every user-facing async pipeline so OS-level error text never leaks through localization.

5. **Render reset windows in the sidebar bar.** `providerUsageResetLabel` already exists; the bar currently stops at percent text (`UI/AIUsageFooterView.swift:150`). Wire it. Localized relative time, minute-level refresh (no per-second timers in the sidebar). Low cost, high operator value.

6. **Replace sleep-based poller lifecycle tests with the existing `tickBody` seam.** `c11Tests/AIUsageTests.swift:476/481` sleeps for 50 ms twice; the poller already exposes a constructor seam (`AIUsagePoller.swift:35`). Wait on an XCTest expectation signaled by `tickBody` instead. Removes a small but real flake source.

### 2B. Strategic — Sets Up Future Advantages

7. **Expose `AIUsagePoller.snapshots` and `incidents` over the c11 socket.** Unanimous top recommendation. Add read-only `aiusage.snapshot` and `aiusage.incidents` (or `provider-status` / `provider.status_changed`). Per the threading policy, parse args off-main, snapshot the dictionary on main, return — no `DispatchQueue.main.sync`. Default to aggregate or redacted account labels on first cut; the privacy surface is larger than the UI's. **This is the single move that unlocks every other agent-coordination idea.**

8. **Introduce a normalized `AIUsageAvailability` (or `AIUsagePressure`) layer.** A pure, testable model that derives `available | pressureHigh | exhausted | authExpired | statusDegraded | stale` from snapshots + fetch errors + incidents + freshness. Footer, settings summaries, socket commands, and future launch guidance all consume it instead of each inventing slightly different interpretations.

9. **Promote `AIUsageProvider` → `C11Connector` with capability protocols.** Pure naming + protocol-extraction work. AI usage stays the first concrete consumer. Doors open: GitHub PRs, Lattice tickets, Cloudflare incidents, build minutes, anything operator-relevant. Caveat (Codex + Claude both flag): resist pre-generalizing until a second concrete consumer is in flight, or you're building speculative scaffolding.

10. **Centralize the egress allowlist into `C11EgressAllowlist`.** Make it the source of truth that every chrome-originated `URLSession.data` call consults. Generate or validate `docs/privacy-endpoints.md` from it. Add a release-time script that scans for stray `URL(string:)` literals and fails if any host is missing from the registry. Turns a prose contract into an enforceable one.

11. **Refactor the poller into fanout-collect + main-actor publication.** Today `runTick` loops accounts and providers serially on the main actor. Codex names this explicitly: snapshot inputs on main → load secrets off-main → fan out fetches in a `TaskGroup` → return value-typed results → publish once on main if generation still matches. Scales with account count, keeps generation-cancellation as strict as today.

12. **Extract AI-usage settings coordination out of `c11App.swift`.** Current implementation spreads state, sheet, removal-confirm, section placement, and reset-all linkage across `c11App.swift:4430 / 4974 / 4981 / 6050 / 6417`. An `AIUsageSettingsCoordinator` view-model contains it. Each future provider control then has a clear mount point instead of growing the app root.

13. **Add fixture-driven parser tests before adding more providers.** Per-provider JSON fixtures through an injectable transport or parser seam. Behavioral, not source-text. Lets the next provider PR come with a 5-minute test instead of a from-scratch HTTP harness.

14. **Build a `MockProvider` value with configurable `fetchUsage` outcomes.** Turns "add a provider" into a known shape with a known test pattern.

---

## 3. Wildest Mutations — Creative / Ambitious Ideas Worth Exploring

1. **Self-throttling, budget-aware agents.** With socket access to live utilization, an agent's launcher (or the agent itself) refuses to spawn a new clear-Claude when the operator's primary account is over a threshold. The skill teaches the rule; the connector enforces it. A budget-aware swarm. (Claude + Gemini)

2. **Quota-aware model routing.** `cc` (or whatever launches the agent) reads the connector and picks Claude vs. Codex based on which has more quota right now. Operator-side load balancing without operator involvement. Cross-provider routing across multiple accounts of the same provider extends naturally. (Claude + Gemini)

3. **c11 as a circuit breaker.** When `AIUsageStatusPagePoller` detects an active outage, c11 fails fast on agent requests to that provider — preventing wasted retry loops during known outages. Could ship as a soft mode (warning sidebar pill + skill instruction) before any networking integration. (Gemini)

4. **The "provider traffic light" as workspace chrome.** Tiny per-pane indicator at workspace level rather than buried in a footer section. The operator running 30 agents doesn't want exact percentages — they want "can I safely start another expensive loop right now." Per-pane stripe colored by current utilization once the time-series exists. (Codex + Claude)

5. **Quota-aware workspace blueprints.** Workspace templates declare desired provider budgets ("needs Codex < 80% session", "prefer Claude if OpenAI status is degraded"). This branch creates the first local signal needed for that. (Codex)

6. **Privacy ledger generated from code.** Provider manifests generate `docs/privacy-endpoints.md`, a runtime privacy view in Settings, and endpoint assertions in tests from one source of truth. Documentation stops being prose and becomes a checked artifact. (Codex)

7. **Browser-based credential capture via the embedded WKWebView.** The current Claude flow is a four-step DevTools spelunk. The c11-browser substrate is right there. "Sign in to Claude" button → embedded browser → JS bridge hands cookie + orgId back to the editor sheet. Same shape for `~/.codex/auth.json` (read-only import with explicit consent only). (Claude + Codex)

8. **Local time-series ring buffer per account (last 24h, ~1440 samples).** Sparkline next to each bar, "will I run out before reset?" extrapolation, cross-account budgeting suggestions ("Personal Claude is at 95%, Work is at 30% — swap?"), agent-readable consumption curve over the socket. ~250-400 LOC. (Claude + Codex)

9. **"What's my cheapest hour?" weekly digest.** With time-series, c11 knows when the operator has been most productive on the cheapest quota and can suggest schedule patterns. (Claude)

10. **Cross-machine sync via a c11 mesh.** Keychain stays `ThisDeviceOnly` (correctly). But the *snapshots* (already redacted, just numbers + reset times) could broadcast to a c11 mesh so an operator on laptop + desktop sees a unified view. Especially useful when an agent runs in cloud and the operator is on the road. (Claude)

11. **Connector marketplace shape.** A `connector.json` (id, display, fields, fetch URL template, JSONPath expressions for utilization/resetsAt, allowlisted hosts) plus a generic interpreter could let users add a connector for any statuspage-like service without recompiling. Risky — interpreter complexity and security surface — but it's where the architecture is naturally pointing. (Claude)

12. **Status-page module promoted to "c11 incident feed."** Hosts already allowlisted; parser is generic statuspage.io JSON. Add `status.github.com`, `www.cloudflarestatus.com`, status pages for any service Stage 11 touches. One-screen view of "is anything in my stack on fire?" (Claude)

13. **`SidebarFooterRegistry`.** The footer is becoming a stack of widgets (dev panel, footer buttons, AI usage). Generalize to a registry where any subsystem registers a small view. Build status, current branch sync, mempool of pending agent broadcasts all become widgets. (Claude — but flagged "lower priority than initially thought" until a third widget exists.)

---

## 4. Leverage Points and Flywheel Opportunities

### 4A. Highest-Leverage Single Moves

1. **Socket exposure of poller state** — the move that starts the whole flywheel. ~50 LOC. Without it the feature is a UI panel; with it, it's a coordination primitive.

2. **`AIUsageAvailability` derived layer** — one normalized verdict that views, socket commands, and agent skills consume. Stops every consumer from inventing its own interpretation of "96% session + minor incident + stale status."

3. **`OcclusionAwareTimer` extraction** — pays back on every future polling subsystem (browser refresh, Lattice sync, build watcher).

4. **Centralized egress allowlist + generated privacy doc** — turns the privacy contract from prose into a checked artifact. Required before more chrome-side network call sites land.

5. **`C11AppOwnedError`** — stops OS-level error text from ever reaching the UI. Adopt as standard rule for every user-facing async pipeline.

6. **Generation-tagged-await helper** — 30-line utility, every future async/UI binding can use it to bail early when generation has changed.

7. **`MockProvider` test fixture** — turns "add a provider" into a 5-minute test pattern instead of a from-scratch harness.

### 4B. The Flywheels (Two of Them)

**Flywheel 1 — Autonomous Resilience / Coordination (the operator:agent flywheel):**
1. Operator adds an account → footer renders quota.
2. Footer renders quota → operator notices throttling.
3. Operator wants the agents to also notice.
4. **Socket exposure ← the trigger turn. Without this step the loop never spins.**
5. Agents read socket → self-throttle, route around saturation, broadcast quota state.
6. Agents broadcasting quota state → c11 becomes the operator's air-traffic-control view.
7. ATC view is more useful than pretty numbers → operator adds more connectors.
8. More connectors → richer ATC view → more reasons for agents to read the connectors.
9. Goto step 5.

**Flywheel 2 — Open-Source / Upstream-Friendly:**
1. The provider protocol stays small and clean.
2. External contributors can add a connector with one file (~100 LOC, like the existing two).
3. Each new connector → more reason for cmux to merge it back upstream.
4. Upstream-friendly improvements → operator base for c11 grows.
5. Larger operator base → more demand for connectors.
6. Goto step 2.
   *Discipline required:* never bake provider-specific code into the central poller. The current discipline is good (`fetchUsage` / `fetchStatus` are closures; `AIUsageProvider` knows nothing Claude- or Codex-specific). Keep it that way.

### 4C. What to Do Tomorrow Morning

If forced to pick one move: **expose snapshots over the c11 socket.** Everything else is polish or extension. That single move turns "an opt-in panel in the sidebar" into "a coordination primitive the swarm can read." That's the c11-shaped thing to do here.

If forced to pick three small refactors to land alongside the feature: **extract `OcclusionAwareTimer`, centralize the defaults keys, promote `AIUsageAppOwnedError`.** All three are confirmed feasible by independent reads, all three isolate primitives that are clearly going to be reused, all three are pure mechanical lifts with no API-surface risk.

The strategic moves (`AIUsageAvailability`, `C11Connector` rename, fanout-collect refactor, settings coordinator extraction, generated privacy ledger) should follow as soon as the second concrete connector is in flight — at which point the right abstractions will be obvious because there will be two consumers instead of one.

The wildest mutations (budget-aware agents, circuit breakers, quota-aware routing, connector marketplace) all gate on one prerequisite: socket exposure. Land that, and they all become incremental rather than speculative.

---

## Closing

Three independent reviewers, three different model families, near-perfect agreement: the feature is good; the substrate underneath the feature is the actual prize; the single highest-leverage move is to expose that substrate to agents over the socket. Land the small refactors that isolate the reusable primitives, then turn on the socket bridge, and C11-23 stops being "AI usage in the sidebar" and starts being the spine of c11's operator-telemetry layer.
