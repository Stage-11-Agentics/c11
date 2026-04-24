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

    func testInboxURL() throws {
        let ws = stubWorkspace()
        let url = try MailboxLayout.inboxURL(
            state: stateURL,
            workspaceId: ws,
            surfaceName: "builder"
        )
        XCTAssertEqual(
            url.path,
            "/tmp/c11-test-state/workspaces/\(ws.uuidString)/mailboxes/builder"
        )
    }

    func testInboxAllowsSpacesInSurfaceNames() throws {
        let ws = stubWorkspace()
        // Alignment doc §3: surface names may contain spaces. Comma is reserved
        // as a metadata list separator but no layout rule forbids it in names.
        let url = try MailboxLayout.inboxURL(
            state: stateURL,
            workspaceId: ws,
            surfaceName: "build watcher"
        )
        XCTAssertEqual(url.lastPathComponent, "build watcher")
    }

    func testInboxAllowsUnicodeSurfaceNames() throws {
        let ws = stubWorkspace()
        let url = try MailboxLayout.inboxURL(
            state: stateURL,
            workspaceId: ws,
            surfaceName: "ビルダー"
        )
        XCTAssertEqual(url.lastPathComponent, "ビルダー")
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

    func testInboxRejectsInvalidName() {
        let ws = stubWorkspace()
        XCTAssertThrowsError(
            try MailboxLayout.inboxURL(state: stateURL, workspaceId: ws, surfaceName: "../escape")
        )
    }
}
