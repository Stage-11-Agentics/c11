# Repair brief 1, addendum: C11-360 Review 2 (Grok), FAIL at cc7ae25963

The full review is at `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review2-C11-360.md`. This is the last addendum. Fold it in, then push once.

## Blocking
- **B5** In source mode a docked outline covers the line numbers and the first ~218 px of every line: only `#layout` gets the dock gutter, not `#srcScroller`. Give the source scroller the same gutter (reserved whether or not the outline is open, so closing it doesn't shift source lines), and add a harness case: docked outline plus source mode, where `elementFromPoint` at the first line's number and text start hits the source row, not the outline.

## Repair in place (small, related)
- **N10** Typing in the outline filter drops the scrollspy mark: call `updateOutlineActive(true)` at the end of `renderOutlineList`.
- **N11** At 300% the filter glyphs clip: size the header and input from the scale.
- **N12** Store the outline's explicit choice as a boolean or `"auto"` correctly in the snapshot (`MarkdownWebRenderer.swift:397`).
- **N13** Goes away with the in-page find bar (the native field is removed); make sure the in-page field never repaints a stale query.

Then push once, refresh the validation comment (include both reviewers' repair checks), and send `HANDOFF C11-360 REVIEW <head> …`.
