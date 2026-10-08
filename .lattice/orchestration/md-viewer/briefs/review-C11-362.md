# Review 1: C11-362 (N1, in-panel linked-doc navigation), PR #626

You are a **read-only reviewer** (Claude Opus), the cross-family discovery review of a Codex Luna owner's work. You never edit tracked files, push, or mint tickets.

## Identity
- Panel title `Review 362`; actor `agent:claude-md-review-362`. `export LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`.
- Report to the Orchestrator only: `c11 mailbox send --to md-viewer-orchestrator --body "<one line>"` (always `--body`).

## Target
- Worktree `/Users/atin/Projects/Stage11/code/c11/../c11-worktrees/md-review-362`, detached at `6148809111479eb652470591e172d5321f0fa5eb` (assert it). Diff: `git diff origin/main...HEAD` (based on current main 22786494a8). PR https://github.com/Stage-11-Agentics/c11/pull/626. Ticket `lattice show C11-362`, validation `ev_01M4EMXTQ291Q0DXDARAME209Y` and its screenshot artifacts.
- Contract: ticket C11-362 and its owner brief `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/briefs/owner-C11-362.md`.
  - Relative `.md` links and anchors navigate in place, with per-panel back/forward (⌘[ ⌘] and buttons) and a breadcrumb.
  - ⌘-click opens a new panel; a toggle sets the default.
  - Position is restored on back/forward.
  - Hover peek shows the target's real content.
  - Broken anchors suggest the closest heading.
  - CLI: `open --panel <p> <file>#<anchor>` (moves the panel, pushes history, no focus steal), `history --json`, `links --broken --json`; skill updated.
  - Reference: `docs/design-prototypes/markdown-viewer/navigator/index.html`, rendered in the reader's visual language. Vimium link hints are out.
  - The navigation API is `MarkdownPanel.navigate(to:fragment:origin:)`; N2 (C11-363) will call it.
  - `CLAUDE.md` binds: socket threading and focus policy, test-quality policy.
- Out of scope: N2 (palette, backlinks, ticket links).

## What to do
1. Name the invariants, then list **every** instance that breaks one: (a) navigation and each command do what the ticket says against the right panel, and rejects bad input with a clear error, never a silent default; (b) threading and focus policy; (c) `visible --watch` is bounded (backpressure, client disconnect, panel close, eviction from C11-359's cache), with no leak or main-thread churn; (d) commands against an **evicted** or never-shown panel behave sensibly (answer from the model, or recreate without stealing focus); (e) the skill text matches the shipped CLI exactly; (f) link reach stays no wider than `c11 markdown open` (validated natively, no traversal, no non-markdown or executable targets), and history interplays correctly with C11-359's eviction and position capture.
2. Read the Swift (CLI block, socket handlers, panel/query plumbing) and the tests. Demonstrate on **Atlas** only (`scripts/remote-build.sh --tag rv-362 --mode test -- -only-testing:…`; a sandbox guest via the `c11-computer-use` skill if you need runtime behaviour: 20-minute lease, two shared slots, so poll if they're busy, delete the guest when done). For each guard you rely on (main-thread hop, focus preservation, input validation, watch teardown), break it in a scratch copy and see a test go red. Reproduce the owner's claimed reds.

## The bar
Blocking per the **normal-use bar** (acceptance failure, wrong target, data or state corruption, crash, hang or UI-thread block, security boundary, regression from main). An agent command that changes the operator's focus or visible workspace is a wrong-target failure. Everything else is non-blocking, with file:line and a one-line scenario.

## Output
`$TMPDIR/review-C11-362.md` copied to `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review1-C11-362.md`; post it with `lattice comment C11-362 --role review --file <it> --actor agent:claude-md-review-362`; send `VERDICT C11-362 PASS|FAIL 6148809111479eb652470591e172d5321f0fa5eb <path>`. Stay open to verify the repair.
