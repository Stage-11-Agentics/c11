# c11 Consolidation Notes — M1–M8 onto features/c11mux-1-8

**Date:** 2026-04-16
**Note:** Branch names below are preserved as-of the consolidation; the project was later renamed from `c11mux` to `c11`, but the integration work happened under the original branch names.
**Scope:** Consolidate six parallel module branches (M1, M3+M6, M4, M5, M7, M8) plus a new canonical M2 substrate onto the integration branch `features/c11mux-1-8`, removing a three-way divergence of the Module 2 (per-surface metadata) implementation so the fork builds green as one integrated result.

## Why this work was needed

Three of the six module branches had each shipped their own incompatible copy of the Module 2 metadata substrate as a development shim:

| Branch | M2 shape | Scope | API style |
|---|---|---|---|
| `features/c11mux-m1` | `SurfaceMetadataStore` singleton | global | `setMetadata(workspaceId:, surfaceId:, …)` |
| `features/c11mux-m3-m6` | `SurfaceMetadataStore` struct, no global state | per-use | local struct copies |
| `features/c11mux-m7` | Per-`Workspace` instance, lock-backed | workspace-scoped | `workspace.surfaceMetadata.set(…)` |

Merging any two of these together would have produced duplicate type declarations, duplicate JSON-RPC handlers (`surface.set_metadata` / `surface.get_metadata` / `surface.clear_metadata`), and conflicting storage semantics for the same canonical keys (`role`, `status`, `task`, `model`, `progress`, `terminal_type`, `title`, `description`).

Rather than paper over that with a merge-conflict resolution pass, the consolidation created a single canonical substrate on `features/c11mux-m2` and rebased each consumer onto it.

## Canonical substrate (`features/c11mux-m2`)

The canonical substrate promoted M1's singleton shape to the baseline:

- **`Sources/SurfaceMetadataStore.swift`** — singleton (`SurfaceMetadataStore.shared`), serial dispatch queue, workspace-keyed nested dictionaries, `MetadataSource` as a top-level type, `MetadataKey` namespace for canonical key strings (`MetadataKey.title`, `MetadataKey.terminalType`, `MetadataKey.modelLabel`, …).
- **`Sources/AgentDetector.swift`** — heuristic TTY-name → `terminal_type` detector used by M1's OSC-fallback path.
- **JSON-RPC dispatch** in `TerminalController.swift` — `surface.set_metadata`, `surface.get_metadata`, `surface.clear_metadata` routed through the singleton.
- **`MetadataKey`** gains `modelLabel` (non-canonical display hint used by M3's sidebar chip), plus `canonical: Set<String>` and `canonicalTerminalTypes: Set<String>` constants so downstream modules can share that vocabulary.

Precedence chain preserved: `explicit > declare > osc > heuristic`. Lower-precedence writes soft-reject per key (`applied: false`, `reason: "lower_precedence"`).

## Rebased consumer branches

Three branches were rebased to delete their local M2 shim and retarget the canonical store:

### `features/c11mux-m1-rebased` (from `c11mux-m1` → `c11mux-m2`)
No code-level rebase needed — M1 is the canonical shape. Brought forward the tests_v2 TUI-detection suite and the zsh/bash shell-integration forwarding that exports the agent declaration into the store.

### `features/c11mux-m3-m6-rebased` (from `c11mux-m3-m6` → `c11mux-m2`)
- Deleted the local `SurfaceMetadataStore` struct + duplicate JSON-RPC cases in `CLI/cmux.swift` and `TerminalController.swift`.
- `AgentChipResolver` and `ContentView` agent-chip read-site now call `TerminalController.canonicalMetadataSnapshot(workspaceId:, surfaceId:)`, a static helper that converts the singleton's `(metadata, sources)` return into the shape the chip resolver expects.
- Hoisted the `canonicalMetadataSnapshot` call out of the sidebar-tab trailing-closure `guard` to avoid a Swift type-check timeout in `ContentView.swift` at the agent-chip call site.

### `features/c11mux-m7-rebased` (from `c11mux-m7` → `c11mux-m2`)
This rebase was the largest. M7 had shipped the most divergent variant.

- **Deleted `Sources/SurfaceMetadata.swift`** (M7's combined enum + per-workspace store + title formatter). The enum + store are replaced by the canonical substrate.
- **Extracted `Sources/TitleFormatting.swift`** — pure M7 helper (`TitleFormatting.sidebarLabel(from:)`, 25-grapheme cap, token-boundary truncation with U+2026 ellipsis). Kept as its own file so M3's sidebar tab label uses it alongside the agent chip.
- **`Workspace.swift`:**
  - Removed the `surfaceMetadata: SurfaceMetadataStore = SurfaceMetadataStore()` instance field — no longer owned per-workspace.
  - Kept the M7-specific fields: `titleBarCollapsed`, `titleBarUserCollapsed`, `titleBarVisible`.
  - Rewrote `syncPanelTitleFromMetadata`, `surfaceTitleBarState`, and `titleBarStatePayload` to read from `SurfaceMetadataStore.shared.getMetadata(workspaceId:, surfaceId:)`.
  - Added a small `Self.extractSource(_:)` helper that decodes the singleton's `[String: [String: Any]]` source dict back to a typed `MetadataSource` value (the singleton returns JSON-shaped dicts; the per-workspace variant returned typed structs).
  - `renameTab` path routes through `SurfaceMetadataStore.shared.setMetadata(…, mode: .merge, source: .explicit)` and `.clearMetadata(…, source: .explicit)`.
  - Surface close prunes both the singleton (`removeSurface(workspaceId:, surfaceId:)`) and the M7-only title-bar collapse-state dictionaries.
- **`TabManager.swift` (OSC title routing):** `updatePanelTitle` now writes through `SurfaceMetadataStore.shared.setMetadata(source: .osc)` / `.clearMetadata(source: .osc)`. The singleton's precedence gate enforces "OSC cannot overwrite `declare`/`explicit` title", keeping the spec behavior.
- **`TerminalController.swift` (JSON-RPC dispatch):**
  - Deleted M7's duplicate `v2SurfaceSetMetadata` / `v2SurfaceGetMetadata` / `v2SurfaceClearMetadata` and the `case "surface.set_metadata" …` dispatch cases — M2 owns the canonical dispatch.
  - Renamed M7's `v2ResolveSurfaceForMetadata` to `v2ResolveWorkspaceForTitleBar` (returns `(Workspace, UUID)?` for title-bar-specific handlers `surface.get_titlebar_state`, `surface.set_titlebar_visibility`, `surface.set_titlebar_collapsed`). M2's own resolver remains `v2ResolveSurfaceForMetadata` / `v2ResolveWorkspaceSurface`.
  - New `applyTitleDescriptionSideEffects(workspaceId:, surfaceId:, tabManager:, applied:, autoExpand:)` method wires M7's render-cache sync (`syncPanelTitleFromMetadata`) and auto-expand (`maybeAutoExpandTitleBar`) into M2's canonical `surface.set_metadata` and `surface.clear_metadata` handlers. The hook checks `result.applied["title"] == true` / `applied["description"] == true` to decide whether to run the M7 side effects — the canonical `WriteResult` does not expose a `changedKeys` field, so we use `applied` as the proxy.

## Merge order into `features/c11mux-1-8`

Merges used `--no-ff` to preserve the branch-topology audit trail. Each merge verified with `xcodebuild -scheme cmux -configuration Debug` into `/tmp/cmux-consolidation` and rejected if the integrated tree failed to build.

| # | Branch | Outcome | Conflict notes |
|---|---|---|---|
| 1 | `features/c11mux-m2` | clean | — |
| 2 | `features/c11mux-m1-rebased` | clean | — |
| 3 | `features/c11mux-m3-m6-rebased` | clean | — |
| 4 | `features/c11mux-m7-rebased` | 1 conflict | `ContentView.swift` sidebar-tab label — kept M3's `AgentChipBadge` **and** M7's `TitleFormatting.sidebarLabel(from:)` wrapper on the title text. Also deduped a second `MetadataKey` enum introduced during the M7 rebase that collided with M3's richer version. |
| 5 | `features/c11mux-m4` | clean | — |
| 6 | `features/c11mux-m5` | clean | — |
| 7 | `features/c11mux-m8` | clean | — |

## Final state

- **Branch:** `features/c11mux-1-8` at `d7e2ab30`.
- **Build:** `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-consolidation build` → `** BUILD SUCCEEDED **` (only pre-existing Swift 6 concurrency warnings on `Workspace: BonsplitDelegate`; unrelated to this consolidation).
- **Tests:** Not run locally per project policy — Python `tests_v2/` and UI tests run on CI. Test files from all six module branches have been preserved on the integration branch.
- **Sub-branches preserved:** `features/c11mux-m1`, `c11mux-m1-rebased`, `c11mux-m2`, `c11mux-m3-m6`, `c11mux-m3-m6-rebased`, `c11mux-m4`, `c11mux-m5`, `c11mux-m7`, `c11mux-m7-rebased`, `c11mux-m8` — none deleted.
- **No remote pushes** were performed from this session.

## Things to watch after this lands

1. **`Workspace.extractSource` coercion.** The helper turns `[String: Any]` source dicts from the singleton back into a typed `MetadataSource`. If a future `SurfaceMetadataStore` change drops the `{source, ts}` JSON shape, M7's title-bar `source` field will go nil — break loudly rather than silently.
2. **Side-effect hook semantics.** `applyTitleDescriptionSideEffects` assumes `applied[key] == true` equals "the key's value materially changed." That is correct for the current store (the applied flag is set only when the value is accepted), but if the store ever reports `applied: true` for an idempotent no-op write, M7 will re-run the render-cache sync redundantly. Non-fatal, just wasteful.
3. **`CLI/cmux.swift` size growth.** The M4 merge added ~2,344 lines (mostly installers for GitHub Copilot CLI, Gemini CLI, Codex CLI integration). Nothing is duplicated, but the file is now ~14k lines. Consider a future split if CLI subcommands keep accreting.
4. **OSC-title precedence.** `TabManager.updatePanelTitle` now uses the store's precedence gate for OSC writes. That is intentional but a behavior change versus the pre-M2 code, which always accepted OSC titles. Any explicit `declare`/`explicit`-sourced title now holds against OSC. Spec-correct but worth a smoke test through an actual agent like `claude` that emits OSC 0/2 sequences.
