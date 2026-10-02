import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-258: execute the actual composed line through an interactive zsh PTY,
/// then compare the fake harness's file receipt with the exact staged body.
final class LaunchPromptDeliveryTests: XCTestCase {
    func testTypedPlannerRejectsAnUnstagedBody() {
        let result = AgentLaunchPlanner.plan(
            request: AgentLaunchRequest(kind: "codex", prompt: "body"),
            userDefault: .factory, projectConfig: nil, userTemplate: nil
        )
        guard case .failure(let error) = result else { return XCTFail("body must be staged") }
        XCTAssertEqual(error, .promptFileRequired)
    }

    func testLongBodiesRunThroughBothArgvDeliveryShapesWithLiteralBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LaunchPromptStore(rootDirectory: root.appendingPathComponent("owned space ' $ runtime"))
        let fake = root.appendingPathComponent("fake agent.py")
        try #"""
#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
if args[0] == '--prompt':
    args = args[1:]
instruction = args[0]
prefix, suffix = 'Read the file at ', ' and follow it exactly.'
assert instruction.startswith(prefix) and instruction.endswith(suffix)
path = instruction[len(prefix):-len(suffix)]
data = pathlib.Path(path).read_bytes()
pathlib.Path(os.environ['C11_LAUNCH_AGENT_RECEIPT']).write_text(json.dumps({
    'instruction': instruction, 'file_sha256': hashlib.sha256(data).hexdigest(), 'file_bytes': len(data)
}))
"""#.write(to: fake, atomically: true, encoding: .utf8)
        let harness = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/launch_agent_pty_harness.py")
        let command = "/usr/bin/env python3 " + DefaultAgentResolver.shellQuote(fake.path)
        let sentinel = root.appendingPathComponent("injected")
        for length in [500, 1300, 32 * 1024] {
            let body = "  Quotes ' \" `touch \(sentinel.path)` $(touch \(sentinel.path)) $HOME\nUnicode 日本語 🦉\n"
                + String(repeating: "x", count: length) + "\n trailing  "
            let staged = try store.stage(prompt: body)
            defer { store.discard(staged) }
            for kind in ["codex", "opencode"] {
                let template = UserAgentLaunchTemplate(command: command, modelFlag: nil, effortFlag: nil,
                    effortValues: nil, promptDelivery: kind == "codex" ? "positional" : "--prompt", env: nil)
                let plan = try AgentLaunchPlanner.plan(
                    request: AgentLaunchRequest(kind: "fixture-\(kind)", prompt: body),
                    userDefault: .factory, projectConfig: nil, userTemplate: template,
                    promptFilePath: staged.url.path
                ).get()
                XCTAssertLessThan(plan.launchLine.utf8.count, 1024)
                XCTAssertFalse(plan.launchLine.contains(body))
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", harness.path, "--command", plan.launchLine,
                                     "--expected-file", staged.url.path, "--timeout", "5"]
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let captured = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: captured, as: UTF8.self)
                XCTAssertEqual(process.terminationStatus, 0, text)
                let observation = try XCTUnwrap(try JSONSerialization.jsonObject(with: captured) as? [String: Any])
                XCTAssertEqual(observation["success"] as? Bool, true, text)
                XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path), "body was interpreted as shell code")
                XCTAssertEqual(try Data(contentsOf: staged.url), Data(body.utf8))
            }
        }
    }

    func testPostBootAndExistingTabCarryOnlyAFileInstruction() {
        let path = "/tmp/owned path.txt"
        let typed = LaunchPromptDelivery.compose(command: "kimi", delivery: .postBoot, promptFilePath: path)
        XCTAssertEqual(typed.launchLine, "kimi")
        XCTAssertEqual(typed.delayedPrompt, LaunchPromptDelivery.instruction(path: path))
        let existing = DefaultAgentLaunchComposition.plan(agent: .codex, bareCommand: "codex --yolo",
                                                         cwd: "/tmp/project space", promptFilePath: path)
        XCTAssertEqual(existing.launchLine, "cd '/tmp/project space' && codex --yolo")
        XCTAssertEqual(existing.delayedPrompt, LaunchPromptDelivery.instruction(path: path))
    }

    func testSettingsResolverPreservesBodyWithoutInliningIt() {
        let body = "  synthetic\n literal ' $() 🦉  "
        var config = DefaultAgentConfig.factory
        config.agents[.claudeCode] = AgentConfig(command: "claude", initialPrompt: body, envOverridesText: "")
        let (_, launch) = DefaultAgentResolver.resolve(explicitAgent: .claudeCode, userDefault: config, projectConfig: nil)
        XCTAssertEqual(launch.initialPrompt, body)
        XCTAssertEqual(launch.command, "claude")
    }

    func testDeadlineCancelsUnstartedMainAdmission() {
        let gate = AgentLaunchDeadlineGate<Bool>(deadline: Date().addingTimeInterval(0.01)) {
            XCTFail("cancelled main work must not send a command")
            return true
        }
        var queued: (@Sendable () -> Void)?
        gate.enqueue { queued = $0 }
        XCTAssertNil(gate.wait())
        XCTAssertTrue(gate.cancelledBeforeStart)
        queued?()
    }

    func testWorkerDeadlineDoesNotWaitIndefinitelyForRunningMainWork() {
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let gate = AgentLaunchDeadlineGate<Bool>(deadline: Date().addingTimeInterval(0.1)) {
            started.signal()
            finish.wait()
            completed.signal()
            return true
        }
        gate.enqueue { DispatchQueue.global().async(execute: $0) }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let before = Date()
        XCTAssertNil(gate.wait())
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.5)
        XCTAssertFalse(gate.cancelledBeforeStart, "running main work owns any staged files")
        finish.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    }
}
