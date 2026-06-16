# C11-135: DevTools attach exposes stale orphan terminal behind browser portal; attach() lands detached

Observed during C11-133 validation on a tagged build (2026-06-12, tag c11-133, evidence in notes/browser-freeze-triage-20260612/).

Two related observations:
1. Toggling DevTools on a portal-hosted browser pane calls _WKInspector.attach() on first reveal (BrowserPanel.prepareDeveloperToolsForRevealIfNeeded), but on the current WebKit build the inspector ALWAYS opens as a detached window; the attach attempt transiently shrinks the page webview.
2. During that transient shrink, the exposed region rendered a STALE ORPHAN TERMINAL hosted view from the previously-selected workspace (screenshot captured at 18:41Z). Portal log showed terminal-portal entries with sync.skip.orphan ... visibleInUI=1 frame=<exactly the exposed region> reason=missingAnchorOrWindow — workspace switching leaves prior-workspace terminal hosted views visible-but-orphaned, normally covered by the browser portal above. Any geometry change that uncovers them (inspector attach, page resize) paints stale terminal content inside a browser pane.

Repro shape: tagged build with C11_PORTAL_DEBUG=1, two workspaces (one with terminals), switch to the browser workspace, toggle DevTools on a browser pane, watch the carved region + sync.skip.orphan lines.

Related: C11-132 (browser portal geometry sync), C11-133 (divider hit-test cache) — found during their validation; independent deliverable.
