## Code Review
- **Date:** 2026-05-04T15:43:00Z
- **Model:** Gemini
- **Branch:** cmux-37/final-push
- **Latest Commit:** aea6eaa8cf308fa60f69260bec91ffefe2615850
- **Linear Story:** CMUX-37
---

**Architectural**
- **Security vs. IPC Overhead**: The decision to perform file I/O for blueprints entirely within the CLI process and parse via the `workspace.parse_blueprint` socket method is excellent. It neatly mitigates arbitrary-file-read vectors by isolating disk access to the user's shell environment. The double round-trip cost (read -> parse via IPC -> apply via IPC) is a perfectly acceptable trade-off for security, especially given the small size of blueprint files.
- **Set Manifests**: Implementing `WorkspaceSnapshotSet` as a pointer file without duplicating the underlying inner snapshot data keeps the architecture clean and maintains independent restorability of single workspaces.

**Tactical**
- **Custom YAML Parser**: Embedding a lightweight, custom YAML parser (`WorkspaceBlueprintMarkdown.YAML`) avoids bloating the binary with heavy third-party dependencies. However, custom parsers often struggle with edge cases. It is adequate for the strict layout subset, but we must ensure error messages are descriptive when users author invalid syntax.
- **Diagnostic Downgrades**: Reclassifying expected restore "failures" (like seed terminal reuse and redundant metadata) into `info` lines client-side correctly satisfies the user requirement without polluting the pure wire protocol of `ApplyFailure`.

### Issues

- **Blockers**
  - None. The implementation is clean, adheres strictly to project conventions, and fully addresses the 5 workstreams identified in the smoke report without overstepping.

- **Important**
  1. ✅ Confirmed — `Sources/WorkspaceBlueprintMarkdown.swift:123`: The parser handles invalid UTF-8 by defaulting to an empty string (`String(data: data, encoding: .utf8) ?? ""`). This masks the actual encoding error and will subsequently throw a confusing `ParseError.missingLayoutSection`. It should explicitly throw a `.invalidEncoding` error so users aren't left scratching their heads.
  2. ✅ Confirmed — `Sources/WorkspaceBlueprintMarkdown.swift:540` (`tokenize`): The custom YAML tokenizer checks for spaces (`if ch == " " { indent += 1 } else { break }`) but stops on tabs. The inline comment claims "tabs are counted as one", but the code explicitly breaks on `	`. If a user authors a Blueprint using an editor configured to indent with tabs, the parser will miscalculate the indentation level (treating it as 0) resulting in silent structure malformation or vague parsing errors. The parser should explicitly reject tabs with a clear error or accurately compute tab widths.

- **Potential**
  3. ✅ Confirmed — `CLI/c11.swift:3125` (`blueprintPlanFromFile`): Dispatch relies strictly on the `.md` file extension. If a user provides a file without an extension (e.g., `agent-room`), it falls through to the JSON decoder and emits a generic "not a valid blueprint file (missing 'plan' key)". A simple header sniff (e.g., checking if the content begins with `---`) would provide a much better fallback experience.
  4. ⬇️ Lower priority — `Sources/TerminalController.swift:5093` (`v2SnapshotRestoreSet`): The sequential `v2MainSync` block inside the loop over `manifest.snapshots` executes the `WorkspaceLayoutExecutor.apply` for each workspace synchronously on the main thread. While acceptable for a restore operation, restoring a very large set of workspaces could block the Ghostty/AppKit UI thread long enough to cause a visible stall. Consider yielding the thread briefly between workspace restorations in a future performance pass.
