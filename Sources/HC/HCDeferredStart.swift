import Foundation
import os

/// What an hc start needed and did not have when a native surface came up.
/// The raw value is the token the log line carries.
enum HCStartBlocker: String, Equatable, Sendable {
    case ghosttyConfig = "ghostty_config"
    case launchSnapshot = "launch_snapshot"
    case hcConfiguration = "hc_configuration"
    case surfaceGrid = "surface_grid"
}

/// How one try at starting a panel's hc session ended.
enum HCStartOutcome: Equatable {
    /// The create/attach task was launched; nothing more to retry.
    case started
    /// An input is missing; try again when it may have arrived.
    case blocked(HCStartBlocker)
    /// The surface or session this try belonged to is gone; drop it.
    case abandoned
}

/// Holds an hc start that could not run yet and re-runs it when an input may
/// have arrived. The native surface is created once, so a start that only
/// tried once (the grid is empty until the surface has been sized, and a view
/// created before layout is not sized yet) left the panel with a live surface,
/// no attachment, and every send refused. Callers say when to retry; this type
/// never polls and never creates a terminal itself: a retry only repeats the
/// same one start, which creates at most once through the session.
@MainActor
final class HCDeferredStart {
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.start")

    private var held: (@MainActor (Bool) -> HCStartOutcome)?
    /// Whether the start began as the app's first native surface. Decided once
    /// at `begin` and handed to every retry: the app-wide first-surface flag is
    /// consumed when the surface is created, so a retry that read it again would
    /// launch the first terminal with the regular command instead of the
    /// operator's `initial-command`.
    private var firstSurface = false
    private(set) var blocker: HCStartBlocker?
    private let report: (HCStartBlocker) -> Void

    /// Each time the blocker changes (first block, or a different input is
    /// missing) the condition is logged, then `onBlocked` runs.
    init(onBlocked: @escaping (HCStartBlocker) -> Void = { _ in }) {
        self.report = { blocker in
            Self.logger.notice("hc.start.blocked condition=\(blocker.rawValue, privacy: .public)")
            onBlocked(blocker)
        }
    }

    var isWaiting: Bool { held != nil }

    /// Try now; keep the attempt for a retry if it names a missing input.
    /// `firstSurface` is fixed here for this start and passed to every try.
    func begin(firstSurface: Bool, _ attempt: @escaping @MainActor (_ firstSurface: Bool) -> HCStartOutcome) {
        held = attempt
        self.firstSurface = firstSurface
        run()
    }

    /// An input may now be present (the surface got its first size, the
    /// configuration was installed). A no-op when nothing is waiting.
    func inputsMayHaveArrived() {
        guard held != nil else { return }
        run()
    }

    /// The surface or session is going away.
    func cancel() {
        held = nil
        blocker = nil
    }

    private func run() {
        guard let attempt = held else { return }
        switch attempt(firstSurface) {
        case .started, .abandoned:
            held = nil
            blocker = nil
        case .blocked(let missing):
            if blocker != missing {
                blocker = missing
                report(missing)
            }
        }
    }
}
