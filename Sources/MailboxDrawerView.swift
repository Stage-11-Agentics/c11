import SwiftUI
import AppKit

// C11-397: the subtitle bar's mailbox cell and the drawer it opens.
//
// The cell is `[unread] envelope [received]`: unread in orange (on an orange
// backdrop for three minutes after the newest unread message lands), received
// in gray. Each number has a fixed slot sized for `99+`, so nothing in the bar
// moves when a count changes. The drawer is read-only: it lists the panel's
// mail newest first and never claims, deletes or sends anything. Every string
// in a message is untrusted text from another agent and renders verbatim.

/// Colors and sizes the drawer needs. The drawer is hosted in its own child
/// panel, outside the bar's SwiftUI environment, so the bar hands them over.
struct MailboxDrawerStyle {
    var background: NSColor
    var foreground: Color
    var secondary: Color
    var border: Color
    var scale: CGFloat
}

enum MailboxDrawerText {
    /// `now`, `45s`, `12m`, `5h`, `3d`: the age of a moment, or a duration.
    static func span(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 48 * 3600 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    static func age(of date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 10 {
            return String(localized: "mailbox.drawer.age.now", defaultValue: "just now")
        }
        return String(
            localized: "mailbox.drawer.age.ago",
            defaultValue: "\(span(interval)) ago"
        )
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Cell

struct MailboxCellView: View {
    @ObservedObject var model: MailboxBadgeModel
    let isOpen: Bool
    let fontSize: CGFloat
    let secondary: Color
    let action: () -> Void

    @State private var hovering = false

    private var unread: Int { model.summary.unread }
    private var received: Int { model.summary.received }
    /// Wide enough for `99+` at this size in tabular digits.
    private var slotWidth: CGFloat { ceil(fontSize * 2.2) + 6 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                unreadSlot
                Image(systemName: "envelope")
                    .font(.system(size: fontSize + 1))
                    .foregroundColor(unread > 0 ? Color(nsColor: .systemOrange) : secondary)
                    .frame(width: fontSize + 5)
                Text(MailboxPanelMail.countText(received))
                    .font(.system(size: fontSize, design: .monospaced).monospacedDigit())
                    .foregroundColor(secondary.opacity(received == 0 ? 0.55 : 1))
                    .lineLimit(1)
                    .frame(width: slotWidth, alignment: .leading)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(isOpen ? 0.14 : (hovering ? 0.08 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(.isButton)
    }

    private var unreadSlot: some View {
        let fresh = model.isFresh && unread > 0
        return Text(unread > 0 ? MailboxPanelMail.countText(unread) : "")
            .font(.system(size: fontSize, weight: fresh ? .semibold : .regular, design: .monospaced).monospacedDigit())
            .foregroundColor(fresh ? Color.black.opacity(0.85) : Color(nsColor: .systemOrange))
            .lineLimit(1)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(fresh ? Color(nsColor: .systemOrange) : Color.clear)
            )
            .frame(width: slotWidth, alignment: .trailing)
    }

    private var helpText: String {
        var lines: [String] = []
        if unread > 0 {
            var line = String(
                localized: "mailbox.cell.help.unread",
                defaultValue: "\(unread) unread: the agent has not taken them yet"
            )
            if let oldest = model.summary.oldestUnreadAt {
                line += " " + String(
                    localized: "mailbox.cell.help.oldest",
                    defaultValue: "(oldest \(MailboxDrawerText.age(of: oldest, now: Date())))"
                )
            }
            lines.append(line)
        }
        lines.append(String(localized: "mailbox.cell.help.received", defaultValue: "\(received) received"))
        lines.append(String(localized: "mailbox.cell.help.open", defaultValue: "Click to read"))
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        String(
            localized: "mailbox.cell.accessibility",
            defaultValue: "Mailbox, \(unread) unread, \(received) received"
        )
    }
}

// MARK: - Drawer

/// Who sent a message, resolved against the panels open right now.
struct MailboxDrawerSender: Equatable {
    var panelNumber: Int?
    var address: String?
    var isOpen: Bool
}

struct MailboxDrawerView: View {
    @ObservedObject var model: MailboxBadgeModel
    let panelTitle: String?
    let panelNumber: Int?
    let mailboxAddress: String?
    let inboxURL: URL?
    let width: CGFloat
    let maxHeight: CGFloat
    let style: MailboxDrawerStyle
    let resolveSenders: ([String]) -> [String: MailboxDrawerSender]

    @State private var listing: MailboxPanelMail.Listing?
    @State private var senders: [String: MailboxDrawerSender] = [:]
    @State private var expanded: Set<String> = []
    @State private var contentHeight: CGFloat = 0
    @State private var loadGeneration = 0

    private var bodyFont: Font { .system(size: 11.5 * style.scale, design: .monospaced) }
    private var metaFont: Font { .system(size: 10.5 * style.scale, design: .monospaced) }
    private var textFont: Font { .system(size: 12 * style.scale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(style.border).frame(height: 1)
            content
        }
        .frame(width: width, alignment: .leading)
        .background(Color(nsColor: style.background))
        .overlay(Rectangle().stroke(style.border, lineWidth: 1))
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _ in reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(localized: "mailbox.drawer.title", defaultValue: "Mail for \(headerName)"))
            .font(textFont.weight(.semibold))
            .foregroundColor(style.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            Text(identityLine)
                .font(metaFont)
                .foregroundColor(style.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(String(
                localized: "mailbox.drawer.counts",
                defaultValue: "\(model.summary.unread) unread · \(model.summary.received) received"
            ))
            .font(metaFont.monospacedDigit())
            .foregroundColor(style.secondary)
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerName: String {
        panelTitle ?? String(localized: "mailbox.drawer.thisPanel", defaultValue: "this panel")
    }

    private var identityLine: String {
        var parts: [String] = []
        if let mailboxAddress { parts.append(mailboxAddress) }
        if let panelNumber {
            parts.append(String(localized: "mailbox.drawer.panelNumber", defaultValue: "panel \(panelNumber)"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let listing {
            if listing.messages.isEmpty {
                Text(String(localized: "mailbox.drawer.empty", defaultValue: "No mail yet."))
                    .font(textFont)
                    .foregroundColor(style.secondary)
                    .padding(12)
            } else {
                messageList(listing)
            }
        } else {
            Text(String(localized: "mailbox.drawer.loading", defaultValue: "Reading mail…"))
                .font(textFont)
                .foregroundColor(style.secondary)
                .padding(12)
        }
    }

    private func messageList(_ listing: MailboxPanelMail.Listing) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(listing.messages) { message in
                            MailboxMessageCard(
                                message: message,
                                sender: senders[message.from],
                                now: timeline.date,
                                isExpanded: expanded.contains(message.id),
                                hasParentInList: message.inReplyTo.map { id in listing.messages.contains { $0.id == id } } ?? false,
                                parentTopic: message.inReplyTo.flatMap { id in listing.messages.first { $0.id == id }?.topic },
                                style: style,
                                bodyFont: bodyFont,
                                metaFont: metaFont,
                                textFont: textFont,
                                onToggleExpanded: { toggleExpanded(message.id) },
                                onShowParent: { id in
                                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                                }
                            )
                            .id(message.id)
                            Rectangle().fill(style.border).frame(height: 1)
                        }
                        if listing.hiddenCount > 0 {
                            Text(String(
                                localized: "mailbox.drawer.olderHidden",
                                defaultValue: "\(listing.hiddenCount) older messages are not shown."
                            ))
                            .font(metaFont)
                            .foregroundColor(style.secondary)
                            .padding(12)
                        }
                    }
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: MailboxDrawerHeightKey.self, value: geometry.size.height)
                        }
                    )
                }
            }
            .frame(height: min(max(contentHeight, 1), maxHeight))
            .onPreferenceChange(MailboxDrawerHeightKey.self) { contentHeight = $0 }
        }
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func reload() {
        guard let inboxURL else {
            listing = MailboxPanelMail.Listing()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = autoreleasepool { MailboxPanelMail.listing(inbox: inboxURL) }
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                senders = resolveSenders(Array(Set(loaded.messages.map(\.from))))
                listing = loaded
            }
        }
    }
}

private struct MailboxDrawerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MailboxMessageCard: View {
    let message: MailboxPanelMail.Message
    let sender: MailboxDrawerSender?
    let now: Date
    let isExpanded: Bool
    let hasParentInList: Bool
    let parentTopic: String?
    let style: MailboxDrawerStyle
    let bodyFont: Font
    let metaFont: Font
    let textFont: Font
    let onToggleExpanded: () -> Void
    let onShowParent: (String) -> Void

    static let foldedLineLimit = 12

    private var orange: Color { Color(nsColor: .systemOrange) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            fromRow
            chips
            bodyBlock
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle().fill(message.isUnread ? orange : Color.clear).frame(width: 3),
            alignment: .leading
        )
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            stateChip
            Text(verbatim: message.topic ?? String(localized: "mailbox.drawer.noTopic", defaultValue: "(no topic)"))
                .font(metaFont.weight(.semibold))
                .foregroundColor(message.topic == nil ? style.secondary : style.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(timeText)
                .font(metaFont.monospacedDigit())
                .foregroundColor(style.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var stateChip: some View {
        let label = message.isUnread
            ? String(localized: "mailbox.drawer.state.unread", defaultValue: "UNREAD")
            : String(localized: "mailbox.drawer.state.read", defaultValue: "READ")
        return Text(label)
            .font(.system(size: 9 * style.scale, weight: .semibold))
            .foregroundColor(message.isUnread ? Color.black.opacity(0.85) : style.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(message.isUnread ? orange : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(message.isUnread ? Color.clear : style.border, lineWidth: 1)
            )
            .help(message.isUnread
                ? String(localized: "mailbox.drawer.state.unread.help", defaultValue: "The agent has not taken this message yet.")
                : String(localized: "mailbox.drawer.state.read.help", defaultValue: "The agent has taken this message."))
    }

    private var timeText: String {
        guard let date = message.sentAt ?? message.arrivedAt else { return "" }
        return "\(MailboxDrawerText.stamp(date)) · \(MailboxDrawerText.age(of: date, now: now))"
    }

    private var fromRow: some View {
        var parts: [String] = []
        if let number = sender?.panelNumber {
            parts.append(String(localized: "mailbox.drawer.panelNumber", defaultValue: "panel \(number)"))
        }
        if let address = sender?.address, address != message.from { parts.append(address) }
        if sender?.isOpen != true {
            parts.append(String(localized: "mailbox.drawer.sender.notOpen", defaultValue: "not open"))
        }
        let detail = parts.joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(localized: "mailbox.drawer.from", defaultValue: "from"))
                .font(textFont)
                .foregroundColor(style.secondary)
            Text(verbatim: message.from.isEmpty ? "?" : message.from)
                .font(textFont.weight(.semibold))
                .foregroundColor(style.foreground)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(verbatim: "· " + detail)
                    .font(metaFont)
                    .foregroundColor(style.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        let items = chipItems
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    chip(items[index])
                }
            }
        }
    }

    private enum ChipKind { case plain, warn, link(String) }
    private struct Chip { let text: String; let kind: ChipKind }

    private var chipItems: [Chip] {
        var items: [Chip] = []
        if message.urgent {
            items.append(Chip(text: String(localized: "mailbox.drawer.chip.urgent", defaultValue: "urgent"), kind: .warn))
        }
        if let parent = message.inReplyTo {
            let label = parentTopic.map {
                String(localized: "mailbox.drawer.chip.replyToTopic", defaultValue: "↳ reply to \($0)")
            } ?? String(localized: "mailbox.drawer.chip.replyToId", defaultValue: "↳ reply to \(String(parent.prefix(10)))…")
            items.append(Chip(text: label, kind: hasParentInList ? .link(parent) : .plain))
        }
        if let ttl = message.ttlSeconds, ttl > 0, let expiry = message.expiresAt() {
            let ttlText = MailboxDrawerText.span(TimeInterval(ttl))
            if message.isExpired(now: now) {
                items.append(Chip(text: String(
                    localized: "mailbox.drawer.chip.ttlExpired",
                    defaultValue: "ttl \(ttlText) · expired \(MailboxDrawerText.span(now.timeIntervalSince(expiry))) ago"
                ), kind: .warn))
            } else {
                items.append(Chip(text: String(
                    localized: "mailbox.drawer.chip.ttlLive",
                    defaultValue: "ttl \(ttlText) · expires in \(MailboxDrawerText.span(expiry.timeIntervalSince(now)))"
                ), kind: .plain))
            }
        }
        if let replyTo = message.replyTo {
            items.append(Chip(text: String(localized: "mailbox.drawer.chip.replyAddress", defaultValue: "replies to \(replyTo)"), kind: .plain))
        }
        if let contentType = message.contentType {
            items.append(Chip(text: contentType, kind: .plain))
        }
        return items
    }

    @ViewBuilder
    private func chip(_ chip: Chip) -> some View {
        let label = Text(verbatim: chip.text)
            .font(metaFont)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 0.5)
        switch chip.kind {
        case .plain:
            label.foregroundColor(style.secondary)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(style.border, lineWidth: 1))
        case .warn:
            label.foregroundColor(orange)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(orange.opacity(0.45), lineWidth: 1))
        case .link(let id):
            Button { onShowParent(id) } label: {
                label.foregroundColor(Color(nsColor: .linkColor))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(nsColor: .linkColor).opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Body

    private var fullText: String {
        var pieces: [String] = []
        if !message.body.isEmpty { pieces.append(message.body) }
        if case .text(let text, _, _)? = message.reference?.content { pieces.append(text) }
        return pieces.joined(separator: "\n\n")
    }

    private var isLong: Bool {
        let text = fullText
        let lines = text.reduce(into: 1) { count, character in if character.isNewline { count += 1 } }
        return lines > Self.foldedLineLimit || text.count > 1400
    }

    @ViewBuilder
    private var bodyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = message.problem {
                Text(verbatim: problem)
                    .font(bodyFont)
                    .foregroundColor(orange)
            } else {
                if !message.body.isEmpty {
                    bodyText(message.body)
                }
                if let reference = message.reference {
                    referenceBlock(reference)
                }
                if message.body.isEmpty && message.reference == nil {
                    Text(String(localized: "mailbox.drawer.emptyBody", defaultValue: "This message has no body."))
                        .font(bodyFont)
                        .foregroundColor(style.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(style.border, lineWidth: 1))

        HStack(spacing: 12) {
            if isLong {
                Button(isExpanded
                    ? String(localized: "mailbox.drawer.showLess", defaultValue: "Show less")
                    : String(localized: "mailbox.drawer.showAll", defaultValue: "Show all")
                ) { onToggleExpanded() }
                .buttonStyle(.link)
                .font(metaFont)
            }
            if !fullText.isEmpty {
                Button(String(localized: "mailbox.drawer.copy", defaultValue: "Copy text")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullText, forType: .string)
                }
                .buttonStyle(.link)
                .font(metaFont)
            }
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(bodyFont)
            .foregroundColor(style.foreground)
            .lineLimit(isExpanded ? nil : Self.foldedLineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func referenceBlock(_ reference: MailboxPanelMail.Reference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: referenceCaption(reference))
                .font(metaFont)
                .foregroundColor(style.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            switch reference.content {
            case .text(let text, let truncated, let bytes):
                if text.isEmpty {
                    Text(String(localized: "mailbox.drawer.ref.emptyFile", defaultValue: "The referenced file is empty."))
                        .font(bodyFont)
                        .foregroundColor(style.secondary)
                } else {
                    bodyText(text)
                }
                if truncated {
                    Text(String(
                        localized: "mailbox.drawer.ref.truncated",
                        defaultValue: "Showing the first \(MailboxDrawerText.byteCount(MailboxPanelMail.maxReferencedBytes)) of \(MailboxDrawerText.byteCount(bytes))."
                    ))
                    .font(metaFont)
                    .foregroundColor(orange)
                }
            default:
                Text(verbatim: referenceProblem(reference.content))
                    .font(bodyFont)
                    .foregroundColor(orange)
            }
        }
    }

    private func referenceCaption(_ reference: MailboxPanelMail.Reference) -> String {
        if case .text(_, _, let bytes) = reference.content {
            return String(
                localized: "mailbox.drawer.ref.captionSized",
                defaultValue: "from file \(reference.path) · \(MailboxDrawerText.byteCount(bytes))"
            )
        }
        return String(localized: "mailbox.drawer.ref.caption", defaultValue: "from file \(reference.path)")
    }

    private func referenceProblem(_ content: MailboxPanelMail.Reference.Content) -> String {
        switch content {
        case .text:
            return ""
        case .missing:
            return String(localized: "mailbox.drawer.ref.missing", defaultValue: "The referenced file is gone (no such file).")
        case .notAbsolute:
            return String(localized: "mailbox.drawer.ref.notAbsolute", defaultValue: "The reference is not an absolute path, so c11 did not open it.")
        case .notRegularFile:
            return String(localized: "mailbox.drawer.ref.notRegular", defaultValue: "The reference is not a regular file, so c11 did not open it.")
        case .notText(let bytes):
            return String(
                localized: "mailbox.drawer.ref.notText",
                defaultValue: "The referenced file is not text (\(MailboxDrawerText.byteCount(bytes)))."
            )
        case .unreadable(let reason):
            return String(localized: "mailbox.drawer.ref.unreadable", defaultValue: "c11 could not read the referenced file: \(reason)")
        }
    }
}
