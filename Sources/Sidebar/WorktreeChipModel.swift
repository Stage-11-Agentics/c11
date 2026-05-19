import Foundation

/// C11-104 — projection from `ResolvedGitContext` to renderable chip rows.
///
/// Pure value types so `c11LogicTests` can run against constructed
/// inputs without a SwiftUI host.

public struct WorktreeChip: Equatable, Sendable {
    public let label: String      // basename, e.g. "c11-104-sidebar-chips"
    public let dotColorHex: String  // uppercase RGB sRGB hex, no leading "#"
    public let isSubmodule: Bool    // true for the inner submodule row's
                                    // surrogate "worktree" — render with `↳`
                                    // prefix and no dot.

    public init(label: String, dotColorHex: String, isSubmodule: Bool = false) {
        self.label = label
        self.dotColorHex = dotColorHex
        self.isSubmodule = isSubmodule
    }
}

public struct BranchChip: Equatable, Sendable {
    public let label: String     // "feature/x", "main", "(detached @ abc1234)", "(no branch)"
    public let isDimmed: Bool    // main/master/trunk → dimmed
    public let isDetached: Bool

    public init(label: String, isDimmed: Bool, isDetached: Bool) {
        self.label = label
        self.isDimmed = isDimmed
        self.isDetached = isDetached
    }
}

public struct WorktreeChipRow: Equatable, Sendable {
    public let worktree: WorktreeChip?   // nil for main-checkout rows
    public let branch: BranchChip
    public let indent: Indent

    public enum Indent: Equatable, Sendable {
        case none
        /// Submodule's inner row — rendered indented + `↳` prefix.
        case submodule
    }

    public init(worktree: WorktreeChip?, branch: BranchChip, indent: Indent = .none) {
        self.worktree = worktree
        self.branch = branch
        self.indent = indent
    }
}

public enum WorktreeChipProjector {
    /// Names that render the branch chip dimmed.
    public static let mainBranchNames: Set<String> = ["main", "master", "trunk"]

    /// Project a resolved context into chip rows for the sidebar.
    /// Returns an empty array when the chip row should not render
    /// (settings disabled, no git context).
    ///
    /// `isDirty` preserves the legacy dirty-marker UX (branch chip
    /// gets a `*` suffix when the working tree has uncommitted
    /// changes) — sourced from `Workspace.panelGitBranches[surfaceId]
    /// .isDirty` upstream.
    public static func project(
        _ context: ResolvedGitContext?,
        settingsEnabled: Bool,
        isDirty: Bool = false
    ) -> [WorktreeChipRow] {
        guard settingsEnabled else { return [] }
        guard let context else { return [] }

        let outerRow = projectOuter(context.outer, isDirty: isDirty)
        guard let inner = context.inner else {
            return [outerRow]
        }
        // Inner row's dirty state is the submodule's own working tree
        // — a future addition. For now the outer surface's dirty bit
        // governs the outer row only.
        let innerRow = projectInner(inner)
        return [outerRow, innerRow]
    }

    // MARK: - Internal

    static func projectOuter(_ kind: GitContextKind, isDirty: Bool = false) -> WorktreeChipRow {
        switch kind {
        case .mainCheckout(let branch):
            return WorktreeChipRow(
                worktree: nil,
                branch: projectBranch(branch, isDirty: isDirty),
                indent: .none
            )
        case .linkedWorktree(let basename, let absolutePath, let branch):
            let chip = WorktreeChip(
                label: basename,
                dotColorHex: WorktreeColorPalette.color(for: absolutePath)
            )
            return WorktreeChipRow(
                worktree: chip,
                branch: projectBranch(branch, isDirty: isDirty),
                indent: .none
            )
        }
    }

    static func projectInner(_ inner: GitSubmoduleContext) -> WorktreeChipRow {
        let chip = WorktreeChip(
            label: inner.name,
            dotColorHex: "",
            isSubmodule: true
        )
        return WorktreeChipRow(
            worktree: chip,
            branch: projectBranch(inner.branch),
            indent: .submodule
        )
    }

    static func projectBranch(_ branch: BranchValue, isDirty: Bool = false) -> BranchChip {
        let suffix = isDirty ? "*" : ""
        switch branch {
        case .attached(let name):
            let isMainish = mainBranchNames.contains(name)
            return BranchChip(label: "\(name)\(suffix)", isDimmed: isMainish, isDetached: false)
        case .detached(let sha):
            return BranchChip(
                label: "(detached @ \(sha))\(suffix)",
                isDimmed: false,
                isDetached: true
            )
        case .unknown:
            return BranchChip(label: "(no branch)\(suffix)", isDimmed: false, isDetached: false)
        }
    }
}
