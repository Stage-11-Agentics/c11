import XCTest
import Darwin

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class TerminalControllerSocketSecurityTests: XCTestCase {
    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("csec-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testSocketPermissionsFollowAccessMode() throws {
        let workspaceManager = WorkspaceManager()

        let allowAllPath = makeSocketPath("allow-all")
        TerminalController.shared.start(
            workspaceManager: workspaceManager,
            socketPath: allowAllPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: allowAllPath)
        XCTAssertEqual(try socketMode(at: allowAllPath), 0o666)

        TerminalController.shared.stop()

        let restrictedPath = makeSocketPath("c11-only")
        TerminalController.shared.start(
            workspaceManager: workspaceManager,
            socketPath: restrictedPath,
            accessMode: .c11Only
        )
        try waitForSocket(at: restrictedPath)
        XCTAssertEqual(try socketMode(at: restrictedPath), 0o600)
    }

    func testSocketCommandPolicyDistinguishesFocusIntent() throws {
#if DEBUG
        let nonFocus = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "ping",
            isV2: false
        )
        XCTAssertTrue(nonFocus.insideSuppressed)
        XCTAssertFalse(nonFocus.insideAllowsFocus)
        XCTAssertFalse(nonFocus.outsideSuppressed)
        XCTAssertFalse(nonFocus.outsideAllowsFocus)

        let focusV1 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "focus_window",
            isV2: false
        )
        XCTAssertFalse(focusV1.insideSuppressed)
        XCTAssertTrue(focusV1.insideAllowsFocus)
        XCTAssertFalse(focusV1.outsideSuppressed)

        let focusWindowV2 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "window.focus",
            isV2: true
        )
        XCTAssertFalse(focusWindowV2.insideSuppressed)
        XCTAssertTrue(focusWindowV2.insideAllowsFocus)

        let focusV2 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.select",
            isV2: true
        )
        XCTAssertTrue(focusV2.insideSuppressed)
        XCTAssertTrue(focusV2.insideAllowsFocus)
        XCTAssertFalse(focusV2.outsideSuppressed)

        let selectWorkspaceV1 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "select_workspace",
            isV2: false
        )
        XCTAssertTrue(selectWorkspaceV1.insideSuppressed)
        XCTAssertTrue(selectWorkspaceV1.insideAllowsFocus)

        let moveWorkspace = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.move_to_window",
            isV2: true
        )
        XCTAssertTrue(moveWorkspace.insideSuppressed)
        XCTAssertFalse(moveWorkspace.insideAllowsFocus)

        let triggerFlash = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "surface.trigger_flash",
            isV2: true
        )
        XCTAssertTrue(triggerFlash.insideSuppressed)
        XCTAssertFalse(triggerFlash.insideAllowsFocus)
#else
        throw XCTSkip("Socket command policy snapshot helper is debug-only.")
#endif
    }

    func testConcurrentSocketPoliciesStayOnTheirOwnRequest() async {
        let controller = TerminalController.shared
        let firstEntered = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let letFirstFinish = DispatchSemaphore(value: 0)
        let letSecondFinish = DispatchSemaphore(value: 0)
        let first = Task.detached {
            controller.withSocketCommandPolicy(commandKey: "workspace.select", isV2: true) {
                firstEntered.signal()
                _ = letFirstFinish.wait(timeout: .now() + 5)
                return TerminalController.socketCommandAllowsInAppFocusMutations()
            }
        }
        _ = firstEntered.wait(timeout: .now() + 5)
        let second = Task.detached {
            controller.withSocketCommandPolicy(commandKey: "ping", isV2: false) {
                secondEntered.signal()
                _ = letSecondFinish.wait(timeout: .now() + 5)
                return TerminalController.socketCommandAllowsInAppFocusMutations()
            }
        }
        _ = secondEntered.wait(timeout: .now() + 5)
        // Neither worker request contaminates the operator's main thread.
        XCTAssertFalse(TerminalController.shouldSuppressSocketCommandActivation())
        letFirstFinish.signal()
        let firstAllowed = await first.value
        XCTAssertTrue(firstAllowed)
        letSecondFinish.signal()
        let secondAllowed = await second.value
        XCTAssertFalse(secondAllowed)
        XCTAssertNil(SocketCommandContext.current)
    }

    func testPingHasContextFreeSocketWorkerResponse() async {
        let response = await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return TerminalController.socketWorkerImmediateV1Response("  PING  ")
        }.value

        XCTAssertEqual(response, "PONG")
        XCTAssertNil(TerminalController.socketWorkerImmediateV1Response("list_windows"))
        XCTAssertNil(TerminalController.socketWorkerImmediateV1Response(#"{"method":"system.ping"}"#))
    }

    func testRemoteStatusPayloadOmitsSensitiveSSHConfiguration() {
        let workspaceManager = WorkspaceManager()
        let workspace = workspaceManager.addWorkspace(select: false, eagerLoadTerminal: false)

        workspace.configureRemoteConnection(
            .init(
                destination: "example.com",
                port: 2222,
                identityFile: "/Users/test/.ssh/id_ed25519",
                sshOptions: ["ControlMaster=auto", "ControlPersist=600"],
                localProxyPort: 1080,
                relayPort: 4444,
                relayID: "relay-id",
                relayToken: "relay-token",
                localSocketPath: "/tmp/cmux-test.sock",
                terminalStartupCommand: "ssh example.com"
            ),
            autoConnect: false
        )

        let payload = workspace.remoteStatusPayload()
        XCTAssertNil(payload["identity_file"])
        XCTAssertNil(payload["ssh_options"])
        XCTAssertEqual(payload["has_identity_file"] as? Bool, true)
        XCTAssertEqual(payload["has_ssh_options"] as? Bool, true)
    }

    private func waitForSocket(at path: String, timeout: TimeInterval = 2.0) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: path)
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return
        }
        XCTFail("Timed out waiting for socket at \(path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    private func socketMode(at path: String) throws -> UInt16 {
        var fileInfo = stat()
        guard lstat(path, &fileInfo) == 0 else {
            throw posixError("lstat(\(path))")
        }
        return UInt16(fileInfo.st_mode & 0o777)
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
