## Evolutionary Code Review
- **Date:** 2026-04-26T23:42:00Z
- **Model:** Claude claude-sonnet-4-6
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** e7987ee9276344d36e41f12478164929aded792c
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory

---

## What's Really Being Built

The stated feature is "AI usage monitoring" -- a few progress bars and provider status indicators in the sidebar. That description undersells what's actually here.

What's really being built is a **first-class agent observability substrate**. The AIUsage module is a credential store + polling engine + provider abstraction that can attach to any external system and project a live health signal into c11's sidebar. The provider contract (`AIUsageProvider` struct with `fetchUsage`, `fetchStatus`, `credentialFields`, and keychain service) is general enough that almost nothing about it is Claude/Codex-specific. Strip the provider names and this is: "a pluggable poller that fetches structured health data from credentialed external APIs and surfaces it in a persistent, collapsible sidebar widget."

c11 is the command center for agents. The operator running thirty agents needs to know not just that the agents are running, but that the AI services they depend on are healthy, not rate-limited, not experiencing incidents. This module builds the infrastructure for that. The progress bars are the demo; the substrate is the point.

**The unnamed capability:** Real-time AI infrastructure health visible in the operator's peripheral vision while agents work -- without leaving c11.

---

## Emerging Patterns

### Pattern 1: The Provider Protocol as a Codebase Primitive

`AIUsageProvider` is a value-type plugin protocol disguised as a struct. It has no class identity -- it's declared by filling in closures. New providers slot in by adding an `extension Providers` file and appending to `AIUsageRegistry.all`. The barrier to adding the third provider (Gemini, GPT-5 Pro, a local Ollama endpoint) is very low -- one file, no subclassing, no framework registration.

This pattern should be **formalized and documented** as the c11 "provider" pattern. Right now it's implicit. Named, it becomes reusable.

### Pattern 2: Credential Field Metadata

`AIUsageCredentialField` carries not just the data shape (id, label, placeholder, secret flag) but also the validation logic as a closure and a help text string. The editor sheet then renders the full form generically from this metadata alone. This is a **data-driven form** pattern -- the field description contains everything needed to render, validate, and persist the field.

The pattern works well here. Its evolutionary implication: you could describe any settings UI as a set of `C11CredentialField` (or `C11SettingsField`) descriptors and get the form for free. This is the path toward a plugin ecosystem where external agents can register settings panes without touching SwiftUI.

### Pattern 3: C11AppOwnedError

Promoting `AIUsageAppOwnedError` to `C11AppOwnedError` was the right call. The pattern -- a marker protocol that distinguishes "our error, surface as-is" from "OS error, show a generic message" -- is general and should become a first-class documentation entry. Any future error surfaced to users should be evaluated against this protocol. Right now the pattern is partially applied: `AIUsageStoreError`, `ClaudeAIUsageFetchError`, `CodexAIUsageFetchError`, and `AIUsageFetchTimeoutError` all conform; future modules should know to do the same.

**Anti-pattern forming:** The check in `AIUsagePoller.localizedFetchErrorMessage(_:)` has three guard cases before falling back to generic (checks for `AIUsageStoreError` specifically, then `AIUsageFetchTimeoutError` specifically, then `C11AppOwnedError` generically). The specific cases are redundant -- both of those types already conform to `C11AppOwnedError`. This will need cleanup before a fourth provider error type lands.

### Pattern 4: Test Seam via tickBody

`AIUsagePoller`'s `tickBody: (@MainActor (Bool) async -> Void)?` injection is a clean way to make the poller testable without a full provider stack. Worth naming explicitly: this is the "behavior seam" pattern -- inject the core behavior, not just the dependencies. The test suite uses it well. Future pollers (if c11 adds other polling subsystems) should adopt the same shape.

---

## How This Could Evolve

### Evolution 1: From "AI Usage" to "Agent Health Board"

The most direct evolution: the AIUsage module becomes a generic `C11ServiceMonitor` substrate. Today it monitors two AI providers. In six months, it could monitor:
- Local agent process health (CPU, memory, task queue depth)
- Lattice board connectivity and task counts
- Custom REST endpoints the operator wants to watch (CI status, deploy pipeline, database connection count)

The architecture already supports this -- `AIUsageProvider` is nearly a general health source contract. The remaining coupling is in naming (`AIUsage*`, `aiusage.*` localization keys) and in the two hardcoded window types (session/week). Generalizing the window model to `[AIUsageWindow]` or a `[String: AIUsageWindow]` keyed by label would decouple the display from the Claude-specific 5h/7d framing.

**The generalized primitive looks like:**
```swift
struct C11ServiceHealth {
    let metrics: [String: C11HealthMetric]  // replaces AIUsageWindows
    let incidents: [C11HealthIncident]      // replaces AIUsageIncident
}

struct C11HealthMetric {
    let label: String
    let utilization: Int          // 0-100
    let resetsAt: Date?
    let windowSeconds: TimeInterval
}
```

### Evolution 2: Push Threshold Alerting

Right now the sidebar bars are passive. An operator running agents at 90% Claude usage won't notice unless they look at the sidebar. The next logical step: `AIUsagePoller` emits threshold events that can be wired to a notification or a sidebar "alert flash."

The state machine already exists implicitly -- the color thresholds in `AIUsageColorSettings` define warning and danger zones. Making those thresholds trigger an explicit published event (`@Published var thresholdBreaches: [UUID: Int]`) is a small delta. That event can then drive:
- A menu bar badge count
- A banner in the sidebar footer header row
- A c11 socket command that agents can subscribe to (e.g., `c11 aiusage watch --threshold 90 --provider claude` blocks until breached)

### Evolution 3: Socket API for Agent Access

c11's value proposition is that surfaces are scriptable from outside the process. The AIUsage module currently has no socket exposure -- it's UI-only. Adding a handful of socket commands would let agents query their own provider health without leaving their current task:

```
c11 aiusage status          # → JSON: {provider, utilization_session, utilization_week, incidents}
c11 aiusage wait --below 80 # → blocks until utilization drops, useful before spawning heavy tasks
```

This closes a loop: the operator sees agent health in the sidebar, but the agents themselves also have visibility into their service state. An agent that knows it's at 95% session usage can choose to yield, reschedule, or warn the operator proactively.

### Evolution 4: Multi-Account Credential Rotation Workflow

`AIUsageAccountStore` supports multiple accounts per provider. The current UI allows adding/editing/removing them. The evolutionary step is **coordinated rotation**: when Claude usage approaches limit on account A, automatically switch in-flight tasks to account B. This requires:
- A priority/order on accounts (already implicit -- array order)
- The poller exposing "least-loaded account for provider X" as a computed property
- The socket API above so agents can request the best available account

This turns usage monitoring into active resource scheduling. The infrastructure is ~80% there.

---

## Mutations and Wild Ideas

### Mutation 1: Temporal Usage Fingerprinting

Every snapshot includes a `fetchedAt` timestamp. Store a rolling window of snapshots (last N ticks) and you have a usage timeline. Expose it as a sparkline in the sidebar bar widget instead of a static number. At a glance, the operator sees whether usage is climbing, stable, or falling -- without having to watch it.

Implementation: add a `history: [UUID: [AIUsageSnapshot]]` alongside `snapshots: [UUID: AIUsageSnapshot]` in the poller. Cap at 60 entries (one hour at 60s tick). The footer bar's `GeometryReader` could overlay a faint line chart behind the fill bar.

### Mutation 2: Provider Health as a Task Constraint in Lattice

Lattice tickets live in the same codebase ecosystem. Imagine a Lattice task attribute: `requires_provider: claude, max_utilization: 80`. The agent scheduler checks AIUsage before starting a ticket and defers it if the provider is above threshold. The AIUsage module becomes a scheduling primitive, not just a display widget.

This is speculative but the pieces are close: Lattice knows about tasks, c11 knows about provider health, and the socket layer connects them.

### Mutation 3: Synthetic Usage Provider for Local Models

The provider contract requires `fetchUsage: @Sendable (AIUsageSecret) async throws -> AIUsageWindows`. A local Ollama or LM Studio instance has no usage API -- but c11 could synthesize one by timing inference requests and estimating utilization from queue depth or response latency. The provider struct is flexible enough to accommodate this -- `credentialFields` would just be `[]` and `fetchUsage` would call localhost.

This makes c11 useful for self-hosted operators and expands the monitoring surface beyond managed APIs.

### Mutation 4: Export / Time-Series Logging

Add an optional `AIUsageLogger` that writes snapshots to a local SQLite file or CSV. Useful for cost attribution across agents, catching API drift (Claude's rate limits changing over time), and post-incident analysis. The poller already has all the data; logging is a side-effect closure injected at startup.

---

## Leverage Points

### Leverage Point 1: Generalize the Keychain Layer (HIGH)

`AIUsageKeychain` is a clean, well-tested generic Keychain wrapper. It uses `UUID` as the account identifier and `[String: String]` as the payload. This is directly reusable for any secret storage in c11. Right now it lives under `Sources/AIUsage/` and is `internal` to the module. Moving it to `Sources/Security/C11Keychain.swift` and renaming to `C11Keychain` costs nothing but makes it available to the next feature that needs credential storage. 

The test patterns in `AIUsageTests.swift` (unique service per test, deterministic cleanup in tearDown) are also worth extracting as a test utilities file.

**Confirmed:** `AIUsageKeychain.swift` is entirely within `Sources/AIUsage/`. It has zero AIUsage-specific logic -- it operates only on `UUID`, `String`, and `Data`. Promotion to shared layer is a zero-risk refactor.

### Leverage Point 2: Make AIUsageProvider Discoverable (STRATEGIC)

`AIUsageRegistry.all` is a hardcoded array. Adding a third provider requires editing this file. An alternative: providers self-register via a static initializer or a simple registration call in their `extension Providers` file. This decouples registry management from the list and makes it possible to conditionally compile providers (e.g., exclude Codex from a lite build) without touching a central file.

A lightweight pattern:
```swift
// In AIUsageRegistry.swift
private var _registered: [AIUsageProvider] = []
static func register(_ provider: AIUsageProvider) {
    _registered.append(provider)
}
static var all: [AIUsageProvider] { _registered }
```

Providers call `AIUsageRegistry.register(Providers.claude)` in their file-level `extension`. The registry never needs to be edited again.

**Note:** This requires care with initialization order -- static initializers in Swift are lazy. A startup `AIUsageRegistry.ensureRegistered()` call in AppDelegate would make the order explicit.

### Leverage Point 3: colorSettings as a General-Purpose c11 Color System (STRATEGIC)

`AIUsageColorSettings` implements hex-based color storage, threshold-segmented mapping, and smooth interpolation. This is exactly the same color system any future health indicator in c11 would need -- pane CPU usage, network throughput, memory pressure. Generalizing to `C11HealthColorSettings` or even a simpler `C11ThresholdColorMap` struct makes the next feature build on this, not duplicate it.

The interpolation math in `Color.usageInterpolate` is already on `Color` as an extension. Renaming to `Color.thresholdInterpolate` or moving it to a `C11ColorMath` namespace signals that it's available codebase-wide.

### Leverage Point 4: The Pending-Force Coalescing Pattern (HIGH)

`AIUsagePoller`'s `pendingForce: Bool` coalescing -- where an in-flight task dequeues and checks whether the waiting tick needs to be forced -- is a general async work-coalescing pattern. Other parts of c11 that do "refresh on event" (surface metadata updates, tab icon updates) could benefit from the same shape. This is worth capturing as a documented utility or at minimum a comment that names the pattern for future readers.

The `runWithTimeout` helper in the poller is similarly general -- it's a clean `withThrowingTaskGroup` wrapper that cancels the losing task. Promoting it to a `Sources/Utilities/` function makes it available everywhere.

---

## The Flywheel

There is a flywheel waiting to be set spinning here, and it's the connection between **agent observability** and **agent behavior**.

Currently the loop is: agents do work -> services rate-limit -> operator notices bars are red -> operator intervenes. That's a reactive loop with human latency in the middle.

The flywheel version: agents do work -> services approach limits -> c11 emits a socket event -> agents self-throttle or reschedule -> limits stabilize -> agents resume at full speed. Human is out of the loop for routine management.

Each step that closes the loop makes the system more autonomous:
1. Socket read API (agents can query their own health): small delta, high value
2. Threshold events (poller publishes threshold crossings): medium delta, enables automation
3. Agent SDK integration (agents call `c11 aiusage status` before heavy tasks): operator-side configuration, no c11 code change
4. Active scheduling (Lattice tasks defer based on provider health): larger integration, but the vision is clear from here

The flywheel compounds because every new provider added to the monitoring substrate immediately participates in the scheduling logic with zero additional code. Adding Gemini monitoring also adds Gemini scheduling. That's the property that makes a flywheel -- components added to one part of the loop strengthen the entire loop.

---

## Concrete Suggestions

### High Value

**1. Promote `AIUsageKeychain` to a shared `C11Keychain` in `Sources/Security/`** ✅ Confirmed
- Move `Sources/AIUsage/AIUsageKeychain.swift` to `Sources/Security/C11Keychain.swift`, rename type to `C11Keychain`, update call sites in `AIUsageAccountStore`
- Zero behavioral change, enables the next feature needing Keychain without reinvention
- Risk: low (pure rename/move, test coverage exists)

**2. Fix the redundant type-checks in `AIUsagePoller.localizedFetchErrorMessage(_:)`** ✅ Confirmed
- Lines 256-264 in `AIUsagePoller.swift`: the `AIUsageStoreError` and `AIUsageFetchTimeoutError` cases are subsumed by the `C11AppOwnedError` check below. Removing the specific cases reduces maintenance surface -- any future conforming error type is handled automatically.
- Risk: near-zero (the behavior is identical since all three types conform to `C11AppOwnedError`)

**3. Promote `runWithTimeout` to a shared utility** ✅ Confirmed
- Extract `AIUsagePoller.runWithTimeout` from its private method into `Sources/Utilities/TaskTimeout.swift` or similar
- Already used in two places within the poller; will be needed by any future polling subsystem
- Risk: none (pure extraction)

### Strategic

**4. Add socket read commands for AI usage state** ❓ Needs exploration
- New socket commands: `aiusage.status` returning JSON snapshot, `aiusage.providers` listing registered providers
- Follows existing socket command shape (see CLAUDE.md threading policy: off-main parsing, `DispatchQueue.main.async` for UI reads)
- Enables the agent self-throttling flywheel
- Risk: medium (requires socket command registration boilerplate, threading discipline per policy)

**5. Generalize `AIUsageProvider` toward a `C11ServiceMonitor` interface** ❓ Needs exploration
- Decouple `AIUsageWindows` from the fixed two-window shape toward `[String: AIUsageWindow]` keyed by label
- This is the architectural gate for non-AI provider types (CI, database, local agent processes)
- Risk: medium (requires updating both fetchers and all display code that assumes `.session` / `.week`)
- Suggested approach: keep the existing shape but add a `windows: [String: AIUsageWindow]` computed property to `AIUsageWindows` as a bridge, migrate display code to use that, then later remove the named properties

**6. Self-registering providers via `AIUsageRegistry.register`** ✅ Confirmed (compatible with architecture)
- The `AIUsageRegistry.all` static array in `Sources/AIUsage/AIUsageRegistry.swift` (line 7) is the only place that would change
- Adding `register(_:)` makes the registry append-only and removes the need to edit a central file when a new provider lands
- Risk: low, but requires verifying Swift static initializer order relative to first `all` access

### Experimental

**7. Sparkline history in footer bars** ❓ Needs exploration
- Add `@Published var history: [UUID: [AIUsageSnapshot]]` to `AIUsagePoller`, capped at 60 entries
- Footer bar's `GeometryReader` overlays a faint line-chart path behind the current-fill bar
- Visual signal for "climbing vs. stable vs. falling" without adding cognitive load
- Risk: minor rendering complexity; test coverage for history capping is straightforward

**8. Threshold breach events as `@Published var`** ❓ Needs exploration
- Add `@Published var activeBreaches: Set<UUID>` (accounts at or above configurable threshold)
- Drives a menu bar badge or sidebar row highlight with no new polling infrastructure
- Risk: low; needs a user-facing threshold setting (could default to 90)

**9. Temporal export via lightweight local logging** ⬇️ Lower priority than initially thought
- Valuable for cost attribution but adds a persistence layer that needs its own management UI (log rotation, export format, privacy implications)
- The data is available whenever someone is ready to build this; not worth rushing

---

## Validation Pass Notes

- Items 1, 2, 3, 6: Verified by direct code reading. All suggested changes are compatible with existing architecture.
- Item 2 specifically: `AIUsagePoller.swift` lines 255-268 confirm the redundancy. `AIUsageStoreError` conforms to `C11AppOwnedError` at `AIUsageAccount.swift:48`. `AIUsageFetchTimeoutError` conforms at `AIUsagePoller.swift:7`. Both have `isAppOwned { true }`. The specific guards add no behavior.
- Item 4 (socket commands): Would need to follow the threading policy in CLAUDE.md (off-main parsing). No existing `aiusage` socket namespace to conflict with. Compatible.
- Item 5 (generalize windows): The two-window assumption is in `AIUsageWindows` struct (`AIUsageProvider.swift:9`), both fetchers, `AIUsageFooterView.bar` (session/week labels), and `AIUsageSettingsSection`. Not a trivial change -- confirmed ❓ rating is appropriate.
- Item 7 (sparkline): `GeometryReader` is already in use in `AIUsageFooterView.bar`. A `Path`-based sparkline overlay fits within the existing layout. The data model change in the poller is straightforward. Complexity is UI, not architecture.
