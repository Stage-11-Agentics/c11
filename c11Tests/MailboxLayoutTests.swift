import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MailboxLayoutTests: XCTestCase {

    private let stateURL = URL(fileURLWithPath: "/tmp/c11-test-state", isDirectory: true)

    private func stubWorkspace() -> UUID {
        // Fixed UUID keeps the expected path stable across runs.
        UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    }

    // MARK: - Path shape

    func testMailboxesRoot() {
        let ws = stubWorkspace()
        let url = MailboxLayout.mailboxesRoot(state: stateURL, workspaceId: ws)
        XCTAssertEqual(
            url.path,
            "/tmp/c11-test-state/workspaces/\(ws.uuidString)/mailboxes"
        )
    }

    func testOutboxURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.outboxURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(
            url.path,
            "/tmp/c11-test-state/workspaces/\(ws.uuidString)/mailboxes/_outbox"
        )
    }

    func testProcessingURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.processingURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(url.lastPathComponent, "_processing")
    }

    func testRejectedURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.rejectedURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(url.lastPathComponent, "_rejected")
    }

    func testBlobsURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.blobsURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(url.lastPathComponent, "blobs")
    }

    func testDispatchLogURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.dispatchLogURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(url.lastPathComponent, "_dispatch.log")
        XCTAssertFalse(url.hasDirectoryPath)
    }

    func testInboxURLIsKeyedOnLowercasedTabUUID() {
        let ws = stubWorkspace()
        let tab = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000BEEF")!
        let url = MailboxLayout.inboxURL(state: stateURL, workspaceId: ws, tabId: tab)
        XCTAssertEqual(
            url.path,
            "/tmp/c11-test-state/workspaces/\(ws.uuidString)/mailboxes/a1b2c3d4-0000-4000-8000-00000000beef"
        )
    }

    func testLegacyInboxURLKeepsSafeTitles() {
        let ws = stubWorkspace()
        XCTAssertEqual(
            MailboxLayout.legacyInboxURL(state: stateURL, workspaceId: ws, panelName: "build watcher")?
                .lastPathComponent,
            "build watcher"
        )
        XCTAssertEqual(
            MailboxLayout.legacyInboxURL(state: stateURL, workspaceId: ws, panelName: "ビルダー")?
                .lastPathComponent,
            "ビルダー"
        )
    }

    /// Titles that could never have been a directory, or that name the tree's
    /// own directories, have no legacy inbox.
    func testLegacyInboxURLRejectsUnsafeAndReservedTitles() {
        let ws = stubWorkspace()
        let long = "MRQ-214 [review]: " + String(repeating: "x", count: 90)
        for title in ["a/b: c", long, "../escape", ".hidden", "", "_outbox", "_read", "blobs"] {
            XCTAssertNil(
                MailboxLayout.legacyInboxURL(state: stateURL, workspaceId: ws, panelName: title),
                title
            )
        }
    }

    func testRecvInboxURLsReadsCanonicalThenExistingLegacy() throws {
        let state = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let ws = stubWorkspace()
        let tab = UUID()

        // No legacy directory on disk: only the canonical inbox.
        XCTAssertEqual(
            MailboxLayout.recvInboxURLs(state: state, workspaceId: ws, tabId: tab, panelName: "watcher"),
            [MailboxLayout.inboxURL(state: state, workspaceId: ws, tabId: tab)]
        )

        let legacy = try XCTUnwrap(
            MailboxLayout.legacyInboxURL(state: state, workspaceId: ws, panelName: "watcher")
        )
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(
            MailboxLayout.recvInboxURLs(state: state, workspaceId: ws, tabId: tab, panelName: "watcher"),
            [MailboxLayout.inboxURL(state: state, workspaceId: ws, tabId: tab), legacy]
        )
        // Tab UUID unknown (a `--surface` name c11 could not resolve): legacy only.
        XCTAssertEqual(
            MailboxLayout.recvInboxURLs(state: state, workspaceId: ws, tabId: nil, panelName: "watcher"),
            [legacy]
        )
        // A title-unsafe name never yields a legacy path.
        XCTAssertEqual(
            MailboxLayout.recvInboxURLs(state: state, workspaceId: ws, tabId: tab, panelName: "a/b: c"),
            [MailboxLayout.inboxURL(state: state, workspaceId: ws, tabId: tab)]
        )
    }

    func testReadURLIsInsideInbox() {
        let inbox = MailboxLayout.inboxURL(state: stateURL, workspaceId: stubWorkspace(), tabId: UUID())
        XCTAssertEqual(MailboxLayout.readURL(inbox: inbox).deletingLastPathComponent().path, inbox.path)
        XCTAssertEqual(MailboxLayout.readURL(inbox: inbox).lastPathComponent, "_read")
    }

    // MARK: - Filenames

    func testEnvelopeFilename() {
        XCTAssertEqual(
            MailboxLayout.envelopeFilename(id: "01K3A2B7X8PQRTVWYZ0123456J"),
            "01K3A2B7X8PQRTVWYZ0123456J.msg"
        )
    }

    func testTempFilename() {
        XCTAssertEqual(
            MailboxLayout.tempFilename(id: "01K3A2B7X8PQRTVWYZ0123456J"),
            ".01K3A2B7X8PQRTVWYZ0123456J.tmp"
        )
    }

    func testRejectedErrorFilename() {
        XCTAssertEqual(
            MailboxLayout.rejectedErrorFilename(id: "01K3A2B7X8PQRTVWYZ0123456J"),
            "01K3A2B7X8PQRTVWYZ0123456J.err"
        )
    }

    // MARK: - Surface-name validation

    func testRejectsEmpty() {
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName("")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: "", reason: .empty)
            )
        }
    }

    func testRejectsForwardSlash() {
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName("nested/path")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: "nested/path", reason: .containsPathSeparator)
            )
        }
    }

    func testRejectsNullByte() {
        let evil = "foo\u{0}bar"
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName(evil)) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: evil, reason: .containsNullByte)
            )
        }
    }

    func testRejectsParentReference() {
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName("..")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: "..", reason: .parentReference)
            )
        }
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName(".")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: ".", reason: .parentReference)
            )
        }
    }

    func testRejectsLeadingDot() {
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName(".hidden")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: ".hidden", reason: .leadingDot)
            )
        }
    }

    func testRejectsOverlongName() {
        // 65 ASCII bytes → over the 64-byte cap.
        let overlong = String(repeating: "x", count: MailboxLayout.maxSurfaceNameBytes + 1)
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName(overlong)) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: overlong, reason: .tooLong)
            )
        }
    }

    func testAcceptsNameAtByteCap() {
        let exactly64 = String(repeating: "x", count: MailboxLayout.maxSurfaceNameBytes)
        XCTAssertNoThrow(try MailboxLayout.validateSurfaceName(exactly64))
    }
}
