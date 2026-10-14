# Adversarial Plan Review

### Executive Summary
The plan is meticulously documented and strictly adheres to the stated shape and latency requirements, but it contains a critical architectural inversion and a high likelihood of failing its own performance gates. By attempting to keep `vendor/bonsplit` "upstream-clean" while simultaneously forcing it to own the application-wide shared animation clock, the plan creates a tightly coupled dependency loop. Furthermore, the plan vastly underestimates the SwiftUI invalidation risks of driving 40+ leaf views via a shared timer in a typing-latency-critical environment. The most likely outcome is that the complex dot-fill animation fails the fleet-scale latency gate, triggering the fallback ladder and rendering a significant portion of this implementation dead code.

### How Plans Like This Fail
- **The "Upstream Clean" Contortion:** Trying to sneak highly specific, product-coupled behaviors (like a UUID-phase-staggered global animation clock) into a generic upstream UI library (`bonsplit`). It usually results in awkward abstractions that are neither truly generic nor perfectly suited for the parent app.
- **The SwiftUI Environment Trap:** Assuming that `@State` and `Equatable` will perfectly isolate leaf view repaints. In practice, injecting a shared clock—often via Combine or Environment—can cause unexpected deep tree invalidations that destroy typing latency.
- **The Untested Extremes:** Designing a fixed 9pt mark floor without a plan for what happens when the container genuinely runs out of horizontal space.

### Assumption Audit
- **Load-bearing:** *The shared clock is a generic renderer primitive, not a c11 flag/socket/metadata primitive, so the Bonsplit change remains upstream-clean.*
  **Likelihood to hold: Low.** A generic tab bar library does not naturally need a staggered, UUID-hashed, application-wide animation clock that knows about "working" and "waiting" phases. Upstream is highly likely to reject this as domain-specific bloat.
- **Load-bearing:** *Each animated mark is leaf-isolated... so repaints cannot invalidate the tab row or workspace card (`TabItemView` relies on `Equatable` + `.equatable()`)*
  **Likelihood to hold: Medium.** If the shared clock is implemented via an `@Observable` or `ObservableObject` that the leaf subscribes to, it is very easy to accidentally trigger layout passes in the parent if the geometry or state escapes the leaf.
- **Cosmetic:** *The continuous animation (dip) is plausibly the cheap one and the discrete one (fill) the expensive one.*
  **Likelihood to hold: High.** Opacity tweens are render-server composite operations; shape structural changes force body re-evaluations.

### Blind Spots
- **Layout Overflow:** The plan dictates that `WorkspacePulseMarkRowMetrics.minimumSlot` becomes 9pt and yields width instead of shrinking. It completely ignores what happens when the row actually runs out of width. Does the title truncate? Do marks clip? Does the row wrap?
- **CPU Wakeups for Non-Key Windows:** The plan states "animate only when the app is active, the mark is present/on-screen...". It does not explicitly define what happens when c11 is visible on a secondary monitor but is not the *key* (focused) window. If a user is coding in VS Code and 20 agents are animating in c11 on monitor 2, is the CPU constantly waking up to draw 2.5Hz dots?
- **Phase Offset Cost:** Deriving phase from UUID bytes using an "explicit stable algorithm". If this algorithm runs per-beat per-mark, it introduces unnecessary overhead. It needs to be cached on initialization.

### Challenged Decisions
- **Placing the shared clock in `vendor/bonsplit`:** This is an architectural inversion. `c11` is the orchestrator; `bonsplit` is a UI component library. The parent app (`c11`) should own the global ticker and pass the current phase/time down to the UI components. Forcing the tab bar to own the global heartbeat just to keep the "vocabulary" together is a mistake.
- **The 0.4s Hard Square Wave:** A 2.5Hz hard flash (violet/white) for `flagged+waiting` is aggressive. While technically below the 3Hz seizure threshold, having multiple agents stalled and flashing like strobe lights indefinitely could be visually exhausting and hostile to the user.

### Hindsight Preview
Two years from now, we will look back and regret putting the application's global animation clock inside a vendored tab bar submodule. We will also realize that "default-on" motion for background terminal processes trains users to either turn on `Static marks` immediately or ignore the UI entirely because it's too "busy". Early warning sign: the fleet-scale typing latency gate barely passes, or fails sporadically on older Intel Macs.

### Reality Stress Test
What happens when:
1. A user is running 30 agents across 5 workspaces.
2. They resize the sidebar to its minimum width.
3. They are typing rapidly in the active terminal pane.

**Result:** The 9pt fixed-width marks refuse to shrink, forcing extreme truncation of the agent titles (or breaking the layout entirely). The 30 agents, all running the dot-fill animation, subscribe to the Bonsplit-owned shared clock. The SwiftUI `Equatable` boundary leaks because of an environmental propagation error, causing the entire sidebar to re-evaluate at 2.5Hz, completely destroying the typing latency and failing the hard ship blocker.

### The Uncomfortable Truths
- The "upstream-clean Bonsplit fix" is a fiction. We are shoving c11-specific animation logic and UUID-phase staggering into a tab bar library to satisfy our own architectural constraints.
- We are building a highly complex, 4-second staggered typewriter animation (the dot fill) that has a very high chance of being disabled by the latency fallback ladder before it even ships.

### Hard Questions for the Plan Author
1. Why does `vendor/bonsplit` (a tab UI component) own the global app animation clock instead of `c11` injecting a timer stream into it?
2. When the sidebar mark row yields width to preserve the 9pt minimum slot, what exactly gets visually compressed or truncated in a crowded workspace?
3. How exactly does Bonsplit compute a UUID-based phase offset without importing c11's `WorkspacePulseAgent` or metadata concepts?
4. If the dot-fill animation fails the latency gate and we fall back to dip-only, will the complex dot-fill code be completely removed, or left as dead weight in the repo?
5. Does the shared timer pause when the c11 app is visible on screen but in the background (not the key window)?
