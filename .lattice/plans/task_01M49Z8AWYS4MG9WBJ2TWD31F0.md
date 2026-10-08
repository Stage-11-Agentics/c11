# C11-349: Emit app foreground, screen-lock and sleep events so foreground time is measurable

## Why
c11 cannot say how long it was in the foreground. A 5.5-day 0.67 session (1,208 tabs, 110 peak open) was analyzed post hoc on 2026-10-06. Foreground time was unrecoverable: the event log has no app activation or screen-lock signal, and macOS Screen Time is TCC-protected. The best proxy, clustered workspace switches, gave only a lower bound (88 bursts, about 37 h). `last_seen_at` and `c11 history` (1.0) already compute "c11 frontmost, screen unlocked" internally but never emit the edges.

## Deliverable
Add operator-presence events to the event log, driven entirely by notifications c11 already observes or can observe for free:
- `app.activated` / `app.deactivated` (NSApplication didBecomeActive / didResignActive)
- `screen.locked` / `screen.unlocked` (the session resign/become-active notifications, plus the distributed screen-lock notifications)
- `system.sleep` / `system.wake` (NSWorkspace willSleep / didWake)
- `window.occlusion` with `{window_id, visible}` on occlusion-state change, if it is already observed for App Nap handling

Payloads are structural only. Update the envelope schema, `references/events.md`, and the skill, then sync installed skills.

## Performance constraint (hard)
Notification-driven only, with no timers and no polling. Each event goes through the existing EventLog serial queue, so emission is off-main and non-blocking. Nothing touches the typing path, `hitTest`, or `forceRefresh`. Expected volume is tens of events a day.

## Acceptance
1. A real tagged build switched away from and back to c11, then locked and unlocked, writes the paired events in seq order.
2. An offline consumer can compute foreground hours for an instance from the log alone. Add a small helper or `c11 report` section (see the report ticket).
3. A test through the real EventLog path, not a source-text assertion.
