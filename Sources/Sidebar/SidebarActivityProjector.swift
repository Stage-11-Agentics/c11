import Foundation

/// Coarse, derived activity classification for a workspace, computed from
/// low-level surface signals when no agent has explicitly reported status.
///
/// C11-162 (Telemetry truth): when the agent-claimed status pill goes
/// silent (expires) or was never set, the sidebar falls back to a *derived*
/// pill so the row still tells the truth about whether the workspace is
/// doing anything.
public enum SidebarActivityState: String, Sendable {
    case working
    case idle
}

/// Visual rollup states for a workspace sidebar card. This is deliberately a
/// presentation projection over the existing per-surface liveness and
/// notification truth; it is not a new metadata or persistence state.
enum WorkspacePulseState: String, CaseIterable {
    case waiting
    case working
    case idle
    case cold
}

struct WorkspacePulseAgent: Equatable, Identifiable {
    let surfaceId: UUID
    let state: WorkspacePulseState
    let context: WorkspacePulseAgentContext?
    /// Forward-compatible attention modifiers. C11-184 owns the metadata and
    /// signal primitives that will populate them; false defaults preserve the
    /// current lifecycle-only projection until that wiring lands.
    let flagged: Bool
    let suppressed: Bool
    let flagReason: String?

    var id: UUID { surfaceId }

    init(
        surfaceId: UUID,
        state: WorkspacePulseState,
        context: WorkspacePulseAgentContext?,
        flagged: Bool = false,
        suppressed: Bool = false,
        flagReason: String? = nil
    ) {
        self.surfaceId = surfaceId
        self.state = state
        self.context = context
        self.flagged = flagged
        self.suppressed = suppressed
        self.flagReason = flagReason
    }

    /// Suppression is a lifecycle projection, and a flag wins when both
    /// modifiers are present. The stored `state` remains the source truth for
    /// C11-184; renderers and summary counts consume this presented value.
    var presentedState: WorkspacePulseState {
        SurfaceAttentionSnapshot.presentedState(
            state,
            flagged: flagged,
            suppressed: suppressed
        )
    }
}

struct WorkspacePulseSummary: Equatable {
    let flaggedCount: Int
    let waitingCount: Int
    let workingCount: Int
    let idleCount: Int
    let coldCount: Int
    let agents: [WorkspacePulseAgent]
    let terminalCount: Int
    let browserCount: Int
    let documentCount: Int

    init(
        flaggedCount: Int = 0,
        waitingCount: Int,
        workingCount: Int,
        idleCount: Int,
        coldCount: Int,
        agents: [WorkspacePulseAgent] = [],
        terminalCount: Int = 0,
        browserCount: Int = 0,
        documentCount: Int = 0
    ) {
        self.flaggedCount = flaggedCount
        self.waitingCount = waitingCount
        self.workingCount = workingCount
        self.idleCount = idleCount
        self.coldCount = coldCount
        self.agents = agents
        self.terminalCount = terminalCount
        self.browserCount = browserCount
        self.documentCount = documentCount
    }

    var dominant: WorkspacePulseState {
        if flaggedCount > 0 {
            return agents.first(where: \.flagged)?.presentedState ?? .waiting
        }
        if waitingCount > 0 { return .waiting }
        if workingCount > 0 { return .working }
        if idleCount > 0 { return .idle }
        return .cold
    }

    func count(for state: WorkspacePulseState) -> Int {
        switch state {
        case .waiting: return waitingCount
        case .working: return workingCount
        case .idle: return idleCount
        case .cold: return coldCount
        }
    }

    func agentCount(for state: WorkspacePulseState) -> Int {
        agents.lazy.filter { $0.presentedState == state }.count
    }

    func visibleWaitingOverflow(visibleAgents: [WorkspacePulseAgent]) -> Int {
        max(
            0,
            agentCount(for: .waiting)
                - visibleAgents.lazy.filter { $0.presentedState == .waiting }.count
        )
    }

    var relevantAgents: [WorkspacePulseAgent] {
        let flagged = agents.filter(\.flagged)
        let unflagged = WorkspacePulseState.allCases.flatMap { state in
            agents.filter { !$0.flagged && $0.presentedState == state }
        }
        return flagged + unflagged
    }
}

/// Compact identity for the exact agent surface whose unread notification is
/// driving a workspace into `waiting`. The pulse owns only one detail line, so
/// normalize title-bar metadata into a stable single-line title + subtitle.
struct WorkspacePulseAgentContext: Equatable {
    let title: String
    let subtitle: String?
}

enum WorkspacePulseAgentContextProjector {
    static func project(title: String?, subtitle: String?) -> WorkspacePulseAgentContext? {
        let title = normalized(title)
        let subtitle = normalized(subtitle)
        if let title {
            return WorkspacePulseAgentContext(title: title, subtitle: subtitle)
        }
        if let subtitle {
            return WorkspacePulseAgentContext(title: subtitle, subtitle: nil)
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

enum WorkspacePulseProjector {
    static func project(
        hasWorkspaceDemand: Bool,
        agents: [WorkspacePulseAgent],
        terminalCount: Int,
        browserCount: Int = 0,
        documentCount: Int = 0
    ) -> WorkspacePulseSummary {
        var waiting = agents.filter { $0.presentedState == .waiting }.count
        if hasWorkspaceDemand && waiting == 0 {
            waiting = 1
        }
        return WorkspacePulseSummary(
            flaggedCount: agents.lazy.filter(\.flagged).count,
            waitingCount: waiting,
            workingCount: agents.filter { $0.presentedState == .working }.count,
            idleCount: agents.filter { $0.presentedState == .idle }.count,
            coldCount: agents.filter { $0.presentedState == .cold }.count,
            agents: agents,
            terminalCount: max(0, terminalCount),
            browserCount: max(0, browserCount),
            documentCount: max(0, documentCount)
        )
    }

    /// Rolls exact agent-surface states up with workspace-level operator
    /// demand. A surface-less notification still makes the workspace demand
    /// attention, represented as one waiting item without inventing an agent.
    static func project(
        hasWorkspaceDemand: Bool,
        surfaceStates: [WorkspacePulseState]
    ) -> WorkspacePulseSummary {
        var waiting = surfaceStates.filter { $0 == .waiting }.count
        if hasWorkspaceDemand && waiting == 0 {
            waiting = 1
        }
        return WorkspacePulseSummary(
            waitingCount: waiting,
            workingCount: surfaceStates.filter { $0 == .working }.count,
            idleCount: surfaceStates.filter { $0 == .idle }.count,
            coldCount: surfaceStates.filter { $0 == .cold }.count
        )
    }
}

/// The single pill the sidebar status region should render for a row, after
/// reconciling an (optional) explicit agent-reported status against the
/// (optional) derived activity fallback.
public struct SidebarVisiblePill: Equatable {
    /// User-facing text (already resolved/localized).
    public let text: String
    /// Decay stage that drives visual emphasis.
    public let stage: SidebarDecayStage
    /// True when this pill was derived from low-level activity rather than
    /// claimed by an agent — the UI styles it visually distinct.
    public let isDerived: Bool

    public init(text: String, stage: SidebarDecayStage, isDerived: Bool) {
        self.text = text
        self.stage = stage
        self.isDerived = isDerived
    }
}

/// Pure projector deciding what the sidebar status region shows for one row.
///
/// It reconciles the explicit agent-claimed status (with its age) against a
/// derived activity fallback. The decay thresholds are passed in so this
/// stays a pure function (fully unit-testable, no `UserDefaults`).
public enum SidebarActivityProjector {
    static let workingTextKey = "sidebar.derivedActivity.working"
    static let idleTextKey = "sidebar.derivedActivity.idle"

    /// Localized text for a derived activity state.
    static func derivedText(_ state: SidebarActivityState) -> String {
        switch state {
        case .working:
            return String(localized: "sidebar.derivedActivity.working", defaultValue: "Working")
        case .idle:
            return String(localized: "sidebar.derivedActivity.idle", defaultValue: "Idle")
        }
    }

    /// Decide the single visible pill for a row.
    ///
    /// - `explicitText` / `explicitAgeSeconds` are `nil` when the agent has
    ///   set no explicit sidebar status.
    /// - `derived` is `nil` when the workspace's derived activity is unknown.
    ///
    /// Rules:
    /// - No explicit → derived pill (`isDerived == true`) if a derived state
    ///   is present, else `nil`.
    /// - Explicit age `< expiry` → explicit pill, stage `fresh` (`< stale`)
    ///   or `stale`.
    /// - Explicit age `>= expiry` → derived pill (`isDerived == true`) if a
    ///   derived state is present, else the explicit pill with stage
    ///   `.expired`.
    static func project(
        explicitText: String?,
        explicitAgeSeconds: Double?,
        derived: SidebarActivityState?,
        staleSeconds: Double,
        expirySeconds: Double
    ) -> SidebarVisiblePill? {
        // No explicit status → derived takeover (or nothing).
        guard let explicitText, !explicitText.isEmpty else {
            guard let derived else { return nil }
            return SidebarVisiblePill(
                text: derivedText(derived),
                stage: .fresh,
                isDerived: true
            )
        }

        let age = explicitAgeSeconds ?? 0
        let stage = SidebarStalenessSettings.stage(
            ageSeconds: age,
            staleSeconds: staleSeconds,
            expirySeconds: expirySeconds
        )

        // Explicit is fresh or stale (still within expiry) → show it.
        if stage != .expired {
            return SidebarVisiblePill(text: explicitText, stage: stage, isDerived: false)
        }

        // Explicit has expired → derived takes over if we have it, else the
        // explicit pill is shown grayed as expired.
        if let derived {
            return SidebarVisiblePill(
                text: derivedText(derived),
                stage: .fresh,
                isDerived: true
            )
        }
        return SidebarVisiblePill(text: explicitText, stage: .expired, isDerived: false)
    }
}
