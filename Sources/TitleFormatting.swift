import Foundation

/// Pure helper for the sidebar-tab-label truncation rule.
/// Used by the workspace sidebar, bonsplit tab labels, and the floor-plan
/// pane-box selected-tab line.
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

    /// Compose the "N: title" surface-ordinal prefix used when the
    /// "Show surface IDs in tab titles" setting is on. Must stay format-identical
    /// to bonsplit's `TabItem.displayedTitle(showOrdinals:)` so the surface title
    /// bar and the tab strip render the same string.
    public static func ordinalPrefixed(ordinal: Int?, title: String, show: Bool) -> String {
        guard show, let ordinal else { return title }
        return "\(ordinal): \(title)"
    }

    /// Return the shortest uppercase, hyphen-free UUID prefix that is unique
    /// among the visible stable identities. Orphan labels use this instead of
    /// a stale `surface:N` ref, whose ordinal may already have been reused.
    public static func collisionSafeUUIDPrefix(
        for id: UUID,
        among visibleIDs: [UUID],
        minimumLength: Int = 6
    ) -> String {
        let target = compactUUID(id)
        let candidates = Set(visibleIDs + [id]).map(compactUUID)
        let start = min(max(1, minimumLength), target.count)

        for length in start...target.count {
            let prefix = String(target.prefix(length))
            let collisions = candidates.lazy.filter { $0.hasPrefix(prefix) }.count
            if collisions == 1 {
                return prefix
            }
        }
        return target
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

    private static func compactUUID(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }
}
