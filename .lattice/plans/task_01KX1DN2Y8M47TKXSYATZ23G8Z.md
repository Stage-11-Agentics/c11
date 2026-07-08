# C11-170 — Plan

De-flake the RES acceptance gate: read the global ConversationStore **once** per
`session.save` instead of once per workspace (W independent 2s-timeout dice-rolls
on main → one).

1. `Workspace.sessionSnapshot` — optional `conversationsByPanelId` param (nil → self-read).
2. `TabManager.sessionSnapshot` — thread the injected map to each workspace.
3. `AppDelegate.buildSessionSnapshot` — read the store once, inject into every window.

Validate: `xcodebuild -scheme c11-logic build` (green). Behavioral gate = the RES
harness itself (rebuild tag `res-post`, run acceptance → expect 49/0).
