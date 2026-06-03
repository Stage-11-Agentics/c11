## Critical Code Review
- **Date:** 2026-05-04T15:43:00Z
- **Model:** Gemini 2.5 Pro
- **Branch:** cmux-37/final-push
- **Latest Commit:** aea6eaa8
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial
---

**The Ugly Truth**: 
This is a massive set of changes doing significant structural work across the application. It manages to stay largely clean by reusing existing types and avoiding threading/latency traps. The separation of `WorkspaceBlueprintMarkdown` as a pure parser is commendable. However, the manual String-based Markdown parsing contains logic holes in number parsing, and the severity classification for expected errors is implemented as brittle hardcoded string matching. The error handling mechanism around snapshots also allows some silent fallback behavior that operators will find confusing.

**What Will Break**:
- **Split Ratios with Negative Numbers**: The `parseSplitRatio` function in `WorkspaceBlueprintMarkdown.swift` parses strings into a `Double` ratio. For fractions like `X/Y`, it correctly checks `X + Y > 0`. But if someone inputs `2/-1`, `X=2, Y=-1`, `X+Y = 1 > 0`, so it passes the check! It returns `2.0`, which is > 1 and will likely break the `bonsplit` tree. For decimals, it enforces `> 0` and `< 1`, but the fractional path is mathematically flawed.
- **Fragile Message Matching**: In `CLI/c11.swift`, `failureSeverity` relies on `message.contains("seed terminal reuse")`. If the phrasing in `WorkspaceLayoutExecutor` changes, this silently regresses back to throwing a `failure:` line, breaking the exact contract this workstream is trying to fix.
- **Local FS Checking for Network Sockets**: In `CLI/c11.swift:3429`, the bare-id form of `c11 restore <id>` checks `isLocalSnapshotSetId(target)`. This hardcodes the home directory and bypasses any `directoryOverride` or future customization of the snapshot root. It also uses `.fileExists` which can race or be slow over network mounts. The socket handler `v2SnapshotRestoreSet` should handle this polymorphism, or the CLI should query the daemon to check if it's a set.

**What's Missing**:
- Validation of `split` ratios in the fractional path to ensure `lhs > 0` and `rhs > 0`.
- An explicit error classification for "seed terminal reuse" in the structured `ApplyFailure` rather than scraping the human-readable `message` string.

**The Nits**:
- In `WorkspaceSnapshotSetFile.Entry`, `selected` defaults to `false` via `decodeIfPresent`, but its default initialization `false` is perfectly adequate and handles absent keys safely.
- `WorkspaceBlueprintStore` falls back to the filename stem if the markdown parser fails to find a name in the frontmatter, but the `WorkspaceBlueprintMarkdown.parse` doesn't know the filename, so it sets it to `""`. This mismatch means a manually edited `.md` without a title frontmatter reads fine in the picker (using filename) but might have a blank `name` property internally if parsed directly via `parse`.

- **Blockers**
1. `WorkspaceBlueprintMarkdown.swift` `parseSplitRatio` validates fractions incorrectly. A split ratio of `2/-1` passes the `(lhs + rhs) > 0` check but produces a ratio of `2.0`, escaping the `0...1` bound required by the layout tree. This will panic or break bonsplit when applied.

- **Important**
1. `CLI/c11.swift` `failureSeverity` uses substring matching (`message.contains("seed terminal reuse")`) to classify diagnostics as `info`. This is extremely brittle. If the wording changes in the executor, the CLI will revert to printing `failure:` lines, breaking automation. Use a structured severity field or an explicit error code instead of scraping the message.
2. In `CLI/c11.swift`, the bare-id form of `c11 restore <id>` checks `isLocalSnapshotSetId(target)`. This hardcodes the home directory and bypasses any `directoryOverride` or future customization of the snapshot root. The socket handler should handle this polymorphism, or the CLI should query the daemon to check if it's a set, rather than making local disk assumptions.

- **Potential**
1. `WorkspaceBlueprintMarkdown.parse` sets `name = frontKV["title"] ?? ""`. If a user manually edits a blueprint and removes the frontmatter title, applying it via `--blueprint` will result in a blank workspace title.
2. `c11 snapshot --all` blocks the main thread for the entire duration of iterating `tabManager.tabs` and capturing each one. For a large number of workspaces, this could induce noticeable typing latency or UI hang.

## Phase 5: Validation Pass

- ✅ Confirmed — Fractional bounds escape: The `parseSplitRatio` logic reads `lhs / (lhs + rhs)`. If `lhs = 2.0`, `rhs = -1.0`, sum is `1.0 > 0`, ratio is `2.0`. Verified in `WorkspaceBlueprintMarkdown.swift`.
- ✅ Confirmed — Fragile message matching: `failureSeverity` checks `message.contains("seed terminal reuse")`. Verified in `CLI/c11.swift`.
- ✅ Confirmed — Hardcoded home dir in CLI: `isLocalSnapshotSetId` checks `FileManager.default.homeDirectoryForCurrentUser`.

## Closing

Not ready for production. The parser bug can produce invalid layout trees that will crash or corrupt the UI layer (`bonsplit`). The hardcoded substring matching for error handling will inevitably regress. Fix the `parseSplitRatio` math and use a proper error code or severity field for the diagnostic classification.