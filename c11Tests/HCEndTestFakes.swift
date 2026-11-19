import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-24 test doubles: a scriptable hc session (records every end/resolve)
/// and an in-memory pending-end store. Shared by the logic and host targets.
final class HCEndFakeSession: HCSession, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HCInventorySnapshot) -> Void)?
    private var handlerQueue: DispatchQueue?
    private var resolveScript: [UUID: [HCLifecycle]] = [:]
    private var endScript: [HCTerminalKey: [HCEndResult]] = [:]
    private(set) var endCalls: [HCTerminalKey] = []
    private(set) var resolveCalls: [HCPanelIdentity] = []

    func scriptResolve(_ panelID: UUID, _ results: HCLifecycle...) {
        lock.lock(); resolveScript[panelID, default: []].append(contentsOf: results); lock.unlock()
    }

    func scriptEnd(_ key: HCTerminalKey, _ results: HCEndResult...) {
        lock.lock(); endScript[key, default: []].append(contentsOf: results); lock.unlock()
    }

    var ends: [HCTerminalKey] {
        lock.lock(); defer { lock.unlock() }; return endCalls
    }

    var resolves: [HCPanelIdentity] {
        lock.lock(); defer { lock.unlock() }; return resolveCalls
    }

    func emit(_ snapshot: HCInventorySnapshot) {
        lock.lock()
        let handler = self.handler
        let queue = handlerQueue
        lock.unlock()
        queue?.async { handler?(snapshot) }
    }

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        lock.lock()
        self.handler = handler
        handlerQueue = queue
        lock.unlock()
        return HCObservation { [weak self] in
            self?.lock.lock(); self?.handler = nil; self?.lock.unlock()
        }
    }

    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        lock.lock()
        resolveCalls.append(identity)
        var queue = resolveScript[identity.panelID] ?? []
        let next = queue.isEmpty ? HCLifecycle.unresolved(identity, .inventoryPending) : queue.removeFirst()
        resolveScript[identity.panelID] = queue
        lock.unlock()
        return next
    }

    func end(_ key: HCTerminalKey) async -> HCEndResult {
        lock.lock()
        endCalls.append(key)
        var queue = endScript[key] ?? []
        let next = queue.isEmpty ? HCEndResult.unresolved(key, .coreUnreachable) : queue.removeFirst()
        endScript[key] = queue
        lock.unlock()
        return next
    }

    func create(_ request: HCCreateRequest) async -> HCCreateResult { .rejectedBeforeTransmission(.backendNotInstalled) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        throw HCUnavailableReason.backendNotInstalled
    }
    func diagnostics() async -> HCDiagnostics {
        HCDiagnostics(inventory: HCInventorySnapshot(readiness: .pending(.backendNotInstalled), revision: HCRevision(connectionGeneration: 0, sequence: 0)))
    }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .refused(.backendNotInstalled) }
}

final class HCEndMemoryStore: HCPendingEndStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [HCPendingEndRecord]
    init(_ records: [HCPendingEndRecord] = []) { self.records = records }
    func load() -> [HCPendingEndRecord] { lock.lock(); defer { lock.unlock() }; return records }
    func save(_ records: [HCPendingEndRecord]) { lock.lock(); self.records = records; lock.unlock() }
    var saved: [HCPendingEndRecord] { load() }
}

/// C11H-307: every terminal a test host creates is a persistent hc terminal
/// (the app activates hc at launch). A test about the exec-shell path, or
/// about hc routing with a known key, pins its panel here before the surface
/// starts, instead of depending on what the test host's live core does.
@MainActor
extension TerminalSurface {
    /// Run this surface as a non-persistent exec shell (local PTY, local
    /// pending-text queue, ready at native create), the path 1.x tests assume.
    func useExecShellForTesting(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(surface, "Pin a test panel's hc path before its surface starts", file: file, line: line)
        hcSession?.detachSurface()
        installHCSessionForTesting(HCPanelSession(
            identity: HCPanelIdentity(panelID: id, persistence: .nonpersistent, origin: .fresh),
            session: HCUnavailableRuntime(), registrar: { _, _ in }))
    }

    /// Give this surface a persistent hc identity with a key on `session`
    /// (default `core-test/<panel id>`, unique per panel).
    @discardableResult
    func usePersistentHCForTesting(session: any HCSession, key: HCTerminalKey? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) -> HCPanelIdentity {
        XCTAssertNil(surface, "Pin a test panel's hc path before its surface starts", file: file, line: line)
        hcSession?.detachSurface()
        let identity = HCPanelIdentity(
            panelID: id, key: key ?? HCTerminalKey(owningCoreID: "core-test", localAddress: id.uuidString),
            persistence: .persistent, origin: .restored)
        installHCSessionForTesting(HCPanelSession(identity: identity, session: session, registrar: { _, _ in }))
        return identity
    }
}
