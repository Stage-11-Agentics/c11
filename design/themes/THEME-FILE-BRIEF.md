# Brief: translate a prototype theme into a schema-2 c11h theme file

You write one or more bundled chrome theme files for c11h, in the worktree
`~/src/c11h-wt-themes` (branch `themes/schema-2`). Write only the files
named in your task. Do not build, do not commit, do not touch Swift.

## Read first

1. `docs/c11h-theme-schema-2.md`: the schema design.
2. `Sources/Theme/ThemeStyleRoles.swift`: every schema-2 role, its TOML path and value kind
   (`ThemeStyleRoleRegistry.all`). Choices are listed in the `*Choices` arrays. A wrong type or an
   unknown choice fails the load, so use only these paths and values.
3. `Resources/c11-themes/stage11.toml` and `Resources/c11-themes/README.md`: schema-1 sections and
   the colour expression grammar (`$palette.x`, `$variable`, `.opacity()`, `.mix()`, `.lighten()`,
   `.darken()`). Hex is `#RRGGBB` or `#RRGGBBAA`; there is no `rgba()`: convert `rgba(255,255,255,.58)`
   to `#FFFFFF94` (alpha byte = round(a*255)).
4. `design/themes/c11h-themes.html`: the approved prototype. The `:root` block (lines 16-77) is the
   c11 baseline; each theme is a `[data-theme="x"]` token block plus flourish rules. That CSS is the
   design. `design/themes/README.md` has the rulings: keep the red cut from Datasheet Mono and
   Terminal Grid (orange only on what needs you).
5. `design/themes/toml/<name>.toml` where it exists: a schema-1 colour register already approved.

## File shape

`Resources/c11-themes/<name>.toml`, `name` equal to the filename, `schema = 2`, version `0.01.001`,
author `Stage 11 Agentics`. A header comment: one line on the theme, then which prototype key it is.
Keep schema-1 sections (`[palette]`, `[variables]`, `[chrome.windowFrame]`, `[chrome.sidebar]`,
`[chrome.dividers]`, `[chrome.titleBar]`, `[chrome.tabBar]`, `[chrome.browserChrome]`,
`[chrome.markdownChrome]`) complete, then the schema-2 sections. Comment any value that is a judgment
call rather than a straight copy.

## Mapping the prototype CSS

| Prototype | Theme role |
|---|---|
| `--chrome` | `chrome.titleBar.background` (opacity 1.0), `chrome.tabBar.background`, `chrome.browserChrome.background`, `chrome.markdownChrome.background` |
| `--chrome-2` | `chrome.descriptionBar.chipFill` only if the chip has a fill; otherwise leave unset |
| `--chrome-ctl` | `chrome.titleBar.controlFill` |
| `--chrome-text`, `--chrome-text-2` | `chrome.titleBar.foreground`, `foregroundSecondary`, `chrome.titleBar.controlForeground` |
| `--chrome-rule` | `chrome.titleBar.borderBottom`, `chrome.tabBar.divider`, `chrome.dividers.color`, `chrome.sidebar.borderLeading` |
| `--sidebar-bg` | `[backdrop]`: `kind = "solid"` + `color`, or `kind = "gradient"` + `gradient`; also `chrome.sidebar.tintBase` with `tintBaseOpacity = 1.0` |
| `--card`, `--card-active` | `chrome.card.fill`, `fillActive` (also `chrome.sidebar.activeTabFill` / `activeTabFillFallback`) |
| `--card-border`, `--card-border-active` | `chrome.card.border`, `borderActive`; a theme rule on `.card.waiting` sets `borderWaiting` |
| `--card-text`, `-2`, `-dim`, `--card-rule` | `chrome.card.text`, `textSecondary`, `textDim`, `rule` |
| `--card-radius`, `--card-pad` | `geometry.cardRadius`, `geometry.cardPaddingPt` (first value) |
| `.card` border width, `.card.active` | `geometry.cardBorderPt`, `cardActiveBorderPt` |
| `--accent` | `chrome.card.accent`, `chrome.sidebar.badgeFill`, `chrome.tabBar.number`, `chrome.tabBar.activeIndicator` |
| waiting colour (`.mk.wait`, `.waiting-pill`, `.state.waiting`) | `states.waiting`; ink on it `states.waitingInk` |
| `--live` | `states.running` |
| `--attn` | `states.unread` (mail); the waiting colour when the theme rules say so |
| `--flag`, `--cold` | `states.flag`, `states.cold` |
| `--tab-active`, `--tab-text`, `--tab-text-2` | `chrome.tabBar.activeFill`, `chrome.tabBar.text` and `activeText`, `textSecondary` |
| `.tab.active` box-shadow inset top / bottom, inverted fill | `geometry.tabSelection`: `overline`, `underline`, `invert`; plain c11 is `indicator` |
| `--area-border-focus`, `--area-border-wait` | `chrome.area.focusBorder`, `chrome.area.waitingBorder`, `chrome.area.thicknessPt` = the `.area` border width |
| `--radius` | `geometry.controlRadius`, and `geometry.chipRadius` unless the chip rule sets its own |
| `.mk` border-radius | `geometry.markRadius` |
| `.card .bar` height / radius / `.g` fill / track | `geometry.progressHeightPt`, `progressRadius`, `chrome.card.progress` (a gradient string is fine), `chrome.card.progressTrack` |
| `.waiting-pill` | `chrome.pill.style` (`filled` or `outline`), `fill` (colour or gradient), `ink`, `border`; `geometry.pillRadius` |
| `.descbar .chip` | `chrome.descriptionBar.chipBorder`, `chipText`, `chipFill`; `geometry.chipRadius` |
| `.card.active` glow box-shadow | `chrome.card.glow` |

Fonts: `--font-ui`, `--font-title`, `--font-mono` become `[type] ui`, `display`, `mono`. SF Pro Text
and SF Pro Display are `"system"`; SF Mono is `"system-mono"`; JetBrains Mono is `"JetBrains Mono"`.

Text styles `[type.<style>]` (attributes `family` = ui|display|mono, `scale`, `weight`, `case`,
`tracking` in em), from the theme's per-element rules. `scale` is the theme's px size over the c11
baseline size, rounded to two places:

| Style | Prototype selector | c11 baseline size |
|---|---|---|
| `windowTitle` | `.win-title` | 13 |
| `cardTitle` | `.card .name` | 17 |
| `cardLabel` | `.card .meta`, `.usage`, `.branch`, `.ports`, `.state` | 11 |
| `agentRow` | `.card .agent` | 13.5 |
| `tab` | `.tab` (and `.strip` font-size) | 12.5 |
| `chip` | `.descbar .chip` | 12 |
| `pill` | `.waiting-pill` | 14 |

`letter-spacing: .06em` is `tracking = 0.06`; `text-transform: uppercase` is `case = "upper"`;
`font-weight` 500/600/700 is medium/semibold/bold. Set only what the theme changes.

Ornaments `[ornaments]`: `bust`, `scanlines` (the overlay's darkest alpha, e.g. 0.14), `titlebarClock`,
`stateTags` (LIVE/HOLD), `hoverBrackets`, `cardHeader` (`boxDrawing` for Terminal Grid's `┌ ├─ └─`,
`console` for Big Board's header row), `sidebarLegend`. Set only those the theme's CSS draws.

## Done means

Each file follows the shape above, uses only registry paths, and every colour from the prototype
block is accounted for. Report back: the file paths, and a short list of every judgment call you made
(values the CSS could not map one to one), so the lead can check them against the prototype.
