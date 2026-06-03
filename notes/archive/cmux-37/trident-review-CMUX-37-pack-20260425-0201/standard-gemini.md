## Code Review
- **Date:** 2026-04-25T02:01:00Z
- **Model:** Gemini
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8
- **Linear Story:** CMUX-37
---

### Architectural Assessment

This branch introduces significant new capabilities for workspace management through "Blueprints" and enhances the existing "Snapshot" functionality. The overall architecture is sound and well-structured.

The introduction of `WorkspacePlanCapture.swift` as a shared helper to serialize workspace state for both Blueprints and Snapshots is a strong architectural decision, promoting consistency and reducing code duplication. The `WorkspaceBlueprintStore` provides a flexible and layered approach to discovering user, repository, and built-in templates, which is a good, extensible design.

The command-line additions (`workspace new`, `workspace export-blueprint`, `snapshot --all`) are logical extensions of the c11 CLI and appear to be implemented with user experience in mind, particularly the interactive blueprint picker.

The primary architectural concern lies in the implementation of agent restart logic within `AgentRestartRegistry.swift`, which diverges significantly from the plan and contains questionable assumptions about CLI flags for certain agents.

### Tactical Review

**Test Coverage:** Per project policy, no local tests were run. The context mentions that tests are handled by CI, and new XCTest files have been added for the new functionality (`WorkspaceBlueprintFileCodableTests`, `WorkspaceBlueprintStoreTests`, `WorkspaceSnapshotBrowserMarkdownRoundTripTests`, `AgentRestartRegistryTests`). The tests appear to cover the new code paths at a unit level.

---

### Review Items

#### Blockers
1.  **[BLOCKER] `AgentRestartRegistry.swift` implementation deviates from plan and uses potentially non-existent flags.**
    - **File:** `Sources/AgentRestartRegistry.swift`
    - **Issue:** The implementation for `codex`, `opencode`, and `kimi` uses hardcoded command strings (`"codex --last\n"`, `"opencode --continue\n"`, `"kimi --continue\n"`) that do not match the logic specified in the plan. More concerningly, the review context document notes that the `--continue` flags for `opencode` and `kimi` "may not actually exist". Shipping code that relies on unverified CLI flags is a significant risk.
    - **Recommendation:**
        1. Verify if the `opencode --continue` and `kimi --continue` flags are valid.
        2. If they are not valid, the implementation must be reverted or changed to a state that does not cause runtime errors.
        3. The implementation should be updated to follow the plan's logic (e.g., handling cases with and without a session id) or the plan should be officially updated to reflect the as-built reality with a clear justification.
    - **Validation:** ✅ Confirmed. The code in `Sources/AgentRestartRegistry.swift` and the provided context document `notes/.tmp/trident-CMUX-37/trident-review-standard.md` both confirm this discrepancy and risk.

#### Important
2.  **[IMPORTANT] Inconsistent documentation for metadata value types in `workspace-apply-plan-schema.md`.**
    - **File:** `docs/workspace-apply-plan-schema.md`
    - **Issue:** The schema documentation is confusing regarding the allowed types for metadata values.
        - The `WorkspaceSpec` section states its `metadata` values must be strings.
        - The `SurfaceSpec` table notes `metadata` and `pane_metadata` values must be JSON-serializable.
        - A note at the end says non-string values for `mailbox.*` pane metadata are dropped.
        - The implementation in `WorkspaceLayoutExecutor.swift` seems to allow any `PersistedJSONValue` for `workspace.metadata` but correctly restricts `pane_metadata` under the `mailbox.*` namespace to strings.
    - **Recommendation:** Clarify the documentation in `workspace-apply-plan-schema.md` to accurately reflect the implementation's behavior for all metadata types to avoid user confusion. It should be explicit about what types are permitted for `workspace.metadata`, `surface.metadata`, and `pane.metadata` (especially the `mailbox.*` namespace).
    - **Validation:** ✅ Confirmed. Cross-referencing the schema document with `WorkspaceLayoutExecutor.swift` confirms the documentation is imprecise compared to the implementation.

#### Potential
3.  **[POTENTIAL] `WorkspaceBlueprintStore.swift` discovers `.md` files but does not parse their content.**
    - **File:** `Sources/WorkspaceBlueprintStore.swift`
    - **Issue:** The blueprint store is configured to look for both `.json` and `.md` files. However, it only uses the filename stem as the blueprint name and does not attempt to parse any content from the markdown files (e.g., YAML frontmatter), which was an option considered in the plan. This could be confusing to users who might expect a `.md` blueprint to be parsed.
    - **Recommendation:** While the context document notes this is "intentional," it would be clearer to either:
        a) Add a comment in `WorkspaceBlueprintStore.swift` explaining *why* `.md` files are indexed but not parsed.
        b) Re-evaluate if only `.json` files should be indexed to avoid ambiguity, unless there's a firm plan to support markdown frontmatter in the near future.
    - **Validation:** ✅ Confirmed. The code in `WorkspaceBlueprintStore.swift` discovers `.md` files but the logic proceeds to only use file URLs, and the context document confirms this is intentional.

#### General Feedback
- The extraction of `WorkspacePlanCapture.swift` is an excellent refactoring that improves code quality.
- The pre-flight fixes in `WorkspaceLayoutExecutor.swift`, such as the pane metadata collision detection and the explicit warnings for when a `workingDirectory` is not applied, are thoughtful improvements that enhance robustness and developer experience.
- The CLI additions are well-considered and improve the usability of c11 for managing complex workspace setups.
