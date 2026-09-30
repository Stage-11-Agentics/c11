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
    static let defaultClockOrder = ["active", "launched"]
    /// Names the sheet can render. `seen` renders `—` until C11-243 supplies it.
    static let knownClocks: Set<String> = ["active", "launched", "seen"]

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
                stateStartedAt: input.stateStartedAt,
                flagRaisedAt: input.flagRaisedAt
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

    static func status(
        activity: BonsplitTabActivityState?,
        isFlagged: Bool,
        stateStartedAt: Date?,
        flagRaisedAt: Date?
    ) -> BonsplitTabDetail.Status? {
        guard let activity else { return nil }
        if isFlagged {
            return .init(kind: .flagged, since: flagRaisedAt ?? stateStartedAt)
        }
        let kind: BonsplitTabDetail.StatusKind
        switch activity {
        case .running: kind = .working
        case .waiting: kind = .waiting
        case .idle: kind = .idle
        case .cold: kind = .cold
        }
        return .init(kind: kind, since: stateStartedAt)
    }

    /// Reads the operator/agent setting: comma-separated, unknown names are
    /// dropped by the sheet itself, an empty or missing value means the default.
    static func clockOrder(defaults: UserDefaults = .standard) -> [String] {
        guard let raw = defaults.string(forKey: clockOrderDefaultsKey) else { return defaultClockOrder }
        return parseClockOrder(raw)
    }

    static func parseClockOrder(_ raw: String) -> [String] {
        let names = raw.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }
        return names.isEmpty ? defaultClockOrder : names
    }

    /// The detail without its time-varying parts: the clocks, and the `since`
    /// of working/idle (measured from the last activity, so it moves with every
    /// burst of output). Those refresh when the sheet opens; everything else is
    /// pushed as it changes, so a stream of activity never churns the tab bar.
    static func ignoringClocks(_ detail: BonsplitTabDetail?) -> BonsplitTabDetail? {
        guard var detail else { return nil }
        detail.clocks = [:]
        if let kind = detail.status?.kind, kind == .working || kind == .idle {
            detail.status?.since = nil
        }
        return detail
    }

    private static func collapsedWhitespace(_ raw: String?) -> String? {
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
            stateStartedAt: help?.stateStartedAt,
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
        guard let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId),
              let detail = tabSheetDetail(panelId: panelId) else { return }
        guard TabSheetDetailBuilder.ignoringClocks(existing.detail)
                != TabSheetDetailBuilder.ignoringClocks(detail) else { return }
        bonsplitController.updateTab(tabId, detail: .some(detail))
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
