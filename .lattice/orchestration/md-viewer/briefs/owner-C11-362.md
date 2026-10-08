# Owner brief: C11-362 (N1, in-panel linked-doc navigation)

- Ticket **C11-362** (`lattice show C11-362`; parent C11-357). Actor `agent:codex-md-n1`. Panel title `N1 Navigator`.
- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/md-n1-nav`, branch `md-viewer/C11-362-in-panel-nav`.
- Depends on C11-360 (reader chrome, PR #623 in review) and C11-361 (agent CLI, building). Starts on GO after both merge.

## What you build
The ticket description: relative `.md` links and in-doc anchors open in the same markdown panel with per-panel back/forward history (⌘[ / ⌘], toolbar buttons) and a breadcrumb; ⌘-click opens in a new c11 markdown panel; a toggle sets which is the default; scroll position restored on back/forward; hover peek showing the target section's real content; broken anchors suggest the closest heading; agent CLI `c11 markdown open --panel <p> <file>#<anchor>` (moves an existing panel and pushes history, no focus steal), `c11 markdown history --panel <p> --json`, `c11 markdown links --panel <p> --broken --json`, skill updated in the same PR.

Design reference: `docs/design-prototypes/markdown-viewer/navigator/index.html` (round 1, not iterated with Atin). Render it in the **reader's visual language from C11-336** (the merged toolbar, themes and typefaces), not the navigator prototype's own. Vimium-style link hints are out (decision for this run). Linked-doc navigation stays inside what C11-359 already allows: relative `.md` links resolved and validated natively; keep the link reach no wider than `c11 markdown open` (the run's hardening list notes that confining it to the document's repo or tree is worth considering here; propose it in your plan).

Builds on: the bridge (`Resources/markdown-viewer/BRIDGE.md`, link messages, `scrollToLine(line, offset)`), C11-359's eviction and reading-state capture (history entries should reuse that position capture), C11-360's toolbar (breadcrumb, buttons) and C11-361's `markdown.*` socket methods and CLI block.

## Proof
Behavioural tests for history (push, back, forward, position restore, eviction interplay), link resolution and broken-anchor suggestions, CLI through the socket seam. An Atlas tagged build (`--tag md-362`), computer use: open `docs/c11-mailbox-guide.md` (anchor links) and a doc with relative links, then navigate in place, go back and forward with ⌘[ ⌘] and the buttons, ⌘-click into a new panel, hover peek, a broken-anchor suggestion, and `c11 markdown open --panel … file#anchor` from a terminal into a background panel with no focus steal. Screenshots attached.

## Review track
Normal: Review 1 Claude Opus, Review 2 Grok.
