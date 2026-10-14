# TP-c11-183-plan-Gemini-Evolutionary

### Executive Summary
The plan aims to decouple agent lifecycle states from color, moving to a purely geometric shape-based vocabulary. While ostensibly an accessibility fix and a prerequisite for the C11-184 "flagged" modifiers, this plan is actually laying the groundwork for a high-density, multi-channel peripheral communication protocol. If evolved correctly, this geometric vocabulary combined with the shared animation clock can transform the sidebar from a simple status list into a cohesive, low-cognitive-load, fleet-scale dashboard that leverages spatial rhythm.

### What's Really Being Built
On paper, this is a UI update for four icons. Under the surface, you are building two massive foundational capabilities:
1. **A Semantic Geometric Protocol**: You are separating the visual channels of the terminal UI. Shape is now exclusively the carrier for *state*. Color is freed up for *urgency/modifiers* (C11-184). Motion is reserved for *demand/attention*. 
2. **Global Fleet-Scale Metronome**: The "shared animation clock" is a synchronized render-infrastructure for the UI. It proves that c11 can handle constant ambient animation across dozens of surfaces without polluting the main thread or breaking the strict typing-latency boundaries detailed in `CLAUDE.md`.

### How It Could Be Better
**Abstract the Metronome:** 
The plan scopes the shared clock as a "small public, Bonsplit-owned generic activity-animation clock." Instead of tying this strictly to the activity marks, conceptualize and implement it as a `WorkspaceMetronome`. Make it a generic publisher (e.g., `Combine` or `AsyncStream`) that pauses on App Nap, off-screen, or backgrounding. By making it generic now, other ambient systems (like hot-loading indicators or future timeline views) can tap into the same exact tick without spawning new timers.

**Spatial Cohesion over Randomness:**
The plan suggests offsetting the animation phase by a "stable hash of surface id" so the fleet staggers. Random scattering is visually noisy. Instead, offset the phase based on the surface's *sorted index* or layout position. This turns 20 independent blinking marks into a subtle, cohesive, cascading visual wave down the sidebar. It groups the fleet into a unified entity rather than a chaotic scatter-plot.

### Mutations and Wild Ideas
- **Throughput-Coupled Motion:** The plan dictates a strict ~4-second typewriter fill for the "working" 3x3 grid. What if the fill speed was subtly coupled to the agent's actual `stdout` / token-generation throughput? A fast-typing agent fills the grid rapidly; a heavily thinking agent fills it slowly. This utilizes the exact same geometric constraints but adds an immense amount of qualitative telemetry for the operator without requiring them to read the text.
- **The 9-Pixel Agent Display:** If the "working" state is a 3x3 grid of dots, you've inadvertently given every agent a tiny 9-pixel display. An agent via the skill could eventually push a 3x3 bitmap to its own mark to indicate specific phases of work (e.g., a mini progress bar, a specific pattern for "compiling" vs. "searching").
- **Sonar (Audio Channel):** With states decoupled and a global clock running, c11 could emit extremely subtle, spatialized audio cues (like a sonar ping) when an agent enters the "needs attention" state, pitched differently based on their position in the workspace.

### What It Unlocks
- **Zero-Cost Peripheral Awareness:** By shifting state to shape and motion, operators will begin to read the sidebar entirely in their peripheral vision. They won't need to focus on a mark to know what it is; the geometric silhouette will register automatically.
- **The Color Canvas:** As intended, this unlocks the entire color spectrum for C11-184 (the violet flag). But it also means future states (like "error" or "success") can use color without fundamentally breaking the lifecycle read.
- **Safe Ambient Animations:** Proving the leaf-isolated, shared-clock pattern works for the marks unlocks the ability to use this pattern elsewhere in c11's highly typing-latency-sensitive environment without fear of regressions.

### Sequencing and Compounding
**De-risk the Clock First:**
The current plan executes pure Bonsplit shapes (Phase 1) before the shared clock (Phase 2). This is risky because the shared clock's latency profile is the *hard ship blocker*. 
*Optimal Sequence:* Build a dummy leaf view and the shared clock *first*. Wire it up and run it against the fleet-scale `c11-unit` typing-latency gate. If the architecture fails the latency gate, you know immediately that you must fallback to the static implementations before spending time perfectly tuning the typewriter fill and opacity dips on the Bonsplit geometry.

### The Flywheel
**The Density Flywheel:**
Right now, an operator might only run 5 agents because the visual noise of checking their states is too high. By moving to a peripheral-friendly geometric read, the cognitive cost of monitoring an agent drops. Lower cognitive cost allows the operator to comfortably dispatch 10, then 20 agents simultaneously. Higher fleet density makes the spatial wave (from the phase offsets) more obvious and useful, further reducing cognitive load and spinning the flywheel. 

### Concrete Suggestions
1. **Implement Spatial Phase Offsetting:** Discard the surface ID hash for phase offsets. Use the item's layout index. A top-to-bottom phase offset creates a breathing, wave-like rhythm that feels designed and calming, rather than randomly flashing.
2. **Accessibility (VoiceOver) Integration:** The plan touches on visual accessibility (color-blindness) but misses screen-reader impacts. Ensure the leaf view sets `accessibilityLabel` correctly on state changes, but aggressively debounces these announcements so a flashing flag doesn't spam VoiceOver.
3. **Formalize the Fallback:** In Phase 3, explicitly implement the degradation ladder (dip-only -> static) as a feature flag or automatic fallback if the render loop exceeds a specific frame budget, rather than just a manual developer toggle.

### Questions for the Plan Author
1. If the shared animation clock fails the fleet-scale typing-latency gate, what is the exact mechanism (code-wise) for degrading to the static set? Are we manually reverting, or is the degradation ladder built into the configuration?
2. Does the shared clock properly respect macOS App Nap and display sleep, or does it rely purely on SwiftUI's `onAppear`/`onDisappear` (which can be unreliable in complex split-views)?
3. How will VoiceOver handle the 0.4s violet/white alarm flash? Will it try to announce every state change, and if so, how is that throttled?
4. Is there room in the technical design to eventually pass a `speedMultiplier` to the working mark, allowing its fill rate to reflect actual agent throughput?