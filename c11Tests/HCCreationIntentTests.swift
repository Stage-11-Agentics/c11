import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCCreationIntentTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c11-intents-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testClaimSurvivesNewStoreAndRejectsDuplicateBeforeTransmission() async throws {
        let dir = try directory()
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh), creationID: UUID(),
                                      argv: ["/bin/zsh"], environment: ["SECRET": "must-not-persist"])
        let process = HCProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        let store = HCCreationIntentStore(directory: dir)
        _ = try await store.claim(request, coreID: "core", process: process)
        let reopened = HCCreationIntentStore(directory: dir)
        let saved = try await reopened.read(panelID: request.identity.panelID)
        XCTAssertEqual(saved?.creationID, request.creationID)
        XCTAssertEqual(saved?.phase, .prepared)
        let disk = try Data(contentsOf: dir.appendingPathComponent("creation-intents.json"))
        XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("must-not-persist"))
        do {
            _ = try await reopened.claim(request, coreID: "core", process: process)
            XCTFail("A replayed request must not claim again")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .creationPending) }
    }

    func testReplacementConsumesEndOnceAndIgnoresDelayedOldCompletion() async throws {
        let store = HCCreationIntentStore(directory: try directory())
        let panel = UUID(), oldID = UUID(), newID = UUID()
        let identity = HCPanelIdentity(panelID: panel, origin: .fresh)
        let process = HCProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        _ = try await store.claim(HCCreateRequest(identity: identity, creationID: oldID, argv: ["sh"]), coreID: "core", process: process)
        try await store.markTransmitted(panelID: panel, creationID: oldID)
        let proof = HCEndEvidence(id: UUID(), creationID: oldID, revision: HCRevision(connectionGeneration: 1, sequence: 4), kind: .createRejected)
        try await store.recordEnd(panelID: panel, creationID: oldID, evidence: proof)
        _ = try await store.claim(HCCreateRequest(identity: identity, creationID: newID, argv: ["sh"]), coreID: "core", process: process)
        do { try await store.bind(panelID: panel, creationID: oldID, key: HCTerminalKey(owningCoreID: "core", localAddress: "t1")); XCTFail("Late old bind") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .staleIdentity) }
        do { _ = try await store.claim(HCCreateRequest(identity: identity, creationID: UUID(), argv: ["sh"]), coreID: "core", process: process); XCTFail("End evidence reused") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .creationPending) }
        let saved = try await store.read(panelID: panel)
        XCTAssertEqual(saved?.creationID, newID)
    }

    func testInitialInputAttemptRemainsSpentAfterCrashAndRefusal() async throws {
        let dir = try directory(), panel = UUID(), creation = UUID()
        let store = HCCreationIntentStore(directory: dir)
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: ["sh"],
            initialInput: HCInitialInput(operationID: UUID(), payload: Data("once".utf8), submitReturn: true))
        _ = try await store.claim(request, coreID: "core", process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 1))
        try await store.bind(panelID: panel, creationID: creation, key: HCTerminalKey(owningCoreID: "core", localAddress: "t1"))
        let first = try await store.claimInitialInput(panelID: panel, creationID: creation)
        XCTAssertTrue(first)
        let reopened = HCCreationIntentStore(directory: dir)
        let repeated = try await reopened.claimInitialInput(panelID: panel, creationID: creation)
        XCTAssertFalse(repeated)
        try await reopened.finishInitialInput(panelID: panel, creationID: creation, outcome: .refused(.unavailable))
        let afterRefusal = try await reopened.claimInitialInput(panelID: panel, creationID: creation)
        XCTAssertFalse(afterRefusal)
    }

    /// C11H-329: a transaction's caller resumes only after the store's lock is
    /// released, so its next transaction on another store over the same
    /// directory (another incarnation, or a store reopened as above) never
    /// finds it held. The first store's worker is held right after it resumes
    /// its caller until that caller's second-store transaction has run; had it
    /// resumed inside the locked scope, that transaction would be busy every time.
    func testATransactionsLockIsReleasedBeforeItsCallerResumes() async throws {
        let dir = try directory(), proceed = DispatchSemaphore(value: 0)
        let first = HCCreationIntentStore(directory: dir, afterDelivery: { _ = proceed.wait(timeout: .now() + 5) })
        let second = HCCreationIntentStore(directory: dir)
        defer { proceed.signal() }
        _ = try await first.read(panelID: UUID())
        var busy = false
        do { _ = try await second.read(panelID: UUID()) } catch is HCIntentStoreBusy { busy = true }
        XCTAssertFalse(busy, "the second store found the first store's finished transaction still holding the lock")
    }

    func testFailedDurabilityBarrierNeverReturnsClaim() async throws {
        let store = HCCreationIntentStore(directory: try directory(), persist: { _, _ in throw POSIXError(.ENOSPC) })
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh), creationID: UUID(), argv: ["sh"])
        do { _ = try await store.claim(request, coreID: "core", process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 1)); XCTFail("Failed write authorized run") }
        catch { XCTAssertEqual((error as? POSIXError)?.code, .ENOSPC) }
    }

    // MARK: C11H-238 (F8)

    private final class Writes: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        func persist(_ data: Data, _ file: URL) throws {
            lock.lock(); count += 1; lock.unlock()
            try HCCreationIntentStore.persistDurably(data, file)
        }
        var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A write transaction that changes nothing writes nothing; a real change
    /// is still written through the durable (fsync) path; and a document that
    /// returns to bytes this store persisted before is written again when the
    /// disk holds something else (A, then B on disk, then A: A lands). The
    /// comparison is with the bytes on disk, never with what was seen before.
    func testOnlyAChangedDocumentIsWrittenAndABAEndsAtA() async throws {
        let dir = try directory()
        let writes = Writes()
        let store = HCCreationIntentStore(directory: dir, persist: { try writes.persist($0, $1) })
        let panel = UUID(), creation = UUID()
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation,
                                      argv: ["/bin/zsh"])
        _ = try await store.claim(request, coreID: "core", process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 100))
        XCTAssertEqual(writes.total, 1)
        let file = dir.appendingPathComponent("creation-intents.json")
        // Unchanged transactions: markUncertain before transmission changes nothing.
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        for _ in 0..<5 { try await store.markUncertain(panelID: panel, creationID: creation) }
        XCTAssertEqual(writes.total, 1, "an unchanged document is not rewritten")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, modified)
        try await store.markTransmitted(panelID: panel, creationID: creation)
        XCTAssertEqual(writes.total, 2, "a real change is written")
        let b = try Data(contentsOf: file)  // transmitted
        try await store.markUncertain(panelID: panel, creationID: creation)
        XCTAssertEqual(writes.total, 3)
        let a = try Data(contentsOf: file)  // uncertain: A, persisted by this store
        XCTAssertNotEqual(a, b)
        try await store.markUncertain(panelID: panel, creationID: creation)
        XCTAssertEqual(writes.total, 3, "A again over A: nothing to write")
        // A second writer (another app incarnation) leaves B on disk.
        try b.write(to: file)
        try await store.markUncertain(panelID: panel, creationID: creation)
        XCTAssertEqual(writes.total, 4, "back to A over B: written again, though A was persisted before")
        XCTAssertEqual(try Data(contentsOf: file), a, "A is what lands")
        let saved = try await HCCreationIntentStore(directory: dir).read(panelID: panel)
        XCTAssertEqual(saved?.phase, .uncertain)
    }
}
