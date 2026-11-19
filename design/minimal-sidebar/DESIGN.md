# The compact workspace card (C11H-221)

Decision by Atin, 2026-11-05 20:45 to 21:20 PST, confirmed 2026-11-06 12:35 ("love it"), from the five prototypes in this folder
(`index.html`; the chosen page is `04-two-line.html`). The sidebar keeps what carries the
signal, the workspace number, the per-agent marks and the counts, and moves the rest to hover.

## The rule: full cards while they fit, compact once they would scroll

- The sidebar shows today's full cards while every workspace fits without scrolling.
- The moment the cards would scroll, every card becomes the compact card below. Width still
  decides the columns (Tiles at two 162 pt columns); compact cards tile the same way.
- Hysteresis: once compact, the sidebar returns to full cards only when they would fit with
  24 pt to spare, counting each card at the height it measured when last drawn full (a card
  never drawn full counts as the mean). Adding and closing one workspace never flaps the mode.
- Settings ▸ Sidebar Detail ▸ Sidebar Density: Automatic (default), Compact, Cards, is the escape hatch.
- Agents read the shown form as `layout.density` in `sidebar-state --json`.

## The compact card

Two lines, 36 pt at the standard chrome scale (45 pt at Large), fixed. Base sizes are given
at the standard scale and follow the chrome scale like every other sidebar token.

| Element | Role | Meaning |
|---|---|---|
| Name | `type.cardTitle`, `chrome.card.text`, 11.5 pt semibold | The workspace. Truncates with an ellipsis, never wraps. |
| Pin ◆ | `chrome.card.textSecondary` | Pinned workspace. |
| `WS N` | `type.cardLabel`, `chrome.card.textDim` | The `workspace:N` ref. `states.waiting` when any agent waits on the operator; the flag's color when any agent is flagged; `chrome.card.accent` on the selected card. |
| Marks | the app's 9 pt marks, unchanged | One per agent, in priority order: flagged, waiting, working, idle, cold; delegates after non-delegates within a state. 3 pt gap. When they overflow, marks drop from the quiet end and a `+N` tail (`cardLabel`, `textDim`) counts them, so an amber or flagged mark is never hidden. |
| Counts | `type.cardLabel`, `chrome.card.textSecondary`; the waiting slot in `states.waiting` | Three fixed slots, 30 pt each, tabular: agents, waiting on you, terminals (browsers and docs included). A zero slot dims; it never disappears. Kept beside the marks on purpose (Atin, 2026-11-06: "with the count, it gives more balance"). |
| Flag band | background `states.flag` or the named kind's token; everything on it in the ink role (`states.waitingInk`, else the chrome background) | When any agent in the workspace is flagged, the second line becomes a band: a flag glyph, then the marks and counts drawn in ink. Same height as the plain second line. |
| Edge | `chrome.card.border`; selected `chrome.card.borderActive` on `chrome.card.fillActive`; a workspace with its own color draws that color as its 1 pt outline when not selected | Selection is a full-perimeter ring. Waiting does not change the edge in compact mode; the number and the marks carry it, so a column of rows stays calm. |
| Folder header | one 32 pt line (standard scale): chevron, icon, name, flagged and waiting slots, pin, menu | Replaces the 52 pt two-line header; member and unread counts move to its tooltip and accessibility label. |
| Top line | the New Group button at 22 pt | 30 pt on the full cards. |
| Footer | `chrome.pill` roles, about 30 pt | Waiting Agent and Flagged Agents side by side; Flagged appears only while a flag is up and keeps the color-aware behavior that C11H-223 (#247) gave it. Chaos stays a Tiles-only button. |

No close × is drawn in compact mode. ⌘W, the context menu and middle-click still close.

## Hover: the card on demand, and a jump to one agent

- After 150 ms over a row, a popover opens at the row's right edge, over the content, and
  stays open while the pointer is inside it: name and number, the mission, up to fifteen
  agents (mark, panel number, title, subtitle; a flag's reason in the flag's color), the
  census line and the branch. Beyond fifteen, `… and N more`.
- Clicking an agent focuses its panel the way a `c11h://panel` link does: select the
  workspace, reveal the area, pulse the panel. This is the operator's route from twenty
  running agents to one of them.
- Nothing in the sidebar moves when the popover opens or closes.

## Rules

1. Nothing jumps. Fixed row height, fixed count slots, the band replaces the second line in
   place, hover changes color only, the popover overlays.
2. Tabular numerals everywhere, and the count slots are sized for two digits.
3. Theme roles only. Every color and radius on the card maps to an existing schema-2 role
   (`chrome.card.*`, `states.*`, `type.cardTitle`, `type.cardLabel`, `geometry.cardRadius`,
   `geometry.markRadius`, `chrome.pill`). No theme ships a compact-only token. The prototype
   proves it under Nocturne, the stock c11 chrome and Datasheet Mono (key K).
4. The marks are the app's marks. Shape carries state, so they still read in ink on a band.
5. `WorkspaceRowView` stays Equatable and reads only precomputed values; the overflow
   measurement belongs to the sidebar container, never to a per-keystroke path.

## What moved to hover

Mission, the `−% −MB` readout, branch and worktree chips, the status pill, the log line,
progress, metadata blocks, pull requests, ports and the composition rail. The full card still
shows all of them whenever every workspace fits.

## Prototypes

`build.py` writes `index.html` and one self-contained page per prototype. Each page shows its
proposal in a 1470 × 956 pt window (a 14-inch MacBook Pro) beside today's card at the same
height with the same 21 workspaces. Keys: `L` light, `Z` 1:1, `N` names, `T` today strips,
`H` hover, `A` motion, `C` counts, `K` theme, `[` `]` width, `-` `=` workspace count, `1` to
`5` pages, `0` index. Rebuild with `python3 build.py`.

Not chosen: 01 Ledger (second: too compact to read), 02 Rail and 05 Glyphs (the title must
show), 03 Mini tiles (one column of them is this card).

## The build (PR #253)

Screenshots from the tagged build in the build host sandbox guest (1440 × 900 display, 200 pt
sidebar, standard chrome scale), in `shots/`. Three more (twenty workspaces in compact form, the
hover card, the landed jump) show real client workspace names, so they live in the private
c11-ops repo (`design/minimal-sidebar/shots/`), not here.

- `built-nocturne.png`: the same rows under Nocturne.
- `built-full-card-when-it-fits.png`: one workspace left, back to the full card.
