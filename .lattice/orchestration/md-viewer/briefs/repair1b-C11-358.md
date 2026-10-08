# Repair brief 1, addendum: C11-358 Review 2 (Grok), FAIL at 2c97338c4c

The full review is at `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review2-C11-358.md`. Add these to the repair you're doing now. This is the last addendum; push once when everything is in.

## Blocking
- **G1, source toggle jumps to the fence start** (`viewer.js:244-256`, `:496-505`). `capture` matches a ≤32-character text-node slice against source lines, so a highlight.js token (`const`) matches the fence's first line, and a plain multi-line fence matches nothing and falls back to `dataset.ls`. The `dy` offset is dropped going into source. Map position inside a block to a source line by counting newlines in the rendered text up to the caret, or by a line map stored at render. Apply the offset both ways.
- **G2, `scrollToLine` in read mode lands on the block, not the line** (`viewer.js:506-509`). Inside a multi-line block (a code fence especially; a long paragraph or list too), map the line through the rendered text and put that line at the top. This is the same mapping G1 needs, so build it once. The bridge v1.1 offset (`lines.offset`, `scrollToLine(line, offset)`) must use the same line semantics, because C11-359's eviction restore depends on it.
- Harness, each red before the fix: park inside a tall highlighted fence and inside a plain fence, toggle source, and land on that line; `scrollToLine` of an interior fence line puts that line at the top in read mode; capture `visible().lines` plus offset inside a fence, reload fresh, `scrollToLine(line, offset)`, and get the same line within 1 px.

## Repair in place (small, related)
- **Non-blocking #1:** render frontmatter as the `dt`/`dd` grid the CSS expects, one key per row, inert text. You're already in the frontmatter code for Review 1's #13.
- **#3:** an empty link `[x]()` posts nothing, or is `blocked`, never the current document.
- **#4:** `> [!WARNING] Watch out` uses `Watch out` as the callout title.
- **#2** (identical-block signatures) goes to the hardening ticket unless the fix falls out of your G1/G2 line-map work.

Then rebase in the side-branch offset commits, push once, refresh the validation comment (including both reviewers' repair checks), and send `HANDOFF C11-358 REVIEW <new head> …`. Both reviewers verify their own findings on that head.
