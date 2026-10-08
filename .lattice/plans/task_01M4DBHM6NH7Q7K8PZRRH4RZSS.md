# C11-358 implementation plan

Deliver the documented bridge first as a standalone commit, then bundle pinned offline libraries and fonts, port the round-4 reader's content CSS/tokens, and implement the renderer engine in Resources/markdown-viewer/. No Swift, project, socket or installed-skill edits. The existing orchestrator owns independent review and merge.

Use markdown-it token maps for source lines and top-level block reconciliation; preserve unchanged DOM nodes, selections and rendered diagrams. Capture a stable block plus within-block source position before reload or layout changes and restore after synchronous layout and every asynchronous diagram/font change. Raw HTML is disabled; document images produce inert placeholders; document links are intercepted and classified for native. Mermaid uses strict security and a second SVG sanitization boundary.

Acceptance maps to a headless disk-loaded Playwright harness: fixtures + messaging doc at 560/820/1200 in light/dark; no network/console errors; sequence entity decoding; tasks/callouts/math/code/footnotes/tables; source/find/outline/progress; node identity/selection; reload and settings anchor stability; hostile HTML/URLs/Mermaid. Capture matching prototype and bundle screenshots at 560/1200 in both themes. Static browser tests are the authorized small local loop; no app launch on Hyperion. Packaged/native proof belongs to R2/final validator since this ticket has no host.

No typing/event hot paths, persistence or native threading changes. Web strings are supplied through bridge settings for native localization, with English defaults. Cut: no diff UI, editing, linked-doc navigation or prototype stage/chrome. Evidence and replay steps go to Lattice; open one draft PR only at handoff. No CI settings changes.

## Reset 2026-10-08 by agent:codex-md-r1
