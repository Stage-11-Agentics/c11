C11-185 (task_01KYQYND86DZMKGR58BJ4Y3R53)  "Agent-state tooltips and persistent Surface Details activity timestamps"
Status: in progress  Priority: medium  Type: task
  Next: review | blocked | cancelled
Assigned: agent:codex-c11-185  Created by: agent:codex-ticket-author
Created: 2026-07-29T22:07:02Z  Updated: 2026-07-29T22:27:13Z

Description:
  ## Summary
  
  Teach the new agent lifecycle marks everywhere they appear, and make Surface Details the authoritative expanded view of the same activity truth. Hovering an agent mark in a top surface tab or either sidebar mark location shows the presented lifecycle state, an accurate duration when c11 has trustworthy evidence, and flagged or suppressed modifiers. Right-click -> Surface Details shows the same state duration plus persistent Created and Last activity timestamps.
  
  This is a follow-on to C11-183 and C11-184. It must reuse their shared state and attention projection rather than derive independent strings in each renderer.
  
  ## Locked user-facing contract
  
  ### Tooltips
  
  - Attach a native tooltip to the padded mark hit area in the top surface tab, sidebar summary rows, and sidebar census mark row. Do not attach it to the aggregate composition rail.
  - Lifecycle is primary; flag and suppression are modifiers. Example shapes of the copy:
    - `Working for 2 minutes`
    - `Waiting for your response`
    - `Idle for 7 minutes`
    - `Cold for 3 minutes`
    - `Idle for 7 minutes\nFlagged: Need a decision on schema migration`
    - `Idle for 7 minutes\nSuppressed`
  - Flagged plus suppressed shows both modifiers. Flag remains the stronger attention signal, but neither modifier erases the presented lifecycle.
  - If no trustworthy state-start timestamp exists, show the localized state alone. Never fabricate `0 minutes`.
  
  ### Duration semantics
  
  - Working and idle use the c11-observed lifecycle or input boundary recorded by `SurfaceActivityTracker`.
  - Cold begins when last activity plus `SidebarAgentColdSettings.thresholdSeconds()` is crossed. `Cold for` must not mean total idle time.
  - Waiting uses the exact surface unread-notification creation time when available; otherwise it has no duration.
  - A flag may use existing `flagRaisedAt` for flag age if the final copy includes it.
  - Suppression has no canonical start time and therefore receives no duration.
  - Relative duration formatting is locale-aware and plural-safe.
  
  ### Surface Details
  
  Add an always-visible activity/timing group to the existing Surface Details panel, for example:
  
  ```text
  Activity        Idle for 7 minutes
  Created         2026-07-29 14:31:05 EDT
  Last activity   2026-07-29 15:02:18 EDT - 7 minutes ago
  ```
  
  - Use the label `Last activity`, not `Last action`. The timestamp means the latest activity c11 actually observed: terminal input, conversation claim, or agent lifecycle transition. It does not claim to observe every agent tool call, subprocess action, output byte, browser event, or filesystem mutation.
  - Created means logical surface creation, not Surface Details capture time, latest app launch, current Ghostty runtime creation, or metadata write time.
  - Created persists across app restart and restore for terminal, browser, and markdown panels. Legacy snapshots without the new field decode successfully and display `Not recorded`; do not invent an original creation time.
  - Last activity uses the persisted activity tracker floor where present. Missing evidence displays `Not recorded`.
  - Absolute timestamps include timezone, remain selectable, and offer an unambiguous copy value. Relative age appears alongside absolute time.
  - The existing Captured row remains separate and continues to mean when the Surface Details snapshot was read.
  - Refresh rereads absolute activity truth. Relative state duration and age stay current on the existing coarse shared clock or an equally bounded leaf-only mechanism.
  
  ## Architecture
  
  1. Add one pure c11-owned agent activity help/details projection containing presented lifecycle, optional state-start time, optional last-activity time, flag reason and raised time, and suppression. Tooltips and Surface Details consume this same projection.
  2. Keep `SurfaceLivenessDeriver -> derived activity metadata -> top tabs/sidebar cards` as the state pipeline. No renderer may independently infer lifecycle.
  3. Extend `WorkspacePulseAgent` with the immutable activity-help payload used by sidebar renderers.
  4. Extend the host-owned `BonsplitTabActivityPresentation` with generic help data needed to render the top-tab tooltip. Bonsplit renders supplied presentation; c11 continues to own product semantics such as flagged and suppressed.
  5. Promote logical `createdAt` to a first-class panel/session property for terminal, browser, and markdown surfaces. Add a backward-compatible optional `created_at` field to `SessionPanelSnapshot` and pass it through every fresh-create and restore path. Do not use the terminal-only private debug creation timestamp as the canonical value.
  6. Surface Details captures structured activity details separately from mutable metadata JSON. Do not write derived UI facts into `SurfaceMetadataStore` merely to display them.
  
  ## Performance and interaction guardrails
  
  - Do not read `SurfaceMetadataStore`, `SurfaceActivityTracker`, notification indexes, or perform date formatting inside the typing-hot `ContentView.TabItemView` body or `WindowTerminalHostView.hitTest()`. Precompute immutable payloads in the existing parent/state-sync paths.
  - No per-agent repeating timers. Refresh tooltip copy on hover entry; use the existing coarse clock only in leaf views that visibly age while open. Animation settings and Reduce Motion behavior are unchanged.
  - The top tooltip target may include the mark padding so a 9pt glyph remains practically hoverable, but must not change layout, tab selection, context menus, or close behavior.
  - Preserve user-owned changes in the current dirty checkout by implementing from an isolated worktree.
  - Any Bonsplit change must be committed and pushed to `Stage-11-Agentics/bonsplit` main before the parent submodule pointer is committed. Flag the generic tooltip capability as an upstream candidate.
  
  ## Localization and accessibility
  
  - All new c11 copy uses `String(localized:defaultValue:)`; translate the final English into ja, uk, ko, zh-Hans, zh-Hant, and ru through the required translator pass.
  - Bonsplit activity labels remain localized in all seven `.lproj` catalogs.
  - VoiceOver receives lifecycle, duration, modifiers, and flag reason in the same semantic order as the tooltip, without duplicating values already exposed by the tab.
  - Validate `Resources/Localizable.xcstrings` with `jq`, not `plutil`, and verify interpolation tokens across every locale.
  
  ## Likely code surfaces
  
  - `Sources/Sidebar/SidebarActivityProjector.swift`
  - `Sources/ContentView.swift`
  - `Sources/Workspace.swift`
  - `Sources/Conversation/SurfaceActivity.swift`
  - `Sources/SurfaceManifestView.swift`
  - `Sources/SurfaceManifestViewerWindowController.swift` and/or `Sources/TerminalController.swift`
  - `Sources/Panels/Panel.swift`, `TerminalPanel.swift`, `BrowserPanel.swift`, `MarkdownPanel.swift`
  - `Sources/SessionPersistence.swift` plus restore/create call sites
  - `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitActivityAnimationClock.swift`
  - `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
  - `Resources/Localizable.xcstrings` and Bonsplit localization catalogs
  
  ## Acceptance criteria
  
  1. Hovering every individual agent mark in the top surface tab and both sidebar mark locations shows a localized tooltip with the same presented lifecycle semantics.
  2. Working, idle, cold, and waiting durations use the sources and fallback rules above; cold duration begins at threshold crossing.
  3. Flagged, suppressed, and flagged plus suppressed tooltips preserve lifecycle and display the applicable modifier details.
  4. Tooltip hit areas are usable without changing mark geometry, layout, selection, context-menu, overflow, or close behavior.
  5. Surface Details shows Activity, Created, Last activity, and Captured as distinct values. State duration agrees with the tooltip for the same surface at the same clock instant.
  6. New terminal, browser, and markdown surfaces receive logical creation timestamps, which survive session snapshot round-trip and restore. Legacy snapshots decode and show `Not recorded` rather than a fabricated creation time.
  7. Last activity survives restart where the existing activity floor is persisted; missing activity evidence is represented honestly.
  8. Pure tests cover duration boundaries, missing timestamps, cold-threshold arithmetic, suppressed waiting projecting as idle, flag plus suppression composition, created-at snapshot round-trip, and legacy decoding. Bonsplit tests cover the generic help payload and rendered accessibility composition through executable paths.
  9. No source-text or project-file assertion tests are added.
  10. English and all six translations are complete and token-safe; `jq . Resources/Localizable.xcstrings` and Bonsplit catalog validation pass.
  11. Relevant c11 logic and host-required tests pass. The implementation is exercised in a tagged QA build through actual hover and Surface Details flows, with screenshots or equivalent visible evidence for top tab, sidebar, and details panel. Obtain scoped computer-use approval before that validation.
  12. Bonsplit commit is reachable from its remote main before the parent pointer lands; parent diff is clean, scoped, and does not absorb unrelated dirty-worktree changes.
  
  ## Out of scope
  
  - Claiming observation of individual agent tool calls or output activity.
  - Adding new CLI or socket API fields solely for this UI change.
  - Changing lifecycle colors, shapes, motion, cold threshold, flag behavior, or suppression signal eligibility.
  - Redesigning the Surface Details panel beyond the new activity/timing group.

Relationships (outgoing):
  related_to -> task_01KYMTXQVWCXCF0TGN5ZWG341E "Flagged and suppressed agents: the attention model"
  related_to -> task_01KYMTWW3VVZSR308G0X3YE79H "Rebuild agent-state mark vocabulary: lifecycle in shape alone"

Branch links:
  feat/c11-185-agent-activity-details by agent:codex-c11-185

Plan: plans/task_01KYQYND86DZMKGR58BJ4Y3R53.md

Events (latest first):
  2026-07-29T22:27:13Z  status_changed  planned -> in_progress  by agent:codex-c11-185
  2026-07-29T22:27:13Z  auto_review_spawned    by agent:lattice-auto-review
  2026-07-29T22:27:13Z  status_changed  in_planning -> planned  by agent:codex-c11-185
  2026-07-29T22:26:12Z  branch_linked  branch 'feat/c11-185-agent-activity-details'  by agent:codex-c11-185
  2026-07-29T22:26:12Z  status_changed  backlog -> in_planning  by agent:codex-c11-185
  2026-07-29T22:26:12Z  assignment_changed  unassigned -> agent:codex-c11-185  by agent:codex-c11-185
  2026-07-29T22:07:20Z  relationship_added  related_to -> task_01KYMTWW3VVZSR308G0X3YE79H  by agent:codex-ticket-author
  2026-07-29T22:07:15Z  relationship_added  related_to -> task_01KYMTXQVWCXCF0TGN5ZWG341E  by agent:codex-ticket-author
  2026-07-29T22:07:02Z  task_created    by agent:codex-ticket-author
    on behalf of: human:atin | reason: Direct operator request after approving the evaluated tooltip and Surface Details plan
