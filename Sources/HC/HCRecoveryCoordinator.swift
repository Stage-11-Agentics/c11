import Darwin
import Foundation

protocol HCPeerVerifying: Sendable {
    func verify(_ peer: HCPeerEvidence, configuration: HCLaunchConfiguration) async throws -> HCVerifiedPeer
    func validateOwnedState(_ configuration: HCLaunchConfiguration, coreID: String) async throws
}
extension HCBuildVerifier: HCPeerVerifying {}

protocol HCProcessObserving: Sendable {
    func hasExited(_ process: HCProcessIdentity) async -> Bool
}

struct HCKernelProcessObserver: HCProcessObserving {
    func hasExited(_ process: HCProcessIdentity) async -> Bool {
        if let current = try? HCBuildVerifier.processIdentity(process.pid) { return current != process }
        // A denied or temporarily unreadable kernel query is not exit evidence.
        return kill(process.pid, 0) == -1 && errno == ESRCH
    }
}

struct HCConnectedRuntime: Sendable {
    let connection: any HCConnection
    let verified: HCVerifiedPeer
}

/// One planned handover, never a retry loop or a signal to a core/holder.
/// The caller shares an in-flight recovery task across its session's panels.
struct HCRecoveryCoordinator: Sendable {
    let configuration: HCLaunchConfiguration
    let factory: any HCConnectionFactory
    let verifier: any HCPeerVerifying
    let launcher: any HCCoreLaunching
    let processes: any HCProcessObserving

    func recover(_ previous: HCConnectedRuntime, generation: UInt64,
                 deadlineUptimeNanoseconds deadline: UInt64 = HCMonotonic.deadline(after: HCLimits.recoverySeconds)) async throws -> HCConnectedRuntime {
        let identity = previous.verified
        if await processes.hasExited(identity.identity.process) {
            // Retry after a successful handover whose replacement failed to start.
            try await verifier.validateOwnedState(configuration, coreID: identity.identity.coreID)
        } else {
            // Revalidate the exact live endpoint immediately before its mutation.
            let current = try await verifier.verify(previous.connection.peer, configuration: configuration)
            guard current.identity.process == identity.identity.process,
                  current.identity.coreID == identity.identity.coreID else { throw HCUnavailableReason.foreignSession }
            do {
                _ = try await previous.connection.request(HCRPCRequest(method: "server.restart", params: .object([:]),
                    deadlineUptimeNanoseconds: min(deadline, HCMonotonic.deadline(after: HCLimits.connectSeconds))))
            } catch let error as HCRPCFailure {
                guard error.transmission == .possible else { throw error }
                // The reply may vanish. Actual process exit settles the handover.
            }
        }
        previous.connection.close(reason: .connectionLost)
        while !(await processes.hasExited(identity.identity.process)) {
            guard HCMonotonic.now < deadline else { throw HCUnavailableReason.recoveryRequired }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard HCMonotonic.now < deadline else { throw HCUnavailableReason.recoveryRequired }
        _ = try await launcher.start(configuration, deadlineUptimeNanoseconds: deadline)
        guard HCMonotonic.now < deadline else { throw HCUnavailableReason.recoveryRequired }
        let request = HCConnectionRequest(configuration: configuration, generation: generation,
            deadlineUptimeNanoseconds: min(deadline, HCMonotonic.deadline(after: HCLimits.connectSeconds)))
        let connection = try await factory.connect(request, verify: { peer in
            try await verifier.verify(peer, configuration: configuration)
        })
        do {
            let verified = connection.verification
            guard HCMonotonic.now < request.deadlineUptimeNanoseconds, verified.isPinnedBuild,
                  verified.identity.coreID == identity.identity.coreID,
                  verified.identity.process != identity.identity.process else { throw HCUnavailableReason.recoveryRequired }
            return HCConnectedRuntime(connection: connection, verified: verified)
        } catch {
            connection.close(reason: .recoveryRequired)
            throw error
        }
    }
}

enum HCMonotonic {
    #if DEBUG
    /// Test seam: every reading moves this far ahead, as if that much time had passed.
    nonisolated(unsafe) static var advancedForTesting: UInt64 = 0
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds &+ advancedForTesting }
    #else
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    #endif
    static func deadline(after seconds: TimeInterval) -> UInt64 {
        now + UInt64(seconds * 1_000_000_000)
    }
}

/// Return at the caller's absolute deadline even when an injected async source
/// is slow to observe cancellation. Late results never resume the caller twice.
enum HCBoundedOperation {
    static func run<Value: Sendable>(deadline: UInt64,
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard HCMonotonic.now < deadline else { throw HCUnavailableReason.deadlineExceeded }
        let state = HCDeadlineResult<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.begin(continuation)
                let work = Task {
                    do {
                        try Task.checkCancellation()
                        let value = try await operation()
                        guard HCMonotonic.now < deadline else { throw HCUnavailableReason.deadlineExceeded }
                        state.finish(.success(value))
                    }
                    catch { state.finish(.failure(error)) }
                }
                let timer = Task {
                    let now = HCMonotonic.now
                    if deadline > now {
                        do { try await Task.sleep(nanoseconds: deadline - now) }
                        catch { return }
                    }
                    state.finish(.failure(HCUnavailableReason.deadlineExceeded))
                }
                state.tasks(work, timer)
            }
        } onCancel: { state.finish(.failure(CancellationError())) }
    }
}

private final class HCDeadlineResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var running: [Task<Void, Never>] = []

    func begin(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }

    func tasks(_ work: Task<Void, Never>, _ timer: Task<Void, Never>) {
        lock.lock()
        if result != nil { lock.unlock(); work.cancel(); timer.cancel() }
        else { running = [work, timer]; lock.unlock() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let running = self.running
        self.running = []
        lock.unlock()
        for task in running { task.cancel() }
        continuation?.resume(with: result)
    }
}
