# Plan Review: C11-359 (native markdown panel on WKWebView)

Reviewed against: the task description, `docs/markdown-viewer-design.md` (origin/main), R1's `Resources/markdown-viewer/BRIDGE.md` (branch `md-viewer/C11-358-web-renderer` @ 249e9e38c8), and the current code on origin/main (da8205bc9e). Line references are to origin/main.

## 1. Verdict

**FAIL (plan-level)**

This needs a short amendment, not a rewrite. The in-flight work in `c11-worktrees/md-r2-panel` (`MarkdownPresentation.swift`, `MarkdownAssetPolicy.swift`, field-local snapshot decoding) is consistent with the amended plan and does not need to be thrown away. The FAIL is driven by issues 2 and 5. Issue 2 is a contract conflict with R1 that has to be settled while R1 is still being built. Issue 5 is a security gap in link routing. Issues 1, 3 and 4 are concrete misses that will otherwise surface as a compile break, regressions in tab drag-and-drop and shortcuts, and misleading weight numbers.

## 2. Summary

The plan covers every bullet of the task at the headline level: lazy retained web view, scoped scheme handler, link interception, state model with field-local fallbacks, dependency removal, and the proof list. It is also honest about the cut line. But it is terse to the point of skipping the places where this ticket touches existing c11 machinery that assumes "WKWebView means browser panel". Those are drag-type routing, Cmd-equivalent routing, the first-responder model, and the link-open policy. It also misses that `MarkdownUI` has a second consumer, and that R1's bridge v1 currently forbids the local-image path the task requires. The biggest concern is the cross-ticket image contract: as written, R2 would build native image serving that nothing in R1's page ever requests.

## 3. Issues

**[MAJOR] Acceptance proof / bridge dependency: the local-image contract conflicts with R1's BRIDGE v1**
The task requires that "local images resolve only beside the open document". BRIDGE.md says the opposite: "Images from markdown are inert alt-text placeholders, including local paths", and "grant the custom scheme only bundled assets". The plan says it will "serve … scoped sibling image files through a custom scheme". With bridge v1, no page request will ever hit that path, so the image acceptance cannot be met at integration. Even once the URL shape is agreed, the configuration and scheme handler are shared (one configuration per the task). So the handler has to map the requesting web view to its panel's document directory, using the `webView` argument of `webView(_:start:)`. Otherwise panel A can read images from panel B's directory.
**Recommendation:** Settle the image URL shape with R1 now, while both are in flight. For example: the page rewrites a relative `src` to `c11md://doc/<relative-path>`; native resolves it against the requesting web view's document directory, resolves symlinks, rejects anything that escapes, and serves from an image MIME allowlist. Amend BRIDGE.md and update the `imageBlocked` semantics. Decide whether "beside" means the document directory only or its subtree (recommended: the subtree, so `./assets/x.png` works, with no `..` escape). Decide whether SVG is allowed: if yes, serve it with a `sandbox` CSP header. If R1 cannot take the change, the plan should say images are deferred and flag that acceptance gap to the orchestrator, rather than ship dead native code.

**[MAJOR] Link routing: "route through c11" is undefined, and local non-markdown links are a code-execution path**
"Per existing policy" has no single home today. The policy is inline in the terminal's `GHOSTTY_ACTION_OPEN_URL` handler (`Sources/GhosttyTerminalView.swift:2476-2545`): `openTerminalLinksInCmuxBrowser`, host whitelist, external patterns, and ⌥ forcing external. The plan doesn't say whether markdown links use those terminal settings, where a c11 browser opens (a split beside the markdown panel? which existing open path?), or where a relative `.md` link opens. It also only covers the three kinds the task lists. A hostile document can link `./run.command`, `./x.app`, `file:///…/foo.terminal`, or an absolute path. If any fallback hands those to `NSWorkspace.open`, one click executes code. BRIDGE says native must validate independently, but the plan states no native allowlist.
**Recommendation:** Extract the terminal routing into one shared helper and call it from both terminal and markdown (no copy-paste). State the native allowlist explicitly: `http`/`https` go through the shared helper; anchors stay in-page; `.md`/`.markdown`/`.mdown` paths (relative, absolute or `file:`) open a markdown panel through the existing `markdown open` path (name it and its placement); everything else is dropped and logged under DEBUG. That includes non-markdown local files, other `file:` URLs, `javascript:`, `data:`, `mailto:` and unknown schemes. Add `./evil.command` and `file:///System/Applications/Calculator.app` links to the hostile fixture.

**[MAJOR] Web view integration: a plain WKWebView regresses tab drag-and-drop and Cmd shortcuts, and the plan has no first-responder model**
c11 already had to fix this for the browser, in `CmuxWebView`:
- WKWebView registers `public.text`/`.string` drag types, so it swallows bonsplit tab drags and sidebar reorder drags. AppKit routes the drag to the web view instead of the SwiftUI `.onDrop` siblings (`Sources/Panels/CmuxWebView.swift:1245-1276`). A plain WKWebView in the markdown pane breaks dragging a tab onto a markdown pane to split or move it.
- WebKit doesn't reliably pass Cmd equivalents (⌘W, ⌘T, ⌘D, ⌘1–9 and so on) up the chain, so `CmuxWebView.performKeyEquivalent` routes them to the main menu and `handleBrowserSurfaceKeyEquivalent` (`CmuxWebView.swift:203-290`, `AppDelegate.swift:13065`).
- `MarkdownPanel.focus()`/`unfocus()` are no-ops today (`MarkdownPanel.swift:189-193`) because nothing could take first responder. A WKWebView takes first responder on click. So the plan has to decide what holds first responder when the panel is focused by keyboard, socket or `pane.focus`, so that space, arrows and Page Down scroll and ⌘C copies. Only explicit focus-intent commands may move it (socket focus policy).

The zoom keys are fine: they go through the local monitor before the responder chain (`AppDelegate.swift:11226`, `:12405`). The plan should still state `allowsMagnification = false` and `pageZoom = 1`, which the task names.
**Recommendation:** Add a small `MarkdownWebView: WKWebView` that shares the drag-type filter and the Cmd-equivalent routing with `CmuxWebView`, by extracting them rather than subclassing `CmuxWebView`. Subclassing would pull the markdown view into the `cmuxOwningWebView` / address-bar / `focusedBrowserPanel` paths in AppDelegate (`AppDelegate.swift:15529-15760`). Define focus(): make the web view first responder only on focus intent. Add to the proof: drag a tab onto a markdown pane; ⌘W, ⌘D and ⌘1 with the markdown web view as first responder; space-scroll and ⌘C after keyboard focus.

**[MAJOR] Weight: a shared WKProcessPool is a no-op on this target, the measurement will mislead, and there is no contingency**
The deployment target is macOS 14.0. Since macOS 12, separate `WKProcessPool` instances no longer change process allocation, so "one shared WKProcessPool" saves nothing. Each live WKWebView generally gets its own `com.apple.WebKit.WebContent` process. Two consequences follow:
- **The measurement must count WebContent processes.** origin/main's MarkdownUI panels render in-process. The new build moves rendering out of process, so comparing c11's own RSS will make the WKWebView build look *lighter*. Sum the footprint of the c11 process plus every WebContent and Networking process it owns (`footprint` or `vmmap --summary` per PID), and record the process count.
- **Lazy creation only helps panels that are never shown.** The model retains the web view forever, so an operator who clicks through 20 tabs ends with 20 live WebContent processes. The plan has no budget and no plan B.

The task also leaves the 20-panel scenario undefined. All 20 visible in a grid and 20 tabs with one visible test different things.
**Recommendation:** Measure both scenarios: 20 tabs with one visible (shows the lazy win), and 20 visible (shows the ceiling, and click-through of all 20 tabs reaches the same ceiling). Write down a budget before measuring. Name the fallback if the numbers are bad: release the web view of a panel hidden for more than N minutes (or an LRU cap), and on re-show restore with `load` plus `scrollToLine(lastVisible.lines.first)`. The model already owns content and state, so this is cheap. Use `WKWebsiteDataStore.nonPersistent()` for the markdown configuration, and never the browser's `sharedProcessPool` (`BrowserPanel.swift:2180`, kept for cookie sharing).

**[MAJOR] Dependency cleanup: MarkdownUI has a second consumer, so it can't be removed as planned**
`Sources/PanelTitleBarView.swift:3` imports MarkdownUI and renders every panel's expanded title-bar description with `Markdown(...)` plus a compact `Theme` (`:181-182`, `:284`). The plan lists Package.resolved under "dependency cleanup", but the task's condition ("once nothing uses them") isn't met, and porting the title bar is out of scope. (Also, the live Package.resolved is `GhosttyTabs.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, not the one at the root.)
**Recommendation:** Keep the MarkdownUI package and remove it only from `MarkdownPanelView`. Remove `FencedCodeRenderer.swift`, `MermaidRenderer.swift` and the registration at `AppDelegate.swift:2764`, along with `MarkdownSegment` and the segment parser. File a follow-up ticket to port the title-bar description (e.g. to `AttributedString(markdown:)`, which needs a decision about lists) and then drop the package. Say this explicitly in the PR so the reviewer doesn't read the kept dependency as unfinished work.

**[MINOR] Sequencing with R1: no stub, and no owner for the bundle in pbxproj**
R1's branch so far holds only BRIDGE.md. "Use the R1 bridge once available" leaves R2 unable to prove anything end to end until R1 lands. Both tickets will touch `project.pbxproj` to add the `Resources/markdown-viewer/` folder reference, and gem-normalized pbxproj diffs conflict badly.
**Recommendation:** Name the owner of the bundle's folder reference (recommended: R1 adds it; R2 adds only Swift files). Before R1 lands, test the native side against a tiny test-only page that implements `ready`/`load`/`setSettings`/`link` per BRIDGE. Rebase onto R1 for the proof runs.

**[MINOR] Renderer lifecycle: the plan doesn't cover failure modes and first paint**
The plan doesn't state:
- Queuing load and settings until `ready`, with the latest request winning.
- Pushing settings before the first `load`, so a restored dark/serif panel doesn't flash defaults.
- Recovery in `webViewWebContentProcessDidTerminate`: reload with the last content, settings and scroll line. WebContent processes are jetsam targets under exactly the 20-panel pressure above, and a white panel violates "never a broken or empty panel". The worktree's `MarkdownWebRenderer` already appears to handle this; put it in the plan and the proof.
- Suppressing the web view's background until first render, so dark mode doesn't flash white.
- Appearance plumbing. The existing appearance observer (`MarkdownPanel.swift:418`) exists only for Mermaid re-renders and goes away with that path. Native should pass `osAppearance` from the window's effective appearance (c11 theme slots can differ from the OS) and update it on change.
- The bridge `strings` map: 12 keys that need six translations.

**Recommendation:** Add these as one checklist line under the renderer helper, and add "kill a WebContent process; the panel recovers in place" to the proof.

**[MINOR] State model: clamping and fallback are different semantics**
The task says out-of-range values fall back to the default. Today `normalizedFontScale` clamps to the range (`MarkdownPanel.swift:70`), and `MarkdownPanelFontScaleTests.testNormalizedFontScaleClampsToRange` (`:29`) asserts clamping. Interactive zoom must keep clamping: ⌘− at 50% stays at 50%. Persisted or decoded values must fall back to 1.0.
**Recommendation:** State the split in the plan: clamp in `zoomIn`/`zoomOut`, fall back in restore and decode. Replace the clamp test with two behavioral tests, one for each path. Keep the rule that restore never writes last-used, and that changing one field publishes only that field as the new default (the in-flight `saveLastUsed(fields:)` already does this).

**[MINOR] State model: theme and typeface names are hardcoded natively, which bypasses R1's registry**
The design says "the picker builds itself from the registry, so adding a theme means registering one token set". A native allowlist (`["system","light","dark"]`) means every new theme also needs a Swift change, or native silently resets it to `system` on restore.
**Recommendation:** Have native read a small manifest from the bundle (e.g. `themes.json`, shared with the page's registry), or keep the native list but make the page's `state.theme.resolved` the authority and document the coupling in BRIDGE.md.

**[MINOR] Threat notes: what the plan should record**
`docs/security-threat-model.md` §4 (`:125-140`) needs specific updates:
- `NSAllowsArbitraryLoadsInWebContent = true` also applies to the markdown web view, so CSP plus navigation cancel are the only network barrier.
- The doc's claim that there is "no explicit JS bridge from web content" becomes false: `c11md` is a new page→native channel. Record its message allowlist and that it exposes no file, socket or open primitive.

**Recommendation:** Also have the scheme handler send CSP as a response header, as defense in depth beside R1's meta tag: `default-src 'none'; script-src c11md:; style-src c11md: 'unsafe-inline'; img-src c11md: data:; font-src c11md:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`. Return nil from `createWebViewWith`, disable `javaScriptCanOpenWindowsAutomatically` and back/forward gestures, and allow exactly one navigation: the initial `index.html`.

**[MINOR] Proof runs: Atlas needs an unlocked GUI session**
c11 can't create terminal surfaces while the screen is locked (the ghostty `OutOfMemory` symptom in CLAUDE.md), and WebKit compositing on a locked or headless session is unreliable. If the Atlas session is locked, the tagged run and the 20-panel numbers are invalid.
**Recommendation:** Add a precheck to the proof step: confirm an unlocked console session on Atlas, or park and ask the operator. Launch with `launch-tagged-automation.sh <tag> --qa fresh` (and `--qa resume` for the restore proof).

## 4. Positive Observations

- **The cut line is clear and correct.** It keeps the existing filename row, defers R3 chrome and R4 CLI, adds no editor, no diff UI and no linked-doc history. That keeps the ticket to one pass.
- **Field-local decoding fallbacks** are named explicitly. That is the right call: a synthesized `Codable` with an enum or type mismatch would throw and could take down the whole session snapshot. The in-flight `MarkdownPresentation.init(from:)` and the `CFBoolean` checks on UserDefaults show this was thought through.
- **Retaining the lazy web view in the model** (not the SwiftUI view) is the right ownership, given SwiftUI tears down and rebuilds representables during split and workspace churn. Creating it "only when visible" matches the socket focus and threading policy.
- **Preserving `markdown.get_content`** is called out, and it stays safe because it reads `panel.content`, which the plan keeps.
- **Atlas for the heavy runs**, a narrowed logic suite locally, and the Merge Captain owning skill sync are all consistent with the machine and launch rules.
- **The proof list maps one-to-one to the task's proof bullets**, including the comparison against origin/main and the load average.
