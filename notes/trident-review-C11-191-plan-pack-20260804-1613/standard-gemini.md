# Standard Plan Review

### Executive Summary
The plan correctly identifies the specific blocking operation (`ghostty_surface_set_display_id`) responsible for the C11-191 watchdog hangs, discarding a misleading symbolicated stack trace in favor of local log disassembly. The two-part fix (c11 memoization + ghostty `.instant` mailbox push) is excellent and addresses both the immediate spamming issue (O(layout passes) vs O(display changes)) and the underlying architectural vulnerability (blocking the main thread on an inter-thread queue).

### The Plan's Intent vs. Its Execution
The plan's intent is to eliminate the 2.3s SwiftUI preference-pass hang. By recognizing that `updateNSView` is unconditionally pushing to a bounded mailbox on every layout pass, the plan addresses the root cause of the mailbox filling up. By changing the mailbox push to non-blocking (`.instant`), it guarantees that even if the renderer is wedged (e.g. by font contention, as seen in the related BUG ticket), the main thread will not livelock. The execution perfectly aligns with the intent.

### Architectural Assessment
This is the correct decomposition. The problem is a combination of two bad behaviors:
1. The caller (c11) is spamming a state update (display ID) redundantly at 60Hz.
2. The callee (Ghostty) is enforcing synchronous backpressure (`.forever`) on the main thread for a non-critical metadata update.

Fixing both layers is the most robust approach. The c11-side fix prevents unnecessary mailbox churn and avoids waking the renderer when nothing has changed. The Ghostty-side fix enforces the strict rule that the UI thread must not wait on a potentially wedged background thread. 

An alternative would be to only fix the c11 side (memoization). However, as the related BUG ticket demonstrates, the renderer thread *can* get wedged (e.g. font lock contention). If the renderer is wedged and a legitimate display ID change occurs, the c11 main thread would still block on the `.forever` push. Therefore, the Ghostty-side non-blocking push is a necessary structural fix.

### Is This the Move?
Yes, this is the right move. The project principles explicitly state that nothing blocking may run on the main thread, least of all inside a layout pass. 
Changing `ghostty_surface_set_display_id` to use `.instant` + log-and-drop handles the backpressure correctly without taking down the UI. If the renderer is so swamped that the 64-slot mailbox is full, dropping a display ID update is a very acceptable fallback compared to beachballing the app. 
The c11-side memoization is standard SwiftUI performance hygiene (don't do work in `updateNSView` unless inputs changed).

### Key Strengths
* **Skepticism of the Sentry Stack**: The author noticed the impossible frame (`Foundation.URL? outlined copy`) and cross-referenced with a local watchdog log and disassembly to find the real blocking call. This is expert-level debugging.
* **Defense in Depth**: Fixing the spam on the Swift side *and* the blocking nature on the Zig side ensures the bug won't recur even if another spammer is introduced later.
* **Respect for Upstream**: The Zig change is properly identified as a generic upstream fix, adhering to the repo's fork policy.

### Weaknesses and Gaps
* **Dropped Display ID Risk**: If the mailbox is full and the push is dropped, does the renderer's display link stay pointed at the old monitor indefinitely? The plan mentions "hot sites pass `force: false`, every deliberate unstick-vsync site keeps `force: true`". But if the `force: true` push is dropped due to a full mailbox, what recovers it? It's likely the renderer is already heavily wedged if the mailbox is full, but it's worth considering if there's a retry mechanism or if the user simply interacting with the window again will issue a new display ID.
* **Relation to `BUG-main-thread-deadlock-attachSurface.md`**: The plan addresses the mailbox push deadlock, but does not explicitly mention the font lock contention that might be *causing* the renderer to stop draining the mailbox in the first place. The mailbox fills because the renderer is slow/wedged. If the renderer is wedged on `SharedGrid.lock`, fixing the main-thread deadlock turns a global app hang into a per-surface hang (the renderer thread is still stuck). This is a vast improvement (the app survives), but the user still has a dead terminal surface.

### Alternatives Considered
* **Asynchronous dispatch from Swift**: Instead of pushing to the mailbox directly, Swift could dispatch to a background queue to perform the `.forever` push. This is a common pattern, but it's worse here: it still blocks a thread, and if the mailbox never drains, you leak threads. The plan's choice (Zig-side `.instant` push) is structurally superior because it respects the bounded nature of the mailbox.
* **Increasing Mailbox Size**: Changing the mailbox from 64 to 1024 slots. This is a naive fix that just delays the hang. The plan correctly avoids this.

### Readiness Verdict
**Ready to execute.** The plan is well-reasoned, backed by hard evidence, and structurally sound.

### Questions for the Plan Author
1. If the `.instant` push fails because the mailbox is full during a legitimate `force: true` display ID change (e.g., window moved to a different monitor), does the terminal just render at the wrong refresh rate until the user interacts with the window again? Is that acceptable?
2. The renderer's mailbox is full because the renderer stopped draining it. While this plan correctly protects the main thread from being taken down as collateral damage, do we know *why* the renderer stopped draining? Is it the font lock contention described in `BUG-main-thread-deadlock-attachSurface.md`, or something else? 
3. Should the Ghostty fork change also include a wake-up signal *before* the `.instant` push? (The plan mentions "Notify the renderer first so it can drain", which implies yes, but it's worth confirming that the notification mechanism itself doesn't block).