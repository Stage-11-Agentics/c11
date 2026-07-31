# Evolutionary Plan Review

### Executive Summary
The current plan treats C11-185 primarily as a UI polish task—adding localized tooltips and exposing a few timestamps in a details panel. However, beneath the surface, it establishes the foundation for a deeply temporal understanding of agent behavior. If evolved correctly, this isn't just about displaying timestamps; it's about shifting the application from a spatial layout of agents to a timeline-based control center. The biggest opportunity here is utilizing this new temporal truth (durations, creation times, wait times) to unlock agent performance profiling, dynamic resource management, and smarter attention routing for the user.

### What's Really Being Built
You are building the primitives for an **Agent Profiling and Telemetry Engine**. By strictly defining and persisting the boundaries of state transitions (Working, Idle, Cold, Waiting) and exposing a logical `createdAt`, you are creating the exact data structures needed to answer critical questions: "Is this agent efficient?", "Is it stuck?", "Is the user bottlenecking the agent?" The tooltips and Surface Details panels are merely the first, most primitive consumers of this engine. 

### How It Could Be Better
* **Decouple Telemetry from Presentation:** The plan suggests creating a "pure c11 activity-help projection" aimed squarely at tooltips. Instead of optimizing this projection purely for the view layer (text/strings), create a first-class `TemporalAgentProfile` that is view-agnostic. The tooltip renderer should consume this profile to generate strings, but so could a future background resource-manager or CLI dashboard.
* **Resilient Timekeeping:** Relying on simple wall-clock timestamps and subtraction (`now - stateStart`) can be fragile during system sleep, time zone changes, or VM suspends. The plan should explicitly mandate the use of a monotonic clock for duration calculations (Working/Idle/Waiting) to prevent anomalies like "Cold for -5 hours" or instantaneous cold-state upon waking a laptop.

### Mutations and Wild Ideas
* **The "Attention Economy" Sidebar:** Once you know exactly how long an agent has been `Waiting`, you can mutate the sidebar from a static list to a dynamic "Attention Required" queue, sorted by wait duration or flag severity multiplied by time.
* **Agent Billing / Burn Rate Dashboard:** "Working for 20 minutes" translates directly into API token spend. This temporal data could evolve into a live "Burn Rate" meter per tab, helping users manage compute costs.
* **Auto-Hibernation / GC:** Instead of just passively showing `Cold for 3 hours`, this data structure allows the system to autonomously spin down, archive, or garbage-collect forgotten cold surfaces to save memory, turning a passive UI feature into an active performance optimization.

### What It Unlocks
* **Time-Series Analysis:** Persisting these timestamps unlocks the ability to build a true session timeline in the future. Users could visually scrub back through a session to see exactly *when* an agent got stuck or when a flag was raised relative to output.
* **SLA Monitoring:** You can define internal Service Level Agreements (SLAs) for agents (e.g., "If working > 10 mins without any observable output, raise an internal alert/flag").
* **CLI Extensibility:** Once `createdAt` and state durations are formalized internally, it becomes trivial to add a CLI endpoint (e.g., `c11 top`) that displays a real-time process-list of agent activity, bringing CLI observability to parity with the GUI.

### Sequencing and Compounding
* **Invest Early in the Telemetry Protocol:** Step 2 of the plan ("Add one pure c11 activity-help projection...") should be elevated to a core domain model change. Formalize the structured telemetry object first, before writing any UI projection code.
* **Defer Formatting to the Edge:** Do the math and state tracking in raw units (seconds, pure enums) as deep in the stack as possible. Only project into localized strings at the absolute edge (just before Bonsplit/Details panel). Precomputing the payload is good for performance, but ensure it doesn't bake localized strings too early, which would prevent other non-UI systems from using the raw data.
* **Future-Proofing the Bonsplit Contract:** In Step 4, when changing the Bonsplit submodule, ensure the generic help interface is designed such that it can easily be swapped for a rich data payload in the future (e.g., when Bonsplit needs to render mini-charts or progress bars instead of just text tooltips).

### The Flywheel
* **The Transparency -> Trust -> Delegation Flywheel:** By showing exactly what an agent is doing and for how long, you increase user trust. Trust leads to the user confidently launching and delegating to more concurrent agents. More concurrent agents necessitate better visibility and sorting, which this feature (and its future evolutions) provides. To accelerate this flywheel, ensure the state durations are incredibly accurate and resilient to edge cases (like system sleep).

### Concrete Suggestions
1. **Monotonic Clock Fallbacks:** Explicitly use monotonic clocks (like `mach_absolute_time` or `ProcessInfo.processInfo.systemUptime` in Swift) for calculating relative durations to avoid system sleep/wake drift, while using wall-clock only for the absolute `createdAt` and `Last activity` labels.
2. **Headless Access:** Consider exposing the `Activity/Created/Last activity` tuple via an AppleScript dictionary or local socket API in this same pass. If it's useful for the UI, power users will want to script and monitor it immediately.
3. **Ghostty/Terminal Parity:** Ensure the logical `createdAt` logic perfectly aligns with how Ghostty records process starts so that a terminal-based agent and a browser-based agent look completely identical temporally.

### Questions for the Plan Author
1. How does the system handle duration calculations across system sleep boundaries or laptop lid-closes? Should an agent be "Cold" immediately upon wake if the threshold elapsed while sleeping?
2. Is the `activity-help projection` tightly coupled to string generation, or is it a structured object that could easily be reused for a future CLI `top` equivalent?
3. Could the precise `Waiting` duration be used to drive an OS notification system (e.g., alerting the user if an agent has been waiting for input in the background for > 5 minutes)?
4. Should we introduce an "Auto-Archive" policy for agents that reach a certain `Cold` duration, leveraging these new tracking mechanisms?
5. The spec strictly states that legacy snapshots will show `Not recorded`. Could we safely heuristically infer a rough `createdAt` based on the file modification time of the legacy snapshot itself, or is the strict "don't invent" rule completely uncompromising?