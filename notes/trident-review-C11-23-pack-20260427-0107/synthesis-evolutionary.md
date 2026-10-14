## Evolutionary Synthesis — C11-23 AI Usage Monitoring
- **Date:** 2026-04-27
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6ed68713
- **Sources:** evolutionary-claude.md (Claude/Sonnet), evolutionary-codex.md (Codex/GPT-5), evolutionary-gemini.md (Gemini)
- **Review Type:** Synthesis

---

## Executive Summary: The Three Biggest Opportunities

**1. This is not a monitoring feature — it is an agent observability primitive.**
All three models converged on a single framing: the stated feature ("AI usage monitoring") dramatically understates what's being built. The local-first, credential-free, multi-tool telemetry substrate is a capability no vendor dashboard can replicate — because vendor dashboards don't see across all tools. C11 is uniquely positioned to be the single place that does. The strategic opportunity is to recognize this early and architect toward it, not retrofit later.

**2. The flywheel is real but requires one structural investment to spin.**
More local readers produce a better aggregate truth, which produces stronger operator decisions, which creates more demand for providers. But the flywheel only spins if adding a provider gets cheaper. Right now it costs two files plus changes to `AIUsageRegistry.all` and `AIUsageAccountStore.load()`. Closing that to one file (by moving auto-detection predicates onto the provider itself) is the investment that makes every future provider free.

**3. Synchronous I/O on the main actor is the highest near-term runtime risk.**
All three models flagged this independently as confirmed, high-value, and actionable now. As JSONL files accumulate and more providers are added, this will produce perceptible frame drops. The fix is mechanical and non-architectural. It should land before the third provider is wired in.

---

## 1. Consensus Direction

All three models agreed on these evolutionary paths without prompting:

1. **Rename the real capability.** "AI usage monitoring" is the smallest possible description. The correct name is "local-first agent observability" or "cross-tool agent telemetry." This is not cosmetic — naming it correctly shapes what gets built next.

2. **Fix blocking I/O on the main actor (highest confidence, confirmed by all three).** Both fetchers perform synchronous I/O inside `async` functions called from a `@MainActor` context. Wrap the I/O in `Task.detached(priority: .utility)` in both `ClaudeLocalUsageFetcher.fetchUsage` and `CodexLocalUsageFetcher.fetchUsage`. Make this the adapter contract: all future readers must execute off-main.

3. **Formalize `isLocalProvider` as an explicit capability, not an inferred one.** The `credentialFields.isEmpty` check appears in at least four call sites. All three models independently identified this as an unnamed capability system trying to exist. Add `var isLocalProvider: Bool { credentialFields.isEmpty }` to `AIUsageProvider` and replace all call sites.

4. **Move auto-detection predicates onto the provider, not the store.** The hardcoded detection blocks in `AIUsageAccountStore.load()` (lines 177-201) will become a maintenance hazard as provider count grows. Each provider should declare its own `autoDetect: (@Sendable () -> Bool)?` closure. `load()` iterates `AIUsageRegistry.all` calling that closure. Adding a new provider stops requiring a change in the store.

5. **Add a cross-provider aggregate window.** `AIUsagePoller.snapshots` already has every account. A computed `aggregateSessionCostUSD`, `aggregateSessionTokens`, and `aggregateWeekCostUSD` on the poller requires no new model types. This is the first "total operator spend across all agents" number that no vendor can produce. All three models treated this as high-value and low-effort.

6. **Extract a normalized `AIUsageEvent` and shared `AIUsageWindowAggregator`.** The window aggregation logic (cutoff computation, filter, sum, reset derivation) is duplicated between Claude and Codex fetchers. Claude and Codex converged on the same extraction: providers produce normalized events, shared code builds windows. This is the seam that turns new providers into data-source plugins rather than full re-implementations.

---

## 2. Best Concrete Suggestions

Ranked by confidence and near-term value:

1. **Dispatch fetcher I/O off the main actor** (all three, confirmed).
   In both fetchers, wrap synchronous work in `Task.detached(priority: .utility) { ... }.value`. `fetchUsage` is already `async throws`; the detached task composes cleanly with the existing `runWithTimeout` wrapper. Make this the explicit adapter contract for all future readers. Risk: low.

2. **Add `isLocalProvider` computed property to `AIUsageProvider`** (all three, confirmed).
   One line: `var isLocalProvider: Bool { credentialFields.isEmpty }`. Replace all `credentialFields.isEmpty` checks across `AIUsageAccountStore`, `AIUsagePoller`, and `AIUsageEditorSheet`. Pure refactor, no behavior change.

3. **Add aggregate computed properties to `AIUsagePoller`** (all three, confirmed).
   ```swift
   var aggregateSessionCostUSD: Double { snapshots.values.reduce(0.0) { $0 + $1.session.costUSD } }
   var aggregateSessionTokens: Int { snapshots.values.reduce(0) { $0 + $1.session.tokensUsed } }
   var aggregateWeekCostUSD: Double { snapshots.values.reduce(0.0) { $0 + $1.week.costUSD } }
   ```
   Enables a total row in the footer when multiple providers are active. Do not aggregate utilization percentages — they share no common denominator unless an explicit total budget exists.

4. **Fix `gpt-4o-mini` cost matching in `CodexLocalUsageFetcher.cost()`** (Claude, confirmed, specific line).
   The current `hasPrefix("gpt-4o")` check matches `gpt-4o-mini` at the `gpt-4o` rate — a 5x overestimate. Add `gpt-4o-mini` check before the `gpt-4o` check. One-line fix, no architecture impact.

5. **Move auto-detection predicates onto providers** (Claude + Codex, strategic).
   Add `autoDetect: (@Sendable () -> Bool)?` to `AIUsageProvider`. Migrate the Claude and Codex detection blocks from `AIUsageAccountStore.load()` into provider declarations. Generalize `load()` to iterate `AIUsageRegistry.all`. Touch points: `AIUsageProvider.swift`, both provider files, `AIUsageAccountStore`. Do before the third provider arrives; cost of not doing this grows with each addition.

6. **Extract `AIUsageEvent` plus shared `AIUsageWindowAggregator`** (Codex, strategic, detailed spec).
   Normalized event type with: timestamp, providerId, model, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, estimatedCostUSD, sourceHint. Move duplicated cutoff/filter/sum/reset logic from both fetchers into a shared aggregator. Keep provider-specific cost functions near the provider at first — avoid prematurely designing a universal pricing engine.

7. **Fix stale documentation** (Gemini, confirmed, trivial).
   Remove the troubleshooting section in `docs/ai-usage-monitoring.md` that references HTTP 401/403/404 error codes. These are artifacts of the old remote API approach and are no longer relevant for local-only providers.

8. **Separate pricing into a catalog with accuracy provenance** (Codex, strategic).
   Claude pricing lives in branches; Codex uses blended family rates. Extract into `AIUsagePricingCatalog` that returns cost plus accuracy metadata: `exact`, `blended`, `estimate`, `unknown`. The UI can then say "estimated" only when warranted. Prevents future fetchers from scattering pricing tables. Keep catalog static — no network price fetching until there is a clear update workflow.

9. **Make local fetchers fixture-driven** (Codex, strategic).
   Both fetchers hardcode `NSHomeDirectory()`, blocking clean tests. Introduce instance readers with injected roots, db URLs, and clocks. Add CI tests covering malformed rows, timestamp units, cost propagation, and window cutoffs through executable paths.

---

## 3. Wildest Mutations

Ambitious ideas worth tracking — none require immediate action:

1. **Budget Governor.** Once c11 has a real-time aggregate session cost, it can act as a budget enforcer. Operator-configured soft and hard thresholds per workspace/session. When aggregate cost crosses the soft threshold: flash sidebar, emit warning to agent panes, write metadata. At hard threshold: block new agent launches. Implementation: `AIUsagePoller` emits a `budgetExceeded` notification; c11 socket handler posts to subscribed panes; agents that read the skill learn to poll `c11 budget-status` before expensive operations. No vendor can offer this because no vendor sees across all tools.

2. **Burn Rate Display.** Alongside cumulative cost, compute tokens/minute (and dollars/hour) for the current session window. The sorted entries already provide the time structure needed. A "12k tok/min" display gives the operator a feel for workload intensity — how hot it's running, not just where the counter has landed. One additional field on `AIUsageWindow`, one display addition in `AIUsageFooterView`.

3. **Per-Project Cost Attribution.** `ClaudeLocalUsageFetcher.allEntries()` traverses `~/.claude/projects/<hash>/`. The project path is already visible at the point of file enumeration; it's simply not retained. Capturing a sanitized path hint on each entry enables "you spent $2.40 on c11 today and $0.80 on Lattice." Codex threads may have title/path/session columns in `state_5.sqlite` — worth inspecting. Path-only version using directory basename as project identifier is low-cost and immediately useful.

4. **Pane-Scoped Economics.** If agents self-report via c11 socket metadata, usage can be attributed to a surface, not just a provider. The operator could see which running pane is expensive right now — crossing from aggregate monitoring into per-agent runtime visibility. Requires a push model (agents report) alongside the existing pull model (c11 reads files).

5. **Historical Trend Persistence.** C11 writes a lightweight `~/.c11/usage_history.sqlite` — not read from a vendor tool, but owned by c11. Hourly snapshots enable weekly trend graphs, "40% more spend this week than last," and anomaly detection ("this branch is unusually expensive per commit"). Codex flags this as lower priority until normalized events and reader tests exist; the schema should not be fossilized before the event model is stable.

6. **Socket-Accessible Usage Signal.** Expose `c11 usage snapshot --json` as a read-only socket command returning aggregate session cost and tokens. Agents could check current burn before spawning expensive sub-tasks. Later, a write command could let tools without local logs self-report usage events (push model). Threading policy: parse off-main, minimal UI/model work on main actor.

7. **Cross-Tool Event Correlation (Gemini's furthest reach).** The system currently shows parallel usage streams. The next leap is detecting causal chains: "high-token Codex response immediately followed by a Claude prompt containing similar tokens." Requires more sophisticated event timestamping and correlation across providers. Provides unparalleled workflow insights. Very experimental — needs a stable event model first.

8. **Local LLM as a Provider (Gemini).** Add a provider for Ollama or similar local inference. The "cost" metric mutates to represent local resources: GPU/CPU seconds, memory, or energy (Joules). Shifts the cost concept from monetary to resource-based. Philosophically interesting; demonstrates the abstraction is not inherently about dollars.

9. **Generalize to a Full Local Telemetry Plane (Gemini, most ambitious).** Rename the module from `AIUsage` to `LocalTelemetry` or `DashboardKit`. Make `TelemetrySnapshot` use a generic `[String: Double]` dictionary for metrics. Add non-AI providers: Git commit frequency, Xcode build times, Figma design statistics. A unified timeline interleaving AI tokens, git commits, and build events would create a personal activity log for the operator's entire workflow. Most ambitious — but the Provider/Fetcher abstraction is already extensible enough to support this without a rewrite.

---

## 4. Leverage Points and Flywheel Opportunities

### Highest-Leverage Single Changes

1. **`isLocalProvider` computed property on `AIUsageProvider`.** One line that replaces four call sites. High signal-to-noise ratio for every future engineer and agent reading the code. The smallest change with the clearest improvement to intent.

2. **`autoDetect` closure on the provider.** The single change that makes `AIUsageRegistry.all` self-managing and reduces adding a new provider from "touch three files including the store" to "touch one file." This is the load-bearing prerequisite for the flywheel.

3. **`Task.detached` wrapping I/O in both fetchers.** Protects frame rate as data accumulates. Makes the adapter contract explicit. Costs nothing to implement; the architecture already supports it.

4. **Aggregate projections on `AIUsagePoller`.** Three computed properties, no new types, no new state. Produces the first "total operator spend" number that no vendor dashboard can offer. This is the value statement for the whole feature, made real with three `reduce` calls.

### The Flywheel

The flywheel is: **more local readers -> better aggregate truth -> stronger operator decisions -> more demand for providers.**

Claude and Codex prove the loop. The third provider (Gemini CLI, Kimi, Aider, OpenCode) makes the aggregate view qualitatively better. The fourth makes vendor dashboards feel incomplete. Once budget and burn-rate signals exist, agents have a reason to consume the same data via socket, which justifies the socket/CLI exposure. Usage monitoring becomes part of orchestration, not just display.

The flywheel requires the auto-detection pattern to be generalized first. Without it, each new provider is a multi-file change and `AIUsageAccountStore.load()` becomes a maintenance hazard. With it, each new provider costs one file (~100-150 lines) plus one line in `AIUsageRegistry.all`. The pattern is established and testable. The per-provider cost is low and decreasing.

### The Position Worth Protecting

C11 is the only process that sees across all agent tools running on the operator's machine. No vendor can occupy this position. Vendor dashboards see one tool; c11 sees the room. That is the durable competitive moat — not the UI, not the pricing tables, not the specific providers. Every architectural decision should be evaluated against the question: "does this make the cross-tool aggregate view stronger or weaker?"
