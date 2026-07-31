# Standard Plan Review

### Executive Summary
The plan is essentially a regurgitation of the task specification. It successfully identifies all constraints, dependencies, and requirements (like the Bonsplit submodule choreography and the typing-hot guardrails) but stops short of actual architectural design. It functions more as an execution checklist than a blueprint. While technically sound because it adopts the spec's constraints wholesale, it defers all the hard implementation details—like how to update tooltips on hover without invalidating hot views, and how to calculate the cold threshold correctly—to the coding phase.

### The Plan's Intent vs. Its Execution
The intent of the plan is to guide the implementation of agent-state tooltips and persistent timestamps. The execution of the plan merely re-states the acceptance criteria as actionable steps. It does not map the actual state flow or define the data structures. It outlines *what* will be done (e.g., "Add one pure c11 activity-help projection"), but not *how*. As a result, the risk of intent drift during execution is high because the agent writing the code will have to invent the architecture on the fly.

### Architectural Assessment
The structure presented is correct because it is mandated by the spec, but it lacks necessary depth. The plan rightly acknowledges the need for an immutable activity-help payload and the promotion of `createdAt` through `Panel` implementations. 

However, it fails to outline the data structures. What does the `activity-help` payload look like? Does it store pre-formatted strings, or does it store the raw timestamps and modifier enums for localized formatting closer to the view? An alternative and stronger framing would have explicitly defined the structs/types for the projection and detailed the exact data flow from `SurfaceLivenessDeriver` to `ContentView.TabItemView` and `BonsplitTabActivityPresentation`.

### Is This the Move?
In highly constrained systems like this (dealing with typing-hot paths in SwiftUI/AppKit and external submodules like Bonsplit), deferring design to the implementation phase is a risky move. A better plan would nail down the specific mechanisms for the performance constraints before touching the code. For instance, the spec demands "Refresh tooltip copy on hover entry" but also says "precompute immutable payloads in the existing parent/state-sync paths." The plan does not explain how these two seemingly conflicting requirements will be reconciled.

### Key Strengths
- **Constraint Awareness:** The plan correctly identifies the need to avoid `SurfaceMetadataStore` for UI facts and respects the Bonsplit submodule boundary.
- **Backward Compatibility:** Explicitly calls out leaving legacy snapshots nil for `createdAt` and capturing `Not recorded`, strictly adhering to the spec.
- **Testing Focus:** Step 4 contains an excellent list of edge cases to test (missing evidence, cold threshold arithmetic, flag + suppression composition, legacy decoding).

### Weaknesses and Gaps
- **Superficiality:** It rewrites the prompt instead of designing the solution.
- **Performance Ambiguity:** The plan says it will precompute the projection for top tabs but doesn't explain how it will fulfill the requirement to "Refresh tooltip copy on hover entry" without per-agent repeating timers and without invalidating the typing-hot `ContentView.TabItemView`.
- **Cold Duration Calculation:** The spec has a very specific rule: "Cold begins when last activity plus `SidebarAgentColdSettings.thresholdSeconds()` is crossed." The plan mentions testing this but doesn't explain how the projection will calculate it instead of just falling back to total idle time.

### Alternatives Considered
For the tooltip refresh mechanism, the plan defaults to precomputation. An alternative would be an `ObservableObject` or a localized state wrapper specifically attached to the tooltip view modifier that calculates the localized string on-demand when the hover state changes, reading from the immutable baseline timestamp payload. The plan should have considered and explicitly chosen a path here to ensure performance guardrails are met.

### Readiness Verdict
**Needs revision.** The plan is a good checklist, but it needs to answer the "how" for the trickiest parts of the spec before coding begins. Specifically, it needs to detail the struct of the projection and the mechanism for hover-refresh in hot paths.

### Questions for the Plan Author
1. How exactly will you fulfill the requirement to "Refresh tooltip copy on hover entry" for the top tab without introducing timers or invalidating the typing-hot `ContentView.TabItemView` when the precomputed payload changes?
2. What will the `activity-help` projection data structure look like? Will it contain pre-formatted localized strings, or raw enums and timestamps for the view to format?
3. Where and how will you store the structured Activity/Created/Last activity data for Surface Details if you are explicitly avoiding `SurfaceMetadataStore`?
4. How are you calculating the "cold" duration so it correctly reflects the time *since* the threshold was crossed, rather than the total idle time?
5. Which specific `Panel` classes and session snapshot decoders will you need to modify to plumb the optional `createdAt` field?
