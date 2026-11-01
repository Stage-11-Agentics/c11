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
    /// Closes the drawer, as a second click on the envelope does.
    var onClose: () -> Void = {}

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
    @State private var linkOpener = MailboxDrawerLinkOpener()

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
        .background(MailboxDrawerHostReader { linkOpener.hostView = $0 })
        .overlay(Rectangle().stroke(style.border, lineWidth: 1))
        // Every body link in every tab opens here; Text never opens a URL itself.
        .environment(\.openURL, OpenURLAction { url in
            // A link that landed closes the drawer the way its close button does,
            // so the destination and its pulse are not covered.
            linkOpener.open(url, onPanelLinkOpened: onClose)
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

    private var tabBar: some View {
        Picker("", selection: $tab) {
            Text(String(localized: "mailbox.drawer.tab.received", defaultValue: "Received")).tag(Tab.received)
            Text(String(localized: "mailbox.drawer.tab.sent", defaultValue: "Sent")).tag(Tab.sent)
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
                        filter: $insightsFilter,
                        slice: insightsSlice,
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
                }
                if let topic = filter.topic {
                    chip(String(localized: "mailbox.insights.chip.topic", defaultValue: "topic \(topic)")) { filter.topic = nil }
                }
                if let window = filter.window {
                    chip(windowName(window)) { filter.window = nil }
                }
                if let key = filter.recipient {
                    chip(String(localized: "mailbox.insights.chip.to", defaultValue: "to \(recipientName(key))")) { filter = MailboxPanelMail.InsightsFilter() }
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
                Text(verbatim: record.header.from)
                    .foregroundColor(style.foreground)
                    .lineLimit(1)
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
/// malformed target shows the same non-modal notice. `http` and `https` open
/// in the default browser. Nothing else is ever a link.
@MainActor
final class MailboxDrawerLinkOpener {
    weak var hostView: NSView?
    private let notices = PanelLinkNoticePresenter()

    func open(_ url: URL, onPanelLinkOpened: () -> Void) -> OpenURLAction.Result {
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

    private func showNotice(_ notice: PanelLinkNotice) {
        guard let host = hostView?.window?.contentView ?? hostView else { return }
        notices.show(notice, in: host)
    }
}

/// Hands the drawer's AppKit view to the link opener, for its notice.
private struct MailboxDrawerHostReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
