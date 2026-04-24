# C11-16: Runtime-detect Full Disk Access grant and auto-continue the TCC primer

Follow-up to **C11-15**. After C11-15 ships, the TCC primer shows as a first-run sheet with Full Disk Access as the primary CTA. Clicking that button opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` — the user drops c11 into the FDA list, toggles it on, and returns to the app. But the primer is still sitting there in "click Continue" state.

Goal: when the user grants FDA while the primer is up, detect it and auto-advance.

## Approach sketches

- **Probe the filesystem.** On an interval (e.g., 1 Hz while the primer is visible), try reading a protected file c11 would otherwise be blocked from. If it succeeds, FDA is granted.
- **NSWorkspace activation notification.** When the app re-activates after the user visits Settings, run the probe once.
- **Observe TCC directly.** `tccutil` is user-space and audited; no official notification for grants. Probe is more portable.

The visible UX after detection: a short "Thanks — Full Disk Access granted. Continuing…" state, then dismissal and shell spawn.

## Risks / watch-outs

- Avoid hammering the filesystem probe (backoff).
- Don't block the main thread; the probe lives on a background queue.
- Respect the user's "Continue without it" path — auto-advance should not steal focus from a user mid-click on the secondary button.
