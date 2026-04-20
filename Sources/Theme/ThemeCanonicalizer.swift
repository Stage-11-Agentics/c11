import Foundation

public enum ThemeCanonicalizer {
    public static func canonicalize(_ theme: C11muxTheme) -> String {
        var lines: [String] = []

        lines.append("[identity]")
        lines.append(contentsOf: formatEntries([
            ("name", theme.identity.name),
            ("display_name", theme.identity.displayName),
            ("author", theme.identity.author),
            ("version", theme.identity.version),
            ("schema", "\(theme.identity.schema)")
        ], quoteValuesFor: ["name", "display_name", "author", "version"]))
        lines.append("")

        lines.append("[palette]")
        lines.append(contentsOf: formatSortedMap(theme.palette))
        lines.append("")

        lines.append("[variables]")
        lines.append(contentsOf: formatSortedMap(theme.variables))
        lines.append("")

        let windowFrame = theme.chrome.windowFrame
        appendSection(
            title: "chrome.windowFrame",
            pairs: [
                ("color", string(windowFrame.color)),
                ("thicknessPt", number(windowFrame.thicknessPt)),
                ("inactiveOpacity", number(windowFrame.inactiveOpacity)),
                ("unfocusedOpacity", number(windowFrame.unfocusedOpacity))
            ],
            into: &lines
        )

        let sidebar = theme.chrome.sidebar
        appendSection(
            title: "chrome.sidebar",
            pairs: [
                ("tintOverlay", string(sidebar.tintOverlay)),
                ("tintBase", string(sidebar.tintBase)),
                ("tintBaseOpacity", number(sidebar.tintBaseOpacity)),
                ("activeTabFill", string(sidebar.activeTabFill)),
                ("activeTabFillFallback", string(sidebar.activeTabFillFallback)),
                ("activeTabRail", string(sidebar.activeTabRail)),
                ("activeTabRailFallback", string(sidebar.activeTabRailFallback)),
                ("activeTabRailOpacity", number(sidebar.activeTabRailOpacity)),
                ("inactiveTabCustomOpacity", number(sidebar.inactiveTabCustomOpacity)),
                ("inactiveTabMultiSelectOpacity", number(sidebar.inactiveTabMultiSelectOpacity)),
                ("badgeFill", string(sidebar.badgeFill)),
                ("borderLeading", string(sidebar.borderLeading))
            ],
            into: &lines
        )

        let dividers = theme.chrome.dividers
        appendSection(
            title: "chrome.dividers",
            pairs: [
                ("color", string(dividers.color)),
                ("thicknessPt", number(dividers.thicknessPt))
            ],
            into: &lines
        )

        let titleBar = theme.chrome.titleBar
        appendSection(
            title: "chrome.titleBar",
            pairs: [
                ("background", string(titleBar.background)),
                ("backgroundOpacity", number(titleBar.backgroundOpacity)),
                ("foreground", string(titleBar.foreground)),
                ("foregroundSecondary", string(titleBar.foregroundSecondary)),
                ("borderBottom", string(titleBar.borderBottom))
            ],
            into: &lines
        )

        let tabBar = theme.chrome.tabBar
        appendSection(
            title: "chrome.tabBar",
            pairs: [
                ("background", string(tabBar.background)),
                ("activeFill", string(tabBar.activeFill)),
                ("divider", string(tabBar.divider)),
                ("activeIndicator", string(tabBar.activeIndicator))
            ],
            into: &lines
        )

        let browserChrome = theme.chrome.browserChrome
        appendSection(
            title: "chrome.browserChrome",
            pairs: [
                ("background", string(browserChrome.background)),
                ("omnibarFill", string(browserChrome.omnibarFill))
            ],
            into: &lines
        )

        let markdownChrome = theme.chrome.markdownChrome
        appendSection(
            title: "chrome.markdownChrome",
            pairs: [
                ("background", string(markdownChrome.background))
            ],
            into: &lines
        )

        let behavior = theme.behavior
        appendSection(
            title: "behavior",
            pairs: [
                ("animateWorkspaceCrossfade", bool(behavior.animateWorkspaceCrossfade))
            ],
            into: &lines
        )

        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendSection(
        title: String,
        pairs: [(String, String?)],
        into lines: inout [String]
    ) {
        let nonEmpty = pairs.compactMap { key, value -> (String, String)? in
            guard let value else { return nil }
            return (key, value)
        }
        guard !nonEmpty.isEmpty else { return }

        lines.append("[\(title)]")
        let maxKey = nonEmpty.map(\.0.count).max() ?? 0
        for (key, value) in nonEmpty {
            let padding = String(repeating: " ", count: maxKey - key.count)
            lines.append("\(key)\(padding) = \(value)")
        }
        lines.append("")
    }

    private static func formatEntries(
        _ entries: [(String, String)],
        quoteValuesFor: Set<String>
    ) -> [String] {
        let maxKey = entries.map(\.0.count).max() ?? 0
        return entries.map { key, value in
            let padding = String(repeating: " ", count: maxKey - key.count)
            let rendered = quoteValuesFor.contains(key) ? "\"\(escape(value))\"" : value
            return "\(key)\(padding) = \(rendered)"
        }
    }

    private static func formatSortedMap(_ map: [String: String]) -> [String] {
        let sortedKeys = map.keys.sorted()
        let maxKey = sortedKeys.map(\.count).max() ?? 0
        return sortedKeys.compactMap { key in
            guard let value = map[key] else { return nil }
            let padding = String(repeating: " ", count: maxKey - key.count)
            return "\(key)\(padding) = \"\(escape(value))\""
        }
    }

    private static func string(_ value: String?) -> String? {
        guard let value else { return nil }
        return "\"\(escape(value))\""
    }

    private static func number(_ value: Double?) -> String? {
        guard let value else { return nil }
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    private static func bool(_ value: Bool?) -> String? {
        guard let value else { return nil }
        return value ? "true" : "false"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
