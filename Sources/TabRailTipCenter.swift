import AppKit
import SwiftUI
import Bonsplit

/// One rail tip for the app. Bonsplit reports overflow, the count-cell view,
/// and whether the tab sheet is open. This type decides when the tip is on
/// screen and owns the popover. The policy decides when a new offer may start.
///
/// The popover is not modal. Each time it opens, if the terminal window
/// was key just before, that window is made key again. A refresh of an
/// already-shown tip does not take the keyboard back. Clicking outside
/// ends this offer and does not dismiss the tip. Undo restores Tabs and
/// does the same.
@MainActor
final class TabRailTipCenter: NSObject, NSPopoverDelegate {
    static let shared = TabRailTipCenter()

    private var policy: TabRailTipPolicy
    private let model = TabRailTipModel()
    private var slots: [String: Slot] = [:]
    private var phase: Phase = .idle
    /// The one area opened by Try Rail, so Undo can remove its persisted open bit.
    private var previewedRailSlot: Slot?
    private var sawList = false
    /// True after this showing has written `lastOffered`. Cleared when the
    /// showing ends, so a later offer (after the 30-day gap) stamps again.
    private var stamped = false
    /// True from Try Rail until the popover is on the rail bar's count cell.
    /// The tabs-strip anchor dies when the bar rebuilds; that close is not
    /// the operator leaving the tip.
    private var reanchoring = false
    private weak var anchorBeforeSwitch: NSView?
    /// Bumps each time the popover is shown. A programmatic close records the
    /// generation it closed. A late `popoverDidClose` for that generation is
    /// not the operator leaving a newer show.
    private var showGeneration = 0
    private var programmaticCloseGeneration: Int?
    private var userClose = false
    private var popover: NSPopover?
    private var hosting: NSHostingController<TabRailTipView>?
    private var shownAnchor: NSView?
    private var refreshQueued = false
    /// Readable from `deinit`, which may not be on the main actor.
    nonisolated(unsafe) private var escapeMonitor: Any?

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
        /// When the current overflow started. Nil while the strip fits.
        var overflowSince: Date?
        var sustainItem: DispatchWorkItem?
        weak var anchor: NSView?
        var sheetOpen = false

        init(workspace: Workspace, paneId: PaneID) {
            self.workspace = workspace
            self.paneId = paneId
        }
    }

    private override init() {
        policy = TabRailTipPolicy(calendar: TabRailTipPolicy.localCalendar(), store: UserDefaultsTabRailTipStore())
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(calendarDayChanged(_:)), name: .NSCalendarDayChanged, object: nil)
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
        if overflowing {
            armSustain(slot)
        } else {
            slot.overflowSince = nil
            slot.sustainItem?.cancel()
            slot.sustainItem = nil
        }
        scheduleRefresh()
    }

    func notePaneClosed(workspace: Workspace, paneId: PaneID) {
        let id = slotID(workspace, paneId)
        if let slot = slots.removeValue(forKey: id) {
            slot.sustainItem?.cancel()
        }
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

    /// Safe from a tab-selection callback that is not already on the main actor.
    nonisolated func scheduleRefresh() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.enqueueRefresh() }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.enqueueRefresh() }
            }
        }
    }

    // MARK: Actions

    func performTryRail() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let slot = frontSlot(), let workspace = slot.workspace else { return }
        previewedRailSlot = slot
        phase = .undo
        reanchoring = true
        anchorBeforeSwitch = slot.anchor
        model.mode = .undo
        model.rows = []
        TabLayoutSettings.setMode(.rail)
        workspace.bonsplitController.setRailOpen(true, inPane: slot.paneId)
        resizePopover()
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
        if let slot = previewedRailSlot,
           let workspace = slot.workspace,
           workspace.bonsplitController.allPaneIds.contains(slot.paneId) {
            workspace.bonsplitController.setRailOpen(false, inPane: slot.paneId)
        }
        previewedRailSlot = nil
        TabLayoutSettings.setMode(.tabs)
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
        performShowList(in: slot, workspace: workspace)
    }

    /// The count-cell callback runs after the clicked area is focused and before
    /// Bonsplit toggles its sheet. Consume only the active teaching action.
    func performShowListFromCountCell(workspace: Workspace, paneId: PaneID) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard TabLayoutSettings.mode() == .tabs else { return false }
        switch phase {
        case .live, .pending:
            break
        case .idle, .undo:
            return false
        }
        guard let slot = slots[slotID(workspace, paneId)],
              frontSlot() === slot,
              !slot.sheetOpen else { return false }
        performShowList(in: slot, workspace: workspace)
        return true
    }

    private func performShowList(in slot: Slot, workspace: Workspace) {
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
        previewedRailSlot = nil
        hidePopover()
    }

    // MARK: Popover

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        if let pending = programmaticCloseGeneration, pending != showGeneration {
            // This close is for a show we already replaced. The new show's
            // monitor stays.
            programmaticCloseGeneration = nil
            return
        }
        removeEscapeMonitor()
        if programmaticCloseGeneration != nil {
            programmaticCloseGeneration = nil
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

    @objc nonisolated private func windowKeyChanged(_ notification: Notification) {
        scheduleRefresh()
    }

    /// An area that is still overflowing when the local day rolls over records
    /// the new day. The notification is not promised to arrive on the main queue.
    @objc nonisolated private func calendarDayChanged(_ notification: Notification) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.recordOpenOverflows()
                self.scheduleRefresh()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.recordOpenOverflows()
                    self.scheduleRefresh()
                }
            }
        }
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
        pruneSlots()
        recordOpenOverflows()
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
        previewedRailSlot = nil
        hidePopover()
    }

    private func present(on anchor: NSView) {
        let popover = ensurePopover()
        if popover.isShown, shownAnchor === anchor {
            resizePopover()
            installEscapeMonitor()
            return
        }
        let wasKey = anchor.window?.isKeyWindow == true
        if popover.isShown {
            closeProgrammatically(popover)
        }
        showGeneration += 1
        shownAnchor = anchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        resizePopover()
        guard popover.isShown else { return }
        installEscapeMonitor()
        guard wasKey else { return }
        anchor.window?.makeKey()
    }

    private func hidePopover() {
        guard let popover, popover.isShown else { return }
        closeProgrammatically(popover)
        shownAnchor = nil
    }

    /// Records the show generation being closed. `popoverDidClose` for that
    /// generation is ours, including when it arrives after a newer show.
    /// A close that does not happen clears the mark immediately.
    private func closeProgrammatically(_ popover: NSPopover) {
        let generation = showGeneration
        programmaticCloseGeneration = generation
        popover.performClose(nil)
        if popover.isShown, programmaticCloseGeneration == generation {
            programmaticCloseGeneration = nil
        }
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

    /// Escape ends the offer only when the popover's own window is the one
    /// receiving it. The event is returned so a terminal still gets Escape.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                guard self.popover?.isShown == true else { return event }
                guard let popoverWindow = self.popover?.contentViewController?.view.window else { return event }
                guard event.window === popoverWindow else { return event }
                let flags = event.modifierFlags.intersection([.command, .control, .option])
                guard event.keyCode == 53, flags.isEmpty else { return event }
                self.closeFromUser()
                return event
            }
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    private func closeFromUser() {
        userClose = true
        programmaticCloseGeneration = nil
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

    private func slotID(_ workspace: Workspace, _ paneId: PaneID) -> String {
        workspace.id.uuidString + "|" + paneId.id.uuidString
    }

    private func slot(_ workspace: Workspace, _ paneId: PaneID) -> Slot {
        let id = slotID(workspace, paneId)
        if let existing = slots[id] {
            existing.workspace = workspace
            return existing
        }
        let created = Slot(workspace: workspace, paneId: paneId)
        slots[id] = created
        return created
    }

    /// Drops slots whose workspace or pane is gone, and cancels their timers.
    private func pruneSlots() {
        let stale = slots.keys.filter { key in
            guard let slot = slots[key], let workspace = slot.workspace else { return true }
            return !workspace.bonsplitController.allPaneIds.contains(slot.paneId)
        }
        for key in stale {
            slots[key]?.sustainItem?.cancel()
            slots.removeValue(forKey: key)
        }
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
                guard let manager = app.workspaceManagerFor(workspaceId: workspace.id) else { continue }
                guard manager.window === window else { continue }
                guard manager.selectedWorkspace?.id == workspace.id else { continue }
                guard workspace.bonsplitController.focusedPaneId == slot.paneId else { continue }
                return slot
            }
        }
        return nil
    }

    private func refreshCalendar() {
        policy.calendar = TabRailTipPolicy.localCalendar()
    }

    /// Starts this area's own 2s timer. A blip in another area cannot credit it.
    private func armSustain(_ slot: Slot, now: Date = Date()) {
        refreshCalendar()
        // Remember when this overflow started even if today is already
        // recorded. Otherwise a strip that stays overflowing past midnight
        // has no start time and the new day is skipped. The timer is the
        // only thing today's mark suppresses.
        let since = now
        slot.overflowSince = since
        if policy.hasRecordedOverflow(on: now) { return }
        guard slot.sustainItem == nil else { return }
        let item = DispatchWorkItem { [weak self, weak slot] in
            MainActor.assumeIsolated {
                guard let self, let slot else { return }
                slot.sustainItem = nil
                self.refreshCalendar()
                let started = slot.overflowSince ?? since
                let still = slot.overflowing && slot.workspace != nil
                if self.policy.recordSustainedOverflow(since: started, now: Date(), stillOverflowing: still) {
                    self.scheduleRefresh()
                }
            }
        }
        slot.sustainItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + TabRailTipPolicy.sustain, execute: item)
    }

    /// Records today for an area that has already been overflowing for 2s.
    /// Used when the day changes and on refresh, so a strip that stays
    /// overflowing across midnight still counts the new day. One mark per day.
    private func recordOpenOverflows(now: Date = Date()) {
        refreshCalendar()
        if policy.hasRecordedOverflow(on: now) {
            for slot in slots.values {
                slot.sustainItem?.cancel()
                slot.sustainItem = nil
            }
            return
        }
        for slot in slots.values {
            guard slot.overflowing, slot.workspace != nil, let since = slot.overflowSince else { continue }
            if policy.recordSustainedOverflow(since: since, now: now, stillOverflowing: true) {
                break
            }
        }
    }

    private func previewRows(workspace: Workspace, paneId: PaneID) -> [TabRailTipPreviewRow] {
        let bonsplitTabs = workspace.bonsplitController.tabs(inPane: paneId)
        guard !bonsplitTabs.isEmpty else { return [] }
        let selected = workspace.bonsplitController.selectedTab(inPane: paneId)?.id
        let index = bonsplitTabs.firstIndex(where: { $0.id == selected }) ?? 0
        let range = TabRailTipPreviewWindow.range(count: bonsplitTabs.count, selectedIndex: index)
        return bonsplitTabs[range].map { bonsplitTab in
            TabRailTipPreviewRow(
                id: bonsplitTab.id.uuid.uuidString,
                title: bonsplitTab.detail?.title.flatMap { $0.isEmpty ? nil : $0 } ?? bonsplitTab.title,
                ordinal: bonsplitTab.displayOrdinal,
                status: Self.statusKind(for: bonsplitTab),
                selected: bonsplitTab.id == selected
            )
        }
    }

    private static func statusKind(for bonsplitTab: Bonsplit.Tab) -> TabRailTipStatusKind? {
        if let kind = bonsplitTab.detail?.status?.kind {
            switch kind {
            case .working: return .working
            case .waiting: return .waiting
            case .flagged: return .flagged
            case .idle: return .idle
            case .cold: return .cold
            }
        }
        switch bonsplitTab.activityState {
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
                Text(String(localized: "tabRailTip.undoBody", defaultValue: "This area's tab list stays open on the left. Undo puts Tabs back."))
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
