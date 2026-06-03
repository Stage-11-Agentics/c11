import SwiftUI

/// C11-104 — renders the worktree+branch chips row(s) under a workspace's
/// agent chip in the sidebar.
///
/// All projection work happens upstream (`WorktreeChipProjector`).
/// This view is purely a layout shim — no git / IO / metadata reads inside
/// the body, so it stays cheap to render on every TabItemView re-eval.
struct WorktreeChipsRow: View {
    let rows: [WorktreeChipRow]
    let foreground: Color
    let secondary: Color

    @Environment(\.chromeScaleTokens) private var chromeTokens

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    rowView(for: row)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func rowView(for row: WorktreeChipRow) -> some View {
        HStack(spacing: 4) {
            if row.indent == .submodule {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: chromeTokens.sidebarWorkspaceDetail))
                    .foregroundColor(secondary.opacity(0.7))
            }

            if let worktree = row.worktree {
                worktreeChipView(worktree)
            }

            branchChipView(row.branch)

            Spacer(minLength: 0)
        }
        .padding(.leading, row.indent == .submodule ? 8 : 0)
    }

    @ViewBuilder
    private func worktreeChipView(_ chip: WorktreeChip) -> some View {
        HStack(spacing: 3) {
            if !chip.isSubmodule {
                Circle()
                    .fill(Color(nsColor: NSColor(hex: chip.dotColorHex) ?? .gray))
                    .frame(width: 7, height: 7)
            }
            Text(chip.label)
                .font(.system(size: chromeTokens.sidebarWorkspaceDetail, design: .monospaced))
                .foregroundColor(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func branchChipView(_ chip: BranchChip) -> some View {
        Text(chip.label)
            .font(.system(size: chromeTokens.sidebarWorkspaceDetail, design: .monospaced))
            .foregroundColor(secondary)
            .opacity(chip.isDimmed ? 0.55 : 1.0)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var parts: [String] = []
        for row in rows {
            if let wt = row.worktree {
                if row.indent == .submodule {
                    parts.append("submodule \(wt.label)")
                } else {
                    parts.append("worktree \(wt.label)")
                }
            }
            parts.append("branch \(row.branch.label)")
        }
        return parts.joined(separator: ", ")
    }
}
