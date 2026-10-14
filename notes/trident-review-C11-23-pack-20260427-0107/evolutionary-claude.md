## Evolutionary Code Review
- **Date:** 2026-04-27T01:07:00Z
- **Model:** Claude / claude-sonnet-4-6
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6ed68713
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory

---

## What's Really Being Built

The stated feature is "AI usage monitoring." That understates it considerably.

What's actually being built is a **local-first agent observability layer** — a substrate that makes the operator:agent pair's economics visible in real time, without credentials, without network calls, without asking permission from any vendor. The design position is worth naming: this system treats the local filesystem as the authoritative telemetry bus. The agent tools write to disk as their native side effect; c11 reads those artifacts and renders intelligence from them.

This is a posture, not just an implementation choice. It says: we don't need vendor APIs to understand what agents are doing. The data is already here. We just need to read it.

The deeper capability unlocked: c11 is now a **runtime cost oracle** for any agent tool whose data lives on disk. That's a position no vendor dashboard can occupy, because vendor dashboards don't know about the other tools running alongside them. Only c11 does.

The secondary capability: the session-window concept (5-hour rolling window with `resetsAt` derived from the oldest live entry) is not Claude-specific reasoning. It's a generalized pattern for "what has this operator spent in the last working unit of time." That pattern will compose.

---

## Emerging Patterns

### Pattern 1: The Credential-Free Provider as First-Class Citizen

`credentialFields: []` is already treated as a first-class discriminant throughout `AIUsageAccountStore`, `AIUsagePoller`, and `add()`/`remove()`/`update()`. This is good. The pattern is: empty credential fields means "local-only, no Keychain, no secret fetch, auto-register on detection."

This should be formalized as a protocol or at least a named concept. Right now it's implicit — `credentialFields.isEmpty` is checked in at least four call sites. A computed property `var isLocalProvider: Bool { credentialFields.isEmpty }` on `AIUsageProvider` would make this intent explicit and reduce the boolean footprint across the codebase.

**Catch this early:** The auto-registration logic in `AIUsageAccountStore.load()` is hardcoded for Claude and Codex by name (lines 177-201). As the third and fourth local providers arrive, this becomes a pattern violation — each new provider will need a dedicated block. The better pattern: providers should declare their own auto-detection predicate as part of `AIUsageProvider`, and `load()` should iterate `AIUsageRegistry.all` calling that predicate for any local provider that lacks an account.

### Pattern 2: The Dual-Window Model is an Emerging Primitive

`AIUsageWindows(session:week:)` is fixed-arity right now — exactly two windows. But the underlying structure (a rolling time window with token count, cost, utilization, and a resetsAt derived from the oldest entry) is generic. The window concept is more fundamental than "session" and "week." It could express:
- "last N hours" (configurable per operator)
- "this calendar month" (billing cycle alignment)
- "this git branch's lifetime" (agent-scoped work unit)
- "since last commit" (developer rhythm)

The struct is Sendable and Equatable — it's already designed for composition. The only thing holding it back from generalization is the fixed `session`/`week` properties on `AIUsageWindows`.

### Pattern 3: The Fetcher-as-Static-Enum Anti-Pattern

Both `ClaudeLocalUsageFetcher` and `CodexLocalUsageFetcher` are `enum` types with only static methods — effectively namespaced functions. This works but forecloses testability and configuration injection without subclassing-style workarounds. A future provider that needs a configurable path (e.g., a Gemini fetcher pointing at a non-default data directory) cannot easily override path logic.

This is a forming anti-pattern. Not a crisis at two providers, but worth catching before five providers exist.

### Pattern 4: Synchronous I/O on Main Actor — Not Yet Painful, Will Become So

Both fetchers perform synchronous I/O (`String(contentsOf:)` in Claude, `sqlite3_step` loop in Codex) in code that runs on the `@MainActor`. The poller calls into these via `async throws` closures, but `async` does not automatically dispatch to a background thread. Currently the data sets are small and reads are fast. As JSONL files accumulate (months of Claude Code usage, large project directories), this will produce perceptible frame drops.

This is the highest near-term runtime risk. See Concrete Suggestions #1.

---

## How This Could Evolve

### Evolution 1: The Provider Registry Becomes Dynamic

Right now `AIUsageRegistry.all` is a hardcoded array literal: `[Providers.claude, Providers.codex]`. This is the simplest thing that works.

The natural evolution: providers register themselves. Each `AIProvider.swift` file calls `AIUsageRegistry.register(self)` at module load time (using a `static let _registered = AIUsageRegistry.register(Providers.claude)` side-effect pattern). `AIUsageRegistry.all` becomes a `[AIUsageProvider]` backed by a thread-safe array.

This makes adding a new provider a one-file operation with no changes to `AIUsageRegistry.swift`. It also opens the door to runtime-loaded providers (plugin architecture), though that's further out.

### Evolution 2: The Session Window Becomes Configurable and Cross-Tool

The 5-hour session window is currently hardcoded as a constant in both fetchers. A configurable session window length (surfaced in Settings as "session length: 3h / 5h / 8h / 1 day") would let operators tune to their own work rhythms.

More interestingly: a **cross-tool aggregate window** — "total tokens/cost across all providers in the last 5 hours" — is a trivially small amount of new code given the existing infrastructure. `AIUsagePoller.snapshots` already contains `AIUsageSnapshot` for every account. A computed property that sums `session.tokensUsed` and `session.costUSD` across all snapshots would produce a real-time "how much am I spending right now across all my agents" number. This is genuinely new information that no vendor dashboard can provide.

### Evolution 3: Model-Level Breakdown

Currently `ClaudeLocalUsageFetcher.Entry` captures model per entry (line 247). The `cost()` function uses model to look up pricing. But the aggregation step throws the model away — entries are summed into a single `tokensUsed` and `costUSD`. The data to break down by model (Opus vs. Sonnet vs. Haiku within a window) already exists. A `modelBreakdown: [String: (tokens: Int, costUSD: Double)]` field on `AIUsageWindow` would let the UI render "you spent 2h 40m of Sonnet and 20 min equivalent of Opus today" — a fundamentally different view of usage.

### Evolution 4: Local Usage as a Socket-Accessible Signal

C11's socket protocol (`C11_SOCKET`) is already the coordination bus for agent telemetry. Exposing `report_usage` as a socket command — `c11 report_usage claude 1200 0.004` — would let agents self-report their token consumption as they work. This is the inverse of the current pull model (c11 reads files after the fact). A push model would enable real-time budget enforcement: an orchestrator pane can query c11 for current session spend before spawning the next expensive task.

---

## Mutations and Wild Ideas

### Mutation 1: Budget Enforcement Gate

Once c11 knows real-time session cost, it can act as a budget enforcer. An operator-configured threshold (say, $5/session) causes c11 to: flash the sidebar, emit a warning to any pane running an agent, optionally block new agent launches. This crosses from monitoring into governance. No vendor can offer this because no vendor sees across all tools.

Implementation sketch: `AIUsagePoller` emits a `budgetExceeded` notification when aggregate cost crosses the threshold. The c11 socket command handler listens and posts to any pane subscribed to budget events. Agents that read the skill learn to poll `c11 budget-status` before starting expensive operations.

### Mutation 2: The "Burn Rate" Display

Instead of (or alongside) cumulative cost, compute tokens/minute for the current session window. A "burn rate" display — "12k tokens/min" — would give the operator a feel for how hot the current workload is running, not just where the counter has landed. This is a one-line computation on the sorted `sessionEntries` array.

### Mutation 3: Project-Scoped Usage Attribution

`ClaudeLocalUsageFetcher.allEntries()` currently reads all JSONL files under `~/.claude/projects/` without tracking which project directory they came from. The project name is encoded in the path (`~/.claude/projects/<project-hash>/`). Capturing the directory path per entry would enable per-project cost attribution — "you spent $2.40 on c11 today and $0.80 on Lattice." This requires storing the path alongside the entry, but the data is already there.

### Mutation 4: Gemini / Kimi / OpenCode Fetchers

The fetcher abstraction is genuinely extensible. Any tool that writes local state is a candidate:
- **Gemini CLI:** writes conversation history to a local path (needs investigation). If it does, a `GeminiLocalUsageFetcher` would follow the exact same JSONL pattern.
- **Kimi CLI:** similar investigation needed.
- **OpenCode:** if it uses SQLite for state (common in Rust/Go CLI tools), a SQLite fetcher would follow the Codex pattern almost verbatim.
- **Aider:** `~/.aider/` contains usage logs. Token counts are in the session JSON.

Each of these is a one-file addition to `Sources/AIUsage/` plus one line in `AIUsageRegistry.all` and one detection block in `load()`. The abstraction is genuinely ready.

### Mutation 5: Historical Trend Persistence

Today's architecture is stateless across launches — each poll re-reads all JSONL/SQLite data and computes windows from scratch. There's no memory of "what did I spend yesterday." A lightweight SQLite database written by c11 (not read from a vendor tool) — `~/.c11/usage_history.sqlite` — could persist hourly snapshots. This enables:
- Weekly trend graphs in the popover
- "You've spent 40% more this week than last week"
- Anomaly detection ("this branch is unusually expensive per commit")

The existing window model maps cleanly to rows in such a database.

---

## Leverage Points

**1. `isLocalProvider` computed property on `AIUsageProvider`** (one line)
Replaces four `credentialFields.isEmpty` call sites with intent. High signal-to-noise for the next engineer reading the code.

**2. Provider auto-detection predicate declared on the provider itself**
Moving the detection logic (`FileManager.default.fileExists(atPath:...)`) from `AIUsageAccountStore.load()` into a closure on `AIUsageProvider` (e.g., `autoDetect: (@Sendable () -> Bool)?`) reduces the blast radius of every new provider addition. Adding a third provider stops requiring a change in `AIUsageAccountStore`.

**3. Dispatching I/O off the main actor**
A single `Task.detached { ... }` or `await withCheckedContinuation` wrapping the `allEntries()` calls in both fetchers would make the entire polling path non-blocking. This makes every future provider free from having to worry about threading — the contract becomes: "implement `fetchUsage`, we handle dispatch."

**4. `AIUsageWindows` gaining a cross-provider aggregate**
One computed property on `AIUsagePoller` — `var aggregateSession: AIUsageWindow` — that sums all snapshots. Zero new model types needed. Enables the "total operator spend" display that's currently missing.

---

## The Flywheel

The flywheel here is: **more tools, more signal, more value, which justifies more tools.**

The current state: two providers (Claude + Codex), both local, both credential-free, both auto-detected. The moment a third tool's data becomes readable locally (Gemini, Kimi, Aider, OpenCode), the aggregate view becomes qualitatively more useful — operators who run mixed workloads get a complete picture for the first time.

Each new provider costs roughly one file (`<Tool>LocalUsageFetcher.swift` ~100-150 lines) plus one line in `AIUsageRegistry.all`. The infrastructure already exists. The cost per provider is low and decreasing (the pattern is now established and testable).

The secondary flywheel: the cross-tool cost aggregate creates pressure toward budget features, which makes the infrastructure load-bearing enough to justify model-level breakdown, project attribution, historical persistence — each of which makes the tool more valuable to the operator and increases the surface area for future features.

The flywheel is real but it needs the auto-detection pattern to be generalized first (Concrete Suggestion #3 below). Otherwise each new provider is a two-file change (fetcher + store), and the `load()` function becomes a maintenance hazard.

---

## Concrete Suggestions

### High Value

**1. Dispatch fetcher I/O off the main actor** ✅ Confirmed

In both fetchers, wrap the synchronous work in a detached task:

```swift
// ClaudeLocalUsageFetcher.fetchUsage
static func fetchUsage(account: AIUsageAccount) async throws -> AIUsageWindows {
    let entries = try await Task.detached(priority: .utility) {
        try allEntries()  // move sync file I/O here
    }.value
    // rest of aggregation runs wherever (it's pure CPU, fast)
    ...
}
```

Same pattern for `CodexLocalUsageFetcher`. `allEntries()` can remain `throws` (non-async) since it's only called from within the detached task.

This is confirmed compatible with the existing architecture — `fetchUsage` is already `async throws` and called via `runWithTimeout` which uses a `ThrowingTaskGroup`. A detached task inside `fetchUsage` composes cleanly with the timeout wrapper.

Risk: low. The detached task inherits no actor context, which is exactly what we want for file I/O.

**2. Add `isLocalProvider` computed property to `AIUsageProvider`** ✅ Confirmed

```swift
// In AIUsageProvider.swift, add to struct AIUsageProvider:
var isLocalProvider: Bool { credentialFields.isEmpty }
```

Replace all `credentialFields.isEmpty` and `credentialFields.isEmpty != true` checks throughout `AIUsageAccountStore`, `AIUsagePoller`, and `add()`/`remove()`/`update()` with `provider.isLocalProvider`. This is a pure refactor — no behavior change, confirmed by inspection of all four call sites.

**3. Add `aggregateSessionCost` computed property to `AIUsagePoller`** ✅ Confirmed

```swift
// In AIUsagePoller.swift, add:
var aggregateSessionCost: Double {
    snapshots.values.reduce(0.0) { $0 + $1.session.costUSD }
}

var aggregateSessionTokens: Int {
    snapshots.values.reduce(0) { $0 + $1.session.tokensUsed }
}
```

These properties are safe to add — `snapshots` is `@Published private(set)` and already observed by the UI. No new state needed. The sidebar footer could display a total line when more than one provider is active. This makes the cross-tool aggregate visible for the first time.

---

### Strategic

**4. Declare `autoDetect` on `AIUsageProvider` and generalize `load()`** ❓ Needs exploration

Move detection logic out of `AIUsageAccountStore.load()` and into each provider:

```swift
// In AIUsageProvider:
let autoDetect: (@Sendable () -> Bool)?

// In ClaudeAIProvider.swift:
static let claude = AIUsageProvider(
    ...
    autoDetect: {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude/projects").path
        )
    }
)

// In AIUsageAccountStore.load():
for provider in AIUsageRegistry.all {
    guard let detect = provider.autoDetect else { continue }
    let hasAccount = accounts.contains { $0.providerId == provider.id }
    if !hasAccount && detect() {
        let auto = AIUsageAccount(providerId: provider.id, displayName: provider.displayName)
        accounts.append(auto)
    }
}
try? persist(accounts)
```

This is the right architectural direction but requires touching `AIUsageProvider` (the core struct), both provider files, and `AIUsageAccountStore`. Needs careful testing of the idempotency guarantee. Worth doing before the third provider arrives — after that, the cost of NOT doing it grows with each addition.

**5. Capture model-level breakdown in `AIUsageWindow`** ❓ Needs exploration

Add `modelBreakdown: [String: (tokens: Int, costUSD: Double)]` to `AIUsageWindow`. The data is available in both fetchers (model per entry). The aggregation in `ClaudeLocalUsageFetcher.fetchUsage` can be extended to populate this dictionary with minimal new code.

The UI implication is larger — the popover or a tooltip would need to render this breakdown. But the model change is straightforward and the UI can be deferred. The value is: pricing data is model-specific and the operator's actual model mix is often surprising. Knowing "80% of my Claude spend is Opus" is actionable.

**6. Fix `gpt-4o-mini` cost matching in `CodexLocalUsageFetcher.cost()`** ✅ Confirmed

```swift
// Current (line 510-516 of CodexLocalUsageFetcher.swift):
if model.hasPrefix("gpt-5.5") || model.hasPrefix("gpt-5") {
    ratePerMillion = 7.0
} else if model.hasPrefix("gpt-4o") {       // <-- matches gpt-4o-mini at gpt-4o rate
    ratePerMillion = 5.0
} else if model.hasPrefix("gpt-4-turbo") {
```

Fix: add a `gpt-4o-mini` check before the `gpt-4o` check:

```swift
} else if model.hasPrefix("gpt-4o-mini") {
    ratePerMillion = 0.60   // blended estimate for mini
} else if model.hasPrefix("gpt-4o") {
    ratePerMillion = 5.0
```

This is a confirmed bug — `gpt-4o-mini` gets `gpt-4o` pricing (5x overestimate). The fix is one line before an existing `hasPrefix` check. No architecture impact.

---

### Experimental

**7. Burn rate display (`tokens/min` for current session)**

Compute `burnRate: Double` as `Double(session.tokensUsed) / (Date().timeIntervalSince(sessionCutoff) / 60.0)` in the fetcher. Display in the footer as "12k tok/min." This would require no model changes — just a new field on `AIUsageWindow` and a display addition in `AIUsageFooterView.bar()`. Value is signal to the operator about workload intensity, not just accumulation. Uncertain whether operators find rate more actionable than cumulative — needs user testing.

**8. `c11 budget-status` socket command returning aggregate cost**

Expose `aggregateSessionCost` via a socket command so agents can query their own budget status before spawning expensive sub-tasks. This would require: a new socket command handler in the c11 socket layer, a delegation path from the socket to `AIUsagePoller.shared`, and a response format. Non-trivial plumbing but the value is genuine — it makes c11 a cost-aware orchestration primitive. This is the beginning of budget governance.

**9. Per-project cost attribution for Claude**

In `ClaudeLocalUsageFetcher.allEntries()`, capture the project directory path (the component between `.claude/projects/` and the `.jsonl` filename). Store it on `Entry`. The aggregation step can group by project path and emit `projectBreakdown: [String: Double]` (project name to cost) as an additional field. The `displayName` for a project could be derived from a `CLAUDE.md` title or the directory basename. This requires persisting a project-name mapping (or reading `CLAUDE.md` files, which is expensive). The path-only version (using directory basename as project identifier) is low-cost and immediately useful.
