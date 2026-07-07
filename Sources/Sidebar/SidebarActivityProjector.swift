import Foundation

/// Coarse, derived activity classification for a workspace, computed from
/// low-level surface signals when no agent has explicitly reported status.
///
/// C11-162 (Telemetry truth): when the agent-claimed status pill goes
/// silent (expires) or was never set, the sidebar falls back to a *derived*
/// pill so the row still tells the truth about whether the workspace is
/// doing anything.
public enum SidebarActivityState: String {
    case working
    case idle
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
