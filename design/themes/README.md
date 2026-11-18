# c11h theme prototypes

`c11h-themes.html` is the c11h window rebuilt in one self-contained HTML page: the
titlebar, the workspace sidebar with its cards and the Waiting Agent pill, two areas with
their panel strips, description bars, terminal content, prompt and status lines. The
content is fixed mock data taken from a real session on 2026-11-02; only the theme changes.

Open the file in any browser (it is local, loads nothing from the network, and uses fonts
already installed on the laptop: SF Pro, SF Mono, JetBrains Mono, Iowan Old Style). Switch
themes with the strip at the top, the keys `1` to `7`, or the arrow keys. The hash remembers
the theme, so `c11h-themes.html#nocturne` opens on that one.

| Key | Theme | Family | One line |
|---|---|---|---|
| 1 | c11 | baseline | plain c11: the grey chrome as it ships |
| 2 | Datasheet Mono | Datasheet Mono | by the spec in `~/src/aesthetics/datasheet-mono/AESTHETIC.md`: square, 1 px rules, mono caps, international orange only where something needs you (the waiting pill, the waiting marks, the waiting area's frame), inversion for the selected tab, brackets outside clickable things on hover. Atin, 2026-11-02: the first cut had too much red; bars, caret, mail and running state went back to ink |
| 3 | Terminal Grid | Datasheet Mono (reference) | the chrome drawn in one character grid: box-drawing trees in cards, dotted rules, a `$ c11h` header, grey on near-black, orange for the live thing |
| 4 | c11h today | Vaporwave | c11's grey chrome with the Sunset Mall gradient behind the sidebar, as c11h ships now (a full-chrome Sunset Mall was tried and dropped as weak, Atin 2026-11-02) |
| 5 | Outrun Horizon | Vaporwave | darker night, the neon horizon, a cyan perspective grid on the sidebar floor, scanlines, hot pink for the live thing, chrome-gradient title, a marble bust rising in the Waiting Agent pill |
| 6 | Nocturne | high-end dark | matte near-black, hairline rules, SF Pro Display for names, tracked JetBrains Mono caps for every label, one cold accent, amber only for what needs you; no glow, no material |
| 7 | Big Board | high-end dark | mission control: console cards with a header row, LIVE and HOLD tags, green for running, amber for waiting, a segmented clock in the titlebar |

What stays constant across themes, on purpose:

- Every UI element of c11h and its placement. Themes change tokens (colour, type, radius,
  rules) and a few flourishes, never the layout.
- Terminal text and its ANSI colours are Ghostty's and follow `c11 terminal-theme`, not the
  chrome theme. The terminal background does follow the theme here so each page reads as a
  whole; in the app that pairing would be a terminal-theme choice.

Rules of taste honoured (from `aesthetics/README.md`): no coloured left-edge strips, kind
carried by full-perimeter outlines, nothing jumps (fixed heights, reserved space, tabular
numerals).

Where the themes would land in the app: the chrome theme engine plan,
`docs/c11-theming-plan.md`, and the c11h sidebar background setting,
`Sources/C11HSidebarBackground.swift`.

## Built (theme schema 2)

Every prototype theme ships as a bundled chrome theme; `c11h themes set <name>` selects it
(design: `docs/c11h-theme-schema-2.md`). Screenshots from a tagged build in a sandbox guest, one real
agent waiting, are in `shots/`.

| Key | Prototype | Bundled theme | Shot |
|---|---|---|---|
| 1 | c11 | `stage11` (schema 1; with Sidebar Background None for plain grey) | `shots/stage11.png` |
| 2 | Datasheet Mono | `datasheet-mono` | `shots/datasheet-mono.png` |
| 3 | Terminal Grid | `terminal-grid` | `shots/terminal-grid.png` |
| 4 | c11h today | `c11h` (and `stage11`, whose Dark slot falls back to Sunset Mall) | `shots/c11h.png` |
| 5 | Outrun Horizon | `outrun-horizon` | `shots/outrun-horizon.png` |
| 6 | Nocturne | `nocturne` | `shots/nocturne.png` |
| 7 | Big Board | `bigboard` | `shots/bigboard.png` |

Not yet carried from the prototype: area frames (focused blue, waiting gold), the terminal
background (Ghostty's, `c11h terminal-theme`), dotted and dashed rules, title prefixes (`$ c11h ·`,
`WS 06`), and JetBrains Mono on Macs without it (SF Mono stands in). The schema-1 copies of
`nocturne`, `bigboard` and `datasheet-mono` in the user themes folder shadow the bundled ones and
must be removed once a schema-2 build is installed. `archive/toml-schema1/` holds those superseded schema-1 drafts.
