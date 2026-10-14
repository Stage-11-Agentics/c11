# Launch Panel v2 — panel + settings prototype

Iteration on the C11-175 model picker after the first live review of the shipped popover
(2026-07-24). Operator direction: keep the aesthetic, change the mechanics. Rev 2 folds in
the operator's decisions from the first prototype pass.

**Open it:** `c11 browser open file://$(pwd)/docs/design-prototypes/launch-panel/index.html`
Self-contained, no deps. Both stages render side by side: the window+panel, and Settings.

## The design (operator-decided, 2026-07-24)

1. **Popover → panel, centered on the pane.** Appears instantly (zero entrance animation),
   centered over the pane whose A button was right-clicked — "it displays centered on that
   pane." Non-transient: stays open until esc, ✕, or toggling A. Launching keeps it open.
2. **Left column — "User Configurations."** Saved full recipes: harness + model + effort +
   **custom system prompts** (gold chip: `·blank·`, `+append`). No number badges, no pin
   gesture — see 6.
3. **Right column — "Harnesses."** One row per harness enabled on this machine. Each row
   carries two **dropdowns — agent (model) and effort — preset to that harness's base
   defaults**, so a quick tweak-and-↵ launches a one-off without minting a config. A
   dropdown moved off base goes gold (`.changed`). Harnesses without an effort axis show
   an inert "—" dropdown. Disabled/undetected harnesses roll up into "+N — enable in
   Settings."
4. **Panel stays focused on launching.** No in-panel config management — a single
   **circled ⚙ button in the header** (⌘,) deep-links to Settings — Agent Configuration
   (which owns config management, harness enablement, and launch stats). No footer rows.
5. **Keyboard: ↑↓ and ↵ only.** No 1–9 number launching. Esc closes.
6. **Launch sets the system default.** No "follow recent" checkbox, no pin ceremony:
   whatever was launched last from this panel IS the system-level default for a plain
   A-click. The ● + DEFAULT tag are pure display of where that landed. Uniform rule —
   a tweaked-dropdown harness launch becomes the default too, shown unnamed.
7. **↵ launches AND closes the panel.** Persistence covers everything short of launch:
   browsing, dropdown tweaking, pinning, focus loss. Launch = intent fulfilled, get out
   of the way of the pane the agent is booting in.
8. **No toast, ever.** When a harness row's dropdowns move off base, a quiet gold
   **+ save** button materializes inline on the row — save the recipe as a User
   Configuration right there, or don't. Fast, hacker, effortless.
9. **Dropdowns are mouse-only.** Keyboard ↵ on a harness row launches its base. No
   focus traversal into dropdowns.
10. **⌘⇧A opens the same panel centered on the focused pane.**

## Settings — Agent Configuration (stage 2)

A **new pane named "Agent Configuration"** (operator: existing Agents & Automation pane
is disliked; this replaces it — migrate what's needed, then retire it). Manages exactly
the panel's two objects, no modal-in-modal:

- **User Configurations**: drag-reorder list, inline mini-editor (model/effort chips with
  ○ inherits / ● override states), read-only default strip (default = last launched).
- **Harnesses**: detected-on-machine grid; enable toggle = appears in the panel; select
  a card to edit its **base recipe** inline below — command, default model, default
  effort, initial prompt, env. This absorbs everything the old Agents & Automation pane
  (`DefaultAgentSettingsView`) held: per-harness command/model/effort/prompt/env, reset
  to factory. Its default-agent picker and follow-recent toggle are superseded by
  launch-sets-default and do not migrate.
- **Launch stats** live here (panel shows nothing but the ⌘, row).

## Perf note for the implementation (the v1 slowness)

The shipped popover rides bonsplit's SwiftUI `.contextMenu` on the A button:
right-click → AppKit menu-tracking session → SwiftUI evaluates menu content →
`menuItemsForNewTabKind` side-effect → `DispatchQueue.main.async` hop →
`NSPopover` with `animates = true`. Every stage adds latency; `.contextMenu` itself is
the dominant cost. v2 should:

- intercept right-mouse-down on the A button directly (no menu session at all),
- present a borderless child window / panel centered on the pane, `animates = false`,
- keep the model build lazy-cheap (install probe already cached; stats headline moves
  to Settings anyway).

## Still open

- UX audit findings (gpt-5.6-sol xhigh → UX-AUDIT.md; Fable 5 → UX-AUDIT-FABLE.md) —
  fold in once both land.
- Real model lists per provider for the dropdowns (operator to supply; mocks are stale).
