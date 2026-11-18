import Foundation
import OSLog

/// A fresh install that cannot start its core must say why. Every step of the
/// core-start path reports its outcome here with a public reason, so
/// `log show --predicate 'subsystem == "com.stage11.c11"'` names the step that
/// stopped it. The sink is injectable so the reasons are testable.
struct HCCoreStartLog: Sendable {
    enum Step: String, Sendable {
        case activation          // app start: launch configuration and services
        case connect             // first connect / start-or-connect as a whole
        case launchPin           // pinned core file: present, private, hash
        case launchState         // existing core.lock/core.json ownership
        case launchDirectories   // run and state directories: private, unlinked
        case launchConfig        // c11's own herdr-core/config.toml (A1)
        case launchFileLimit     // file descriptor floor
        case launchSpawn         // spawning `serve` as this process's child (A1)
        case launchExit          // the core answers before the deadline, or its exit status
    }

    enum Outcome: String, Sendable { case ok, failed }

    struct Event: Equatable, Sendable {
        let step: Step
        let outcome: Outcome
        /// Stable token: an HCUnavailableReason name, or posix:<code>, or error:<type>.
        let reason: String?
        let detail: String?
    }

    let emit: @Sendable (Event) -> Void

    init(emit: @escaping @Sendable (Event) -> Void) { self.emit = emit }

    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.launch")

    static let live = HCCoreStartLog { event in
        let detail = event.detail ?? "-"
        switch event.outcome {
        case .ok:
            logger.info("hc_core_start step=\(event.step.rawValue, privacy: .public) outcome=ok detail=\(detail, privacy: .public)")
        case .failed:
            logger.error("hc_core_start step=\(event.step.rawValue, privacy: .public) outcome=failed reason=\(event.reason ?? "unknown", privacy: .public) detail=\(detail, privacy: .public)")
        }
    }

    func passed(_ step: Step, detail: String? = nil) {
        emit(Event(step: step, outcome: .ok, reason: nil, detail: detail))
    }

    func failed(_ step: Step, _ error: Error, detail: String? = nil) {
        emit(Event(step: step, outcome: .failed, reason: Self.reason(error), detail: detail))
    }

    static func reason(_ error: Error) -> String {
        if let reason = error as? HCUnavailableReason { return reason.rawValue }
        if let failure = error as? HCRPCFailure { return failure.reason.rawValue }
        if let posix = error as? POSIXError { return "posix:\(posix.code.rawValue)" }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return "posix:\(ns.code)" }
        return "error:\(type(of: error))"
    }
}
