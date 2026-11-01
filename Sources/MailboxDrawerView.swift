import SwiftUI
import AppKit

// C11-397: the subtitle bar's mailbox cell and the drawer it opens.
//
// The cell is `[unread] envelope [received]`: unread in orange (on an orange
// backdrop for three minutes after the newest unread message lands), received
// in gray. Each number has a fixed slot sized for five characters (exact
// through 99999, then `123k`), so nothing in the bar moves when a count
// changes. The drawer is read-only: it lists the panel's mail newest first,
// shows what it sent, and summarizes both in Insights; it never claims,
// deletes or sends anything. Every string in a message is untrusted text from
// another agent and renders verbatim.

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
    /// Wide enough for the widest count text at this size in monospaced digits.
    private var slotWidth: CGFloat {
        ceil(fontSize * 0.62 * CGFloat(MailboxPanelMail.countSlotCharacters)) + 6
    }

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
        lines = MailboxHoldCopy.cellHelp(linesBeforeHold: lines, heldBehindDraft: model.heldBehindDraft)
        lines.append(String(localized: "mailbox.cell.help.open", defaultValue: "Click to read"))
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        MailboxHoldCopy.cellAccessibility(
            unread: unread,
            received: received,
            heldBehindDraft: model.heldBehindDraft
        )
    }
}

// MARK: - Drawer

/// The open drawer's size. The bar changes it in place when its area
/// resizes, so the drawer keeps its scroll position, "Show all" folds and
/// listing instead of being rebuilt.
final class MailboxDrawerGeometry: ObservableObject {
    @Published var width: CGFloat = 320
    @Published var maxHeight: CGFloat = 220

    func update(width: CGFloat, maxHeight: CGFloat) {
        if self.width != width { self.width = width }
        if self.maxHeight != maxHeight { self.maxHeight = maxHeight }
    }
}

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
    @ObservedObject var geometry: MailboxDrawerGeometry
    let style: MailboxDrawerStyle
    let resolveSenders: ([String]) -> [String: MailboxDrawerSender]

    /// C11-399: the drawer reads what the panel received, or what it sent.
    /// Insights summarizes both.
    enum Tab: Hashable { case received, sent, insights }

    @State private var tab: Tab = .received
    @State private var listing: MailboxPanelMail.Listing?
    @State private var sentListing: MailboxPanelMail.SentListing?
    @State private var sentGeneration = 0
    @State private var insights: MailboxPanelMail.Insights?
    @State private var insightsGeneration = 0
    @State private var insightSenders: [String: MailboxDrawerSender] = [:]
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
            if let held = MailboxHoldCopy.drawerBanner(heldBehindDraft: model.heldBehindDraft) {
                Text(held)
                    .font(metaFont)
                    .foregroundColor(Color(nsColor: .systemOrange))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("mailbox-draft-hold")
            }
            tabBar
            Rectangle().fill(style.border).frame(height: 1)
            content
        }
        .frame(width: geometry.width, alignment: .leading)
        .background(Color(nsColor: style.background))
        .overlay(Rectangle().stroke(style.border, lineWidth: 1))
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _ in
            reload()
            if tab == .insights { reloadInsights() }
        }
        .onChange(of: tab) { newTab in
            if newTab == .sent { reloadSent() }
            if newTab == .insights { reloadInsights() }
        }
        // Recipients take mail on their own; their counts do not move this
        // panel's revision, so the open Sent view refreshes itself. One listing
        // of this panel's `_sent/` plus a few stats per message, off the main
        // thread, and only while the Sent tab is showing.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if tab == .sent { reloadSent() }
        }
        // The hourly and daily buckets slide with the clock, and recipients
        // take sent mail on their own. A full insights scan is heavier than a
        // Sent refresh, so it repeats less often, and only while showing.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            if tab == .insights { reloadInsights() }
        }
    }

    private var tabBar: some View {
        Picker("", selection: $tab) {
            Text(String(localized: "mailbox.drawer.tab.received", defaultValue: "Received")).tag(Tab.received)
            Text(String(localized: "mailbox.drawer.tab.sent", defaultValue: "Sent")).tag(Tab.sent)
            Text(String(localized: "mailbox.drawer.tab.insights", defaultValue: "Insights")).tag(Tab.insights)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 270 * style.scale)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
            Text(tab == .sent
                ? String(
                    localized: "mailbox.drawer.sent.counts",
                    defaultValue: "\(sentListing?.total ?? 0) sent"
                )
                : String(
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
        if tab == .sent {
            sentContent
        } else if tab == .insights {
            insightsContent
        } else if let listing {
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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(listing.messages) { message in
                            let parent = message.inReplyTo.flatMap { id in listing.messages.first { $0.fileId == id } }
                            MailboxMessageCard(
                                message: message,
                                sender: senders[message.from],
                                now: timeline.date,
                                isExpanded: expanded.contains(message.id),
                                parentId: parent?.id,
                                parentTopic: parent?.topic,
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
            .frame(height: min(max(contentHeight, 1), geometry.maxHeight))
            .onPreferenceChange(MailboxDrawerHeightKey.self) { contentHeight = $0 }
        }
    }

    @ViewBuilder
    private var sentContent: some View {
        if let sentListing {
            if sentListing.messages.isEmpty {
                Text(String(localized: "mailbox.drawer.sent.empty", defaultValue: "Nothing sent yet."))
                    .font(textFont)
                    .foregroundColor(style.secondary)
                    .padding(12)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sentListing.messages) { message in
                                MailboxSentCard(
                                    message: message,
                                    now: timeline.date,
                                    style: style,
                                    bodyFont: bodyFont,
                                    metaFont: metaFont,
                                    textFont: textFont
                                )
                                Rectangle().fill(style.border).frame(height: 1)
                            }
                            if sentListing.hiddenCount > 0 {
                                Text(String(
                                    localized: "mailbox.drawer.sent.olderHidden",
                                    defaultValue: "\(sentListing.hiddenCount) older sent messages are not shown."
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
                .frame(height: min(max(contentHeight, 1), geometry.maxHeight))
                .onPreferenceChange(MailboxDrawerHeightKey.self) { contentHeight = $0 }
            }
        } else {
            Text(String(localized: "mailbox.drawer.loading", defaultValue: "Reading mail…"))
                .font(textFont)
                .foregroundColor(style.secondary)
                .padding(12)
        }
    }

    @ViewBuilder
    private var insightsContent: some View {
        if let insights {
            ScrollView(.vertical, showsIndicators: true) {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    MailboxInsightsView(
                        insights: insights,
                        senders: insightSenders,
                        now: timeline.date,
                        width: geometry.width,
                        style: style,
                        metaFont: metaFont,
                        textFont: textFont
                    )
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: MailboxDrawerHeightKey.self, value: geometry.size.height)
                        }
                    )
                }
            }
            .frame(height: min(max(contentHeight, 1), geometry.maxHeight))
            .onPreferenceChange(MailboxDrawerHeightKey.self) { contentHeight = $0 }
        } else {
            Text(String(localized: "mailbox.drawer.loading", defaultValue: "Reading mail…"))
                .font(textFont)
                .foregroundColor(style.secondary)
                .padding(12)
        }
    }

    private func reloadInsights() {
        guard let inboxURL else {
            insights = MailboxPanelMail.Insights()
            return
        }
        insightsGeneration += 1
        let generation = insightsGeneration
        let root = inboxURL.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = autoreleasepool { MailboxPanelMail.insights(inbox: inboxURL, mailboxesRoot: root) }
            DispatchQueue.main.async {
                guard generation == insightsGeneration else { return }
                insightSenders = resolveSenders(loaded.senders.top.map(\.name))
                if loaded != insights { insights = loaded }
            }
        }
    }

    private func reloadSent() {
        guard let inboxURL else {
            sentListing = MailboxPanelMail.SentListing()
            return
        }
        sentGeneration += 1
        let generation = sentGeneration
        let root = inboxURL.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = autoreleasepool { MailboxPanelMail.sentListing(senderInbox: inboxURL, mailboxesRoot: root) }
            DispatchQueue.main.async {
                guard generation == sentGeneration else { return }
                if loaded != sentListing { sentListing = loaded }
            }
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

/// One message the panel sent: where it went and whether each recipient's
/// agent has taken it. Text is untrusted and renders verbatim.
private struct MailboxSentCard: View {
    let message: MailboxPanelMail.SentMessage
    let now: Date
    let style: MailboxDrawerStyle
    let bodyFont: Font
    let metaFont: Font
    let textFont: Font

    private var orange: Color { Color(nsColor: .systemOrange) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            ForEach(message.recipients.indices, id: \.self) { index in
                recipientRow(message.recipients[index])
            }
            if let copy = message.message, copy.problem == nil, !copy.body.isEmpty {
                Text(verbatim: copy.body)
                    .font(bodyFont)
                    .foregroundColor(style.foreground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(style.border, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeText: String {
        guard let date = message.sentAt else { return "" }
        return "\(MailboxDrawerText.stamp(date)) · \(MailboxDrawerText.age(of: date, now: now))"
    }

    private func recipientRow(_ recipient: MailboxPanelMail.SentRecipient) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(localized: "mailbox.drawer.sent.to", defaultValue: "to"))
                .font(textFont)
                .foregroundColor(style.secondary)
            Text(verbatim: recipient.name)
                .font(textFont.weight(.semibold))
                .foregroundColor(style.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            stateChip(recipient.state)
        }
    }

    private func stateChip(_ state: MailboxPanelMail.SentState) -> some View {
        let label: String
        let help: String
        switch state {
        case .unread:
            label = String(localized: "mailbox.drawer.state.unread", defaultValue: "UNREAD")
            help = String(localized: "mailbox.drawer.sent.state.unread.help", defaultValue: "The recipient has not taken this message yet.")
        case .read:
            label = String(localized: "mailbox.drawer.state.read", defaultValue: "READ")
            help = String(localized: "mailbox.drawer.sent.state.read.help", defaultValue: "The recipient has taken this message.")
        case .gone:
            label = String(localized: "mailbox.drawer.sent.state.gone", defaultValue: "GONE")
            help = String(localized: "mailbox.drawer.sent.state.gone.help", defaultValue: "The recipient's copy is no longer there.")
        }
        let unread = state == .unread
        return Text(label)
            .font(.system(size: 9 * style.scale, weight: .semibold))
            .foregroundColor(unread ? Color.black.opacity(0.85) : style.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(unread ? orange : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(unread ? Color.clear : style.border, lineWidth: 1))
            .help(help)
    }
}

private struct MailboxMessageCard: View {
    let message: MailboxPanelMail.Message
    let sender: MailboxDrawerSender?
    let now: Date
    let isExpanded: Bool
    /// The parent message's list id, when the parent is in the list.
    let parentId: String?
    let parentTopic: String?
    let style: MailboxDrawerStyle
    let bodyFont: Font
    let metaFont: Font
    let textFont: Font
    let onToggleExpanded: () -> Void
    let onShowParent: (String) -> Void

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
            items.append(Chip(text: label, kind: parentId.map { .link($0) } ?? .plain))
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
            if message.isLong {
                Button(isExpanded
                    ? String(localized: "mailbox.drawer.showLess", defaultValue: "Show less")
                    : String(localized: "mailbox.drawer.showAll", defaultValue: "Show all")
                ) { onToggleExpanded() }
                .buttonStyle(.link)
                .font(metaFont)
            }
            if message.problem == nil && (!message.body.isEmpty || message.reference.map(Self.hasText) == true) {
                // The drawer's panel never becomes key, so text selection could
                // not be copied with Command-C; this button is the copy path.
                Button(String(localized: "mailbox.drawer.copy", defaultValue: "Copy text")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.fullText, forType: .string)
                }
                .buttonStyle(.link)
                .font(metaFont)
            }
        }
    }

    private static func hasText(_ reference: MailboxPanelMail.Reference) -> Bool {
        if case .text(let text, _, _) = reference.content { return !text.isEmpty }
        return false
    }

    private func bodyText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(bodyFont)
            .foregroundColor(style.foreground)
            .lineLimit(isExpanded ? nil : MailboxPanelMail.foldedLineLimit)
            .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Insights

/// The drawer's Insights view: totals, recent activity, who writes and about
/// what, and where this panel's own mail went. Names and topics are untrusted
/// text from other agents and render verbatim. Every row has a fixed shape,
/// so a refresh changes numbers, never the layout.
private struct MailboxInsightsView: View {
    let insights: MailboxPanelMail.Insights
    let senders: [String: MailboxDrawerSender]
    let now: Date
    let width: CGFloat
    let style: MailboxDrawerStyle
    let metaFont: Font
    let textFont: Font

    private var orange: Color { Color(nsColor: .systemOrange) }
    private var barColor: Color { style.foreground.opacity(0.55) }
    private var trackColor: Color { style.border.opacity(0.6) }
    private var numberFont: Font { .system(size: 17 * style.scale, weight: .semibold, design: .monospaced).monospacedDigit() }
    private var labelFont: Font { .system(size: 9 * style.scale, weight: .semibold) }
    private var sectionFont: Font { metaFont.weight(.semibold) }
    private var countWidth: CGFloat { 62 * style.scale }
    private var unreadWidth: CGFloat { 72 * style.scale }
    private var nameWidth: CGFloat { min(max(width * 0.36, 110), 280) }
    private var chartHeight: CGFloat { 40 * style.scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            tiles
            recentLines
            barChart(
                title: String(localized: "mailbox.insights.hourly.title", defaultValue: "Received, last 24 hours"),
                values: insights.hourly,
                leading: String(localized: "mailbox.insights.hourly.start", defaultValue: "24h ago"),
                trailing: String(localized: "mailbox.insights.hourly.end", defaultValue: "now"),
                help: hourHelp
            )
            barChart(
                title: String(localized: "mailbox.insights.daily.title", defaultValue: "Received, last 14 days"),
                values: insights.daily,
                leading: insights.dayStarts.first.map(dayText) ?? "",
                trailing: String(localized: "mailbox.insights.daily.end", defaultValue: "today"),
                help: dayHelp
            )
            if insights.scanned > 0 {
                rankingSection(
                    title: String(localized: "mailbox.insights.senders.title", defaultValue: "Top senders"),
                    ranking: insights.senders,
                    showUnread: true,
                    detail: senderDetail
                )
                rankingSection(
                    title: String(localized: "mailbox.insights.topics.title", defaultValue: "Top topics"),
                    ranking: insights.topics,
                    showUnread: false,
                    detail: { _ in nil }
                )
                compositionLine
            }
            if insights.sent > 0 {
                rankingSection(
                    title: String(localized: "mailbox.insights.recipients.title", defaultValue: "Sent to"),
                    ranking: insights.recipients,
                    showUnread: false,
                    detail: { _ in nil },
                    trailing: insights.sentCopies > 0
                        ? String(
                            localized: "mailbox.insights.recipients.taken",
                            defaultValue: "\(insights.sentTaken) of \(insights.sentCopies) copies taken"
                        )
                        : nil
                )
            }
            footnotes
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Totals

    private var tiles: some View {
        HStack(spacing: 8) {
            tile(
                insights.received,
                label: String(localized: "mailbox.insights.tile.received", defaultValue: "RECEIVED"),
                help: String(localized: "mailbox.insights.tile.received.help", defaultValue: "Every message this panel has received.")
            )
            tile(
                insights.unread,
                label: String(localized: "mailbox.insights.tile.unread", defaultValue: "UNREAD"),
                help: String(localized: "mailbox.insights.tile.unread.help", defaultValue: "Messages the agent has not taken yet."),
                accent: insights.unread > 0
            )
            tile(
                max(0, insights.received - insights.unread),
                label: String(localized: "mailbox.insights.tile.taken", defaultValue: "TAKEN"),
                help: String(localized: "mailbox.insights.tile.taken.help", defaultValue: "Messages the agent has taken.")
            )
            tile(
                insights.sent,
                label: String(localized: "mailbox.insights.tile.sent", defaultValue: "SENT"),
                help: String(localized: "mailbox.insights.tile.sent.help", defaultValue: "Messages this panel sent that c11 still records.")
            )
        }
    }

    private func tile(_ value: Int, label: String, help: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value.formatted())
                .font(numberFont)
                .foregroundColor(accent ? orange : style.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(labelFont)
                .foregroundColor(style.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(style.border, lineWidth: 1))
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private var recentLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            metaLine(String(
                localized: "mailbox.insights.recent",
                defaultValue: "\(insights.lastHour) in the last hour · \(insights.lastDay) in 24 hours · \(insights.lastWeek) in 7 days"
            ))
            if let firstAt = insights.firstAt, let lastAt = insights.lastAt {
                if let perDay = insights.perDay {
                    metaLine(String(
                        localized: "mailbox.insights.span.rate",
                        defaultValue: "First \(MailboxDrawerText.stamp(firstAt)) · newest \(MailboxDrawerText.age(of: lastAt, now: now)) · about \(perDay.formatted(.number.precision(.fractionLength(1)))) a day"
                    ))
                } else {
                    metaLine(String(
                        localized: "mailbox.insights.span",
                        defaultValue: "First \(MailboxDrawerText.stamp(firstAt)) · newest \(MailboxDrawerText.age(of: lastAt, now: now))"
                    ))
                }
            }
            if insights.unread > 0, let oldest = insights.oldestUnreadAt {
                Text(String(
                    localized: "mailbox.insights.oldestUnread",
                    defaultValue: "Oldest unread has waited \(MailboxDrawerText.span(now.timeIntervalSince(oldest)))"
                ))
                .font(metaFont)
                .foregroundColor(orange)
                .lineLimit(1)
            }
        }
    }

    private func metaLine(_ text: String) -> some View {
        Text(text)
            .font(metaFont.monospacedDigit())
            .foregroundColor(style.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    // MARK: Activity

    private func barChart(
        title: String,
        values: [Int],
        leading: String,
        trailing: String,
        help: @escaping (Int) -> String
    ) -> some View {
        let peak = values.max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(sectionFont)
                    .foregroundColor(style.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(localized: "mailbox.insights.peak", defaultValue: "peak \(peak)"))
                    .font(metaFont.monospacedDigit())
                    .foregroundColor(style.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { index in
                    let value = values[index]
                    let height = value == 0 ? 1 : max(3, chartHeight * CGFloat(value) / CGFloat(max(peak, 1)))
                    RoundedRectangle(cornerRadius: value == 0 ? 0 : 2)
                        .fill(value == 0 ? trackColor : barColor)
                        .frame(height: height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .contentShape(Rectangle())
                        .help(help(index))
                }
            }
            .frame(height: chartHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(values.map(String.init).joined(separator: ", ")))
            HStack {
                Text(leading)
                Spacer(minLength: 8)
                Text(trailing)
            }
            .font(metaFont)
            .foregroundColor(style.secondary)
            .lineLimit(1)
        }
    }

    private func hourHelp(_ index: Int) -> String {
        let count = insights.hourly[index]
        let hoursAgo = MailboxPanelMail.insightsHours - 1 - index
        if hoursAgo == 0 {
            return String(localized: "mailbox.insights.hour.current.help", defaultValue: "Past hour: \(count) received")
        }
        return String(
            localized: "mailbox.insights.hour.help",
            defaultValue: "\(hoursAgo + 1) to \(hoursAgo) hours ago: \(count) received"
        )
    }

    private func dayHelp(_ index: Int) -> String {
        let count = insights.daily[index]
        guard insights.dayStarts.indices.contains(index) else { return "\(count)" }
        return String(
            localized: "mailbox.insights.day.help",
            defaultValue: "\(dayText(insights.dayStarts[index])): \(count) received"
        )
    }

    private func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: Rankings

    private func senderDetail(_ tally: MailboxPanelMail.Tally) -> String? {
        guard let number = senders[tally.name]?.panelNumber else { return nil }
        return String(localized: "mailbox.drawer.panelNumber", defaultValue: "panel \(number)")
    }

    private func rankingSection(
        title: String,
        ranking: MailboxPanelMail.Ranking,
        showUnread: Bool,
        detail: @escaping (MailboxPanelMail.Tally) -> String?,
        trailing: String? = nil
    ) -> some View {
        let peak = max(ranking.top.first?.count ?? 0, 1)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(sectionFont)
                    .foregroundColor(style.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing ?? String(
                    localized: "mailbox.insights.distinct",
                    defaultValue: "\(ranking.distinct) in all"
                ))
                .font(metaFont.monospacedDigit())
                .foregroundColor(style.secondary)
                .lineLimit(1)
                .fixedSize()
            }
            if ranking.top.isEmpty {
                Text(String(localized: "mailbox.insights.none", defaultValue: "None yet."))
                    .font(metaFont)
                    .foregroundColor(style.secondary)
            }
            ForEach(ranking.top) { tally in
                rankingRow(
                    name: tally.name,
                    detail: detail(tally),
                    count: tally.count,
                    fraction: CGFloat(tally.count) / CGFloat(peak),
                    unread: showUnread ? tally.unread : nil
                )
            }
            if ranking.others > 0 {
                rankingRow(
                    name: String(
                        localized: "mailbox.insights.others",
                        defaultValue: "\(ranking.distinct - ranking.top.count) more"
                    ),
                    detail: nil,
                    count: ranking.others,
                    fraction: nil,
                    unread: showUnread ? 0 : nil,
                    muted: true
                )
            }
        }
    }

    private func rankingRow(
        name: String,
        detail: String?,
        count: Int,
        fraction: CGFloat?,
        unread: Int?,
        muted: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 4) {
                Text(verbatim: name)
                    .font(textFont)
                    .foregroundColor(muted ? style.secondary : style.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(verbatim: detail)
                        .font(metaFont)
                        .foregroundColor(style.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(width: nameWidth, alignment: .leading)
            .help(name)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(trackColor)
                    if let fraction {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: max(2, geometry.size.width * min(fraction, 1)))
                    }
                }
            }
            .frame(height: 6)
            Text(verbatim: count.formatted())
                .font(metaFont.monospacedDigit())
                .foregroundColor(style.foreground)
                .lineLimit(1)
                .frame(width: countWidth, alignment: .trailing)
            if let unread {
                Text(unread > 0
                    ? String(localized: "mailbox.insights.unreadCount", defaultValue: "\(unread) unread")
                    : "")
                .font(metaFont.monospacedDigit())
                .foregroundColor(orange)
                .lineLimit(1)
                .frame(width: unreadWidth, alignment: .trailing)
            }
        }
    }

    /// Wraps instead of truncating: every count in it matters.
    private var compositionLine: some View {
        Text(String(
            localized: "mailbox.insights.composition",
            defaultValue: "\(insights.urgent) urgent · \(insights.replies) replies · \(insights.fileBodies) with a file body · \(insights.untitled) without a topic"
        ))
        .font(metaFont.monospacedDigit())
        .foregroundColor(style.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Notes

    @ViewBuilder
    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 3) {
            if insights.received == 0 && insights.sent == 0 {
                metaLine(String(localized: "mailbox.drawer.empty", defaultValue: "No mail yet."))
            }
            if insights.scanIsPartial {
                metaLine(String(
                    localized: "mailbox.insights.note.partial",
                    defaultValue: "Senders and topics cover the newest \(insights.scanned + insights.unparsed) of \(insights.received) messages."
                ))
            }
            if insights.unparsed > 0 {
                metaLine(String(
                    localized: "mailbox.insights.note.unparsed",
                    defaultValue: "\(insights.unparsed) files could not be read as envelopes."
                ))
            }
            if insights.sentIsTrimmed {
                metaLine(String(
                    localized: "mailbox.insights.note.sentTrimmed",
                    defaultValue: "c11 keeps the newest \(MailboxSentLedger.retain) sent records, so older sends are not counted."
                ))
            }
        }
    }
}
