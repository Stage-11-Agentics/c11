# CMUX-12: Pane title bar chrome & theming

Render pane titles (from the pane metadata layer in CMUX-11) as first-class UI chrome — a centered strip above the pane that communicates identity at a glance, parallel in contract to the existing surface title bar, and themed consistently with it.

DEPENDS ON: CMUX-11 (pane metadata & naming) Phases 1 and 2 must merge first so the view has data to read.

DESIGN DECISIONS (from scoping conversation):

1. Centered title text, mirroring the surface title bar contract.

2. Optional — only renders when pane.metadata.title is set. Unnamed panes look unchanged for operators who don't adopt the habit. (Distinct from surfaces, which render chrome even for unnamed surfaces.)

3. Expand chevron toggles between title-only and title+description, matching the existing surface title bar affordance.

4. Dismissible via right-click → Hide. Dismissal is ephemeral session state (paneTitleBarUserCollapsed, reset per restart, matching Tier 1's ephemeral-state decision for surfaces). The underlying pane.metadata.title is untouched. Clearing the title permanently is a separate action (cmux clear-metadata or inline rename to empty).

5. Right-click context menu:
   - Rename… — flips the strip into an inline TextField, populated with the current title, that writes back via pane.set_metadata on Return. Cancel on Escape or click-away. Gives operators a first-class in-app renaming path without the CLI.
   - Hide title bar — per (4).
   - Expand / Collapse — toggles chevron state.

6. Theming unification: consumes the same theme tokens as surface title bars via the in-flight c11mux theming plan. Both layers feel like one system.

7. Dual-title rendering: when both pane and active surface are named, render both — pane title on top, surface title directly below. The stack reads as a path from 'why this pane exists' to 'what is showing in it right now.' Each strip retains its own collapse/dismiss behavior.

8. Bonsplit stays unopinionated; c11mux SwiftUI layers render the chrome above the pane, not bonsplit itself.

PHASES (each a PR):

Phase 1 — PaneTitleBarView (visible strip, chevron, collapse/expand wired up, no menu yet). This is the first user-visible milestone.
Phase 2 — Context menu (Rename, Hide, Expand/Collapse) + inline rename with first-class operator UX.
Phase 3 — Theming token unification with the theming plan's output.

PLAN DOC: docs/c11mux-pane-title-bar-plan.md

RISKS:
- Typing latency: any SwiftUI view added to the pane host is hot-path risk. Mitigation: strict hot-path review in Phase 1; view is equatable and only re-evaluates when title metadata changes.
- Chrome proliferation: multi-surface panes stack pane title + surface titles + tabs. Mitigation: decisions 2 (optional) and 4 (dismissible) let operators trim to taste.
- Theming plan churn: Phase 3 depends on theming plan's final token shape. Mitigation: Phase 1 ships with ad-hoc parity to surface title bars; Phase 3 migrates to formal tokens when they land.
