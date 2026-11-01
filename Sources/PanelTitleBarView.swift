import SwiftUI
import AppKit
import Bonsplit

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
    /// The panel's `mailbox.address`, shown in the mailbox drawer's header.
    var mailboxAddress: String?
    /// The panel has received mail, so it shows the mailbox cell (C11-397).
    var showsMailbox: Bool = false

    var hasDescription: Bool {
        !(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The bar renders only when the workspace shows title bars and the surface
    /// has a description or a mailbox. Everything that reserves space for the
    /// bar (the portal's top frame edge included) keys off this.
    var rendersBar: Bool {
        visible && (hasDescription || showsMailbox)
    }
}

/// Maximum description render region: ~5 × line height at 11pt.
/// Used as an explicit frame cap when the description exceeds 5 lines.
let titleBarDescriptionMaxHeight: CGFloat = 90

struct PanelTitleBarView: View {
    let state: PanelTitleBarState
    var onToggleCollapsed: () -> Void = {}
    /// The panel's workspace and id, for the mailbox cell (C11-397). Without
    /// them the bar shows only the description.
    var workspace: Workspace? = nil
    var panelId: UUID? = nil
    var isVisibleInUI: Bool = true

    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chromeScaleTokens) private var chromeTokens
    @AppStorage(ThemeAppStorage.Keys.m1bSurfaceTitleBarMigrated, store: ThemeAppStorage.defaults)
    private var m1bSurfaceTitleBarMigrated = false
    @State private var measuredDescriptionHeight: CGFloat = 0
    /// The width the description gets beside the mailbox cell and chevron slot.
    @State private var descriptionWidth: CGFloat = 0
    @StateObject private var drawerPresenter = CollapsedSheetPresenter()
    @StateObject private var drawerGeometry = MailboxDrawerGeometry()
    @State private var isDrawerOpen = false
    @State private var barWidth: CGFloat = 0
    /// This bar's mailbox cell is counted as on screen by the badge store.
    @State private var cellRegistered = false

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
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .padding(.trailing, mailboxModel == nil ? 12 : 6)
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
                // The mailbox drawer hangs flush under the whole bar.
                .background(CollapsedSheetAnchorReader { drawerPresenter.anchorView = $0 })
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { barWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { barWidth = $0 }
                    }
                )
                .accessibilityElement(children: .contain)
                // An open drawer follows the area's width in place; the
                // presenter re-hangs it when its size changes.
                .onChange(of: barWidth) { _ in if isDrawerOpen { updateDrawerGeometry() } }
                .onChange(of: isVisibleInUI) { visible in
                    if !visible { closeDrawer(animated: false) }
                    updateCellRegistration(visible && mailboxModel != nil)
                }
                .onDisappear {
                    closeDrawer(animated: false)
                    updateCellRegistration(false)
                }
        }
    }

    // MARK: - Mailbox (C11-397)

    private var mailboxModel: MailboxBadgeModel? {
        guard state.showsMailbox, let workspace, let panelId else { return nil }
        return MailboxBadgeStore.shared.model(workspace: workspace, panelId: panelId)
    }

    private var drawerStyle: MailboxDrawerStyle {
        MailboxDrawerStyle(
            background: resolvedBackgroundColor.withAlphaComponent(1),
            foreground: resolvedForegroundColor,
            secondary: resolvedSecondaryForegroundColor,
            border: resolvedBottomBorderColor,
            scale: chromeTokens.surfaceTitleBarTitle / 12
        )
    }

    private func toggleDrawer() {
        if isDrawerOpen {
            closeDrawer(animated: true)
        } else {
            presentDrawer()
        }
    }

    private func closeDrawer(animated: Bool) {
        guard isDrawerOpen || drawerPresenter.isPresented else { return }
        isDrawerOpen = false
        drawerPresenter.onDismiss = nil
        if animated { drawerPresenter.dismissAnimated() } else { drawerPresenter.dismiss() }
    }

    /// Kept-alive hidden workspaces stay mounted, so "on screen" also needs
    /// the panel to be visible; the store reconciles on-screen cells faster.
    private func updateCellRegistration(_ registered: Bool) {
        guard let panelId, registered != cellRegistered else { return }
        cellRegistered = registered
        if registered {
            MailboxBadgeStore.shared.cellAppeared(panelId: panelId)
        } else {
            MailboxBadgeStore.shared.cellDisappeared(panelId: panelId)
        }
    }

    /// The drawer is its area's width (320 pt minimum) and at most 70% of
    /// the window's height.
    private func updateDrawerGeometry() {
        let window = drawerPresenter.anchorView?.window
        let windowHeight = window?.contentLayoutRect.height ?? 800
        let screenWidth = window?.screen?.visibleFrame.width ?? 4000
        drawerGeometry.update(
            width: min(max(barWidth, 320), screenWidth),
            maxHeight: max(220, windowHeight * 0.7)
        )
    }

    private func presentDrawer() {
        guard let model = mailboxModel, let workspace, let panelId else { return }
        updateDrawerGeometry()
        let workspaceId = workspace.id
        let drawer = MailboxDrawerView(
            model: model,
            panelTitle: state.title,
            panelNumber: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: panelId),
            mailboxAddress: state.mailboxAddress,
            inboxURL: MailboxBadgeStore.shared.inboxURL(workspaceId: workspaceId, panelId: panelId),
            geometry: drawerGeometry,
            style: drawerStyle,
            resolveSenders: { names in Self.resolveSenders(names, preferring: workspaceId) },
            onClose: { [weak presenter = drawerPresenter, open = $isDrawerOpen] in
                // Same path as a second click on the envelope.
                open.wrappedValue = false
                presenter?.onDismiss = nil
                presenter?.dismissAnimated()
            }
        )
        // Capture the binding, not the view: the view holds the presenter and
        // the workspace, and the presenter holds this closure.
        let open = $isDrawerOpen
        drawerPresenter.onDismiss = { open.wrappedValue = false }
        // Opening is a reason to recount: a hand-dropped file would otherwise
        // wait for the reconcile while the drawer already lists it.
        MailboxBadgeStore.inboxChanged(workspaceId: workspaceId, panelId: panelId)
        isDrawerOpen = true
        drawerPresenter.present(rootView: AnyView(drawer))
        if !drawerPresenter.isPresented { isDrawerOpen = false }
    }

    /// Matches each `from` the way the dispatcher matches a `to` (address,
    /// then role, then title), preferring a panel in the reader's workspace.
    static func resolveSenders(_ names: [String], preferring workspaceId: UUID) -> [String: MailboxDrawerSender] {
        let panels = AppDelegate.shared?.mailboxAddressableSurfaces() ?? []
        var result: [String: MailboxDrawerSender] = [:]
        for name in names where !name.isEmpty {
            let matches = MailboxMatcher.select(MailboxAddress.parse(name), from: panels, identity: { $0.identity })
            guard let match = matches.first(where: { $0.workspaceId == workspaceId }) ?? matches.first else {
                result[name] = MailboxDrawerSender(panelNumber: nil, address: nil, isOpen: false)
                continue
            }
            result[name] = MailboxDrawerSender(
                panelNumber: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: match.surfaceId),
                address: match.address,
                isOpen: true
            )
        }
        return result
    }

    private var chevronAccessibilityLabel: String {
        if displaysCollapsed {
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
                if displaysCollapsed {
                    collapsedDescription
                } else {
                    // An expanded mail-only bar renders the placeholder the way
                    // it renders a description, so one arriving does not move it.
                    expandedDescription(Self.collapsedLine(descriptionText).isPlaceholder
                        ? Self.collapsedLine(descriptionText).text : descriptionText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TitleBarDescriptionWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(TitleBarDescriptionWidthKey.self) { newValue in
                if abs(newValue - descriptionWidth) > 0.5 { descriptionWidth = newValue }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            if let model = mailboxModel {
                // Fixed width, pinned to the first line: a long description
                // truncates before it and an expanded one grows under it.
                MailboxCellView(
                    model: model,
                    isOpen: isDrawerOpen,
                    fontSize: chromeTokens.surfaceTitleBarTitle - 1,
                    secondary: resolvedSecondaryForegroundColor,
                    action: toggleDrawer
                )
                .background(CollapsedSheetTrailingAnchorReader { drawerPresenter.trailingAnchorView = $0 })
                .onAppear { updateCellRegistration(isVisibleInUI) }
                .onDisappear { updateCellRegistration(false) }
            }
            Button(action: onToggleCollapsed) {
                Image(systemName: displaysCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: chromeTokens.surfaceTitleBarAccessory, weight: .semibold))
                    .foregroundColor(resolvedSecondaryForegroundColor)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(chevronAccessibilityLabel))
            // The chevron shows only when there is more to see: a collapsed
            // line that is cut off, or an expanded description taller than a
            // line. Its slot stays either way, so neither the description nor
            // the mailbox cell moves when it appears.
            .opacity(showsChevron ? 1 : 0)
            .disabled(!showsChevron)
            .accessibilityHidden(!showsChevron)
        }
        // One height for every collapsed bar (placeholder or description,
        // mailbox cell or not), so the panel below never moves. Expanded,
        // the bar only grows from there.
        .frame(minHeight: rowHeight, maxHeight: displaysCollapsed ? rowHeight : nil, alignment: .top)
    }

    private var showsChevron: Bool {
        Self.needsMoreThanOneLine(
            description: descriptionText,
            fontSize: chromeTokens.surfaceTitleBarTitle,
            availableWidth: descriptionWidth
        )
    }

    /// What the bar draws: collapsed when the panel says so, and also when the
    /// description fits on one line, since expanding it would show the same
    /// line. A short description is never stuck expanded with no way back.
    private var displaysCollapsed: Bool {
        Self.displaysCollapsed(
            collapsed: effectiveCollapsed,
            description: descriptionText,
            fontSize: chromeTokens.surfaceTitleBarTitle,
            availableWidth: descriptionWidth
        )
    }

    /// The description needs more than the one collapsed line: that line is
    /// cut off, or the text has its own line breaks. Content alone decides,
    /// so the chevron (shown exactly when this holds) means the same thing
    /// whether the bar is expanded or collapsed. Before the bar has a width
    /// it is false.
    static func needsMoreThanOneLine(description: String, fontSize: CGFloat, availableWidth: CGFloat) -> Bool {
        guard !description.isEmpty, availableWidth > 0 else { return false }
        if description.contains(where: \.isNewline) { return true }
        return lineOverflows(collapsedLine(description).text, fontSize: fontSize, width: availableWidth)
    }

    /// Until the bar has a width, it follows the panel's state so the first
    /// frame matches the last; after that a one-line description draws collapsed.
    static func displaysCollapsed(collapsed: Bool, description: String, fontSize: CGFloat, availableWidth: CGFloat) -> Bool {
        if collapsed { return true }
        guard availableWidth > 0 else { return false }
        return !needsMoreThanOneLine(description: description, fontSize: fontSize, availableWidth: availableWidth)
    }

    /// The line is wider than `width` in the bar's font. Biased by 2 pt
    /// toward overflowing, so a line SwiftUI truncates by a hair still gets
    /// its chevron.
    static func lineOverflows(_ text: String, fontSize: CGFloat, width: CGFloat) -> Bool {
        let natural = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return ceil(natural) > width - 2
    }

    /// The collapsed row's height: one line of the description font with its
    /// padding, or the chevron's 18 pt slot if that is taller.
    private var rowHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: chromeTokens.surfaceTitleBarTitle)
        return max(ceil(font.ascender - font.descender + font.leading) + 4, 18)
    }

    private var collapsedDescription: some View {
        // A mail-only bar reads a dim placeholder in the same font, so a real
        // description takes its place on the same line without a jump.
        let line = Self.collapsedLine(descriptionText)
        return Text(line.text)
            .font(.system(size: chromeTokens.surfaceTitleBarTitle))
            .foregroundColor(line.isPlaceholder ? resolvedSecondaryForegroundColor : resolvedForegroundColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.vertical, 2)
    }

    /// The collapsed line: the description on one line, or the placeholder
    /// when the bar shows only because the panel has mail.
    static func collapsedLine(_ description: String) -> (text: String, isPlaceholder: Bool) {
        let line = singleLine(description)
        if line.isEmpty {
            return (String(localized: "titlebar.description.placeholder", defaultValue: "No subtitle set"), true)
        }
        return (line, false)
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
        Self.collapsedLine(descriptionText).text
    }
}

// MARK: - Description height measurement

private struct TitleBarDescriptionWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
            let task = titleBarDescriptionTaskListItem(content)
            blocks.append(.listItem(
                marker: task?.marker ?? marker,
                text: titleBarDescriptionInertLinks(task?.text ?? content),
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

private func titleBarDescriptionTaskListItem(_ text: AttributedString) -> (marker: String, text: AttributedString)? {
    let value = String(text.characters)
    let marker: String
    if value.hasPrefix("[ ] ") { marker = "☐" }
    else if value.hasPrefix("[x] ") || value.hasPrefix("[X] ") { marker = "☑" }
    else { return nil }

    var remaining = text
    let end = remaining.index(remaining.startIndex, offsetByCharacters: 4)
    remaining.removeSubrange(remaining.startIndex..<end)
    return (marker, titleBarDescriptionTrimmed(remaining))
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
