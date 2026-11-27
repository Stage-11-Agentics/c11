# c11 theme schema 2

Theme Engine Lead (Cairn, Opus), 2026-11-02. Builds the seven approved themes in
`design/themes/c11-themes.html` as real c11 chrome themes. Brief: `design/themes/BUILD-BRIEF.md`.

## Decisions from Atin

Atin, 2026-11-03, approved all three: JetBrains Mono is bundled (`Resources/Fonts`, registered for the
process only when the family is not installed); area frames are a theme feature (focused and waiting,
off in stage11 and c11); a theme may name a paired terminal theme, applied with
`c11 themes set <name> --with-terminal`.

## What schema 2 is

`schema = 2` is schema 1 plus seven optional sections. Nothing in schema 1 changes meaning, so no
converter is needed. The loader accepts 1 and 2; new sections in a schema-1 file warn and are
ignored. An older build refuses a schema-2 file and falls back to `stage11` (the rule since v1).

**No regression by construction.** Every new role has *no* default. A role a theme leaves unset
resolves to nil, and the view keeps the value it hardcodes today. `stage11` and every schema-1
theme therefore render exactly as now, without having to reproduce today's constants as tokens.

**The engine goes live for schema-2 themes.** The themed paths in the titlebar, description bar,
sidebar rows, bonsplit and browser/markdown chrome sit behind seven `theme.m1b.*` debug flags that
default to off, which is why Nocturne on Atin's dark slot barely shows. Rule: a path is themed
when its flag is on *or* the active theme is schema 2. The flags stay as debug overrides.

## New value types

- `string`: a font family (`"system"`, `"system-mono"`, or a family name) or an enum value.
- `gradient`: a string of stops, `"#2D1060 0%, #6B1F8F 42%, #C2307F 72%"`. Colours in stops may be
  `$` expressions. The TOML subset parser is untouched (no arrays needed).

## New sections

| Section | Roles | Read by |
|---|---|---|
| `[type]` | `ui`, `display`, `mono` families | every text style below |
| `[type.<style>]` for `windowTitle`, `cardTitle`, `cardLabel`, `agentRow`, `tab`, `chip`, `pill` | `family` (ui, display, mono), `scale` (times the chrome-scale size, so Chrome Scale still works), `weight`, `case` (none, upper), `tracking` (em) | sidebar card, panel strip, description chip, titlebar, waiting pill |
| `[geometry]` | `cardRadius`, `cardBorderPt`, `cardActiveBorderPt`, `pillRadius`, `controlRadius`, `chipRadius`, `markRadius`, `progressHeightPt`, `tabSelection` (indicator, overline, underline, invert) | card, pill, titlebar controls, chip, lifecycle marks, progress bar, bonsplit tab |
| `[chrome.card]` | `fill`, `fillActive`, `border`, `borderActive`, `borderWaiting`, `text`, `textSecondary`, `textDim`, `rule`, `sheen` (bool) | `WorkspaceRowView` |
| `[chrome.pill]` | `style` (filled, outline), `fill` (colour or gradient), `ink`, `border` | Waiting Agent and Flagged rows |
| `[chrome.descriptionBar]` | `chipFill`, `chipBorder`, `chipText` | `PanelTitleBarView` chip |
| `[chrome.area]` | `focusBorder`, `waitingBorder`, `thicknessPt` (1 when unset, 0 is off); corners from `geometry.controlRadius` | area frames, drawn by the portal chrome overlays |
| `[backdrop]` | `kind` (material, solid, gradient), `color`, `gradient`, `grid` (none, perspective), `gridColor`, `gridTop` | `SidebarBackdrop` |
| `[states]` | `waiting`, `waitingInk`, `running`, `idle`, `cold`, `flag`, `unread`, `notification`, `usageLimit` | lifecycle ramp, marks, count dot, mailbox cell, badges |
| `[ornaments]` | switches, below | feature views |
| `[terminal]` | `pairedTheme`: a Ghostty theme name (the bundled ones are `c11-<theme>`, in `Resources/ghostty/themes/`) | `c11 themes set <name> --with-terminal` only; without the flag the terminal never changes |

`[states]` themes the colours only. Which state a panel is in, and the attention rules, stay c11's.
Named flag kinds keep their registry colours; `flag` is the generic violet.

**Backdrop.** `C11SidebarBackground`'s two gradients are also `[backdrop]` values: the bundled
`c11` theme draws Sunset Mall and `outrun-horizon` draws Outrun Horizon. The Sidebar Background
setting defaults to "From theme", which draws the active theme's `[backdrop]`. A theme without one,
the default `stage11` among them, shows c11's material and tint in both slots, the plain sidebar of
c11 1.8 (C11H-438). Sunset Mall and Outrun Horizon override the theme in the Dark slot; None always
shows the material.
Cards keep opaque fills, so text contrast never depends on the backdrop (C11H-32).

## Token or feature

A **token** changes a value a view already draws. A **feature** is view code that exists only for
a theme, off unless the theme switches it on. A feature never changes layout size: it draws in
space the layout already reserves.

| Ornament | Kind | Where it draws |
|---|---|---|
| `bust` | feature | Outrun's marble bust inside the Waiting Agent pill |
| `scanlines` (+ opacity) | feature | Outrun's overlay on the chrome, never the terminal |
| `titlebarClock` | feature | Big Board's LIVE tag, machine, clock in the titlebar's right slot |
| `stateTags` | feature | Big Board's LIVE and HOLD tags in place of the card state icon |
| `hoverBrackets` | feature | Datasheet Mono's corner marks on the hovered card, tab and pill |
| `cardHeader` (none, boxDrawing, console) | feature | Terminal Grid's `┌ ├─ └─` tree and Big Board's header row |
| `sidebarLegend` | feature | Terminal Grid's legend line above the sidebar foot |
| `activeGlow` | token | Outrun's cyan glow on the active card (a shadow) |
| inverted selected tab | token | `geometry.tabSelection = "invert"` (Datasheet Mono) |

## Rules for the Swift work

- Resolve theme values in the parent and pass a plain `Equatable` style struct into
  `WorkspaceRowView` and `TabItemView`, compared by theme version. Nothing new in `hitTest`,
  `forceRefresh` or any per-keystroke path.
- bonsplit gets the new tab fields in `BonsplitConfiguration.Appearance`, committed to the
  Stage 11 fork's `main` first, then the parent pointer.
- Fonts resolve once per theme load and are cached; a missing family logs once and falls back.

## The seven themes

`stage11` (c11, exists), `c11` (today), `datasheet-mono`, `terminal-grid`, `outrun-horizon`,
`nocturne`, `bigboard`. Each is a bundled file in `Resources/c11-themes/`, translated from the
prototype CSS, with a screenshot in `design/themes/shots/` from a tagged build in a sandbox guest.

## Test plan

- `c11LogicTests`: every bundled theme loads and validates; the `stage11` golden snapshot is
  unchanged; schema-1 files ignore new sections with a warning; every new role resolves to nil
  when unset; gradient and string parsing, including bad stops, unknown enums and missing fonts;
  `themes dump` lists the new roles.
- Visual: one tagged build, each theme set by `c11 themes set` and screenshotted in a guest next
  to the prototype; `stage11` screenshots from before and after must match.

## Engine notes (leave a stone)

- Theme validation runs in the app (`theme.validate` over the socket); the CLI has no parser.
- Bundled themes are copied by the app build's resource phase from `Resources/c11-themes/`, so a
  new `.toml` needs no project edit.
- c11 worktrees need `git submodule update --init vendor/bonsplit` before reading bonsplit.
- A user theme with the same name shadows the bundled one ("user wins"). Atin's themes folder holds
  schema-1 `nocturne`, `bigboard` and `datasheet-mono`; they must be replaced by the bundled schema-2
  files (or removed) once a schema-2 build runs, or he keeps seeing the colour-only versions.
- Gradient stops take their location from the last word (`… 42%`); the expression before it may
  contain spaces inside parentheses.
- Area frames cannot be SwiftUI strokes: terminals and browsers are portal-hosted above all SwiftUI
  content. Each area carries an invisible `AreaFrameAnchorView` in bonsplit's pane overlay slot, and
  the portal chrome overlays (terminal, then browser over its web views) stroke the anchors' bounds
  when they draw, above the content, the panel strip and the window frame. Only the selected
  workspace frames its areas: the focused one, and any whose tabs hold a waiting mark; focus wins,
  and a state whose colour is unset falls through to the next. A window that never held a
  terminal gets its terminal portal from the first framed anchor, since that overlay draws them.
