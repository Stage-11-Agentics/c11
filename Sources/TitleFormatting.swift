import Foundation

/// Module 7 — title formatting helpers.
///
/// Pure helper for the sidebar-tab-label truncation rule (25-grapheme cap,
/// token-boundary truncation with U+2026 ellipsis). Used by the workspace
/// sidebar, bonsplit tab labels, and M8's floor-plan pane-box selected-tab
/// line.
public enum TitleFormatting {
    /// Character cap for sidebar-tab-label truncation (grapheme clusters).
    public static let sidebarLabelCharCap = 25

    /// Truncate `title` per the M7 sidebar-truncation rule.
    ///
    /// - 25-grapheme-cluster cap (Swift `Character` count).
    /// - Token-boundary aware: cuts at the last whitespace at or before index 24
    ///   if one exists; otherwise hard-cuts at index 24 and appends a single
    ///   U+2026 horizontal ellipsis.
    /// - Trims and collapses internal whitespace runs before measuring.
    public static func sidebarLabel(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = collapseInternalWhitespace(trimmed)

        if collapsed.count <= sidebarLabelCharCap {
            return collapsed
        }

        let cap = sidebarLabelCharCap
        let first25 = String(collapsed.prefix(cap))
        if let lastSpace = first25.lastIndex(where: { $0 == " " }) {
            let cut = collapsed[collapsed.startIndex..<lastSpace]
            let cutString = cut.trimmingCharacters(in: .whitespaces)
            if !cutString.isEmpty {
                return cutString + "\u{2026}"
            }
        }

        let hardCut = collapsed.prefix(cap - 1)
        return String(hardCut) + "\u{2026}"
    }

    private static func collapseInternalWhitespace(_ s: String) -> String {
        var result = ""
        var inWhitespace = false
        for ch in s {
            if ch.isWhitespace {
                if !inWhitespace {
                    result.append(" ")
                    inWhitespace = true
                }
            } else {
                result.append(ch)
                inWhitespace = false
            }
        }
        return result
    }
}
