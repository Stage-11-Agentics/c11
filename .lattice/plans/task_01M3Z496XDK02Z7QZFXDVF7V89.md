# C11-324: Keep a background browser tab running without showing it

## Why
Agents proving browser features (pollers, timers, video, rAF) need the page running. A browser tab in a background workspace is hidden: the portal container is set `isHidden` (`Sources/BrowserWindowPortal.swift:3928-3938`) and the panel is throttled (`Sources/Panels/BrowserPanel.swift:3131-3134`). So the page likely sees `document.hidden = true`, with timers and media paused. That pushed the LAT-365 agent to switch Atin's workspace to keep its page visible (2026-10-02). Once agents can't switch workspaces, they need a way to keep a background browser running.

## Scope
Let an agent keep a browser tab running while its workspace is hidden. For example, a per-tab `keep-live` option (`c11 browser <s> keep-live on|off`) that keeps the WKWebView unoccluded or hosted off screen, and reports `document.visibilityState` as visible. Precedent: the invisible bootstrap window for hidden terminals (C11-114, `Sources/GhosttyTerminalView.swift:2910-2929`). Take snapshots of a kept-live page while it is in the background.

Out: anything that changes the operator's visible workspace.

## Acceptance
A browser tab in a background workspace with keep-live on keeps its timers running, reports `document.hidden === false`, plays video, and returns a non-blank `browser snapshot`. The operator's workspace never changes. Turning keep-live off restores normal throttling.
