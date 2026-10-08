import SwiftUI
import AppKit

// M7 — Surface title bar.
//
// Renders above every terminal surface (and, when mounted, browser/markdown).
// Shows only the live description (the surface's `description` metadata key):
// the tab already carries the title, so the bar never repeats it, and with no
// description the bar takes no height at all. Collapsed it is one truncated
// line; expanded it is the full description (Markdown subset), capped and
// scrollable. Title and description editing live on the tab (context menu and
// the metadata CLI), not in this bar.

struct PanelTitleBarState: Equatable {
    var title: String?
    var description: String?
    var titleSource: MetadataSource?
    var descriptionSource: MetadataSource?
    var visible: Bool = true
    var collapsed: Bool = true

    /// The bar renders only when the workspace shows title bars and the surface
    /// has a description. Everything that reserves space for the bar (the
    /// portal's top frame edge included) keys off this.
    var rendersBar: Bool {
        visible && !(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// Maximum description render region: ~5 × line height at 11pt.
/// Used as an explicit frame cap when the description exceeds 5 lines.
let titleBarDescriptionMaxHeight: CGFloat = 90

struct PanelTitleBarView: View {
    let state: PanelTitleBarState
    var onToggleCollapsed: () -> Void = {}

    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chromeScaleTokens) private var chromeTokens
    @AppStorage(ThemeAppStorage.Keys.m1bSurfaceTitleBarMigrated, store: ThemeAppStorage.defaults)
    private var m1bSurfaceTitleBarMigrated = false
    @State private var measuredDescriptionHeight: CGFloat = 0

    private var descriptionText: String {
        state.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var effectiveCollapsed: Bool {
        state.collapsed
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
        if !state.rendersBar {
            EmptyView()
        } else {
            descriptionBar
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

    /// The description with its toggle chevron: one truncated line collapsed,
    /// the full Markdown description (capped, scrollable) expanded.
    private var descriptionBar: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if effectiveCollapsed {
                    collapsedDescription
                } else {
                    expandedDescription(descriptionText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onToggleCollapsed) {
                Image(systemName: effectiveCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: chromeTokens.surfaceTitleBarAccessory, weight: .semibold))
                    .foregroundColor(resolvedSecondaryForegroundColor)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(chevronAccessibilityLabel))
        }
    }

    private var collapsedDescription: some View {
        Text(Self.singleLine(descriptionText))
            .font(.system(size: chromeTokens.surfaceTitleBarTitle))
            .foregroundColor(resolvedForegroundColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.vertical, 2)
    }

    /// Newlines and runs of whitespace collapse to single spaces.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @ViewBuilder
    private func expandedDescription(_ description: String) -> some View {
        let sanitized = sanitizeDescriptionMarkdown(description)
        let markdown = TitleBarDescriptionMarkdown(text: sanitized)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TitleBarDescriptionHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )

        Group {
            if measuredDescriptionHeight > titleBarDescriptionMaxHeight {
                ScrollView(.vertical, showsIndicators: true) {
                    markdown
                }
                .frame(height: titleBarDescriptionMaxHeight)
            } else {
                markdown
            }
        }
        .onPreferenceChange(TitleBarDescriptionHeightKey.self) { newValue in
            if abs(newValue - measuredDescriptionHeight) > 0.5 {
                measuredDescriptionHeight = newValue
            }
        }
    }

    private var accessibilityText: String {
        Self.singleLine(descriptionText)
    }
}

// MARK: - Description height measurement

private struct TitleBarDescriptionHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Markdown subset enforcement

/// Strips markdown constructs that the title-bar subset does not allow before
/// the string reaches the native renderer. Preserves inline code, bold, italic, lists,
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

// MARK: - Compact native markdown subset

/// Block structure stays native and lightweight: expanded descriptions never
/// create a web view. The caller sanitizes unsupported constructs first.
enum TitleBarDescriptionBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case rule
}

func titleBarDescriptionBlocks(_ text: String) -> [TitleBarDescriptionBlock] {
    var blocks: [TitleBarDescriptionBlock] = []
    var paragraph: [String] = []
    func flushParagraph() {
        if !paragraph.isEmpty {
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }
    }

    let listPattern = try? NSRegularExpression(pattern: #"^(\s*)([-+*]|[0-9]{1,9}[.)])\s+(.+)$"#)
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            flushParagraph()
            continue
        }

        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes),
           trimmed.count == hashes || trimmed.dropFirst(hashes).first?.isWhitespace == true {
            flushParagraph()
            let heading = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            blocks.append(.heading(level: hashes, text: heading))
            continue
        }

        let ruleCharacters = trimmed.filter { !$0.isWhitespace }
        if ruleCharacters.count >= 3,
           let first = ruleCharacters.first,
           "*-_".contains(first), ruleCharacters.allSatisfy({ $0 == first }) {
            flushParagraph()
            blocks.append(.rule)
            continue
        }

        if trimmed.hasPrefix(">") {
            flushParagraph()
            let quote = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let last = blocks.last, case .quote(let previous) = last {
                blocks[blocks.count - 1] = .quote(previous + "\n" + quote)
            } else {
                blocks.append(.quote(quote))
            }
            continue
        }

        let range = NSRange(line.startIndex..., in: line)
        if let match = listPattern?.firstMatch(in: line, range: range),
           let indentRange = Range(match.range(at: 1), in: line),
           let markerRange = Range(match.range(at: 2), in: line),
           let bodyRange = Range(match.range(at: 3), in: line) {
            flushParagraph()
            let marker = String(line[markerRange])
            let indentation = line[indentRange].reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            blocks.append(.listItem(
                marker: "-+*".contains(marker) ? "•" : marker,
                text: String(line[bodyRange]),
                depth: indentation / 2
            ))
            continue
        }

        paragraph.append(trimmed)
    }
    flushParagraph()
    return blocks
}

/// Foundation supplies inline emphasis/code parsing. Drop the URL attribute
/// entirely so links retain their text but cannot navigate or become controls.
func titleBarDescriptionInline(_ text: String) -> AttributedString {
    var result = (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
    for run in result.runs where run.link != nil {
        result[run.range].foregroundColor = Color.accentColor
        result[run.range].link = nil
    }
    return result
}

private struct TitleBarDescriptionMarkdown: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(titleBarDescriptionBlocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    private func inline(_ text: String, size: CGFloat = 11) -> Text {
        var attributed = titleBarDescriptionInline(text)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: size, design: .monospaced)
            attributed[run.range].foregroundColor = colorScheme == .dark
                ? Color(red: 0.85, green: 0.6, blue: 0.95)
                : Color(red: 0.6, green: 0.2, blue: 0.7)
        }
        return Text(attributed)
    }

    @ViewBuilder
    private func blockView(_ block: TitleBarDescriptionBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .padding(.vertical, 2)
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 13 : (level == 2 ? 12 : 11)
            inline(text, size: size)
                .font(.system(size: size, weight: level < 3 ? .bold : (level < 5 ? .semibold : .medium)))
                .foregroundColor(level == 6 ? .secondary : .primary)
                .padding(.top, level < 3 ? 4 : (level < 5 ? 3 : 2))
                .padding(.bottom, 2)
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .top, spacing: 5) {
                Text(verbatim: marker)
                    .monospacedDigit()
                    .frame(minWidth: 12, alignment: .trailing)
                inline(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 2)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.2) : Color.gray.opacity(0.4))
                    .frame(width: 2)
                inline(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}
