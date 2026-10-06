import Foundation
import Bonsplit

/// Assembles the tab sheet's per-tab detail (type, subtitle, status, clocks)
/// from already-resolved inputs. Pure: no stores, no AppKit. `Workspace` gathers
/// the inputs; bonsplit only renders the result.
enum TabSheetDetailBuilder {
    /// UserDefaults key for the clock column order: a comma-separated list of
    /// clock names. Change it in one command:
    /// `defaults write com.stage11.c11 c11.panelSheet.clocks -string "launched,active"`.
    /// The setting used to be `c11.tabSheet.clocks`; reads fall back to it while
    /// the new key is unset, and it is never written or deleted.
    static let clockOrderDefaultsKey = "c11.panelSheet.clocks"
    static let legacyClockOrderDefaultsKey = "c11.tabSheet.clocks"
    /// Every clock the sheet can show. The default order is `active,seen,launched`;
    /// `touched` (last operator input), `turn`, `tools`, `tokens` and `cache`
    /// (time left on the agent's prompt cache) are opt-in through the setting.
    static let defaultClockOrder = ["active", "seen", "launched"]
    static let optInClocks = ["touched", "turn", "tools", "tokens", "cache"]

    struct Inputs {
        var panelType: TabContentType
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
        /// The `active` clock: "how long since something was added to this tab",
        /// per tab type (see `TabActivitySignals.swift`). nil renders `—`.
        var activeAt: Date?
        /// Last operator keystroke or click in the tab (`touched`).
        var touchedAt: Date?
        /// The stored moment the operator last stopped looking at the tab (`seen`,
        /// C11-243); nil if never.
        var seenAt: Date?
        /// True while the operator is looking at the tab: `seen` reads "now".
        var isBeingSeen: Bool = false
        /// Agent tabs: the current or last turn, from the transcript tail.
        var turnStartedAt: Date?
        var turnToolCalls: Int?
        var tokens: Int?
        /// The turn's end: the last agent event, used once the agent is no longer working.
        var lastAgentEventAt: Date?
        /// When set, the turn clock ends here even if the displayed activity is still running.
        var turnEndedAt: Date? = nil
        /// Journal phase clock. When `journalPhaseSinceApplies` is true, `nil` stays nil
        /// and does not fall back to the last activity time.
        var journalPhaseSinceApplies: Bool = false
        var journalPhaseSince: Date? = nil
        /// Existing unconfirmed-evidence qualification, appended to the subtitle.
        var evidenceNote: String? = nil
        /// Agent tabs: the prompt cache from the transcript tail (`cache`).
        var promptCache: PromptCacheObservation? = nil
        var now: Date = Date()
        var locale: Locale = TabSheetClockText.appLocale
    }

    static func build(_ input: Inputs) -> BonsplitTabDetail {
        var clocks: [String: Date] = [:]
        if let active = input.activeAt { clocks["active"] = active }
        if let launched = input.createdAt { clocks["launched"] = launched }
        if !input.isBeingSeen, let seen = input.seenAt { clocks["seen"] = seen }
        if let touched = input.touchedAt { clocks["touched"] = touched }
        var texts: [String: String] = [:]
        // The tab being looked at has no age to show: `seen` reads "now".
        if input.isBeingSeen {
            texts["seen"] = String(localized: "tabSheet.clock.seenNow", defaultValue: "now")
        }
        if let start = input.turnStartedAt {
            let end: Date
            if let turnEndedAt = input.turnEndedAt {
                end = turnEndedAt
            } else if input.activity == .running {
                end = input.now
            } else {
                end = input.lastAgentEventAt ?? input.now
            }
            texts["turn"] = TabSheetClockText.duration(end.timeIntervalSince(start), locale: input.locale)
            if let tools = input.turnToolCalls { texts["tools"] = String(tools) }
        }
        if let tokens = input.tokens { texts["tokens"] = TabSheetClockText.count(tokens, locale: input.locale) }
        if let cache = input.promptCache {
            texts["cache"] = promptCacheClockText(cache, now: input.now, locale: input.locale)
        }
        return BonsplitTabDetail(
            title: collapsedWhitespace(input.title),
            agentLabel: agentLabel(
                terminalKind: input.terminalKind,
                model: input.model,
                modelLabel: input.modelLabel
            ),
            agentTintHex: agentTintHex(
                terminalKind: input.terminalKind,
                model: input.model,
                modelLabel: input.modelLabel
            ),
            typeLabel: typeLabel(input.panelType),
            subtitle: subtitle(input),
            status: status(
                activity: input.activity,
                isFlagged: input.isFlagged,
                enteredAt: input.stateEnteredAt,
                stateStartedAt: input.stateStartedAt,
                flagRaisedAt: input.flagRaisedAt,
                lastActivityAt: input.lastActivityAt,
                journalPhaseSinceApplies: input.journalPhaseSinceApplies,
                journalPhaseSince: input.journalPhaseSince
            ),
            clocks: clocks,
            clockTexts: texts
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

    /// The agent chip's colour by model family, the same scheme as the Claude
    /// Code statusline: Fable purple, Opus white, Sonnet blue, Haiku pink, any
    /// other model (or harness) cyan. nil when the surface is not an agent.
    static func agentTintHex(terminalKind: String?, model: String?, modelLabel: String?) -> String? {
        guard AgentIdentityPolicy.isAgentKind(terminalKind) else { return nil }
        let name = [model, modelLabel].compactMap { $0 }.joined(separator: " ").lowercased()
        if name.contains("fable") { return "#AF5FFF" }
        if name.contains("opus") { return "#FFFFFF" }
        if name.contains("sonnet") { return "#5AA0FF" }
        if name.contains("haiku") { return "#FF80C8" }
        return "#5FD7D7"
    }

    /// The tab's kind for the sheet's Type column, shown when it hosts no agent.
    static func typeLabel(_ tabType: TabContentType) -> String {
        switch tabType {
        case .terminal:
            return String(localized: "tabSheet.type.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "tabSheet.type.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "tabSheet.type.markdown", defaultValue: "Markdown")
        }
    }

    /// The description flattened to one line; else the kind's own locator: cwd
    /// for a shell, host for a browser, path for markdown.
    static func subtitle(_ input: Inputs) -> String? {
        let base: String?
        if let description = oneLine(input.description) { base = description }
        else {
            switch input.panelType {
            case .terminal:
                base = abbreviatedPath(input.directory)
            case .browser:
                base = input.browserURL.flatMap { $0.host ?? $0.absoluteString }
            case .markdown:
                base = abbreviatedPath(input.markdownPath)
            }
        }
        let notes = [oneLine(input.evidenceNote), promptCacheNote(input)].compactMap { $0 }
        guard !notes.isEmpty else { return base }
        let note = notes.joined(separator: " · ")
        guard let base else { return note }
        return "\(base) · \(note)"
    }

    /// A waiting agent keeps its gold mark; its expired cache shows here.
    private static func promptCacheNote(_ input: Inputs) -> String? {
        guard input.activity == .waiting,
              let cache = input.promptCache, cache.isCold(at: input.now) else { return nil }
        return String(localized: "tabSheet.subtitle.cacheExpired", defaultValue: "cache expired")
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
        lastActivityAt: Date? = nil,
        journalPhaseSinceApplies: Bool = false,
        journalPhaseSince: Date? = nil
    ) -> BonsplitTabDetail.Status? {
        guard let activity else { return nil }
        if isFlagged {
            return .init(kind: .flagged, since: flagRaisedAt ?? enteredAt)
        }
        if journalPhaseSinceApplies {
            switch activity {
            case .running: return .init(kind: .working, since: journalPhaseSince)
            case .idle: return .init(kind: .idle, since: journalPhaseSince)
            case .waiting: return .init(kind: .waiting, since: journalPhaseSince)
            case .cold: break
            }
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

    /// `active` for a terminal tab: an agent's last transcript event when it has
    /// one; otherwise (plain shell, or an agent whose files say nothing) the later
    /// of scrollback growth while visible and the last command start/finish.
    /// Operator input never counts; nil renders `—`.
    static func terminalActiveAt(agentLastEventAt: Date?, outputGrowthAt: Date?, commandEdgeAt: Date?) -> Date? {
        agentLastEventAt ?? [outputGrowthAt, commandEdgeAt].compactMap { $0 }.max()
    }

    /// `38m` left while warm (`~1h 5m` for an estimate), `cold` once expired.
    /// Whole minutes: the sheet refreshes every few seconds, not every second.
    static func promptCacheClockText(_ cache: PromptCacheObservation, now: Date, locale: Locale) -> String {
        let remaining = cache.coldAt().timeIntervalSince(now)
        guard remaining > 0 else {
            return String(localized: "tabSheet.clock.cacheCold", defaultValue: "cold")
        }
        let left = remaining < 60
            ? String(localized: "tabSheet.clock.cacheUnderMinute", defaultValue: "<1m")
            : TabSheetClockText.duration((remaining / 60).rounded(.up) * 60, locale: locale)
        guard cache.isEstimate else { return left }
        return String(localized: "tabSheet.clock.cacheEstimate", defaultValue: "~\(left)")
    }

    /// Header title for the opt-in clocks (short: the column is narrow).
    static func clockTitle(_ name: String) -> String? {
        switch name {
        case "touched": return String(localized: "tabSheet.clock.touched", defaultValue: "Touched")
        case "turn": return String(localized: "tabSheet.clock.turn", defaultValue: "Turn")
        case "tools": return String(localized: "tabSheet.clock.tools", defaultValue: "Tools")
        case "tokens": return String(localized: "tabSheet.clock.tokens", defaultValue: "Tokens")
        case "cache": return String(localized: "tabSheet.clock.cache", defaultValue: "Cache")
        default: return nil
        }
    }

    /// Reads the operator/agent setting: comma-separated, unknown names are
    /// dropped by the sheet itself, an empty or missing value means the default.
    static func clockOrder(defaults: UserDefaults = .standard) -> [String] {
        // The new key wins whenever it is set; the old key is read only while it is absent.
        let key = defaults.object(forKey: clockOrderDefaultsKey) != nil
            ? clockOrderDefaultsKey
            : legacyClockOrderDefaultsKey
        // `-string "a,b"` is the documented form; `-array a b` works too.
        if let list = defaults.array(forKey: key) as? [String] {
            return parseClockOrder(list.joined(separator: ","))
        }
        guard let raw = defaults.string(forKey: key) else { return defaultClockOrder }
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
        detail.clockTexts = [:]
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
        let snapshot = TabMetadataStore.shared.getMetadata(
            workspaceId: id,
            surfaceId: panelId,
            keys: [MetadataKey.description, MetadataKey.model, MetadataKey.modelLabel, AgentModelDetector.MetadataKeys.detected]
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
        let fullTitle = resolvedTabTitle(
            panelId: panelId,
            fallback: tabTitles[panelId] ?? panel.displayTitle
        )
        func source(_ key: String) -> MetadataSource? {
            (snapshot.sources[key]?["source"] as? String).flatMap(MetadataSource.init(rawValue:))
        }
        // Agent-declared (`set-agent --model`) > detected from the session files >
        // launch stamp.
        let effectiveModel = AgentModelPrecedence.effective(
            model: snapshot.metadata[MetadataKey.model] as? String,
            modelSource: source(MetadataKey.model),
            modelLabel: snapshot.metadata[MetadataKey.modelLabel] as? String,
            labelSource: source(MetadataKey.modelLabel),
            detected: snapshot.metadata[AgentModelDetector.MetadataKeys.detected] as? String
        )
        let signals = tabSheetSignals(panel: panel, panelId: panelId, terminalKind: terminalKind)
        let legacyActivityAt = help?.lastActivityAt
            ?? TabActivityTracker.shared.lastActivity(for: panelId.uuidString)
        let journal = JournalCoordinator.shared.snapshot(tabID: panelId)
        let sheetActivity: AgentRoster.SheetActivity
        if activity == .running { sheetActivity = .running }
        else if activity == .idle { sheetActivity = .idle }
        else if activity == .waiting { sheetActivity = .waiting }
        else { sheetActivity = .other }
        let clock = journal.map {
            AgentRoster.sheetClock(phase: $0.phase, activity: sheetActivity, flagged: attention.isFlagged,
                                   historical: $0.isHistorical, sinceMs: $0.sinceMs)
        }
        let managedTurn: Date? = {
            guard let journal, journal.turnID != nil else { return nil }
            guard let ms = JournalCoordinator.shared.cachedTurnStartedMs(tabID: panelId) else { return nil }
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }()
        let turnEndedAt: Date? = {
            guard let journal, journal.turnID != nil else { return nil }
            guard journal.isHistorical || activity != .running else { return nil }
            return Date(timeIntervalSince1970: Double(journal.observedAtMs) / 1000)
        }()
        return TabSheetDetailBuilder.build(.init(
            panelType: panel.panelType,
            title: fullTitle,
            terminalKind: terminalKind,
            model: effectiveModel.model,
            modelLabel: effectiveModel.label,
            description: snapshot.metadata[MetadataKey.description] as? String,
            directory: tabDirectories[panelId],
            browserURL: (panel as? BrowserTab)?.currentURL,
            markdownPath: (panel as? MarkdownTab)?.filePath,
            activity: activity,
            isFlagged: attention.isFlagged,
            stateEnteredAt: entered,
            stateStartedAt: activity == .waiting || activity == .cold ? help?.stateStartedAt : nil,
            flagRaisedAt: attention.flagRaisedAt,
            lastActivityAt: legacyActivityAt,
            createdAt: panel.createdAt,
            activeAt: signals.activeAt,
            touchedAt: signals.touchedAt,
            seenAt: TabSeenTracker.shared.storedLastSeenAt(panelId: panelId),
            isBeingSeen: TabSeenTracker.shared.isBeingSeen(panelId: panelId),
            turnStartedAt: journal != nil ? managedTurn : signals.turnStartedAt,
            turnToolCalls: signals.turnToolCalls,
            tokens: signals.tokens,
            lastAgentEventAt: signals.lastAgentEventAt,
            turnEndedAt: turnEndedAt,
            journalPhaseSinceApplies: clock?.applies ?? false,
            journalPhaseSince: clock?.since,
            evidenceNote: journal?.isHistorical == true
                ? String(localized: "journal.evidence.unconfirmed", defaultValue: "Unconfirmed")
                : nil,
            promptCache: AgentIdentityPolicy.isAgentKind(terminalKind)
                ? AgentModelDetector.shared.signals(forSurface: panelId)?.promptCache
                : nil
        ))
    }

    /// The per-type signals behind `active`, `touched`, `turn`, `tools` and
    /// `tokens`. Plain reads of stores the panels keep up to date; no work here
    /// scales with output.
    private func tabSheetSignals(
        panel: any TabContent,
        panelId: UUID,
        terminalKind: String?
    ) -> (activeAt: Date?, touchedAt: Date?, turnStartedAt: Date?, turnToolCalls: Int?, tokens: Int?, lastAgentEventAt: Date?) {
        switch panel.panelType {
        case .terminal:
            let surface = (panel as? TerminalTab)?.surface
            let touched = surface?.lastOperatorInputAt
            // Plain terminal, or an agent whose files say nothing (Kimi, Copilot,
            // no transcript yet): output that scrolled while visible, or a command
            // starting/finishing. Hidden terminals only see command edges. Operator
            // input is never part of Active; with no signal the clock reads `—`.
            let growth = surface?.lastOutputGrowthAt
            let edge = tabShellEdgeAt[panelId]
            let plainActive = TabSheetDetailBuilder.terminalActiveAt(agentLastEventAt: nil, outputGrowthAt: growth, commandEdgeAt: edge)
            if AgentIdentityPolicy.isAgentKind(terminalKind),
               let signals = AgentModelDetector.shared.signals(forSurface: panelId) {
                let hasTurn = signals.turnStartedAt != nil
                return (
                    TabSheetDetailBuilder.terminalActiveAt(agentLastEventAt: signals.lastEventAt, outputGrowthAt: growth, commandEdgeAt: edge),
                    touched,
                    signals.turnStartedAt,
                    hasTurn ? signals.turnToolCalls : nil,
                    hasTurn ? signals.turnTokens : signals.sessionTokens,
                    signals.lastEventAt
                )
            }
            return (plainActive, touched, nil, nil, nil, nil)
        case .markdown:
            return ((panel as? MarkdownTab)?.lastContentChangeAt, nil, nil, nil, nil, nil)
        case .browser:
            let browser = panel as? BrowserTab
            return (browser?.lastLoadedAt, browser?.lastOperatorInputAt, nil, nil, nil, nil)
        }
    }

    /// Pushes the tab's sheet detail into bonsplit when anything other than a
    /// clock changed. Clocks are refreshed by `tabDetailProvider` as the sheet
    /// opens, so a stream of activity never churns the tab bar.
    func syncSurfaceTabDetailForTab(_ panelId: UUID) {
        // Nothing can show the detail unless a sheet is open in this pane;
        // opening one refreshes it, so skip the work otherwise.
        // Nothing open anywhere (the common case): no pane lookup, no work.
        guard bonsplitController.hasVisibleTabDetail,
              let paneId = paneId(forPanelId: panelId),
              bonsplitController.isTabDetailVisible(inPane: paneId),
              let bonsplitTabId = bonsplitTabIdFromTabId(panelId),
              let existing = bonsplitController.tab(bonsplitTabId),
              let detail = tabSheetDetail(panelId: panelId) else { return }
        guard TabSheetDetailBuilder.ignoringClocks(existing.detail)
                != TabSheetDetailBuilder.ignoringClocks(detail) else { return }
        bonsplitController.updateTab(bonsplitTabId, detail: .some(detail))
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
                lastActivityAt: TabActivityTracker.shared.lastActivity(for: panelId.uuidString),
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
    func tabDetailReplacingTitle(bonsplitTabId: TabID, with title: String) -> BonsplitTabDetail?? {
        guard var detail = bonsplitController.tab(bonsplitTabId)?.detail else { return nil }
        detail.title = TabSheetDetailBuilder.collapsedWhitespace(title)
        return .some(detail)
    }

    func installTabSheetDetailProviders() {
        bonsplitController.tabDetailProvider = { [weak self] bonsplitTabId in
            guard let self, let panelId = self.tabIdFromBonsplitTabId(bonsplitTabId) else { return nil }
            return self.tabSheetDetail(panelId: panelId)
        }
        bonsplitController.sheetClockOrderProvider = {
            TabSheetDetailBuilder.clockOrder()
        }
        // Titles for the opt-in clocks; `active`, `launched` and `seen` use bonsplit's own.
        bonsplitController.sheetClockTitleProvider = { name in
            TabSheetDetailBuilder.clockTitle(name)
        }
    }
}
