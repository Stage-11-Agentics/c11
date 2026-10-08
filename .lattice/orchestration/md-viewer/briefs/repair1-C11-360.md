# Repair brief 1: C11-360 (PR #623, head cc7ae25963)

Review 1 (Claude Opus) is a FAIL. The full review is at `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review1-C11-360.md`. Review 2 (Grok) is running on the same head; its blocking findings come to you as an addendum. **Start now; push once, after the addendum** (or after I tell you there is none). First rebase onto current `origin/main`: C11-359's follow-up `fd263426f9` landed after your base and touches `MarkdownWebRenderer.swift` and `MarkdownPanel.swift`.

## Blocking
- **B1** Toolbar glyphs, labels and the find field take their colour from the hosting view's colour scheme, not the panel theme, so they're unreadable when the theme and c11's chrome disagree. Drive every toolbar colour from `palette` (or set `.environment(\.colorScheme, …)` from the palette on the toolbar). Prove it with Light-in-dark-chrome and Dark-in-light-chrome screenshots.
- **B2** Below 430 px the right cluster centres and the breadcrumb disappears. Keep a flexible breadcrumb (or a spacer) at every width, pin the cluster trailing, and drop the file name before the heading at narrow widths, as the prototype does (this covers N3 too). Prove it with a resize sweep 300 to 1200 px: the cluster's trailing edge stays fixed.
- **B3** Match the doc's button styling. The outline toggle uses full-contrast ink and the prototype's widths. Icon buttons reuse or copy `OmnibarAddressButtonStyle` and the browser's sizes (open externally exactly like `openInExternalBrowserButton`). The theme `Menu` uses `.menuIndicator(.hidden)`.
- **B4** Localize the outline filter `placeholder` (and add a harness assertion with a non-English string set).

## Orchestrator rulings
- **The find bar moves into the page** (my earlier ruling; the review's R1). The page already owns the find engine, hit marks and gold ticks. Render the prototype's find popover there: quiet bar, match count, previous/next, Esc closes. Native ⌘F (through the existing Find menu route, see N1) just opens it via the bridge. Remove the native find bar. Harness cases: open, type, count, next/previous, Esc, anchor stability.
- **"System" theme follows c11's effective appearance**, which is the OS appearance when c11's own appearance is System. That's the behaviour since #622; leave it, and note it in BRIDGE.md and the skill if they say "OS".

## Repair in place
- **N1** Route ⌘F through the existing Find menu path and ⇧⌘O through the customizable shortcut registry (`KeyboardShortcutSettings`, as the doc says). No hard-coded key blocks ahead of the registry.
- **N2** Esc ordering: let the page handle Esc first (popover, then filter text, then the outline); native closes the outline only when the page didn't consume it.
- **N4** Reserve the progress readout's width instead of shrinking its font.
- **N5** Add `c11LogicTests` coverage for the native half: toggle choice persistence, Esc ordering and shortcut routing, with a stub renderer.
- **N7** A one-line note in the design doc that the docking threshold uses the active body size.
- N6 (stale default-app tooltip) goes to the hardening ticket.

Then: six-locale pass for any new strings; harness green; the Atlas tagged build (`--tag md-360`) UI proof at **~560 px** (really 560, not 700) and wide, covering all three themes in both chrome appearances, each typeface, the outline docked and as overlay, the in-page find, size by keyboard and buttons, and open externally. Push once, refresh the validation comment, send `HANDOFF C11-360 REVIEW <head> …`. Both reviewers verify.
