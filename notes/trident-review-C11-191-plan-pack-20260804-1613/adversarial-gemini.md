# Adversarial Plan Review

### Executive Summary
The plan identifies a genuine bug—unconditional mailbox pushes causing a deadlock on a full 64-slot queue—but it suffers from severe tunnel vision. The plan author dismisses the original ticket's hypothesis (a SwiftUI preference pass hang) and ignores prior investigation (`notes/BUG-main-thread-deadlock-attachSurface.md`) into the *exact same process (pid 6063)* that proved the main thread was blocked on a font grid lock, not just the mailbox. By only fixing the mailbox spam, this plan treats a symptom (SwiftUI spamming updates) without addressing why the renderers are wedged or the fact that `attachToView` still blocks on the font lock. The plan is highly vulnerable to "fixing the wrong thing" and leaving the primary user-facing hang completely unresolved.

### How Plans Like This Fail
1. **The Single-Root-Cause Fallacy**: The author finds one smoking gun (mailbox filling up) and stops looking, declaring the original hypothesis ("that reading does not survive contact with the evidence") dead. Complex hangs often have multiple contributing factors.
2. **Dismissing Conflicting Evidence**: The plan ignores `BUG-main-thread-deadlock-attachSurface.md`, which analyzed the *same pid 6063* using `sample` and proved it was blocked in `SharedGridSet.ref`. The plan claims "Every wedged sample sits at `attachSurface + 372`" based on `hang.log`, totally ignoring the `sample` data.
3. **Treating Symptoms, Not Diseases**: The mailbox fills up because SwiftUI is spamming `updateNSView` (disease 1) and the renderer thread is not draining it (disease 2). Memoizing the display ID stops the mailbox from filling, but SwiftUI is still churning 60+ times a frame, and the renderer is still wedged/starved.

### Assumption Audit
1. **Assumption:** The Sentry stack's SwiftUI frames are just "outer frames" and the *real* blocker is always `ghostty_surface_set_display_id`.
   * **Likelihood to hold:** Low. The 941 Sentry events might actually be SwiftUI layout passes thrashing (the TabItemView Equatable bypass mentioned in the ticket), and the mailbox full is just an edge case hit by pid 6063.
2. **Assumption:** The renderer thread is not draining because it's just a little behind.
   * **Likelihood to hold:** Zero. If the renderer thread isn't draining a 64-slot queue, it's either deadlocked or starved (likely by the `SharedGridSet` rwlock contention detailed in the other bug report). Notifying a deadlocked thread won't make it drain.
3. **Assumption:** Dropping a `.macos_display_id` message on a full mailbox is safe.
   * **Likelihood to hold:** Medium. It might break vsync or display updates if the dropped message was a *genuine* display change. Memoizing is better, but dropping on the Zig side introduces a hidden failure mode.

### Blind Spots
1. **The Font Lock Deadlock:** The plan completely ignores `BUG-main-thread-deadlock-attachSurface.md`'s finding about `SharedGridSet.lock.lock()`. If a new surface is attached (which calls `attachToView` -> `ghostty_surface_new`), it will STILL block the main thread waiting for the font lock, which is held by 21 renderers.
2. **SwiftUI Layout Churn:** The plan accepts that `updateNSView` is called 64+ times in quick succession as a given. Why is `updateNSView` firing that much? If the tab bar preference pass is churning, memoizing the display ID just makes the churn *silent*; it doesn't fix the CPU burn or the 2.3s stall if the churn itself is expensive.
3. **Renderer State:** The plan assumes sending a notify to the renderer will make it drain the queue. But if the renderer is wedged on a font rwlock, the notify does nothing.

### Challenged Decisions
1. **Dropping `.macos_display_id` messages (the upstream Zig fix):**
   * *Counterargument:* If the queue is full because the renderer is permanently wedged, dropping the message prevents the main thread from dying, but leaves the terminal surface permanently broken (no vsync, no rendering). If the queue is full transiently, dropping a display ID change means the terminal continues to render for the wrong display. The real fix is an unbounded queue, or a dedicated atomic state for display ID, or figuring out why the renderer is stuck.
2. **Ignoring the `SharedGridSet` lock:**
   * *Counterargument:* The other bug report proved `__ulock_wait2` was in `SharedGridSet.ref`. The plan author asserts it's in `reconcileAttachedWindowIfNeeded` (`attachSurface + 372`). Both are called from `attachSurface`. Fixing one without the other leaves the app just as vulnerable to hangs when attaching a *new* surface.

### Hindsight Preview
Two years from now, we'll look back and realize:
* "We memoized the display ID to fix a symptom, but we left a massive SwiftUI layout thrash in the codebase."
* "We didn't fix the font grid lock contention, so power-users with 20+ terminals still got beachballs."
* "We added a log-and-drop to a core IPC queue, which led to months of 'terminal occasionally stops updating' bug reports because the display link message got dropped."

### Reality Stress Test
1. **Competitor/User Behavior:** A user opens 30 agents (heavy font cache thrashing).
2. **SwiftUI Quirks:** A macOS update slightly changes `ScrollViewReader` behavior, causing 100 preference updates per layout instead of 10.
3. **Result:** The mailbox doesn't fill up anymore (thanks to memoization), but the app still beachballs for 3 seconds because SwiftUI is evaluating 30 `TabItemView`s 100 times, and when they try to open the 31st terminal, it deadlocks completely on `SharedGridSet.ref`.

### The Uncomfortable Truths
* The plan author read `hang.log` and found a different deadlock than the one in the Sentry issue and the `BUG-` ticket, and assumed they are all the same thing.
* The tab bar is likely still broken and slow. We are just unblocking the main thread from a side effect of its slowness.
* The Zig fix (push `.instant` and drop) is a band-aid. If a core thread's mailbox fills up, the system is already failing.

### Hard Questions for the Plan Author
1. How do you reconcile your finding (`attachSurface + 372` -> mailbox full) with the `sample` data from `BUG-main-thread-deadlock-attachSurface.md` which proved pid 6063 was blocked in `SharedGridSet.ref` (`attachToView` -> `ghostty_surface_new`)? Did pid 6063 hit *both* deadlocks, and if so, why does this plan only fix one?
2. If the renderer thread is wedged on the font rwlock (as the other ticket proves), how will `surface.renderer_thread.wakeup.notify()` make it drain the mailbox?
3. Why is `updateNSView` firing 64+ times before the renderer can drain it? Aren't we just masking a catastrophic SwiftUI layout loop?
4. If the Zig `.instant` push drops a *legitimate* display ID change (e.g., window moved to another monitor) because the renderer is momentarily busy, does vsync permanently break for that surface?
5. The original ticket (C11-191) reports a ~2.3s hang, while your hang.log shows a 13-hour wedge. Are you sure you are fixing the 2.3s Sentry issue, or did you just find a different permanent wedge and assume they are the same?
