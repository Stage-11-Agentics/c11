import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure tests for `ConversationRef`, `SurfaceConversations`, and the
/// reconciliation rule used by `ConversationStore`.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class ConversationRefTests: XCTestCase {

    // MARK: - Codable round-trip

    func testRefCodableRoundTripPreservesAllFields() throws {
        let original = ConversationRef(
            kind: "claude-code",
            id: "abc12345-ef67-890a-bcde-f0123456789a",
            placeholder: false,
            cwd: "/Users/foo/proj",
            capturedAt: Date(timeIntervalSince1970: 123_456.789),
            capturedVia: .hook,
            state: .alive,
            diagnosticReason: "matched cwd + mtime after claim",
            payload: ["model": .string("claude-opus-4-7")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationRef.self, from: data)
        XCTAssertEqual(decoded.kind, original.kind)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.placeholder, original.placeholder)
        XCTAssertEqual(decoded.cwd, original.cwd)
        XCTAssertEqual(decoded.capturedAt.timeIntervalSince1970,
                       original.capturedAt.timeIntervalSince1970, accuracy: 0.0001)
        XCTAssertEqual(decoded.capturedVia, original.capturedVia)
        XCTAssertEqual(decoded.state, original.state)
        XCTAssertEqual(decoded.diagnosticReason, original.diagnosticReason)
        XCTAssertEqual(decoded.payload, original.payload)
    }

    func testRefCodableRoundTripWithNilOptionals() throws {
        let original = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:foo:bar",
            placeholder: true,
            cwd: nil,
            capturedAt: Date(timeIntervalSince1970: 0),
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationRef.self, from: data)
        XCTAssertNil(decoded.cwd)
        XCTAssertNil(decoded.diagnosticReason)
        XCTAssertNil(decoded.payload)
        XCTAssertTrue(decoded.placeholder)
    }

    func testSurfaceConversationsCodableEmitsHistoryArrayExplicitly() throws {
        let surface = SurfaceConversations(active: nil, history: [])
        let data = try JSONEncoder().encode(surface)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"history\":[]"),
                      "history must be written as empty array, not omitted; got: \(json)")
    }

    // MARK: - CaptureSource priority

    func testCaptureSourcePriorityOrder() {
        XCTAssertGreaterThan(CaptureSource.runtimeEnv.priority, CaptureSource.hook.priority)
        XCTAssertGreaterThan(CaptureSource.hook.priority, CaptureSource.scrape.priority)
        XCTAssertGreaterThan(CaptureSource.scrape.priority, CaptureSource.manual.priority)
        XCTAssertGreaterThan(CaptureSource.manual.priority, CaptureSource.wrapperClaim.priority)
    }

    func testCaptureEvidenceTierSeparatesCausalFromInferred() {
        XCTAssertEqual(CaptureSource.runtimeEnv.evidenceTier, .causal)
        XCTAssertEqual(CaptureSource.hook.evidenceTier, .causal)
        XCTAssertEqual(CaptureSource.scrape.evidenceTier, .inferred)
        XCTAssertEqual(CaptureSource.manual.evidenceTier, .inferred)
        XCTAssertEqual(CaptureSource.wrapperClaim.evidenceTier, .placeholder)
    }

    func testQuarantineAndRuntimeEnvRoundTripAreBackwardCompatibleAdditions() throws {
        let original = ConversationRef(
            kind: "codex",
            id: "aaaa1111-2222-3333-4444-555566667777",
            capturedVia: .runtimeEnv,
            state: .unknown,
            quarantineReason: .conflictingCausalIdentity
        )
        let decoded = try JSONDecoder().decode(
            ConversationRef.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.capturedVia, .runtimeEnv)
        XCTAssertEqual(decoded.quarantineReason, .conflictingCausalIdentity)
        XCTAssertTrue(decoded.isQuarantined)
    }

    // MARK: - Reconciliation rule

    func testReconciliationLatestCapturedAtWins() {
        let older = ConversationRef(
            kind: "claude-code",
            id: "aaaa1111-2222-3333-4444-555566667777",
            capturedAt: Date(timeIntervalSince1970: 1000),
            capturedVia: .scrape,
            state: .alive
        )
        let newer = ConversationRef(
            kind: "claude-code",
            id: "bbbb1111-2222-3333-4444-555566667777",
            capturedAt: Date(timeIntervalSince1970: 2000),
            capturedVia: .scrape,
            state: .alive
        )
        XCTAssertTrue(ConversationStore._testShouldReplace(existing: older, candidate: newer))
        XCTAssertFalse(ConversationStore._testShouldReplace(existing: newer, candidate: older))
    }

    func testReconciliationCloseTimeBreaksTieBySourcePriority() {
        let now = Date()
        let scrapeRef = ConversationRef(
            kind: "claude-code",
            id: "aaaa1111-2222-3333-4444-555566667777",
            capturedAt: now,
            capturedVia: .scrape,
            state: .alive
        )
        let hookRef = ConversationRef(
            kind: "claude-code",
            id: "bbbb1111-2222-3333-4444-555566667777",
            capturedAt: now.addingTimeInterval(0.1), // within close-time window
            capturedVia: .hook,
            state: .alive
        )
        XCTAssertTrue(ConversationStore._testShouldReplace(existing: scrapeRef, candidate: hookRef),
                      "hook should outrank scrape on close timestamps")
        XCTAssertFalse(ConversationStore._testShouldReplace(existing: hookRef, candidate: scrapeRef),
                       "scrape must NOT displace hook on close timestamps")
    }

    func testReconciliationWrapperClaimNeverDisplacesNonWrapperClaim() {
        let now = Date()
        let scrapeRef = ConversationRef(
            kind: "claude-code",
            id: "aaaa1111-2222-3333-4444-555566667777",
            capturedAt: now,
            capturedVia: .scrape,
            state: .alive
        )
        let laterClaim = ConversationRef(
            kind: "claude-code",
            id: "wrapper-claim:foo",
            placeholder: true,
            capturedAt: now.addingTimeInterval(1_000_000), // far in the future
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        XCTAssertFalse(
            ConversationStore._testShouldReplace(existing: scrapeRef, candidate: laterClaim),
            "wrapper-claim must never replace a confirmed scrape, even much later"
        )
    }

    func testReconciliationWrapperClaimDisplacesOlderWrapperClaim() {
        let older = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:foo:1",
            placeholder: true,
            capturedAt: Date(timeIntervalSince1970: 1000),
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        let newer = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:foo:2",
            placeholder: true,
            capturedAt: Date(timeIntervalSince1970: 2000),
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        XCTAssertTrue(ConversationStore._testShouldReplace(existing: older, candidate: newer),
                      "wrapper-claim CAN replace an older wrapper-claim (re-launch in same surface)")
    }

    func testReconciliationManualOutranksWrapperClaim() {
        let now = Date()
        let claim = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:foo",
            placeholder: true,
            capturedAt: now,
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        let manual = ConversationRef(
            kind: "codex",
            id: "aaaa1111-2222-3333-4444-555566667777",
            capturedAt: now.addingTimeInterval(0.1),
            capturedVia: .manual,
            state: .alive
        )
        XCTAssertTrue(ConversationStore._testShouldReplace(existing: claim, candidate: manual))
    }

    func testInferredEvidenceNeverDisplacesCausalRegardlessOfTimestamp() {
        let causal = ConversationRef(
            kind: "codex",
            id: "aaaa1111-2222-3333-4444-555566667777",
            capturedAt: Date(timeIntervalSince1970: 1),
            capturedVia: .runtimeEnv,
            state: .alive
        )
        let inferred = ConversationRef(
            kind: "codex",
            id: "bbbb1111-2222-3333-4444-555566667777",
            capturedAt: Date(timeIntervalSince1970: 9_999_999),
            capturedVia: .scrape,
            state: .alive
        )
        XCTAssertFalse(ConversationStore._testShouldReplace(existing: causal, candidate: inferred))
        XCTAssertTrue(ConversationStore._testShouldReplace(existing: inferred, candidate: causal))
    }

    // MARK: - Store actor end-to-end

    func testStoreClaimThenPushReplacesPlaceholder() async {
        let store = ConversationStore()
        let cwd = "/tmp/proj"
        await store.claim(
            surfaceId: "S1",
            kind: "codex",
            cwd: cwd,
            placeholderId: "wrapper-claim:S1:1"
        )
        let pushed = await store.push(
            surfaceId: "S1",
            kind: "codex",
            id: "aaaa1111-2222-3333-4444-555566667777",
            source: .scrape,
            cwd: cwd,
            state: .alive
        )
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.id, pushed.id)
        XCTAssertFalse(active?.placeholder ?? true)
    }

    func testStoreSecondClaimDoesNotRegressRealId() async {
        let store = ConversationStore()
        let cwd = "/tmp/proj"
        await store.push(
            surfaceId: "S1",
            kind: "codex",
            id: "aaaa1111-2222-3333-4444-555566667777",
            source: .scrape,
            cwd: cwd,
            state: .alive
        )
        await store.claim(
            surfaceId: "S1",
            kind: "codex",
            cwd: cwd,
            placeholderId: "wrapper-claim:S1:reissue"
        )
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.id, "aaaa1111-2222-3333-4444-555566667777",
                       "second wrapper-claim must not regress a confirmed scrape id")
        XCTAssertEqual(active?.capturedVia, .scrape)
    }

    func testExpiredClaimDoesNotMutateStore() async {
        let store = ConversationStore()
        let expiresAt = Date().addingTimeInterval(0.02)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let result = await store.claim(
            surfaceId: "S-expired",
            kind: "codex",
            cwd: "/tmp/proj",
            placeholderId: "wrapper-claim:S-expired",
            expiresAt: expiresAt
        )
        XCTAssertEqual(result, .expired)
        let expiredActive = await store.active(for: "S-expired")
        XCTAssertNil(expiredActive)
    }

    func testRuntimeEnvIdempotenceStickinessAndSameSurfaceNewLifecycle() async {
        let store = ConversationStore()
        let firstId = "aaaa1111-2222-3333-4444-555566667777"
        let nextId = "bbbb1111-2222-3333-4444-555566667777"
        let first = await store.captureRuntimeEnv(
            surfaceId: "S1", id: firstId, cwd: "/tmp/proj"
        )
        XCTAssertEqual(first.outcome, .accepted)
        let again = await store.captureRuntimeEnv(
            surfaceId: "S1", id: firstId, cwd: "/tmp/proj"
        )
        XCTAssertEqual(again.outcome, .idempotent)

        _ = await store.push(
            surfaceId: "S1",
            kind: "codex",
            id: nextId,
            source: .scrape,
            capturedAt: Date().addingTimeInterval(10_000)
        )
        let afterInferred = await store.active(for: "S1")
        XCTAssertEqual(afterInferred?.id, firstId)

        let replacement = await store.captureRuntimeEnv(
            surfaceId: "S1", id: nextId, cwd: "/tmp/proj"
        )
        XCTAssertEqual(replacement.outcome, .accepted)
        let afterReplacement = await store.active(for: "S1")
        XCTAssertEqual(afterReplacement?.id, nextId)
    }

    func testConflictingCausalOwnersQuarantineEverySurface() async {
        let store = ConversationStore()
        let id = "aaaa1111-2222-3333-4444-555566667777"
        _ = await store.captureRuntimeEnv(surfaceId: "S1", id: id, cwd: "/a")
        let conflict = await store.captureRuntimeEnv(surfaceId: "S2", id: id, cwd: "/b")
        XCTAssertEqual(conflict.outcome, .quarantinedConflict)
        let s1 = await store.active(for: "S1")
        let s2 = await store.active(for: "S2")
        XCTAssertEqual(s1?.quarantineReason, .conflictingCausalIdentity)
        XCTAssertEqual(s2?.quarantineReason, .conflictingCausalIdentity)
    }

    func testCausalOwnerWinsAndQuarantinesInferredDuplicate() async {
        let store = ConversationStore()
        let id = "aaaa1111-2222-3333-4444-555566667777"
        _ = await store.push(
            surfaceId: "S-inferred", kind: "codex", id: id, source: .scrape
        )
        _ = await store.captureRuntimeEnv(surfaceId: "S-causal", id: id, cwd: "/b")
        let inferred = await store.active(for: "S-inferred")
        let causal = await store.active(for: "S-causal")
        XCTAssertEqual(inferred?.quarantineReason, .displacedByCausalOwner)
        XCTAssertNil(causal?.quarantineReason)
    }

    func testSeedQuarantinesAllInferredDuplicateOwners() async {
        let id = "aaaa1111-2222-3333-4444-555566667777"
        let ref = ConversationRef(
            kind: "codex", id: id, capturedVia: .scrape, state: .suspended
        )
        let store = ConversationStore()
        let audit = await store.seed(from: [
            "S1": SurfaceConversations(active: ref),
            "S2": SurfaceConversations(active: ref)
        ])
        XCTAssertEqual(audit.quarantinedSurfaceIds, ["S1", "S2"])
        let s1 = await store.active(for: "S1")
        let s2 = await store.active(for: "S2")
        XCTAssertEqual(s1?.quarantineReason, .duplicateInferredIdentity)
        XCTAssertEqual(s2?.quarantineReason, .duplicateInferredIdentity)
    }

    func testSuspendAllAliveTransitionsState() async {
        let store = ConversationStore()
        await store.push(
            surfaceId: "S1",
            kind: "claude-code",
            id: "aaaa1111-2222-3333-4444-555566667777",
            source: .hook,
            state: .alive
        )
        await store.suspendAllAlive()
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .suspended)
    }

    func testMarkAllUnknownTransitionsAfterCrash() async {
        let store = ConversationStore()
        await store.push(
            surfaceId: "S1",
            kind: "claude-code",
            id: "aaaa1111-2222-3333-4444-555566667777",
            source: .hook,
            state: .alive
        )
        await store.markAllUnknown(reason: "crash recovery")
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .unknown)
        XCTAssertEqual(active?.diagnosticReason, "crash recovery")
    }

    func testTombstoneSetsState() async {
        let store = ConversationStore()
        await store.push(
            surfaceId: "S1",
            kind: "claude-code",
            id: "aaaa1111-2222-3333-4444-555566667777",
            source: .hook,
            state: .alive
        )
        await store.tombstone(surfaceId: "S1", reason: "operator ended")
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .tombstoned)
        XCTAssertEqual(active?.diagnosticReason, "operator ended")
    }

    func testClearWipesSurface() async {
        let store = ConversationStore()
        await store.push(
            surfaceId: "S1",
            kind: "codex",
            id: "aaaa1111-2222-3333-4444-555566667777",
            source: .scrape,
            state: .alive
        )
        await store.clear(surfaceId: "S1")
        let active = await store.active(for: "S1")
        XCTAssertNil(active)
    }
}
