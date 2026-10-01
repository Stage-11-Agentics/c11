import AppKit
import SwiftUI
import Bonsplit

/// One rail tip for the app. Bonsplit reports overflow, the count-cell view,
/// and whether the tab sheet is open. This type decides when the tip is on
/// screen and owns the popover. The policy decides when a new offer may start.
///
/// The popover is not modal. After it is shown, keyboard focus is given back
/// to the terminal window. Clicking outside ends this offer and does not
/// dismiss the tip. Undo restores Tabs and does the same.
final class TabRailTipCenter: NSObject, NSPopoverDelegate {
    static let shared = TabRailTipCenter()

    private let policy: TabRailTipPolicy
    private let model = TabRailTipModel()
    private var slots: [String: Slot] = [:]
    private var phase: Phase = .idle
    private var sawList = false
    /// True after this showing has written `lastOffered`. Cleared when the
    /// showing ends, so a later offer (after the 30-day gap) stamps again.
    private var stamped = false
    /// True from Try Rail until the popover is on the rail bar's count cell.
    /// The tabs-strip anchor dies when the bar rebuilds; that close is not
    /// the operator leaving the tip.
    private var reanchoring = false
    private weak var anchorBeforeSwitch: NSView?
    private var programmaticClose = false
    private var userClose = false
    private var popover: NSPopover?
    private var hosting: NSHostingController<TabRailTipView>?
    private var shownAnchor: NSView?
    private var sustainItem: DispatchWorkItem?
    private var recordedDayKey: String?
    private var refreshQueued = false
    private var keyWindow: NSWindow?
    private var escapeMonitor: Any?

    private enum Phase {
        case idle
        case pending
        case live
        case undo
    }

    private final class Slot {
        weak var workspace: Workspace?
        let paneId: PaneID
        var overflowing = false
        weak var anchor: NSView?
        var sheetOpen = false

        init(workspace: Workspace, paneId: PaneID) {
            self.workspace = workspace
            self.paneId = paneId
        }
    }

    private override init() {
        policy = TabRailTipPolicy(calendar: .current, store: UserDefaultsTabRailTipStore())
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didResignKeyNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    // MARK: Signals from a workspace

    func noteOverflow(workspace: Workspace, paneId: PaneID, overflowing: Bool) {
        let slot = slot(workspace, paneId)
        guard slot.overflowing != overflowing else { return }
        slot.overflowing = overflowing
        updateSustain()
        scheduleRefresh()
    }

    func noteAnchor(workspace: Workspace, paneId: PaneID, view: NSView?) {
        let slot = slot(workspace, paneId)
        guard slot.anchor !== view else { return }
        slot.anchor = view
        scheduleRefresh()
    }

    func noteSheet(workspace: Workspace, paneId: PaneID, open: Bool) {
        let slot = slot(workspace, paneId)
        guard slot.sheetOpen != open else { return }
        slot.sheetOpen = open
        // Opening the list on the area in front changes the teaching copy.
        // A sheet on some other area does not.
        if open, frontSlot() === slot { sawList = true }
        scheduleRefresh()
    }

    func scheduleRefresh() {
        if Thread.isMainThread {
            enqueueRefresh()
        } else {
            DispatchQueue.main.async { [weak self] in self?.enqueueRefresh() }
        }
    }

    // MARK: Actions

    func performTryRail() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let slot = frontSlot(), let workspace = slot.workspace else { return }
        phase = .undo
        reanchoring = true
        anchorBeforeSwitch = slot.anchor
        model.mode = .undo
        model.rows = []
        TabLayoutSettings.setMode(.rail)
        workspace.bonsplitController.setRailOpen(true, inPane: slot.paneId)
        resizePopover()
        restoreKey()
        scheduleRefresh()
    }

    func performUndo() {
        dispatchPrecondition(condition: .onQueue(.main))
        // Idle before the defaults write, so the layout observer cannot
        // treat the return to Tabs as a new offer. Undo does not dismiss.
        phase = .idle
        reanchoring = false
        anchorBeforeSwitch = nil
        stamped = false
        hidePopover()
        TabLayoutSettings.setMode(.tabs)
        restoreKey()
    }

    func performShowList() {
        dispatchPrecondition(condition: .onQueue(.main))
        switch phase {
        case .live, .pending:
            break
        case .idle, .undo:
            return
        }
        guard let slot = frontSlot(), let workspace = slot.workspace else { return }
        sawList = true
        model.sawList = true
        hidePopover()
        workspace.bonsplitController.setTabSheetOpen(true, inPane: slot.paneId)
    }

    func performDismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        policy.dismiss()
        phase = .idle
        reanchoring = false
        anchorBeforeSwitch = nil
        stamped = false
        hidePopover()
        restoreKey()
    }

    // MARK: Popover

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        removeEscapeMonitor()
        if programmaticClose {
            programmaticClose = false
            return
        }
        if userClose {
            userClose = false
            endOffer()
            return
        }
        // The count cell's view was replaced (the bar folded, or Rail opened).
        // Wait for the new anchor instead of ending the offer.
        if reanchoring || shownAnchor?.window == nil {
            shownAnchor = nil
            return
        }
        endOffer()
    }

    func popoverDidShow(_ notification: Notification) {
        guard let shown = notification.object as? NSPopover, shown === popover else { return }
        restoreKey()
    }

    @objc private func windowKeyChanged(_ notification: Notification) {
        scheduleRefresh()
    }

    private func enqueueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        let stale = slots.compactMap { $0.value.workspace == nil ? $0.key : nil }
        for key in stale {
            slots.removeValue(forKey: key)
        }
        if policy.isDismissed {
            phase = .idle
            reanchoring = false
            hidePopover()
            return
        }
        switch phase {
        case .idle:
            considerStarting()
        case .pending, .live:
            updateTeaching()
        case .undo:
            updateUndo()
        }
    }

    private func considerStarting() {
        guard TabLayoutSettings.mode() == .tabs else { return }
        guard let slot = frontSlot(), slot.overflowing, !slot.sheetOpen, slot.anchor?.window != nil else { return }
        guard policy.shouldOffer(now: Date(), layoutIsTabs: true, areaOverflowing: true) else { return }
        phase = .pending
        sawList = false
        showTeaching(slot)
    }

    private func updateTeaching() {
        guard TabLayoutSettings.mode() == .tabs else {
            endOffer()
            return
        }
        guard let slot = frontSlot() else {
            hidePopover()
            return
        }
        if slot.sheetOpen || !slot.overflowing {
            hidePopover()
            return
        }
        showTeaching(slot)
    }

    private func updateUndo() {
        guard TabLayoutSettings.mode() == .rail else {
            endOffer()
            return
        }
        guard let slot = frontSlot(), let anchor = slot.anchor, anchor.window != nil else {
            hidePopover()
            return
        }
        model.mode = .undo
        present(on: anchor)
        // Still the tabs-strip cell. The rail bar has not taken its place yet.
        if let previous = anchorBeforeSwitch, anchor === previous { return }
        reanchoring = false
        anchorBeforeSwitch = nil
    }

    private func showTeaching(_ slot: Slot) {
        guard let anchor = slot.anchor, anchor.window != nil, let workspace = slot.workspace else { return }
        model.mode = .teaching
        model.sawList = sawList
        model.rows = previewRows(workspace: workspace, paneId: slot.paneId)
        present(on: anchor)
        guard popover?.isShown == true else { return }
        guard phase == .pending || phase == .live else { return }
        if !stamped {
            policy.markOffered(now: Date())
            stamped = true
        }
        phase = .live
    }

    private func endOffer() {
        phase = .idle
        reanchoring = false
        anchorBeforeSwitch = nil
        stamped = false
        hidePopover()
    }

    private func present(on anchor: NSView) {
        let popover = ensurePopover()
        if popover.isShown, shownAnchor === anchor {
            resizePopover()
            installEscapeMonitor()
            restoreKey()
            return
        }
        if popover.isShown {
            programmaticClose = true
            popover.performClose(nil)
        }
        shownAnchor = anchor
        keyWindow = anchor.window
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        resizePopover()
        if popover.isShown { installEscapeMonitor() }
        restoreKey()
    }

    private func hidePopover() {
        guard let popover, popover.isShown else { return }
        programmaticClose = true
        popover.performClose(nil)
        shownAnchor = nil
    }

    private func ensurePopover() -> NSPopover {
        if let popover { return popover }
        let host = NSHostingController(rootView: TabRailTipView(model: model))
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = host
        self.hosting = host
        self.popover = popover
        return popover
    }

    private func resizePopover() {
        guard let popover, let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        guard fit.width > 1, fit.height > 1 else { return }
        popover.contentSize = NSSize(width: ceil(fit.width), height: ceil(fit.height))
    }

    /// The tip must not keep the keyboard. Put key status back on the
    /// terminal window the popover is attached to. Semitransient closes on a
    /// click in that window, not on this key change.
    private func restoreKey() {
        keyWindow?.makeKey()
    }

    /// Escape ends the offer and is not typed into the terminal. The popover
    /// is not key, so the window would otherwise deliver Escape to the shell.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover?.isShown == true else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard event.keyCode == 53, flags.isEmpty else { return event }
            self.closeFromUser()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    private func closeFromUser() {
        userClose = true
        reanchoring = false
        anchorBeforeSwitch = nil
        guard let popover, popover.isShown else {
            userClose = false
            endOffer()
            return
        }
        popover.performClose(nil)
    }

    // MARK: Slots and the sustain timer

    private func slot(_ workspace: Workspace, _ paneId: PaneID) -> Slot {
        let id = workspace.id.uuidString + "|" + paneId.id.uuidString
        if let existing = slots[id] {
            existing.workspace = workspace
            return existing
        }
        let created = Slot(workspace: workspace, paneId: paneId)
        slots[id] = created
        return created
    }

    /// The focused pane of the front window's selected workspace.
    /// A key popover is skipped in favor of the main window. An inactive
    /// app has no front area, so the tip hides until the operator comes back.
    private func frontSlot() -> Slot? {
        guard NSApp.isActive, let app = AppDelegate.shared else { return nil }
        var seen = Set<ObjectIdentifier>()
        for case let window? in [NSApp.keyWindow, NSApp.mainWindow] {
            guard seen.insert(ObjectIdentifier(window)).inserted else { continue }
            for slot in slots.values {
                guard let workspace = slot.workspace else { continue }
                guard let manager = app.tabManagerFor(tabId: workspace.id) else { continue }
                guard manager.window === window else { continue }
                guard manager.selectedWorkspace?.id == workspace.id else { continue }
                guard workspace.bonsplitController.focusedPaneId == slot.paneId else { continue }
                return slot
            }
        }
        return nil
    }

    private func updateSustain(now: Date = Date()) {
        let today = policy.dayKey(for: now)
        if recordedDayKey == today || policy.hasRecordedOverflow(on: now) {
            recordedDayKey = today
            sustainItem?.cancel()
            sustainItem = nil
            return
        }
        let any = slots.values.contains { $0.overflowing && $0.workspace != nil }
        if !any {
            sustainItem?.cancel()
            sustainItem = nil
            return
        }
        guard sustainItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.sustainFired()
        }
        sustainItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + TabRailTipPolicy.sustain, execute: item)
    }

    private func sustainFired() {
        sustainItem = nil
        guard slots.values.contains(where: { $0.overflowing && $0.workspace != nil }) else { return }
        let now = Date()
        if policy.recordOverflow(now: now) {
            recordedDayKey = policy.dayKey(for: now)
            scheduleRefresh()
        } else {
            recordedDayKey = policy.dayKey(for: now)
        }
    }

    private func previewRows(workspace: Workspace, paneId: PaneID) -> [TabRailTipPreviewRow] {
        let tabs = workspace.bonsplitController.tabs(inPane: paneId)
        guard !tabs.isEmpty else { return [] }
        let selected = workspace.bonsplitController.selectedTab(inPane: paneId)?.id
        let index = tabs.firstIndex(where: { $0.id == selected }) ?? 0
        let range = TabRailTipPreviewWindow.range(count: tabs.count, selectedIndex: index)
        return tabs[range].map { tab in
            TabRailTipPreviewRow(
                id: tab.id.uuid.uuidString,
                title: tab.detail?.title.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title,
                ordinal: tab.displayOrdinal,
                status: Self.statusKind(for: tab),
                selected: tab.id == selected
            )
        }
    }

    private static func statusKind(for tab: Bonsplit.Tab) -> TabRailTipStatusKind? {
        if let kind = tab.detail?.status?.kind {
            switch kind {
            case .working: return .working
            case .waiting: return .waiting
            case .flagged: return .flagged
            case .idle: return .idle
            case .cold: return .cold
            }
        }
        switch tab.activityState {
        case .running: return .working
        case .idle: return .idle
        case .cold: return .cold
        case .waiting: return .waiting
        case nil: return nil
        }
    }
}

enum TabRailTipStatusKind {
    case working, waiting, flagged, idle, cold
}

struct TabRailTipPreviewRow: Identifiable, Equatable {
    let id: String
    let title: String
    let ordinal: Int?
    let status: TabRailTipStatusKind?
    let selected: Bool
}

final class TabRailTipModel: ObservableObject {
    enum Mode { case teaching, undo }
    @Published var mode: Mode = .teaching
    @Published var sawList = false
    @Published var rows: [TabRailTipPreviewRow] = []
}

struct TabRailTipView: View {
    @ObservedObject var model: TabRailTipModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = TipPalette.resolve(colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            if model.mode == .undo {
                Text(String(localized: "tabRailTip.undoTitle", defaultValue: "Tab Layout is Rail"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text(String(localized: "tabRailTip.undoBody", defaultValue: "Every area keeps its tab list on the left. Undo puts Tabs back."))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                tipButton(
                    String(localized: "tabRailTip.undo", defaultValue: "Undo"),
                    identifier: "tabRailTip.undo",
                    fill: palette.gold,
                    ink: palette.ink
                ) {
                    TabRailTipCenter.shared.performUndo()
                }
            } else {
                Text(String(localized: "tabRailTip.title", defaultValue: "More tabs than fit"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text(model.sawList
                    ? String(localized: "tabRailTip.bodyAfterList", defaultValue: "That list is the number on the bar. Rail keeps it open on the left.")
                    : String(localized: "tabRailTip.body", defaultValue: "The number opens every tab in this area. Rail keeps that list on the left."))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "tabRailTip.previewLabel", defaultValue: "Tab Layout: Rail"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.faint)
                    .textCase(.uppercase)
                preview(palette)
                HStack(spacing: 8) {
                    tipButton(
                        String(localized: "tabRailTip.tryRail", defaultValue: "Try Rail"),
                        identifier: "tabRailTip.tryRail",
                        fill: palette.gold,
                        ink: palette.ink
                    ) {
                        TabRailTipCenter.shared.performTryRail()
                    }
                    tipButton(
                        String(localized: "tabRailTip.showList", defaultValue: "Show tab list"),
                        identifier: "tabRailTip.showList",
                        fill: palette.count,
                        ink: palette.text,
                        border: palette.border
                    ) {
                        TabRailTipCenter.shared.performShowList()
                    }
                }
                Button(action: { TabRailTipCenter.shared.performDismiss() }) {
                    Text(String(localized: "tabRailTip.dismiss", defaultValue: "Don't show again"))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tabRailTip.dismiss")
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(palette.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabRailTip")
    }

    private func preview(_ palette: TipPalette) -> some View {
        VStack(spacing: 0) {
            ForEach(model.rows) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(mark(row.status, palette))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.title)
                            .font(.system(size: 11, weight: row.selected ? .bold : .regular))
                            .foregroundStyle(row.selected ? palette.text : palette.dim)
                            .lineLimit(1)
                        if let word = statusWord(row.status) {
                            Text(word)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(statusColor(row.status, palette))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let ordinal = row.ordinal {
                        Text(String(format: String(localized: "tabRailTip.tabOrdinal", defaultValue: "Tab %lld"), Int64(ordinal)))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(row.selected ? palette.gold : palette.faint)
                    }
                }
                .padding(.vertical, 3)
                .padding(.leading, 5)
                .padding(.trailing, 8)
                .background(row.selected ? palette.rowActive : Color.clear)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(row.selected ? palette.gold : Color.clear)
                        .frame(width: 3)
                }
            }
        }
        .background(palette.header)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(palette.separator, lineWidth: 1)
        )
    }

    private func tipButton(
        _ title: String,
        identifier: String,
        fill: Color,
        ink: Color,
        border: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    if let border {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(border, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func statusWord(_ status: TabRailTipStatusKind?) -> String? {
        switch status {
        case .working:
            return String(localized: "tabRailTip.status.working", defaultValue: "working")
        case .waiting:
            return String(localized: "tabRailTip.status.waiting", defaultValue: "waiting")
        case .flagged:
            return String(localized: "tabRailTip.status.flagged", defaultValue: "flagged")
        case .idle:
            return String(localized: "tabRailTip.status.idle", defaultValue: "idle")
        case .cold:
            return String(localized: "tabRailTip.status.cold", defaultValue: "cold")
        case nil:
            return nil
        }
    }

    private func statusColor(_ status: TabRailTipStatusKind?, _ palette: TipPalette) -> Color {
        switch status {
        case .waiting: return palette.amber
        case .flagged: return palette.violet
        default: return palette.faint
        }
    }

    private func mark(_ status: TabRailTipStatusKind?, _ palette: TipPalette) -> Color {
        switch status {
        case .working: return palette.text
        case .waiting: return palette.amber
        case .flagged: return palette.violet
        case .idle, .cold: return palette.faint
        case nil: return Color.clear
        }
    }
}

/// Sheet colors from the tab bar, duplicated here so the tip does not depend
/// on bonsplit's internal palette. Dark and light pairs match that sheet.
private struct TipPalette {
    let background: Color
    let header: Color
    let text: Color
    let dim: Color
    let faint: Color
    let border: Color
    let separator: Color
    let gold: Color
    let ink: Color
    let rowActive: Color
    let count: Color
    let amber: Color
    let violet: Color

    static func resolve(_ scheme: ColorScheme) -> TipPalette {
        scheme == .dark ? dark : light
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }

    private static let gold = rgb(0xd4a72c)
    private static let amber = rgb(0xe0a030)
    private static let violet = rgb(0x9d8ad9)
    private static let ink = rgb(0x1b1b1b)

    private static let dark = TipPalette(
        background: rgb(0x1d1e23),
        header: rgb(0x191a1e),
        text: rgb(0xe8e8ea),
        dim: rgb(0x9a9ca3),
        faint: rgb(0x74777f),
        border: rgb(0x4a4c55),
        separator: rgb(0x2c2e34),
        gold: gold,
        ink: ink,
        rowActive: rgb(0x25272d),
        count: rgb(0x2f3138),
        amber: amber,
        violet: violet
    )

    private static let light = TipPalette(
        background: rgb(0xf7f8fa),
        header: rgb(0xeef0f4),
        text: rgb(0x16171b),
        dim: rgb(0x55585f),
        faint: rgb(0x7d8088),
        border: rgb(0xb9bdc7),
        separator: rgb(0xdcdfe5),
        gold: gold,
        ink: ink,
        rowActive: rgb(0xf0f1f5),
        count: rgb(0xeceef2),
        amber: amber,
        violet: violet
    )
}
