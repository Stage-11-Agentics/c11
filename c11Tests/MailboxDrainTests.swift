import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-257 Lane C: claim-to-`_read/` consumption and the per-harness hook JSON
/// that `c11 mailbox recv --hook-format` prints at a turn boundary.
final class MailboxDrainTests: XCTestCase {

    private final class WorkspaceScanCountingFileManager: FileManager {
        private let workspacesRootPath: String
        private(set) var workspacesRootEnumerations = 0

        init(workspacesRoot: URL) {
            workspacesRootPath = workspacesRoot.path
            super.init()
        }

        override func contentsOfDirectory(atPath path: String) throws -> [String] {
            if path == workspacesRootPath { workspacesRootEnumerations += 1 }
            return try super.contentsOfDirectory(atPath: path)
        }
    }

    private var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-drain-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("watcher", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inbox.deletingLastPathComponent())
    }

    @discardableResult
    private func deliver(id: String, body: String = "hello", from: String = "builder") throws -> URL {
        let envelope = try MailboxEnvelope.build(
            from: from,
            to: "watcher",
            body: body,
            id: id,
            ts: "2026-10-01T12:00:00Z"
        )
        let url = inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        try envelope.encode().write(to: url)
        return url
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".msg") }
            .sorted()
    }

    private let idA = "01K0000000000000000000000A"
    private let idB = "01K0000000000000000000000B"
    private let idC = "01K0000000000000000000000C"

    // MARK: - Claim

    func testClaimMovesEnvelopeIntoReadDirectory() throws {
        let entry = try deliver(id: idA)
        let claimed = try XCTUnwrap(MailboxDrain.claim(entry))
        XCTAssertEqual(claimed.deletingLastPathComponent().lastPathComponent, "_read")
        XCTAssertEqual(names(in: inbox), [])
        XCTAssertEqual(names(in: MailboxDrain.readURL(inbox: inbox)), ["\(idA).msg"])
    }

    func testSecondClaimOfSameEnvelopeFindsItGone() throws {
        let entry = try deliver(id: idA)
        XCTAssertNotNil(MailboxDrain.claim(entry))
        XCTAssertNil(MailboxDrain.claim(entry))
    }

    func testRacingConsumersClaimEachEnvelopeExactlyOnce() throws {
        let entries = try [idA, idB, idC].map { try deliver(id: $0) }
        let lock = NSLock()
        var wins: [String: Int] = [:]
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            for entry in entries where MailboxDrain.claim(entry) != nil {
                lock.lock()
                wins[entry.lastPathComponent, default: 0] += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(wins, ["\(idA).msg": 1, "\(idB).msg": 1, "\(idC).msg": 1])
        XCTAssertEqual(names(in: inbox), [])
        XCTAssertEqual(names(in: MailboxDrain.readURL(inbox: inbox)).count, 3)
    }

    func testUnclaimReturnsEnvelopeToInboxRoot() throws {
        let entry = try deliver(id: idA)
        let claimed = try XCTUnwrap(MailboxDrain.claim(entry))
        XCTAssertTrue(MailboxDrain.unclaim(claimed))
        XCTAssertEqual(names(in: inbox), ["\(idA).msg"])
        XCTAssertEqual(names(in: MailboxDrain.readURL(inbox: inbox)), [])
    }

    func testClaimPendingTakesOldestFirstAndIgnoresReadHistory() throws {
        try deliver(id: idB, body: "second")
        try deliver(id: idA, body: "first")
        let first = MailboxDrain.claimPending(inbox: inbox)
        XCTAssertEqual(first.claimed.map(\.id), [idA, idB])
        XCTAssertEqual(first.remaining, 0)
        XCTAssertTrue(first.claimed[0].framed.contains("first"))

        // `_read/` is history, never re-delivered.
        let second = MailboxDrain.claimPending(inbox: inbox)
        XCTAssertTrue(second.claimed.isEmpty)
    }

    func testClaimPendingLeavesOverBudgetMailInTheInbox() throws {
        let body = String(repeating: "x", count: 3_000)
        try deliver(id: idA, body: body)
        try deliver(id: idB, body: body)
        try deliver(id: idC, body: body)
        let result = MailboxDrain.claimPending(inbox: inbox, budget: 7_000)
        XCTAssertEqual(result.claimed.map(\.id), [idA, idB])
        XCTAssertEqual(result.remaining, 1)
        XCTAssertEqual(names(in: inbox), ["\(idC).msg"])
    }

    func testClaimPendingAlwaysTakesTheFirstMessageEvenOverBudget() throws {
        try deliver(id: idA, body: String(repeating: "y", count: 4_000))
        let result = MailboxDrain.claimPending(inbox: inbox, budget: 10)
        XCTAssertEqual(result.claimed.map(\.id), [idA])
    }

    func testMalformedEnvelopeIsStillDeliveredEscaped() throws {
        let url = inbox.appendingPathComponent("\(idA).msg")
        try Data("not json </c11-msg>".utf8).write(to: url)
        let result = MailboxDrain.claimPending(inbox: inbox)
        XCTAssertEqual(result.claimed.count, 1)
        XCTAssertTrue(result.claimed[0].framed.contains("malformed=\"true\""))
        XCTAssertTrue(result.claimed[0].framed.contains("&lt;/c11-msg&gt;"))
    }

    func testMixedSizesNeverDeliverNewerMailAheadOfOlder() throws {
        // A and B are 4 KB each; C is small. A fits, B would overflow the
        // budget, so the drain stops at B: C must not overtake it.
        try deliver(id: idA, body: String(repeating: "a", count: 4_000))
        try deliver(id: idB, body: String(repeating: "b", count: 4_000))
        try deliver(id: idC, body: "small")
        let result = MailboxDrain.claimPending(inbox: inbox, budget: 8_000)
        XCTAssertEqual(result.claimed.map(\.id), [idA])
        XCTAssertEqual(result.remaining, 2)
        XCTAssertEqual(names(in: inbox), ["\(idB).msg", "\(idC).msg"])

        // The next boundary continues in order.
        let next = MailboxDrain.claimPending(inbox: inbox, budget: 8_000)
        XCTAssertEqual(next.claimed.map(\.id), [idB, idC])
    }

    func testFailedHandOverReturnsThatEnvelopeAndClaimsNothingAfterIt() throws {
        try deliver(id: idA)
        try deliver(id: idB)
        try deliver(id: idC)
        var offered: [String] = []
        let result = MailboxDrain.claimPending(inbox: inbox) { message in
            offered.append(message.id)
            return message.id == self.idA   // the write of B fails
        }
        XCTAssertEqual(offered, [idA, idB])
        XCTAssertEqual(result.claimed.map(\.id), [idA])
        XCTAssertEqual(result.remaining, 2)
        XCTAssertEqual(names(in: inbox), ["\(idB).msg", "\(idC).msg"])
        XCTAssertEqual(names(in: MailboxDrain.readURL(inbox: inbox)), ["\(idA).msg"])
    }

    func testClaimedMessageCarriesTheEnvelopeRecipient() throws {
        try deliver(id: idA)
        XCTAssertEqual(MailboxDrain.claimPending(inbox: inbox).claimed.first?.recipient, "watcher")
    }

    func testPanelInboxIsTheLowercasedPanelUUID() throws {
        let panel = UUID(uuidString: "B3A3DFEF-0A83-4887-BBE9-FDE27516A3B5")!
        let root = URL(fileURLWithPath: "/tmp/m", isDirectory: true)
        XCTAssertEqual(
            MailboxDrain.panelInboxURL(mailboxesRoot: root, panelId: panel).path,
            "/tmp/m/b3a3dfef-0a83-4887-bbe9-fde27516a3b5"
        )
    }

    func testClaimPendingMergesSeveralInboxesInULIDOrder() throws {
        let other = inbox.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try deliver(id: idB)
        let envelope = try MailboxEnvelope.build(from: "builder", to: "watcher", body: "first", id: idA, ts: "2026-10-01T12:00:00Z")
        try envelope.encode().write(to: other.appendingPathComponent("\(idA).msg"))
        let result = MailboxDrain.claimPending(inboxes: [inbox, other])
        XCTAssertEqual(result.claimed.map(\.id), [idA, idB])
        XCTAssertEqual(result.claimed.map { $0.inbox.lastPathComponent }, ["other", "watcher"])
    }

    // MARK: - Moved tab

    private func workspaceInbox(_ root: URL, _ workspace: UUID, _ panel: UUID) -> URL {
        root.appendingPathComponent(workspace.uuidString, isDirectory: true)
            .appendingPathComponent("mailboxes", isDirectory: true)
            .appendingPathComponent(panel.uuidString.lowercased(), isDirectory: true)
    }

    func testPanelInboxURLsFindsAMovedPanelsInboxInAnotherWorkspace() throws {
        let root = inbox.deletingLastPathComponent().appendingPathComponent("workspaces", isDirectory: true)
        let panel = UUID(), stale = UUID(), current = UUID(), unrelated = UUID()
        let currentInbox = workspaceInbox(root, current, panel)
        try FileManager.default.createDirectory(at: currentInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceInbox(root, unrelated, UUID()), withIntermediateDirectories: true)
        let envelope = try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "moved mail", id: idA, ts: "2026-10-01T12:00:00Z"
        )
        try envelope.encode().write(to: currentInbox.appendingPathComponent("\(idA).msg"))

        let found = MailboxDrain.panelInboxURLs(workspacesRoot: root, preferredWorkspaceId: stale, panelId: panel)
        XCTAssertEqual(found.map(\.path), [currentInbox.path])
        XCTAssertEqual(MailboxDrain.workspaceId(ofInbox: found[0]), current)
        XCTAssertEqual(MailboxDrain.claimPending(inboxes: found).claimed.map(\.id), [idA])

        // An old, now-empty inbox must still trigger the fallback after a move.
        let staleInbox = workspaceInbox(root, stale, panel)
        try FileManager.default.createDirectory(at: staleInbox, withIntermediateDirectories: true)
        let movedAgain = try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "second message", id: idB, ts: "2026-10-01T12:01:00Z"
        )
        try movedAgain.encode().write(to: currentInbox.appendingPathComponent("\(idB).msg"))
        let both = MailboxDrain.panelInboxURLs(workspacesRoot: root, preferredWorkspaceId: stale, panelId: panel)
        XCTAssertEqual(both.map(\.path), [staleInbox.path, currentInbox.path])
        XCTAssertEqual(MailboxDrain.claimPending(inboxes: both).claimed.map(\.id), [idB])
    }

    func testPanelInboxUsesPendingPreferredPathWithoutWorkspaceScan() throws {
        let root = inbox.deletingLastPathComponent().appendingPathComponent("workspaces", isDirectory: true)
        let panel = UUID(), current = UUID()
        let directInbox = workspaceInbox(root, current, panel)
        try FileManager.default.createDirectory(at: directInbox, withIntermediateDirectories: true)
        for _ in 0..<32 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(UUID().uuidString, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let envelope = try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "direct mail", id: idA, ts: "2026-10-01T12:00:00Z"
        )
        try envelope.encode().write(to: directInbox.appendingPathComponent("\(idA).msg"))
        let fileManager = WorkspaceScanCountingFileManager(workspacesRoot: root)

        let inboxes = MailboxDrain.panelInboxURLs(
            workspacesRoot: root,
            preferredWorkspaceId: current,
            currentWorkspaceId: current,
            panelId: panel,
            fileManager: fileManager
        )
        let claimed = MailboxDrain.claimPending(inboxes: inboxes, fileManager: fileManager).claimed

        XCTAssertEqual(inboxes.map(\.path), [directInbox.path])
        XCTAssertEqual(claimed.map(\.id), [idA])
        XCTAssertEqual(fileManager.workspacesRootEnumerations, 0)
    }

    func testNoMailStopUsesFreshScanCacheWithoutWorkspaceScan() throws {
        let root = inbox.deletingLastPathComponent().appendingPathComponent("workspaces", isDirectory: true)
        let panel = UUID(), preferred = UUID(), retained = UUID()
        let preferredInbox = workspaceInbox(root, preferred, panel)
        let retainedInbox = workspaceInbox(root, retained, panel)
        try FileManager.default.createDirectory(at: preferredInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedInbox, withIntermediateDirectories: true)

        let cache = inbox.deletingLastPathComponent()
            .appendingPathComponent("mailbox-tab-scan", isDirectory: true)
            .appendingPathComponent(panel.uuidString.lowercased())
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try retainedInbox.path.write(to: cache, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: cache.path)
        let fileManager = WorkspaceScanCountingFileManager(workspacesRoot: root)

        let inboxes = MailboxDrain.panelInboxURLs(
            workspacesRoot: root,
            preferredWorkspaceId: preferred,
            panelId: panel,
            scanCache: cache,
            scanInterval: 300,
            now: now,
            fileManager: fileManager
        )

        XCTAssertEqual(inboxes.map(\.path), [preferredInbox.path, retainedInbox.path])
        XCTAssertEqual(fileManager.workspacesRootEnumerations, 0)
    }

    func testNoMailStopRefreshesStaleScanCache() throws {
        let root = inbox.deletingLastPathComponent().appendingPathComponent("workspaces", isDirectory: true)
        let panel = UUID(), preferred = UUID(), current = UUID()
        let preferredInbox = workspaceInbox(root, preferred, panel)
        let currentInbox = workspaceInbox(root, current, panel)
        try FileManager.default.createDirectory(at: preferredInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentInbox, withIntermediateDirectories: true)

        let cache = inbox.deletingLastPathComponent()
            .appendingPathComponent("mailbox-tab-scan", isDirectory: true)
            .appendingPathComponent(panel.uuidString.lowercased())
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try preferredInbox.path.write(to: cache, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-301)],
            ofItemAtPath: cache.path
        )
        let fileManager = WorkspaceScanCountingFileManager(workspacesRoot: root)

        let inboxes = MailboxDrain.panelInboxURLs(
            workspacesRoot: root,
            preferredWorkspaceId: preferred,
            panelId: panel,
            scanCache: cache,
            scanInterval: 300,
            now: now,
            fileManager: fileManager
        )

        XCTAssertEqual(inboxes.map(\.path), [preferredInbox.path, currentInbox.path])
        XCTAssertEqual(fileManager.workspacesRootEnumerations, 1)
    }

    func testPanelInboxScansWhenGenericReceiveCannotResolveLiveOwner() throws {
        let root = inbox.deletingLastPathComponent().appendingPathComponent("workspaces", isDirectory: true)
        let panel = UUID(), stale = UUID(), current = UUID()
        let staleInbox = workspaceInbox(root, stale, panel)
        let currentInbox = workspaceInbox(root, current, panel)
        try FileManager.default.createDirectory(at: staleInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentInbox, withIntermediateDirectories: true)
        try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "old workspace mail", id: idA, ts: "2026-10-01T12:00:00Z"
        ).encode().write(to: staleInbox.appendingPathComponent("\(idA).msg"))
        try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "current workspace mail", id: idB, ts: "2026-10-01T12:01:00Z"
        ).encode().write(to: currentInbox.appendingPathComponent("\(idB).msg"))
        let fileManager = WorkspaceScanCountingFileManager(workspacesRoot: root)

        let inboxes = MailboxDrain.panelInboxURLs(
            workspacesRoot: root,
            preferredWorkspaceId: stale,
            scanWhenOwnerUnknown: true,
            panelId: panel,
            fileManager: fileManager
        )
        let claimed = MailboxDrain.claimPending(inboxes: inboxes, fileManager: fileManager).claimed

        XCTAssertEqual(Set(inboxes.compactMap(MailboxDrain.workspaceId(ofInbox:))), Set([stale, current]))
        XCTAssertEqual(claimed.map(\.id), [idA, idB])
        XCTAssertEqual(fileManager.workspacesRootEnumerations, 1)
    }

    func testPanelInboxIncludesIntermediateWorkspacesAfterMultipleMoves() throws {
        let root = inbox.deletingLastPathComponent().appendingPathComponent("workspaces", isDirectory: true)
        let panel = UUID(), stale = UUID(), intermediate = UUID(), current = UUID()
        let staleInbox = workspaceInbox(root, stale, panel)
        let intermediateInbox = workspaceInbox(root, intermediate, panel)
        let currentInbox = workspaceInbox(root, current, panel)
        try FileManager.default.createDirectory(at: staleInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: intermediateInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentInbox, withIntermediateDirectories: true)
        let staleMail = try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "old workspace mail", id: idA, ts: "2026-10-01T12:00:00Z"
        )
        let intermediateMail = try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "intermediate workspace mail", id: idB, ts: "2026-10-01T12:01:00Z"
        )
        let currentMail = try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "current workspace mail", id: idC, ts: "2026-10-01T12:02:00Z"
        )
        try staleMail.encode().write(to: staleInbox.appendingPathComponent("\(idA).msg"))
        try intermediateMail.encode().write(to: intermediateInbox.appendingPathComponent("\(idB).msg"))
        try currentMail.encode().write(to: currentInbox.appendingPathComponent("\(idC).msg"))
        let fileManager = WorkspaceScanCountingFileManager(workspacesRoot: root)

        let inboxes = MailboxDrain.panelInboxURLs(
            workspacesRoot: root,
            preferredWorkspaceId: stale,
            currentWorkspaceId: current,
            panelId: panel,
            fileManager: fileManager
        )
        let claimed = MailboxDrain.claimPending(inboxes: inboxes, fileManager: fileManager).claimed

        XCTAssertEqual(Set(inboxes.compactMap(MailboxDrain.workspaceId(ofInbox:))), Set([stale, intermediate, current]))
        XCTAssertEqual(claimed.map(\.id), [idA, idB, idC])
        XCTAssertEqual(Set(claimed.compactMap { MailboxDrain.workspaceId(ofInbox: $0.inbox) }), Set([stale, intermediate, current]))
        XCTAssertEqual(fileManager.workspacesRootEnumerations, 1)
    }

    func testPanelInboxFallbackRescansAfterPreferredWorkspaceMisses() throws {
        let root = inbox.deletingLastPathComponent().appendingPathComponent("workspaces", isDirectory: true)
        let panel = UUID(), stale = UUID(), current = UUID()
        let staleInbox = workspaceInbox(root, stale, panel)
        try FileManager.default.createDirectory(at: staleInbox, withIntermediateDirectories: true)
        XCTAssertEqual(
            MailboxDrain.panelInboxURLs(workspacesRoot: root, preferredWorkspaceId: stale, panelId: panel).map(\.path),
            [staleInbox.path]
        )

        let currentInbox = workspaceInbox(root, current, panel)
        try FileManager.default.createDirectory(at: currentInbox, withIntermediateDirectories: true)
        let envelope = try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "after move", id: idA, ts: "2026-10-01T12:00:00Z"
        )
        try envelope.encode().write(to: currentInbox.appendingPathComponent("\(idA).msg"))

        let resolved = MailboxDrain.panelInboxURLs(workspacesRoot: root, preferredWorkspaceId: stale, panelId: panel)
        XCTAssertEqual(resolved.map(\.path), [staleInbox.path, currentInbox.path])
        XCTAssertEqual(MailboxDrain.claimPending(inboxes: resolved).claimed.map(\.id), [idA])
    }

    func testClaimDeadline() {
        XCTAssertTrue(MailboxHookOutput.mayClaim(processElapsedSeconds: 0.2))
        XCTAssertTrue(MailboxHookOutput.mayClaim(processElapsedSeconds: nil))
        XCTAssertFalse(MailboxHookOutput.mayClaim(processElapsedSeconds: 6))
        XCTAssertFalse(MailboxHookOutput.mayClaim(processElapsedSeconds: 9.5))
    }

    func testHandWrittenFileIsClaimedUnderAFreshULID() throws {
        try deliver(id: idA)
        try Data("hand-written note".utf8).write(to: inbox.appendingPathComponent("0note.msg"))
        let claimed = MailboxDrain.claimPending(inbox: inbox).claimed
        XCTAssertEqual(claimed.count, 2)
        let note = try XCTUnwrap(claimed.first { $0.text == "hand-written note" })
        XCTAssertTrue(MailboxDrain.isULID(note.id), "recorded under a minted ULID, not 0note")
        XCTAssertEqual(note.readURL.lastPathComponent, "\(note.id).msg")
        XCTAssertTrue(note.framed.contains("id=\"\(note.id)\""))
        XCTAssertEqual(names(in: inbox), [])
        XCTAssertFalse(names(in: MailboxDrain.readURL(inbox: inbox)).contains("0note.msg"))
        XCTAssertTrue(claimed.contains { $0.id == idA && $0.readURL.lastPathComponent == "\(idA).msg" })
    }

    // MARK: - Framing

    func testFramingMatchesStdinPushForInlineBodies() throws {
        let envelope = try MailboxEnvelope.build(
            from: "a \"b\"",
            to: "watcher",
            topic: "build.done",
            body: "<script>&",
            id: idA,
            ts: "2026-10-01T12:00:00Z",
            replyTo: "builder",
            urgent: true
        )
        XCTAssertEqual(
            MailboxFraming.framedBlock(envelope: envelope),
            StdinMailboxHandler.formatFramedBlock(envelope: envelope)
        )
    }

    func testFramingInlinesBodyRef() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-bodyref-\(UUID().uuidString).txt")
        try Data("full brief".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "",
            id: idA,
            ts: "2026-10-01T12:00:00Z",
            bodyRef: file.path
        )
        XCTAssertEqual(envelope.body, "")
        let framed = MailboxFraming.framedBlock(envelope: envelope)
        XCTAssertTrue(framed.contains("body_ref=\"\(file.path)\""))
        XCTAssertTrue(framed.contains("full brief"))
        let stored = try envelope.encode()
        let raw = String(data: stored, encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("\"body\":\"\""))
        XCTAssertEqual(MailboxFraming.displayText(data: stored), framed)
        XCTAssertEqual(
            MailboxDrain.framedBlock(data: stored, fallbackId: idA),
            framed
        )
    }

    func testBodyRefCapNamesThePath() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-bodyref-\(UUID().uuidString).txt")
        var bytes = Data(repeating: 0x61, count: MailboxEnvelope.maxBodyBytes)
        bytes.append(contentsOf: "TAIL".utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "",
            id: idA,
            ts: "2026-10-01T12:00:00Z",
            bodyRef: file.path
        )
        let body = MailboxFraming.presentedBody(envelope: envelope)
        XCTAssertFalse(body.contains("TAIL"))
        XCTAssertTrue(body.hasPrefix(String(repeating: "a", count: MailboxEnvelope.maxBodyBytes)))
        XCTAssertTrue(body.contains("[truncated; rest is at \(file.path)]"))
        XCTAssertEqual(envelope.body, "")
    }

    func testMissingBodyRefNamesThePath() throws {
        let missing = "/tmp/c11-394-missing-\(UUID().uuidString).txt"
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "",
            id: idA,
            ts: "2026-10-01T12:00:00Z",
            bodyRef: missing
        )
        let body = MailboxFraming.presentedBody(envelope: envelope)
        XCTAssertEqual(body, "[body unavailable; see \(missing)]")
        XCTAssertTrue(MailboxFraming.framedBlock(envelope: envelope).contains("body_ref=\"\(missing)\""))
    }

    func testBodyRefCutsOnAUTF8Boundary() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-bodyref-\(UUID().uuidString).txt")
        var bytes = Data("a".utf8)
        bytes.append(contentsOf: "€".utf8)
        bytes.append(contentsOf: "Z".utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let read = MailboxFraming.readBodyRef(path: file.path, cap: 2)
        XCTAssertEqual(read.text, "a")
        XCTAssertTrue(read.truncated)
        XCTAssertFalse(read.text.contains("€"))
    }

    func testFifoBodyRefIsUnavailable() throws {
        let path = "/tmp/c11-394-fifo-\(UUID().uuidString)"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let read = MailboxFraming.readBodyRef(path: path, cap: 32)
        XCTAssertTrue(read.missing)
        XCTAssertEqual(read.text, "")
    }

    func testDirectoryBodyRefIsUnavailable() {
        let read = MailboxFraming.readBodyRef(path: "/tmp", cap: 32)
        XCTAssertTrue(read.missing)
        XCTAssertEqual(read.text, "")
    }

    /// `/dev/zero` would fill the inline cap if the regular-file check were
    /// gone. A device is unavailable, and the read does not consume it.
    func testDeviceBodyRefIsUnavailable() {
        let read = MailboxFraming.readBodyRef(path: "/dev/zero", cap: 8)
        XCTAssertTrue(read.missing)
        XCTAssertEqual(read.text, "")
    }

    func testPendingStaysUntilAClaim() throws {
        let url = try deliver(id: idA)
        let dir = url.deletingLastPathComponent()
        XCTAssertTrue(MailboxIO.isPending(id: idA, inbox: dir))
        _ = try MailboxIO.claim(id: idA, inbox: dir)
        XCTAssertFalse(MailboxIO.isPending(id: idA, inbox: dir))
    }

    func testInlineBodyRecvStaysRawJSON() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "inline",
            id: idA,
            ts: "2026-10-01T12:00:00Z"
        )
        let stored = try envelope.encode()
        XCTAssertEqual(
            MailboxFraming.displayText(data: stored),
            String(data: stored, encoding: .utf8)
        )
    }

    // MARK: - Hook input

    func testParsesClaudeAndCodexStopInput() {
        let input = MailboxHookInput.parse(Data(#"{"hook_event_name":"Stop","stop_hook_active":true}"#.utf8))
        XCTAssertEqual(input.event, .stop)
        XCTAssertTrue(input.stopHookActive)
    }

    func testParsesGrokCamelCaseStopInput() {
        let input = MailboxHookInput.parse(Data(#"{"hookEventName":"stop","stopHookActive":false,"reason":"end_turn"}"#.utf8))
        XCTAssertEqual(input.event, .stop)
        XCTAssertFalse(input.stopHookActive)
        XCTAssertEqual(input.stopReason, "end_turn")
    }

    func testParsesPromptSubmitSpellings() {
        XCTAssertEqual(MailboxHookInput.parse(Data(#"{"hook_event_name":"UserPromptSubmit"}"#.utf8)).event, .promptSubmit)
        XCTAssertEqual(MailboxHookInput.parse(Data(#"{"hookEventName":"user_prompt_submit"}"#.utf8)).event, .promptSubmit)
        XCTAssertEqual(MailboxHookEvent(name: "prompt-submit"), .promptSubmit)
        XCTAssertNil(MailboxHookInput.parse(Data()).event)
    }

    // MARK: - Drain policy

    func testStopDrainsOnlyOutsideAStopHookContinuation() {
        for format in MailboxHookFormat.allCases {
            let turnEnd = MailboxHookInput(event: .stop, stopReason: "end_turn")
            XCTAssertTrue(MailboxHookOutput.shouldDrain(format: format, input: turnEnd))
            XCTAssertFalse(
                MailboxHookOutput.shouldDrain(
                    format: format,
                    input: .init(event: .stop, stopHookActive: true, stopReason: "end_turn")
                ),
                "\(format) must not drain on a continuation stop"
            )
        }
        // Claude and Codex send no reason on Stop.
        XCTAssertTrue(MailboxHookOutput.shouldDrain(format: .claude, input: .init(event: .stop)))
        XCTAssertTrue(MailboxHookOutput.shouldDrain(format: .codex, input: .init(event: .stop)))
    }

    func testGrokDrainsOnlyAtTurnEndStop() {
        XCTAssertTrue(MailboxHookOutput.shouldDrain(format: .grok, input: .init(event: .stop, stopReason: "end_turn")))
        XCTAssertFalse(MailboxHookOutput.shouldDrain(format: .grok, input: .init(event: .stop, stopReason: "shutdown")))
        XCTAssertFalse(MailboxHookOutput.shouldDrain(format: .grok, input: .init(event: .stop)), "missing reason")
        XCTAssertFalse(MailboxHookOutput.shouldDrain(format: .grok, input: .init(event: .stop, stopReason: "END_TURN")))
        XCTAssertFalse(MailboxHookOutput.shouldDrain(format: .grok, input: .init(event: .stop, stopReason: "")))
        // A non-string reason parses as missing.
        let malformed = MailboxHookInput.parse(Data(#"{"hookEventName":"stop","reason":7}"#.utf8))
        XCTAssertFalse(MailboxHookOutput.shouldDrain(format: .grok, input: malformed))
        // Grok discards an allowing UserPromptSubmit hook's output.
        XCTAssertFalse(MailboxHookOutput.shouldDrain(format: .grok, input: .init(event: .promptSubmit)))
    }

    func testPromptSubmitNeverDrains() {
        for format in MailboxHookFormat.allCases {
            XCTAssertFalse(
                MailboxHookOutput.shouldDrain(format: format, input: .init(event: .promptSubmit)),
                "\(format): mail added to an operator's turn is not acted on; it waits for the Stop"
            )
        }
        XCTAssertFalse(MailboxHookOutput.shouldDrain(format: .claude, input: .init()))
    }

    // MARK: - Hook JSON

    private func decode(_ rendered: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
    }

    func testClaudeStopPayloadDeliversAsAdditionalContextWithoutBlockingError() throws {
        let json = try decode(MailboxHookOutput.render(
            MailboxHookOutput.payload(context: "ctx", format: .claude)
        ))
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "Stop")
        XCTAssertEqual(specific["additionalContext"] as? String, "ctx")
        XCTAssertNil(json["decision"])
        XCTAssertNil(json["reason"])
    }

    func testCodexAndGrokStopPayloadsBlockWithMessagesAsReason() throws {
        for format in [MailboxHookFormat.codex, .grok] {
            let json = try decode(MailboxHookOutput.render(
                MailboxHookOutput.payload(context: "ctx", format: format)
            ))
            XCTAssertEqual(json["decision"] as? String, "block")
            XCTAssertEqual(json["reason"] as? String, "ctx")
        }
    }

    func testContextHeaderCountsMessagesAndAnnouncesTheRest() throws {
        try deliver(id: idA, body: "ping one")
        try deliver(id: idB, body: "ping two")
        let claimed = MailboxDrain.claimPending(inbox: inbox).claimed
        let context = MailboxHookOutput.context(framedBlocks: claimed.map(\.framed), remaining: 3)
        XCTAssertTrue(context.hasPrefix("c11 mailbox: 2 new messages"))
        XCTAssertTrue(context.contains("3 more waiting"))
        XCTAssertTrue(context.contains("ping one"))
        XCTAssertTrue(context.contains("ping two"))
        XCTAssertTrue(context.contains("<c11-msg from=\"builder\" id=\"\(idA)\""))
    }

    // MARK: - Delivery receipt panel key (C11-337)

    private let receiptPanel = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!

    func testReceiptWritesOnlyPanelId() throws {
        let receipt = MailboxDeliveryReceipt(
            panelId: receiptPanel, deliveries: [.init(id: idA, recipient: "watcher")], ts: "t"
        )
        let data = try XCTUnwrap(receipt.encode())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["panel_id"] as? String, receiptPanel.uuidString)
        XCTAssertNil(object["tab_id"], "C11-345: tab_id is read, never written")
        XCTAssertEqual(MailboxDeliveryReceipt.decode(data)?.receipt, receipt)
    }

    func testReceiptDecodesLegacyTabIdOnly() throws {
        let json = #"{"version":1,"via":"drain","ts":"t","tab_id":"\#(receiptPanel.uuidString)","deliveries":[{"id":"\#(idA)","recipient":"w"}]}"#
        let decoded = try XCTUnwrap(MailboxDeliveryReceipt.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.receipt.panelId, receiptPanel)
        XCTAssertTrue(decoded.dropped.isEmpty)
    }

    func testReceiptDecodesPanelIdOnlyAndPrefersItOverTabId() throws {
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!
        let panelOnly = #"{"version":1,"via":"drain","ts":"t","panel_id":"\#(receiptPanel.uuidString)","deliveries":[{"id":"\#(idA)","recipient":"w"}]}"#
        XCTAssertEqual(MailboxDeliveryReceipt.decode(Data(panelOnly.utf8))?.receipt.panelId, receiptPanel)
        let both = #"{"version":1,"via":"drain","ts":"t","panel_id":"\#(receiptPanel.uuidString)","tab_id":"\#(other.uuidString)","deliveries":[{"id":"\#(idA)","recipient":"w"}]}"#
        XCTAssertEqual(MailboxDeliveryReceipt.decode(Data(both.utf8))?.receipt.panelId, receiptPanel)
        let invalidPanel = #"{"version":1,"via":"drain","ts":"t","panel_id":"not-a-uuid","deliveries":[{"id":"\#(idA)","recipient":"w"}]}"#
        let decoded = try XCTUnwrap(MailboxDeliveryReceipt.decode(Data(invalidPanel.utf8)))
        XCTAssertNil(decoded.receipt.panelId)
        XCTAssertEqual(decoded.receipt.deliveries.count, 1)
        XCTAssertEqual(decoded.dropped.count, 1)
    }
}

/// C11-364 / C11-369: the mailbox CLI seam. `c11 mailbox send` and `recv`
/// call these functions before any outbox write or inbox claim.
final class MailboxCLISeamTests: XCTestCase {

    private var inbox: URL!
    private let idA = "01K0000000000000000000000A"

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-cli-seam-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("watcher", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inbox.deletingLastPathComponent())
    }

    private func deliver(body: String) throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: body,
            id: idA,
            ts: "2026-10-01T12:00:00Z"
        )
        try envelope.encode().write(to: inbox.appendingPathComponent("\(idA).msg"))
    }

    private func messageNames(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".msg") }
            .sorted()
    }

    private func assertSend(
        _ args: [String],
        fails expected: MailboxSendArguments.Failure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try MailboxSendArguments.parse(args), file: file, line: line) { error in
            XCTAssertEqual(error as? MailboxSendArguments.Failure, expected, file: file, line: line)
        }
    }

    func testPositionalBodyIsDeliveredOnTheEnvelope() throws {
        let parsed = try MailboxSendArguments.parse(["--to", "watcher", "build green sha=abc"])
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: parsed.to,
            body: parsed.body,
            id: idA,
            ts: "2026-10-01T12:00:00Z"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try envelope.encode()) as? [String: Any])
        XCTAssertEqual(object["body"] as? String, "build green sha=abc")
        XCTAssertEqual(object["to"] as? String, "watcher")
    }

    func testBodyFlagStillDelivers() throws {
        let parsed = try MailboxSendArguments.parse(["--to", "watcher", "--body", "from the flag"])
        XCTAssertEqual(parsed.body, "from the flag")
        XCTAssertEqual(try MailboxEnvelope.build(from: "builder", to: parsed.to, body: parsed.body, id: idA, ts: "2026-10-01T12:00:00Z").body, "from the flag")
    }

    func testBodyRefAllowsAnEmptyBody() throws {
        let parsed = try MailboxSendArguments.parse(["--to", "watcher", "--body-ref", "/tmp/diff.patch"])
        XCTAssertEqual(parsed.body, "")
        XCTAssertEqual(parsed.bodyRef, "/tmp/diff.patch")
    }

    func testToParentParsesByItselfAndConflictsWithRecipientFlags() throws {
        let parsed = try MailboxSendArguments.parse(["--to-parent", "--body", "completion report"])
        XCTAssertTrue(parsed.toParent)
        XCTAssertNil(parsed.to)
        XCTAssertNil(parsed.toWorkspace)
        XCTAssertEqual(parsed.body, "completion report")

        assertSend(
            ["--to-parent", "--to", "owner", "--body", "report"],
            fails: .toParentConflict
        )
        assertSend(
            ["--to-parent", "--to-workspace", "workspace:2", "--body", "report"],
            fails: .toParentConflict
        )
    }

    func testEmptyBodyIsRefused() {
        assertSend(["--to", "watcher"], fails: .emptyBody)
        assertSend(["--to", "watcher", "--body", ""], fails: .emptyBody)
        XCTAssertTrue(MailboxSendArguments.Failure.emptyBody.description.contains("empty"))
    }

    func testBodyAndPositionalTogetherAreRefused() {
        assertSend(["--to", "watcher", "--body", "flag", "positional"], fails: .bodyConflict)
    }

    func testExtraPositionalIsRefused() {
        assertSend(["--to", "watcher", "one", "two"], fails: .extraArgument)
    }

    func testUnknownFlagIsRefused() {
        assertSend(["--to", "watcher", "--nope", "hello"], fails: .unknownFlag("--nope"))
        XCTAssertTrue(MailboxSendArguments.Failure.unknownFlag("--nope").description.contains("Unknown flag"))
        XCTAssertTrue(MailboxSendArguments.Failure.unknownFlag("--nope").description.contains("--nope"))
    }

    func testLiteralDashDashCanCarryFlagShapedText() throws {
        let parsed = try MailboxSendArguments.parse(["--to", "watcher", "--", "--nope"])
        XCTAssertEqual(parsed.body, "--nope")
    }

    func testRedirectedDrainLeavesTheEnvelopeUnread() throws {
        try deliver(body: "HANDOFF C11-361")
        var handedOff = false
        XCTAssertThrowsError(try MailboxRecvAdmission.consume(
            inboxes: [inbox],
            stdoutIsTTY: false,
            acknowledged: false
        ) { _ in
            handedOff = true
            return true
        }) { error in
            let message = (error as? MailboxRecvAdmission.Refusal)?.description ?? ""
            XCTAssertTrue(message.contains("recv --drain --ack"), message)
        }
        XCTAssertFalse(handedOff)
        XCTAssertEqual(messageNames(in: inbox), ["\(idA).msg"])
        XCTAssertEqual(messageNames(in: MailboxDrain.readURL(inbox: inbox)), [])
    }

    func testAcknowledgedDrainMarksTheEnvelopeRead() throws {
        try deliver(body: "HANDOFF C11-361")
        var printed = ""
        let result = try MailboxRecvAdmission.consume(
            inboxes: [inbox],
            stdoutIsTTY: false,
            acknowledged: true
        ) { message in
            printed += message.text
            return true
        }
        XCTAssertEqual(result.claimed.map(\.id), [idA])
        XCTAssertTrue(printed.contains("HANDOFF C11-361"))
        XCTAssertEqual(messageNames(in: inbox), [])
        XCTAssertEqual(messageNames(in: MailboxDrain.readURL(inbox: inbox)), ["\(idA).msg"])
    }

    func testTerminalDrainMarksReadWithoutAck() throws {
        try deliver(body: "visible")
        let result = try MailboxRecvAdmission.consume(
            inboxes: [inbox],
            stdoutIsTTY: true,
            acknowledged: false
        )
        XCTAssertEqual(result.claimed.map(\.id), [idA])
        XCTAssertEqual(messageNames(in: inbox), [])
    }

    func testRecvUnknownFlagIsRefused() {
        XCTAssertThrowsError(try MailboxRecvArguments.parse(["--drain", "--nope"])) { error in
            XCTAssertEqual(error as? MailboxRecvArguments.Failure, .unknownFlag("--nope"))
        }
    }

    func testRecvTabAliasAndAckParse() throws {
        let parsed = try MailboxRecvArguments.parse(["--drain", "--ack", "--tab", "watcher"])
        XCTAssertTrue(parsed.drains)
        XCTAssertTrue(parsed.ack)
        XCTAssertEqual(parsed.panel, "watcher")
        XCTAssertEqual(parsed.panelFlag, "--tab")
        let peek = try MailboxRecvArguments.parse(["--peek"])
        XCTAssertFalse(peek.drains)
        XCTAssertNil(peek.panelFlag)
    }

    func testBodyFlagKeepsDashPrefixedText() throws {
        let frontMatter = try MailboxSendArguments.parse(["--to", "watcher", "--body", "---\nBuild green"])
        XCTAssertEqual(frontMatter.body, "---\nBuild green")
        let flagShaped = try MailboxSendArguments.parse(["--to", "watcher", "--body", "--nope"])
        XCTAssertEqual(flagShaped.body, "--nope")
        let help = try MailboxSendArguments.parse(["--to", "watcher", "--body", "--help"])
        XCTAssertEqual(help.body, "--help")
        let shortHelp = try MailboxSendArguments.parse(["--to", "watcher", "--body", "-h"])
        XCTAssertEqual(shortHelp.body, "-h")
    }

    func testBodyFlagStillRequiresAValueAndOtherFlagsRejectDashes() {
        assertSend(["--to", "watcher", "--body"], fails: .flagNeedsValue("--body"))
        assertSend(["--to", "--nope", "hello"], fails: .flagNeedsValue("--to"))
    }

    func testRetryCommandRepeatsArgvAndAppendsAck() {
        XCTAssertEqual(
            MailboxRecvAdmission.retryCommand(arguments: ["/tmp/c11", "mailbox", "recv", "--drain"]),
            "c11 mailbox recv --drain --ack"
        )
        XCTAssertEqual(
            MailboxRecvAdmission.retryCommand(arguments: [
                "/Applications/c11 DEV.app/Contents/MacOS/c11",
                "--socket", "/tmp/target socket",
                "mailbox", "recv", "--panel", "other", "--drain",
            ]),
            "c11 --socket '/tmp/target socket' mailbox recv --panel other --drain --ack"
        )
        XCTAssertEqual(
            MailboxRecvAdmission.retryCommand(arguments: [
                "c11", "--socket", "/tmp/target socket", "--window", "window:1",
                "mailbox", "recv", "--tab", "other", "--drain",
            ]),
            "c11 --socket '/tmp/target socket' --window window:1 mailbox recv --tab other --drain --ack"
        )
        XCTAssertEqual(
            MailboxRecvAdmission.retryCommand(arguments: [
                "c11", "--socket", "/tmp/target socket",
                "mailbox", "recv", "--surface", "other agent's inbox", "--drain",
            ]),
            "c11 --socket '/tmp/target socket' mailbox recv --surface 'other agent'\\''s inbox' --drain --ack"
        )
        let refusal = MailboxRecvAdmission.Refusal(
            retryCommand: MailboxRecvAdmission.retryCommand(arguments: [
                "/tmp/c11", "--socket", "/tmp/target socket",
                "mailbox", "recv", "--panel", "other", "--drain",
            ])
        )
        XCTAssertTrue(refusal.description.contains("--socket '/tmp/target socket'"))
        XCTAssertTrue(refusal.description.contains("--panel other --drain --ack"))
        XCTAssertTrue(MailboxRecvAdmission.Refusal().description.contains("recv --drain --ack"))
    }

}
