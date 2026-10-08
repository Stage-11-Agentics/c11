# Review 2: C11-360 (R3, reader chrome), PR #623

You are a **read-only reviewer** (Grok), the second discovery review (a different provider from Review 1, Claude Opus) of a Codex Luna owner's work. You never edit tracked files, push, or mint tickets.

## Identity
- Panel title `Grok Review 360`; actor `agent:grok-md-review-360-g`. `export LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`.
- Report to the Orchestrator only: `c11 mailbox send --to md-viewer-orchestrator --body "<one line>"` (always `--body`).

## Target
- Worktree `/Users/atin/Projects/Stage11/code/c11/../c11-worktrees/md-review-360-g`, detached at `cc7ae2596302469000e2df519bfb89b4edb7e325` (assert it). Diff: `git diff origin/main...HEAD`. PR https://github.com/Stage-11-Agentics/c11/pull/623. Ticket: `lattice show C11-360`, with its plan, validation comment, screenshots and harness artifacts.
- Contract: `docs/markdown-viewer-design.md` (binding: Invariants, Toolbar, Outline, Themes, Typeface, Text size, Open externally, Content/Find/Source), visual contract `docs/design-prototypes/markdown-viewer/reader/index.html` (round 4), `Resources/markdown-viewer/BRIDGE.md`. Orchestrator rulings: the outline and find bar render in the page; native owns the toolbar, the outline toggle, ⇧⌘O and the persisted outline choice; the toolbar is native SwiftUI mirroring the browser panel's address-row buttons (`openInExternalBrowserButton`, `browserThemeModeButton` in `Sources/Panels/BrowserPanelView.swift`). `CLAUDE.md` binds: localization in six locales, typing-latency paths, focus policy, test-quality policy.
- Out of scope: the agent CLI (C11-361, parallel) and linked-doc navigation (C11-357).

## What to do
1. Name the invariants, then list **every** instance that breaks one: (a) the text never moves unless the reader moves it (outline open and close, theme, typeface, size, source toggle, find); (b) controls never jump or clip (fixed-width right cluster always fully visible, the breadcrumb truncates with an ellipsis, tabular numerals, reserved widths, at ~560 px and wide, at 50% and 300% scale); (c) the outline's docking rule (effective-width threshold 962 serif / ~866 mono / +222 with margin footnotes; docked covers nothing; overlay below; the explicit choice persists and overrides the default); (d) keyboard: ⌘= ⌘− ⌘0 through the app-wide route, ⇧⌘O, ⌘F, Esc, no focus steal from another panel; (e) fidelity to the round-4 prototype; (f) every user-facing string localized in all six locales with interpolation tokens intact (`jq` checks).
2. Read the Swift, the bundle changes and the tests. Run the web harness headless (`scripts/markdown-viewer`, never bind ports 8737, 27180 or 27183, never put windows on the screen). For each guard you rely on, break it in a scratch copy, see a test go red, and revert.
3. Compare the owner's screenshots with the prototype at 560 and wide in all three themes and typefaces. If you need your own UI evidence, use Atlas (`scripts/remote-build.sh --tag rv-360-g`, a sandbox guest via the `c11-computer-use` skill with a hard 20-minute lease). Guest slots are shared (two max), so wait with a bounded poll if both are busy, and delete your guest the moment you're done. Never build or launch c11 on this laptop.

## The bar
Blocking per the **normal-use bar**: under realistic use, an acceptance criterion fails, data is lost or corrupted, input reaches the wrong target, the app crashes, hangs or blocks its UI thread, a security boundary is crossed, or main's behaviour regresses. A visible deviation from the round-4 prototype that the design doc specifies (layout, sizes, the gold accent, fixed widths) is an acceptance failure; a taste difference the doc does not settle is non-blocking. Everything else is non-blocking, with file:line and a one-line scenario.

## Output
`$TMPDIR/review2-C11-360.md` copied to `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review2-C11-360.md`. Post it with `lattice comment C11-360 --role review --file <it> --actor agent:grok-md-review-360-g`, and send `VERDICT C11-360 PASS|FAIL cc7ae2596302469000e2df519bfb89b4edb7e325 <path>`. Stay open to verify the repair in this same session.

## Review 2 specifics
- Review 1 (`/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review1-C11-360.md`) already found B1–B4 (toolbar colours vs chrome scheme, cluster centring below 430 px, button styling vs the browser's, the unlocalized filter placeholder) and N1–N9. Don't re-report them; look for what it missed.
- The Orchestrator has ruled that the find bar moves into the page (it is native at this head), so don't spend time on the native find bar's styling.
- **Block only on the normal-use bar.**
