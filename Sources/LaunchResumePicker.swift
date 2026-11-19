import AppKit
import Foundation

/// Launch-time resume policy (C11H-38, words shared with C11-559).
///
/// c11 resumes the previous session by default: live hc terminals come back
/// and ended conversations resume once (C11H-5), with no question asked.
/// Settings > General > "On launch" has three values, stored under
/// `c11.launch.resumePolicy` (the same key and values as c11):
/// - `always` "Resume previous session" (default)
/// - `ask` "Ask which workspaces to resume": restore everything, adopt every
///   live terminal, then offer the ended sessions in an inline banner
///   (resume all, choose, not now). It never blocks restore or the socket
///   (C11H-39); the old pre-restore sheet is gone.
/// - `never` "Start fresh": an empty window; no live hc terminal is ended, each
///   still-running one goes to the Recovered workspace (the existing orphan
///   path, `HCRecoveredTerminalController`), and ended conversations are not
///   resumed.
/// Holding Option while the app launches chooses (`ask`) for that launch only;
/// Option and Shift together start fresh for that launch only. Neither asks a
/// question before restore, which is what held the socket at `not_ready`
/// (C11H-39). `C11_QA_LAUNCH` wins over all of it.

enum LaunchResumePolicy: String, CaseIterable {
    case always
    case ask
    case never

    static let defaultsKey = "c11.launch.resumePolicy"

    /// Show "Ask which workspaces to resume" in the menu, and honor a stored
    /// `ask`. One switch so c11 can drop it if the operator says so; with it
    /// off a stored or imported `ask` reads as `always`.
    nonisolated static let offersAskOption = true

    /// Unset, empty, a typo and (when hidden) `ask` all resume.
    static func current(defaults: UserDefaults = .standard) -> LaunchResumePolicy {
        let raw = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case LaunchResumePolicy.never.rawValue: return .never
        case LaunchResumePolicy.ask.rawValue: return offersAskOption ? .ask : .always
        default: return .always
        }
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Why a launch did not resume everything automatically.
enum LaunchFreshReason: Equatable {
    /// Option was held while the app launched; this launch only.
    case optionHeld
    /// Option and Shift were held: start fresh, this launch only.
    case optionShiftHeld
    /// "On launch" is set in Settings.
    case setting
    /// `C11_QA_LAUNCH=fresh`; automation, never reported to the operator.
    case qaLaunch
}

enum LaunchResumeDecision: Equatable {
    /// Restore the session; live terminals return and ended conversations
    /// resume once (C11H-5).
    case resume
    /// Restore everything and adopt every live terminal, but hold ended
    /// conversations until the operator chooses in the banner.
    case ask(LaunchFreshReason)
    /// "Start fresh": the snapshot is not applied. Running hc terminals are
    /// never ended; the recovered-orphans path puts them in "Recovered".
    case startFresh(LaunchFreshReason)

    var restoresSession: Bool {
        switch self {
        case .resume, .ask: return true
        case .startFresh: return false
        }
    }

    /// Whether ended conversations resume on their own.
    var resumesConversations: Bool { self == .resume }
}

@MainActor
enum LaunchResumePicker {
    /// What this launch does with the previous session.
    ///
    /// - `C11_QA_LAUNCH` wins over everything: `resume` resumes, `fresh`
    ///   restores nothing. An automated run is never changed by a stray key
    ///   or by the operator's setting.
    /// - Option and Shift held: start fresh for this launch.
    /// - Option held: offer the choice for this launch (`ask`).
    /// - Otherwise the stored setting decides, and the default is resume.
    ///
    /// `nonisolated`: pure value logic, callable off-main by tests.
    nonisolated static func decide(
        qa: QALaunchPolicy,
        persisted: LaunchResumePolicy,
        optionHeld: Bool,
        shiftHeld: Bool = false
    ) -> LaunchResumeDecision {
        switch qa {
        case .on(.resume): return .resume
        case .on(.fresh): return .startFresh(.qaLaunch)
        case .off:
            if optionHeld && shiftHeld { return .startFresh(.optionShiftHeld) }
            if optionHeld {
                return LaunchResumePolicy.offersAskOption ? .ask(.optionHeld) : .startFresh(.optionHeld)
            }
            switch persisted {
            case .always: return .resume
            case .ask: return .ask(.setting)
            case .never: return .startFresh(.setting)
            }
        }
    }

    /// Filter `snapshot.windows[*].tabManager.workspaces` to only those
    /// whose UUID is in `keep`. Empty windows (all workspaces dropped)
    /// are themselves dropped so the operator doesn't get a phantom
    /// blank window. Returns `nil` when the filter empties the snapshot
    /// completely; the caller treats `nil` the same as `.skipAll`.
    static func filtered(
        snapshot: AppSessionSnapshot,
        keep: Set<UUID>
    ) -> AppSessionSnapshot? {
        var newWindows: [SessionWindowSnapshot] = []
        for window in snapshot.windows {
            let kept = window.workspaceManager.workspaces.filter { keep.contains($0.id) }
            guard !kept.isEmpty else { continue }
            var newWindow = window
            // Reanchor selectedWorkspaceIndex to a kept workspace —
            // dropping arbitrary workspaces can leave the index pointing
            // at a position that no longer exists, which the restore
            // path treats as "no selection" (focus reconcile schedules a
            // fallback). Map the prior selected ID to the new index, or
            // fall back to the first kept workspace.
            let priorSelectedId: UUID? = {
                if let idx = window.workspaceManager.selectedWorkspaceIndex,
                   idx >= 0,
                   idx < window.workspaceManager.workspaces.count {
                    return window.workspaceManager.workspaces[idx].id
                }
                return nil
            }()
            let newSelectedIndex = priorSelectedId.flatMap { id in
                kept.firstIndex { $0.id == id }
            } ?? 0
            newWindow.workspaceManager = SessionWorkspaceManagerSnapshot(
                selectedWorkspaceIndex: newSelectedIndex,
                workspaces: kept,
                workspaceGroups: window.workspaceManager.workspaceGroups,
                workspaceGroupMetadata: window.workspaceManager.workspaceGroupMetadata,
                workspaceRootOrder: window.workspaceManager.workspaceRootOrder
            )
            newWindows.append(newWindow)
        }
        guard !newWindows.isEmpty else { return nil }
        return AppSessionSnapshot(
            version: snapshot.version,
            createdAt: snapshot.createdAt,
            windows: newWindows,
            focusHistory: snapshot.focusHistory,
            panelLineageNodes: snapshot.panelLineageNodes
        )
    }
}
