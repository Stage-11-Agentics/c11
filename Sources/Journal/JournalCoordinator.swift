import Foundation

/// Bridges immutable target facts and the existing exact conversation identity to disk.
/// The socket worker waits for storage, never for the main actor or a UI repaint.
final class JournalCoordinator: @unchecked Sendable {
    static let shared = JournalCoordinator()
    private let lock = NSLock()
    private let startupQueue = DispatchQueue(label: "com.stage11.c11.journal-startup", qos: .utility)
    private var targets: [UUID: UUID] = [:]
    private var snapshots: [UUID: JournalSnapshot] = [:]
    private var store: JournalStore?
    private var storageError: JournalError?
    private var started = false
    private var sink: (@Sendable (JournalSnapshot) -> Void)?

    func register(tabID: UUID, workspaceID: UUID) {
        lock.lock(); targets[tabID] = workspaceID; lock.unlock()
    }
    func remove(tabID: UUID) {
        lock.lock(); targets.removeValue(forKey: tabID); snapshots.removeValue(forKey: tabID); lock.unlock()
    }
    func snapshot(tabID: UUID) -> JournalSnapshot? {
        lock.lock(); defer { lock.unlock() }; return snapshots[tabID]
    }
    func target(tabID: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }; return targets[tabID]
    }
    func health() -> JournalError? {
        lock.lock(); let error = storageError; let store = store; lock.unlock()
        return error ?? store?.health()
    }
    func start(onProjection: @escaping @Sendable (JournalSnapshot) -> Void) {
        lock.lock()
        sink = onProjection
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        startupQueue.async { [self] in
            do {
                let store = try storage()
                for baseline in try store.baselines() {
                    if isEligible(baseline.owner) {
                        publish(JournalReplayPolicy.restored(baseline))
                    }
                }
                drain(store: store, first: true)
            } catch { setError(error) }
        }
    }

    // A single lock protects lazy initialization; no UI code takes this path.
    private let openLock = NSLock()
    private func storage() throws -> JournalStore {
        openLock.lock(); defer { openLock.unlock() }
        lock.lock(); let existing = store; lock.unlock()
        if let existing { return existing }
        let layout = try JournalStorageLayout.resolve(bundleID: Bundle.main.bundleIdentifier)
        let created = try JournalStore(layout: layout)
        lock.lock(); store = created; storageError = nil; lock.unlock()
        return created
    }

    private final class OwnershipRead: @unchecked Sendable {
        let lock = NSLock()
        var eligible = false
        func set(_ value: Bool) { lock.lock(); eligible = value; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return eligible }
    }
    func isEligible(_ owner: JournalOwner) -> Bool {
        guard !ConversationStorePolicy.isDisabled, target(tabID: owner.tabID) != nil else { return false }
        let read = OwnershipRead()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let ref = await ConversationStore.shared.active(for: owner.tabID.uuidString)
            read.set(ref?.isEligibleCausalOwner == true && ref?.kind == owner.agentKind && ref?.id == owner.sessionID)
            done.signal()
        }
        guard done.wait(timeout: .now() + .milliseconds(100)) == .success else { return false }
        return read.get()
    }

    func append(_ draft: JournalDraft, historical: Bool = false) throws -> JournalAppendResult {
        do {
            let eligible = draft.owner.map(isEligible) ?? false
            let result = try storage().append(draft: draft, context: JournalContext(eligible: eligible, historical: historical))
            if let changed = result.changedSnapshot {
                startupQueue.async { [self] in publish(changed) }
            }
            lock.lock(); storageError = nil; lock.unlock()
            return result
        } catch { setError(error); throw error }
    }

    private func publish(_ value: JournalSnapshot) {
        guard isEligible(value.owner) else { return }
        lock.lock()
        let old = snapshots[value.owner.tabID]
        guard old?.owner != value.owner || (old?.lastSequence ?? -1) <= value.lastSequence else { lock.unlock(); return }
        snapshots[value.owner.tabID] = value
        let callback = sink
        lock.unlock()
        callback?(value)
    }

    private func drain(store: JournalStore, first: Bool) {
        let counts = autoreleasepool {
            JournalSpool(layout: store.layout).drain(limit: first ? 1000 : 100, durationMs: first ? 2000 : 200,
                now: Int64(Date().timeIntervalSince1970 * 1000)) { [self] draft in
                    _ = try append(draft, historical: true)
                }
        }
        if counts.remaining {
            startupQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in drain(store: store, first: false) }
        }
    }
    private func setError(_ error: Error) {
        guard let code = error as? JournalError, [.busy, .full, .unavailable, .unsupportedVersion].contains(code) else { return }
        lock.lock(); storageError = code; lock.unlock()
    }
}
