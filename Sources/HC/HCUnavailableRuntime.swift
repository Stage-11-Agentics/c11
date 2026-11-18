import Foundation

/// Composition default until the live backend lands. Never launches a process,
/// authorizes a replacement, supplies a screen receipt, or claims input delivery.
struct HCUnavailableRuntime: HCSession, HCInventorySource, HCConnectionFactory, HCInputPort, HCScreenProvider {
    private var unavailableSnapshot: HCInventorySnapshot {
        HCInventorySnapshot(
            readiness: .pending(.backendNotInstalled),
            revision: HCRevision(connectionGeneration: 0, sequence: 0)
        )
    }

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        let snapshot = unavailableSnapshot
        let delivery = UnavailableDelivery()
        queue.async { if delivery.isActive { handler(snapshot) } }
        return HCObservation { delivery.cancel() }
    }

    func snapshot() async -> HCInventorySnapshot { unavailableSnapshot }
    func refresh() async -> HCInventorySnapshot { unavailableSnapshot }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle { .unresolved(identity, .backendNotInstalled) }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { .rejectedBeforeTransmission(.backendNotInstalled) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        throw HCUnavailableReason.backendNotInstalled
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { .unresolved(key, .backendNotInstalled) }
    func diagnostics() async -> HCDiagnostics { HCDiagnostics(inventory: unavailableSnapshot, unavailableReason: .backendNotInstalled) }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .refused(.backendNotInstalled) }
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection { throw HCUnavailableReason.backendNotInstalled }
    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
    // This adapter is never bound to a native surface; composition must install
    // a real input port before enabling keys/paste, so these cannot claim delivery.
    func receiveRaw(_ bytes: Data, kind: HCRawInputKind, generation: UInt64) {}
    func invalidate(generation: UInt64, reason: HCInputRefusal) {}
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
}

private final class UnavailableDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
