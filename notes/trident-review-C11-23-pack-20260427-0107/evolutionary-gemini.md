## Evolutionary Code Review
- **Date:** 2026-04-27T01:07:00Z
- **Model:** Gemini
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** b3c8d6f4
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory
---

### What's Really Being Built

This branch doesn't just add a feature; it erects the scaffolding for a **Local-First Telemetry Plane**. The pivot from remote APIs to local file/database readers (`ClaudeLocalUsageFetcher`, `CodexLocalUsageFetcher`) establishes a powerful, privacy-preserving pattern. The core capability being built is a generic framework for securely gathering data from local application state and presenting it in a unified UI. While it currently monitors AI tools, the `Provider`/`Fetcher` abstraction is extensible enough to monitor anything: local build times, file sync status, project-specific metrics, or even personal habits. This is the beginning of a personal, on-device dashboard for the user's own digital ecosystem.

### Emerging Patterns

- **Provider/Fetcher Abstraction**: This is the most potent pattern here. `AIUsageProvider` defines the "what" (metadata, UI), while the `fetchUsage` closure points to a `Fetcher` that handles the "how" (reading a specific data source). This pluggable architecture is the key to future extensibility.
- **Windowed Aggregation**: The `AIUsageWindow` (session/week) is a solid primitive for time-series summarization, applicable beyond just token counting.
- **Declarative Auto-Registration**: The logic in `AIUsageAccountStore` that detects local data sources (`~/.claude/projects/`) and automatically provisions an account is a great UX pattern that makes onboarding seamless.
- **Anti-Pattern to Address**: Both `ClaudeLocalUsageFetcher` and `CodexLocalUsageFetcher` perform blocking, synchronous I/O (`String(contentsOf:)`, SQLite calls) directly inside an `async` function. As these are called from a `@MainActor` context, this will block the UI and should be dispatched to a background thread.

### How This Could Evolve

The clear evolutionary path is to lean into the "Local Telemetry Plane" concept.

1.  **Generalize the Core Module**: Rename the `AIUsage` module to something more descriptive like `LocalTelemetry` or `DashboardKit`. The `Provider` could be made generic over the data type it fetches, moving beyond `AIUsageWindows`.
2.  **Richer Data Source Fetchers**: The true power is unlocked by adding more fetchers. Imagine providers for:
    *   **Git**: Parse `git log` to track commit frequency and code churn per-project.
    *   **Xcode**: Read build logs from `~/Library/Developer/Xcode/DerivedData` to monitor build times, error rates, and warning trends.
    *   **Figma**: A local Figma plugin could write design statistics to a file, which this plane could then read and display.
3.  **A Unified Timeline**: The current session-based `AIUsageWindow` is good, but a "god view" would be better. A unified timeline that interleaves events from *all* providers (Claude usage, Codex tokens, git commits, Xcode builds) would create a rich, personal activity log for a user's entire workflow.

### Mutations and Wild Ideas

- **Ambient Project Context**: If the app could detect the user's active project (e.g., via the frontmost window's directory), it could dynamically filter all telemetry. The usage view would transform to show token counts and metrics *only for the current repository or workspace*.
- **Local LLM as a Provider**: Add a provider for a local LLM running via Ollama or similar. The "cost" metric could be mutated to represent local resources, like GPU/CPU seconds, memory usage, or even energy consumption in Joules. This shifts the "cost" concept from monetary to resource-based.
- **Cross-Tool Event Correlation**: The system currently shows parallel usage streams. The next leap is detecting causal chains. "User copied code from a high-token Codex response, then immediately pasted it into a Claude prompt." This requires more sophisticated event timestamping and correlation but would provide unparalleled workflow insights.

### Leverage Points

- **The `Provider` Struct**: This is the single biggest leverage point. Making it trivial for a developer to add a new provider is the key to scaling the ecosystem. A "Provider Template" or even a small CLI wizard to scaffold a new fetcher would have an outsized impact.
- **The `AIUsageWindow` Struct**: Generalizing this to support arbitrary metrics beyond `tokensUsed` and `costUSD` (e.g., counts, durations, booleans) would unlock the previously mentioned use cases (builds, commits, etc.).

### The Flywheel

There is a powerful flywheel waiting to be spun up here:

**More Providers -> More Utility -> More Engagement -> More Demand for Providers**

The more tools the dashboard can monitor, the more indispensable it becomes. This encourages users to keep it running and visible, which in turn creates a demand for developers to contribute new providers for their own tools, kicking off a virtuous cycle.

### Concrete Suggestions

1.  **High Value ✅ Confirmed**: **Fix Blocking I/O**. Refactor the synchronous file and database I/O in the fetchers to a background thread to prevent UI stalls.
    - In `ClaudeLocalUsageFetcher.swift`, wrap the file enumeration and `String(contentsOf:)` loops in a `Task.detached`.
    - In `CodexLocalUsageFetcher.swift`, wrap the `sqlite3_*` call sequence in a `Task.detached`.

2.  **Strategic ❓ Needs exploration**: **Generalize to a `LocalTelemetry` Module**.
    - Rename core components: `AIUsageProvider` -> `TelemetryProvider`, `AIUsageWindow` -> `TelemetrySnapshot`.
    - Update `TelemetrySnapshot` to use a generic `[String: Double]` dictionary for metrics instead of hardcoded `tokensUsed` and `costUSD`. This makes the system extensible to any quantifiable data.

3.  **Experimental ❓ Needs exploration**: **Build a "Git Commit" Provider**. As a proof-of-concept for the telemetry plane, create a `GitCommitFetcher.swift`. It would use the `Process` API to run `git log --since="7 days ago"` in user-specified project directories and count the number of commits. This would demonstrate the system's flexibility and provide immediate value.

4.  **High Value ✅ Confirmed**: **Fix Stale Documentation**. Update `docs/ai-usage-monitoring.md` to remove the troubleshooting section mentioning HTTP error codes (401, 403, 404). These are artifacts from the old remote API approach and are no longer relevant for the local-only providers.
