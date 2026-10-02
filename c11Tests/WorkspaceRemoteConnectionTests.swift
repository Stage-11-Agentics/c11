import XCTest

#if canImport(c11)
@testable import c11
#elseif canImport(c11_DEV)
@testable import c11_DEV
#endif

final class WorkspaceRemoteConnectionTests: XCTestCase {
    func testRemoteCommandRelayDoesNotStartListener() {
        XCTAssertThrowsError(try WorkspaceRemoteCLIRelayServer().start()) { error in
            XCTAssertEqual(error.localizedDescription, "c11 commands are not available over c11 ssh in this version")
        }
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
}
