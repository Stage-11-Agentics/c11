# c11 chrome reskin — void aesthetic prototype

A clickable, self-contained HTML mock (`index.html`) of the full c11 window reskinned in the
void-popover language (`docs/void-popover-aesthetic.md`). Same layout, same density, same
affordances as today's chrome — only the skin changes. Tokens are copied verbatim from the
model-picker prototype's CSS variables.

## What's reskinned

- **Titlebar** — surface ground with the §6 header sheen, hairline bottom rule; title drops
  from 13px bold to 12px @ 500 with light tracking. No gold.
- **Workspace sidebar** — matched to main's **workspace-pulse cards** (26a872e8c, Jul 23):
  radius-12 card on `#111318` with identity radial tint + white sheen, header (14px
  semibold title, hover-only ✕), up to two agent summary rows with pulse marks, hairline
  footer ("N agents · N terminals" + per-agent marks row), CPU/RSS metrics,
  `set-status` rows with freshness decay, progress bar, log line, and the 4px
  composition rail segmented by agent state. No unread badge (removed on main).
  **The reskin's sole sidebar divergence:** selection swaps main's 2pt white outline for
  the **2px gold left spine + goldGhost radial**; a waiting agent still tints the border
  gold-ish at 0.38 exactly as main does.
- **Tab bar** — matched to main/bonsplit@2d14dee anatomy: **[agent pulse mark] →
  ["N: title" as one text run, one color] → [close × on the right, always visible]**.
  Pulse marks use main's activity palette (running `#79AEE8` spinner, idle `#78B59E`
  square, cold `#707681` dot, waiting `#D0AA45` "W" badge). Active tab = chrome ground
  lightened (~0.12, per bonsplit) + **3px gold top indicator** (main uses the accent color
  there — in the void language the accent *is* gold, so this is the tab bar's one gold
  moment); flash-new stays the 1.2s transient decay. Text floors raised for contrast:
  unselected white @ 0.72, hover 0.9, selected full white @ 600.
- **Split panes** — divider stays 1px rule. Focused pane gets a 1.5px **gold ring** (the
  workarea's one gold moment, replacing the themed WorkspaceFrame color); unfocused panes
  drop to a hairline rule frame.
- **Browser surface chrome** — url bar as a surface2 input with hairline border (gold @ 0.5
  on focus), nav buttons on the gray ladder.
- **Markdown surface** — fully chrome-owned, so the reskin applies end to end: mono @ 300
  prose, white-opacity ladder, centered section rules flanked by hairlines.

**Gold budget** (one moment per region): sidebar → selected spine · workarea →
focused-pane ring · tab bar → active-tab top indicator (flash-new as transient) ·
titlebar → none.

**Text contrast floor:** no interactive or informational text below white @ 0.55; labels
that were `#555555` dim in v1 now sit at 0.55–0.72 opacity white, with hover lifting a
full ladder step.

## Density: console scale

The chrome runs at "space station controller" density — readable at a glance, clickable
with a trackball without aiming:

- 40px titlebar and tab bar; 32×30 toolbuttons; 20px close targets (always visible, not
  hover-revealed); 26×24 sidebar nav buttons.
- Type one step up across the board: 13.5px sidebar titles, 12.5px tabs, 11.5px telemetry
  rows, 4px progress track.
- Hover feedback is a full ladder step (white wash @ 0.05 + lifted border), with a
  distinct `:active` pressed state on every control.

## Terminal material

Terminal panes are mocked in **#282c34** — the operator's actual Ghostty ground (the
config's `background` is commented out, so Ghostty's default applies). The active tab
picks up this same material tone, reading as "this tab is that content." Chrome stays on
the #0a0a0a void; the grey belongs to Ghostty and the reskin only frames it.

## What's untouchable (Ghostty)

Terminal cell content — colors, fonts, ligatures, cursor, the grid background — belongs to
the user's Ghostty config. The mock renders PTY areas as neutral dark text and says so
inline. The reskin's jurisdiction ends at the ring around each pane; it never assumes
translucency through the terminal ground, and overlay chrome (toasts, popovers) grounds on
#0a0a0a so it works over arbitrary user color schemes.

## Open questions for the operator

1. **Active-tab treatment** — the mock fills the active tab with the terminal material
   tone (#282c34), no indicator bar. In the real app this would mean sampling the user's
   Ghostty background (or falling back to surface2) — worth it, or keep a fixed neutral?
   Alternatively keep bonsplit's 3pt indicator in gold, at the cost of a second permanent
   gold moment in the workarea alongside the pane ring.
2. **Focused-pane ring vs workspace custom colors** — today the frame takes the workspace's
   custom color. Does gold replace that everywhere, or only for uncolored workspaces?
3. **Selected sidebar card** — spine + goldGhost replaces both current styles (`.leftRail`
   and `.solidFill`). Retire the style setting, or keep `.solidFill` as a void-tuned
   variant?
4. **Unread badge** — kept solid gold (it's "the one thing that matters"), but it competes
   with the spine on a selected card. Demote to goldFaint outline?
5. **Light theme** — the void palette is dark-committed (§9.7). This reskin implies the
   Light theme slot becomes a deliberate follow-up project.
6. **Agent analytics as its own screen** (operator note, 2026-07-24) — the sidebar pulse
   cards are accumulating analytics weight (summaries, counts, marks row, composition
   rail, metrics). Fine for now, but start thinking about pulling agent analytics out
   into a dedicated screen so the cards can stay glanceable.
