### Executive Summary
The current plan identifies a critical deadlock where SwiftUI's synchronous layout pass is blocked by Ghostty's mailbox futex, driven by relentless `updateNSView` display ID re-assertions. However, treating this merely as a "message flooding" bug to be patched with memoization and mailbox drops misses a massive architectural opportunity. The real potential here is to fundamentally evolve c11 into an indestructible workspace hypervisor. By expanding this fix from a surgical patch into an **Asynchronous FFI Boundary**, we can guarantee that no terminal deadlock—whether from mailboxes or font grid lock contention—can ever wedge the operator's command center again.

### What's Really Being Built
On paper, this plan builds a memoization cache and a non-blocking push variant for Ghostty. Beneath the surface, it is laying the foundation for an **Asynchronous UI-to-Terminal Bridge**. The core capability being evolved is the decoupling of the c11 UI thread (the hypervisor) from the Ghostty renderer lifecycle (the guest). The thing that actually evolves is c11's resilience profile: transitioning from a tightly coupled terminal emulator into a master control plane that is structurally immune to its subprocesses' failures.

### How It Could Be Better
1. **Solve the Class, Not the Instance:** The `BUG-main-thread-deadlock-attachSurface.md` investigation proved that `attachSurface` also blocks on `ghostty_surface_new` due to `SharedGridSet` lock contention. The plan's display ID memoization does nothing to protect the main thread from that separate deadlock. The plan would be infinitely better if it moved *all* Ghostty interactions out of `updateNSView` and off the main thread entirely, rather than just optimizing one call path.
2. **State Coalescing over Log-and-Drop:** Modifying `ghostty_surface_set_display_id` to push `.instant` and drop on a full mailbox is dangerous. If a renderer wakes up, it will drain the full mailbox but miss the dropped display ID, leaving it permanently out of sync with the window's display link. c11 should manage a state reconciler instead: writing the desired state to a shared atomic configuration block that the renderer pulls, completely avoiding the mailbox queue for idempotent continuous state.

### Mutations and Wild Ideas
1. **The Shared Memory Config Block:** Mutate the mailbox architecture. Instead of pushing configuration changes (like display ID, window size, or focus state) through a bounded FIFO message queue, place them in a lock-free atomic struct. The mailbox is only used to send a lightweight "config changed" ping. The renderer reads the struct on its next loop. This collapses 10,000 redundant updates into a single atomic write and structurally eliminates "UI state mailbox full" deadlocks forever.
2. **Zombie Terminal Mode:** If a renderer thread wedges (e.g., deadlock detected via timeouts), c11 could detach the UI from the dead Ghostty instance and replace it with a "Ghostty Unresponsive - [Restart] [Debug]" overlay. Because the agent underneath is likely still running and accessible via the c11 socket, this turns a catastrophic crash into a highly localized, manageable UI event.
3. **The Out-of-Process Renderer (The Chrome Model):** Push the decoupling to its logical extreme. What if Ghostty surfaces ran in a separate XPC service? This massive mutation would guarantee absolute main-app stability at the OS level.

### What It Unlocks
*   **Total UI Immunity:** By completely isolating the FFI boundary, c11's core UI (tabs, splits, markdown, browser) becomes immune to terminal rendering stalls.
*   **Massive Agent Scaling:** Operators can confidently run 50+ concurrent agents without the fear that a massive log spew in one terminal will freeze their entire command center.
*   **Headless-First Resilience:** If the UI is decoupled from the terminal state, the terminal can run entirely headlessly and attach/detach from the UI on the fly, unlocking roaming sessions or remote UI attachments.

### Sequencing and Compounding
1. **Immediate (The Bleeding):** Implement the `setDisplayID` memoization locally in c11 to stop the high-volume (941 events) bleeding, as the plan suggests.
2. **Short Term (The Real Fix):** Move `attachSurface` entirely off the main thread to a dedicated background serial queue (or a Swift Concurrency `@globalActor`). This catches both the mailbox deadlock and the font grid deadlock.
3. **Medium Term (Upstream):** Propose the atomic shared-state pull model for UI configurations to upstream `cmux`/`ghostty`, eliminating the need for bounded queues for idempotent state updates entirely.

### The Flywheel
**The Resilience Flywheel:** Decoupling the UI ensures the app never crashes -> The operator confidently runs more agents simultaneously -> Increased concurrency puts more stress on the renderer -> Ghostty bugs surface as isolated pane hangs rather than full-app wedges -> Agents/Maintainers use `c11-computer-use` and socket commands to auto-recover, report, and debug those panes -> Faster iteration on renderer stability.
By fixing the isolation layer, we create a safe environment to find and fix all other Ghostty bottlenecks.

### Concrete Suggestions
1. **Introduce a `GhosttyBridge` Actor:** Create a dedicated background serial queue or Actor that serializes all calls to Zig. `GhosttyTerminalView.updateNSView` should fire `Task { @GhosttyBridge in ... }` instead of calling `attachSurface` synchronously.
2. **Never Drop State:** Do not implement "log-and-drop" for `.instant` messages in Ghostty. If upstream isn't ready for a pull-model config struct, implement a coalescing message type where newer display ID messages overwrite older ones in the queue, rather than appending or dropping.
3. **Deadlock Recovery Socket Command:** Implement a `c11 force-detach-surface --surface <ref>` (or `c11 recover`) command that runs completely off-main. This allows an operator or watchdog script to nuke a wedged pane without force-quitting the app.

### Questions for the Plan Author
1. If the `.instant` push for `macos_display_id` drops on a full mailbox, how does the renderer ever learn its correct display ID once it finishes draining? Doesn't this risk a permanently mismatched display link?
2. `BUG-main-thread-deadlock-attachSurface.md` proved that `ghostty_surface_new` also blocks `updateNSView` due to font grid lock contention. The memoization fix does not address this. Shouldn't we wrap the entirety of `attachSurface` in an async/background dispatch to protect the main thread completely?
3. Since `updateNSView` is called frequently by SwiftUI, could we avoid pushing to the mailbox altogether when the state is unchanged by keeping the memoization cache on the C11 side (as proposed), but *also* isolating the push to a background thread?
4. Would proposing a "pull" model (atomic config block) for continuous UI states like Display ID and Window Size be a better upstream architectural proposal than tweaking the mailbox push behavior?