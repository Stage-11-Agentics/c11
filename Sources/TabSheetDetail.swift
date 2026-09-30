import Foundation
import Bonsplit

/// Assembles the tab sheet's per-tab detail (agent, subtitle, status, clocks)
/// from already-resolved inputs. Pure: no stores, no AppKit. `Workspace` gathers
/// the inputs; bonsplit only renders the result.
enum TabSheetDetailBuilder {
    /// UserDefaults key for the clock column order: a comma-separated list of
    /// clock names. Change it in one command:
    /// `defaults write com.stage11.c11 c11.tabSheet.clocks -string "launched,active"`.
    static let clockOrderDefaultsKey = "c11.tabSheet.clocks"
    /// `seen` is accepted and renders `—` until last-seen tracking (C11-243) supplies it.
    static let defaultClockOrder = ["active", "launched"]

    struct Inputs {
        var panelType: PanelType
        /// Full title (custom or process title), untruncated.
        var title: String?
        /// The kind used for live agent presentation (`nil` for a plain shell).
        var terminalKind: String?
        var model: String?
        var modelLabel: String?
        var description: String?
        var directory: String?
        var browserURL: URL?
        var markdownPath: String?
        var activity: BonsplitTabActivityState?
        var isFlagged: Bool
        /// When the surface entered its current state, as the workspace saw it happen.
        var stateEnteredAt: Date?
        /// Exact start the projection knows for waiting (notification time) and cold.
        var stateStartedAt: Date?
        var flagRaisedAt: Date?
        var lastActivityAt: Date?
        var createdAt: Date?
    }

    static func build(_ input: Inputs) -> BonsplitTabDetail {
        var clocks: [String: Date] = [:]
        if let active = input.lastActivityAt { clocks["active"] = active }
        if let launched = input.createdAt { clocks["launched"] = launched }
        return BonsplitTabDetail(
            title: collapsedWhitespace(input.title),
            agentLabel: agentLabel(
                terminalKind: input.terminalKind,
                model: input.model,
                modelLabel: input.modelLabel
            ),
            subtitle: subtitle(input),
            status: status(
                activity: input.activity,
                isFlagged: input.isFlagged,
                enteredAt: input.stateEnteredAt,
                stateStartedAt: input.stateStartedAt,
                flagRaisedAt: input.flagRaisedAt,
                lastActivityAt: input.lastActivityAt
            ),
            clocks: clocks
        )
    }

    /// `Harness · model`, `Harness` when the model is unknown, nil when the
    /// surface is not a recognized agent.
    static func agentLabel(terminalKind: String?, model: String?, modelLabel: String?) -> String? {
        guard AgentIdentityPolicy.isAgentKind(terminalKind) else { return nil }
        let normalized = AgentIdentityPolicy.normalizedKind(terminalKind) ?? ""
        let harness = AgentIdentityPolicy.fallbackDisplayName(for: normalized) ?? normalized
        let shortModel = AgentChipResolver.normalizedModelLabel(modelLabel)
            ?? AgentChipResolver.shortenModel(model?.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let shortModel, !shortModel.isEmpty else { return harness }
        return "\(harness) · \(shortModel)"
    }

    /// The description flattened to one line; else the kind's own locator: cwd
    /// for a shell, host for a browser, path for markdown.
    static func subtitle(_ input: Inputs) -> String? {
        if let description = oneLine(input.description) { return description }
        switch input.panelType {
        case .terminal:
            return abbreviatedPath(input.directory)
        case .browser:
            guard let url = input.browserURL else { return nil }
            return url.host ?? url.absoluteString
        case .markdown:
            return abbreviatedPath(input.markdownPath)
        }
    }

    /// The state word and how long the state has held. Waiting counts from the
    /// notification, cold from the projection's start and flagged from the flag
    /// raise (each an exact event time when known); working and idle count from
    /// when the workspace saw the surface enter the state. Any missing time falls
    /// back to the recorded entry, and working/idle last to the last activity.
    static func status(
        activity: BonsplitTabActivityState?,
        isFlagged: Bool,
        enteredAt: Date?,
        stateStartedAt: Date?,
        flagRaisedAt: Date?,
        lastActivityAt: Date? = nil
    ) -> BonsplitTabDetail.Status? {
        guard let activity else { return nil }
        if isFlagged {
            return .init(kind: .flagged, since: flagRaisedAt ?? enteredAt)
        }
        switch activity {
        case .running: return .init(kind: .working, since: enteredAt ?? lastActivityAt)
        case .idle: return .init(kind: .idle, since: enteredAt ?? lastActivityAt)
        case .waiting: return .init(kind: .waiting, since: stateStartedAt ?? enteredAt)
        case .cold: return .init(kind: .cold, since: stateStartedAt ?? enteredAt)
        }
    }

    /// The base state a surface is in, ignoring any flag. The recorded entry
    /// tracks this only: a flag has its own time (the raise), and toggling it
    /// must not reset how long the surface has been working or idle.
    static func baseKind(activity: BonsplitTabActivityState?) -> BonsplitTabDetail.StatusKind? {
        switch activity {
        case .running: return .working
        case .idle: return .idle
        case .waiting: return .waiting
        case .cold: return .cold
        case nil: return nil
        }
    }

    /// Where the clock starts for a state first seen with no history (after a
    /// relaunch, or when a surface gains a status): the last recorded activity
    /// for working/idle, the notification or dormancy start for waiting/cold,
    /// never later than now.
    static func seededEnteredAt(
        kind: BonsplitTabDetail.StatusKind,
        now: Date,
        lastActivityAt: Date?,
        exactStart: Date?
    ) -> Date {
        switch kind {
        case .working, .idle:
            return min(now, lastActivityAt ?? now)
        case .waiting, .cold:
            return min(now, exactStart ?? lastActivityAt ?? now)
        case .flagged:
            return now
        }
    }

    /// Reads the operator/agent setting: comma-separated, unknown names are
    /// dropped by the sheet itself, an empty or missing value means the default.
    static func clockOrder(defaults: UserDefaults = .standard) -> [String] {
        // `-string "a,b"` is the documented form; `-array a b` works too.
        if let list = defaults.array(forKey: clockOrderDefaultsKey) as? [String] {
            return parseClockOrder(list.joined(separator: ","))
        }
        guard let raw = defaults.string(forKey: clockOrderDefaultsKey) else { return defaultClockOrder }
        return parseClockOrder(raw)
    }

    static func parseClockOrder(_ raw: String) -> [String] {
        let names = raw.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }
        return names.isEmpty ? defaultClockOrder : names
    }

    /// The detail without its clocks. Clocks move with every burst of output,
    /// so they refresh when a sheet opens (and on its slow tick); everything
    /// else is pushed as it changes.
    static func ignoringClocks(_ detail: BonsplitTabDetail?) -> BonsplitTabDetail? {
        guard var detail else { return nil }
        detail.clocks = [:]
        return detail
    }

    static func collapsedWhitespace(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func oneLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let flattened = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.isEmpty ? nil : flattened
    }

    private static func abbreviatedPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

/// The state a surface last entered and when.
struct TabSheetStatusEntry: Equatable {
    var kind: BonsplitTabDetail.StatusKind
    var at: Date
}

// MARK: - Workspace wiring

extension Workspace {
    /// Gathers the inputs for one tab's sheet detail. Cheap: dictionary reads
    /// and a handful of metadata keys; called when a sheet opens and on
    /// metadata/activity events, never on a timer.
    func tabSheetDetail(panelId: UUID) -> BonsplitTabDetail? {
        guard let panel = panels[panelId] else { return nil }
        let snapshot = SurfaceMetadataStore.shared.getMetadata(
            workspaceId: id,
            surfaceId: panelId,
            keys: [MetadataKey.description, MetadataKey.model, MetadataKey.modelLabel]
        )
        let activity = resolvedSurfaceTabActivityState(panelId: panelId)
        // Idempotent: makes sure the entry describes the state we are about to
        // show, whichever recorder saw (or missed) the last transition.
        recordTabSheetStatusTransition(panelId: panelId, activity: activity)
        let baseKind = TabSheetDetailBuilder.baseKind(activity: activity)
        let entered = tabSheetStatusEntered[panelId].flatMap { $0.kind == baseKind ? $0.at : nil }
        let help = resolvedAgentActivityHelp(panelId: panelId, activityState: activity)
        let attention = attentionSnapshot(panelId: panelId)
        let terminalKind = panel.panelType == .terminal ? surfaceActivityTerminalKind(panelId: panelId) : nil
        let fullTitle = resolvedPanelTitle(
            panelId: panelId,
            fallback: panelTitles[panelId] ?? panel.displayTitle
        )
        return TabSheetDetailBuilder.build(.init(
            panelType: panel.panelType,
            title: fullTitle,
            terminalKind: terminalKind,
            model: snapshot.metadata[MetadataKey.model] as? String,
            modelLabel: snapshot.metadata[MetadataKey.modelLabel] as? String,
            description: snapshot.metadata[MetadataKey.description] as? String,
            directory: panelDirectories[panelId],
            browserURL: (panel as? BrowserPanel)?.currentURL,
            markdownPath: (panel as? MarkdownPanel)?.filePath,
            activity: activity,
            isFlagged: attention.isFlagged,
            stateEnteredAt: entered,
            stateStartedAt: activity == .waiting || activity == .cold ? help?.stateStartedAt : nil,
            flagRaisedAt: attention.flagRaisedAt,
            lastActivityAt: help?.lastActivityAt
                ?? SurfaceActivityTracker.shared.lastActivity(for: panelId.uuidString),
            createdAt: panel.createdAt
        ))
    }

    /// Pushes the tab's sheet detail into bonsplit when anything other than a
    /// clock changed. Clocks are refreshed by `tabDetailProvider` as the sheet
    /// opens, so a stream of activity never churns the tab bar.
    func syncSurfaceTabDetailForPanel(_ panelId: UUID) {
        // Nothing can show the detail unless a sheet is open in this pane;
        // opening one refreshes it, so skip the work otherwise.
        // Nothing open anywhere (the common case): no pane lookup, no work.
        guard bonsplitController.hasVisibleTabDetail,
              let paneId = paneId(forPanelId: panelId),
              bonsplitController.isTabDetailVisible(inPane: paneId),
              let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId),
              let detail = tabSheetDetail(panelId: panelId) else { return }
        guard TabSheetDetailBuilder.ignoringClocks(existing.detail)
                != TabSheetDetailBuilder.ignoringClocks(detail) else { return }
        bonsplitController.updateTab(tabId, detail: .some(detail))
    }

    /// Notes a change of the surface's base state (working, idle, waiting,
    /// cold) so the sheet can say how long it has held. Cheap: one dictionary
    /// compare. A first sighting (a relaunch, a surface that just gained a
    /// status) is seeded from what c11 already knows rather than stamped "now",
    /// so an agent idle for three hours still reads three hours after a restore:
    /// the last recorded activity for working/idle, the notification or
    /// dormancy start for waiting/cold. Only a change seen from a known state
    /// is stamped with the current time.
    func recordTabSheetStatusTransition(panelId: UUID, activity: BonsplitTabActivityState?) {
        guard let kind = TabSheetDetailBuilder.baseKind(activity: activity) else {
            tabSheetStatusEntered.removeValue(forKey: panelId)
            return
        }
        let existing = tabSheetStatusEntered[panelId]
        guard existing?.kind != kind else { return }
        let now = Date()
        var at = now
        if existing == nil {
            at = TabSheetDetailBuilder.seededEnteredAt(
                kind: kind,
                now: now,
                lastActivityAt: SurfaceActivityTracker.shared.lastActivity(for: panelId.uuidString),
                exactStart: kind == .waiting || kind == .cold
                    ? resolvedAgentActivityHelp(panelId: panelId, activityState: activity)?.stateStartedAt
                    : nil
            )
        }
        tabSheetStatusEntered[panelId] = TabSheetStatusEntry(kind: kind, at: at)
    }

    /// The tab's current detail with its title replaced, for the same
    /// `updateTab` call that changes the tab's title. nil when the tab has no
    /// detail yet (opening a sheet supplies it).
    func tabDetailReplacingTitle(tabId: TabID, with title: String) -> BonsplitTabDetail?? {
        guard var detail = bonsplitController.tab(tabId)?.detail else { return nil }
        detail.title = TabSheetDetailBuilder.collapsedWhitespace(title)
        return .some(detail)
    }

    func installTabSheetDetailProviders() {
        bonsplitController.tabDetailProvider = { [weak self] tabId in
            guard let self, let panelId = self.panelIdFromSurfaceId(tabId) else { return nil }
            return self.tabSheetDetail(panelId: panelId)
        }
        bonsplitController.sheetClockOrderProvider = {
            TabSheetDetailBuilder.clockOrder()
        }
    }
}
