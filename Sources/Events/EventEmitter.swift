import Foundation

/// Process-wide facade for the c11 events stream (C11-163). `EventEmitter.shared`
/// is callable from **any** thread — main-actor emit sites (surface create/close,
/// workspace select, waiting edges) and off-main queues (metadata stores, the
/// mailbox dispatcher) alike. The underlying `EventLog` owns all threading, so
/// emitting is a cheap envelope build + a fire-and-forget `append`; no emit site
/// ever blocks and none needs to hop threads.
///
/// Initialize eagerly and early via `start()` (from `applicationDidFinishLaunching`,
/// on main) so the first-use state-dir resolution + `log.opened` marker land
/// before any surface-creation or metadata path can emit (amendment K). Calls
/// before `start()`, or when disabled, are silent no-ops.
final class EventEmitter {

    static let shared = EventEmitter()

    /// Canonical metadata keys that produce a `metadata.changed` event in v1.
    /// `progress` is deliberately excluded — it is the highest-frequency
    /// canonical key and would flood the stream (amendment G); it can be added
    /// later behind explicit coalescing. Matches the SPEC EVT-2 named set
    /// (status/title/description) minus progress.
    static let canonicalMetadataEventKeys: Set<String> = ["status", "title", "description"]

    private let lock = NSLock()
    private var log: EventLog?
    private var instanceId: String = ""
    private var enabled = false

    private init() {}

    // MARK: - Lifecycle

    /// Resolves the per-instance log path, mints the instance id, opens the log,
    /// and writes the `log.opened` marker. Idempotent; safe to call once on main
    /// at launch. Disabled under XCTest (host suites must not write real logs)
    /// unless a test injected a log via `startForTesting`.
    func start() {
        lock.lock()
        if enabled || log != nil {
            lock.unlock()
            return
        }
        if Self.isRunningUnderXCTest() {
            lock.unlock()
            return
        }
        lock.unlock()

        // Resolve outside the lock — StateDirectoryMigration does disk I/O.
        guard let state = try? EventLogLayout.defaultStateURL() else { return }
        let instance = EventLogLayout.makeInstanceId()
        let url = EventLogLayout.logURL(state: state, instance: instance)
        let newLog = EventLog(url: url, instance: instance)

        lock.lock()
        guard log == nil else { lock.unlock(); return }
        log = newLog
        instanceId = instance
        enabled = true
        lock.unlock()

        newLog.open()
    }

    /// Test seam: install a caller-provided log + instance and enable emission.
    func startForTesting(log: EventLog, instance: String) {
        lock.lock()
        self.log = log
        self.instanceId = instance
        self.enabled = true
        lock.unlock()
    }

    /// Test seam: tear down so the next `startForTesting` starts clean.
    func resetForTesting() {
        lock.lock()
        log = nil
        instanceId = ""
        enabled = false
        lock.unlock()
    }

    /// Flush the underlying log (tests / shutdown).
    func flush() {
        currentLog()?.flush()
    }

    // MARK: - Emit helpers (v1 taxonomy)

    func emitSurfaceCreated(
        workspace: UUID,
        surface: UUID,
        kind: String,
        title: String? = nil
    ) {
        var payload: [String: Any] = ["kind": kind]
        if let title { payload["title"] = title }
        emit(.surfaceCreated, workspace: workspace, surface: surface, payload: payload)
    }

    func emitSurfaceClosed(workspace: UUID, surface: UUID) {
        emit(.surfaceClosed, workspace: workspace, surface: surface)
    }

    func emitWorkspaceSelected(previous: UUID?, selected: UUID) {
        var payload: [String: Any] = [:]
        if let previous { payload["previous"] = previous.uuidString }
        emit(.workspaceSelected, workspace: selected, payload: payload)
    }

    /// `scope` is "surface" or "pane"; `source` is the `MetadataSource` raw
    /// value stringified by the caller (the pure envelope never names the enum).
    /// `prior` is optional — the surface store does not retain it for free.
    func emitMetadataChanged(
        scope: String,
        workspace: UUID,
        surface: UUID,
        key: String,
        value: Any?,
        prior: Any?,
        source: String
    ) {
        var payload: [String: Any] = [
            "scope": scope,
            "key": key,
            "source": source,
        ]
        if let value, JSONSerialization.isValidJSONObject([value]) || value is String || value is NSNumber {
            payload["value"] = value
        }
        if let prior, JSONSerialization.isValidJSONObject([prior]) || prior is String || prior is NSNumber {
            payload["prior"] = prior
        }
        emit(.metadataChanged, workspace: workspace, surface: surface, payload: payload)
    }

    func emitWaiting(entered: Bool, workspace tabId: UUID, surface: UUID?) {
        emit(entered ? .waitingEntered : .waitingLeft, workspace: tabId, surface: surface)
    }

    func emitMailboxAccepted(
        workspace: UUID,
        id: String,
        from: String,
        to: String?,
        topic: String?
    ) {
        var payload: [String: Any] = ["id": id, "from": from]
        if let to { payload["to"] = to }
        if let topic { payload["topic"] = topic }
        emit(.mailboxAccepted, workspace: workspace, payload: payload)
    }

    func emitMailboxDelivered(
        workspace: UUID,
        id: String,
        recipient: String,
        surface: UUID?
    ) {
        emit(
            .mailboxDelivered,
            workspace: workspace,
            surface: surface,
            payload: ["id": id, "recipient": recipient]
        )
    }

    /// TEL seam (C11-162): the derived working/idle activity state. If TEL's
    /// derived-liveness signal has not landed, this stays an unused stub call
    /// site that TEL wires later — the event type ships now so consumers can key
    /// on it. `state` is "working" or "idle".
    func emitDerivedLiveness(workspace: UUID, surface: UUID, state: String) {
        emit(
            .livenessDerived,
            workspace: workspace,
            surface: surface,
            payload: ["state": state]
        )
    }

    // MARK: - Core

    private func emit(
        _ type: EventEnvelope.EventType,
        workspace: UUID? = nil,
        surface: UUID? = nil,
        pane: UUID? = nil,
        payload: [String: Any] = [:]
    ) {
        // Capture ts + snapshot the log under the lock; build + append outside.
        lock.lock()
        guard enabled, let log else { lock.unlock(); return }
        let instance = instanceId
        lock.unlock()

        let envelope = EventEnvelope(
            type: type,
            instance: instance,
            ts: Date(),
            workspace: workspace?.uuidString,
            surface: surface?.uuidString,
            pane: pane?.uuidString,
            payload: payload
        )
        log.append(envelope)
    }

    private func currentLog() -> EventLog? {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    // MARK: - Test detection

    private static func isRunningUnderXCTest() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        return false
    }
}
