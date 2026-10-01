import XCTest
import Network

#if canImport(c11)
@testable import c11
#elseif canImport(c11_DEV)
@testable import c11_DEV
#endif

final class WorkspaceRemoteConnectionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error),
                timedOut: false
            )
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    func testRemoteRelayMetadataCleanupScriptRemovesMatchingSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64008.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64008.daemon_path")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64008".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
        defer { try? fileManager.removeItem(at: home) }

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                WorkspaceRemoteSessionController.remoteRelayMetadataCleanupScript(relayPort: 64008),
            ],
            timeout: 30  // generous hang-guard: the script is ms-fast; 5s flaked under CI WebProcess load
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(fileManager.fileExists(atPath: socketAddrURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: authURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: daemonPathURL.path))
    }

    func testRemoteRelayMetadataCleanupScriptPreservesDifferentSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-preserve-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64009.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64009.daemon_path")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64010".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
        defer { try? fileManager.removeItem(at: home) }

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                WorkspaceRemoteSessionController.remoteRelayMetadataCleanupScript(relayPort: 64009),
            ],
            timeout: 30  // generous hang-guard: the script is ms-fast; 5s flaked under CI WebProcess load
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(fileManager.fileExists(atPath: socketAddrURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: authURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: daemonPathURL.path))
    }

    func testRemoteCommandRelayDoesNotStartListener() {
        XCTAssertThrowsError(try WorkspaceRemoteCLIRelayServer().start()) { error in
            XCTAssertEqual(error.localizedDescription, "c11 commands are not available over c11 ssh in this version")
        }
    }

    func testRemoteCommandIsRefusedAfterSuccessfulHandshake() throws {
        // Exercise the retained refusal handler using a test-owned transport.
        // Production cannot create a relay listener.
        let queue = DispatchQueue(label: "c11.tests.remote-command-refusal")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "test transport ready")
        var session: WorkspaceRemoteCLIRelayServer.Session?
        listener.newConnectionHandler = { connection in
            let accepted = WorkspaceRemoteCLIRelayServer.Session(
                connection: connection,
                relayID: "test-session",
                relayToken: Data(repeating: 0x61, count: 32),
                queue: queue,
                onClose: {}
            )
            session = accepted
            accepted.start()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: queue)
        defer {
            listener.cancel()
            queue.sync { session?.stop() }
        }
        wait(for: [ready], timeout: 10)
        let port = try XCTUnwrap(listener.port).rawValue
        let script = """
        import hashlib, hmac, json, socket, sys
        with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=5) as sock:
            stream = sock.makefile('rwb', buffering=0)
            challenge = json.loads(stream.readline())
            message = 'relay_id={}\\nnonce={}\\nversion={}'.format(challenge['relay_id'], challenge['nonce'], challenge['version'])
            mac = hmac.new(b'a' * 32, message.encode(), hashlib.sha256).hexdigest()
            stream.write(json.dumps({'relay_id': challenge['relay_id'], 'mac': mac}).encode() + b'\\n')
            assert json.loads(stream.readline()) == {'ok': True}
            print('handshake accepted')
            stream.write(b'ping\\n')
            result = json.loads(stream.readline())
            assert result['ok'] is False, result
            assert result['error']['code'] == 'remote_commands_disabled', result
            print(result['error']['message'])
            assert stream.readline() == b''
        """
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["python3", "-c", script, String(port)],
            timeout: 15
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "handshake accepted\nc11 commands are not available over c11 ssh in this version\n")
    }

    func testSSHAgentEnvVarsPropagateToSpawnedProcess() throws {
        // Verify that setting process.environment = ProcessInfo.processInfo.environment
        // causes spawned processes to inherit SSH agent variables from the parent.
        let testKey = "C11_TEST_SSH_AGENT_VAR"
        let testValue = "/tmp/c11-test-ssh-agent-\(UUID().uuidString).sock"
        setenv(testKey, testValue, 1)
        defer { unsetenv(testKey) }

        // ProcessInfo must reflect the newly set variable.
        let capturedEnv = ProcessInfo.processInfo.environment
        XCTAssertEqual(capturedEnv[testKey], testValue, "ProcessInfo.environment must include newly set env var")

        // A process launched with the captured environment must see the var.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printenv")
        process.arguments = [testKey]
        process.environment = capturedEnv
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(output, testValue, "SSH agent env var must be visible in spawned process environment")
    }

    @MainActor
    func testProxyOnlyErrorsKeepSSHWorkspaceConnectedAndLoggedInSidebar() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to cmux-macmini unavailable: Failed to start local daemon proxy: daemon RPC timeout waiting for hello response (retry in 3s)"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "cmux-macmini")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(
            workspace.statusEntries["remote.error"]?.value,
            "Remote proxy unavailable (cmux-macmini): \(proxyError)"
        )
        XCTAssertEqual(workspace.logEntries.last?.source, "remote-proxy")
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, true)
        XCTAssertEqual(
            ((workspace.remoteStatusPayload()["proxy"] as? [String: Any])?["state"] as? String),
            "error"
        )

        workspace.applyRemoteConnectionStateUpdate(.connecting, detail: "Connecting to cmux-macmini", target: "cmux-macmini")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(
            workspace.statusEntries["remote.error"]?.value,
            "Remote proxy unavailable (cmux-macmini): \(proxyError)"
        )

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:9999",
            target: "cmux-macmini"
        )

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.statusEntries["remote.error"])
        XCTAssertEqual(
            ((workspace.remoteStatusPayload()["proxy"] as? [String: Any])?["state"] as? String),
            "unavailable"
        )
    }
}
