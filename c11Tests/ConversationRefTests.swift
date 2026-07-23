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
        let pushedResult = await store.push(
            surfaceId: "S1",
            kind: "codex",
            id: "aaaa1111-2222-3333-4444-555566667777",
            source: .scrape,
            cwd: cwd,
            state: .alive
        )
        guard let pushed = pushedResult else {
            return XCTFail("scrape is an allowed generic push source")
        }
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.id, pushed.id)
        XCTAssertFalse(active?.placeholder ?? true)
    }

    func testStorePushRejectsReservedSourcesWithoutMutation() async {
        for source in [CaptureSource.runtimeEnv, .wrapperClaim] {
            let store = ConversationStore()
            let result = await store.push(
                surfaceId: "S-reserved",
                kind: "codex",
                id: "aaaa1111-2222-3333-4444-555566667777",
                source: source,
                state: .alive
            )
            XCTAssertNil(result)
            let active = await store.active(for: "S-reserved")
            let snapshot = await store.snapshot()
            XCTAssertNil(active)
            XCTAssertTrue(snapshot.isEmpty)
        }
    }

    func testPlainLaunchClaimInvalidatesPriorExactLifecycle() async {
        let store = ConversationStore()
        let cwd = "/tmp/proj"
        _ = await store.captureRuntimeEnv(
            surfaceId: "S1",
            id: "aaaa1111-2222-3333-4444-555566667777",
            cwd: cwd,
            capturedAt: Date().addingTimeInterval(60)
        )
        await store.claim(
            surfaceId: "S1",
            kind: "codex",
            cwd: cwd,
            placeholderId: "wrapper-claim:S1:reissue"
        )
        let active = await store.active(for: "S1")
        XCTAssertTrue(active?.placeholder == true)
        XCTAssertEqual(active?.capturedVia, .wrapperClaim)
        XCTAssertEqual(
            active?.payload?[ConversationLifecyclePayloadKey.invalidatedConversationID],
            .string("aaaa1111-2222-3333-4444-555566667777")
        )

        let latePriorRollout = ScrapeCandidate(
            id: "aaaa1111-2222-3333-4444-555566667777",
            filePath: "/tmp/late-a.jsonl",
            mtime: Date().addingTimeInterval(60),
            size: 1,
            cwd: cwd
        )
        let eligible = CodexStrategy().eligibleCandidates(inputs: ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            lastActivityTimestamp: nil,
            wrapperClaim: active,
            push: nil,
            scrapeCandidates: [latePriorRollout]
        ))
        XCTAssertTrue(eligible.isEmpty, "late writes from lifecycle A cannot re-own B")

        let decision = ResumeDecisionEngine.decide(ResumeDecisionInput(
            mode: .clean,
            auditComplete: true,
            ownership: .unique,
            kind: active?.kind ?? "codex",
            id: active?.id ?? "",
            placeholder: active?.placeholder ?? true,
            state: .unknown,
            exactIDValid: false,
            transcriptEvidence: .notRequired,
            diagnosticReason: active?.diagnosticReason,
            fallbackCommand: nil
        ))
        guard case .skip(let code, _) = decision else {
            return XCTFail("unreported lifecycle B must not resume lifecycle A")
        }
        XCTAssertEqual(code, .placeholder)
    }

    func testExactResumeIntentPreservesOnlyMatchingPriorIdentity() async {
        let store = ConversationStore()
        let idA = "aaaa1111-2222-3333-4444-555566667777"
        let idB = "bbbb1111-2222-3333-4444-555566667777"
        _ = await store.captureRuntimeEnv(surfaceId: "S1", id: idA, cwd: "/tmp/proj")

        _ = await store.claim(
            surfaceId: "S1", kind: "codex", cwd: "/tmp/proj",
            placeholderId: "wrapper-claim:matching",
            expectedResumeId: idA,
            expiresAt: nil
        )
        let matching = await store.active(for: "S1")
        XCTAssertEqual(matching?.id, idA)
        XCTAssertFalse(matching?.placeholder ?? true)

        _ = await store.claim(
            surfaceId: "S1", kind: "codex", cwd: "/tmp/proj",
            placeholderId: "wrapper-claim:mismatch",
            capturedAt: Date().addingTimeInterval(1),
            expectedResumeId: idB,
            expiresAt: nil
        )
        let mismatched = await store.active(for: "S1")
        XCTAssertTrue(mismatched?.placeholder == true)
        XCTAssertEqual(
            mismatched?.payload?[ConversationLifecyclePayloadKey.invalidatedConversationID],
            .string(idA)
        )
    }

    func testDelayedClaudeWrapperClaimCannotOverwriteHookIdentity() async {
        let store = ConversationStore()
        let hookID = "aaaa1111-2222-3333-4444-555566667777"
        await store.push(
            surfaceId: "S-claude",
            kind: "claude-code",
            id: hookID,
            source: .hook,
            cwd: "/tmp/proj",
            capturedAt: Date(timeIntervalSince1970: 1),
            state: .alive
        )

        _ = await store.claim(
            surfaceId: "S-claude",
            kind: "claude-code",
            cwd: "/tmp/proj",
            placeholderId: "wrapper-claim:S-claude:late",
            capturedAt: Date(timeIntervalSince1970: 10_000),
            expiresAt: nil
        )

        let active = await store.active(for: "S-claude")
        XCTAssertEqual(active?.id, hookID)
        XCTAssertEqual(active?.capturedVia, .hook)
        XCTAssertFalse(active?.placeholder ?? true)
    }

    func testSocketGenericPushRejectsReservedSourcesWithoutStoreMutation() async throws {
        for (index, reservedSource) in ["runtimeEnv", "wrapperClaim"].enumerated() {
            let surfaceID = UUID()
            await ConversationStore.shared.clear(surfaceId: surfaceID.uuidString)

            let response = await TerminalController.shared.v2DispatchConversation(
                "conversation.push",
                id: 206 + index,
                params: [
                    "surface_id": surfaceID.uuidString,
                    "kind": "codex",
                    "id": "aaaa1111-2222-3333-4444-555566667777",
                    "source": reservedSource,
                ]
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
            )
            let error = try XCTUnwrap(object["error"] as? [String: Any])
            XCTAssertEqual(object["ok"] as? Bool, false)
            XCTAssertEqual(error["code"] as? String, "invalid_source")
            let message = error["message"] as? String
            if reservedSource == "runtimeEnv" {
                XCTAssertTrue(message?.contains("conversation.capture_runtime") == true)
            } else {
                XCTAssertTrue(message?.contains("conversation.claim") == true)
            }
            let active = await ConversationStore.shared.active(for: surfaceID.uuidString)
            XCTAssertNil(active)
        }
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

    func testUnacknowledgedLaunchBoundaryInvalidatesPriorOwnerThroughPersistence() async throws {
        let store = ConversationStore()
        let idA = "aaaa1111-2222-3333-4444-555566667777"
        let idB = "bbbb1111-2222-3333-4444-555566667777"
        let boundary = Date(timeIntervalSince1970: 2_000.75)
        _ = await store.captureRuntimeEnv(
            surfaceId: "S1",
            id: idA,
            cwd: "/tmp/proj",
            capturedAt: Date(timeIntervalSince1970: 2_000.5)
        )

        let expiredClaim = await store.claim(
            surfaceId: "S1",
            kind: "codex",
            cwd: "/tmp/proj",
            placeholderId: "wrapper-claim:S1:expired",
            capturedAt: boundary,
            expectedResumeId: nil,
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(expiredClaim, .expired)

        let applied = await store.applyCodexLaunchBoundaries([
            CodexLaunchBoundaryMarker(
                surfaceId: "S1",
                boundaryAt: boundary,
                expectedResumeId: nil
            )
        ])
        XCTAssertEqual(applied, ["S1"])

        let persisted = try JSONEncoder().encode(await store.snapshot())
        let restored = try JSONDecoder().decode(
            [String: SurfaceConversations].self,
            from: persisted
        )
        let active = try XCTUnwrap(restored["S1"]?.active)
        XCTAssertTrue(active.placeholder)
        XCTAssertEqual(active.capturedVia, .wrapperClaim)
        XCTAssertEqual(
            active.payload?[ConversationLifecyclePayloadKey.invalidatedConversationID],
            .string(idA)
        )

        let decision = ResumeDecisionEngine.decide(ResumeDecisionInput(
            mode: .clean,
            auditComplete: true,
            ownership: Workspace.resumeOwnership(for: active),
            kind: active.kind,
            id: active.id,
            placeholder: active.placeholder,
            state: .unknown,
            exactIDValid: false,
            transcriptEvidence: .notRequired,
            diagnosticReason: active.diagnosticReason
        ))
        guard case .skip(let code, _) = decision else {
            return XCTFail("unreported lifecycle B must not resume prior lifecycle A")
        }
        XCTAssertEqual(code, .placeholder)

        _ = await store.captureRuntimeEnv(
            surfaceId: "S1",
            id: idB,
            cwd: "/tmp/proj",
            capturedAt: Date(timeIntervalSince1970: 2_000.9)
        )
        let lateApply = await store.applyCodexLaunchBoundaries([
            CodexLaunchBoundaryMarker(
                surfaceId: "S1",
                boundaryAt: boundary,
                expectedResumeId: nil
            )
        ])
        XCTAssertTrue(lateApply.isEmpty)
        let finalActive = await store.active(for: "S1")
        XCTAssertEqual(finalActive?.id, idB)
    }

    func testUnacknowledgedExactResumeBoundaryPreservesMatchingOwner() async {
        let store = ConversationStore()
        let idA = "aaaa1111-2222-3333-4444-555566667777"
        _ = await store.captureRuntimeEnv(
            surfaceId: "S1",
            id: idA,
            cwd: "/tmp/proj",
            capturedAt: Date(timeIntervalSince1970: 2_000.5)
        )

        let applied = await store.applyCodexLaunchBoundaries([
            CodexLaunchBoundaryMarker(
                surfaceId: "S1",
                boundaryAt: Date(timeIntervalSince1970: 2_000.75),
                expectedResumeId: idA
            )
        ])
        XCTAssertTrue(applied.isEmpty)
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.id, idA)
        XCTAssertFalse(active?.placeholder ?? true)
    }

    func testAcknowledgedClaimCrashBeforeSaveUsesRetainedBoundary() async {
        let idA = "aaaa1111-2222-3333-4444-555566667777"
        let capturedA = Date(timeIntervalSince1970: 2_000.5)
        let boundary = Date(timeIntervalSince1970: 2_000.75)
        let diskStore = ConversationStore()
        _ = await diskStore.captureRuntimeEnv(
            surfaceId: "S1",
            id: idA,
            cwd: "/tmp/proj",
            capturedAt: capturedA
        )
        let staleDiskSnapshot = await diskStore.snapshot()

        let liveStore = ConversationStore()
        _ = await liveStore.seed(from: staleDiskSnapshot)
        let claim = await liveStore.claim(
            surfaceId: "S1",
            kind: "codex",
            cwd: "/tmp/proj",
            placeholderId: "wrapper-claim:S1:acknowledged",
            capturedAt: Date(timeIntervalSince1970: 2_000.8),
            expectedResumeId: nil,
            expiresAt: nil
        )
        guard case .accepted(let livePlaceholder) = claim else {
            return XCTFail("claim should be acknowledged in the live Store")
        }
        XCTAssertTrue(livePlaceholder.placeholder)

        // Simulate a crash before that in-memory placeholder is autosaved:
        // the next process seeds exact A from disk, then replays the retained
        // boundary before scrape/verification can authorize A.
        let restoredStore = ConversationStore()
        _ = await restoredStore.seed(from: staleDiskSnapshot)
        let applied = await restoredStore.applyCodexLaunchBoundaries([
            CodexLaunchBoundaryMarker(
                surfaceId: "S1",
                boundaryAt: boundary,
                expectedResumeId: nil
            )
        ])
        XCTAssertEqual(applied, ["S1"])
        let restored = await restoredStore.active(for: "S1")
        XCTAssertTrue(restored?.placeholder == true)
        XCTAssertEqual(
            restored?.payload?[ConversationLifecyclePayloadKey.invalidatedConversationID],
            .string(idA)
        )
    }

    func testStartupLoadsOwnBundleStableAndPidFallbackMarkersOnlyForSnapshotSurfaces() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-206-startup-sockets-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let prodBundle = "com.stage11.c11"
        let tagBundle = "com.stage11.c11.debug.c11.206.codex.resume"
        XCTAssertNotEqual(
            CodexLaunchBoundaryMarkerStore.recordedSocketPathURL(
                bundleIdentifier: prodBundle
            ),
            CodexLaunchBoundaryMarkerStore.recordedSocketPathURL(
                bundleIdentifier: tagBundle
            )
        )

        let preferred = root.appendingPathComponent("tag.sock").path
        let fallbackPaths = [
            root.appendingPathComponent("c11-\(getuid()).sock").path,
            root.appendingPathComponent("tag-4242.sock").path,
        ]
        for (index, fallbackPath) in fallbackPaths.enumerated() {
            let caseRoot = root.appendingPathComponent("case-\(index)")
            try fileManager.createDirectory(
                at: caseRoot,
                withIntermediateDirectories: true
            )
            let prodRecord = caseRoot.appendingPathComponent("prod-record")
            let tagRecord = caseRoot.appendingPathComponent("tag-record")
            let prodFallback = caseRoot.appendingPathComponent("prod.sock").path
            CodexLaunchBoundaryMarkerStore.recordBoundSocketPath(
                prodFallback,
                bundleIdentifier: prodBundle,
                fileManager: fileManager,
                recordURL: prodRecord
            )
            CodexLaunchBoundaryMarkerStore.recordBoundSocketPath(
                fallbackPath,
                bundleIdentifier: tagBundle,
                fileManager: fileManager,
                recordURL: tagRecord
            )

            let allowedSurface = UUID().uuidString
            let foreignSurface = UUID().uuidString
            let prodSurface = UUID().uuidString
            let markerDirectory = CodexLaunchBoundaryMarkerStore.directoryURL(
                socketPath: fallbackPath
            )
            let prodMarkerDirectory = CodexLaunchBoundaryMarkerStore.directoryURL(
                socketPath: prodFallback
            )
            try fileManager.createDirectory(
                at: markerDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: prodMarkerDirectory,
                withIntermediateDirectories: true
            )
            let boundary = Date(timeIntervalSince1970: 2_000.75 + Double(index))
            for surfaceID in [allowedSurface, foreignSurface] {
                let markerURL = markerDirectory.appendingPathComponent(surfaceID)
                try "2000\n\nfixture\n".write(
                    to: markerURL,
                    atomically: true,
                    encoding: .utf8
                )
                try fileManager.setAttributes(
                    [.modificationDate: boundary],
                    ofItemAtPath: markerURL.path
                )
            }
            try "2000\n\nprod\n".write(
                to: prodMarkerDirectory.appendingPathComponent(prodSurface),
                atomically: true,
                encoding: .utf8
            )

            let loaded = CodexLaunchBoundaryMarkerStore.loadForStartup(
                preferredSocketPath: preferred,
                allowedSurfaceIds: [allowedSurface],
                bundleIdentifier: tagBundle,
                fileManager: fileManager,
                recordURL: tagRecord
            )
            XCTAssertEqual(
                loaded,
                [CodexLaunchBoundaryMarker(
                    surfaceId: allowedSurface,
                    boundaryAt: boundary,
                    expectedResumeId: nil
                )],
                "case \(index) must read only its tagged bundle record and snapshot surface"
            )

            let symlinkRecord = caseRoot.appendingPathComponent("tag-record-link")
            try fileManager.createSymbolicLink(
                at: symlinkRecord,
                withDestinationURL: tagRecord
            )
            XCTAssertTrue(
                CodexLaunchBoundaryMarkerStore.loadForStartup(
                    preferredSocketPath: preferred,
                    allowedSurfaceIds: [allowedSurface],
                    bundleIdentifier: tagBundle,
                    fileManager: fileManager,
                    recordURL: symlinkRecord
                ).isEmpty,
                "bundle socket record must be an owned regular file, not a symlink"
            )

            let store = ConversationStore()
            _ = await store.captureRuntimeEnv(
                surfaceId: allowedSurface,
                id: "aaaa1111-2222-3333-4444-55556666777\(index)",
                cwd: "/tmp/proj",
                capturedAt: boundary.addingTimeInterval(-0.1)
            )
            let applied = await store.applyCodexLaunchBoundaries(loaded)
            XCTAssertEqual(applied, [allowedSurface])
            let active = await store.active(for: allowedSurface)
            XCTAssertTrue(active?.placeholder == true)
        }
    }

    func testLaunchBoundaryMarkerStoreUsesSubsecondModificationDate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-206-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("c11.sock").path
        let directory = CodexLaunchBoundaryMarkerStore.directoryURL(
            socketPath: socketPath
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let surfaceID = "c040ef8d-58a5-4c29-bebd-29f3d44ed203"
        let expectedID = "aaaa1111-2222-3333-4444-555566667777"
        let markerURL = directory.appendingPathComponent(surfaceID)
        try "2000\n\(expectedID)\nsurface:pid:token\n".write(
            to: markerURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000.75)],
            ofItemAtPath: markerURL.path
        )

        XCTAssertEqual(
            CodexLaunchBoundaryMarkerStore.load(socketPath: socketPath),
            [CodexLaunchBoundaryMarker(
                surfaceId: surfaceID,
                boundaryAt: Date(timeIntervalSince1970: 2_000.75),
                expectedResumeId: expectedID
            )]
        )
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

    func testSeedQuarantinesDistinctInferredCodexOwnersInSameNormalizedCwd() async {
        let store = ConversationStore()
        let audit = await store.seed(from: [
            "S1": SurfaceConversations(active: ConversationRef(
                kind: "codex",
                id: "aaaa1111-2222-3333-4444-555566667777",
                cwd: "/work/shared/../shared",
                capturedVia: .scrape,
                state: .suspended
            )),
            "S2": SurfaceConversations(active: ConversationRef(
                kind: "codex",
                id: "bbbb1111-2222-3333-4444-555566667777",
                cwd: "/work/shared",
                capturedVia: .manual,
                state: .suspended
            )),
        ])

        XCTAssertEqual(audit.quarantinedSurfaceIds, ["S1", "S2"])
        let s1 = await store.active(for: "S1")
        let s2 = await store.active(for: "S2")
        XCTAssertEqual(s1?.quarantineReason, .sameCwdWithoutCausalIdentity)
        XCTAssertEqual(s2?.quarantineReason, .sameCwdWithoutCausalIdentity)
    }

    func testSeedPreservesDistinctCausalCodexOwnersInSameCwd() async {
        let store = ConversationStore()
        let audit = await store.seed(from: [
            "S1": SurfaceConversations(active: ConversationRef(
                kind: "codex",
                id: "aaaa1111-2222-3333-4444-555566667777",
                cwd: "/work/shared",
                capturedVia: .runtimeEnv,
                state: .suspended
            )),
            "S2": SurfaceConversations(active: ConversationRef(
                kind: "codex",
                id: "bbbb1111-2222-3333-4444-555566667777",
                cwd: "/work/shared",
                capturedVia: .runtimeEnv,
                state: .suspended
            )),
        ])

        XCTAssertTrue(audit.quarantinedSurfaceIds.isEmpty)
        let s1 = await store.active(for: "S1")
        let s2 = await store.active(for: "S2")
        XCTAssertNil(s1?.quarantineReason)
        XCTAssertNil(s2?.quarantineReason)
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
