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
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case listItem(marker: String, text: AttributedString, depth: Int)
    case quote(AttributedString)
    case rule
}

private enum TitleBarDescriptionBlockKind: Equatable {
    case paragraph
    case heading(Int)
    case listItem(marker: String, depth: Int)
    case quote
    case codeBlock
    case rule
}

/// Uses semantic block identity to group runs from one native row. List items
/// and block quotes can span multiple paragraph intents, so they key by item or
/// quote identity instead of paragraph identity.
private struct TitleBarDescriptionBlockKey: Equatable {
    let enclosingIdentity: Int
    let blockIdentity: Int
    let kind: TitleBarDescriptionBlockKind
}

func titleBarDescriptionBlocks(_ text: String) -> [TitleBarDescriptionBlock] {
    guard let parsed = try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .full)
    ) else {
        return text.isEmpty ? [] : [.paragraph(AttributedString(text))]
    }

    var blocks: [TitleBarDescriptionBlock] = []
    var currentKey: TitleBarDescriptionBlockKey?
    var currentText = AttributedString()
    var currentParagraphIdentity: Int?

    func flushCurrentBlock() {
        guard let key = currentKey else { return }
        let content = titleBarDescriptionTrimmed(currentText)

        switch key.kind {
        case .paragraph:
            guard !content.characters.isEmpty else { break }
            blocks.append(.paragraph(titleBarDescriptionInertLinks(content)))
        case .codeBlock:
            guard !content.characters.isEmpty else { break }
            var code = titleBarDescriptionInertLinks(content)
            for run in code.runs {
                code[run.range].font = .system(size: 11, design: .monospaced)
            }
            blocks.append(.paragraph(code))
        case .heading(let level):
            guard !content.characters.isEmpty else { break }
            blocks.append(.heading(level: level, text: titleBarDescriptionInertLinks(content)))
        case .listItem(let marker, let depth):
            guard !content.characters.isEmpty else { break }
            blocks.append(.listItem(
                marker: marker,
                text: titleBarDescriptionInertLinks(content),
                depth: depth
            ))
        case .quote:
            guard !content.characters.isEmpty else { break }
            blocks.append(.quote(titleBarDescriptionInertLinks(content)))
        case .rule:
            blocks.append(.rule)
        }

        currentKey = nil
        currentText = AttributedString()
        currentParagraphIdentity = nil
    }

    for (runIndex, run) in parsed.runs.enumerated() {
        let key = titleBarDescriptionBlockKey(
            for: run.presentationIntent,
            fallbackIdentity: runIndex
        )
        let paragraphIdentity = titleBarDescriptionParagraphIdentity(for: run.presentationIntent)

        if currentKey != key {
            flushCurrentBlock()
            currentKey = key
        } else if titleBarDescriptionJoinsParagraphs(key.kind),
                  let previousParagraphIdentity = currentParagraphIdentity,
                  let paragraphIdentity,
                  previousParagraphIdentity != paragraphIdentity {
            currentText.append(AttributedString("\n"))
        }
        currentParagraphIdentity = paragraphIdentity

        var fragment = AttributedString(parsed[run.range])
        if key.kind == .rule {
            fragment = AttributedString(String(fragment.characters).replacingOccurrences(of: "\u{2E3B}", with: ""))
        }
        currentText.append(fragment)
    }
    flushCurrentBlock()
    return blocks
}

private func titleBarDescriptionBlockKey(
    for intent: PresentationIntent?,
    fallbackIdentity: Int
) -> TitleBarDescriptionBlockKey {
    let components = intent?.components ?? []
    let enclosingIdentity = components.first?.identity ?? fallbackIdentity

    if let itemIndex = components.firstIndex(where: {
        if case .listItem = $0.kind { return true }
        return false
    }), case .listItem(let ordinal) = components[itemIndex].kind {
        let item = components[itemIndex]
        let parentList = components.dropFirst(itemIndex + 1).first(where: {
            switch $0.kind {
            case .orderedList, .unorderedList: return true
            default: return false
            }
        })
        let marker: String
        if let parentList, case .orderedList = parentList.kind {
            marker = "\(ordinal)."
        } else {
            marker = "•"
        }
        let depth = max(0, components.reduce(into: 0) { count, component in
            switch component.kind {
            case .orderedList, .unorderedList: count += 1
            default: break
            }
        } - 1)
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: item.identity,
            blockIdentity: item.identity,
            kind: .listItem(marker: marker, depth: depth)
        )
    }

    if let heading = components.last(where: {
        if case .header = $0.kind { return true }
        return false
    }), case .header(let level) = heading.kind {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: enclosingIdentity,
            blockIdentity: heading.identity,
            kind: .heading(level)
        )
    }

    if let rule = components.last(where: {
        if case .thematicBreak = $0.kind { return true }
        return false
    }) {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: enclosingIdentity,
            blockIdentity: rule.identity,
            kind: .rule
        )
    }

    if let codeBlock = components.last(where: {
        if case .codeBlock = $0.kind { return true }
        return false
    }) {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: enclosingIdentity,
            blockIdentity: codeBlock.identity,
            kind: .codeBlock
        )
    }

    if let quote = components.first(where: {
        if case .blockQuote = $0.kind { return true }
        return false
    }) {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: quote.identity,
            blockIdentity: quote.identity,
            kind: .quote
        )
    }

    if let paragraph = components.last(where: {
        if case .paragraph = $0.kind { return true }
        return false
    }) {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: enclosingIdentity,
            blockIdentity: paragraph.identity,
            kind: .paragraph
        )
    }

    return TitleBarDescriptionBlockKey(
        enclosingIdentity: enclosingIdentity,
        blockIdentity: fallbackIdentity,
        kind: .paragraph
    )
}

private func titleBarDescriptionParagraphIdentity(for intent: PresentationIntent?) -> Int? {
    intent?.components.first(where: {
        if case .paragraph = $0.kind { return true }
        return false
    })?.identity
}

private func titleBarDescriptionJoinsParagraphs(_ kind: TitleBarDescriptionBlockKind) -> Bool {
    switch kind {
    case .listItem, .quote: return true
    default: return false
    }
}

private func titleBarDescriptionTrimmed(_ input: AttributedString) -> AttributedString {
    guard let first = input.characters.firstIndex(where: { !$0.isWhitespace }),
          let last = input.characters.lastIndex(where: { !$0.isWhitespace }) else {
        return AttributedString()
    }
    return AttributedString(input[first..<input.index(afterCharacter: last)])
}

/// Full Markdown parsing retains inline styling while the native block mapper
/// consumes presentation intents. Drop links after parsing so labels remain
/// visible without creating controls or navigation.
private func titleBarDescriptionInertLinks(_ input: AttributedString) -> AttributedString {
    var result = input
    for run in result.runs where run.link != nil {
        result[run.range].foregroundColor = Color.accentColor
        result[run.range].link = nil
    }
    return result
}

/// Foundation supplies inline emphasis/code parsing for this compatibility
/// helper. Drop the URL attribute entirely so links retain their text but
/// cannot navigate or become controls.
func titleBarDescriptionInline(_ text: String) -> AttributedString {
    let parsed = (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
    return titleBarDescriptionInertLinks(parsed)
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

    private func inline(_ text: AttributedString, size: CGFloat = 11) -> Text {
        var attributed = titleBarDescriptionInertLinks(text)
        for run in attributed.runs {
            let isCodeBlock = run.presentationIntent?.components.contains(where: {
                if case .codeBlock = $0.kind { return true }
                return false
            }) ?? false
            guard isCodeBlock || run.inlinePresentationIntent?.contains(.code) == true else { continue }
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
