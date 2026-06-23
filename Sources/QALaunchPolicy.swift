import Foundation

/// QA / automation launch policy, parsed from the `C11_QA_LAUNCH`
/// environment variable (dual-read `CMUX_QA_LAUNCH`).
///
/// A normal interactive launch can present two blocking dialogs before the
/// operator reaches a usable window: the Agent Skills install/update
/// onboarding sheet, and the "Resume previous session?" picker. Those are
/// correct for humans but a nuisance for automated QA, which wants the GUI
/// up with no modal in the way and a deterministic resume decision.
///
/// Setting `C11_QA_LAUNCH` to any non-empty value turns **QA mode** on:
/// both dialogs are suppressed. The value selects the resume direction:
///
/// ```
///   C11_QA_LAUNCH=fresh    QA mode, start clean (no session restore)
///   C11_QA_LAUNCH=resume   QA mode, silently restore the prior session
///   C11_QA_LAUNCH=<other>  QA mode, default: fresh
///   (unset / empty)        normal interactive launch (both dialogs may show)
/// ```
///
/// The variable is read fresh from the environment each launch and never
/// persisted, so it can't leak into a later non-QA run the way a UserDefaults
/// pref would. It is intentionally not gated to debug builds — nobody sets it
/// in production, and gating would make it useless for QA against a release
/// build.
enum QALaunchPolicy: Equatable {
    /// Whether the prior session is restored once QA mode is active.
    enum Resume: Equatable {
        case fresh
        case resume
    }

    case off
    case on(Resume)

    /// Primary (authored) and legacy env var names. The c11 binary dual-reads
    /// `C11_*` / `CMUX_*`; `C11_*` is canonical and wins when both are set.
    static let primaryKey = "C11_QA_LAUNCH"
    static let legacyKey = "CMUX_QA_LAUNCH"

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> QALaunchPolicy {
        let raw = (environment[primaryKey] ?? environment[legacyKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .off }
        switch raw.lowercased() {
        case "resume", "restore":
            return .on(.resume)
        default:
            // Any other non-empty value (fresh, none, no, 0, 1, …) is QA mode
            // with a clean slate. Default-fresh keeps automation deterministic:
            // resume is the deliberate opt-in.
            return .on(.fresh)
        }
    }

    /// QA mode is active — suppress the skill-install and resume-session
    /// dialogs.
    var isActive: Bool {
        if case .on = self { return true }
        return false
    }

    /// QA mode is active and the prior session should be silently restored.
    var shouldResume: Bool {
        self == .on(.resume)
    }

    /// QA mode is active and the prior session should be skipped (clean slate).
    var shouldStartFresh: Bool {
        self == .on(.fresh)
    }
}
