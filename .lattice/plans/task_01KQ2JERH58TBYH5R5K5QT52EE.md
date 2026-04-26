# C11-14: Refactor cleanup: large files, dead code, structural smells

Sweep ticket for code-quality wins identified during a 2026-04-25 exploratory pass over the c11 source tree. Two concrete items to start, plus a section to be filled in by an exploration pass.

## Pass 1 — concrete items

### 1. Delete rejected installer code in `CLI/c11.swift` (~2,300 lines)

Lines ~13906–16252 implement the `cmux install <tui>` integration installers (Module 4). Per CLAUDE.md, this work is **policy-rejected**: 'c11 install <tui> is rejected. Any proposal that writes to a user's persistent tool config is a non-starter… The 691-line spec exists as a historical artifact only — do not revive it.'

The implementation, however, was never deleted. It is dead code by policy, not by accident.

Scope:
- Remove the `cmux install` / `cmux uninstall` subcommand handlers and routing in `CMUXCLI`.
- Remove the `InstallExitCode`, `IntegrationInstallerConstants`, `IntegrationInstallerPlan`, `IntegrationInstallerStatus` types.
- Remove the helper enums `IntegrationInstallerHelpers`, the Claude/TOML/OpenCode shim sections.
- Verify the `Resources/bin/claude` grandfathered wrapper is untouched (CLAUDE.md calls it out as a deliberate exception with a `DO NOT GENERALIZE` header).
- Update `docs/c11mux-module-4-integration-installers-spec.md` — either delete or mark as historical with a clear 'NOT IMPLEMENTED, NOT TO BE REVIVED' banner.
- Drop any tests/fixtures that exist solely to exercise the installer paths.

Risk: zero (policy-dead code, no shipping callers). Win: `c11.swift` 17,039 → ~14,700.

### 2. Carve `ContentView.swift` enum helpers into sibling files

`Sources/ContentView.swift` is 14,131 lines. The `ContentView` struct itself runs ~1420–7328 (~5,900 lines), which is genuinely a SwiftUI god-view and risky to split. But the file also contains many self-contained helper enums and structs that are de-facto separate modules already, just colocated:

- `SidebarRemoteErrorCopySupport`, `InternalTabDragConfigurationProvider`, `SidebarResizeInteraction`, `DragOverlayRoutingPolicy` (lines 65–400)
- `CommandPaletteOverlayPromotionPolicy`, `WorkspaceMountPolicy`, `MountedWorkspacePresentationPolicy` (lines 918–1420)
- `CommandPaletteSwitcherSearchIndexer`, `CommandPaletteFuzzyMatcher`, `CommandPaletteSearchEngine` (lines 7344–8309)
- `SidebarDropPlanner`, `SidebarDragAutoScrollPlanner`, `SidebarSelection`, `SidebarMaterialOption`/`SidebarBlendModeOption`/`SidebarStateOption`/`SidebarTintDefaults`/`SidebarPresetOption` (lines 12777–13997)
- `FeedbackComposerBridge` (lines 10081–10825)

These move to sibling files (`Sources/Sidebar/`, `Sources/CommandPalette/`, `Sources/Feedback/`) with **no behavior change** — pure mechanical extraction. Each block is internally cohesive and externally referenced by name. Goal: ContentView.swift down to ~8k by removing the helpers, leaving the actual View body and its tightly-coupled neighbors.

**What NOT to touch in this pass:**
- `ContentView` struct body (load-bearing for SwiftUI diffing)
- `TabItemView` and its `Equatable` contract (CLAUDE.md flags as typing-latency-critical)
- Any helper that reads from `@EnvironmentObject` / `@ObservedObject` of the ContentView (would require care to extract)

Risk: low (mechanical, type-checker enforced). Win: ContentView.swift 14,131 → ~8,000, helpers become independently navigable and testable.

## Pass 2 — exploration findings (to be appended)

Exploration pass scheduled in same session. Will append findings as comments on this ticket once complete.

## Out of scope (for now)

- `Sources/TerminalController.swift` (17,240) — single 17k-line god-class is the worst structural smell, but every change risks the typing-latency contracts CLAUDE.md flags by name. Defer until a specific pain point forces it.
- `Sources/AppDelegate.swift` (13,374) — needs investigation pass first to know what's actually in there.
- Sweeping naming or API shape changes.
