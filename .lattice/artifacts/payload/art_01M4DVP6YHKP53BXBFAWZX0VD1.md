# Plan Review: C11-360 (reader chrome)

Reviewed against merged `origin/main`: R1 is `c37ced9d78` (#620) and R2 is `a95823705c` (#621). Both parents have landed. The R2 seams the plan names (`MarkdownPanel.presentation`, `setFontScale/setTheme/setTypeface/setOutlineOpen`, `MarkdownWebRenderer.state`, `call(_:arguments:completion:)`, `focusedMarkdownPanel`, `handleWebPanelKeyEquivalent`) all match the merged code.

## 1. Verdict

**FAIL (plan-level).** The plan needs a targeted amendment, not a rewrite. The overall decomposition is sound. Two premises are wrong, though, and both change the architecture:

- **"No bridge change is needed."** The native outline cannot reach the reader theme's colours or fonts.
- **"Add ⌘F to the focused markdown path."** The Edit menu consumes ⌘F before any markdown path sees it.

Both should be settled before GO.

## 2. Summary

The plan is unusually well evidenced:

- It read the real parent heads.
- It measured the prototype headlessly.
- It respects the page-owned anchoring boundary.
- It maps the contract to both executable and packaged proof.

The key concerns:

1. The native outline has no route to the reader theme's tokens, fonts or scale geometry, so it cannot match the round-4 visual contract without a bridge amendment or a deliberate alternative.
2. The keyboard and find seams are named wrongly, and several files that must change are missing from the file list.
3. R2's restore path re-applies the find query, which makes the plan's "transient" find bar incorrect.
4. Per-frame state publishing would re-render the whole reader surface on main.

## 3. Issues

**[MAJOR] Architecture §3 and §5: the native outline cannot reach the reader theme's colours, fonts or dock geometry, so the "no bridge change" premise is false**

In the prototype and in the `.opanel`/`.olist` rules that R1 ported into `viewer.css` (lines 34–69), the outline is part of the reading surface:

- **Background:** `--paper` at 74%, with `blur(16px) saturate(1.15)`.
- **Ink and rules:** `--ink-dim`, `--ink-strong`, `--ink-faint`, `--rule-soft` and `--wash`.
- **Heading entries:** set in `--font-head` (Literata, SF or JetBrains) × `--face-rail`.
- **Sizing:** every size is multiplied by `--scale`.

The bridge exposes none of this:

- `themes()` returns only `{id,label,scheme,defaultTypeface}` (`viewer.js:753`).
- `state.theme` is only `{choice,resolved}`.

That leaves the native outline with two bad options:

- **Hardcode a Swift copy of the `themes.js` hex values.** This breaks the design rule that "adding a theme means registering one token set".
- **Draw in c11 chrome colours.** In the light theme that puts a dark or neutral sheet over light paper, a visible mismatch with the visual contract.

The bundled faces are woff2 subsets inside the web bundle and are not registered with AppKit.

The geometry is also unspecified. When docked, the page reserves `(272 + 28) × scale` CSS px on the left (`viewer.js:454–458`), and the prototype panel is `min(272px × scale, 86%)` wide with all of its text scaled. A fixed 272 pt native panel would:

- leave a 328 pt dead gap at 200%;
- cover text at 50%.

**Recommendation:** Settle this with the Orchestrator before GO. Pick one option:

- **(a) Bridge amendment.** Have `themes()` or `state.theme` also return the outline tokens (paper, ink-strong, ink-dim, ink-faint, rule-soft, wash, head family, face-rail). Then either register the bundled faces natively (verify CoreText accepts the variable woff2 subsets) or get sign-off for SF or house mono in the outline.
- **(b) Page-rendered outline.** The page renders the outline list with the styles it already ships, and native owns only the toggle, the persisted choice and the keyboard. This needs an amendment for filter input and click or close events.

My gut is (b): less code, exact fidelity, and blur, scale and crossfade come for free. But it contradicts R1's README wording, so it is the Orchestrator's call.

Under either option, write the geometry rule into the plan:

- docked width = 272 × fontScale;
- overlay capped at 86% of the pane;
- top edge below the toolbar;
- the overlay never alters layout.

**[MAJOR] Architecture §8: the ⌘F seam is wrong (the Edit menu eats it), and the file list is missing the files that must change**

`MarkdownWKWebView.performKeyEquivalent` offers ⌘-equivalents to `NSApp.mainMenu` first. Edit › Find… (`c11App.swift`, the C11-41 block) is bound to ⌘F and calls `WorkspaceManager.startSearch()`, which only handles terminal and browser panels (`WorkspaceManager.swift:1394`).

A markdown ⌘F handler in the web view or the custom-shortcut path therefore never fires, and ⌘F silently does nothing. The same applies to:

- ⌘G and ⇧⌘G (Find Next and Find Previous);
- ⇧⌘F (Hide Find Bar);
- `isFindVisible`, which drives the menu's enabled state.

Once the native find field holds focus, the web view is no longer the responder at all.

**Recommendation:**

- **Find:** add a `focusedMarkdownPanel` branch (it already exists at `WorkspaceManager.swift:3382`) to `startSearch`, `findNext`, `findPrevious`, `hideFind` and `isFindVisible`.
- **Find-bar state:** put presentation and a focus-request token on `MarkdownPanel`, transient and not persisted. Menu actions cannot reach SwiftUI `@State`.
- **⇧⌘O:** either add it as a `KeyboardShortcutSettings` action, which makes it rebindable and conflict-checked by the existing registry, or make it a menu item enabled only when `focusedMarkdownPanel != nil`, so the chord passes through for browsers and terminals.
- **File list:** add `WorkspaceManager.swift`, `c11App.swift` and possibly `KeyboardShortcutSettings.swift`. `MarkdownPanel.swift` changes by more than "a small file-app action".

**[MAJOR] Scope "transient" bullet and Architecture §4: find-bar visibility must come from bridge state, because R2 restores find queries**

`MarkdownReadingPosition` (in `MarkdownRendererCache.swift`) captures `findQuery` and `sourceMode`. When a renderer is recreated after four-reader eviction or a WebContent crash, `restoreReadingPosition` re-issues `find(query)`. The c11-markdown skill already documents this: "Reopening a panel restores … find query."

The plan treats find state as transient "unless the merged parent contract specifies otherwise". It does specify otherwise. If the native bar lives in view-local state, a restored reader shows gold marks with no bar and no visible way to clear them.

**Recommendation:**

- Show the bar when `state.find != nil` or a native open request is pending.
- Seed the field from `state.find.query`.
- Make close and Escape call `findClose`.
- Debounce per-keystroke `find` by about 100 ms. `search()` re-walks and re-marks the whole document on every call, so also ignore stale completions.
- Add an acceptance row: find in a panel, push it past the retention limit, return to it, and the bar comes back with the same query and count.

**[MAJOR] Architecture §2–3 and Threading: per-frame state re-renders the whole reader surface on main**

`renderer.state` is an untyped `[String: Any]`. It is republished up to once per animation frame while scrolling, and on every `selectionchange`. The plan puts toolbar, outline and find in one SwiftUI surface that observes the renderer. Every scroll frame would then, on main:

- re-run the whole body;
- re-decode the dictionary;
- rebuild an outline list that can run to hundreds of rows on long documents;
- re-lay out the truncating breadcrumb.

That is main-thread work competing with every terminal in the window. Separately, the Launch Services lookup for the open-externally tooltip (`NSWorkspace.urlForApplication(toOpen:)`) must not run inside `body`.

**Recommendation:**

- Decode each message once into a typed, Equatable model.
- Publish small slices so a scroll frame only touches the breadcrumb, progress and scrollspy highlight:
  - readouts: heading path, progress, minutes left;
  - outline tree: changes on load only;
  - current heading id;
  - find count and current match.
- Key `ForEach` on the heading's `line`, not its slug.
- Cache the default-app lookup per file path, refreshed on hover or app activation.
- Add a long-document scroll check to the Atlas proof: outline open, hang monitor quiet.

**[MAJOR] Acceptance table: the proof requires keyboard paths for theme, typeface and source, and none are planned**

The task's proof line asks for "keyboard and toolbar paths for size, theme, typeface, outline, find, source". The plan defines keyboard paths only for size, find and outline.

**Recommendation:** Do one of the following, then add matching rows to the table:

- Define the missing paths: a keyboard-navigable theme/typeface popover (arrows and Return), and a source-toggle chord (for example ⌥⌘U, Safari's View Source) checked against `KeyboardShortcutSettings`.
- Get the Orchestrator to confirm that "keyboard path" means Tab or Full Keyboard Access into the toolbar controls.

**[MINOR] Architecture §6: the open-externally helper collides with R4, which runs in parallel**

C11-361 ships `c11 markdown open-external --panel` and runs at the same time as this ticket. "Shareable with R4 if its ticket needs it" understates this: R4 does need it. Both tickets will also edit `Localizable.xcstrings` and `skills/c11-markdown/SKILL.md`.

**Recommendation:**

- At READY, agree through the Orchestrator who lands the helper and what it is called (for example `MarkdownPanel.defaultExternalApp` plus `openExternally() -> Bool`). The other ticket rebases onto it.
- Plan an xcstrings rebase step: jq merge, then re-audit the interpolation tokens.
- Define the no-default-app case, where the URL comes back nil: a generic tooltip plus `NSWorkspace.open(fileURL)`, or a disabled button.

**[MINOR] Architecture §1 and §7: reusing the browser's button styling requires editing an upstream-derived file**

Several pieces the plan wants to reuse are not reachable from new files:

- `OmnibarAddressButtonStyle` and `cmuxFlatSymbolColorRendering` are `private` to `BrowserPanelView.swift`.
- `addressBarButtonSize`, `devToolsButtonIconSize` and `devToolsColorOption` are members of the browser view.

"Styled exactly like `openInExternalBrowserButton`" needs those lifted out.

**Recommendation:** Add `BrowserPanelView.swift` to the file list. Limit the change to access levels and shared constants, with no behaviour change, and flag it per the CLAUDE.md upstream-divergence rule.

**[MINOR] Architecture §8: the Escape precedence ignores the page's own Escape handling**

The page already uses Escape to close the diagram pan/zoom overlay and the footnote popover (`viewer.js:744`). A native interception for find or outline must not swallow an Escape meant for an open diagram.

**Recommendation:**

- Use this order: diagram (`state.diagram_open != null`), then the page handles it; then find; then the outline.
- State whether Escape on a *docked* outline also closes it. The design implies yes, and that persists an explicit hide.

**[MINOR] Architecture §3: the persistence consequences of an explicit outline choice are not stated**

Every toggle, ⇧⌘O press or Escape writes `markdown.outlineOpen.lastUsed`, and no UI path returns to `auto`:

- One Escape on a narrow overlay makes every new panel, including wide ones, start hidden.
- One open at narrow width makes new narrow panels start with their text covered.

This is what the design says.

**Recommendation:** Write it into the plan and into the replay scenario so reviewers don't file it as a bug. Confirm with the Orchestrator that no "back to automatic" affordance is wanted.

**[MINOR] Architecture §1: undefined behaviour below about 300 px, before first render, and on renderer failure**

- **Narrow panes.** The right cluster (224) plus the toggle (30) plus padding comes to about 280 px, and c11 panes get narrower than that. The plan does not define what gives way first.
- **Renderer failure.** R2's `MarkdownRendererContent` swaps in "Renderer unavailable" on failure. If the toolbar lives inside it, open externally disappears exactly when it is the operator's escape hatch.

**Recommendation:**

- Define the yield order (breadcrumb, then the progress readout; never the cluster) and add a ~320 px screenshot to the proof.
- Keep the toolbar visible before first render and on failure. Show placeholders in the reserved readout widths, and keep open externally enabled.

**[MINOR] Completeness: the skill source and accessibility handles are missing**

- `skills/c11-markdown/SKILL.md` documents the panel's shortcuts (⌘= / ⌘− / ⌘0), but the plan never edits the skill source. Syncing the installed copy stays with the Merge Captain.
- The plan does not give the controls accessibility identifiers.

**Recommendation:**

- Add ⌘F, ⇧⌘O and the toolbar controls to the skill source in this PR.
- Give every control an `accessibilityIdentifier` and a localized `accessibilityLabel`, as the browser does, so the Atlas computer-use pass and later agents can address them.

**[MINOR] Architecture §5: the theme menu does not build itself from the registry**

The design says "the picker builds itself from the registry". The plan builds it from `MarkdownPresentation.themeNames` and `typefaceNames`.

**Recommendation:**

- Build menu entries and their order from `call("themes")` and `call("typefaces")`.
- Use localized labels keyed by id, falling back to the registry label.
- Keep the Swift lists as validation only.

If you keep the Swift list as the source of truth instead, record that as a deliberate mirror.

## 4. Positive Observations

- **Grounded in real code.** It read the actual parent PR head and branch rather than the ticket text. Every seam name it relies on survives in merged main.
- **Respects the R1 ownership boundary.** The page owns anchoring and docking layout, and the plan explicitly forbids a second scroll restore and any change to the shared API without reporting it.
- **Measured the prototype.** It took real numbers headlessly with no install or server: 36 px toolbar, 224 px cluster, 46 px readout, 30/92 px toggle. That is the right way to hold "controls never jump".
- **Strong acceptance table.** Each contract item maps to both an executable check and a packaged Atlas proof, and the plan says plainly that screenshots and compiles do not prove interactions.
- **Correct operational hygiene:**
  - work starts only after GO, with an ancestor check against the merge SHA;
  - builds run on Atlas only;
  - on-screen safety is covered (display enumeration, kill timer, dismissal proof);
  - no `main.sync` telemetry, DEBUG-gated `dlog`;
  - no new persistence schema;
  - clear scope fences.
