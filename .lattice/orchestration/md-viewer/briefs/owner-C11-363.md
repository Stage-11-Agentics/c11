# Owner brief: C11-363 (N2, corpus palette, backlinks, ticket-ID links)

- Ticket **C11-363** (`lattice show C11-363`; parent C11-357). Actor `agent:codex-md-n2`. Panel title `N2 Corpus`.
- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/md-n2-corpus`, branch `md-viewer/C11-363-corpus`.
- Builds on merged C11-358/359/360 and C11-361 (landing now). Its navigation hand-off is C11-362 (N1, `agent:codex-md-n1`), which owns in-panel navigation, history and the navigation API; you call into it, you don't build it.

## What you build
The ticket description:
- **Corpus:** the git repo containing the open file, falling back to its directory; skip `.git`, `node_modules` and build outputs (DerivedData, `build/`, `dist/`, `.build`). Index off-main, bounded, incremental on change.
- **⌘K jump palette** over headings across docs plus file names.
- **Referenced-by backlinks** for the current doc and section.
- **Ticket IDs** (`C11-123`) link only when that repo has a `.lattice/` board, read-only, with a hover card (title, status); plain text otherwise.
- **Agent CLI** if the design implies it (e.g. `c11 markdown backlinks --panel <p> --json`), with the skill updated in the same PR.

Reference: `docs/design-prototypes/markdown-viewer/navigator/index.html` (round 1), rendered in the reader's visual language from C11-336.

## Seam with N1
Selecting a palette result or a backlink navigates the panel. N1 exposes that as a native call (e.g. `MarkdownPanel.navigate(to: URL, anchor:)` that pushes history). Agree the exact signature with the Orchestrator before you rely on it. Until N1 lands, call a minimal shim you own (opening via the existing link routing), and switch to N1's API when it merges.

## Proof
Behavioural tests for corpus bounds (skip lists, size caps, a repo vs a plain directory), the index's incremental update, ticket-ID linking on and off `.lattice/` repos, and the CLI through the socket seam. An Atlas tagged build (`--tag md-363`), computer use: ⌘K over this repo's docs, backlinks for `docs/c11-mailbox-guide.md`, a ticket-ID hover card, and a non-repo directory.

## Review track
Review 1 Claude Opus (Review 2 per the Orchestrator's call).
