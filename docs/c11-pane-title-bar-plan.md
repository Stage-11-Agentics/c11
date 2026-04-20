# c11 — Pane Title Bar Chrome & Theming Plan

**Status:** plan (not scheduled). **Author:** conversation 2026-04-18.
**Scope:** visual chrome that renders a pane's title (from the metadata layer shipped in the companion plan) as a first-class UI primitive, parallel in contract to the existing surface title bar, and themed consistently with it.
**Depends on:** [Pane metadata & naming plan](./c11-pane-naming-plan.md) — pane titles must exist in the metadata store and persist before this plan adds a view for them.
**Adjacent to:**
- In-flight c11 theming plan (sibling workstream) — pane title bars must inherit the same theme tokens as surface title bars so both layers feel like one system.
- [Pane dialog primitive plan](./c11-pane-dialog-primitive-plan.md) — pane title bars and pane-anchored dialogs share pane-scoped geometry. This plan coordinates the vertical stacking so dialog scrims do not occlude the title bar.
**Non-goals:** the metadata mechanism itself (companion plan), window-level chrome, sidebar changes beyond what is needed to reflect a pane title when relevant.

---

## Motivation

Panes are the spatial unit an operator navigates. With the companion plan, a pane can carry a title that describes its role in the task graph (e.g. `Login Button :: Code Review`). That title is invisible today outside of `cmux tree` and RPC responses — an operator glancing at the pane sees only the active surface.

A proper chrome layer makes the title useful: a centered strip above the pane that communicates the pane's identity at a glance, parallel in contract to the surface title bar. The user's framing: "a beautiful set of primitives — if users want to put titles on top of panes, we should do that."

The contract mirrors surfaces deliberately. Operators already know how the surface title bar behaves (collapse/expand chevron, dismiss, description toggle). The pane title bar should feel like the same thing at a different scope, so there is no new mental model to learn.

---

## Decisions (locked from scoping conversation)

1. **Centered title text.** Horizontal center, mirroring the surface title bar contract.
2. **Optional — only shows when a title is set.** When `pane.metadata.title` is unset, no chrome renders. This keeps empty panes visually unchanged for operators who don't adopt the naming habit. (Distinct from surfaces, which render a title bar even for unnamed surfaces — panes default to invisible chrome.)
3. **Expand chevron.** Same affordance as the surface title bar: expanded state shows description (and whatever else the surface title bar shows when expanded); collapsed shows title only.
4. **Dismissible (hide) — not destructive.** Right-click → Hide (or click an explicit close affordance) toggles the chrome off for the current view, matching the ephemeral `titleBarCollapsed` / `titleBarUserCollapsed` pattern surfaces use. The underlying `pane.metadata.title` is untouched. To clear the title permanently, the operator uses `cmux clear-metadata --pane <ref> --key title` or right-click → Rename and submits empty text.
5. **Right-click context menu.** On the pane title bar strip:
   - **Rename…** — opens an inline edit affordance (text field), populated with the current title, that writes back via `pane.set_metadata` on commit. The same path an agent uses; operator gets a first-class rename surface without going to the CLI.
   - **Hide title bar** — dismisses chrome per (4).
   - **Expand / Collapse** — toggles the chevron state.
   - Future: Clear title, Copy title, etc. Not in this PR.
6. **Theming unification.** Pane title bars use the same theme tokens (background, text color, divider, hover states) as surface title bars. The theming source of truth is whatever the in-flight theming plan establishes; this plan consumes it rather than forking tokens.
7. **Dual titles when both pane and active surface are named.** Render both: pane title on top, surface title directly below. Visually the stack reads as a path from "why this pane exists" to "what's showing in it right now." Each strip retains its own collapse/dismiss behavior. When only one is set, only that one renders.
8. **Dismiss state is per-pane, ephemeral.** `titleBarCollapsed` / `titleBarUserCollapsed` for panes behaves the same as for surfaces in the Tier 1 persistence plan: reset to default on restart. Persisting dismissal is deferred until operators ask for it.
9. **Bonsplit stays unopinionated about c11 chrome.** The title bar is rendered by c11 SwiftUI views layered above the bonsplit pane, not by bonsplit itself. This preserves the principle that bonsplit is a split-tree primitive.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ PaneTitleBarView (new) — mirrors SurfaceTitleBarView     │  ← Phase 1
├──────────────────────────────────────────────────────────┤
│ Context menu + inline rename action                      │  ← Phase 2
├──────────────────────────────────────────────────────────┤
│ Theme tokens shared with surface title bars              │  ← Phase 3
├──────────────────────────────────────────────────────────┤
│ PaneMetadataStore + Pane RPCs (companion plan)           │  ← already built when this ticket starts
├──────────────────────────────────────────────────────────┤
│ Bonsplit pane (unopinionated — c11 layers above)         │  ← unchanged
└──────────────────────────────────────────────────────────┘
```

Each phase is its own PR. Phase 1 ships a minimal visible strip tied to `pane.metadata.title`, with only collapse/expand wired up. Phase 2 adds the context menu and inline rename. Phase 3 brings in the theming plan's tokens and polishes visual parity with surface title bars.

---

## Phase 1 — `PaneTitleBarView`

**Deliverable:** a SwiftUI view that renders a pane's title in a centered strip above the pane. Visible when `pane.metadata.title` is set, hidden otherwise. Collapse/expand chevron works. No right-click menu yet.

### Current state

- `SurfaceTitleBarView` (existing surface title bar view) defines the visual contract: centered text, chevron, expand-to-show-description. Layout and styling are the reference this phase parallels.
- Panes in c11 host content via the pane portal + SwiftUI layering in `Sources/Panels/` and the terminal window portal (`Sources/TerminalWindowPortal.swift`). There is no pane-level SwiftUI wrapper that sits *above* the content view; the pane's content currently extends to the pane bounds.
- The Tier 1 persistence plan notes `titleBarCollapsed` / `titleBarUserCollapsed` are ephemeral state on surfaces today, reset per restart (decision 4 in that plan).

### Target state

- **New view:** `Sources/Panels/PaneTitleBarView.swift`. Structure and props parallel `SurfaceTitleBarView`:
  - `title: String`, `description: String?`, `isExpanded: Bool`, `onToggle: () -> Void`.
  - Renders a fixed-height strip with centered title, chevron on the leading edge (matching surface chevron position).
  - Expanded state shows description below the title.
- **Pane container layout:** the pane's content view gets a host container that stacks `PaneTitleBarView` (optional) over the current pane content. When `pane.metadata.title == nil` and `activeSurface.metadata.title == nil`, no chrome; otherwise the relevant strip(s) render per decision 7.
- **State plumbing:** `paneTitleBarCollapsed` / `paneTitleBarUserCollapsed` ephemeral state mirrors the surface pattern, keyed by `PaneID`. Default is expanded (matching surface default).
- **Title resolution:** reads `PaneMetadataStore.value(for: .title, pane: paneId)` from the companion plan's store. Updates via a small observer on the store's revision counter.

### Typing-latency safety

The pane title bar must not introduce work into the typing hot path. The title view reads the store on mount and on revision-counter change; it does not subscribe to per-keystroke events. Reference the project CLAUDE.md's "Typing-latency-sensitive paths" note — any `@EnvironmentObject` or `@ObservedObject` added here must be validated against `TabItemView`'s equatable pattern before merge.

### Tests

- Snapshot test: named pane renders the strip with centered title; unnamed pane renders no chrome.
- Expand/collapse toggle updates the layout without mutating `pane.metadata`.
- Store change (title set/cleared via RPC) updates the view within one runloop tick.
- Typing-latency assertion: `dlog` before and after a keystroke in a terminal surface inside a named pane should show no additional allocations from the title bar's path.

### Not in this phase

No right-click menu, no rename UI, no theming polish beyond reusing existing surface title bar tokens.

---

## Phase 2 — Context menu + inline rename

**Deliverable:** right-click on the pane title bar opens a context menu (Rename, Hide, Collapse/Expand). Rename opens inline edit.

### Current state

Surfaces have right-click menus for tab operations in the bonsplit tab bar, but not on surface title bars themselves (the title bar is passive display today). This phase introduces right-click semantics at the title bar level as a new interaction surface.

### Target state

- **NSMenu / SwiftUI context menu** attached to `PaneTitleBarView`:
  - **Rename…** — dismisses the menu, flips the title strip into an editable `TextField` populated with the current title, focuses the field. On Return: submits via `pane.set_metadata`. On Escape or click-away: cancels without write. Error surface: if the write fails (cap exceeded, invalid target), show a brief inline error banner and restore the original title.
  - **Hide title bar** — sets `paneTitleBarUserCollapsed = true` (or equivalent "hidden entirely" flag — see below). To re-show, operator sets a title via CLI or another pane-level command (future: menu item elsewhere to re-enable).
  - **Expand / Collapse** — toggles the chevron state, identical to clicking the chevron.
- **Hide vs. collapse distinction:**
  - *Collapse* shrinks the strip to title-only (hides description).
  - *Hide* removes the strip entirely for this session.
  - Both states are ephemeral per decision 8. Hide is "stronger" dismissal; collapse is "compact view."
- **Localization:** all menu items and placeholders are localized via `String(localized:...)` per project CLAUDE.md. Keys added to `Resources/Localizable.xcstrings` with English + Japanese translations.
- **Accessibility:** menu items have accessibility labels; inline rename field announces as a text input.

### UX polish

- Rename commits with Return, cancels with Escape. No confirmation dialog — trust the operator, matching the "it's text" philosophy from the companion plan.
- After rename commit, briefly flash a subtle highlight on the strip to confirm the write landed. Same affordance surfaces use today when their title changes.

### Tests

- Unit: context menu builds with correct items given pane state (title set vs. unset).
- Integration: right-click → Rename → type → Return → verify `pane.metadata.title` updated via `lattice`-style round-trip (simulated RPC).
- Hide → re-show path: hide via menu, set title via CLI, strip re-appears.

### Not in this phase

- Sidebar or tab-bar-level indication of pane title changes (downstream polish).
- Undo of rename (a general c11 capability to add later, not specific to panes).

---

## Phase 3 — Theming unification

**Deliverable:** pane title bar chrome consumes the same theme tokens as the surface title bar. Both layers feel like one system.

### Current state

The c11 theming plan (in-flight, sibling workstream) is establishing a token system for colors, typography, and spacing. Surface title bars are a consumer. This phase aligns pane title bars with the same source.

### Target state

- Pane title bar uses `Theme.titleBar.*` tokens (or whatever naming the theming plan lands on) — background color, text color, divider color, hover/focused states, typography scale.
- When theming changes (user switches theme), both surface and pane title bars update together.
- Dual-title rendering (decision 7) uses subtly different weights or opacity to distinguish pane (primary, top) from surface (secondary, below) without requiring two color tokens. The goal: the stack reads as a single nested identity, not two competing strips.

### Tests

- Snapshot tests at each supported theme; verify pane and surface title bars render consistent token values.
- Theme switch observable: change theme, both bars repaint within one runloop tick.

### Not in this phase

Theming of other pane-scoped chrome (scrollbars, focus rings, etc.) — that's the theming plan's scope, not this one.

---

## Open questions

1. **Where exactly does the pane title bar sit vertically?** Above the pane's content (pushing surfaces down) vs. overlaid at the top edge (covering a pixel row). Above-and-pushing matches the surface title bar model; overlay is less intrusive but can hide terminal content. **Recommendation:** above, matching surface title bars. Confirm when wireframing Phase 1.

2. **Sidebar reflection of pane titles.** The sidebar today groups by surface/workspace. Does a named pane get its own row, or does the pane name appear as a grouping label above its surfaces? This crosses into sidebar design territory — **defer to a follow-up**. Phase 1 only touches in-pane chrome; sidebar adjustments are a separate smaller PR.

3. **Re-showing a hidden title bar.** Once an operator hides the title bar via right-click, how do they re-show it? Options: (a) a menubar command, (b) right-click on the pane body (not the title bar), (c) automatic re-show when the title changes via RPC. **Leaning toward (c) plus (a) as a belt-and-suspenders** — if the title changes, the strip comes back; and there's a menubar entry for operators who want to force it.

4. **Dual-title rendering when one is hidden.** If the pane title bar is hidden but the surface title bar is visible, does the surface title bar look the same as before this plan, or slightly adjusted? **Recommendation:** identical to today. The pane title bar's presence is additive.

5. **Dismissing the inline rename field.** If the operator clicks outside the field, do we commit or cancel? macOS convention varies. **Recommendation:** cancel on click-away, commit only on explicit Return. Matches most text editing affordances in the app.

---

## Rollout

Phase 1 → Phase 2 → Phase 3, each its own PR.

- **Phase 1** is the visible milestone: operators can see pane titles in the UI for the first time. Ship behind no flag — the chrome is optional and only renders when titles are set, so the risk surface is small.
- **Phase 2** adds the interaction surface that makes operator-level naming practical without CLI.
- **Phase 3** is polish; can land concurrently with or after the theming plan's v1.

This ticket blocks on the companion plan's **Phase 1 + Phase 2 merged** (store and RPCs must exist before the view has data to read). Persistence (companion Phase 3) and skill guidance (companion Phase 4) can land in parallel with this ticket's phases.

## Touched code (by phase)

- **Phase 1:** `Sources/Panels/PaneTitleBarView.swift` (new), `Sources/Panels/PaneHostView.swift` or equivalent (wrap pane content with optional title bar), `Sources/TerminalWindowPortal.swift` (verify hitTest remains pointer-only per the typing-latency note), unit + snapshot tests.
- **Phase 2:** Same files plus menu assembly, `Resources/Localizable.xcstrings` additions, rename field state management.
- **Phase 3:** Token consumption updates; theming plan's output drives concrete edits.

---

## Risks

- **Chrome proliferation.** A pane with multiple surfaces plus a pane title bar plus per-surface title bars plus a tab bar plus a status chip is a lot of vertical chrome. Mitigation: decisions 2 (optional rendering) and 8 (easy dismissal) plus the dual-title collapse option means operators can trim to taste.
- **Typing latency regression.** Adding any SwiftUI view to the pane host is risk territory per project CLAUDE.md. Mitigation: strict hot-path review in Phase 1; the view is equatable and only re-evaluates when title metadata changes.
- **Theming plan churn.** Phase 3 depends on the theming plan's final token shape. Mitigation: Phase 1 ships with ad-hoc parity to surface title bars (copy the tokens); Phase 3 migrates to the formal token system when it lands. No blocking dependency.
- **Discoverability of Hide → Re-show.** Operators who hide a title bar may not know how to bring it back. Mitigation: the default behavior in open question 3 (re-show on title change) plus a menubar command covers the common case.
