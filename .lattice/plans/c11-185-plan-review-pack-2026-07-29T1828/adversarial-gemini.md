# Adversarial Plan Review

### Executive Summary
The plan acts as a superficial checklist that parrots the acceptance criteria without resolving the fundamental architectural contradictions introduced by the spec. The single biggest issue is the irreconcilable conflict between precomputing the tooltip strings (as the plan suggests in Step 2) and the requirement to "refresh tooltip copy on hover entry" without using repeating timers. If you precompute a relative duration string in the state-sync path, it will go stale the moment the user stops interacting with the app. When they hover 10 minutes later, they will see the old duration.

### How Plans Like This Fail
Plans involving relative time displays ("Working for 2 minutes", "Idle for 7 minutes") fail because they treat elapsed time as static data. Developers pre-format the string, pass it down the view hierarchy, and forget that time keeps moving independently of app state changes. When the user hovers, they see stale data. The alternative failure mode is inserting a `Timer` to trigger view updates or doing heavy date formatting in a typing-hot view (both of which the spec explicitly forbids). This plan is highly vulnerable because it explicitly states it will "precompute it with localized duration... composition," almost guaranteeing the tooltips will either be stale or violate performance guardrails to keep them fresh.

### Assumption Audit
*   **Assumption:** Precomputing the localized duration string in the parent state-sync works for tooltips. **Load-bearing.** If this holds, the plan works. It will *not* hold. State-syncs only happen on activity or state changes, while time passes continuously. Tooltips will be stale on hover unless evaluated dynamically.
*   **Assumption:** Standard tooltip mechanisms (e.g., SwiftUI `.help()`) evaluate on demand upon hover entry. **Invisible.** SwiftUI `.help()` takes a binding or static value. If the value is a precomputed string, it will not update on hover unless a separate state mechanism triggers a re-render.
*   **Assumption:** "Cold" duration calculation just needs the `lastActivity` timestamp. **Invisible.** Cold duration actually needs to subtract the `thresholdSeconds` from the idle duration (i.e., time since `lastActivity + thresholdSeconds`). Does the projection precalculate the cold transition time, or does it expect the leaf node to know the threshold?
*   **Assumption:** `lastActivity` is already perfectly persisted and restored for all panel types. **Visible.** The plan promotes `createdAt` (Step 3) but barely mentions the mechanics of `lastActivity` persistence and restoration, despite the spec requiring it to survive restarts.

### Blind Spots
*   **The "Refresh on Hover" mechanism:** How exactly will the app know the user hovered to trigger a refresh of the string without doing date formatting in the hot path, and without triggering a state change that invalidates the `TabItemView` body? The plan leaves this as "magic".
*   **Waiting State Timestamps:** The spec states "Waiting uses the exact surface unread-notification creation time". Where is this time fetched? It is often not natively present in standard lifecycle liveness derivations.
*   **Memory / CPU for on-demand strings:** If formatting is correctly deferred to hover time, what are the performance implications if the user aggressively scrubs their mouse across 50 tabs?
*   **Timezone and Locale changes:** What happens to "Created" and "Last activity" absolute timestamps if the user changes timezones or locales mid-session?

### Challenged Decisions
*   **Precomputing the localized duration (Step 2):** This is the fatal flaw. "Add one pure c11 activity-help projection with localized duration/modifier composition; precompute it for top tabs". You cannot precompute a relative time string if you aren't updating it with a timer. The projection must precompute the *data* (e.g., `enum State { case idle(since: Date) }`) and the *tooltip presentation layer* must lazily compute the localized string exactly on hover entry. The plan needs to push the formatting to the absolute edge (e.g., an `NSView` tooltip delegate or a carefully crafted hover action), outside the `TabItemView` body but evaluated strictly on demand.
*   **Bonsplit generic help data boundary (Step 2/4):** The plan mentions adding help data to Bonsplit but doesn't define the API boundary. If `BonsplitTabActivityPresentation` accepts a precomputed `String`, Bonsplit's tooltips will be hopelessly stale. Bonsplit needs to accept a closure `() -> String` or raw timestamp data to evaluate it lazily.
*   **Promotion of `createdAt` (Step 3):** Why only terminal, browser, and markdown? If a new panel type is added, does it silently fail to have a creation timestamp? This feels like an incomplete architectural change.

### Hindsight Preview
In two months, users will file bug reports stating, "The tooltip says the agent has been idle for 2 minutes, but I haven't typed anything in an hour." We will look back and say, "Of course precomputed strings go stale, why didn't we format them lazily on hover?" We will also likely realize that attaching dynamic native tooltips in SwiftUI required `.onHover` tracking to force state updates, which ended up causing the exact typing-hot re-renders in `TabItemView` we were specifically trying to avoid.

### Reality Stress Test
Disruptions:
1.  **The long pause:** A user leaves the window in the background for 3 hours, foregrounds it, and immediately hovers over a tab. (A precomputed string will say "Idle for 0 minutes" because it was generated 3 hours ago).
2.  **API Limitations:** The Bonsplit repo maintainers (or its current architecture) do not support lazy tooltip string closures. (We are forced to either fork Bonsplit's tab model or suffer stale tooltips).
3.  **Complex Locales:** The "final six-locale translation pass" encounters languages where plural rules for time don't map cleanly to simple string interpolation.

**Result:** The feature easily meets the acceptance criteria during a 5-second QA test but fails entirely in real-world, long-lived development sessions due to stale data.

### The Uncomfortable Truths
*   The specification is asking for a UX that SwiftUI is historically terrible at providing efficiently (lazy, dynamic tooltips without timers or view body invalidations).
*   The plan's author largely summarized the task description into 6 bullet points without actually designing a technical solution for the most contradictory constraints.
*   "Delegate the final six-locale translation pass" is hand-waving away the complexity of pluralizing time strings in 6 different grammatical structures. Foundation's formatting APIs handle this, but they are expensive to allocate and call on the fly.

### Hard Questions for the Plan Author
1. How exactly will the localized tooltip string update to reflect elapsed time when the user hovers, given that Step 2 explicitly says the duration string is "precomputed" in the parent path?
2. If `TabItemView` cannot perform date formatting, and the string cannot be precomputed without going stale, where *exactly* in the call stack is the duration string generated? (If the answer is "we don't know", the plan is blocked).
3. What is the API contract for `BonsplitTabActivityPresentation`? Does it take a static `String` for the tooltip (which will go stale) or a lazy `() -> String` provider?
4. How is the cold duration (time since crossing the cold threshold) accurately calculated? Does the precomputed payload include the threshold, or does it precalculate the transition time and pass that down?
5. The spec requires "Waiting" to use the "unread-notification creation time". Is that precise timestamp already available in the `WorkspacePulseAgent` payload, or does the pipeline need new, potentially expensive wiring?
6. How do you prevent `.onHover` tracking from invalidating `ContentView.TabItemView` bodies and violating the typing-hot performance guardrails?