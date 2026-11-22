import AppKit
import Foundation

/// Close and clear-history wording for hc terminals (C11H-24, Settled 10, A13).
/// Closing an hc terminal ends its session and everything it started; the
/// confirmation says so. Exec/fallback panels keep the plain close copy,
/// because their nohup jobs survive the hangup and this copy would be untrue.
enum HCCloseCopy {
    static var panelTitle: String {
        String(localized: "hc.close.panel.title", defaultValue: "End session?")
    }

    static var panelMessage: String {
        String(
            localized: "hc.close.panel.message",
            defaultValue: "Closing this panel ends its terminal session and every process it started, including background and nohup jobs."
        )
    }

    static var panelConfirmLabel: String {
        String(localized: "hc.close.panel.confirm", defaultValue: "End Session")
    }

    /// Appended to an area, workspace or window close message when any of its
    /// panels is an hc terminal.
    static var groupSuffix: String {
        String(
            localized: "hc.close.group.message",
            defaultValue: "This ends every terminal session in it and every process they started, including background and nohup jobs."
        )
    }

    static var groupConfirmLabel: String {
        String(localized: "hc.close.group.confirm", defaultValue: "End Sessions")
    }

    static func groupMessage(_ base: String, endsSession: Bool) -> String {
        guard endsSession else { return base }
        return base.isEmpty ? groupSuffix : base + "\n\n" + groupSuffix
    }

    /// C11H-309: appended to a several-panel close (Close Others, Close to the
    /// Left or Right) when it ends `sessionCount` hc sessions, naming how many.
    static func batchSuffix(sessionCount: Int) -> String {
        sessionCount == 1
            ? String(
                localized: "hc.close.batch.message.one",
                defaultValue: "This ends 1 terminal session and every process it started, including background and nohup jobs."
            )
            : String(
                format: String(
                    localized: "hc.close.batch.message.other",
                    defaultValue: "This ends %lld terminal sessions and every process they started, including background and nohup jobs."
                ),
                sessionCount
            )
    }

    /// The batch card's confirm button: End Session or End Sessions when any
    /// session ends, else nil for the plain Close.
    static func batchConfirmLabel(sessionCount: Int) -> String? {
        switch sessionCount {
        case 0: return nil
        case 1: return panelConfirmLabel
        default: return groupConfirmLabel
        }
    }

    static func batchMessage(_ base: String, sessionCount: Int) -> String {
        guard sessionCount > 0 else { return base }
        return base + "\n\n" + batchSuffix(sessionCount: sessionCount)
    }

    /// The line the CLI prints after a panel's handle for its end outcome.
    static func endOutcomeMessage(_ outcome: HCPanelEndOutcome) -> String {
        switch outcome {
        case .ended:
            return String(
                localized: "hc.close.outcome.ended",
                defaultValue: "Ended session: every process it started, including background and nohup jobs."
            )
        case .alreadyEnded:
            return String(localized: "hc.close.outcome.alreadyEnded", defaultValue: "Session had already ended.")
        case .kept(let holder?):
            // C11H-103: name the other panel, so the operator can find it.
            return String(format: String(
                localized: "hc.close.outcome.keptBy",
                defaultValue: "Session kept: panel %1$@ (\u{201C}%2$@\u{201D}) in workspace \u{201C}%3$@\u{201D} still shows this terminal, so it was not ended."
            ), holder.panelRef ?? holder.panelID.uuidString, holder.title, holder.workspaceTitle)
        case .kept(nil):
            return String(
                localized: "hc.close.outcome.kept",
                defaultValue: "Session kept: another panel still shows this terminal, so it was not ended."
            )
        case .none:
            return String(localized: "hc.close.outcome.none", defaultValue: "No hc session to end.")
        case .pending(.appCarriesScope?):
            // C11H-415: a c11 app opened from this terminal would end with it.
            return String(
                localized: "hc.close.outcome.pendingAppCarriesScope",
                defaultValue: "End held: a c11 app was opened from this terminal and would quit with it. c11 ends the session once that app is gone."
            )
        case .pending:
            return String(
                localized: "hc.close.outcome.pending",
                defaultValue: "End pending: hc has not yet confirmed the session's processes ended. c11 keeps the request and finishes it when hc answers."
            )
        }
    }

    /// Clear-history on an hc terminal clears this view only (X.4: the pin has
    /// no primitive to clear hc's own history).
    static var clearHistoryNotDurable: String {
        String(
            localized: "hc.clearHistory.notDurable",
            defaultValue: "Cleared this view only. hc keeps this terminal's history, so it returns after c11 restarts or reconnects."
        )
    }
}

/// C11H-415: what a close tells the operator, read from its ends' outcomes
/// rather than from the request. The End Session tip says the sessions ended,
/// so it waits for `.ended`. An end a c11 app holds keeps its terminal running
/// with no panel; its notice comes from the end coordinator itself
/// (`HCHeldEndNotices`), for as long as the hold lasts.
enum HCCloseOutcomeReport {
    /// Seconds a close waits for its ends before it offers the tip. hc's own
    /// end takes up to about 3 s when a job ignores the hangup.
    static let settleSeconds: TimeInterval = 5

    struct Report: Equatable {
        /// Live sessions the close ended: the End Session tip's count.
        var endedLive = 0
        /// Ends a c11 app holds.
        var heldByApp = 0
    }

    /// `live`: the panels whose session was still running when closed.
    static func report(_ outcomes: [UUID: HCPanelEndOutcome], live: Set<UUID>) -> Report {
        Report(endedLive: live.filter { outcomes[$0] == .ended }.count,
               heldByApp: outcomes.values.filter { $0 == .pending(.appCarriesScope) }.count)
    }

    /// The notice for `count` ends a c11 app holds. It names no closed panel,
    /// since a restored hold has none to name.
    static func heldNotice(count: Int) -> (title: String, body: String) {
        let title = String(localized: "hc.close.heldNotice.title", defaultValue: "End held")
        guard count > 1 else {
            return (title, String(
                localized: "hc.close.heldNotice.one",
                defaultValue: "One session is held: a c11 app was opened from its terminal and would quit with it. c11 ends it once that app is gone."
            ))
        }
        return (title, String(format: String(
            localized: "hc.close.heldNotice.other",
            defaultValue: "%lld sessions keep running: a c11 app was opened from their terminals and would quit with them. c11 ends them once that app is gone."
        ), count))
    }

    /// After a close requested its ends: waits for them off main, then offers
    /// the End Session tip for what ended, on an operator's close only.
    @MainActor
    static func observe(panelIDs: [UUID], live: Set<UUID>, coordinator: HCExplicitEndCoordinator,
                        workspaceID: UUID?, window: NSWindow?) {
        guard !panelIDs.isEmpty, !live.isEmpty else { return }
        // Read here: the task below runs outside the socket command.
        guard SocketCommandContext.current == nil else { return }
        weak var target = window
        Task { @MainActor in
            let report = report(await coordinator.outcomes(for: panelIDs, timeout: settleSeconds), live: live)
            if report.endedLive > 0 { C11TipCenter.noteSessionsEnded(count: report.endedLive, window: target) }
        }
    }
}

/// C11H-417: the "End held" notice as it stands in the store.
struct HCHeldEndNoticeRecord: Equatable {
    let id: UUID
    let workspaceID: UUID
    let body: String
    let isRead: Bool
}

/// C11H-417: where the "End held" notice lives. One workspace-level notice of
/// its own kind (`.heldEnd`) for every end c11 holds right now.
@MainActor
protocol HCHeldEndNoticeSink: AnyObject {
    func current() -> HCHeldEndNoticeRecord?
    func isOpen(_ workspaceID: UUID) -> Bool
    /// The active window's selected workspace, else any window's; nil when none is open.
    func anyOpenWorkspace() -> UUID?
    /// A fresh unread notice in that workspace's held slot; its banner and sound follow the dial.
    func post(workspaceID: UUID, title: String, body: String)
    /// The notice moved to that workspace with no banner, read or unread as it was.
    func place(workspaceID: UUID, title: String, body: String, isRead: Bool)
    /// New text in place, no banner; its Notification Center copies are retired.
    func update(id: UUID, title: String, body: String)
    /// Gone, with its Notification Center copies.
    func remove(id: UUID)
    /// The app is quitting: nothing is posted or moved.
    var isQuitting: Bool { get }
}

/// C11H-417: the one owner of the "End held" notice, fed by the end
/// coordinator (`HCCarrierHoldChange`), so every held end is shown however it
/// came to be held: at a close, later (after a reconnect), or restored at
/// launch. The rule:
/// - every new hold reaches the operator once, as an unread notice (one
///   notice for all current holds, counting them);
/// - a notice the operator read or cleared stays that way until a new hold;
///   a release only rewords it quietly, or removes it with the last hold;
/// - it moves only when its workspace or window is gone (quietly, read or
///   unread as it was), and waits while no window is open;
/// - its Notification Center copies never outlive its text.
@MainActor
final class HCHeldEndNotices {
    static let shared = HCHeldEndNotices(sink: HCStoreHeldEndNoticeSink())

    private(set) var held: Set<UUID> = []
    private let sink: HCHeldEndNoticeSink
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    /// A new hold the operator has not been told of yet.
    private var owed = false
    /// Where the notice was last put.
    private var placedIn: UUID?
    /// Whether the operator had read it when it was last seen.
    private var lastSeenRead = false
    /// A close took the notice (`capture` saw it just before the clear), so its
    /// absence is a move. With no record and no such close, the operator (or
    /// an agent) cleared it.
    private var captured = false
    /// Cleared by the operator: it stays cleared until a new hold.
    private var dismissed = false
    private var reassertScheduled = false

    /// `schedule` runs work on a later main turn, so holds found together are told once.
    init(sink: HCHeldEndNoticeSink,
         schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
             DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
         }) {
        self.sink = sink
        self.schedule = schedule
    }

    func apply(_ change: HCCarrierHoldChange) {
        switch change {
        case .held(let panelID):
            guard held.insert(panelID).inserted else { return }
            owed = true
            // Holds that arrive together (End All over several) post once.
            guard !reassertScheduled else { return }
            reassertScheduled = true
            schedule { [weak self] in
                self?.reassertScheduled = false
                self?.reassert()
            }
        case .released(let panelID):
            guard held.remove(panelID) != nil else { return }
            reassert()
        }
    }

    /// Called just before a close clears a workspace's or window's notices:
    /// when the notice is there, its going is a move, read or unread as it is.
    func capture() {
        guard let existing = sink.current() else { return }
        lastSeenRead = existing.isRead
        placedIn = existing.workspaceID
        captured = true
    }

    /// Puts the notice in step with the rule. Idempotent.
    func reassert() {
        guard !sink.isQuitting else { return }
        let existing = sink.current()
        if let existing {
            lastSeenRead = existing.isRead
            captured = false
        }
        guard !held.isEmpty else {
            if let existing { sink.remove(id: existing.id) }
            placedIn = nil
            owed = false
            captured = false
            dismissed = false
            return
        }
        let notice = HCCloseOutcomeReport.heldNotice(count: held.count)
        if owed {
            let here = [existing?.workspaceID, placedIn].compactMap { $0 }.first { sink.isOpen($0) }
            guard let target = here ?? sink.anyOpenWorkspace() else { return }
            // The held slot replaces a record in its own workspace in one step.
            if let existing, existing.workspaceID != target { sink.remove(id: existing.id) }
            sink.post(workspaceID: target, title: notice.title, body: notice.body)
            placedIn = target
            owed = false
            captured = false
            dismissed = false
            lastSeenRead = false
            return
        }
        guard !dismissed else { return }
        if let existing {
            if sink.isOpen(existing.workspaceID) {
                placedIn = existing.workspaceID
                if existing.body != notice.body { sink.update(id: existing.id, title: notice.title, body: notice.body) }
                return
            }
            // Its workspace closed without clearing it: it moves.
            sink.remove(id: existing.id)
            captured = true
        } else if !captured {
            // No record, and no close took it: the operator cleared it.
            dismissed = true
            return
        }
        guard let target = sink.anyOpenWorkspace() else { return }
        sink.place(workspaceID: target, title: notice.title, body: notice.body, isRead: lastSeenRead)
        placedIn = target
        captured = false
    }
}

/// C11H-417: the notification store as the held-end notice's home.
@MainActor
final class HCStoreHeldEndNoticeSink: HCHeldEndNoticeSink {
    private var store: TerminalNotificationStore? { AppDelegate.shared?.notificationStore }

    func current() -> HCHeldEndNoticeRecord? {
        guard let notice = store?.notifications.first(where: { $0.origin == .heldEnd && $0.surfaceId == nil }) else { return nil }
        return HCHeldEndNoticeRecord(id: notice.id, workspaceID: notice.workspaceId, body: notice.body, isRead: notice.isRead)
    }

    func isOpen(_ workspaceID: UUID) -> Bool {
        AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceID) != nil
    }

    /// A window a CLI opens never becomes the active one, and after the last
    /// window closed there is no active manager at all: any window's then.
    func anyOpenWorkspace() -> UUID? {
        guard let app = AppDelegate.shared else { return nil }
        return app.workspaceManager?.selectedWorkspaceId ?? app.workspaceManager?.workspaces.first?.id
            ?? app.allMainWindowWorkspaces().first?.id
    }

    func post(workspaceID: UUID, title: String, body: String) {
        store?.addNotification(workspaceId: workspaceID, surfaceId: nil, title: title, subtitle: "", body: body,
                               origin: .heldEnd)
    }

    func place(workspaceID: UUID, title: String, body: String, isRead: Bool) {
        store?.placeHeldEndNotice(workspaceId: workspaceID, title: title, body: body, isRead: isRead)
    }

    func update(id: UUID, title: String, body: String) { store?.updateText(id: id, title: title, body: body) }

    func remove(id: UUID) { store?.remove(id: id) }

    var isQuitting: Bool { AppDelegate.shared?.isTerminatingApp ?? false }
}
