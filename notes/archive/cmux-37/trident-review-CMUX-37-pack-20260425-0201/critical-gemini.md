## Critical Code Review
- **Date:** 2026-04-25T02:01:00Z
- **Model:** Gemini
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial
---

### The Ugly Truth
The foundation for Blueprints and Snapshots seems mostly solid, with good attention to detail on validation and partial-failure modes in the `WorkspaceLayoutExecutor`. However, the implementation of `AgentRestartRegistry` for Phase 5 is critically flawed, shipping commands that are explicitly called out as potentially non-existent. This demonstrates a process failure where tests were written to confirm the incorrect implementation, not the required behavior, creating a high risk of production failure for session restoration.

### What Will Break
1.  **Agent Session Restore:** `AgentRestartRegistry.swift` unconditionally uses `kimi --continue` and `opencode --continue`. The review context explicitly states these flags may not exist. If they don't, session restoration for Kimi and Opencode agents will fail 100% of the time. The command will be sent to the terminal and the shell will reject it, leaving the user with an error message instead of a restored session.

### What's Missing
1.  **Validation for `export-blueprint` name**: `CLI/c11.swift` does not validate the sanitized blueprint name. A name like `!@#` becomes an empty string, leading to a file named `.json` being created in the blueprints directory. There should be a check to ensure the sanitized name is not empty.
2.  **Verification of Agent CLI Flags**: The `AgentRestartRegistry` changes were merged without confirming if the `kimi` and `opencode` CLIs actually support the `--continue` flag. This verification step is crucial and was missed.

### The Nits
1.  **Blueprint file extension confusion**: `WorkspaceBlueprintStore.swift` discovers `.md` files but `WorkspaceBlueprintExporter.swift` only writes `.json` files. A user can't edit a blueprint in place if they authored it as markdown; exporting it would create a new JSON file. This is a minor UX inconsistency.
2.  **Silent directory read failures**: In `WorkspaceBlueprintStore.swift`, using `try?` on `FileManager.default.contentsOfDirectory` means if a blueprint directory is unreadable due to permissions, it will silently fail and appear empty. While not a crash, it's a silent failure that could confuse users. A warning log would be better.

---

### Triage

- **Blockers** — will cause production incidents or data loss
    - ✅ **Confirmed** - `AgentRestartRegistry.swift`: The `resolveCommand` implementation for `kimi` and `opencode` uses `--continue` flags that are not confirmed to exist. This will likely break session restoration for these agents. The tests only confirm the incorrect code was written, not that it works. This must be reverted or confirmed with the tool authors before shipping.

- **Important** — will cause bugs or poor UX
    - ✅ **Confirmed** - `CLI/c11.swift`: A blueprint name that contains no valid characters (e.g., `c11 workspace export-blueprint --name "!!!!"`) will be sanitized to an empty string, creating a file named `.json`. The sanitized name should be validated to prevent this.

- **Potential** — code smells, missing tests, things that will bite you later
    - ❓ **Likely but hard to verify** - `WorkspaceBlueprintStore.swift`: The store's logic for reading `.md` files but only writing `.json` files is an inconsistent user experience that could lead to confusion and duplicate blueprint files.
    - ❓ **Likely but hard to verify** - `WorkspaceBlueprintStore.swift`: Directory read errors are silently ignored. This could make it difficult to debug issues with blueprint discovery if a directory has incorrect permissions.

### Closing Summary
The code for the Blueprint and Snapshot features is largely well-constructed, particularly the defensive validation and failure handling in the layout executor.

However, this branch is **NOT ready for production**.

The `AgentRestartRegistry` change is a critical blocker. Shipping code with unverified CLI flags that are *known* to be uncertain is unacceptable and will likely lead to a production failure for users of Kimi and Opencode. This must be addressed before this branch can be considered for merge. The other "Important" issue regarding blueprint name sanitization should also be fixed.
