## Evolutionary Code Review
- **Date:** 2026-04-26T00:00:00Z
- **Model:** Gemini 1.5 Pro
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** e7987ee9
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory
---

**What's Really Being Built**:
While the feature is "AI usage monitoring," the underlying capability being established is a **Generalized Background Polling & Credential Management Engine** for external services. C11 is learning how to hold secrets securely, periodically query external APIs without blocking the main thread, handle timeouts/errors gracefully, and reflect this state asynchronously in the UI. This is the foundational infrastructure for making C11 an "AI-aware" environment rather than a passive terminal. It's the precursor to C11 acting as an active agent or broker for the user's AI resources.

**Emerging Patterns**:
- **The Poller-Store-Provider Triad**: The coordination between `AIUsagePoller`, `AIUsageAccountStore` (state), and `AIUsageProvider` (API definitions) is a robust pattern for any external integration.
- **Protocol-less Injection**: `AIUsageProvider` uses struct closures (`fetchUsage`, `fetchStatus`) instead of a protocol. This functional approach makes adding new providers data-driven and highly composable.
- **App-Owned Errors**: The promotion of `C11AppOwnedError` establishes a clear boundary between raw system/network errors and semantically meaningful application errors, improving UI error rendering.

**How This Could Evolve**:
- **From Monitoring to Brokering**: Currently, this module just reads state. It could evolve to provision temporary tokens, rotate keys, or set cost limits, acting as a gateway for all terminal-based AI requests.
- **Unified AI Context**: If C11 knows token limits and provider status, it could intelligently route AI requests (e.g., auto-complete, command generation) to the cheapest or most available provider, abstracting the provider choice away from the user.

**Mutations and Wild Ideas**:
- **"Bring Your Own Key" (BYOK) Primitive**: The `AIUsageAccountStore` and `AIUsageKeychain` could be generalized into a `C11CredentialVault`. Scripts or plugins running inside C11 could request a token (with user approval), eliminating the need for users to scatter `export OPENAI_API_KEY` across dotfiles.
- **Status-Aware CLI Tools**: If C11 exposed current AI usage/status as environment variables (e.g., `C11_AI_CLAUDE_STATUS=degraded`) or via its local socket, CLI tools running *inside* C11 could dynamically adapt their behavior based on real-time provider health.

**Leverage Points**:
- **Generalizing the Credential Store**: Decoupling the secure storage logic from "Usage" creates immense value for any future integration requiring authentication.
- **Exposing State to the Shell**: A minimal change to inject the poller's state into the terminal environment gives immediate, scriptable power to users without requiring new UI.

**The Flywheel**:
The more providers C11 supports, the more useful the monitoring dashboard becomes. As users increasingly rely on C11 to track their AI usage, they will naturally want C11 to leverage those tracked resources for terminal tasks. Monitoring is the wedge to becoming the central AI orchestrator for the developer.

**Concrete Suggestions**:
1. **High Value** — Generalize `AIUsageAccountStore` and `AIUsageKeychain` into a global `C11CredentialStore`.
   - **Details:** Currently, `AIUsageKeychain` is tightly coupled to `AIUsageSecret`. By extracting the core keychain and user defaults indexing logic into a generic secure vault, you create a primitive that any future C11 feature (like GitHub integration or remote sync) can use.
   - ✅ Confirmed — Verified that `AIUsageAccountStore.swift` and `AIUsageKeychain.swift` have clear boundaries that can be abstracted using generics or protocols for the stored secret type.

2. **Strategic** — Expose poller status and usage metrics to terminal environments.
   - **Details:** Inject the state from `AIUsagePoller` into the terminal sessions (e.g., as environment variables when spawning a pane, or queryable via the C11 local socket). This allows user scripts to be "AI-aware" and fallback to different tools if a provider is down.
   - ✅ Confirmed — The `AIUsagePoller` singleton makes this state globally accessible. Hooking this into the `TerminalController` or environment injection logic during pane creation is highly compatible with the existing architecture.

3. **Experimental** — Add a "Local" provider stub (e.g., Ollama).
   - **Details:** Even if a local LLM doesn't have "usage" in the traditional sense, tracking its availability/status within the same `AIUsageProvider` framework normalizes the idea that local and remote AIs are peer resources within the C11 ecosystem.
   - ❓ Needs exploration — Promising direction but needs prototyping to see how a "no-op" usage fetcher behaves in the current UI.
