## Evolutionary Code Review
- **Date:** 2026-04-26T22:46:00Z
- **Model:** Gemini-2.5-Pro
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 88d6b540
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory
---

**What's Really Being Built**:
On the surface, this branch adds a UI widget to show API quota. In reality, it establishes a **localized telemetry sidecar** for external AI dependencies. By integrating secure credential storage (`AIUsageKeychain`), remote status polling (`AIUsageStatusPagePoller`), and occlusion-aware background loops (`AIUsagePoller`), C11 is gaining an ambient awareness of the operational health of its external "brain." This is the foundation for a dynamic service mesh for the operator:agent pair, shifting the burden of tracking rate limits and outages from the operator's browser directly into the terminal's native context.

**Emerging Patterns**:
- **The Pluggable Provider Model**: `AIUsageProvider` and `AIUsageRegistry` establish a clean plugin architecture. It's currently used strictly for usage polling, but this abstraction could easily be extended to include model capabilities, token limits, and routing preferences.
- **Occlusion-Aware Polling**: The `visibilityProvider` in `AIUsagePoller` tying ticks to `NSWindow.didChangeOcclusionStateNotification` is an excellent pattern for resource conservation in an ever-present app. This should be a formalized primitive for any future background polling tasks in C11.
- **App-Owned Error Masking**: The `AIUsageAppOwnedError` protocol to prevent raw OS errors from leaking into the UI is a solid privacy and UX pattern that should be generalized across the application.

**How This Could Evolve**:
The current implementation is purely informational for the operator. The natural evolution is to make this information **actionable for the agents**. 
The `AIUsagePoller` should evolve from a UI-driving state machine into a core system resource manager. Instead of just rendering a color-coded bar, this system should emit state changes over the C11 socket. When Claude is down or quota is exhausted, agents shouldn't have to discover this via HTTP 429s or 503s; C11 should inform them proactively.

**Mutations and Wild Ideas**:
- **The Budget-Aware Agent**: If agents can read their quota via the C11 socket, they can dynamically adjust their behavior. Nearing the 100% mark on Claude? The agent autonomously decides to compress its context window, batch requests, or fallback to a cheaper local model for simpler tasks.
- **C11 as a Circuit Breaker**: If `AIUsageStatusPagePoller` detects an outage (`statusFetchFailed`), C11 could act as a local proxy or circuit breaker, instantly failing fast any agent requests to that provider. This prevents agents from wasting time and tokens in retry loops during known outages.
- **Cross-Provider Load Balancing**: With multiple accounts (e.g., "Personal" and "Work" Codex), C11 could eventually act as a transparent router, automatically shifting traffic from an exhausted account to an available one, seamlessly to the agent.

**Leverage Points**:
- **Socket Integration**: The highest leverage move is exposing the `snapshots` and `incidents` from `AIUsagePoller` to the C11 socket API. This small change transforms a UI feature into a programmatic primitive that every skill and agent can utilize.
- **Generalizing the Poller**: The `AIUsagePoller` logic (timer + occlusion observer + async task management) is highly reusable. Extracting the core scheduling engine makes building the next 10 background features trivial.

**The Flywheel**:
The flywheel here is **Autonomous Resilience**. 
1. C11 monitors provider health/quota.
2. C11 exposes this via the socket.
3. Agents read the socket and gracefully degrade or switch providers when limits are hit.
4. The operator experiences fewer hard failures and a smoother workflow.
5. This encourages adding more providers and accounts to C11, feeding more data back into the system.

**Concrete Suggestions**:
1. **High Value**: Expose `AIUsagePoller` state via the C11 socket. Add a new command `c11 provider-status` or emit events like `provider.status_changed` so agents can react to rate limits and outages. ✅ Confirmed — `AIUsagePoller` is an `ObservableObject` with `@Published` properties, making it straightforward to bridge to the socket dispatcher and emit structured metadata.
2. **Strategic**: Extract the occlusion-aware scheduling logic from `AIUsagePoller` into a reusable `OcclusionAwareScheduler` primitive. ✅ Confirmed — The logic in `AIUsagePoller.start()` and `stop()` is sufficiently decoupled from the AI Usage domain to be abstracted safely into a core utility.
3. **Experimental**: Implement a "Circuit Breaker" toggle. When enabled, if `incidents` contains an active outage, C11 intercepts and blocks agent network requests to that provider to fail fast. ❓ Needs exploration — Requires deep integration with how agents currently make network requests, possibly needing a C11-level network proxy or specific new skill instructions to enforce the routing.