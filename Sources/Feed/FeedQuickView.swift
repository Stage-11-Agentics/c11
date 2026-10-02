import AppKit
import Combine
import SwiftUI

struct FeedQuickViewSnapshot: Equatable {
    var projection: FeedProjectionSnapshot = .empty
    var titles: [UUID: String] = [:]
    var now: Date = Date()
    var loading = true

    func rows(for filter: FeedQuickViewSelection.Filter) -> [FeedRow] {
        switch filter {
        case .asks: return projection.attentionRows
        case .turns: return projection.rows.filter { $0.kind == .turnEnd }
        }
    }
}

final class FeedQuickViewModel: ObservableObject {
    @Published private(set) var snapshot = FeedQuickViewSnapshot()
    @Published private(set) var selection = FeedQuickViewSelection()
    @Published private(set) var status = ""
    var onOpen: (AttentionOrder.Target) -> Bool = { _ in false }
    var onOpened: () -> Void = {}

    var rows: [FeedRow] { snapshot.rows(for: selection.filter) }

    func apply(_ snapshot: FeedQuickViewSnapshot) {
        self.snapshot = snapshot
        selection.update(rows.map(\.tabID))
    }

    func switchFilter(_ filter: FeedQuickViewSelection.Filter) {
        selection.switchFilter(filter, tabIDs: snapshot.rows(for: filter).map(\.tabID))
        status = ""
    }

    /// Tab and Shift-Tab flip between the two filters; selection follows `switchFilter`.
    func toggleFilter() {
        let all = FeedQuickViewSelection.Filter.allCases
        let next = all[(all.firstIndex(of: selection.filter).map { $0 + 1 } ?? 0) % all.count]
        switchFilter(next)
    }

    func move(_ delta: Int) { selection.move(delta); status = "" }
    func select(_ tabID: UUID) { selection.select(tabID) }

    func markUnavailable() {
        status = String(localized: "feed.quick.unavailable", defaultValue: "That tab is unavailable")
    }

    func openSelected() {
        guard let row = rows.first(where: { $0.tabID == selection.selectedTabID }) else { return }
        guard onOpen(.init(workspaceID: row.workspaceID, tabID: row.tabID)) else {
            markUnavailable()
            return
        }
        onOpened()
    }
}

enum FeedQuickViewGeometry {
    static let size = NSSize(width: 520, height: 420)
    static let header: CGFloat = 44
    static let filterWidth: CGFloat = 200
    static let filterHeight: CGFloat = 28
    static let status: CGFloat = 16
    static let row: CGFloat = 64
    static let hint: CGFloat = 28
}

struct FeedQuickView: View {
    @ObservedObject var model: FeedQuickViewModel
    // A render seam for executable long-locale layout fixtures, never a runtime override.
    var filterLabels = [
        String(localized: "feed.quick.filter.asks", defaultValue: "Asks"),
        String(localized: "feed.quick.filter.turns", defaultValue: "Turns")
    ]
    var onLayout: ((String, CGRect) -> Void)?
    /// Reports the real focused filter (not the model's selection) to executable tests.
    var onFilterFocus: ((FeedQuickViewSelection.Filter?) -> Void)?
    /// The native focus ring follows the active filter, whether it changed by Tab, Shift-Tab or pointer.
    @FocusState private var focusedFilter: FeedQuickViewSelection.Filter?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "feed.quick.title", defaultValue: "Feed"))
                    .font(.headline).frame(width: 48, alignment: .leading).lineLimit(1)
                HStack(spacing: 0) {
                    ForEach(Array(FeedQuickViewSelection.Filter.allCases.enumerated()), id: \.offset) { index, filter in
                        Button { model.switchFilter(filter) } label: {
                            Text(filterLabels[index]).lineLimit(1).truncationMode(.tail)
                                .frame(width: 100, height: FeedQuickViewGeometry.filterHeight)
                                .background(model.selection.filter == filter ? Color.accentColor.opacity(0.18) : Color.clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focusedFilter, equals: filter)
                        .feedQuickMeasure("filter.\(index)", observer: onLayout)
                        .accessibilityIdentifier(index == 0 ? "feed.quick.filter.asks" : "feed.quick.filter.turns")
                        .accessibilityLabel(filterLabels[index])
                        .accessibilityAddTraits(model.selection.filter == filter ? .isSelected : [])
                    }
                }
                .frame(width: FeedQuickViewGeometry.filterWidth, height: FeedQuickViewGeometry.filterHeight)
                .feedQuickMeasure("filters", observer: onLayout)
                .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 5))
                Text(NotificationMenuSnapshotBuilder.attentionCountTitle(
                    flags: model.snapshot.projection.flagCount, asks: model.snapshot.projection.openAskCount))
                    .font(.caption).monospacedDigit().lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("feed.quick.counts")
            }
            .padding(.horizontal, 12).frame(height: FeedQuickViewGeometry.header)
            .feedQuickMeasure("header", observer: onLayout)
            Text(model.status.isEmpty ? " " : model.status)
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                .frame(height: FeedQuickViewGeometry.status).accessibilityIdentifier("feed.quick.status")
                .feedQuickMeasure("status", observer: onLayout)
            Divider()
            ScrollViewReader { scroll in
                ZStack {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.rows, id: \.tabID) { row in
                                FeedQuickViewRow(row: row, title: model.snapshot.titles[row.tabID] ?? row.tabID.uuidString,
                                    now: model.snapshot.now, selected: model.selection.selectedTabID == row.tabID,
                                    onLayout: onLayout) {
                                        model.select(row.tabID)
                                        model.openSelected()
                                    }
                                    .id(row.tabID)
                            }
                        }
                    }
                    if model.snapshot.loading || model.rows.isEmpty {
                        Text(emptyTitle).font(.headline).foregroundColor(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("feed.quick.empty")
                    }
                }
                .onChange(of: model.selection.selectedTabID) { _, id in
                    if let id { scroll.scrollTo(id) } // No animation; identity, not moving index.
                }
            }
            .frame(height: FeedQuickViewGeometry.size.height - FeedQuickViewGeometry.header - FeedQuickViewGeometry.status - FeedQuickViewGeometry.hint - 1)
            Text(String(localized: "feed.quick.hint", defaultValue: "Arrows move. Return opens. Tab switches filter. Esc closes."))
                .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity).frame(height: FeedQuickViewGeometry.hint)
                .accessibilityIdentifier("feed.quick.hint")
                .feedQuickMeasure("hint", observer: onLayout)
        }
        .frame(width: FeedQuickViewGeometry.size.width, height: FeedQuickViewGeometry.size.height)
        .onAppear { focusedFilter = model.selection.filter }
        .onChange(of: model.selection.filter) { _, filter in focusedFilter = filter }
        .onChange(of: focusedFilter) { _, filter in onFilterFocus?(filter) }
        .coordinateSpace(name: "feed.quick.layout")
        .feedQuickMeasure("content", observer: onLayout)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("feed.quick.view")
    }

    private var emptyTitle: String {
        if model.snapshot.loading { return String(localized: "feed.quick.loading", defaultValue: "Loading") }
        return model.selection.filter == .asks
            ? String(localized: "feed.quick.empty.asks", defaultValue: "No open asks")
            : String(localized: "feed.quick.empty.turns", defaultValue: "No finished turns")
    }
}

struct FeedQuickViewRow: View {
    let row: FeedRow
    let title: String
    let now: Date
    let selected: Bool
    var onLayout: ((String, CGRect) -> Void)?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) { rowContent }
        .buttonStyle(.plain)
        .feedQuickMeasure("row.\(row.tabID.uuidString)", observer: onLayout)
        .accessibilityIdentifier("feed.quick.row.\(row.tabID.uuidString)")
        .accessibilityLabel(kindTitle + ": " + String(title.prefix(256)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(accessibleHelp)
        .accessibilityAction { onOpen() }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
                Text(evidence).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                Text(prompt).font(.subheadline).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(age).font(.caption).monospacedDigit().lineLimit(1).truncationMode(.tail)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: FeedQuickViewGeometry.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    private var prompt: String {
        row.prompt ?? row.flag?.reason ?? String(localized: "feed.quick.prompt.missing", defaultValue: "—")
    }

    private var accessibleHelp: String {
        String([title, evidence, prompt].joined(separator: "\n").prefix(1024))
    }

    private var glyph: String {
        if row.flag != nil { return "flag.fill" }
        switch row.kind {
        case .question: return "questionmark.circle"
        case .plan: return "list.bullet.clipboard"
        case .permission: return "lock"
        case .turnEnd: return "checkmark.circle"
        case nil: return "flag"
        }
    }
    private var kindTitle: String {
        switch row.kind {
        case .question: return String(localized: "feed.quick.kind.question", defaultValue: "Question")
        case .plan: return String(localized: "feed.quick.kind.plan", defaultValue: "Plan")
        case .permission: return String(localized: "feed.quick.kind.permission", defaultValue: "Permission")
        case .turnEnd: return String(localized: "feed.quick.kind.turnEnd", defaultValue: "Turn ended")
        case nil: return String(localized: "feed.quick.kind.flag", defaultValue: "Flag")
        }
    }
    private var age: String {
        guard let ms = row.flag?.raisedAtMs ?? row.openedAtMs else {
            return String(localized: "feed.quick.age.missing", defaultValue: "—")
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        return formatter.string(from: max(0, now.timeIntervalSince1970 - Double(ms) / 1000)) ?? "—"
    }
    private var evidence: String {
        let source: String
        switch row.source {
        case "hook": source = String(localized: "feed.quick.source.hook", defaultValue: "Hook")
        case "plugin": source = String(localized: "feed.quick.source.plugin", defaultValue: "Plugin")
        case "transcript": source = String(localized: "feed.quick.source.transcript", defaultValue: "Transcript")
        case "screen": source = String(localized: "feed.quick.source.screen", defaultValue: "Screen")
        case "shell": source = String(localized: "feed.quick.source.shell", defaultValue: "Shell")
        case "keypress": source = String(localized: "feed.quick.source.keypress", defaultValue: "Keypress")
        case "self_report": source = String(localized: "feed.quick.source.selfReport", defaultValue: "Self report")
        case "c11": source = String(localized: "feed.quick.source.c11", defaultValue: "c11")
        default: source = "—"
        }
        let rank = row.sourceRank.map { String(format: String(localized: "feed.quick.evidence", defaultValue: "%@ · rank %lld"), source, Int64($0)) } ?? source
        return row.confirmation == "unconfirmed"
            ? rank + " · " + String(localized: "journal.evidence.unconfirmed", defaultValue: "Unconfirmed") : rank
    }
}

private extension View {
    /// Optional rendered-layout oracle. Production has no observer/GeometryReader.
    func feedQuickMeasure(_ name: String, observer: ((String, CGRect) -> Void)?) -> some View {
        background {
            if let observer {
                GeometryReader { proxy in
                    Color.clear.onAppear { observer(name, proxy.frame(in: .named("feed.quick.layout"))) }
                        .onChange(of: proxy.frame(in: .named("feed.quick.layout"))) { _, frame in observer(name, frame) }
                }
            }
        }
    }
}
