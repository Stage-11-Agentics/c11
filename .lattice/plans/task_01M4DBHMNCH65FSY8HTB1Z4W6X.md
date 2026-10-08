# C11-362 implementation plan

Base: `origin/main` at `22786494a86a2d32ab7cddc901b8464e139333e0`, with C11-360 merged as `bdb91b1e12a9270e66592923acb46dbabafb5905` and C11-361 merged as `22786494a86a2d32ab7cddc901b8464e139333e0`.

## Shared navigation API proposal

Expose `@MainActor @discardableResult func MarkdownPanel.navigate(to fileURL: URL, fragment: String?, origin: MarkdownNavigationOrigin) async -> MarkdownNavigationOutcome`. `MarkdownNavigationOrigin` distinguishes document links, explicit CLI opens, palette selections, and backlinks. N2 calls it with `.palette` or `.backlink`; N1 centralizes target validation, in-panel history, position restore, and result reporting. The call never selects a workspace or activates a window.

## Architecture and cut line

- Keep a transient history stack and cursor on each `MarkdownPanel`. Entries contain canonical file URL, optional fragment, and optional `MarkdownReadingPosition`. Capture the current position at navigation boundaries; pushing truncates the forward branch. Back/forward restores a visited entry's line, offset, source mode and find state; a first visit loads the target and then jumps to its fragment. Do not persist the stack or introduce a content cache.
- Add one model navigation path that reads/validates a target off-main, safely rebinds the existing panel's path/title/file watcher, and loads through the current renderer without replacing panel identity, selecting a workspace, or stealing focus. Keep unqualified `markdown open <path>` creation behavior. `markdown open --panel <p> <path>#<anchor>` targets an existing Markdown panel; keep the area/pane creation route explicit. Add `markdown.history` and `markdown.links` worker methods alongside the in-place open route.
- Extend the C11-360 bridge and native link handler. Its page currently posts `type:link` before locally scrolling same-document anchors and displaying the return pill. Include the pre-jump `MarkdownReadingPosition` in the anchor event so native history cannot capture the post-jump state; retire or compose the one-step pill with panel back/forward. Cross-document relative Markdown links are validated natively before in-place navigation. Cmd-click opens a new Markdown panel. Add a persisted shared default for same-panel versus new-panel link behavior.
- Keep C11-360's ownership split: `MarkdownReaderToolbar` and toolbar controls stay native; outline tree/filter/scrollspy and find UI/marks stay in the bundled page. Add fixed-width history controls and the mode toggle to the existing toolbar. The page owns peek presentation; native resolves/reads the target section and sends data to the bundled renderer after validation. Broken fragments report a deterministic closest heading and slug.
- Constrain automatic relative navigation, previews, and broken-link scans to the source document's repository root, or its containing document tree without a repository, after symlink resolution. Explicit CLI opens follow the existing explicit-open path policy; do not trust renderer-provided resolved URLs. Keep external HTTP(S)/mailto handling unchanged. Exclude palette/backlinks/ticket links and Vimium hints (C11-363).

## Acceptance to behavioral proof

1. Navigation history: unit-test initial entry, push, branch truncation, back/forward bounds, and position capture/restore. Extend renderer tests for anchor pre-state, first-visit fragments, source/find restoration, and navigation after WebKit eviction.
2. Link mode and toolbar: extend `scripts/markdown-viewer/test.mjs` for local fragment/document dispatch and peek behavior. Atlas computer use drives ⌘[/⌘], toolbar back/forward, both default modes, Cmd-click, breadcrumbs, and narrow/wide layouts; confirm no focus/workspace change.
3. Target policy and broken links: exercise relative targets, missing file/anchor, nearest heading/slug ordering, parent traversal, and symlink escape denial. Verify previews show target-section content without navigation and `links --broken --json` reports stable structured results.
4. CLI and shared API: extend `tests/test_cli_markdown_agent.py` fake-socket tests for in-place `open --panel`, `history --json`, `links --broken --json`, malformed paths/fragments, explicit target requirement, and errors. Atlas scenario opens `docs/c11-mailbox-guide.md` and a relative-link fixture, uses `c11 markdown open --panel … file#anchor`, then confirms history JSON and `c11 tree` still reports the caller's selected workspace.

## Files and constraints

Expected touch set after checking merged APIs: `Sources/Panels/MarkdownPanel.swift`, `MarkdownRendererCache.swift`, `MarkdownWebRenderer.swift`, `MarkdownPanelView.swift`, `Sources/Workspace.swift` or `WorkspaceManager.swift`, `Sources/MarkdownAssetPolicy.swift`, `Sources/SocketHandlers/MarkdownFeedbackHandlers.swift`, `Sources/SocketHandlers/SocketDispatch.swift`, `CLI/c11.swift`, `Resources/markdown-viewer/BRIDGE.md`, `index.html`, `viewer.js`, `viewer.css`, `Resources/Localizable.xcstrings`, `skills/c11-markdown/SKILL.md`, `c11Tests/MarkdownAssetPolicyTests.swift`, new history-model tests, `c11Tests/MarkdownWebRendererTests.swift`, `scripts/markdown-viewer/test.mjs`, and `tests/test_cli_markdown_agent.py`.

Localize only new history/mode/peek/broken-target strings across English, Japanese, Ukrainian, Korean, Simplified Chinese, Traditional Chinese, and Russian. No history work in scroll-state callbacks; file reads/scans stay off-main and WebKit calls remain asynchronous on main. Preserve the current panel/file session snapshot but do not add history persistence. No `DispatchQueue.main.sync`, modal UI, network fetch, or document-supplied script execution. Update `skills/c11-markdown/SKILL.md` with the CLI and reusable API.

Run the page harness locally as the small static Playwright loop; run native and CLI tests plus the tagged app build on Atlas. Reuse only `md-362` for every Atlas build/rebuild. Retrieve logs and attach screenshots before cleaning the Atlas tag and its DerivedData at handoff; if an accidental extra tag is created, retrieve its logs before deleting its `~/c11-builds/<tag>` and `~/Library/Developer/Xcode/DerivedData/c11-<tag>` directories. Computer use runs only in an Atlas sandbox with QA fresh launch and proven dismissal.

## Reset 2026-10-08 by agent:codex-md-n1
