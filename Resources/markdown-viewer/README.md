# Bundled markdown renderer

`index.html` is the complete offline page hosted by the native markdown panel.
The host API, message shapes, source-line units and security contract are in
[BRIDGE.md](BRIDGE.md). Native owns toolbar/outline controls, persisted settings,
file access and navigation. The page owns content and position.

`themes.js` carries the round-4 prototype's light/dark token sets and the three
metric-tuned typefaces. `viewer.css` ports its content rules. `viewer.js` parses
once, groups top-level tokens, and reconciles by token content without detaching
unchanged nodes. Token maps give source ranges. A text-character anchor and its
viewport offset hold position through reflow; each asynchronous diagram update
captures and restores independently. Native must keep pageZoom at 1.

Raw HTML is disabled. Markdown images pass a directory-scoped URL policy and are
rewritten to `c11md-asset://doc/`; the host independently authorizes every request.
Mermaid config directives are refused, rendering uses strict security, and its
SVG crosses DOMPurify plus a resource-URL scrub before insertion. Code/math HTML
comes only from bundled libraries. Document links always report to native, with
local anchor movement handled in the page. CSP denies network access.

## Reproduce the checks

One-time setup from the repository root:

```sh
npm --prefix scripts/markdown-viewer ci
npm --prefix scripts/markdown-viewer exec -- playwright install chromium
```

Then one command (static HTML, headless, no server):

```sh
npm --prefix scripts/markdown-viewer test -- --screenshots
```

The harness loads all seven repository fixtures/documents at 560/820/1200 px in
both themes. It exercises content, line/outline/progress queries, find, source,
unchanged DOM and selection, async diagram and settings anchoring, hostile input,
link interception, and zero network/console errors. `--screenshots` also renders
the committed reader prototype offline and produces four side-by-side comparisons.
Results go under the OS temporary directory (`c11-md-358-evidence`), or
`C11_MD_EVIDENCE`. An existing Chromium executable can be selected with
`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`.

Chromium cannot register a native WKURLSchemeHandler. The image-policy test
observes the renderer's actual private asset URLs, then removes those src values
before Chromium's unsupported loader runs. Native image bytes, symlink/file-type
checks, packaged resource membership and WKWebView hosting require R2/the final
packaged-app validator. This harness does not claim that native proof.

## Refresh vendored assets deliberately

Versions and npm tarball sources are recorded in `vendor/MANIFEST.json`; every
file has a SHA-256. The lockfile pins dependencies and integrity hashes. To rebuild
from those pinned inputs after `npm ci`:

```sh
npm --prefix scripts/markdown-viewer run vendor
```

Review the generated diff and licenses, then run the harness. No dependency is
fetched at runtime. SF Pro is supplied by macOS; the bundled Inter fallback keeps
the sans view available in Linux tests. Literata and JetBrains Mono are bundled
with their font subsets; KaTeX includes its fonts. Notices are included in
`THIRD_PARTY_LICENSES.md`.
