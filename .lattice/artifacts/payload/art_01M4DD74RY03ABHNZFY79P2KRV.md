# C11-358 web renderer validation

Head: `9da95a887332ca324c3909c07fdf85170a1a2d25`. Renderer scope only; no Swift/project/installed-skill edits.

PASS: 42 disk-loaded fixture/width/theme combinations (seven documents at 560/820/1200 px in light/dark) and 14 behavioral scenarios. Browser: Chromium 151.0.7922.34, Playwright 1.56.1. Zero renderer console errors and zero network requests. All seven diagrams in the messaging design render, including sequence messages containing entity references.

The scenarios cover callouts, tasks and nested outline counts, KaTeX, highlighted code and copy messages, frontmatter, stacked tables, margin/popover footnotes, in-pane diagram expansion, literal find across inline formatting, wrapping navigation, unchanged DOM/selection, reload/settings/source position holding, asynchronous diagram resize above the viewport, invalid settings/system theme, concurrent load/settings ordering, superseded loads, hostile content/URLs, local-image URL policy, intercepted links and the return pill, DOM-safe heading IDs, and quiet malformed-diagram fallback.

Mutation proof: temporarily disabled the real anchor restore function. The reload witness failed with `anchor drift` (RED). Restored the original implementation; all 13 non-screenshot scenarios passed (GREEN). Mutation was not committed. Exact logs are attached separately.

Vendoring: pinned dependencies, tarball sources, integrity lockfile, SHA-256 manifest and license notices are included. A clean `npm ci --ignore-scripts --no-audit --no-fund` succeeded. `git diff --check` passes. Vendored upstream minified JS has a scoped whitespace attribute to retain literal shader/distribution bytes.

## Reproduce

After setup documented in Resources/markdown-viewer/README.md:

`npm --prefix scripts/markdown-viewer test -- --screenshots`

This run selected an existing Chromium executable with PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH and wrote evidence to /tmp/c11-358-evidence. It bound no ports and closed every headless browser. No Atlas app/tag was created.

## Proof boundaries

This is static bundled-page proof, not native packaged-app proof. R2/final validator must confirm app resource membership, relative URLs under the private WKWebView scheme, native copy/navigation dispatch, and actual local-image byte delivery with independent traversal/symlink/file-type validation. Chromium cannot register WKURLSchemeHandler: the image test observes the renderer's actual private asset URLs and removes only those srcs before Chromium's unsupported loader runs. Hostile images remain inert without this test adapter.

The four attached comparisons show the committed round-4 prototype beside the bundle at 560/1200 px in both themes. Native toolbar/outline controls belong to R3. The page deliberately omits the prototype's stage and document-stat header; the design contract assigns position/progress to the toolbar.

## Validator scenario

1. Run the command above. Expect 42 fixture combinations, 14 scenarios, no renderer console/network errors, and four comparison PNGs.
2. In the final packaged native panel, open the messaging design. Expect seven themed diagrams and no external Mermaid CLI/network fetch.
3. Scroll into a long section, select some text, then change a block above it. Expect the same text row in place, selected text retained, and unchanged diagrams/code nodes retained.
4. Change theme, face, size and outline; toggle source/read. Expect stable position, correct effective-width layout, read-only source, and usable find/outline/progress queries.
5. Open a synthetic document with an authorized local image plus remote/data/traversal/symlink-outside images. Expect the local image bytes from the native asset scheme and rejected images inert, with no remote load.
6. Click external/local/in-document links and copy controls. Expect native messages for every action, no page navigation, and a local return pill for anchor jumps.
