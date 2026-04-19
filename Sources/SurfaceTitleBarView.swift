import SwiftUI
import AppKit
import MarkdownUI

// M7 — Surface title bar.
//
// Renders above every terminal surface (and, when mounted, browser/markdown).
// Shows a short title and an optional structured description; both ride on the
// per-surface metadata blob (`title` / `description` canonical keys owned by M2).
//
// The expand/collapse animation, description Markdown subset, and inline edit
// overlay are staged additively. The v1 mount renders a static single-line
// header fed from the M2 blob; the edit field is reserved for portal hosting in
// GhosttySurfaceScrollView (see spec: Layering constraint).

struct SurfaceTitleBarState: Equatable {
    var title: String?
    var description: String?
    var titleSource: MetadataSource?
    var descriptionSource: MetadataSource?
    var visible: Bool = true
    var collapsed: Bool = true
}

/// Maximum description render region: ~5 × line height at 11pt.
/// Used as an explicit frame cap when the description exceeds 5 lines.
let titleBarDescriptionMaxHeight: CGFloat = 90

struct SurfaceTitleBarView: View {
    let state: SurfaceTitleBarState
    var onToggleCollapsed: () -> Void = {}

    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ThemeAppStorage.Keys.m1bSurfaceTitleBarMigrated, store: ThemeAppStorage.defaults)
    private var m1bSurfaceTitleBarMigrated = false

    private var descriptionIsEmpty: Bool {
        state.description?.isEmpty ?? true
    }

    /// Render-time collapsed state. When description is empty the bar must
    /// render as if collapsed regardless of the flag, to avoid a multi-line
    /// title + empty description + disabled chevron visual trap.
    private var effectiveCollapsed: Bool {
        state.collapsed || descriptionIsEmpty
    }

    private var themeContext: ThemeContext {
        themeManager.makeContext(colorScheme: colorScheme)
    }

    private var useThemeMigrationPath: Bool {
        m1bSurfaceTitleBarMigrated && themeManager.isEnabled
    }

    private var resolvedBackgroundColor: NSColor {
        guard useThemeMigrationPath,
              let color: NSColor = themeManager.resolve(.titleBar_background, context: themeContext) else {
            return NSColor.windowBackgroundColor
        }
        return color
    }

    private var resolvedBackgroundOpacity: Double {
        guard useThemeMigrationPath,
              let opacity: Double = themeManager.resolve(.titleBar_backgroundOpacity, context: themeContext) else {
            return 0.85
        }
        return opacity
    }

    private var resolvedForegroundColor: Color {
        guard useThemeMigrationPath,
              let color: NSColor = themeManager.resolve(.titleBar_foreground, context: themeContext) else {
            return .primary
        }
        return Color(nsColor: color)
    }

    private var resolvedSecondaryForegroundColor: Color {
        guard useThemeMigrationPath,
              let color: NSColor = themeManager.resolve(.titleBar_foregroundSecondary, context: themeContext) else {
            return .secondary
        }
        return Color(nsColor: color)
    }

    private var resolvedBottomBorderColor: Color {
        guard useThemeMigrationPath,
              let color: NSColor = themeManager.resolve(.titleBar_borderBottom, context: themeContext) else {
            return Color(nsColor: NSColor.separatorColor)
        }
        return Color(nsColor: color)
    }

    var body: some View {
        if !state.visible {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                if !effectiveCollapsed, let description = state.description, !description.isEmpty {
                    descriptionRow(description)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: resolvedBackgroundColor)
                    .opacity(resolvedBackgroundOpacity)
            )
            .overlay(
                Rectangle()
                    .fill(resolvedBottomBorderColor)
                    .frame(height: 1),
                alignment: .bottom
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var chevronAccessibilityLabel: String {
        if effectiveCollapsed {
            return String(localized: "titlebar.chevron.expand",
                          defaultValue: "Expand title bar")
        } else {
            return String(localized: "titlebar.chevron.collapse",
                          defaultValue: "Collapse title bar")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(state.title ?? String(localized: "titlebar.empty_title",
                                       defaultValue: "Untitled"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(resolvedForegroundColor)
                .lineLimit(effectiveCollapsed ? 1 : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onToggleCollapsed) {
                Image(systemName: effectiveCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(resolvedSecondaryForegroundColor)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(descriptionIsEmpty)
            .accessibilityLabel(Text(chevronAccessibilityLabel))
        }
    }

    @ViewBuilder
    private func descriptionRow(_ description: String) -> some View {
        let sanitized = sanitizeDescriptionMarkdown(description)
        ScrollView(.vertical, showsIndicators: true) {
            Markdown(sanitized)
                .markdownTheme(titleBarMarkdownTheme(for: colorScheme))
                .environment(\.openURL, OpenURLAction { _ in .discarded })
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: titleBarDescriptionMaxHeight)
        .padding(.leading, 20)
        .padding(.top, 2)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let title = state.title, !title.isEmpty {
            parts.append(title)
        }
        if !effectiveCollapsed, let description = state.description, !description.isEmpty {
            parts.append(description)
        }
        return parts.joined(separator: " — ")
    }
}

// MARK: - Markdown subset enforcement

/// Strips markdown constructs that the title-bar subset does not allow before
/// the string reaches MarkdownUI. Preserves inline code, bold, italic, lists,
/// headings, blockquotes, rules, and links (link navigation is disabled
/// elsewhere via OpenURLAction { .discarded }).
///
/// Removed:
/// - Images `![alt](url)` — graphics are parking-lot.
/// - Fenced code blocks ```` ``` ```` — too large for a 5-line cap.
/// - Table rows — lines matching `^\s*\|.*\|\s*$`.
func sanitizeDescriptionMarkdown(_ input: String) -> String {
    var s = input

    // 1. Strip images: ![alt text](url) — both lazy and link-style.
    // Regex matches ! followed by [any chars] followed by (any chars).
    if let imgRegex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\([^)]*\\)", options: []) {
        let range = NSRange(s.startIndex..., in: s)
        s = imgRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }

    // 2. Strip fenced code blocks. Split by lines, skip content between
    //    matching ``` fences (and the fence lines themselves).
    do {
        let lines = s.components(separatedBy: "\n")
        var result: [String] = []
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            result.append(line)
        }
        s = result.joined(separator: "\n")
    }

    // 3. Strip table rows: lines that look like `| ... |`.
    do {
        let lines = s.components(separatedBy: "\n")
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            return !(trimmed.hasPrefix("|") && trimmed.hasSuffix("|"))
        }
        s = kept.joined(separator: "\n")
    }

    return s
}

// MARK: - Compact MarkdownUI theme

/// Tight variant of `cmuxMarkdownTheme` sized for a 5-line-capped title bar.
/// Base font 11pt; heading hierarchy 13/12/11 so a `#` heading stays readable
/// but does not dominate a short description region.
func titleBarMarkdownTheme(for colorScheme: ColorScheme) -> Theme {
    let isDark = colorScheme == .dark
    let baseSize: CGFloat = 11
    let inlineCodeFill = isDark
        ? Color(nsColor: NSColor(white: 0.18, alpha: 1.0))
        : Color(nsColor: NSColor(white: 0.92, alpha: 1.0))
    let inlineCodeFg = isDark
        ? Color(red: 0.85, green: 0.6, blue: 0.95)
        : Color(red: 0.6, green: 0.2, blue: 0.7)

    return Theme()
        .text {
            ForegroundColor(.secondary)
            FontSize(baseSize)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(13)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 4, bottom: 2)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(12)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 4, bottom: 2)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(11)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 3, bottom: 2)
        }
        .heading4 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(11)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 3, bottom: 2)
        }
        .heading5 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(11)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 2, bottom: 2)
        }
        .heading6 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(11)
                    ForegroundColor(.secondary)
                }
                .markdownMargin(top: 2, bottom: 2)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(baseSize)
            ForegroundColor(inlineCodeFg)
            BackgroundColor(inlineCodeFill)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isDark ? Color.white.opacity(0.2) : Color.gray.opacity(0.4))
                    .frame(width: 2)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                        FontSize(baseSize)
                    }
                    .padding(.leading, 8)
            }
            .markdownMargin(top: 3, bottom: 3)
        }
        .link {
            ForegroundColor(Color.accentColor)
        }
        .strong {
            FontWeight(.semibold)
        }
        .thematicBreak {
            Divider()
                .markdownMargin(top: 4, bottom: 4)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 3)
        }
}
