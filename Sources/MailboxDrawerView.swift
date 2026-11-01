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

    /// A pickup wait: `45s`, `4m 05s`, `12m`, `3h 05m`, `2d 4h`. Precise
    /// while short, coarser as it grows, never wider than a tile.
    static func wait(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 600 { return "\(seconds / 60)m " + String(format: "%02ds", seconds % 60) }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h " + String(format: "%02dm", seconds % 3600 / 60) }
        return "\(seconds / 86400)d \(seconds % 86400 / 3600)h"
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
    /// The open panel's title, when it is resolved by id (Conversations).
    var title: String? = nil
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
    /// Closes the drawer, as a second click on the envelope does.
    var onClose: () -> Void = {}
    /// Open panels by id, for Conversations: a stamp names a panel exactly.
    var resolvePanels: ([UUID]) -> [UUID: MailboxDrawerSender] = { _ in [:] }

    /// C11-399: the drawer reads what the panel received, or what it sent.
    /// Conversations pairs both by peer; Insights summarizes both.
    enum Tab: Hashable { case received, sent, conversations, insights }

    @State private var tab: Tab = .received
    @State private var listing: MailboxPanelMail.Listing?
    @State private var sentListing: MailboxPanelMail.SentListing?
    @State private var sentGeneration = 0
    @State private var insights: MailboxPanelMail.Insights?
    @State private var insightsGeneration = 0
    @State private var insightSenders: [String: MailboxDrawerSender] = [:]
    /// What the reader clicked in Insights; kept while the drawer is open.
    @State private var insightsFilter = MailboxPanelMail.InsightsFilter()
    /// The slice for `insightsFilter`, computed off the main thread. The
    /// previous slice stays on screen until the new one lands.
    @State private var insightsSlice: MailboxPanelMail.Slice?
    @State private var sliceGeneration = 0
    @State private var resolvedSenderNames: Set<String> = []
    /// One insights scan at a time. A request during a scan marks it dirty and
    /// one rescan follows, after `insightsRescanDelay`, so a busy inbox costs
    /// one scan every few seconds at most, however fast mail arrives.
    @State private var insightsInFlight = false
    @State private var insightsDirty = false
    private static let insightsRescanDelay: TimeInterval = 2
    @State private var senders: [String: MailboxDrawerSender] = [:]
    @State private var expanded: Set<String> = []
    @State private var contentHeight: CGFloat = 0
    @State private var loadGeneration = 0
    /// The notice for a dead or malformed body link, shown over the drawer.
    @State private var linkNotice: PanelLinkNotice?
    @State private var linkNoticeGeneration = 0
    /// Kept by the drawer, so a look at another tab keeps the open thread.
    @StateObject private var conversations = MailboxConversationsModel()

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
        // Over the content, so showing it never moves the drawer's layout.
        .overlay(alignment: .topLeading) {
            if let linkNotice {
                MailboxLinkNoticeCard(text: linkNotice.text).padding(12)
            }
        }
        .overlay(Rectangle().stroke(style.border, lineWidth: 1))
        // Every body link in every tab opens here; Text never opens a URL itself.
        .environment(\.openURL, OpenURLAction { url in
            // A link that landed closes the drawer the way its close button does,
            // so the destination and its pulse are not covered.
            MailboxDrawerLinkOpener.open(url, onPanelLinkOpened: onClose, showNotice: showLinkNotice)
        })
        .onAppear {
            reload()
            // Warm Insights while the reader looks at Received, so the tab
            // opens on numbers instead of a loading line.
            reloadInsights()
        }
        .onChange(of: model.revision) { _ in
            reload()
            if tab == .insights { reloadInsights() }
        }
        .onChange(of: tab) { newTab in
            if newTab == .sent { reloadSent() }
            if newTab == .insights { reloadInsights() }
        }
        .onChange(of: insightsFilter) { _ in recomputeSlice() }
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

    /// Five seconds, like the notice a panel shows for the same link.
    private func showLinkNotice(_ notice: PanelLinkNotice) {
        linkNoticeGeneration &+= 1
        let generation = linkNoticeGeneration
        linkNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if linkNoticeGeneration == generation { linkNotice = nil }
        }
    }

    private var tabBar: some View {
        Picker("", selection: $tab) {
            Text(String(localized: "mailbox.drawer.tab.received", defaultValue: "Received")).tag(Tab.received)
            Text(String(localized: "mailbox.drawer.tab.sent", defaultValue: "Sent")).tag(Tab.sent)
            Text(String(localized: "mailbox.drawer.tab.conversations", defaultValue: "Conversations")).tag(Tab.conversations)
            Text(String(localized: "mailbox.drawer.tab.insights", defaultValue: "Insights")).tag(Tab.insights)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
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
            Text(tab == .conversations
                ? MailboxConversationsText.headerCounts(
                    conversations: conversations.index?.conversations.count ?? 0,
                    unread: model.summary.unread
                )
                : tab == .sent
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
            MailboxDrawerCloseButton(style: style, action: onClose)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 * style.scale }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
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
        } else if tab == .conversations {
            MailboxConversationsView(
                model: conversations,
                inboxURL: inboxURL,
                revision: model.revision,
                thisName: mailboxAddress ?? headerName,
                width: geometry.width,
                height: geometry.maxHeight,
                style: style,
                bodyFont: bodyFont,
                metaFont: metaFont,
                textFont: textFont,
                resolvePanels: resolvePanels
            )
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
                                },
                                onOpenConversation: openConversation
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
                                    textFont: textFont,
                                    onOpenConversation: openConversation
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
                        filter: $insightsFilter,
                        slice: insightsSlice,
                        senders: insightSenders,
                        now: timeline.date,
                        width: geometry.width,
                        style: style,
                        metaFont: metaFont,
                        textFont: textFont,
                        onOpenConversation: openConversation
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
        guard !insightsInFlight else {
            insightsDirty = true
            return
        }
        insightsInFlight = true
        insightsGeneration += 1
        let generation = insightsGeneration
        let root = inboxURL.deletingLastPathComponent()
        // The first load is what the reader waits for; refreshes are background.
        let qos: DispatchQoS.QoSClass = insights == nil ? .userInitiated : .utility
        DispatchQueue.global(qos: qos).async {
            let (loaded, names) = autoreleasepool { () -> (MailboxPanelMail.Insights, [String]) in
                let loaded = MailboxPanelMail.insights(inbox: inboxURL, mailboxesRoot: root)
                // The busiest senders a slice can rank, so drilled rankings show
                // panel numbers too; resolved on main only when the set changes.
                return (loaded, MailboxPanelMail.busiestSenders(loaded))
            }
            DispatchQueue.main.async {
                if generation == insightsGeneration {
                    // A Set: a reordering of the same busiest senders resolves nothing.
                    let nameSet = Set(names)
                    if nameSet != resolvedSenderNames {
                        insightSenders = resolveSenders(names)
                        resolvedSenderNames = nameSet
                    }
                    // Assigned without comparing: an equality check walks every
                    // record on main, and a new scan always differs in time.
                    insights = loaded
                    recomputeSlice()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.insightsRescanDelay) {
                    insightsInFlight = false
                    guard insightsDirty else { return }
                    insightsDirty = false
                    if tab == .insights { reloadInsights() }
                }
            }
        }
    }

    /// Filters the latest scan for the current filter on a background queue.
    /// Only the newest request lands; until then the previous slice shows.
    private func recomputeSlice() {
        let filter = insightsFilter
        guard let insights, !filter.isEmpty, filter.recipient == nil else {
            sliceGeneration += 1
            insightsSlice = nil
            return
        }
        sliceGeneration += 1
        let generation = sliceGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let slice = MailboxPanelMail.slice(insights, filter: filter)
            DispatchQueue.main.async {
                guard generation == sliceGeneration else { return }
                insightsSlice = slice
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

    /// A sender or recipient name in another tab opens that peer's thread
    /// in Conversations, in a narrow drawer as in a wide one.
    private func openConversation(_ key: MailboxPanelMail.PeerKey) {
        conversations.open(key)
        tab = .conversations
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

/// The drawer's close control, at the far right of its header: an × with a
/// hover wash, the same action as a second click on the envelope.
private struct MailboxDrawerCloseButton: View {
    let style: MailboxDrawerStyle
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10 * style.scale, weight: .semibold))
                .foregroundColor(hovering ? style.foreground : style.secondary)
                .frame(width: 20 * style.scale, height: 20 * style.scale)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "mailbox.drawer.close.help", defaultValue: "Close (or click the envelope again)"))
        .accessibilityLabel(Text(String(localized: "mailbox.drawer.close", defaultValue: "Close mailbox")))
        .accessibilityIdentifier("mailbox-drawer-close")
    }
}

/// A sender or recipient name that opens its conversation. It reads as the
/// plain name and shows it is a link on hover, so a card never changes size.
private struct MailboxConversationNameButton: View {
    let name: String
    let font: Font
    let style: MailboxDrawerStyle
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: name)
                .font(font)
                .foregroundColor(hovering ? Color(nsColor: .linkColor) : style.foreground)
                .underline(hovering)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "mailbox.drawer.openConversation.help", defaultValue: "Open the conversation with \(name)"))
        .accessibilityLabel(Text(String(localized: "mailbox.drawer.openConversation.help", defaultValue: "Open the conversation with \(name)")))
        .accessibilityIdentifier("mailbox-open-conversation")
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
    let onOpenConversation: (MailboxPanelMail.PeerKey) -> Void

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
                Text(copy.bodyRich)
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
            // A send is in the thread of the recipient panel it landed in.
            if let panel = recipient.panelId {
                MailboxConversationNameButton(
                    name: recipient.name,
                    font: textFont.weight(.semibold),
                    style: style,
                    action: { onOpenConversation(.panel(panel)) }
                )
            } else {
                Text(verbatim: recipient.name)
                    .font(textFont.weight(.semibold))
                    .foregroundColor(style.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
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
    let onOpenConversation: (MailboxPanelMail.PeerKey) -> Void

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
            // The sender opens its conversation: the stamped panel's, or the
            // name-only row for unstamped mail.
            if let key = MailboxPanelMail.peerKey(of: message) {
                MailboxConversationNameButton(
                    name: message.from.isEmpty ? "?" : message.from,
                    font: textFont.weight(.semibold),
                    style: style,
                    action: { onOpenConversation(key) }
                )
            } else {
                Text(verbatim: message.from.isEmpty ? "?" : message.from)
                    .font(textFont.weight(.semibold))
                    .foregroundColor(style.foreground)
                    .lineLimit(1)
            }
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
                    bodyText(message.bodyRich)
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

    /// The body with its links found once at load (C11-524); every other
    /// character renders exactly as sent.
    private func bodyText(_ text: AttributedString) -> some View {
        Text(text)
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
                    bodyText(message.referenceRich ?? AttributedString(text))
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
/// what, and where this panel's own mail went. Every sender, topic, bar and
/// recipient is a filter: a click narrows the whole view to that slice and
/// lists its newest messages. Names and topics are untrusted text from other
/// agents and render verbatim. Rows have fixed shapes and the filter row
/// always holds its height, so a click or refresh changes content, never layout.
private struct MailboxInsightsView: View {
    let insights: MailboxPanelMail.Insights
    @Binding var filter: MailboxPanelMail.InsightsFilter
    /// The slice for `filter`, or the previous one while it computes; nil
    /// before the first lands, when the totals show under the new chips.
    let slice: MailboxPanelMail.Slice?
    let senders: [String: MailboxDrawerSender]
    let now: Date
    let width: CGFloat
    let style: MailboxDrawerStyle
    let metaFont: Font
    let textFont: Font
    let onOpenConversation: (MailboxPanelMail.PeerKey) -> Void

    private var orange: Color { Color(nsColor: .systemOrange) }
    private var gold: Color { BrandColors.goldSwiftUI }
    private var barColor: Color { style.foreground.opacity(0.55) }
    private var trackColor: Color { style.border.opacity(0.6) }
    private var numberFont: Font { .system(size: 17 * style.scale, weight: .semibold, design: .monospaced).monospacedDigit() }
    private var labelFont: Font { .system(size: 9 * style.scale, weight: .semibold) }
    private var sectionFont: Font { metaFont.weight(.semibold) }
    private var countWidth: CGFloat { 62 * style.scale }
    private var unreadWidth: CGFloat { 72 * style.scale }
    private var nameWidth: CGFloat { min(max(width * 0.36, 110 * style.scale), 280 * style.scale) }
    private var chartHeight: CGFloat { 40 * style.scale }
    private var pickupChartHeight: CGFloat { 32 * style.scale }

    /// The figures a received view shows, from the exact totals or a slice.
    private struct Figures {
        var count: Int
        var unread: Int
        var lastHour: Int
        var lastDay: Int
        var lastWeek: Int
        var oldestUnreadAt: Date?
        var firstAt: Date?
        var lastAt: Date?
        var hourly: [Int]
        var daily: [Int]
        var senders: MailboxPanelMail.Ranking
        var topics: MailboxPanelMail.Ranking
        var urgent: Int
        var replies: Int
        var fileBodies: Int
        var untitled: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            filterRow
            if let key = filter.recipient {
                sentDrill(key: key)
            } else if filter.isEmpty || slice == nil {
                received(overviewFigures, slice: nil)
            } else if let slice {
                received(figures(slice), slice: slice)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overviewFigures: Figures {
        Figures(
            count: insights.received, unread: insights.unread,
            lastHour: insights.lastHour, lastDay: insights.lastDay, lastWeek: insights.lastWeek,
            oldestUnreadAt: insights.oldestUnreadAt, firstAt: insights.firstAt, lastAt: insights.lastAt,
            hourly: insights.hourly, daily: insights.daily,
            senders: insights.senders, topics: insights.topics,
            urgent: insights.urgent, replies: insights.replies, fileBodies: insights.fileBodies, untitled: insights.untitled
        )
    }

    private func figures(_ slice: MailboxPanelMail.Slice) -> Figures {
        Figures(
            count: slice.count, unread: slice.unread,
            lastHour: slice.lastHour, lastDay: slice.lastDay, lastWeek: slice.lastWeek,
            oldestUnreadAt: slice.oldestUnreadAt, firstAt: slice.firstAt, lastAt: slice.lastAt,
            hourly: slice.hourly, daily: slice.daily,
            senders: slice.senders, topics: slice.topics,
            urgent: slice.urgent, replies: slice.replies, fileBodies: slice.fileBodies, untitled: slice.untitled
        )
    }

    // MARK: Filter row

    private var filterRow: some View {
        HStack(spacing: 6) {
            if filter.isEmpty {
                Text(String(localized: "mailbox.insights.filter.hint", defaultValue: "All mail · click a sender, topic, bar or recipient to narrow"))
                    .font(metaFont)
                    .foregroundColor(style.secondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                if let from = filter.from {
                    chip(String(localized: "mailbox.insights.chip.from", defaultValue: "from \(from)")) { filter.from = nil }
                    senderConversationLink(from)
                }
                if let topic = filter.topic {
                    chip(String(localized: "mailbox.insights.chip.topic", defaultValue: "topic \(topic)")) { filter.topic = nil }
                }
                if let window = filter.window {
                    chip(windowName(window)) { filter.window = nil }
                }
                if let key = filter.recipient {
                    chip(String(localized: "mailbox.insights.chip.to", defaultValue: "to \(recipientName(key))")) { filter = MailboxPanelMail.InsightsFilter() }
                    if let panel = UUID(uuidString: key) {
                        openConversationLink { onOpenConversation(.panel(panel)) }
                    }
                }
                Spacer(minLength: 8)
                Button(String(localized: "mailbox.insights.filter.clear", defaultValue: "Clear all")) {
                    filter = MailboxPanelMail.InsightsFilter()
                }
                .buttonStyle(.link)
                .font(metaFont)
                .fixedSize()
            }
        }
        .frame(height: 20 * style.scale, alignment: .leading)
        .clipped()
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "×").foregroundColor(style.secondary)
            }
            .font(metaFont)
            .foregroundColor(style.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(gold, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "mailbox.insights.chip.remove", defaultValue: "Remove this filter"))
        .accessibilityLabel(Text(String(localized: "mailbox.insights.chip.removeLabel", defaultValue: "Remove filter \(text)")))
    }

    /// The conversations a sender name's mail is in, from the slice for this
    /// very name. One opens directly; a name several panels used (or
    /// stamped and unstamped mail alike) is never resolved to one of them:
    /// each message below opens its own.
    private func senderConversationLink(_ from: String) -> some View {
        ZStack(alignment: .leading) {
            // Both forms' width is held from the click on, so the chips after
            // this one never move when the slice lands.
            Text(String(localized: "mailbox.insights.openConversation", defaultValue: "Open conversation"))
                .hidden()
            Text(String(localized: "mailbox.insights.openConversation.several", defaultValue: "\(99) conversations"))
                .hidden()
            if let slice, slice.fromFilter == from {
                if slice.fromPeers.count == 1, let key = slice.fromPeers.first {
                    openConversationLink { onOpenConversation(key) }
                } else if slice.fromPeers.count > 1 {
                    Text(String(
                        localized: "mailbox.insights.openConversation.several",
                        defaultValue: "\(slice.fromPeers.count) conversations"
                    ))
                    .foregroundColor(style.secondary)
                    .help(String(
                        localized: "mailbox.insights.openConversation.several.help",
                        defaultValue: "Mail under this name came from more than one sender. Click a sender name in Messages below to open its conversation."
                    ))
                }
            }
        }
        .font(metaFont)
        .lineLimit(1)
        .fixedSize()
    }

    private func openConversationLink(action: @escaping () -> Void) -> some View {
        Button(String(localized: "mailbox.insights.openConversation", defaultValue: "Open conversation"), action: action)
            .buttonStyle(.link)
            .font(metaFont)
            .lineLimit(1)
            .fixedSize()
            .help(String(localized: "mailbox.insights.openConversation.help", defaultValue: "Show this conversation in the Conversations tab"))
            .accessibilityIdentifier("mailbox-insights-open-conversation")
    }

    private func recipientName(_ key: String) -> String {
        filter.recipientName ?? insights.recipients.top.first { $0.key == key }?.name ?? String(key.prefix(8))
    }

    // MARK: Received

    @ViewBuilder
    private func received(_ figures: Figures, slice: MailboxPanelMail.Slice?) -> some View {
        tiles(figures, drilled: slice != nil)
        recentLines(figures, drilled: slice != nil)
        barChart(
            title: String(localized: "mailbox.insights.hourly.title", defaultValue: "Received, last 24 hours"),
            values: figures.hourly,
            selected: filter.selectedHour(in: insights),
            leading: String(localized: "mailbox.insights.hourly.start", defaultValue: "24h ago"),
            trailing: String(localized: "mailbox.insights.hourly.end", defaultValue: "now"),
            help: { hourHelp($0, count: figures.hourly[$0]) },
            pick: { filter.pickHour($0, in: insights) }
        )
        barChart(
            title: String(localized: "mailbox.insights.daily.title", defaultValue: "Received, last 14 days"),
            values: figures.daily,
            selected: filter.selectedDay(in: insights),
            leading: insights.dayStarts.first.map(dayText) ?? "",
            trailing: String(localized: "mailbox.insights.daily.end", defaultValue: "today"),
            help: { dayHelp($0, count: figures.daily[$0]) },
            pick: { filter.pickDay($0, in: insights) }
        )
        if insights.scanned > 0 {
            rankingSection(
                title: String(localized: "mailbox.insights.senders.title", defaultValue: "Top senders"),
                ranking: figures.senders,
                layout: insights.senders,
                selected: filter.from,
                showUnread: true,
                detail: senderDetail,
                pick: { filter.toggleFrom($0.name) }
            )
            rankingSection(
                title: String(localized: "mailbox.insights.topics.title", defaultValue: "Top topics"),
                ranking: figures.topics,
                layout: insights.topics,
                selected: filter.topic,
                showUnread: false,
                detail: { _ in nil },
                pick: { filter.toggleTopic($0.name) }
            )
            Text(String(
                localized: "mailbox.insights.composition",
                defaultValue: "Urgent \(figures.urgent) · replies \(figures.replies) · file bodies \(figures.fileBodies) · no topic \(figures.untitled)"
            ))
            .font(metaFont.monospacedDigit())
            .foregroundColor(style.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let note = slice == nil ? insights.sampleScopeNote : sliceScopeNote {
                wrappingNote(note)
            }
            pickupSection(slice?.pickup ?? insights.pickup)
        }
        if let slice {
            messageList(slice)
        } else {
            if insights.sent > 0 {
                rankingSection(
                    title: String(localized: "mailbox.insights.recipients.title", defaultValue: "Sent to"),
                    ranking: insights.recipients,
                    layout: insights.recipients,
                    selected: nil,
                    showUnread: false,
                    detail: { _ in nil },
                    trailing: insights.sentCopies > 0
                        ? String(
                            localized: "mailbox.insights.recipients.taken",
                            defaultValue: "\(insights.sentTaken) of \(insights.sentCopies) copies taken"
                        )
                        : nil,
                    pick: { tally in if let key = tally.key { filter.toggleRecipient(key, name: tally.name) } }
                )
            }
            footnotes
        }
    }

    /// A drilled view counts only the parsed sample.
    private var sliceScopeNote: String? {
        guard insights.scanIsPartial else { return nil }
        return String(
            localized: "mailbox.insights.note.slice",
            defaultValue: "Filtered figures cover only the newest \(insights.scanned + insights.unparsed) of \(insights.received) messages."
        )
    }

    private func wrappingNote(_ text: String) -> some View {
        Text(text)
            .font(metaFont.monospacedDigit())
            .foregroundColor(style.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tiles(_ figures: Figures, drilled: Bool) -> some View {
        HStack(spacing: 8) {
            tile(
                figures.count,
                label: String(localized: "mailbox.insights.tile.received", defaultValue: "RECEIVED"),
                help: String(localized: "mailbox.insights.tile.received.help", defaultValue: "Every message this panel has received.")
            )
            tile(
                figures.unread,
                label: String(localized: "mailbox.insights.tile.unread", defaultValue: "UNREAD"),
                help: String(localized: "mailbox.insights.tile.unread.help", defaultValue: "Messages the agent has not taken yet."),
                accent: figures.unread > 0
            )
            tile(
                max(0, figures.count - figures.unread),
                label: String(localized: "mailbox.insights.tile.taken", defaultValue: "TAKEN"),
                help: String(localized: "mailbox.insights.tile.taken.help", defaultValue: "Messages the agent has taken.")
            )
            if drilled {
                tile(
                    text: shareText(figures.count),
                    label: String(localized: "mailbox.insights.tile.share", defaultValue: "OF ALL MAIL"),
                    help: String(localized: "mailbox.insights.tile.share.help", defaultValue: "This slice's share of the messages Insights read.")
                )
            } else {
                tile(
                    insights.sent,
                    label: String(localized: "mailbox.insights.tile.sent", defaultValue: "SENT"),
                    help: String(localized: "mailbox.insights.tile.sent.help", defaultValue: "Messages this panel sent that c11 still records.")
                )
            }
        }
    }

    private func shareText(_ count: Int) -> String {
        let base = max(insights.scanned, 1)
        let share = Double(count) / Double(base) * 100
        return share < 10
            ? share.formatted(.number.precision(.fractionLength(1))) + "%"
            : Int(share.rounded()).formatted() + "%"
    }

    private func tile(_ value: Int, label: String, help: String, accent: Bool = false) -> some View {
        tile(text: value.formatted(), label: label, help: help, accent: accent)
    }

    private func tile(text: String, label: String, help: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: text)
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

    private func recentLines(_ figures: Figures, drilled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            metaLine(String(
                localized: "mailbox.insights.recent",
                defaultValue: "\(figures.lastHour) in the last hour · \(figures.lastDay) in 24 hours · \(figures.lastWeek) in 7 days"
            ))
            if let firstAt = figures.firstAt, let lastAt = figures.lastAt {
                if !drilled, let perDay = insights.perDay {
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
            } else {
                metaLine(" ")
            }
            // Always three lines, so the charts below never move on a click.
            if figures.unread > 0, let oldest = figures.oldestUnreadAt {
                Text(String(
                    localized: "mailbox.insights.oldestUnread",
                    defaultValue: "Oldest unread has waited \(MailboxDrawerText.span(now.timeIntervalSince(oldest)))"
                ))
                .font(metaFont)
                .foregroundColor(orange)
                .lineLimit(1)
            } else {
                metaLine(" ")
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
        selected: Int?,
        leading: String,
        trailing: String,
        help: @escaping (Int) -> String,
        pick: @escaping (Int) -> Void
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
                    let isSelected = selected == index
                    let height = value == 0 ? (isSelected ? 2 : 1) : max(3, chartHeight * CGFloat(value) / CGFloat(max(peak, 1)))
                    Button { pick(index) } label: {
                        RoundedRectangle(cornerRadius: value == 0 ? 0 : 2)
                            .fill(isSelected ? gold : (value == 0 ? trackColor : barColor))
                            .opacity(selected == nil || isSelected || value == 0 ? 1 : 0.35)
                            .frame(height: height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help(index))
                    .accessibilityLabel(Text(help(index)))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .frame(height: chartHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title))
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

    /// A day by its date, an hour by its clock times, so the chip reads the
    /// same however long it stays on.
    private func windowName(_ window: MailboxPanelMail.TimeWindow) -> String {
        if window.isDay { return dayText(window.start) }
        let clock = Date.FormatStyle.dateTime.hour().minute()
        return String(
            localized: "mailbox.insights.chip.hours",
            defaultValue: "\(window.start.formatted(clock)) to \(window.end.formatted(clock))"
        )
    }

    private func hourHelp(_ index: Int, count: Int) -> String {
        let hoursAgo = MailboxPanelMail.insightsHours - 1 - index
        if hoursAgo == 0 {
            return String(localized: "mailbox.insights.hour.current.help", defaultValue: "Past hour: \(count) received")
        }
        return String(
            localized: "mailbox.insights.hour.help",
            defaultValue: "\(hoursAgo + 1) to \(hoursAgo) hours ago: \(count) received"
        )
    }

    private func dayHelp(_ index: Int, count: Int) -> String {
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

    /// `layout` is the unfiltered ranking: a slice keeps its row count and its
    /// "more" row, padded with blank rows, so a click never moves what is below.
    private func rankingSection(
        title: String,
        ranking: MailboxPanelMail.Ranking,
        layout: MailboxPanelMail.Ranking,
        selected: String?,
        showUnread: Bool,
        detail: @escaping (MailboxPanelMail.Tally) -> String?,
        trailing: String? = nil,
        pick: @escaping (MailboxPanelMail.Tally) -> Void
    ) -> some View {
        let peak = max(ranking.top.first?.count ?? 0, 1)
        return VStack(alignment: .leading, spacing: 3) {
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
            // `ranking` pins a selected name, so its gold row stays visible.
            ForEach(ranking.top) { tally in
                MailboxInsightsRowButton(
                    selected: tally.name == selected || (tally.key != nil && tally.key == filter.recipient),
                    gold: gold,
                    help: String(localized: "mailbox.insights.row.help", defaultValue: "Show only \(tally.name)"),
                    action: { pick(tally) }
                ) {
                    rankingRow(
                        name: tally.name,
                        detail: detail(tally),
                        count: tally.count,
                        fraction: CGFloat(tally.count) / CGFloat(peak),
                        unread: showUnread ? tally.unread : nil
                    )
                }
            }
            ForEach(0..<max(0, layout.top.count - ranking.top.count), id: \.self) { _ in
                rankingRow(name: " ", detail: nil, count: 0, fraction: nil, unread: showUnread ? 0 : nil)
                    .padding(.vertical, 2)
                    .hidden()
            }
            if ranking.others > 0 || layout.others > 0 {
                rankingRow(
                    name: String(
                        localized: "mailbox.insights.others",
                        defaultValue: "\(max(0, ranking.distinct - ranking.top.count)) more"
                    ),
                    detail: nil,
                    count: ranking.others,
                    fraction: nil,
                    unread: showUnread ? 0 : nil,
                    muted: true
                )
                .padding(.vertical, 2)
                .opacity(ranking.others > 0 ? 1 : 0)
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

    // MARK: Messages

    private func messageList(_ slice: MailboxPanelMail.Slice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "mailbox.insights.messages.title", defaultValue: "Messages"))
                    .font(sectionFont)
                    .foregroundColor(style.foreground)
                Spacer(minLength: 8)
                Text(String(
                    localized: "mailbox.insights.messages.count",
                    defaultValue: "newest \(slice.messages.count) of \(slice.count)"
                ))
                .font(metaFont.monospacedDigit())
                .foregroundColor(style.secondary)
                .fixedSize()
            }
            .padding(.bottom, 4)
            Rectangle().fill(style.border).frame(height: 1)
            if slice.messages.isEmpty {
                metaLine(String(localized: "mailbox.insights.messages.empty", defaultValue: "No messages in this slice."))
                    .padding(.vertical, 8)
            }
            ForEach(slice.messages) { record in
                messageRow(record)
                Rectangle().fill(style.border).frame(height: 1)
            }
        }
    }

    private func messageRow(_ record: MailboxPanelMail.Record) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stateChip(
                    record.unread
                        ? String(localized: "mailbox.drawer.state.unread", defaultValue: "UNREAD")
                        : String(localized: "mailbox.drawer.state.read", defaultValue: "READ"),
                    filled: record.unread
                )
                if record.header.urgent {
                    Text(String(localized: "mailbox.drawer.chip.urgent", defaultValue: "urgent"))
                        .font(.system(size: 9 * style.scale, weight: .semibold))
                        .foregroundColor(orange)
                }
                Text(verbatim: record.header.topic ?? String(localized: "mailbox.drawer.noTopic", defaultValue: "(no topic)"))
                    .font(metaFont.weight(.semibold))
                    .foregroundColor(record.header.topic == nil ? style.secondary : style.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let date = record.date {
                    Text(MailboxDrawerText.age(of: date, now: now))
                        .font(metaFont.monospacedDigit())
                        .foregroundColor(style.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: 4) {
                Text(String(localized: "mailbox.drawer.from", defaultValue: "from"))
                    .foregroundColor(style.secondary)
                MailboxConversationNameButton(
                    name: record.header.from,
                    font: metaFont,
                    style: style,
                    action: { onOpenConversation(MailboxPanelMail.peerKey(of: record.header)) }
                )
                if let number = senders[record.header.from]?.panelNumber {
                    Text(String(localized: "mailbox.drawer.panelNumber", defaultValue: "panel \(number)"))
                        .foregroundColor(style.secondary)
                        .lineLimit(1)
                }
            }
            .font(metaFont)
            if !record.header.preview.isEmpty {
                Text(record.header.previewRich)
                    .font(metaFont)
                    .foregroundColor(style.foreground.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateChip(_ label: String, filled: Bool) -> some View {
        Text(label)
            .font(.system(size: 9 * style.scale, weight: .semibold))
            .foregroundColor(filled ? Color.black.opacity(0.85) : style.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(filled ? orange : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(filled ? Color.clear : style.border, lineWidth: 1))
    }

    // MARK: Sent drill-down

    @ViewBuilder
    private func sentDrill(key: String) -> some View {
        let slice = MailboxPanelMail.sentSlice(insights, recipient: key)
        HStack(spacing: 8) {
            tile(slice.sent, label: String(localized: "mailbox.insights.tile.sent", defaultValue: "SENT"),
                 help: String(localized: "mailbox.insights.sent.tile.sent.help", defaultValue: "Messages this panel sent to this recipient."))
            tile(slice.taken, label: String(localized: "mailbox.insights.tile.taken", defaultValue: "TAKEN"),
                 help: String(localized: "mailbox.insights.sent.tile.taken.help", defaultValue: "Copies the recipient has taken."))
            tile(slice.waiting, label: String(localized: "mailbox.insights.tile.waiting", defaultValue: "WAITING"),
                 help: String(localized: "mailbox.insights.sent.tile.waiting.help", defaultValue: "Copies still in the recipient's inbox."),
                 accent: slice.waiting > 0)
            tile(slice.gone, label: String(localized: "mailbox.drawer.sent.state.gone", defaultValue: "GONE"),
                 help: String(localized: "mailbox.drawer.sent.state.gone.help", defaultValue: "The recipient's copy is no longer there."))
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "mailbox.insights.messages.title", defaultValue: "Messages"))
                    .font(sectionFont)
                    .foregroundColor(style.foreground)
                Spacer(minLength: 8)
                Text(String(
                    localized: "mailbox.insights.messages.count",
                    defaultValue: "newest \(slice.messages.count) of \(slice.sent)"
                ))
                .font(metaFont.monospacedDigit())
                .foregroundColor(style.secondary)
                .fixedSize()
            }
            .padding(.bottom, 4)
            Rectangle().fill(style.border).frame(height: 1)
            if slice.messages.isEmpty {
                metaLine(String(localized: "mailbox.insights.messages.empty", defaultValue: "No messages in this slice."))
                    .padding(.vertical, 8)
            }
            ForEach(slice.messages) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    stateChip(sentStateLabel(item.state), filled: item.state == .unread)
                    Text(verbatim: item.record.topic ?? String(localized: "mailbox.drawer.noTopic", defaultValue: "(no topic)"))
                        .font(metaFont.weight(.semibold))
                        .foregroundColor(item.record.topic == nil ? style.secondary : style.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let date = item.record.sentAt {
                        Text(MailboxDrawerText.age(of: date, now: now))
                            .font(metaFont.monospacedDigit())
                            .foregroundColor(style.secondary)
                            .fixedSize()
                    }
                }
                .padding(.vertical, 6)
                Rectangle().fill(style.border).frame(height: 1)
            }
        }
        if insights.sentIsTrimmed { footnotes }
    }

    private func sentStateLabel(_ state: MailboxPanelMail.SentState) -> String {
        switch state {
        case .unread: return String(localized: "mailbox.drawer.state.unread", defaultValue: "UNREAD")
        case .read: return String(localized: "mailbox.drawer.state.read", defaultValue: "READ")
        case .gone: return String(localized: "mailbox.drawer.sent.state.gone", defaultValue: "GONE")
        }
    }

    // MARK: Pickup wait

    /// How long mail waited here before the agent took it, for the current
    /// received slice. Fixed shape: four tiles, one line, a five-step
    /// distribution, `pickupSenderCount` sender rows (padded), and notes
    /// whose presence does not change with the filter.
    private func pickupSection(_ pickup: MailboxPanelMail.Pickup) -> some View {
        let none = pickup.claims == 0
        let dash = "—"
        let days = MailboxPanelMail.insightsDays
        // Every row is reserved, so the first claims landing grow nothing.
        let layoutRows = MailboxPanelMail.pickupSenderCount
        let topMedian = max(pickup.senders.map(\.median).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "mailbox.insights.pickup.title", defaultValue: "Pickup wait"))
                    .font(sectionFont)
                    .foregroundColor(style.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(none
                    ? String(localized: "mailbox.insights.pickup.window.none", defaultValue: "no claims · last \(days) days")
                    : pickup.claims == 1
                    ? String(localized: "mailbox.insights.pickup.window.one", defaultValue: "1 claim · last \(days) days")
                    : String(localized: "mailbox.insights.pickup.window", defaultValue: "\(pickup.claims) claims · last \(days) days"))
                .font(metaFont.monospacedDigit())
                .foregroundColor(style.secondary)
                .lineLimit(1)
                .fixedSize()
            }
            HStack(spacing: 8) {
                tile(
                    text: pickup.median.map(MailboxDrawerText.wait) ?? dash,
                    label: String(localized: "mailbox.insights.pickup.median", defaultValue: "MEDIAN"),
                    help: String(localized: "mailbox.insights.pickup.median.help", defaultValue: "Half of the messages were taken faster than this.")
                )
                tile(
                    text: pickup.p90.map(MailboxDrawerText.wait) ?? dash,
                    label: String(localized: "mailbox.insights.pickup.p90", defaultValue: "P90"),
                    help: String(localized: "mailbox.insights.pickup.p90.help", defaultValue: "Nine in ten messages were taken faster than this.")
                )
                tile(
                    text: pickup.slowest.map(MailboxDrawerText.wait) ?? dash,
                    label: String(localized: "mailbox.insights.pickup.slowest", defaultValue: "SLOWEST"),
                    help: String(localized: "mailbox.insights.pickup.slowest.help", defaultValue: "The longest any message waited before it was taken.")
                )
                tile(
                    pickup.claims,
                    label: String(localized: "mailbox.insights.pickup.claims", defaultValue: "CLAIMS"),
                    help: String(localized: "mailbox.insights.pickup.claims.help", defaultValue: "Taken messages these figures cover: each one's claim is recorded in the last \(days) days.")
                )
            }
            metaLine(String(
                localized: "mailbox.insights.pickup.measure",
                defaultValue: "From landing in this inbox to the agent taking it (recv --ack or a hook drain)"
            ))
            pickupDistribution(pickup.buckets)
            ForEach(pickup.senders) { sender in
                pickupSenderRow(
                    name: sender.name,
                    median: MailboxDrawerText.wait(sender.median),
                    claims: sender.claims,
                    fraction: CGFloat(sender.median / topMedian)
                )
            }
            ForEach(0..<max(0, layoutRows - pickup.senders.count), id: \.self) { _ in
                pickupSenderRow(name: " ", median: "", claims: 0, fraction: nil).hidden()
            }
            pickupNotes(pickup)
        }
        .accessibilityElement(children: .contain)
    }

    private func pickupBucketLabel(_ index: Int) -> String {
        switch index {
        case 0: return String(localized: "mailbox.insights.pickup.bucket.underMinute", defaultValue: "under 1m")
        case 1: return String(localized: "mailbox.insights.pickup.bucket.minutes", defaultValue: "1–5m")
        case 2: return String(localized: "mailbox.insights.pickup.bucket.halfHour", defaultValue: "5–30m")
        case 3: return String(localized: "mailbox.insights.pickup.bucket.twoHours", defaultValue: "30m–2h")
        default: return String(localized: "mailbox.insights.pickup.bucket.overTwoHours", defaultValue: "over 2h")
        }
    }

    private func pickupDistribution(_ buckets: [Int]) -> some View {
        let peak = max(buckets.max() ?? 0, 1)
        return HStack(alignment: .top, spacing: 6) {
            ForEach(buckets.indices, id: \.self) { index in
                let value = buckets[index]
                let label = pickupBucketLabel(index)
                VStack(alignment: .leading, spacing: 2) {
                    Color.clear
                        .frame(height: pickupChartHeight)
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: value == 0 ? 0 : 2)
                                .fill(value == 0 ? trackColor : barColor)
                                .frame(height: value == 0 ? 1 : max(3, pickupChartHeight * CGFloat(value) / CGFloat(peak)))
                        }
                    Text(label)
                        .font(metaFont)
                        .foregroundColor(style.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: value.formatted())
                        .font(metaFont.monospacedDigit())
                        .foregroundColor(style.foreground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(String(localized: "mailbox.insights.pickup.bucket.help", defaultValue: "\(label): \(value) claims"))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func pickupSenderRow(name: String, median: String, claims: Int, fraction: CGFloat?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: name)
                .font(textFont)
                .foregroundColor(style.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: nameWidth, alignment: .leading)
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
            Text(verbatim: median)
                .font(metaFont.monospacedDigit())
                .foregroundColor(style.foreground)
                .lineLimit(1)
                .frame(width: countWidth, alignment: .trailing)
            Text(claims == 1
                ? String(localized: "mailbox.insights.pickup.sender.claimsOne", defaultValue: "1 claim")
                : String(localized: "mailbox.insights.pickup.sender.claims", defaultValue: "\(claims) claims"))
            .font(metaFont.monospacedDigit())
            .foregroundColor(style.secondary)
            .lineLimit(1)
            .frame(width: unreadWidth, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .help(String(localized: "mailbox.insights.pickup.sender.help", defaultValue: "Median wait of mail from \(name)"))
    }

    /// Says what the figures cannot see. Each note's presence follows the
    /// whole mailbox, not the filter, so a click never adds or drops a line.
    @ViewBuilder
    private func pickupNotes(_ pickup: MailboxPanelMail.Pickup) -> some View {
        let coverage = insights.claimLog
        let windowStart = insights.scannedAt.addingTimeInterval(-MailboxPanelMail.pickupWindow)
        if coverage.unreadable {
            wrappingNote(String(
                localized: "mailbox.insights.pickup.note.unreadable",
                defaultValue: "c11 could not read this workspace's mailbox log, so no pickup times are known."
            ))
        } else if !coverage.exists {
            wrappingNote(String(
                localized: "mailbox.insights.pickup.note.noLog",
                defaultValue: "This workspace has no mailbox log yet, so no pickup times are known."
            ))
        } else if let readFrom = coverage.readFrom, readFrom > windowStart {
            wrappingNote(String(
                localized: "mailbox.insights.pickup.note.readFrom",
                defaultValue: "The mailbox log was read back to \(MailboxDrawerText.stamp(readFrom)) only; claims before then are not counted."
            ))
        }
        if insights.pickup.unclaimed > 0 {
            wrappingNote(String(
                localized: "mailbox.insights.pickup.note.unclaimed",
                defaultValue: "Taken in the last \(MailboxPanelMail.insightsDays) days without a claim record: \(pickup.unclaimed). c11 records claims from version 1.7.5, so mail taken before that has no pickup time."
            ))
        }
        if insights.scanIsPartial {
            wrappingNote(String(
                localized: "mailbox.insights.pickup.note.sample",
                defaultValue: "Pickup waits cover only the newest \(insights.scanned + insights.unparsed) of \(insights.received) messages."
            ))
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 3) {
            if insights.received == 0 && insights.sent == 0 {
                metaLine(String(localized: "mailbox.drawer.empty", defaultValue: "No mail yet."))
            }
            if insights.unparsed > 0 {
                metaLine(String(
                    localized: "mailbox.insights.note.unparsed",
                    defaultValue: "Unreadable as envelopes: \(insights.unparsed)"
                ))
            }
            if insights.sentIsTrimmed {
                wrappingNote(String(
                    localized: "mailbox.insights.note.sentTrimmed",
                    defaultValue: "c11 keeps about the newest \(MailboxSentLedger.retain) sent records, so older sends may not be counted."
                ))
            }
        }
    }
}

/// A clickable Insights row: a light wash on hover, a gold outline when its
/// filter is on. Negative padding keeps the row aligned with plain rows.
private struct MailboxInsightsRowButton<Label: View>: View {
    let selected: Bool
    let gold: Color
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? gold : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Body links (C11-524)

/// Opens the links `MailboxBodyLinks` found in a body. A `c11://` link takes
/// the same path as a link in a Markdown panel, `AppDelegate.openPanelLink`,
/// so it lands, pulses and records Back history the same way; a dead or
/// malformed target reports the same `PanelLinkNotice`. `http` and `https`
/// open in the default browser. Nothing else is ever a link.
@MainActor
enum MailboxDrawerLinkOpener {
    static func open(
        _ url: URL,
        onPanelLinkOpened: () -> Void,
        showNotice: (PanelLinkNotice) -> Void
    ) -> OpenURLAction.Result {
        let href = url.absoluteString
        if PanelLinkTarget.usesScheme(url) {
            guard let target = PanelLinkTarget(href) else {
                showNotice(.invalid)
                PanelLinkActivation.log(target: href, origin: "mailbox_drawer", activation: "native_click", result: "invalid_target")
                return .handled
            }
            let opened = AppDelegate.shared?.openPanelLink(target) == true
            PanelLinkActivation.log(target: href, origin: "mailbox_drawer", activation: "native_click", result: opened ? "opened" : "unavailable")
            if opened { onPanelLinkOpened() } else { showNotice(.unavailable) }
            return .handled
        }
        guard MailboxBodyLinks.linkURL(href) != nil else { return .discarded }
        NSWorkspace.shared.open(url)
        return .handled
    }
}

/// The panel-link notice as the drawer shows it. The shared AppKit card lays
/// out with Auto Layout, which the drawer's intrinsic-size hosting view does
/// not run for foreign subviews, so the drawer draws the same card itself.
private struct MailboxLinkNoticeCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Color(nsColor: .labelColor))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .frame(maxWidth: 440, alignment: .leading)
            .accessibilityIdentifier("c11.panel-link.notice")
    }
}

// MARK: - Conversations

/// The Conversations tab's state. The drawer holds it, so the selection and
/// the open thread survive a look at another tab. Every load runs off the
/// main thread; a generation guard drops a result a newer request replaced,
/// and a request during a load marks it dirty so one reload follows.
final class MailboxConversationsModel: ObservableObject {
    @Published private(set) var index: MailboxPanelMail.ConversationIndex?
    @Published private(set) var thread: MailboxPanelMail.ConversationThread?
    @Published private(set) var selected: MailboxPanelMail.PeerKey?
    /// A narrow drawer shows the list or the open thread; a wide one, both.
    @Published var showsThread = false
    @Published private(set) var expanded: Set<String> = []
    /// The panels this tab names, by id: numbers, names, and whether open.
    @Published private(set) var panels: [UUID: MailboxDrawerSender] = [:]
    /// Where the open thread scrolls once it lands: its first unread
    /// message, else its end.
    @Published private(set) var placement: Placement?
    /// The message a reply chip just pointed at, outlined for a moment.
    @Published private(set) var flashed: String?
    /// The selected row's place in the list; when a rescan moves it, the
    /// list scrolls to keep it in view.
    @Published private(set) var selectedPosition: Int?

    struct Placement: Equatable {
        let key: MailboxPanelMail.PeerKey
        let target: String
        let token: Int
    }

    static let unreadAnchor = "conversation-unread"
    static let endAnchor = "conversation-end"
    /// Recipients take this panel's sends without moving its revision, so
    /// the tab rescans on its own while it shows. Scans start at least this
    /// far apart, however fast mail arrives.
    static let refreshInterval: TimeInterval = 5
    /// Open panels change rarely: a known set is resolved again this often.
    static let resolveInterval: TimeInterval = 15

    private var inbox: URL?
    private var resolvePanels: ([UUID]) -> [UUID: MailboxDrawerSender] = { _ in [:] }
    private var isShowing = false
    private var tickGeneration = 0
    private var indexGeneration = 0
    private var indexInFlight = false
    private var indexDirty = false
    private var lastScanAt = Date.distantPast
    private var scanScheduled = false
    private var threadGeneration = 0
    private var threadInFlight = false
    private var threadDirty = false
    private var placementToken = 0
    private var resolvedIds: Set<UUID> = []
    private var resolvedAt = Date.distantPast
    /// A conversation another tab asked to open. Only a scan that started
    /// after the jump resolves it, so the thread holds the very message that
    /// was clicked; until then no scan moves the selection off it.
    private(set) var pendingOpen: MailboxPanelMail.PeerKey?
    private var pendingAfter = 0
    /// A forced scan asked for while another ran: the follow-up is forced too.
    private var forceDirty = false
    /// A jump the newest scan does not hold (past the scan or gone). The
    /// thread pane says so instead of showing another peer; a click on a
    /// row clears it.
    @Published private(set) var missed: MailboxPanelMail.PeerKey?

    func appeared(inbox: URL?, resolvePanels: @escaping ([UUID]) -> [UUID: MailboxDrawerSender]) {
        self.inbox = inbox
        self.resolvePanels = resolvePanels
        isShowing = true
        // A jump from another tab waits for no throttle.
        refresh(force: pendingOpen != nil)
        scheduleTick()
    }

    /// Opens one peer's thread from elsewhere in the drawer (a sender or
    /// recipient name), as a click on its row would: selected, shown in a
    /// narrow drawer, and placed at its first unread message or its end.
    /// The key comes from the mail itself (the stamp, else the name-only
    /// row), never from a name. The caller then shows the tab, whose
    /// appearance scans when the list does not hold the key yet.
    func open(_ key: MailboxPanelMail.PeerKey) {
        showsThread = true
        missed = nil
        if key != selected || thread?.key != key {
            selected = key
            thread = nil
            flashed = nil
            updateSelectedPosition()
            // The list on hand shows the thread at once; the scan below
            // reads it again with whatever arrived since.
            if index?.conversation(key) != nil { reloadThread(place: true) }
        }
        pendingOpen = key
        pendingAfter = indexGeneration
        if isShowing { refresh(force: true) }
    }

    func disappeared() {
        isShowing = false
        tickGeneration += 1
    }

    private func scheduleTick() {
        tickGeneration += 1
        let generation = tickGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshInterval) { [weak self] in
            guard let self, self.isShowing, generation == self.tickGeneration else { return }
            self.refresh()
            self.scheduleTick()
        }
    }

    /// Rescans the list, then refreshes the open thread from it. `force`
    /// skips the spacing between scans, for a jump the list cannot serve yet.
    func refresh(force: Bool = false) {
        guard let inbox else {
            index = MailboxPanelMail.ConversationIndex()
            return
        }
        guard !indexInFlight else {
            indexDirty = true
            if force { forceDirty = true }
            return
        }
        let wait = Self.refreshInterval - Date().timeIntervalSince(lastScanAt)
        if wait > 0, !force {
            guard !scanScheduled else { return }
            scanScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.scanScheduled = false
                if self.isShowing { self.refresh() }
            }
            return
        }
        lastScanAt = Date()
        indexInFlight = true
        indexGeneration += 1
        let generation = indexGeneration
        let root = inbox.deletingLastPathComponent()
        // The first load and a jump are what the reader waits for;
        // refreshes are background.
        let qos: DispatchQoS.QoSClass = index == nil || force ? .userInitiated : .utility
        DispatchQueue.global(qos: qos).async { [weak self] in
            let loaded = autoreleasepool {
                MailboxPanelMail.conversationIndex(inbox: inbox, mailboxesRoot: root)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexInFlight = false
                if generation == self.indexGeneration { self.apply(loaded, generation: generation) }
                if self.indexDirty {
                    let force = self.forceDirty
                    self.indexDirty = false
                    self.forceDirty = false
                    self.refresh(force: force)
                }
            }
        }
    }

    private func apply(_ loaded: MailboxPanelMail.ConversationIndex, generation: Int) {
        if loaded != index { index = loaded }
        resolve()
        defer { updateSelectedPosition() }
        if let pending = pendingOpen {
            // A scan from before the jump neither resolves it nor moves the
            // selection; the forced scan after it does.
            guard generation > pendingAfter else { return }
            pendingOpen = nil
            if loaded.conversation(pending) != nil {
                selected = pending
                reloadThread(place: true)
            } else {
                selected = nil
                thread = nil
                missed = pending
            }
            return
        }
        if let selected, loaded.conversation(selected) != nil {
            reloadThread(place: false)
        } else if missed != nil {
            // Nothing is selected after a missed jump until a row is clicked.
        } else if let first = loaded.conversations.first {
            // A wide drawer opens on the newest conversation; a narrow one
            // on the list, with that thread ready behind it.
            selected = first.key
            thread = nil
            showsThread = false
            reloadThread(place: true)
        } else {
            selected = nil
            thread = nil
            showsThread = false
        }
    }

    func select(_ key: MailboxPanelMail.PeerKey) {
        showsThread = true
        missed = nil
        guard key != selected else { return }
        selected = key
        thread = nil
        flashed = nil
        updateSelectedPosition()
        reloadThread(place: true)
    }

    private func updateSelectedPosition() {
        let position = selected.flatMap { key in index?.conversations.firstIndex(where: { $0.key == key }) }
        if position != selectedPosition { selectedPosition = position }
    }

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func flash(_ id: String) {
        flashed = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.flashed == id { self?.flashed = nil }
        }
    }

    private func reloadThread(place: Bool) {
        guard let inbox, let index, let selected, let conversation = index.conversation(selected) else { return }
        // A refresh waits for the load in flight; a new selection never does.
        if !place, threadInFlight {
            threadDirty = true
            return
        }
        threadInFlight = true
        threadGeneration += 1
        let generation = threadGeneration
        let root = inbox.deletingLastPathComponent()
        let floor = index.ledgerFloor
        // A refresh of the open thread first compares signatures (which
        // messages, and every state), from stats and cached headers, and
        // reads no envelope when nothing changed.
        let known = place || thread?.key != selected ? nil : thread?.signature
        DispatchQueue.global(qos: place ? .userInitiated : .utility).async { [weak self] in
            let loaded = autoreleasepool { () -> MailboxPanelMail.ConversationThread? in
                if let known,
                   MailboxPanelMail.threadSignature(conversation, inbox: inbox, mailboxesRoot: root, ledgerFloor: floor) == known {
                    return nil
                }
                return MailboxPanelMail.thread(conversation, inbox: inbox, mailboxesRoot: root, ledgerFloor: floor)
            }
            DispatchQueue.main.async {
                guard let self, generation == self.threadGeneration else { return }
                self.threadInFlight = false
                if let loaded, loaded.key == self.selected {
                    // A thread landing for a peer that had none on screen is
                    // placed like a click, whichever load brought it.
                    let isNew = self.thread?.key != loaded.key
                    // Signatures, not a walk of every message on main.
                    if loaded.signature != self.thread?.signature { self.thread = loaded }
                    self.resolve()
                    if place || isNew {
                        self.placementToken += 1
                        self.placement = Placement(
                            key: loaded.key,
                            target: loaded.firstUnreadId == nil ? Self.endAnchor : Self.unreadAnchor,
                            token: self.placementToken
                        )
                    }
                }
                if self.threadDirty {
                    self.threadDirty = false
                    self.reloadThread(place: false)
                }
            }
        }
    }

    /// Resolves the list's panels and the open thread's recipients when that
    /// set grows, and every `resolveInterval` so closed panels dim.
    private func resolve() {
        var ids = Set(index?.conversations.compactMap(\.key.panelId) ?? [])
        for item in thread?.items ?? [] {
            for recipient in item.recipients { if let id = recipient.panelId { ids.insert(id) } }
        }
        guard !ids.isSubset(of: resolvedIds) || Date().timeIntervalSince(resolvedAt) >= Self.resolveInterval else { return }
        let resolved = resolvePanels(Array(ids))
        resolvedIds = ids
        resolvedAt = Date()
        if resolved != panels { panels = resolved }
    }
}

/// Strings the Conversations tab shares with the drawer header.
enum MailboxConversationsText {
    static func headerCounts(conversations: Int, unread: Int) -> String {
        conversations == 1
            ? String(
                localized: "mailbox.conversations.header.countsOne",
                defaultValue: "1 conversation · \(unread) unread"
            )
            : String(
                localized: "mailbox.conversations.header.counts",
                defaultValue: "\(conversations) conversations · \(unread) unread"
            )
    }

    /// Today's time, a weekday within six days, else a date.
    static func listTime(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if now.timeIntervalSince(date) < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// A day separator in local time.
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let text = dayText(date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "mailbox.conversations.day.today", defaultValue: "Today · \(text)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "mailbox.conversations.day.yesterday", defaultValue: "Yesterday · \(text)")
        }
        return text
    }
}

/// The Conversations tab: this panel's mail with one peer, both directions,
/// in time order. Read-only like the rest of the drawer. Two panes when the
/// drawer is wide, the list then the thread when it is narrow; both a fixed
/// height, so opening another thread never resizes the drawer. Every name,
/// topic and body is untrusted text from another agent and renders verbatim.
private struct MailboxConversationsView: View {
    @ObservedObject var model: MailboxConversationsModel
    let inboxURL: URL?
    let revision: Int
    /// What the thread calls this panel: its address, else its title.
    let thisName: String
    let width: CGFloat
    let height: CGFloat
    let style: MailboxDrawerStyle
    let bodyFont: Font
    let metaFont: Font
    let textFont: Font
    let resolvePanels: ([UUID]) -> [UUID: MailboxDrawerSender]

    /// The prototype's breakpoints, against the drawer's width.
    static let narrowBelow: CGFloat = 500
    static let wideListFrom: CGFloat = 900
    static let fullFooterFrom: CGFloat = 700

    private var scale: CGFloat { style.scale }
    private var isNarrow: Bool { width < Self.narrowBelow }
    private var listWidth: CGFloat { (width >= Self.wideListFrom ? 280 : 220) * scale }
    private var footerHeight: CGFloat { 26 * scale }
    private var paneHeight: CGFloat { max(0, height - footerHeight - 1) }
    private var threadWidth: CGFloat { isNarrow ? width : max(0, width - listWidth - 1) }
    private var orange: Color { Color(nsColor: .systemOrange) }
    private var link: Color { Color(nsColor: .linkColor) }

    /// Who one side of a conversation is, as the list and thread name it.
    struct Peer {
        let name: String
        let number: Int?
        let isOpen: Bool
        let isNameOnly: Bool
    }

    var body: some View {
        // One container, so loading giving way to the list is not an
        // appearance: the refresh loop runs exactly while the tab shows.
        VStack(alignment: .leading, spacing: 0) { content }
            .onAppear { model.appeared(inbox: inboxURL, resolvePanels: resolvePanels) }
            .onDisappear { model.disappeared() }
            .onChange(of: revision) { _ in model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if let index = model.index {
            if index.conversations.isEmpty {
                Text(String(localized: "mailbox.conversations.empty", defaultValue: "No conversations yet."))
                    .font(textFont)
                    .foregroundColor(style.secondary)
                    .padding(12)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    VStack(spacing: 0) {
                        panes(index, now: timeline.date)
                            .frame(width: width, height: paneHeight, alignment: .topLeading)
                            .clipped()
                        Rectangle().fill(style.border).frame(height: 1)
                        footer
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }
        } else {
            // The loaded view's height, so the first scan landing moves nothing.
            Text(String(localized: "mailbox.drawer.loading", defaultValue: "Reading mail…"))
                .font(textFont)
                .foregroundColor(style.secondary)
                .padding(12)
                .frame(width: width, height: height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func panes(_ index: MailboxPanelMail.ConversationIndex, now: Date) -> some View {
        let conversation = model.selected.flatMap { index.conversation($0) }
        if isNarrow {
            // A jump whose thread is not in the list yet keeps the list showing.
            let showingThread = model.showsThread && conversation != nil
            let showingMissed = model.showsThread && conversation == nil && model.missed != nil
            let covered = showingThread || showingMissed
            ZStack(alignment: .topLeading) {
                // Kept underneath, so going back finds the list where it was.
                listPane(index, now: now)
                    .opacity(covered ? 0 : 1)
                    .allowsHitTesting(!covered)
                    .accessibilityHidden(covered)
                if showingThread, let conversation {
                    threadPane(conversation, index: index, now: now)
                        .background(Color(nsColor: style.background))
                } else if showingMissed {
                    missedPane
                        .background(Color(nsColor: style.background))
                }
            }
        } else {
            HStack(spacing: 0) {
                listPane(index, now: now)
                    .frame(width: listWidth)
                Rectangle().fill(style.border).frame(width: 1)
                if let conversation {
                    threadPane(conversation, index: index, now: now)
                        .frame(width: threadWidth)
                } else if model.missed != nil {
                    missedPane.frame(width: threadWidth)
                } else {
                    Color.clear.frame(width: threadWidth)
                }
            }
        }
    }

    /// Where a jump lands when the list does not hold its conversation: the
    /// pane says so, and no other peer's thread stands in for it.
    private var missedPane: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            if isNarrow {
                Button { model.showsThread = false } label: {
                    Text(String(localized: "mailbox.conversations.back", defaultValue: "‹ All"))
                        .font(metaFont)
                        .foregroundColor(link)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(Text(String(localized: "mailbox.conversations.back.accessibility", defaultValue: "Back to all conversations")))
            }
            Text(String(
                localized: "mailbox.conversations.missed",
                defaultValue: "That conversation is not in the list. Conversations reads only this panel's newest \(MailboxPanelMail.insightsScanLimit) received messages and its sends since then."
            ))
            .font(metaFont)
            .foregroundColor(style.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("mailbox-conversation-missed")
        }
        .padding(12 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        let detail: String
        if isNarrow {
            detail = String(localized: "mailbox.conversations.footer.short", defaultValue: "Never sends, claims or deletes mail.")
        } else if width < Self.fullFooterFrom {
            detail = String(localized: "mailbox.conversations.footer.medium", defaultValue: "The drawer never sends, claims or deletes mail.")
        } else {
            detail = String(
                localized: "mailbox.conversations.footer.long",
                defaultValue: "The drawer never sends, claims or deletes mail. Agents reply with c11 mailbox send."
            )
        }
        return (
            Text(String(localized: "mailbox.conversations.footer.readOnly", defaultValue: "Read-only."))
                .fontWeight(.semibold)
                .foregroundColor(style.foreground)
            + Text(verbatim: " " + detail)
        )
        .font(metaFont)
        .foregroundColor(style.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 12 * scale)
        .frame(width: width, height: footerHeight, alignment: .leading)
    }

    // MARK: Peers

    func peer(_ conversation: MailboxPanelMail.Conversation) -> Peer {
        switch conversation.key {
        case .name(let name):
            return Peer(name: name, number: nil, isOpen: false, isNameOnly: true)
        case .panel(let id):
            let resolved = model.panels[id]
            let live = resolved?.isOpen == true ? (resolved?.address ?? resolved?.title) : nil
            let name = live ?? (conversation.label.isEmpty ? nil : conversation.label) ?? String(id.uuidString.lowercased().prefix(8))
            return Peer(name: name, number: resolved?.panelNumber, isOpen: resolved?.isOpen == true, isNameOnly: false)
        }
    }

    private func recipientName(_ recipient: MailboxPanelMail.SentRecipient) -> String {
        if let id = recipient.panelId, let resolved = model.panels[id], resolved.isOpen,
           let name = resolved.address ?? resolved.title {
            return name
        }
        if !recipient.name.isEmpty { return recipient.name }
        return recipient.panelId.map { String($0.uuidString.lowercased().prefix(8)) } ?? "?"
    }

    // MARK: List

    private func listPane(_ index: MailboxPanelMail.ConversationIndex, now: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(index.conversations) { conversation in
                            row(conversation, now: now)
                        }
                        if index.scanIsPartial {
                            Text(String(
                                localized: "mailbox.conversations.note.partial",
                                defaultValue: "Conversations cover the newest \(index.scanned + index.unparsed) of \(index.received) received messages."
                            ))
                            .font(metaFont.monospacedDigit())
                            .foregroundColor(style.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10 * scale)
                        }
                    } header: {
                        listHeader(index)
                    }
                }
            }
            // A rescan that re-sorts the list scrolls only as far as it takes to
            // keep the selected row in view.
            .onChange(of: model.selectedPosition) { _ in
                guard let selected = model.selected else { return }
                proxy.scrollTo(selected.id, anchor: nil)
            }
        }
    }

    private func listHeader(_ index: MailboxPanelMail.ConversationIndex) -> some View {
        let count = index.conversations.count
        return HStack(spacing: 8) {
            Text(count == 1
                ? String(localized: "mailbox.conversations.list.countOne", defaultValue: "1 conversation")
                : String(localized: "mailbox.conversations.list.count", defaultValue: "\(count) conversations"))
            Spacer(minLength: 8)
            Text(String(localized: "mailbox.insights.unreadCount", defaultValue: "\(index.unread) unread"))
        }
        .font(metaFont.monospacedDigit())
        .foregroundColor(style.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10 * scale)
        .frame(height: 26 * scale)
        .background(Color(nsColor: style.background))
        .overlay(alignment: .bottom) { Rectangle().fill(style.border).frame(height: 1) }
    }

    private func row(_ conversation: MailboxPanelMail.Conversation, now: Date) -> some View {
        let peer = self.peer(conversation)
        let status = statusLine(conversation, peer: peer, now: now)
        let numberText: String
        let numberHelp: String
        if peer.isNameOnly {
            numberText = "?"
            numberHelp = String(localized: "mailbox.conversations.number.nameOnly", defaultValue: "No panel: matched by name only")
        } else if let number = peer.number {
            numberText = String(number)
            numberHelp = String(localized: "mailbox.conversations.number.panel", defaultValue: "Panel \(number)")
        } else {
            numberText = "–"
            numberHelp = String(localized: "mailbox.conversations.number.unknown", defaultValue: "This panel is not open, and its number is not known")
        }
        return MailboxConversationRow(
            name: peer.name,
            numberText: numberText,
            numberIsPanel: !peer.isNameOnly && peer.number != nil,
            numberHelp: numberHelp,
            isAway: peer.isNameOnly || !peer.isOpen,
            isSelected: model.selected == conversation.key,
            unread: conversation.unread,
            time: MailboxConversationsText.listTime(conversation.lastAt, now: now),
            direction: conversation.lastDirection,
            preview: previewText(conversation.lastPreview),
            status: status.text,
            statusHelp: status.help,
            accessibility: String(
                localized: "mailbox.conversations.row.accessibility",
                defaultValue: "Conversation with \(peer.name), \(conversation.unread) unread"
            ),
            style: style,
            metaFont: metaFont,
            textFont: textFont,
            action: { model.select(conversation.key) }
        )
    }

    private func previewText(_ preview: MailboxPanelMail.Preview) -> String {
        switch preview {
        case .text(let text): return text
        case .file(let name): return String(localized: "mailbox.conversations.preview.file", defaultValue: "file \(name)")
        case .copyGone: return String(localized: "mailbox.conversations.preview.copyGone", defaultValue: "(copy gone)")
        case .empty: return String(localized: "mailbox.conversations.preview.empty", defaultValue: "(no body)")
        }
    }

    /// Line 3 of a row: the state of this panel's last send, then where the
    /// peer stands.
    private func statusLine(_ conversation: MailboxPanelMail.Conversation, peer: Peer, now: Date) -> (text: Text, help: String) {
        if peer.isNameOnly {
            return (
                Text(String(localized: "mailbox.conversations.status.nameOnly", defaultValue: "name only")),
                String(localized: "mailbox.conversations.status.nameOnly.help", defaultValue: "Matched by name only, so there is no panel to send to")
            )
        }
        let tail = peer.isOpen
            ? Text(verbatim: "")
            : Text(verbatim: " · " + String(localized: "mailbox.drawer.sender.notOpen", defaultValue: "not open"))
        guard let state = conversation.lastSendState else {
            return (
                Text(String(localized: "mailbox.conversations.status.nothingSent", defaultValue: "nothing sent")) + tail,
                String(localized: "mailbox.conversations.status.nothingSent.help", defaultValue: "\(thisName) has sent nothing to \(peer.name)")
            )
        }
        let ago = conversation.lastSendAt.map { MailboxDrawerText.span(now.timeIntervalSince($0)) } ?? "?"
        switch state {
        case .read:
            return (
                Text(String(localized: "mailbox.conversations.status.taken", defaultValue: "sent · taken")) + tail,
                String(localized: "mailbox.conversations.status.taken.help", defaultValue: "\(thisName)'s last send to \(peer.name), \(ago) ago: taken")
            )
        case .unread:
            return (
                Text(String(localized: "mailbox.conversations.status.sent", defaultValue: "sent ·")) + Text(verbatim: " ")
                    + Text(String(localized: "mailbox.conversations.status.waiting", defaultValue: "waiting \(ago)")).foregroundColor(orange)
                    + tail,
                peer.isOpen
                    ? String(localized: "mailbox.conversations.status.waiting.help", defaultValue: "\(thisName)'s last send to \(peer.name), \(ago) ago: not taken yet")
                    : String(localized: "mailbox.conversations.status.waitingClosed.help", defaultValue: "\(thisName)'s last send to \(peer.name), \(ago) ago: not taken yet; the panel is not open")
            )
        case .gone:
            return (
                Text(String(localized: "mailbox.conversations.status.gone", defaultValue: "sent · copy gone")) + tail,
                String(localized: "mailbox.conversations.status.gone.help", defaultValue: "\(thisName)'s last send to \(peer.name), \(ago) ago: the copy is no longer on disk")
            )
        }
    }

    // MARK: Thread

    private enum ThreadRow: Identifiable {
        case marker(id: String, text: String, edge: Bool)
        case day(id: String, text: String)
        case unread(text: String)
        case item(MailboxPanelMail.ThreadItem)

        var id: String {
            switch self {
            case .marker(let id, _, _), .day(let id, _): return id
            case .unread: return MailboxConversationsModel.unreadAnchor
            case .item(let item): return item.id
            }
        }
    }

    private func threadPane(
        _ conversation: MailboxPanelMail.Conversation,
        index: MailboxPanelMail.ConversationIndex,
        now: Date
    ) -> some View {
        let peer = self.peer(conversation)
        let thread = model.thread?.key == conversation.key ? model.thread : nil
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                threadHeader(conversation, peer: peer, thread: thread, proxy: proxy)
                Rectangle().fill(style.border).frame(height: 1)
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let thread {
                            ForEach(rows(thread, index: index, peer: peer, now: now)) { row in
                                rowView(row, peer: peer, conversation: conversation, proxy: proxy, now: now)
                            }
                        } else {
                            Text(String(localized: "mailbox.drawer.loading", defaultValue: "Reading mail…"))
                                .font(textFont)
                                .foregroundColor(style.secondary)
                                .padding(.vertical, 8 * scale)
                        }
                        Color.clear.frame(height: 1).id(MailboxConversationsModel.endAnchor)
                    }
                    .padding(.horizontal, 12 * scale)
                    .padding(.top, 4 * scale)
                    .padding(.bottom, 14 * scale)
                }
                .id(conversation.key)
            }
            .onAppear { place(proxy, key: conversation.key) }
            .onChange(of: model.placement) { _ in place(proxy, key: conversation.key) }
        }
    }

    /// Scrolls a thread that just opened to its first unread message, else its end.
    private func place(_ proxy: ScrollViewProxy, key: MailboxPanelMail.PeerKey) {
        guard let placement = model.placement, placement.key == key else { return }
        let anchor: UnitPoint = placement.target == MailboxConversationsModel.endAnchor ? .bottom : .top
        // After this layout pass, and once more as the lazy rows settle.
        DispatchQueue.main.async { proxy.scrollTo(placement.target, anchor: anchor) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(placement.target, anchor: anchor) }
    }

    private func threadHeader(
        _ conversation: MailboxPanelMail.Conversation,
        peer: Peer,
        thread: MailboxPanelMail.ConversationThread?,
        proxy: ScrollViewProxy
    ) -> some View {
        let unread = thread?.unread ?? conversation.unread
        let canJump = thread?.firstUnreadId != nil
        let total = thread?.total ?? conversation.count
        let received = thread?.received ?? conversation.received
        let sent = thread?.sent ?? conversation.sent
        return VStack(alignment: .leading, spacing: 1 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                if isNarrow {
                    Button { model.showsThread = false } label: {
                        Text(String(localized: "mailbox.conversations.back", defaultValue: "‹ All"))
                            .font(metaFont)
                            .foregroundColor(link)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel(Text(String(localized: "mailbox.conversations.back.accessibility", defaultValue: "Back to all conversations")))
                }
                Text(verbatim: peer.name)
                    .font(textFont.weight(.semibold))
                    .foregroundColor(style.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if peer.isNameOnly {
                    MailboxConversationChip(
                        label: String(localized: "mailbox.conversations.nameOnly", defaultValue: "NAME ONLY"),
                        kind: .plain,
                        help: String(localized: "mailbox.conversations.status.nameOnly.help", defaultValue: "Matched by name only, so there is no panel to send to"),
                        style: style
                    )
                } else {
                    Text(verbatim: whereText(peer))
                        .font(metaFont)
                        .foregroundColor(style.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 8 * scale)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(MailboxConversationsModel.unreadAnchor, anchor: .top)
                    }
                } label: {
                    Text(String(localized: "mailbox.conversations.jump", defaultValue: "\(unread) unread ↓"))
                        .font(metaFont.monospacedDigit())
                        .foregroundColor(orange)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(String(localized: "mailbox.conversations.jump.help", defaultValue: "Show the first unread message"))
                .opacity(canJump ? 1 : 0)
                .disabled(!canJump)
                .accessibilityHidden(!canJump)
            }
            .frame(height: 19 * scale)
            HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                Text(verbatim: howText(conversation))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8 * scale)
                Text(total == 1
                    ? String(localized: "mailbox.conversations.thread.countsOne", defaultValue: "1 message · \(received) in · \(sent) out")
                    : String(localized: "mailbox.conversations.thread.counts", defaultValue: "\(total) messages · \(received) in · \(sent) out"))
                .lineLimit(1)
                .fixedSize()
            }
            .font(metaFont.monospacedDigit())
            .foregroundColor(style.secondary)
            .frame(height: 16 * scale)
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 5 * scale)
        .frame(height: 46 * scale, alignment: .top)
    }

    private func whereText(_ peer: Peer) -> String {
        let state = peer.isOpen
            ? String(localized: "mailbox.conversations.open", defaultValue: "open")
            : String(localized: "mailbox.drawer.sender.notOpen", defaultValue: "not open")
        guard let number = peer.number else { return state }
        return String(localized: "mailbox.drawer.panelNumber", defaultValue: "panel \(number)") + " · " + state
    }

    private func howText(_ conversation: MailboxPanelMail.Conversation) -> String {
        switch conversation.key {
        case .name:
            return String(localized: "mailbox.conversations.how.name", defaultValue: "no sender stamp: keyed by the name in from")
        case .panel(let id):
            let short = String(id.uuidString.lowercased().prefix(8))
            return conversation.received > 0
                ? String(localized: "mailbox.conversations.how.stamp", defaultValue: "keyed by sender stamp \(short)")
                : String(localized: "mailbox.conversations.how.recipient", defaultValue: "keyed by recipient panel \(short)")
        }
    }

    private func rows(
        _ thread: MailboxPanelMail.ConversationThread,
        index: MailboxPanelMail.ConversationIndex,
        peer: Peer,
        now: Date
    ) -> [ThreadRow] {
        var rows: [ThreadRow] = []
        if peer.isNameOnly {
            rows.append(.marker(id: "marker-name", text: String(
                localized: "mailbox.conversations.marker.nameOnly",
                defaultValue: "These messages carry no sender stamp, so c11 keys them by the name \(peer.name). It cannot tell which panel, if any, sent them, and never merges them into a panel's conversation. A script that writes envelopes directly looks like this."
            ), edge: true))
        }
        // Past the scan, older mail either way is unknown: this is not the start.
        if let scanFloor = index.scanFloor {
            rows.append(.marker(id: "marker-scan", text: String(
                localized: "mailbox.conversations.marker.scanFloor",
                defaultValue: "Conversations read only this panel's newest \(index.scanned + index.unparsed) received messages, back to \(MailboxConversationsText.dayText(scanFloor)), \(MailboxConversationsText.clock(scanFloor)). Anything older with \(peer.name), sent or received, is not shown."
            ), edge: true))
        }
        if thread.hiddenCount > 0 {
            rows.append(.marker(id: "marker-hidden", text: peer.isNameOnly
                ? String(localized: "mailbox.conversations.marker.hidden", defaultValue: "\(thread.hiddenCount) older messages are not shown.")
                : String(
                    localized: "mailbox.conversations.marker.hiddenSides",
                    defaultValue: "\(thread.hiddenCount) older messages are not shown · \(peer.name) left, \(thisName) right"
                ), edge: false))
        } else if !peer.isNameOnly && index.scanFloor == nil {
            rows.append(.marker(id: "marker-start", text: String(
                localized: "mailbox.conversations.marker.start",
                defaultValue: "Start of the record · \(peer.name) left, \(thisName) right"
            ), edge: false))
        }
        let floorMarker: ThreadRow? = thread.showsLedgerFloor ? thread.ledgerFloor.map { floor in
            ThreadRow.marker(id: "marker-floor", text: String(
                localized: "mailbox.conversations.marker.ledgerFloor",
                defaultValue: "This panel's sent record starts \(MailboxConversationsText.dayText(floor)), \(MailboxConversationsText.clock(floor)). Anything \(thisName) sent \(peer.name) before then is not recorded, so only \(peer.name)'s side shows above."
            ), edge: true)
        } : nil
        let calendar = Calendar.current
        let unreadShown = thread.items.filter { $0.direction == .received && $0.state == .unread }.count
        var day: Date?
        for item in thread.items {
            if let floorMarker, item.id == thread.ledgerFloorItemId { rows.append(floorMarker) }
            if let date = item.date, day.map({ !calendar.isDate($0, inSameDayAs: date) }) ?? true {
                day = date
                rows.append(.day(id: "day-" + item.id, text: MailboxConversationsText.dayLabel(date, now: now, calendar: calendar)))
            }
            if item.id == thread.firstUnreadId {
                rows.append(.unread(text: unreadShown == 1
                    ? String(localized: "mailbox.conversations.unreadDivider.one", defaultValue: "1 unread: \(thisName) has not taken it yet")
                    : String(localized: "mailbox.conversations.unreadDivider", defaultValue: "\(unreadShown) unread: \(thisName) has not taken these yet")))
            }
            rows.append(.item(item))
        }
        if let floorMarker, thread.ledgerFloorItemId == nil { rows.append(floorMarker) }
        return rows
    }

    @ViewBuilder
    private func rowView(
        _ row: ThreadRow,
        peer: Peer,
        conversation: MailboxPanelMail.Conversation,
        proxy: ScrollViewProxy,
        now: Date
    ) -> some View {
        switch row {
        case .marker(_, let text, let edge):
            if edge {
                Text(verbatim: text)
                    .font(metaFont)
                    .foregroundColor(style.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8 * scale)
                    .padding(.vertical, 5 * scale)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(style.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .padding(.top, 10 * scale)
                    .padding(.bottom, 4 * scale)
            } else {
                Text(verbatim: text)
                    .font(metaFont)
                    .foregroundColor(style.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8 * scale)
                    .padding(.bottom, 2 * scale)
            }
        case .day(_, let text):
            separator(text, color: style.secondary, line: style.border, weight: .semibold)
        case .unread(let text):
            separator(text, color: orange, line: orange.opacity(0.5), weight: .regular)
        case .item(let item):
            let inner = max(0, threadWidth - 24 * scale)
            let maxWidth = inner * 0.86
            MailboxConversationBubble(
                item: item,
                peerName: peer.name,
                thisName: thisName,
                recipientNames: item.recipients.map(recipientName),
                peerPanel: conversation.key.panelId,
                isExpanded: model.expanded.contains(item.id),
                isFlashing: model.flashed == item.id,
                now: now,
                minWidth: min(250 * scale, maxWidth),
                maxWidth: maxWidth,
                style: style,
                bodyFont: bodyFont,
                metaFont: metaFont,
                onToggleExpanded: { model.toggleExpanded(item.id) },
                onShowParent: { id in
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.33)) }
                    model.flash(id)
                }
            )
        }
    }

    private func separator(_ text: String, color: Color, line: Color, weight: Font.Weight) -> some View {
        HStack(spacing: 8 * scale) {
            Rectangle().fill(line).frame(height: 1)
            Text(verbatim: text)
                .font(.system(size: 10 * scale, weight: weight, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize()
            Rectangle().fill(line).frame(height: 1)
        }
        .padding(.top, 12 * scale)
        .padding(.bottom, 4 * scale)
    }
}

/// One conversation in the list: three fixed lines, so counts can change
/// without the list moving.
private struct MailboxConversationRow: View {
    let name: String
    let numberText: String
    let numberIsPanel: Bool
    let numberHelp: String
    let isAway: Bool
    let isSelected: Bool
    let unread: Int
    let time: String
    let direction: MailboxPanelMail.Direction?
    let preview: String
    let status: Text
    let statusHelp: String
    let accessibility: String
    let style: MailboxDrawerStyle
    let metaFont: Font
    let textFont: Font
    let action: () -> Void

    @State private var hovering = false

    private var scale: CGFloat { style.scale }
    private var monoFont: Font { .system(size: 11 * scale, design: .monospaced) }
    private var numberWidth: CGFloat { 22 * scale }
    private var faint: Color { style.secondary.opacity(0.6) }
    private var orange: Color { Color(nsColor: .systemOrange) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    Text(verbatim: numberText)
                        .font(monoFont.monospacedDigit())
                        .foregroundColor(numberIsPanel ? BrandColors.goldSwiftUI : faint)
                        .lineLimit(1)
                        .frame(width: numberWidth, alignment: .leading)
                        .help(numberHelp)
                    Text(verbatim: name)
                        .font(textFont.weight(.semibold))
                        .foregroundColor(isAway ? style.secondary : style.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6 * scale)
                    Text(verbatim: time)
                        .font(metaFont.monospacedDigit())
                        .foregroundColor(style.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(height: 17 * scale)
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    Text(verbatim: direction == .sent ? "→" : "←")
                        .font(monoFont)
                        .foregroundColor(faint)
                        .frame(width: numberWidth, alignment: .leading)
                    Text(verbatim: preview)
                        .font(monoFont)
                        .foregroundColor(unread > 0 ? style.foreground : style.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(height: 16 * scale)
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    status
                        .font(metaFont)
                        .foregroundColor(style.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(statusHelp)
                    Spacer(minLength: 6 * scale)
                    Text(unread > 0
                        ? String(localized: "mailbox.insights.unreadCount", defaultValue: "\(unread) unread")
                        : "")
                    .font(metaFont.weight(.semibold).monospacedDigit())
                    .foregroundColor(Color.black.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, unread > 0 ? 4 : 0)
                    .background(RoundedRectangle(cornerRadius: 3).fill(unread > 0 ? orange : Color.clear))
                    .fixedSize()
                    .frame(minWidth: 56 * scale, alignment: .trailing)
                }
                .padding(.leading, numberWidth + 6 * scale)
                .frame(height: 16 * scale)
            }
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 62 * scale, alignment: .topLeading)
            .background(isSelected ? Color.black.opacity(0.18) : Color.primary.opacity(hovering ? 0.08 : 0))
            .overlay(Rectangle().inset(by: 0.5).stroke(isSelected ? BrandColors.goldSwiftUI : Color.clear, lineWidth: 1))
            .overlay(alignment: .bottom) { Rectangle().fill(style.border).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A small label with a border: a state, or a fact about a message.
private struct MailboxConversationChip: View {
    enum Kind { case plain, filled, waiting, gone }

    let label: String
    let kind: Kind
    let help: String
    let style: MailboxDrawerStyle

    private var orange: Color { Color(nsColor: .systemOrange) }

    var body: some View {
        Text(label)
            .font(.system(size: 9 * style.scale, weight: .semibold))
            .foregroundColor(kind == .filled ? Color.black.opacity(0.85) : (kind == .waiting ? orange : style.secondary))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(kind == .filled ? orange : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 3).stroke(
                    kind == .filled ? Color.clear : style.border,
                    style: StrokeStyle(lineWidth: 1, dash: kind == .gone ? [2, 2] : [])
                )
            )
            .fixedSize()
            .help(help)
    }
}

/// One message in a thread: the peer's on the left, this panel's on the
/// right. A bubble is as wide as its widest line, between `minWidth` and
/// `maxWidth`. Text is untrusted and renders verbatim.
private struct MailboxConversationBubble: View {
    let item: MailboxPanelMail.ThreadItem
    let peerName: String
    let thisName: String
    /// One per `item.recipients`.
    let recipientNames: [String]
    let peerPanel: UUID?
    let isExpanded: Bool
    let isFlashing: Bool
    let now: Date
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let style: MailboxDrawerStyle
    let bodyFont: Font
    let metaFont: Font
    let onToggleExpanded: () -> Void
    let onShowParent: (String) -> Void

    @State private var copied = false

    private var scale: CGFloat { style.scale }
    private var isSent: Bool { item.direction == .sent }
    private var orange: Color { Color(nsColor: .systemOrange) }
    private var link: Color { Color(nsColor: .linkColor) }
    private var gold: Color { BrandColors.goldSwiftUI }
    private var horizontalPadding: CGFloat { 8 * scale }

    private var isDark: Bool {
        guard let color = style.background.usingColorSpace(.sRGB) else { return true }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent < 0.5
    }

    private var fill: Color {
        if isSent { return isDark ? Color.white.opacity(0.05) : Color.white }
        return isDark ? Color.black.opacity(0.22) : Color.black.opacity(0.04)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isSent { Spacer(minLength: 0) }
            bubble
            if !isSent { Spacer(minLength: 0) }
        }
        .padding(.vertical, 3.5 * scale)
    }

    private var bubble: some View {
        MailboxBubbleStack(
            spacing: 4 * scale,
            minWidth: max(0, minWidth - 2 * horizontalPadding),
            maxWidth: max(0, maxWidth - 2 * horizontalPadding)
        ) {
            header
            if isSent && item.recipients.count > 1 { recipientsLine }
            if !chipItems.isEmpty { chipsRow }
            bodyBlock
            if showsActions { actions }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 6 * scale)
        .padding(.bottom, 5 * scale)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(!isSent && item.state == .unread ? orange : style.border, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(gold, lineWidth: 2)
                .padding(-4)
                .opacity(isFlashing ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.25), value: isFlashing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(isSent
            ? String(localized: "mailbox.conversations.bubble.sent", defaultValue: "\(thisName) to \(peerName)")
            : String(localized: "mailbox.conversations.bubble.received", defaultValue: "\(peerName) to \(thisName)")))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
            stateChip(item.state, who: isSent ? peerName : thisName, received: !isSent)
            Text(verbatim: item.topic ?? String(localized: "mailbox.drawer.noTopic", defaultValue: "(no topic)"))
                .font(metaFont.weight(item.topic == nil ? .regular : .semibold))
                .foregroundColor(item.topic == nil ? style.secondary : style.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10 * scale)
            if let date = item.date {
                Text(verbatim: MailboxConversationsText.clock(date))
                    .font(metaFont.monospacedDigit())
                    .foregroundColor(style.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(MailboxDrawerText.stamp(date) + " · " + MailboxDrawerText.age(of: date, now: now))
            }
        }
    }

    private func stateChip(_ state: MailboxPanelMail.SentState, who: String, received: Bool) -> MailboxConversationChip {
        let label: String
        let help: String
        let kind: MailboxConversationChip.Kind
        switch (received, state) {
        case (true, .unread):
            label = String(localized: "mailbox.drawer.state.unread", defaultValue: "UNREAD")
            help = String(localized: "mailbox.conversations.state.unread.help", defaultValue: "\(who) has not taken this message yet.")
            kind = .filled
        case (true, _):
            label = String(localized: "mailbox.insights.tile.taken", defaultValue: "TAKEN")
            help = String(localized: "mailbox.conversations.state.taken.help", defaultValue: "\(who) has taken this message.")
            kind = .plain
        case (false, .unread):
            label = String(localized: "mailbox.insights.tile.waiting", defaultValue: "WAITING")
            help = String(localized: "mailbox.conversations.state.unread.help", defaultValue: "\(who) has not taken this message yet.")
            kind = .waiting
        case (false, .read):
            label = String(localized: "mailbox.insights.tile.taken", defaultValue: "TAKEN")
            help = String(localized: "mailbox.conversations.state.taken.help", defaultValue: "\(who) has taken this message.")
            kind = .plain
        case (false, .gone):
            label = String(localized: "mailbox.drawer.sent.state.gone", defaultValue: "GONE")
            help = String(localized: "mailbox.conversations.state.gone.help", defaultValue: "\(who)'s copy is no longer on disk.")
            kind = .gone
        }
        return MailboxConversationChip(label: label, kind: kind, help: help, style: style)
    }

    /// A broadcast: where it was addressed, and each recipient's copy.
    private var recipientsLine: some View {
        MailboxFlowLayout(spacing: 10 * scale, lineSpacing: 2 * scale) {
            Text(verbatim: item.to.map {
                String(localized: "mailbox.conversations.recipients.to", defaultValue: "to \($0) · \(item.recipients.count) panels")
            } ?? String(localized: "mailbox.conversations.recipients", defaultValue: "to \(item.recipients.count) panels"))
            .font(metaFont)
            .foregroundColor(style.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            ForEach(item.recipients.indices, id: \.self) { index in
                let recipient = item.recipients[index]
                let name = recipientNames.indices.contains(index) ? recipientNames[index] : recipient.name
                HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
                    Text(verbatim: name)
                        .font(metaFont.weight(.semibold))
                        .foregroundColor(recipient.panelId != nil && recipient.panelId == peerPanel ? style.foreground : style.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    stateChip(recipient.state, who: name, received: false)
                }
            }
        }
    }

    // MARK: Chips

    private enum ChipKind { case plain, warn, link(String) }
    private struct Chip {
        let text: String
        let kind: ChipKind
        var help: String? = nil
    }

    private var chipItems: [Chip] {
        guard let message = item.message, message.problem == nil else { return [] }
        var items: [Chip] = []
        if message.urgent {
            items.append(Chip(text: String(localized: "mailbox.drawer.chip.urgent", defaultValue: "urgent"), kind: .warn))
        }
        if let replyTo = message.inReplyTo {
            if let parent = item.parent {
                let topic = parent.topic ?? String(localized: "mailbox.drawer.noTopic", defaultValue: "(no topic)")
                let when = parent.date.map {
                    $0.formatted(.dateTime.weekday(.abbreviated)) + " " + MailboxConversationsText.clock($0)
                } ?? ""
                items.append(Chip(
                    text: String(localized: "mailbox.conversations.chip.replyTo", defaultValue: "↳ reply to \(topic) · \(when)"),
                    kind: .link(parent.id),
                    help: String(localized: "mailbox.conversations.chip.replyTo.help", defaultValue: "Show the message this replies to")
                ))
            } else {
                items.append(Chip(
                    text: String(localized: "mailbox.drawer.chip.replyToId", defaultValue: "↳ reply to \(String(replyTo.prefix(10)))…"),
                    kind: .plain,
                    help: String(localized: "mailbox.conversations.chip.replyOutside.help", defaultValue: "The parent is not in this conversation")
                ))
            }
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
        if let replyAddress = message.replyTo {
            items.append(Chip(text: String(localized: "mailbox.drawer.chip.replyAddress", defaultValue: "replies to \(replyAddress)"), kind: .plain))
        }
        if let contentType = message.contentType {
            items.append(Chip(text: contentType, kind: .plain))
        }
        return items
    }

    private var chipsRow: some View {
        let items = chipItems
        return MailboxFlowLayout(spacing: 4 * scale, lineSpacing: 4 * scale) {
            ForEach(items.indices, id: \.self) { index in
                chip(items[index])
            }
        }
    }

    @ViewBuilder
    private func chip(_ chip: Chip) -> some View {
        let label = Text(verbatim: chip.text)
            .font(metaFont)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .padding(.vertical, 0.5)
        switch chip.kind {
        case .plain:
            label.foregroundColor(style.secondary)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(style.border, lineWidth: 1))
                .help(chip.help ?? chip.text)
        case .warn:
            label.foregroundColor(orange)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(orange.opacity(0.45), lineWidth: 1))
        case .link(let id):
            Button { onShowParent(id) } label: {
                label.foregroundColor(link)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(link.opacity(0.45), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(chip.help ?? chip.text)
        }
    }

    // MARK: Body

    @ViewBuilder
    private var bodyBlock: some View {
        if let message = item.message {
            if let problem = message.problem {
                Text(verbatim: problem)
                    .font(bodyFont)
                    .foregroundColor(orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6 * scale) {
                    // Links found by MailboxBodyLinks (C11-524) open through the
                    // drawer's openURL handler, as they do in Received.
                    if !message.body.isEmpty {
                        bodyText(message.bodyRich, isLong: message.isLong)
                    }
                    if let reference = message.reference {
                        referenceBlock(reference, rich: message.referenceRich, isLong: message.isLong)
                    }
                    if message.body.isEmpty && message.reference == nil {
                        Text(String(localized: "mailbox.drawer.emptyBody", defaultValue: "This message has no body."))
                            .font(bodyFont)
                            .foregroundColor(style.secondary)
                    }
                }
            }
        } else {
            Text(verbatim: String(
                localized: "mailbox.conversations.copyGone",
                defaultValue: "Copy gone. \(peerName)'s copy is no longer on disk, so the text cannot be shown. The sent record keeps the topic, time and recipients."
            ))
            .font(bodyFont)
            .foregroundColor(style.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7 * scale)
            .padding(.vertical, 5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(style.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
    }

    /// Long text folds to its first lines and fades out, until "Show all".
    /// The text carries only the links MailboxBodyLinks found; it is never
    /// parsed as Markdown.
    private func bodyText(_ text: AttributedString, isLong: Bool) -> some View {
        let folded = isLong && !isExpanded
        return Text(text)
            .font(bodyFont)
            .foregroundColor(style.foreground)
            .lineLimit(folded ? MailboxPanelMail.foldedLineLimit : nil)
            .fixedSize(horizontal: false, vertical: true)
            .mask {
                LinearGradient(
                    stops: folded
                        ? [.init(color: .black, location: 0), .init(color: .black, location: 0.72), .init(color: .black.opacity(0), location: 1)]
                        : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }

    @ViewBuilder
    private func referenceBlock(_ reference: MailboxPanelMail.Reference, rich: AttributedString?, isLong: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            Text(verbatim: referenceCaption(reference))
                .font(metaFont)
                .foregroundColor(style.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(reference.path)
            switch reference.content {
            case .text(let text, let truncated, let bytes):
                if text.isEmpty {
                    Text(String(localized: "mailbox.drawer.ref.emptyFile", defaultValue: "The referenced file is empty."))
                        .font(bodyFont)
                        .foregroundColor(style.secondary)
                } else {
                    bodyText(rich ?? AttributedString(text), isLong: isLong)
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
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Actions

    private var hasCopyableText: Bool {
        guard let message = item.message, message.problem == nil else { return false }
        if !message.body.isEmpty { return true }
        if case .text(let text, _, _)? = message.reference?.content { return !text.isEmpty }
        return false
    }

    private var showsActions: Bool {
        guard let message = item.message, message.problem == nil else { return false }
        return message.isLong || hasCopyableText
    }

    private var actions: some View {
        HStack(spacing: 14 * scale) {
            if item.message?.isLong == true {
                Button(isExpanded
                    ? String(localized: "mailbox.drawer.showLess", defaultValue: "Show less")
                    : String(localized: "mailbox.drawer.showAll", defaultValue: "Show all")
                ) { onToggleExpanded() }
                .buttonStyle(.link)
                .font(metaFont)
                .fixedSize()
            }
            if hasCopyableText {
                // The drawer's panel never becomes key, so a selection could
                // not be copied with Command-C; this button is the copy path.
                Button(copied
                    ? String(localized: "mailbox.conversations.copied", defaultValue: "Copied")
                    : String(localized: "mailbox.drawer.copy", defaultValue: "Copy text")
                ) {
                    guard let text = item.message?.fullText else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .buttonStyle(.link)
                .font(metaFont)
                .fixedSize()
                .frame(minWidth: 64 * scale, alignment: .leading)
            }
        }
    }
}

/// Stacks a bubble's rows at one width: the widest row's natural width,
/// kept between `minWidth` and `maxWidth`, so a short message makes a narrow
/// bubble and a long one wraps.
private struct MailboxBubbleStack: Layout {
    var spacing: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat

    private func width(of subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return min(max(widest, minWidth), maxWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = self.width(of: subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: width, height: heights.reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let child = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(child).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }
}

/// Lays chips out left to right, wrapping to a new line when the next one
/// does not fit. A chip wider than a line is narrowed to it.
private struct MailboxFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(width: CGFloat?, subviews: Subviews) -> [Line] {
        let limit = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > limit {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: limit, height: nil))
                size.width = min(size.width, limit)
            }
            if !line.items.isEmpty, line.width + spacing + size.width > limit {
                lines.append(line)
                line = Line()
            }
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = self.lines(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in self.lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
