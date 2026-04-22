# C11-10: Per-surface tab colors inside panes

## Working Vocabulary

- **Workspace color**: existing workspace/sidebar/theme accent stored on `Workspace.customColor`.
- **Surface tab color**: new per-surface color for the tab inside a Bonsplit pane.
- **Surface/panel**: c11-owned terminal/browser/markdown runtime object keyed by panel UUID.
- **Bonsplit tab**: visual tab-strip model item keyed by `TabID`, currently mirrored from the c11 panel.

Use "surface tab color" in code comments, socket docs, and CLI help when ambiguity matters. Avoid adding more plain "tab color" APIs without a nearby qualifier.

## Architectural Decision

The source of truth should live in `Workspace`, keyed by panel/surface ID, not in Bonsplit alone and not only in surface metadata.

Reasons:

- c11 already owns panel-scoped identity state in `Workspace`: custom titles, pinned state, unread state, git/PR/sidebar state, directories, and listening ports.
- Session persistence already snapshots panel-scoped c11 state in `SessionPanelSnapshot`.
- Socket/CLI APIs already target surfaces by panel UUID.
- Bonsplit is the renderer and interaction model for tabs; it should receive a renderable color field through `TabItem`, but it should not become the persistence authority.
- Surface metadata can mirror this later for Lattice/agents, but first-class UI state should not depend on opaque manifest keys.

## Proposed Data Model

1. Add panel-scoped color state to `Workspace`:

   - `@Published private(set) var panelCustomColors: [UUID: String] = [:]`
   - `func setPanelCustomColor(panelId: UUID, color: String?)`
   - `func panelCustomColor(panelId: UUID) -> String?`
   - Normalize via the existing `WorkspaceTabColorSettings.normalizedHex`.

2. Extend session persistence:

   - Add optional `customColor: String?` to `SessionPanelSnapshot`.
   - Write from `panelCustomColors[panelId]`.
   - Restore in `applySessionPanelMetadata`.
   - Keep it optional for backward compatibility with old snapshots.

3. Extend transfer/move paths:

   - Add `customColor` to `Workspace.DetachedSurfaceTransfer`.
   - Preserve it through detach/attach and cross-workspace/window surface moves.
   - Same-workspace reorder and cross-pane move should carry it automatically through the panel ID state.

4. Extend Bonsplit tab model:

   - Add optional `accentColorHex` or `customColorHex` to `Bonsplit.TabItem` and public `Bonsplit.Tab`.
   - Add matching `createTab` and `updateTab` parameters.
   - Decode missing values as nil.
   - Keep Bonsplit validation minimal; c11 validates before update.

Prefer `accentColorHex` inside Bonsplit if this looks upstreamable. Use c11 names like `setPanelCustomColor` in c11 code. If touching Bonsplit beyond a generic accent field/rendering, flag it as an upstream candidate for cmux/Bonsplit.

## Rendering

Start with a restrained visual marker, not a full tab repaint:

- Selected tab: keep the current selected background; use the surface tab color as the top accent indicator and/or a small leading rail/dot.
- Unselected tab: show a thin top/leading accent or small swatch so color remains visible without becoming the dominant chrome.
- Hover, close, dirty, unread, pin, loading spinner, favicon, shortcut hints, and zoom affordances must remain legible.
- Color should be brightened/adjusted for dark appearance using the same display helper currently used for workspace color swatches.

Implementation seam:

- Add color resolving helpers in Bonsplit rendering or pass already-normalized hex to Bonsplit and let `TabItemView` convert to `Color`.
- If using c11-only helpers in Bonsplit would create unwanted coupling, add a small Bonsplit-local hex parser/contrast helper or precompute display hex in c11.

## UI Entry Points

Add a tab context-menu submenu in `vendor/bonsplit/.../TabItemView.swift`:

- `Tab Color`
- `Clear Color` when set
- `Choose Custom Color...`
- palette entries

Thread actions through `TabContextAction`, likely with:

- `clearColor`
- `chooseCustomColor`
- `setColor(String)` is not possible with the current raw-value enum shape, so either:
  - add a dedicated callback for color selection, or
  - evolve `TabContextAction` from a raw enum into an enum with associated values.

Prefer the least disruptive path:

- Add `case clearColor` and `case chooseCustomColor`.
- For palette color selections, add a new Bonsplit callback such as `onSetColor(hex)` / delegate method if needed.
- Handle color dialogs in `Workspace`, mirroring existing workspace color prompt behavior.

All strings must use localization. Bonsplit currently has some bare strings in this menu; do not expand that debt. New strings should go through the existing localization path used by nearby localized context buttons.

## Palette And Settings

The existing `WorkspaceTabColorSettings` helper is useful but poorly named for this feature because it currently means "workspace sidebar tab colors."

Recommended approach:

1. In the implementation PR, introduce a clearer wrapper or rename target:
   - `SurfaceColorPaletteSettings` if it will serve only this feature, or
   - `C11ColorPaletteSettings` / `WorkspaceColorPaletteSettings` if shared by workspace and surface colors.
2. Keep compatibility with existing UserDefaults keys:
   - `workspaceTabColor.defaultOverrides`
   - `workspaceTabColor.customColors`
3. Avoid migrating settings keys unless there is a separate explicit migration slice.

User-facing copy should distinguish:

- **Workspace Color**: sidebar/workspace identity.
- **Tab Color** or **Surface Tab Color**: individual tab in a pane.

## Socket And CLI

Add surface-scoped API, not workspace-scoped API:

- V2 method: `surface.set_custom_color`
  - params: `surface_id`, optional `workspace_id`, and either `hex` or `clear: true`.
  - non-focus command; must not steal app focus.
- Include `custom_color` in:
  - `surface.list`
  - `surface.current`
  - pane surface listings where practical.
- CLI:
  - `c11 surface-color set <hex> [--workspace ...] [--surface ...]`
  - `c11 surface-color clear [--workspace ...] [--surface ...]`
  - `c11 surface-color get [--workspace ...] [--surface ...]`
  - optional `list-palette` can share the workspace palette output.

Naming alternative: `c11 tab-color ...` is friendlier but ambiguous with workspace tabs. If chosen, help text must say "surface tab in a pane."

## Implementation Slices

1. **Model and persistence**
   - Add `panelCustomColors`.
   - Add setter/getter normalization.
   - Add `SessionPanelSnapshot.customColor`.
   - Restore and snapshot round-trip.
   - Add focused unit coverage.

2. **Bonsplit data plumbing**
   - Add optional color field to `TabItem` and public `Tab`.
   - Add create/update parameters.
   - Mirror c11 panel color into Bonsplit when created/restored/changed.
   - Preserve through drag/drop payloads.

3. **Rendering**
   - Add minimal color indicator in `TabItemView`.
   - Validate selected/unselected/hover/pinned/unread/loading/favicon states.
   - Add focused Bonsplit tests if there are existing render/model seams; otherwise keep visual validation manual.

4. **UI controls**
   - Add context menu actions and color prompt.
   - Reuse palette/custom color storage.
   - Localize strings.

5. **Socket/CLI**
   - Add `surface.set_custom_color`.
   - Add list/current payload fields.
   - Add CLI command and docs/help.
   - Ensure non-focus behavior.

6. **Validation**
   - Unit tests for normalization, setter behavior, session snapshot encode/decode backcompat, and restore.
   - Unit tests for Bonsplit `TabItem` encode/decode and update plumbing.
   - Tagged build visual pass for light/dark, workspace-colored and uncolored workspaces, terminal/browser/markdown tabs, loading favicon state, pin/unread/dirty states, and narrow panes.

## Risks

- **Tab terminology ambiguity**: c11 has workspace tabs and pane tabs. Use surface/panel naming in APIs and code.
- **Bonsplit coupling**: the color field is generic enough to upstream; c11-specific palette behavior should stay outside Bonsplit.
- **Visual overload**: workspace color, active indicator, unread badge, dirty dot, favicon, and loading spinner can compete. Start with a subtle marker.
- **State loss on detach/move**: cross-workspace transfer paths need explicit color copying; same-workspace moves likely work by panel ID.
- **Settings key naming debt**: existing `WorkspaceTabColorSettings` predates this meaning of tab; avoid large migrations in the first slice.

## Open Questions

1. Should agent/Lattice writes use the new socket API only, or should c11 also mirror the value into surface metadata under a canonical key such as `tab_color`?
2. Should a newly created tab inherit the current tab's color, the workspace color, or start uncolored? Conservative default: start uncolored.
3. Should duplicate browser tab copy the source tab color? Recommendation: yes, duplicate should preserve identity unless the user clears it.
4. Should pinned tabs render the color differently due to limited width? Recommendation: keep the same indicator and avoid adding text.

## Linked Code Areas

- `Sources/Workspace.swift`
- `Sources/SessionPersistence.swift`
- `Sources/TerminalController.swift`
- `CLI/c11.swift`
- `Sources/ContentView.swift`
- `Sources/TabManager.swift`
- `vendor/bonsplit/Sources/Bonsplit/Public/Types/Tab.swift`
- `vendor/bonsplit/Sources/Bonsplit/Internal/Models/TabItem.swift`
- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift`
- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
- `Resources/Localizable.xcstrings`
- `c11Tests/WorkspaceUnitTests.swift`
- `c11Tests/SessionPersistenceTests.swift`
- `vendor/bonsplit/Tests/BonsplitTests/BonsplitTests.swift`
