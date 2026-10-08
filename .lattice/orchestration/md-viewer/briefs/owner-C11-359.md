# Owner brief: C11-359 (R2, native markdown panel on WKWebView)

- Read first: `owner-common.md` in this folder (your contract), then this brief.
- Ticket: **C11-359** (`lattice show C11-359`; parent C11-336). Actor: `agent:codex-md-r2`. Panel title: `R2 Native Panel`.
- Worktree: `/Users/atin/Projects/Stage11/code/c11-worktrees/md-r2-panel`, branch `md-viewer/C11-359-native-panel`, base `origin/main`.

## What you build
Everything in the ticket description: `MarkdownPanelView` hosting a WKWebView that loads the bundled renderer through a custom URL scheme handler; security (scoped file access, CSP, no document script, link routing through c11, web view navigation cancelled), the shared process pool and lazy creation, the panel state model + session persistence + last-used defaults + fallbacks, every existing path (open, live reload, drop-to-open, snapshot/restore, focus flash, pointer focus, app-wide zoom keys driving the markdown scale, `markdown.get_content`), removal of MarkdownUI and the Mermaid CLI path, threat notes in `docs/security-threat-model.md`, and the 20-panel memory/creation-time measurement. Minimal interim chrome is fine; the full toolbar is C11-360 (R3), and the agent CLI is C11-361 (R4), both after you.

You also own adding `Resources/markdown-viewer/` to the app bundle (folder reference) in `project.pbxproj`. Expect `xcodeproj`-gem churn if you use it (CLAUDE.md Pitfalls); keep the edit as small as you can.

## Parallel with R1 (C11-358)
C11-358's owner (`agent:codex-md-r1`) is building the web bundle now and will push `Resources/markdown-viewer/BRIDGE.md` first on branch `md-viewer/C11-358-web-renderer`; the Orchestrator sends you `BRIDGE <sha>` when it is up. Until then, build what does not need it: the scheme handler, process pool, lazy creation, state model, persistence, fallbacks, zoom routing, focus paths, removal of MarkdownUI, and a stub page for local wiring. Once it is up, integrate against it; for runtime testing you may merge R1's pushed branch into a **local scratch branch** (never into your ticket branch). Your PR lands after R1 merges: rebase onto origin/main then. A bridge change you need goes to the Orchestrator as `BLOCKED C11-359 bridge change <what> NEXT confirm`.

## Proof
Behavioural tests for the state model, persistence round-trip (including bad values → defaults) and scale routing (`c11-logic` where possible). Atlas tagged build (`--tag md-359`): open `docs/c11-messaging-primitive-design.md` offline with Mermaid; live reload while scrolled mid-document with no drift; quit and relaunch restores scale/theme/typeface/outline (`C11_QA_LAUNCH=resume`); the synthetic hostile fixture does nothing and loads nothing; ⌘= / ⌘− / ⌘0 change the markdown scale and never page-zoom; 20 markdown panels: memory and creation time vs a tagged origin/main build on the same scenario, with load average. Screenshots attached.

## Review track
Large-ticket track (security boundary + architecture): Review 1 is two parallel discovery reviews (Claude Fable and Codex Astra), synthesized and verified by Claude Opus; a post-merge review follows. Stay alive through merge for that loop.
