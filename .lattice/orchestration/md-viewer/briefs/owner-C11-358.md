# Owner brief: C11-358 (R1, bundled web renderer)

- Read first: `owner-common.md` in this folder (your contract), then this brief.
- Ticket: **C11-358** (`lattice show C11-358`; parent C11-336). Actor: `agent:codex-md-r1`. Panel title: `R1 Web Renderer`.
- Worktree: `/Users/atin/Projects/Stage11/code/c11-worktrees/md-r1-renderer`, branch `md-viewer/C11-358-web-renderer`, base `origin/main`.

## What you build
Everything in the ticket description: the web side of the renderer as bundled resources under `Resources/markdown-viewer/` (vendored libraries + fonts, the render pipeline, content features, the theme registry and typefaces, scroll anchoring, incremental block re-render, the outline/progress/find/source engine, sanitization, the bridge). Reproduce the reader prototype's content rendering faithfully (`docs/design-prototypes/markdown-viewer/reader/index.html`, round 4): typography, spacing, both themes, tables, Mermaid, code, footnotes, callouts. Its CDN script tags become vendored, pinned files.

**No Swift and no `project.pbxproj` edits.** C11-359 (R2, a parallel Sol owner) adds the folder to the app bundle and hosts it in WKWebView. Your page must work when served from a custom URL scheme rooted at `Resources/markdown-viewer/` (relative asset URLs only) and when loaded from disk by your test harness.

## The bridge comes first (time-critical)
R2 is building the native side right now against your bridge. Within your first ~30 minutes, before anything else:
1. Write `Resources/markdown-viewer/BRIDGE.md`: the JS API object native calls (proposal: `window.c11md` with `load({markdown, documentPath, baseURL, revision})` for first load and live reload, `setSettings({theme, typeface, scale, outlineOpen})`, `scrollToHeading`, `visible()`, `find`/`findNext`/`findPrevious`/`findClose`, `setSourceMode`, plus outline/progress queries) and the messages the page posts to native via `window.webkit.messageHandlers.c11md` (proposal: `ready`, `state` (heading path, progress, minutes left, outline tree, find count), `link` (href, resolved kind, modifier keys), `rendered`, `error`). Include payload shapes, units (scale 0.5–3.0, effective width = pane ÷ scale), who owns scroll anchoring (you), and how the page reports a link instead of navigating.
2. Commit it alone, push the branch, and send the Orchestrator: `BRIDGE C11-358 <sha>` (an extra envelope for this run). After that, a bridge change goes to the Orchestrator first as `BLOCKED C11-358 bridge change <what> NEXT confirm`; never change it silently.

## Proof
A hermetic headless Playwright harness (one command, seconds not minutes) that loads the bundle with the repo fixtures in `docs/design-prototypes/markdown-viewer/fixtures/` and `docs/c11-messaging-primitive-design.md`, and asserts: zero console errors; zero network requests; Mermaid renders including the sequence diagram with entity references; scroll-anchor stability across a reload that changes a block above the viewport; settings changes keep the anchor; sanitization (a synthetic hostile fixture with `<script>`, `onerror`, `javascript:` links and a remote image does nothing and loads nothing); at 560/820/1200 px in each theme. Screenshots side by side with the prototype at 560 and 1200 px, both themes, attached to the ticket. Wire the harness into an existing Ubuntu CI job only if one fits cleanly; never add a macOS job.

## Review track
Normal: Review 1 Claude Opus, Review 2 Grok.
