import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class AgentStartupProbeTests: XCTestCase {
    private func process(
        _ name: String, pid: Int32 = 42, group: Int32 = 42, arguments: [String] = []
    ) -> AgentStartupProbe.ProcessSnapshot {
        .init(pid: pid, processGroup: group, executablePath: "/fixture/bin/\(name)", arguments: arguments)
    }

    private func evidence(
        _ processes: [AgentStartupProbe.ProcessSnapshot], kind: String = "codex", group: Int32 = 42
    ) -> AgentStartupProbe.Evidence? {
        AgentStartupProbe.identifiedProcess(in: .init(foregroundGroup: group, processes: processes), expectedKind: kind)
    }

    func testNativeAgentMustBeInActualForegroundGroup() {
        XCTAssertEqual(evidence([process("codex")]), .init(pid: 42, executable: "codex"))
        XCTAssertNil(evidence([process("codex", pid: 999, group: 999), process("zsh")]))
    }

    func testGroupMemberNativeChildIsObservedEvenWhenWrapperIsGroupLeader() {
        XCTAssertEqual(evidence([
            process("node", arguments: ["node", "/pkg/@openai/codex/bin/codex.js"]),
            process("codex", pid: 43),
        ]), .init(pid: 43, executable: "codex"))
    }

    func testShellWrapperAndUnrelatedHelperNeverEstablishStartup() {
        XCTAssertNil(evidence([process("zsh", arguments: ["codex", "--yolo"])]))
        XCTAssertNil(evidence([process("codex-helper")]))
        XCTAssertNil(evidence([process("grok-pager")], kind: "grok"))
        XCTAssertNil(evidence([process("sleep", arguments: ["sleep", "30"])]))
    }

    func testJSLauncherIsNotCodexProcessProof() {
        XCTAssertNil(evidence([process("node", arguments: ["node", "/pkg/@openai/codex/bin/codex.js"])]))
    }

    func testClaudeNodeEntrypointProvidesProcessEvidence() {
        XCTAssertEqual(evidence([
            process("node", arguments: ["node", "/pkg/@anthropic-ai/claude-code/cli.js", "private prompt"]),
        ], kind: "claude-code"), .init(pid: 42, executable: "node"))
    }

    func testClaudeNativeInstallerVersionPathProvidesProcessEvidence() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions/2.1.284").path
        let native = AgentStartupProbe.ProcessSnapshot(pid: 42, processGroup: 42, executablePath: path, arguments: [])
        XCTAssertEqual(evidence([native], kind: "claude-code"), .init(pid: 42, executable: "2.1.284"))
        XCTAssertNil(evidence([native], kind: "codex"))
    }

    func testVersionNamesOutsideExactClaudeInstallerDirectoryAreNotIdentity() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions").path
        for path in [
            "/tmp/unrelated/2.1.284",
            "/tmp/.local/share/claude/versions/2.1.284",
            "\(directory)/helpers/2.1.284",
            "\(directory)/2.1.284.old",
            "\(directory)/2.1",
            "\(directory)/2.x.284",
            "\(directory)/２.1.284",
        ] {
            let unrelated = AgentStartupProbe.ProcessSnapshot(pid: 42, processGroup: 42, executablePath: path, arguments: [])
            XCTAssertNil(evidence([unrelated], kind: "claude-code"), path)
        }
    }

    func testKimiPythonScriptAndModuleForms() {
        XCTAssertNotNil(evidence([process("python3.13", arguments: ["python3", "/home/bin/kimi"])], kind: "kimi"))
        XCTAssertNotNil(evidence([process("python3", arguments: ["python3", "-m", "kimi_cli"])], kind: "kimi"))
        XCTAssertNil(evidence([process("python3", arguments: ["python3", "-m", "unrelated"])], kind: "kimi"))
    }

    func testAgentNamesAndPackagePathsInsidePromptsAreNotIdentity() {
        XCTAssertNil(evidence([
            process("node", arguments: ["node", "/tmp/unrelated.js", "/pkg/@anthropic-ai/claude-code/cli.js"]),
        ], kind: "claude-code"))
        XCTAssertNil(evidence([process("node", arguments: ["node", "-e", "require('claude')"])], kind: "claude-code"))
        XCTAssertNil(evidence([process("python3", arguments: ["python3", "/tmp/not-kimi.py", "/home/bin/kimi"])], kind: "kimi"))
    }

    func testAmbiguousAndUnknownIdentitiesRemainPending() {
        XCTAssertNil(evidence([process("codex"), process("codex", pid: 43)]))
        XCTAssertNil(evidence([process("custom")], kind: "custom"))
        XCTAssertNil(evidence([process("codex")], group: 0))
    }

    func testObservationPollsForLateTTYAndTargetWithoutGuessingReadiness() {
        var clock = Date(timeIntervalSince1970: 100)
        var resolutionCount = 0
        var snapshots = 0
        let result = AgentStartupProbe.observe(
            ttyName: { resolutionCount += 1; return resolutionCount > 1 ? "ttys-test" : nil },
            expectedKind: "codex", deadline: clock.addingTimeInterval(8),
            snapshot: { tty in
                XCTAssertEqual(tty, "ttys-test")
                snapshots += 1
                return .init(foregroundGroup: 42, processes: [self.process(snapshots > 1 ? "codex" : "zsh")])
            },
            now: { clock }, sleep: { clock = clock.addingTimeInterval($0) }
        )
        XCTAssertEqual(result.status, .started)
        XCTAssertEqual(result.process, .init(pid: 42, executable: "codex"))
        XCTAssertEqual(resolutionCount, 3)
    }

    func testObservationCapsAtFiveSecondsAndUsesTwoHundredMillisecondPolls() {
        let start = Date(timeIntervalSince1970: 100)
        var clock = start
        var pauses: [TimeInterval] = []
        let result = AgentStartupProbe.observe(
            ttyName: { "ttys-test" }, expectedKind: "codex", deadline: start.addingTimeInterval(8),
            snapshot: { _ in .init(foregroundGroup: 42, processes: [self.process("zsh")]) },
            now: { clock }, sleep: { pauses.append($0); clock = clock.addingTimeInterval($0) }
        )
        XCTAssertEqual(result.status, .pending)
        XCTAssertNil(result.process)
        XCTAssertEqual(clock.timeIntervalSince(start), 5, accuracy: 0.0001)
        XCTAssertTrue(pauses.allSatisfy { $0 > 0 && $0 <= 0.2 })
    }

    func testAlreadySpentAdmissionTimeIsSharedWithProbe() {
        let start = Date(timeIntervalSince1970: 100)
        var clock = start.addingTimeInterval(7.5)
        let result = AgentStartupProbe.observe(
            ttyName: { nil }, expectedKind: "codex", deadline: start.addingTimeInterval(8),
            snapshot: { _ in XCTFail("unreported TTY must not be inspected"); return nil },
            now: { clock }, sleep: { clock = clock.addingTimeInterval($0) }
        )
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(clock.timeIntervalSince(start), 8, accuracy: 0.0001)
    }

    func testExpiredMainSnapshotCannotProduceLateSuccess() {
        var clock = Date(timeIntervalSince1970: 100)
        let result = AgentStartupProbe.observe(
            ttyName: { clock = clock.addingTimeInterval(2); return "ttys-test" },
            expectedKind: "codex", deadline: clock.addingTimeInterval(1),
            snapshot: { _ in XCTFail("deadline expired before process snapshot"); return nil },
            now: { clock }, sleep: { _ in XCTFail("deadline already expired") }
        )
        XCTAssertEqual(result.status, .pending)
    }

    func testUnknownCommandDoesNotPollOrClaimFailureFromSilence() {
        let clock = Date(timeIntervalSince1970: 100)
        let result = AgentStartupProbe.observe(
            ttyName: { XCTFail("unknown identity need not resolve TTY"); return nil },
            expectedKind: "custom-command", deadline: clock.addingTimeInterval(8),
            now: { clock }, sleep: { _ in XCTFail("unknown identity need not wait") }
        )
        XCTAssertEqual(result, .init(status: .pending, process: nil))
    }

    func testProcessSnapshotArrivingAfterDeadlineStaysPending() {
        var clock = Date(timeIntervalSince1970: 100)
        let result = AgentStartupProbe.observe(
            ttyName: { "ttys-test" }, expectedKind: "codex", deadline: clock.addingTimeInterval(1),
            snapshot: { _ in
                clock = clock.addingTimeInterval(2)
                return .init(foregroundGroup: 42, processes: [self.process("codex")])
            }, now: { clock }, sleep: { _ in XCTFail("deadline already expired") }
        )
        XCTAssertEqual(result, .init(status: .pending, process: nil))
    }

    func testNativeSnapshotReadsForegroundGroupInsteadOfHighestPIDOnRealPTY() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
                      "PTY fixture requires the Xcode Python interpreter")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("pty.json")
        let fixture = Process()
        let input = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-c", Self.ptyFixture, report.path]
        fixture.standardInput = input
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
            try? input.fileHandleForWriting.close()
            fixture.waitUntilExit() // fixture self-terminates after ten seconds
        }
        let deadline = Date().addingTimeInterval(3)
        var recorded: [String: Any]?
        while Date() < deadline {
            if let data = try? Data(contentsOf: report),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                recorded = object
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let object = try XCTUnwrap(recorded, "PTY fixture did not initialize")
        let tty = try XCTUnwrap(object["tty"] as? String)
        let foreground = try XCTUnwrap(object["foreground"] as? Int32)
        let background = try XCTUnwrap(object["background"] as? Int32)
        XCTAssertGreaterThan(background, foreground)
        var snapshot: AgentStartupProbe.Snapshot?
        while Date() < deadline {
            let sample = AgentStartupProbe.nativeSnapshot(ttyName: tty)
            if sample?.processes.contains(where: { $0.pid == foreground && $0.executablePath.hasSuffix("/sleep") }) == true {
                snapshot = sample
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let observed = try XCTUnwrap(snapshot, "kernel TTY snapshot unavailable")
        XCTAssertEqual(observed.foregroundGroup, foreground)
        XCTAssertTrue(observed.processes.contains { $0.pid == foreground })
        XCTAssertFalse(observed.processes.contains { $0.pid == background })
        XCTAssertNil(AgentStartupProbe.identifiedProcess(in: observed, expectedKind: "codex"))
    }

    private static let ptyFixture = """
    import os, sys, signal, fcntl, termios, json
    controller = os.fork()
    if controller:
        os.waitpid(controller, 0)
        sys.exit(0)
    os.setsid()
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    children = []
    def expire(*args):
        raise SystemExit(0)
    signal.signal(signal.SIGALRM, expire)
    signal.alarm(10)
    try:
        for index in range(2):
            child = os.fork()
            if child == 0:
                os.setpgid(0, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                os.execl('/bin/sleep', 'sleep', '30')
            try:
                os.setpgid(child, child)
            except PermissionError:
                if os.getpgid(child) != child:
                    raise
            children.append(child)
        os.tcsetpgrp(slave, children[0])
        with open(sys.argv[1], 'w') as output:
            json.dump(dict(tty=os.ttyname(slave), foreground=children[0], background=children[1]), output)
        sys.stdin.readline()
    finally:
        for child in children:
            try:
                os.kill(child, signal.SIGKILL)
                os.waitpid(child, 0)
            except ProcessLookupError:
                pass
        os.close(slave)
        os.close(master)
    """
}
