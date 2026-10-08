# Review C11-358 (R1 bundled web renderer), PR #620

**Verdict: FAIL** at head `2c97338c4c995f6513e9f792bfca825935e9a00a`
Reviewer: agent:claude-md-review-358 (Claude Opus, cross-family discovery review). Read-only; every experiment ran in a scratch copy outside the repo, and the worktree was checked pristine after each one.

Two blocking findings. Both reproduce deterministically and pass the owner's harness unchanged, so the harness cannot see either one. Each has a small fix that I proved in scratch.

## Invariants checked

- **(a) Untrusted content is inert.** It never executes script, never loads anything remote and never navigates the page. Links are posted to native and reach the right target.
- **(b) The text never moves unless the reader moves it.** That covers reload, theme, typeface, scale, outline, source toggle, an async Mermaid render above the viewport, and OS appearance flips in system mode (design doc, Invariants 1).
- **(c) Offline.** Every asset is vendored, pinned and hashed, with license notices.
- **(d) The bridge behaves as BRIDGE.md says,** and the content renders per the design doc's Content section (math via KaTeX, GitHub callouts, footnotes, Mermaid, code with copy).

## Blocking findings

### B1. Changing the theme with a diagram above the reader moves the text by the diagram's height (invariant b)

- **Where:** `Resources/markdown-viewer/viewer.js:365` (`const id='c11md-'+generation+'-'+n`), with `:363-369`. Triggered from `setSettings` (`:479`, `supersedes=false`, so the generation is reused) and from the system-appearance listener (`:565`).
- **Scenario:** The operator is reading below one or more Mermaid diagrams and switches light/dark, or the OS appearance flips while the theme is `system`. Every diagram re-renders with the same id it got at load. Mermaid's `render()` begins with `removeExistingElements`, which calls `document.getElementById(id)?.remove()` (see `node_modules/mermaid/dist/mermaid.core.mjs`). That deletes the live SVG out of the article before the async render. The column collapses under the reader, and `capture()` (`:369`) then records the collapsed position as the anchor. The jump becomes permanent.
- **Evidence:** A doc with two small flowcharts above `long` (60 sections), scrolled into Section 30, then `setSettings({theme:'light'})` from dark. The witness character moved **−1394 px**, and sampled positions swung between −1576 and −182 during the render. The result is identical on repeated runs.
- **Mutation proof:** Making the id unique per render call (`…+'-'+(++counter)`) gives drift **0** and no transient movement. Reverting brings back −1394.
- **Test gap:** The harness's settings-anchor loop uses `long` with no diagram, and the async-diagram scenario only changes content through `load`. Neither path re-renders an existing diagram with the same id.
- **Fix direction:** Give each `mermaid.render` call a unique id (a monotonic counter), or never let a render id equal an id present in the article. Add a harness scenario: a diagram above the viewport, then a theme change and an `osAppearance` flip, asserting a witness row stays within 1 px.

### B2. The custom DOMPurify `ALLOWED_URI_REGEXP` strips hrefs and SVG paths: links reach the wrong target, `\sqrt` loses its radical, callout icons are blank (invariants a and d)

- **Where:** `Resources/markdown-viewer/viewer.js:145`, which has `[a-z+.-]+(?:[^a-z+.-:]|$)`. Inside the negated class, `.-:` is a **range** from `.` to `:` and includes `/0-9:`. DOMPurify tests every allowed attribute that is not URI-safe against this regexp. So any value that starts with letters followed directly by a digit fails and the attribute is removed. DOMPurify's own default escapes the hyphen (`[^a-z+.\-:]`).
- **Impact, all reproduced:**
  1. **Links:** `[design](c11-messaging-primitive-design.md)`, `[v2](v2.md)` and `[sub](docs/c11/x.md)` render as `<a>` with **no href**. Clicking one posts `{type:"link", href:"", kind:"local", resolvedURL:"file:///synthetic/u.md"}`, so native receives the *current document* instead of the target. (`adr-0001.md` and `notes.md` survive.) Links shaped like `c11-*.md` are everywhere in this repo's own docs.
  2. **Math:** every KaTeX SVG `<path d="M95,702…">` loses `d`. `$\sqrt{2}$` renders as a bare "2" (`$TMPDIR/review-358-shots/katex-sqrt-head.png`). `\overrightarrow`, stretchy delimiters and the rest of KaTeX's SVG glyphs blank out the same way. This changes the meaning of the content.
  3. **Callouts:** the warning, tip, important and caution icons lose `d` and render blank. Only `note` survives, because it uses a `<circle>`. This is visible in the owner's own comparison PNGs against the prototype.
- **Mutation proof:** I escaped the hyphen in both classes (`[a-z+.\-]+(?:[^a-z+.\-:]|$)`). All hrefs survive and the click posts `href:"c11-messaging-primitive-design.md"` with the right `resolvedURL`. KaTeX paths have `d`, and the icons render. `javascript:` and `data:` stay blocked, and the full harness stays green. The head harness is also green, so nothing covers this.
- **Fix direction:** Escape the hyphen, or drop the custom regexp and enforce the scheme allowlist in a DOMPurify `uponSanitizeAttribute` hook limited to `href`/`src`. Add assertions for: a link to `c11-x.md` keeps its href and posts it; `.katex svg path[d]` exists for `\sqrt{2}`; a callout title SVG path has `d`.

## Non-blocking (for the hardening ticket)

1. `test.mjs`: **guards no test catches.** The harness stayed GREEN with each of these mutated off:
   - CSP meta removed;
   - Mermaid directive refusal (`viewer.js:345`) off;
   - `securityLevel:'loose'`;
   - `cleanSVG` DOMPurify pass skipped (`:349`);
   - blocked-link classification collapsed to `external` (`:122`);
   - KaTeX `trust:true` (`:72`);
   - the DOMPurify markdown pass alone (`:143`), where markdown-it `html:false` is the tested layer.

   With all three Mermaid guards off, hostile diagrams emit `javascript:` anchors (click/link directives), and only CSP stops them, which shows up as console errors. Suggest a hostile Mermaid corpus (init directive, frontmatter config, `click … href "javascript:"`, sequence `link`, classDiagram `link`, `<img onerror>` label, `style … url(https://…)`) plus a CSP assertion. At head, all nine of my hostile diagrams were inert.
2. `viewer.js:534`: a click anywhere in `.diagram-stage` returns (to expand) **before** `preventDefault`. If an `<a>` ever survived into a diagram SVG, the page would follow it. Prevent default for any `a` first.
3. `viewer.js:86` vs `:165/:167`: `R.fence` treats any info string whose first word lowercases to `mermaid` as a diagram, but `prepareBlock` matches only `info.trim()==='mermaid'`. For ```` ```Mermaid ```` or ```` ```mermaid title ```` the diagram fails ("could not be rendered"). In a group holding two fences (a list item with ```` ```mermaid title ```` plus ```` ```js ````), the **copy button on the js block copies the Mermaid source**; reproduced.
4. `viewer.js:121`: `[x](//host/share/x.md)` is classified `local` with `resolvedURL:"file://host/share/x.md"`. Native must reject host-bearing file URLs; consider classifying them `blocked`.
5. `viewer.js:102-114`: `![a](%252e%252e/x.png)` becomes `c11md-asset://doc/%252e%252e/x.png`, which is safe only if the native handler decodes exactly once. Note this for C11-359.
6. `viewer.js:345`: the directive guard over-refuses legitimate diagrams. Any label containing `<img`, `<image`, `url(` or `@import`, or a line starting with `---`, fails as "Unsupported diagram directive", for example a diagram that documents HTML or CSS.
7. `viewer.js:313`: the margin note puts its number span before a block `<p>`, so the number sits on its own line. The prototype has it inline (visible in the 1200 px comparisons).
8. `viewer.js:387`: in the wide layout, find skips footnote text, which lives in the margin aside.
9. `viewer.js:471-472`: load re-applies the captured anchor after `await document.fonts.ready`. A reader scroll during that await is undone. This is usually instantaneous.
10. `index.html:5`: `script-src 'self' file:`. `file:` is needed only by the harness. The production host can serve a CSP without it.
11. `vendor.mjs` (`notices`): `THIRD_PARTY_LICENSES.md` includes notices for dev-only tooling (esbuild, playwright, playwright-core) that never ships. This over-includes but is harmless.
12. `viewer.js:271`: `hold()` is dead code. `viewer.js:328`: Mermaid's `secure` list drops the default `suppressErrorRendering`, which is moot while directives are refused.
13. `viewer.js:126`: a document that begins with a `---` thematic break and has another `---` later is eaten as frontmatter.

## What I demonstrated

- **Owner's suite at head:** 14/14 PASS with `--screenshots` (headless shell 1234, no ports, no windows). Zero console errors, zero network requests.
- **Owner's claimed RED reproduced:** with `restore()` disabled, `anchor drift 560: 17.97 -> 59.86`.
- **Guard mutations, each reverted and checked pristine.** RED (caught):
  - `html:true`;
  - `html:true` with sanitize off;
  - `preventDefault` removed;
  - click listener removed;
  - image rewrite returning the raw src;
  - image tree check off;
  - text anchor (`firstTextAt` returns null), giving `settings anchor 560 mono 39.08 -> 32.63`;
  - `restore` off;
  - async-diagram `restore` off;
  - entity decoding off, which breaks the messaging doc.

  GREEN (uncaught): see non-blocking item 1. The image `..` pre-check is redundant with URL normalization plus the tree check, so it is green but not a hole.
- **Probes:** find open during reload with a change above, drift 0.44 px; find open across a source round trip, 0 px. Link classification and the image URL policy were checked across UNC, absolute, double-encoded, encoded-slash and `file://host` cases (four blocked as expected).
- **Offline/vendoring:** `npm ci --ignore-scripts` plus `node vendor.mjs` in a scratch copy reproduces every vendored file and `THIRD_PARTY_LICENSES.md` **byte-identically**. All 95 MANIFEST SHA-256s match. Versions match package.json and the in-file banners (mermaid 11.12.0, DOMPurify 3.4.16, highlight.js 11.12.0). All 174 lockfile entries resolve from registry.npmjs.org with integrity.
- **Fidelity:** I reviewed the four prototype/bundle comparisons (560 and 1200, light and dark) plus full-length specimen renders (`$TMPDIR/review-358-shots/full-light-560.png`, `full-dark-1200.png`). The gaps beyond the omitted toolbar header (accepted, since R3 owns it) are B2's blank callout icons and non-blocking item 7. Tables stack at 560, the diagram renders themed, and body size and hyphenation follow the narrow rules.
- **Proof boundary:** Chromium only, as the owner disclosed. B1 and B2 are engine-independent (Mermaid API behaviour and regexp semantics).
