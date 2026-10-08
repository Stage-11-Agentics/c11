# Repair brief 1: C11-358 (PR #620, head 2c97338c4c)

Review 1 (Claude Opus) is a FAIL. The full review is at `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review1-C11-358.md` and on the ticket. Review 2 (Grok) is running now on the same head; its blocking findings will come to you as an addendum. **Start repairing now, but don't push to the PR branch until I send the Review 2 addendum (or tell you there is none).** Then push everything once, along with the bridge-offset commits from `md-viewer/C11-358-bridge-offset`.

## Blocking (fix both; each needs a harness case that goes red before the fix)
- **B1** (`viewer.js:363-369`): Mermaid render ids are reused across re-renders, so `mermaid.render` removes the live SVG and a theme change or OS-appearance flip drifts the text by the diagram height (−1394 px). Give every render call a unique id. Harness: a diagram above the viewport, then a theme change and an `osAppearance` flip, with the witness within 1 px.
- **B2** (`viewer.js:145`): the `ALLOWED_URI_REGEXP` class `.-:` is a range that strips hrefs like `c11-x.md` (native gets the current document instead of the target), KaTeX SVG `d` paths (`\sqrt` loses its radical) and callout icon paths. Escape the hyphen, or enforce the scheme allowlist in an `uponSanitizeAttribute` hook on href/src only. Harness: `c11-x.md` keeps its href and posts it; `\sqrt{2}` has `.katex svg path[d]`; every callout type's icon path has `d`.

## Repair in place (from Review 1's non-blocking list; related, small, do them now)
- **#1** Make the security guards observable: a hostile Mermaid corpus (init directive, frontmatter config, `click … href "javascript:"`, sequence/class `link`, `<img onerror>` label, `style … url(https://…)`) asserting the output is inert, plus a CSP assertion. Each guard you rely on should turn a test red when removed.
- **#2** (`:534`) Call `preventDefault` for any `<a>` before the diagram-stage early return.
- **#3** (`:86` vs `:165/:167`) Use one Mermaid info-string predicate everywhere (```` ```Mermaid ````, ```` ```mermaid title ````), and make sure a copy button always copies its own block.
- **#4** (`:121`) Classify host-bearing `file://host/…` and `//host/…` links as `blocked`.
- **#6** Narrow the directive guard so diagrams that merely contain `<img`, `url(` or a `---` line in a label aren't refused, while the hostile corpus stays inert.
- **#7** Make the margin-note number inline, as in the prototype.
- **#10** Keep `file:` out of the CSP the app serves; harness-only allowances belong to the harness.
- **#13** Only treat frontmatter as frontmatter when the document starts with `---` followed by a YAML-ish block, and never eat a leading thematic break.

The rest (#5 is for C11-359, #8, #9, #11, #12) goes to the hardening ticket; leave them unless one is trivial while you're in the file.

Hunt for other instances of each class yourself (other regexps with unescaped ranges, other render or id reuse). When the addendum arrives and everything is in: rebase onto the side-branch commits, push once, refresh the validation comment, and send `HANDOFF C11-358 REVIEW <new head> …`.
