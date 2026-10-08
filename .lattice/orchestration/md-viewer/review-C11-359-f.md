# Review C11-359 (seat f, Claude Fable) — PR #621, native markdown panel on WKWebView

Head reviewed: `b4f6a62ee5daed640c615e3910a7ee168858f27f` (worktree `c11-worktrees/md-review-359-f`, detached, clean; submodules ghostty `e6999ae7`, bonsplit `4ead5952`).
Diff reviewed: `origin/md-viewer/C11-358-web-renderer...HEAD` (36 files, +3134/−1213). R1's bundle is out of scope except where native relies on it.

## Verdict: PASS

No finding crosses the normal-use bar. Ten non-blocking findings follow, two of them test gaps I demonstrated with guard-breaking mutation runs on Atlas.

## Invariants and where they hold

**(a) Untrusted document content never reaches script execution, the network, a navigation, or a file outside what rendering needs.**
- Entry is a private scheme (`c11md://bundle/index.html`), no `file://` access; `MarkdownAssetPolicy.resource(for:)` serves only `index.html`, `.js/.mjs`, `.css`, `.woff/.woff2/.ttf` from the bundled folder (`Sources/MarkdownAssetPolicy.swift:100-117`) and only raster images from the document tree via `c11md-asset://doc/` (`:89-99`).
- Path policy: credentials/port refused; decode exactly once from `percentEncodedPath`; `..`, `\`, `//`, NUL rejected; realpath + prefix check; then an `openat` walk from a pinned directory descriptor with `O_NOFOLLOW` per component, `O_NONBLOCK`, `fstat` regular-file and size bound; ImageIO sniff against a UTI allowlist (`:19-55`, `:80-99`). Verified by a standalone compile of the policy against 31 URLs (traversal, double encoding, encoded slash, NUL, host case, symlink to `/`, symlink inside, FIFO/directory/JPEG-as-PNG/SVG, NFC/NFD unicode, query/fragment): every escape denied, every legitimate path served.
- CSP injected after `<head>` and sent as a response header: `default-src 'none'`, scripts/fonts only from `c11md:`, images only from `c11md-asset:`, no connect/frame/object/form/base (`:62`, `Sources/Panels/MarkdownWebRenderer.swift:33`).
- Navigation: only the single initial main-frame entry load is allowed; everything else cancelled; `createWebViewWith` returns nil; `javaScriptCanOpenWindowsAutomatically = false` (`MarkdownWebRenderer.swift:323-335`, `:165`).
- Bridge messages accepted only from the main frame at `c11md://bundle` (`:275-278`). Document text enters as a JSON argument to `callAsyncJavaScript`, never interpolated (`:189-205`, `:268-271`).
- Link routing is re-validated natively (`MarkdownLinkTarget.resolve`, `MarkdownAssetPolicy.swift:126-146`): anchors stay in page; http(s) without credentials go through the shared terminal link policy `openC11WebLink` (`BrowserPanel.swift:17-39`); relative `.md/.markdown/.mdown` open a markdown panel; `javascript:`, `data:`, `file:`, absolute paths, `mailto:`, control characters, `%00` are blocked. Verified with 22 hrefs.
- Status: holds. The real-WebKit test (`c11Tests/MarkdownWebRendererTests.swift:14-77`) proves inert script/onerror, no https `src`, offline Mermaid, scoped image decode; the policy tests cover the path boundary. Gaps: see findings 1 and 2.

**(b) Existing paths behave as on main.**
- `c11 markdown open` / `markdown.get_content`: socket handlers unchanged (`SocketHandlers/MarkdownFeedbackHandlers.swift:19-22`); `get_content` reads `panel.content`, model-only, works while evicted (host test `:171-175`).
- Live reload: file watcher unchanged (`MarkdownPanel.swift:348-420`); `applyExternalContent` → `renderer?.synchronize()` → `load`; the page keeps the anchor and native restores no second offset (`pendingRestorePosition` is consumed on first `rendered`, `MarkdownWebRenderer.swift:290-297`). Host test asserts ≤1px heading movement after a layout change above the viewport.
- Drop-to-open and the open button: unchanged, empty state only, as on base (`MarkdownPanelView.swift:127-215`).
- Session snapshot/restore: `fontScale` + `theme` + `typeface` + `outlineOpen`, each decoded with `try?` and normalised per field so a bad value falls back alone and never discards the panel (`SessionPersistence.swift:360-405`, `Workspace.swift:912-917`, `:1187`); restore does not touch last-used defaults; autosave fingerprint now covers the four fields (`WorkspaceManager.swift:5772-5783`). 13 presentation tests cover this.
- Focus flash and pointer focus: flash overlay unchanged; the pointer observer is unchanged; the web view refuses first responder unless the panel is focused or a click is in flight (`MarkdownWebRenderer.swift:77-80`), and focus requests only act on a mounted view (`MarkdownPanel.swift:210-219`). Hidden workspaces unmount the web content (`WorkspaceContentView.swift:47-56`, `ContentView.swift:1459,1475`), so a socket `panel.focus` on a hidden workspace cannot steal first responder.
- ⌘= ⌘− ⌘0: `MarkdownWKWebView.performKeyEquivalent` routes to the main menu, then `AppDelegate.handleWebPanelKeyEquivalent` (→ `handleCustomShortcut` → `zoomInFocusedMarkdown`, `AppDelegate.swift:12402-12406`), and returns false for `= + - 0` so WebKit never zooms; `pageZoom = 1`, `allowsMagnification = false` are enforced on every `synchronize` (`:100-113`, `:254`). No main-menu item binds these keys. Host test asserts `pageZoom == 1` after `zoomIn()`.
- Panel descriptions: MarkdownUI replaced by a native block/inline subset (`Sources/PanelTitleBarView.swift:277-434`); links keep their text with the URL attribute stripped; sanitizer unchanged; 4 new tests. Skill reference updated.
- Status: holds, with the deliberate link narrowing in finding 3 and the trivial legacy-snapshot change in finding 8.

**(c) Weight design: shared process pool, lazy creation, bounded eviction (visible + LRU 4), position/mode/find restored, no eviction mid-query or with a focus steal.**
- One `WKProcessPool` and one nonpersistent data store for all readers; per-panel controller and scheme handler (`MarkdownWebRenderer.swift:150-175`).
- No model path creates WebKit; only the visible host's `makeNSView` calls `ensureRenderer()` (`MarkdownPanelView.swift:280-285`, `MarkdownPanel.swift:122-128`). Tests assert `renderer == nil` on construction, restore, autosave and hidden reload.
- `MarkdownRendererRetentionPolicy` (cap constant `defaultHiddenCapacity = 4`, `Sources/MarkdownRendererRetentionPolicy.swift:6`): candidates = oldest unpinned hidden beyond cap; visible IDs never candidates; 11 pure tests.
- `MarkdownRendererCache.reconsider` captures `visible()` asynchronously, then re-checks epoch, visibility, in-flight queries, renderer identity and candidacy before `evictRenderer` (`MarkdownRendererCache.swift:80-115`). Hidden readers keep their last mounted viewport so capture uses the operator's geometry (`MarkdownWebRenderer.swift:59-75`). Re-show: `setSettings`, `load`, then `setSourceMode`, `find`, `scrollToLine(line, offset)` while the page stays at opacity 0 (`:233-250`, `MarkdownPanelView.swift:316`).
- Eviction closes the web view while unmounted; nothing calls `makeFirstResponder` or the flash on that path.
- Status: holds. Reproduced the owner's hidden-viewport red (demonstration below). The "never evict mid-query" guard exists but is not behaviourally tested (finding 2).

**(d) c11 policy.**
- No `runModal` on agent paths: the only `runModal` is the operator's Open button (`MarkdownPanelView.swift:198`), as on base. No WKUIDelegate dialog methods are implemented, so page `alert/confirm/prompt` cannot show a modal.
- Scheme handler work runs off-main on a private queue and hops to main only to deliver (`MarkdownWebRenderer.swift:13-45`); stopped tasks receive no late callback. No new long-lived threads. No `DispatchQueue.main.sync`.
- Typing hot paths: none of the listed files touched; `updateNSView` churn is on the panel view, not a per-keystroke path (see finding 9).
- `dlog`: 4 calls, all inside `#if DEBUG`.
- Localization: 15 new keys, each present in en, ja, ko, ru, uk, zh-Hans, zh-Hant; `jq` parses the catalog; no format tokens in these strings.
- Project file: gem churn, but membership is right: 6 new sources in the app target, logic tests in `c11LogicTests` (5 classes) and the real-WebKit tests in `c11Tests`; `markdown-viewer` as a folder reference in Resources; MarkdownUI, NetworkImage, swift-cmark, FencedCodeRenderer and MermaidRenderer removed.

## Blocking findings

None.

## Non-blocking findings (ranked)

1. **Five native guards have no test.** `Sources/Panels/MarkdownWebRenderer.swift:323-335` (navigation policy and new-window refusal), `:275-278` (bridge messages only from the bundled main frame), `:107-109` (⌘= ⌘− ⌘0 never reach WebKit page zoom), `:33` (CSP response header). Scenario: a refactor drops the navigation cancel or the frame/origin check and the 71-test slice stays green, which is exactly what happened when I removed all five at once (Atlas invocation `b9ea6e51a98e401d90dc9a691e521fb2`, TEST SUCCEEDED). Fix direction: in the real-WebKit test, evaluate `location.assign('c11md://bundle/index.html?x')` and `window.open(...)` from the page and assert `window.c11md` state and `revision` survive (no reload, no second web view); synthesise a ⌘= `NSEvent` through `performKeyEquivalent` and assert `pageZoom == 1` and the method returns false; assert the entry response carries the CSP header (e.g. through a `WKNavigationResponse` capture in the test's delegate).

2. **The in-flight-query pin and the post-capture re-check are not behaviourally witnessed.** `Sources/Panels/MarkdownRendererCache.swift:62-66` (pin) and `:96-101` (epoch/visibility re-check). The host test's `XCTAssertNotNil(panel.renderer, "An in-flight query must prevent eviction")` (`c11Tests/MarkdownWebRendererTests.swift:138`) runs synchronously right after the other panels register, before any asynchronous capture can complete, so it passes with or without the guard; the claim in the ticket's validation comments ("genuine in-flight query witness") rests on the direct flag asserts at `:116` and `:127`. Demonstrated: removing the cache-side pin and both in-flight checks (invocation `1dac4183a95e4a0a94c854f1cc878af9`) and removing the epoch/visibility re-check (invocation `02861ae265a34c6fa9c9541ade29c2fb`) both leave all 71 tests green. Fix direction: hold a query open across the eviction window (a bridge call that awaits a promise the test resolves later, or a large `load`), register the extra panels, pump the run loop, assert no `evictions` event until the query resolves, then assert eviction; for the re-check, re-show the panel during capture and assert it is never evicted.

3. **Link behaviour narrowed relative to main.** `Sources/MarkdownAssetPolicy.swift:126-146`. On main, MarkdownUI's default `openURL` opened `mailto:`, `file:`, absolute paths and other schemes through Launch Services; now they do nothing on click. This matches the ticket text and the threat-model note ("other schemes and arbitrary local files are refused") and is sound hardening, but it is a visible change for a document with a `mailto:` link. Synthesis seat to confirm it is intended; if mail links are wanted, allow `mailto:` explicitly through `NSWorkspace.open` with a scheme allowlist.

4. **Relative `.md` links may traverse anywhere readable.** `MarkdownAssetPolicy.swift:140-144`: `../../../etc/notes.md` resolves to `.markdown` and a click opens a new focused panel on that file (`MarkdownWebRenderer.swift:310-321`). Same reach as `c11 markdown open`, and C11-357 owns linked-doc navigation, so by design for now; consider confining to the document's tree or routing out-of-tree targets through confirmation when R3/C11-357 land.

5. **No recovery for a failed visible renderer.** After two WebContent terminations or an entry load failure, `failure` stays true and the panel shows "Renderer unavailable" until it is hidden, evicted and re-shown (`MarkdownWebRenderer.swift:344-358`, `MarkdownPanelView.swift:307`). Fix direction: retry on the next file change or on re-focus.

6. **A rejected `load` leaves the page invisible.** If the bridge's `load` promise rejects without posting `render_failed` (e.g. `invalid_argument`), `renderedRevision` stays nil and the web view stays at opacity 0 (`MarkdownWebRenderer.swift:265-271`, `MarkdownPanelView.swift:316`). Fix direction: treat a failed `load` completion as `failure` or mark the revision rendered.

7. **Package.resolved churn.** Both resolved files were rewritten from Xcode's `"key" : value` spacing to `"key": value`, and `originHash` was kept although three packages left. Xcode regenerates its format on the next resolve, so the next PR will carry a whitespace-only diff. Let Xcode write the file once.

8. **Legacy snapshot without `fontScale`** now restores at 1.0 instead of the last-used scale (`Workspace.swift:1187`). Only pre-fontScale snapshots; trivial.

9. **`synchronize()` on every `updateNSView`** (`MarkdownPanelView.swift:299`). Cheap today (settings dictionary compare plus a content compare that is pointer-equal when unchanged), but it is a hook on every SwiftUI update of the panel view; R3's toolbar state will multiply those updates. Not a typing hot path.

10. **Hard links inside the document tree serve outside bytes.** Filesystem-level and not reachable from document text, so acceptable; noting it because the threat-model paragraph speaks only of symlinks.

## What I demonstrated

- Worktree asserted at `b4f6a62ee5daed640c615e3910a7ee168858f27f`, clean, submodules initialised.
- **Baseline on Atlas**, tag `rv-359-f`, invocation `9235947b99984254b8643e95f58b4dc4`: the eight-class slice the owner named, 71 tests (50 logic + 21 host, including the 5 real-WebKit tests), `** TEST SUCCEEDED **`, `dirty=false`.
- **Guard-breaking mutation rounds** (scratch edits to `Sources/`, each reverted with `git checkout`; worktree clean at the end):
  - `viewport`: hidden-viewport retention removed (`MarkdownWKWebView.setViewportVisible` → never retain). RED: `testNarrowReadModeEvictionRestoresReadingState` captured line 50 / offset 60.86 instead of 160 / 6.56 and restored line 52, offset −70.89. Reproduces the owner's claimed red for the C11-359 read-mode repair. Invocation `62706b7de36e481fbbeaad484a30bc16`.
  - `query-pin` (flag forced false + no pin): RED only at the direct `hasQueriesInFlight` asserts (`:116`, `:127`) in both eviction tests. Invocation `84735c91217c41c5a09eaef32b1e1813`.
  - `query-pin-2` (flag honest; cache pin and both in-flight checks removed): GREEN, 71/71. Invocation `1dac4183a95e4a0a94c854f1cc878af9`.
  - `recheck` (post-capture epoch/visibility re-check removed): GREEN, 71/71. Invocation `02861ae265a34c6fa9c9541ade29c2fb`.
  - `untested-guards` (navigation always allowed, new windows created, bridge frame/origin guard removed, zoom-key guard removed, CSP header removed): GREEN, 71/71. Invocation `b9ea6e51a98e401d90dc9a691e521fb2`.
- **Standalone policy probe** (local `swiftc` of `MarkdownAssetPolicy.swift` plus a driver, no app build): 31 asset URLs and 22 link hrefs, results as summarised under invariant (a). A second compile with the decode replaced by Foundation's `url.path` still denied `%00` and `%2e%2e` variants through the inner `read(path:)` checks, so the boundary is layered.
- Localization coverage (15 keys × 7 locales), `jq` validity, `dlog` gating, pbxproj membership and the Package.resolved diffs inspected as described.
- Not demonstrated by me: the packaged UI (the laptop never launches c11; I relied on the owner's Atlas screenshot/footprint artifacts and the Validator scenario in the ticket), pointer and keyboard focus in a real window, WebContent-termination recovery, and the 20-panel footprint numbers.

## Scope notes for the synthesis seat

- The PR is stacked on R1; R1's `viewer.js` offset bridge (`scrollToLine(line, offset)`, `lines.offset`) is included here with R1 authorship and is the only R1 surface this review depended on.
- Atlas tag `rv-359-f` is being freed after this report; the mutation logs are in this seat's scratchpad only.
