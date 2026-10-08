# Review 1: C11-360 reader chrome, PR #623

Reviewer: agent:claude-md-review-360 (Claude Opus, cross-family). Read-only.
Head reviewed: `cc7ae2596302469000e2df519bfb89b4edb7e325` (asserted), diff `origin/main...HEAD`.

**Verdict: FAIL.** There are 4 blocking findings. Three of them are small fixes. B1 is the one that matters: picking the Light theme in c11's default dark chrome makes the toolbar unreadable.

## What I ran

- Web harness, headless: `node scripts/markdown-viewer/test.mjs` passed **34/34**, with zero network requests and zero console errors. No ports were bound.
- I mutation-tested the guards in a scratch copy of `Resources/markdown-viewer`. Each mutation turned a test red, and the copy was reverted after each run:
  - Dock gutter reserved only while open: red, "docked outline open moved the text anchor horizontally 166 -> 300".
  - Overlay that reflows the column: red, "overlay outline open moved the text anchor".
  - Heading click closes the outline: red.
  - Escape no longer closes the outline: red.
  - Escape does not post `outlineDismiss`: red.
  - Filter drops the parent of a matching heading: red.
  - Outline `tree` leaks into bridge state: red.
- I probed the docking threshold, scanning widths around each switch point. The switch is monotonic and the docked outline covers nothing. Measured effective widths:

  | Face | Plain document | With margin footnotes |
  |---|---|---|
  | Serif | 944 | 1184 |
  | Sans | 927 | 1167 |
  | Mono | 851 | 1088 |

  The values are identical at scale 1 and scale 2, so the threshold follows effective width. The doc's 962 serif and ~866 mono assume a 17.5 px body. Below the 1000 px "wide" breakpoint the body is 17 px, so the threshold lands 15 to 18 px lower. This is R1 code, it is self-consistent, and it is not blocking. N7 suggests a doc note.
- Atlas build `rv-360`: invocation `70cb2ceffda84ef1a99d694ec08f46a1`, `C11_REMOTE_OK compile=ok`.
- Sandbox guest `rv360`: second slot, 20-minute hard lease, deleted after use. I tested a light-theme serif panel at wide and at 566 px, and a system-theme mono panel at 566 px. Evidence is in `review1-C11-360-evidence/`.
- Localization: `jq empty` passes. All 36 new keys are present in ja, uk, ko, zh-Hans, zh-Hant and ru. The format tokens (`%d`, `%%`, `%@`) match in every locale.

## Invariants checked

- **(a) The text never moves.** The page side holds for outline open/close (docked and overlay), theme, typeface, scale, source and reload; the harness and mutations prove it. The native find overlay floats over the page and does not reflow it. Pass.
- **(b) Controls never jump or clip.** Fails below 430 px (B2). At 566 px and wide, the right cluster is fully visible.
- **(c) Docking rule.** Pass, with the threshold note above.
- **(d) Keyboard.** ⌘= ⌘− ⌘0 still go through the existing app-wide route. ⇧⌘O and ⌘F act only on the focused Markdown panel; the owner proved the background-terminal case. Esc ordering is diagram, then find, then outline. Pass, with notes N1 and N2.
- **(e) Prototype fidelity.** Fails on B1 and B3.
- **(f) Localization.** Fails on B4.

## Blocking

**B1. With the Light theme in dark c11 chrome (and Dark in light chrome), the toolbar is unreadable.**
- Where: `Sources/Panels/MarkdownPanelView.swift:692-697` and `:675`.
- Cause: `MarkdownReaderPalette` paints the toolbar from the panel's theme. `MarkdownChromeButtonStyle` colours the glyphs with `Color.primary` / `Color.secondary`, which follow the hosting view's colour scheme, not the panel's theme.
- What I saw (`rv360-light-wide.png`, `rv360-light-toolbar-crop.png`, `rv360-light-560.png`): with the Light theme in c11's dark chrome, these render white-on-light and are nearly invisible:
  - the outline toggle and its "Outline" label;
  - find, source, − and +;
  - the theme menu and open externally.
- The native find bar has the same cause (`:348` onward). Its `TextField` text uses the default primary colour over `palette.paper`, so typed text will be white on near-white. I read this from the code; I did not screenshot it.
- The owner's UI proof covers only Dark in dark chrome, which is the one combination where the two colour sources agree.
- Fix: drive the button style and find-field colours from `palette`, or set `.environment(\.colorScheme, palette.isDark ? .dark : .light)` on the toolbar and the find bar.

**B2. Below 430 px the right cluster jumps to the centre, and the breadcrumb and progress disappear.**
- Where: `MarkdownPanelView.swift:444-468`.
- Cause: the breadcrumb is the only flexible child of the toolbar `HStack`, and the code removes it below 430 px. Nothing then pushes the controls right. The `HStack` takes its intrinsic width and the default-centred `VStack` centres it.
- Effect: as an area crosses 430 px, the right cluster moves from the trailing edge to the middle. This breaks "controls never jump", and a 4-way split on a laptop is narrower than 430 px. It also contradicts "the breadcrumb truncates with an ellipsis instead": the prototype keeps the crumb at tight widths and drops only the file name.
- Fix: keep a flexible breadcrumb, or at least a `Spacer`, at every width. Pin the cluster with `.frame(maxWidth: .infinity, alignment: .trailing)`.

**B3. The doc-specified styling of the toolbar buttons is not met.**
- Outline toggle (`:494`, `:697`):
  - The doc says "full-contrast ink". When not pressed, the button renders in `Color.secondary`.
  - Its widths are 84 and 32; the prototype's are 92 and 30.
- Open externally (`:568`): the doc says "styled exactly like `openInExternalBrowserButton`". That button is 22 pt with an 11 pt glyph, `OmnibarAddressButtonStyle` (8 pt continuous radius, hover wash, 0.16 pressed). This one and every icon button are 30×28 pt with a 13 pt glyph, a 5 pt radius and no hover state. The prototype's `.ib` is a 26 px hit with a 13 px glyph and an 8 px radius, "like the browser address-bar row".
- Theme button (`:613`): `Menu` with `.menuStyle(.borderlessButton)` draws a disclosure chevron ("◐⌄" in every screenshot). Neither `browserThemeModeButton` nor the prototype has one. Use `.menuIndicator(.hidden)`, as `AgentConfigEditorSheet.swift:879` does.
- Fix: reuse or copy `OmnibarAddressButtonStyle` and the browser's sizes, and give the outline toggle `ink` as its foreground.

**B4. The visible outline filter placeholder is never localized.**
- Where: `Resources/markdown-viewer/index.html:24` hard-codes `placeholder="Filter outline"`. `viewer.js:370` localizes only the `aria-label`.
- Proof: a headless run with ja strings gave `{placeholder:'Filter outline', aria:'アウトラインを絞り込む'}`. Every non-English user sees English in the filter field.
- Fix: also set `outlineFilter.placeholder = S.strings.outlineFilter`, plus one harness assertion.

## Needs an Orchestrator call (not counted as blocking)

**R1. The find bar is native, but the ruling says it renders in the page.** `run-state.md` (06:45) and `checkpoint-3.md` record "outline (and find bar) render in the page". The owner's plan and the 14:00 comment say "Find remains in the native bar". It works: the owner proved ⌘F, the match count and closing. But it is the surface that inherits B1, and it diverges from the prototype's 356 px `--pop` find bar. Either accept the native find bar and require the B1 fix to cover it, or move find into the page, where the hit marks and gold ticks already live.

## Non-blocking

- **N1. ⌘F and ⇧⌘O are hard-coded ahead of the customizable shortcut registry** (`AppDelegate.swift:11940-11956`). The Find menu already routes ⌘F through `startSearch` to `focusedMarkdownPanel` (`WorkspaceManager.swift:1421`), so the ⌘F block is redundant. Both blocks pre-empt any user shortcut rebound to ⌘F or ⇧⌘O while Markdown is focused.
- **N2. Escape is caught natively before the page sees it** (`MarkdownWebRenderer.swift:115`). With the outline open, Esc closes the outline even when a footnote popover is open or the filter field has text. The page's own popover branch is unreachable in that state.
- **N3. The middle-truncated breadcrumb cuts the current heading.** At 566 px it reads `rv.md ›…eader review` (`:449`). The prototype drops the file name at narrow widths so the heading survives. A head truncation, or dropping the file name below about 600 px, would read better.
- **N4. The progress label shrinks its font** (`minimumScaleFactor(0.78)`, `:460`). Longer localized strings render the readout at a different size than short ones. The prototype reserves width instead (128, or 78 at narrow).
- **N5. No Swift tests cover the native half.** That half is the toggle choice, Esc ordering, find debounce and shortcut routing. CLAUDE.md allows skipping when a test is impractical, but says to state it; the PR doesn't. A `c11LogicTests` case on `MarkdownPanel.toggleOutline` / `dismissReaderOverlay` with a stub renderer looks practical.
- **N6. `defaultExternalAppName` is cached by path** (`MarkdownPanel.swift:171`). Changing the default .md app leaves a stale tooltip until the path changes. When no app is registered, the button opens nothing and gives no feedback.
- **N7. The doc's threshold numbers are 15 to 18 px off at medium widths** (see the probe above). Consider a one-line doc note that the threshold uses the active body size.
- **N8. The System theme follows c11's chrome appearance, not the OS.** The guest OS was Light, c11's chrome was dark, and System rendered dark (`rv360-system-mono.png`). That is pre-existing R2 behaviour (`MarkdownWebRenderer.swift:316`), outside R3, and the design says "system follows the OS appearance". Flagging it for the Orchestrator.
- **N9. `skills/c11-markdown/SKILL.md` changed,** so `scripts/sync-installed-skills.sh c11-markdown` is part of landing.

## Owner evidence vs the prototype

The owner's "narrow" screenshot is about 700 pt, not 560. All the owner's UI evidence is Dark theme with Serif. My 566 px and Light/System/Mono captures fill that gap and are what exposed B1. At 566 px the right cluster fits fully, the gold hairline sits under the row, and the scale readout uses tabular digits in a reserved 42 pt.
