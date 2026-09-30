# Tab sheet round three: worker brief

You build round three of the c11 tab bar redesign. Worktree: `/Users/atin/Projects/Stage11/code/c11/c11-worktrees/tab-sheet-grid`, branch `tab-sheet-grid`. It is stacked on `tab-bar-qol` (c11 PR #459 plus bonsplit PR #5, reviewed and awaiting Atin's hand-check). First run `git submodule update --init --recursive`, which pins bonsplit at `781b108`, then branch bonsplit as `tab-sheet-grid` from there. When #459/#5 merge, rebase onto main; your parent will tell you.

Read first: this worktree's `CLAUDE.md`, `skills/c11-hotload/SKILL.md`, `design/tab-bar-qol/BRIEF.md` (round one, for context), and the round-one code: `vendor/bonsplit/Sources/Bonsplit/Internal/Views/CollapsedTabSheet.swift` and `TabBarView.swift`.

Parent: Cairn at `surface:159`, `workspace:14`. Report with `c11 send --workspace workspace:14 --surface surface:159 "<msg>"` at each phase change, when blocked, and at the end with PR links. Do not merge.

## Binding design

`design/tab-bar-qol/prototype-v3.html`. Serve it (`python3 -m http.server` from that dir) and open it in a c11 browser surface; its tokens and column widths are the spec. `prototype-v2.html` is history only: its NEW badge and "with new output" footer are cut.

## What changes

1. **Dark palette.** The sheet, the collapsed header block and the count cell move to the prototype's near-black tokens: sheet `#0e0f12`, row hover `#1b1d22`, active row `#17181c`, header and footer `#0a0b0d`, separators `#202227`, border `#3a3c44`, block `#111215`, count cell `#07080a`. The gold rules stay. c11 has Light and Dark theme slots, so go through the appearance-aware `TabBarColors` functions. In a light theme, the block and sheet should still be the highest-contrast surface; choose the equivalent and show it in a screenshot.
2. **Title bar under the tabs** (`Sources/SurfaceTitleBarView.swift` and its host). Stop repeating the tab title. The bar shows only the live description; with no description, it takes no height at all. This applies in every tier. Keep rename and description editing reachable wherever they already live (check the tab context menu and double-click), and don't strand an affordance that exists only in this bar.
3. **Count cell on every tab bar.** The full tier gets the same count cell as the collapsed tiers (`N ▾`, same size, same styling, background-waiting dot). It sits at a fixed spot at the right end of the tab strip, immediately left of the controls cluster, so it never moves as tabs change. It opens the same sheet. Fold its width into the tier math (`estimatedChromeWidth` and related) so the tier thresholds stay exact.
4. **The sheet becomes a fixed grid.** Two-line rows of 46pt. Columns: `Tab N` (68pt, right-aligned, monospaced) · activity mark (18) · title (the only flexible column, minimum 260) · agent (150) · status (104) · one column per clock (78 each) · close (22, visible on hover, space always reserved) · grip (24, `⋮⋮`, at the far right). There is a header row: TAB, TITLE, AGENT, STATUS, then the clock names. Line 1 carries the title, agent tag, status and clocks. Line 2 carries the subtitle (the tab's description, with fallbacks: cwd for a shell, host for a browser, path for markdown), spanning the title, agent and status columns. Rules:
   - An empty cell shows `—`; it never collapses. Text truncates inside its column. Use tabular numerals. Nothing moves when text changes length or when a clock ticks.
   - The visible tab has a bold title, a gold `Tab N` and the gold 3pt left rule.
   - Rows stay in tab order. Dragging still works: the grip is the visible affordance, and the whole row stays draggable as in round one.
   - The footer reads `N tabs` plus `K need you` (waiting + flagged) in amber.
   - Width comes from the columns; clamp it to the screen. Collapsed tiers anchor flush-left under the bar as now. The full tier anchors the sheet's right edge to the count cell's right edge.
   - Relative times refresh about once a second, and only while the sheet is open.
5. **`Tab N` labels.** The number column reads `Tab 171`. Atin wants people to say "tab 171", so make it localizable ("Tab %d").
6. **Agent tag.** `Harness · model` for Claude Code, Codex, Pi and OMP, plus any other kind c11 already identifies (grok, kimi, opencode, …). Draw on c11's existing agent identity: launch-agent metadata, `set-agent`, the session-resume wrappers and the conversation strategies. If the model is unknown, show the harness alone; if there is no agent, show `—`. If a harness has no model detection today, report it rather than inventing a guess.
7. **Status.** The state word and how long it has held: `working 12m`, `waiting 6m` (amber), `flagged 14m` (violet), `idle 48m`. Use the existing activity state and its timing (the activity tooltip work in `5e6360bb5` records it).
8. **Clocks.** **Active** is the time since the tab last produced output or an agent last wrote to it. **Launched** is the time since the tab opened (panels already carry `createdAt`). The order comes from one ordered list with default `active,launched`. Make it changeable by an agent in one command: use the simplest mechanism c11 already has for settings (a user default or the settings file), and document it in `skills/c11/SKILL.md`. Unknown names are ignored. Also accept `seen` and render it as `—` for now, because C11-243 (last-seen tracking, built in parallel on another branch) will supply the value.

## Architecture

Bonsplit stays generic. Add a host-provided per-tab detail model (for example a `BonsplitTabDetail` with agent label, subtitle, status and since, and a named-clock dictionary) through the existing delegate/configuration seam. c11 fills it from its panels and metadata; bonsplit only renders it. Don't poll: recompute when metadata changes or the sheet opens, and use the 1s ticker only for relative time text.

## Constraints

- Localize all new strings in all 7 locales (en, ja, ko, ru, uk, zh-Hans, zh-Hant) in the same commit, as round one did.
- Builds go through the lock (`./scripts/reload.sh --tag tab-sheet-grid`) and run incrementally. Run only targeted tests, never the full suite on this machine. Another agent (C11-243) builds in parallel through the same lock.
- **No synthesized drags, ever, on this machine.** Don't activate the app or steal focus while Atin is working. If you need a click to reach a state (for example opening the sheet), ask your parent first and keep it to a few. Prefer socket and CLI state setup plus window screenshots (`screencapture -l <windowid>` doesn't take focus). Atin does the drag checks by hand from a numbered script you write.
- c11-specific chrome, so no upstream cmux PR. Bonsplit changes go through a bonsplit PR on `Stage-11-Agentics/bonsplit`, with the c11 submodule bump in the c11 PR, linked both ways.

## Done means

- Two open PRs (bonsplit, then c11) with screenshots in both themes: the collapsed sheet, the full-tier sheet opened from the new count cell, a row with no agent (dashes), a flagged row, a long title and a long subtitle truncating without shifting columns, and the title bar with and without a description.
- A numbered manual check script for Atin in the c11 PR body: drag a row by its grip to another area, reorder rows, and check the full-tier count cell.
- Test results for the targeted tests only.
- Commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
