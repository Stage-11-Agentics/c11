# Markdown viewer design

The design contract for C11-336: the markdown panel rebuilt on a web renderer. The prototype at `docs/design-prototypes/markdown-viewer/reader/index.html` shows this document in motion; where the two disagree, this document wins. Linked-doc navigation is a separate ticket (C11-357).

## What it is for

Reading one document well, in a pane that is often a half or a third of a laptop screen, by an operator who arrives cold between other agents. Every decision below serves that.

## Invariants

1. **The text never moves unless the reader moves it.** Live reload, theme, typeface and size changes, the source toggle, and opening or closing the outline all keep the same line in the same place. WKWebView has no native scroll anchoring, so the renderer anchors in JS, including when an async Mermaid render lands above the viewport.
2. **Controls never jump or clip.** The toolbar's right-hand cluster is fixed-width and always fully visible; the breadcrumb truncates with an ellipsis instead. Readouts use tabular numerals and reserved widths.
3. **Agents never take the operator's eye by force.** Agent commands change the surface only when asked, and never steal macOS focus.
4. **Offline.** Every renderer library is bundled in the app. No network fetches.

## Renderer

WKWebView replaces MarkdownUI. Bundled: markdown-it with footnotes, task lists, heading anchors and GitHub callouts (`> [!NOTE]`); Mermaid; highlight.js; KaTeX. Mermaid no longer needs an external CLI, so `FencedCodeRenderer`'s Mermaid path goes away.

On live reload, only changed blocks re-render, so diagrams, highlighted code and the text selection survive. This is invisible; there is no change-tracking or diff UI.

## Toolbar

A slim row under the panel bar, the counterpart of the browser's address row, in the c11 void language.

- **Far left:** the outline toggle (see Outline).
- **Left, after the toggle:** file name › current heading path, then reading progress (`42% · 9 min left`). The progress hairline under the row is the surface's one gold accent.
- **Right, fixed-width icon buttons:** find, source, text size, theme, open externally.

## Outline

The toolbar (breadcrumb, progress, size, every button) is always visible; the outline is the only part that comes and goes. With the outline closed, the toolbar's heading path and progress are the position cue, and nothing else is drawn in the margin.

**Open by default; the operator chooses to hide it.** When the effective width (pane ÷ text scale) has room for the panel plus the full text column, the column is laid out clear of the panel, so the open outline covers nothing and closing it leaves the text where it is. With the serif face that threshold is an effective width of 962 px (272 px panel, 28 px gap, 630 px column, 32 px right padding); mono docks from about 866 px, and a document with margin footnotes needs 222 px more. Below the threshold the panel would cover text, so it starts hidden and opens as an overlay. The operator's explicit open or hide is remembered like theme, typeface and size (per panel, last used as the new-panel default) and overrides the width default.

The toggle sits at the left end of the toolbar, next to where the panel appears (SF Symbol `sidebar.left`), with full-contrast ink, a clear pressed state while open, and an "outline" label when the toolbar has room (only the label drops when tight; the button keeps a fixed width). It also toggles with ⇧⌘O (checked against `KeyboardShortcutSettings` for conflicts in the build).

The panel is translucent (backdrop blur over the page) and appears and disappears with a quick crossfade of about 120 ms, with no slide. It shows the scrollspy position, the current section's subheadings, and task counts (`2/4`), and typing filters it. Clicking a heading jumps there and keeps the panel open; Esc or the toggle closes it.

## Themes

A registry of named token sets. Each theme defines prose, chrome, code highlighting, callout colours, Mermaid theme variables, and font families. The picker builds itself from the registry, so adding a theme means registering one token set. It ships **system, light and dark**; system follows the OS appearance. Dark is first-class, not an inverted light.

The control mirrors the browser's theme button (`browserThemeModeButton` in `Sources/Panels/BrowserPanelView.swift`): an icon button that opens a small menu.

## Typeface

A second section of the theme menu: **theme default, reading serif (Literata), sans (SF Pro), mono.** Each face carries tuned metrics, not just a family swap:

| Face | Measure | Leading |
|---|---|---|
| Literata | 36em | 1.62 |
| SF Pro | 35em | 1.56 |
| Mono | 30.5em (about 63 characters) | 1.8 |

Code and table text stay about the same size across faces. A theme may carry its own default face; the operator's choice overrides it. The panel-bar chrome keeps the house mono.

## Text size

50% to 300% in 10% steps. **⌘= / ⌘− / ⌘0** reach the panel through c11's app-wide zoom shortcut handler (`AppDelegate` → `WorkspaceManager.zoomInFocusedMarkdown` / `zoomOutFocusedMarkdown` / `resetZoomFocusedMarkdown`). The web view's own page zoom must not intercept these keys. The toolbar shows a fixed-width percentage readout with − and + buttons.

Layout breakpoints respond to the effective width (pane width ÷ scale), the way browser zoom works, so 1200 px at 200% lays out like a 600 px pane.

## Persistence

Theme, typeface and text size are per panel and survive a c11 restart with the panel. The session snapshot already carries the markdown panel's `fontScale` (`SessionPersistence.swift`, restored in `Workspace.swift`), so theme and typeface are two more optional fields beside it. The last value used in any panel becomes the default for new panels, extending today's `markdown.fontScale.lastUsed`.

**Any error falls back to the default view.** An unknown theme or typeface name, an out-of-range scale, or an unreadable field restores the defaults for that setting, never a broken or empty panel.

## Content

- **Prose:** a measured column (see Typeface). Body text steps down from 17.5 px at wide widths to 16.5 px at 560 px. Hyphenation is on only at narrow widths.
- **Tables:** below the narrow breakpoint, text tables with three or more columns become stacked label/value records. At wider widths a table may extend beyond the text column. Horizontal scroll with a sticky first column is the last resort.
- **Mermaid:** themed to match. Rendered at the column's width, at most 85% of the pane's height. An expand control opens pan and zoom inside the pane. A parse error shows a quiet message with the source underneath. Entity references such as `&lt;` inside sequence diagrams must be converted before parsing, because Mermaid splits statements on the `;`. (`docs/c11-messaging-primitive-design.md` trips this today.)
- **Code:** syntax-highlighted, with a copy button.
- **Footnotes:** margin notes when the pane is wide, popovers otherwise. In-document links leave a "back to …" pill.
- **Headings:** anchors with copy-link.
- **Find (⌘F):** a quiet bar with a match count and next/previous.
- **Source:** a read-only toggle that keeps the reader's place.

## Open externally

An `arrow.up.right.square` button styled exactly like the browser's `openInExternalBrowserButton`. It opens the file with the operator's default app for `.md`. The tooltip names the app ("Open in Typora"). This is how editing works: there is no in-app editor.

## Agent surface

Every control has a CLI counterpart.

| Command | Does |
|---|---|
| `c11 markdown scroll --panel <p> --heading "<text>"` | Jumps to a section and flashes it briefly in gold |
| `c11 markdown visible --panel <p> --json` | Reports what the operator is reading: heading path, line range, progress, theme, typeface, size, open find, selection. `--watch` streams it. |
| `c11 markdown theme --panel <p> --set <name>` / `--list` | Sets or lists registered themes; rejects unknown names |
| `c11 markdown typeface --panel <p> --set <name>` / `--list` | Sets or lists faces |
| `c11 markdown font --panel <p> --scale <n>` | Sets text size |
| `c11 markdown open-external --panel <p>` | Opens the file in the default markdown app |

Queries run off-main per the socket threading policy. Every command updates the c11 skill (`skills/c11-markdown/SKILL.md`) in the same change.

## Not in scope

- Diffs and change tracking.
- In-app editing (C11-344, cancelled in favour of open externally).
- Navigation across linked docs (C11-357).
