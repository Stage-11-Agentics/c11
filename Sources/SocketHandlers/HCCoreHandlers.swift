import Foundation

/// Installed by 2C only when the local backend is composed. This registry cannot
/// discover a default hc, start a process, or fall back to a tenant CLI.
actor HCManagedCommandEndpoint {
    static let shared = HCManagedCommandEndpoint()
    private var sessions: [HCManagedSession] = []
    func install(_ session: HCManagedSession) { sessions = [session] }
    /// C11H-67: every shard's session. A command goes to the shard its
    /// terminal's `HC_SESSION` names; the first session refuses any other.
    func install(_ sessions: [HCManagedSession]) { self.sessions = sessions }
    /// Tests only: the endpoint is process-wide, so a test that installs one removes it.
    func uninstall() { sessions = [] }
    func perform(_ command: HCManagedCommand) async throws -> HCJSONValue {
        guard let session = sessions.first(where: { $0.configuration.session == command.session }) ?? sessions.first else {
            throw HCUnavailableReason.backendNotInstalled
        }
        return try await session.managedCommand(command)
    }
}

private final class HCCommandResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<HCJSONValue, HCManagedCallFailure>?
    func set(_ value: Result<HCJSONValue, HCManagedCallFailure>) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Result<HCJSONValue, HCManagedCallFailure>? { lock.lock(); defer { lock.unlock() }; return value }
}

extension TerminalController {
    /// `hc.call`, registered in `socketWorkerV2Methods`, `socketWorkerV2Response`
    /// and `system.capabilities`. No AppKit/Ghostty state is read here. A
    /// bounded wait is confined to this connection's socket worker.
    nonisolated func v2HCCall(params: [String: Any], waitSeconds: TimeInterval = 34) -> V2CallResult {
        guard !Thread.isMainThread else { return .err(code: "hc_worker_required", message: String(localized: "hc.cli.workerRequired", defaultValue: "This hc command requires a socket worker."), data: nil) }
        let command: HCManagedCommand
        do { command = try JSONDecoder().decode(HCManagedCommand.self, from: JSONSerialization.data(withJSONObject: params)) }
        catch { return .err(code: "hc_invalid_arguments", message: String(localized: "hc.cli.invalidArguments", defaultValue: "The hc command arguments are invalid."), data: nil) }
        let result = HCCommandResponse(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { result.set(.success(try await HCManagedCommandEndpoint.shared.perform(command))) }
            catch { result.set(.failure(HCManagedCallFailure(error, mayMutate: command.verb == .run || command.verb == .restart))) }
            done.signal()
        }
        guard done.wait(timeout: .now() + waitSeconds) == .success, let value = result.get() else {
            task.cancel()
            if command.verb.isReadOnly {
                return .err(code: "hc_deadlineExceeded", message: String(localized: "hc.cli.failed", defaultValue: "The hc command could not complete."), data: ["retry_safe": true])
            }
            // This is deliberately uncertain, never a zero-transmission receipt.
            return .err(code: "hc_outcome_uncertain", message: String(localized: "hc.cli.uncertain", defaultValue: "The hc command may have taken effect. Check its result before retrying."), data: ["retry_safe": false])
        }
        switch value {
        case .success(let payload):
            do { return .ok(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload), options: [.fragmentsAllowed])) }
            catch { return .err(code: "hc_response_invalid", message: String(localized: "hc.cli.invalidResponse", defaultValue: "The hc response could not be decoded."), data: nil) }
        case .failure(let failure):
            if !failure.retrySafe {
                return .err(code: "hc_outcome_uncertain", message: String(localized: "hc.cli.uncertain", defaultValue: "The hc command may have taken effect. Check its result before retrying."),
                            data: ["retry_safe": false, "reason": failure.reason.rawValue])
            }
            return .err(code: "hc_" + failure.reason.rawValue, message: String(localized: "hc.cli.failed", defaultValue: "The hc command could not complete."), data: ["retry_safe": true])
        }
    }
}
