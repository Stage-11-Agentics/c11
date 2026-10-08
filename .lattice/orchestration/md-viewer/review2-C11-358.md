# Review 2 — C11-358

Verdict: **FAIL**
Head: `2c97338c4c995f6513e9f792bfca825935e9a00a`
Actor: `agent:grok-md-review-358-g`
Scope: web renderer only (Resources/markdown-viewer, scripts/markdown-viewer, THIRD_PARTY_LICENSES.md). No Swift, no pbxproj.

This file records only findings the prior review did not. Mermaid render-id reuse, the DOMPurify `ALLOWED_URI_REGEXP` range, and that review's non-blocking list stay theirs. Their symptoms are still visible here (blank warning and tip icons at 560 and 1200 in both themes; the wide-layout footnote number on its own line). They are not repeated below.

## Invariants

(a) Document content never executes script, never loads anything remote, and never navigates the page. A link click is `preventDefault`'d and posted with the right href, kind, and resolvedURL.

(b) Design invariant 1 (`docs/markdown-viewer-design.md` Invariants, and Content "Source"): the text never moves unless the reader moves it. Live reload, theme, typeface, scale, source toggle, outline, font load, and async Mermaid above the viewport keep the same line in the same place.

(c) Offline. Every library and font is vendored, pinned, and hashed in `vendor/MANIFEST.json`. Licenses are in `THIRD_PARTY_LICENSES.md`. No runtime network.

(d) The bridge matches `Resources/markdown-viewer/BRIDGE.md` (methods, State, units, link kinds, image amendment, anchoring ownership). `scrollToLine(line)` at this head is a 1-based source line with no offset (`BRIDGE.md` Native → page). The offset amendment is on another branch and is not part of this head. It does not excuse a miss of tens of lines.

## Blocking

### 1. Source toggle jumps to the fence start

`Resources/markdown-viewer/viewer.js:244-248` (`capture`), used by `setSourceMode` at `viewer.js:496-505`. Source restore at `viewer.js:252-256` scrolls to `a.line` and applies `dy` only when `a.source` is set. A read-mode capture has `source` unset, so the intra-block offset is dropped on the way into source.

`capture` estimates the line by taking at most 32 characters of the text node under the viewport and running `findIndex` for a source line that includes that string. highlight.js splits a line into short tokens, so the node is often just `const`. That matches the first code line. A plain fence is one text node that contains newlines, so the slice matches no source line and the line stays at `dataset.ls`, the opening fence.

Scenario: the reader is in the middle of a tall code fence and toggles source. They see the first line of the fence, or the opening ```, not the line they were reading. Toggling back to read returns them, because the saved text path still works. The harness source round-trip (`scripts/markdown-viewer/test.mjs:79-81`) parks on a heading, so it stays green.

Evidence, headless, real bundle, viewport 900×700:

- Highlighted fence of 80 `const lineNN` lines. Reader parked on `const line40 = 40;` (viewport top 11.703125 px). Source mode showed line 4 `const line00 = 0;` and line 5 `const line01 = 1;`. Return to read restored 11.703125 px. The file map is line 3 opening fence, line 4 `const line00`, line 44 `const line40`. Jump of about 40 lines.
- Same shape, second measurement: read `visible().lines` first 42 last 77; source top rows were lines 4–6 (`const line00`, `const line01`, `const line02`); source `visible().lines.first` was 4; return matched 29.703125 px.
- Plain (unhighlighted) fence: source top was line 3, text `` ``` ``. Read position 29.703125 px before and after.

Fix: map a character offset inside the code or paragraph to a source line by counting newlines, or by a snippet that includes neighboring tokens, not one highlight.js text node. Apply `dy` on the way into source. Add a harness case that parks inside a tall fence and asserts the source row.

### 2. `scrollToLine` in read mode scrolls to the block, not the line

`Resources/markdown-viewer/viewer.js:506-509`. In read mode the target is the block whose `dataset.ls`/`dataset.le` contains the line, and `scrollTop` is `topIn` of that block. A code fence is one block. Source mode has a row per line and would land correctly. `BRIDGE.md` specifies a 1-based source line. An agent or the native host that asks for a line inside a fence is taken to the fence start. The action reaches the wrong target.

Evidence, same session, read mode forced after load:

`c11md.scrollToLine(50)` on

```
# Code

```javascript
const line00 = 0;
...
const line79 = 79;
```
```

returned `{mode:"read", lines:{first:3, last:37, total:87}, scrollTop:95}` with the viewport top on the code chrome, not on a code line. File line 50 is `const line46`. The visible range ends at line 37, so the requested line is off screen. An earlier on-screen reading was source mode left over from the previous call and is discarded.

Fix: inside the block, map the source line through the rendered text (newline count, or a line map stored at render) and scroll that range to the top. Do not stop at the block element. Cover it in the harness: `scrollToLine` of an interior fence line must put that line at the top of the scroller.

## Non-blocking

1. Frontmatter is a raw blob. `viewer.js:177` sets `textContent` on a `div.frontmatter`. `viewer.css:117-119` is a `dt`/`dd` grid, so the whole `title: …` / `status: …` string sits in the first column. The design Content section does not mention frontmatter. The harness only counts `.frontmatter`.

2. Identical top-level blocks share a signature. `viewer.js:130` drops `map`, `level`, and `block` before JSON. `reconcile` (`viewer.js:171-198`) then shifts previous nodes FIFO. Editing the first of two identical flowcharts discarded the second SVG node (`keptSecond: false`) and re-rendered it. The heading below moved 17.96875 → 17.4375 px (−0.531 px). Both SVGs were present and there was no diagram error. Position held. A later unchanged copy is still recreated.

3. An empty link `[empty]()` is classified `local` and posts the current document URL (`viewer.js:121`). The click reports a file open of the document already on screen.

4. A GitHub callout with a custom title, `[!WARNING] Watch out`, renders the title slot as `warning` and leaves `Watch out` in the body (`viewer.js:33-43` and `:83`). The text is not dropped. The Content section only names `> [!NOTE]`.

## Demonstrated

Pinned head, unmutated tree, headless shell 1234, no window, no bound port:

- `npm --prefix scripts/markdown-viewer test -- --screenshots`: 14/14 PASS, zero console errors, zero network requests.
- `vendor/MANIFEST.json`: 95 files, 0 SHA-256 mismatches, computed offline. `vendor/fonts.css` has no `http` URLs. Package pins match the vendoring script (markdown-it 15.0.2, mermaid 11.12.0, DOMPurify 3.4.16, highlight.js 11.12.0, KaTeX 0.19.0).
- Side-by-side screenshots at 560 and 1200, light and dark, against the round-4 prototype. Body size, measure, callout color, inline code, and hyphenation match the Content section (16.5 px and hyphens at narrow; 17.5 px and manual hyphens at wide; a 3-column table reflows only at narrow). Scale 2 at 1200 px reports effective width 600 and the narrow size, font 33 px. The missing toolbar, reading-stats line, and outline rail are prototype chrome this ticket does not own. The empty wide gutter is the outline dock reservation (`paddingLeft` 300 px at 1200).

Temporary edits, each reverted. After every run `git rev-parse HEAD` was `2c97338c4c995f6513e9f792bfca825935e9a00a` and `git status --porcelain` was empty. Screenshot scenario omitted on these runs (13 scenarios):

- `restore()` returns immediately. Red: `anchor drift 560: 17.96875 -> 59.859375` at `test.mjs:71`. Same assertion the owner recorded.
- `MarkdownIt` `html:true`. Red at `test.mjs:112`: hostile node count 1, expected 0.
- `sanitize()` returns the HTML unchanged. Still 13/13 green. `html:false` is what the hostile case actually proves. Already recorded by the prior review.
- `preventDefault` removed in `handleClick`. Red at `test.mjs:127`: the remote link click left the document and the page URL became `chrome-error://chromewebdata/`.
- `assetURL` returns the raw `src`. Red at `test.mjs:112`: hostile image count 4, expected 0.
- CSP meta removed from `index.html`. Still 13/13 green, zero console errors, zero network requests. Already recorded by the prior review.

The two blocking bugs are also uncaught by the green suite. It never parks inside a tall fence, and it never calls `scrollToLine` on an interior fence line.

Other headless checks at this head, not new findings: a unique paragraph selection survived an edit above it (top 236.96875 px both sides, selection `Beta`). A sequence-diagram `link` to `javascript:` rendered as SVG text with zero anchors. Ten traversal, remote, data, and absolute image URLs were rejected; four in-tree URLs rewrote to `c11md-asset://doc/…`. No new remote load and no page navigation from a middle-click or a hash.

## Repair check

Verification of the repair should show, on the repaired head: source toggle from the middle of a highlighted fence and from a plain fence lands on that source line; `scrollToLine` of an interior fence line puts that line at the top in read mode; the existing anchor, hostile, link, and image cases stay green; the two new cases are in the harness.
