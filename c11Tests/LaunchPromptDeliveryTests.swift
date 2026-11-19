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

    /// A headline leads the first message as one literal line: a shell sees no
    /// newline, expansion or quote break in it, and the file pointer follows.
    func testAHeadlineLeadsTheInstructionAsOneLiteralLine() throws {
        let headline = "Piece \"1\" of 4: it's $(touch /tmp/nope) `id` $HOME\nsecond\tline\u{07}"
        let plan = LaunchPromptDelivery.compose(command: "/usr/bin/printf %s", delivery: .positional,
                                                promptFilePath: "/tmp/p q.md", headline: headline)
        let expected = "Piece \"1\" of 4: it's $(touch /tmp/nope) `id` $HOME second line "
            + "Read the file at /tmp/p q.md and follow it exactly."
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", "-c", plan.launchLine]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), expected)

        let long = LaunchPromptDelivery.instruction(path: "/p", headline: String(repeating: "z ", count: 400))
        XCTAssertTrue(long.hasSuffix("… Read the file at /p and follow it exactly."))
        XCTAssertEqual(LaunchPromptDelivery.instruction(path: "/p", headline: " \n "),
                       LaunchPromptDelivery.instruction(path: "/p"))
        for leading in ["--model x", "/clear now", "! rm", "-- -/ !"] {
            XCTAssertFalse(LaunchPromptDelivery.instruction(path: "/p", headline: leading).first.map { "-/!".contains($0) } ?? true,
                           leading)
        }
        XCTAssertEqual(LaunchPromptDelivery.sanitizedHeadline("--model x"), "model x")
        XCTAssertNil(LaunchPromptDelivery.sanitizedHeadline("-- / !"))
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

    @MainActor
    func testPostBootDelayStartsAtActualLauncherSubmissionAfterLateAttachment() {
        var now: TimeInterval = 0
        var live = true
        var attached = false
        var jobs: [(TimeInterval, @MainActor () -> Void)] = []
        var writes: [(String, TimeInterval)] = []
        var launcherCompletion: ((Bool) -> Void)?
        let sequence = LaunchPostBootSequence(
            launcher: "kimi --auto", prompt: "Read the file at /fixture and follow it exactly.",
            isLive: { live }, isReady: { attached },
            submit: { text, completion in
                writes.append((text, now))
                if writes.count == 1 { launcherCompletion = completion } else { completion(true) }
            }, schedule: { delay, work in jobs.append((now + delay, work)) })
        func advance(to deadline: TimeInterval) {
            while let index = jobs.indices.min(by: { jobs[$0].0 < jobs[$1].0 }), jobs[index].0 <= deadline {
                let next = jobs.remove(at: index)
                now = next.0
                next.1()
            }
            now = deadline
        }
        sequence.start()
        advance(to: 3)
        XCTAssertTrue(writes.isEmpty, "no launcher/prompt enters an unattached submit buffer")
        attached = true
        advance(to: 3.25)
        XCTAssertEqual(writes.map { $0.0 }, ["kimi --auto"])
        advance(to: 7)
        XCTAssertEqual(writes.count, 1, "paste alone must not start the delay")
        launcherCompletion?(true)
        advance(to: 9.49)
        XCTAssertEqual(writes.count, 1)
        advance(to: 9.5)
        XCTAssertEqual(writes.map { $0.0 }, ["kimi --auto", "Read the file at /fixture and follow it exactly."])
        XCTAssertEqual(writes.last?.1, 9.5)
        live = false
    }

    @MainActor
    func testPostBootPromptWaitsBehindADialogAndNeverTypesIntoIt() {
        var now: TimeInterval = 0
        var jobs: [(TimeInterval, @MainActor () -> Void)] = []
        var writes: [(String, TimeInterval)] = []
        var dialogUp = false
        let sequence = LaunchPostBootSequence(
            launcher: "codex", prompt: "Read the file at /fixture and follow it exactly.",
            isLive: { true }, isReady: { true },
            submit: { text, completion in writes.append((text, now)); completion(true) },
            isBlockedByDialog: { dialogUp },
            schedule: { delay, work in jobs.append((now + delay, work)) })
        func advance(to deadline: TimeInterval) {
            while let index = jobs.indices.min(by: { jobs[$0].0 < jobs[$1].0 }), jobs[index].0 <= deadline {
                let next = jobs.remove(at: index)
                now = next.0
                next.1()
            }
            now = deadline
        }
        // The launcher goes to a shell and is never held; the trust chooser then comes up.
        dialogUp = true
        sequence.start()
        XCTAssertEqual(writes.map { $0.0 }, ["codex"], "a dialog does not hold the launcher line")
        advance(to: 60)
        XCTAssertEqual(writes.count, 1, "the prompt and its Return are held for a minute behind the chooser")
        dialogUp = false   // a person answered it
        advance(to: 61)
        XCTAssertEqual(writes.map { $0.0 }, ["codex", "Read the file at /fixture and follow it exactly."])
        XCTAssertGreaterThanOrEqual(writes[1].1, 60)
    }

    @MainActor
    func testPostBootPromptIsDroppedNotTypedIfTheDialogOutlastsTheBound() {
        var now: TimeInterval = 0
        var jobs: [(TimeInterval, @MainActor () -> Void)] = []
        var writes: [String] = []
        let sequence = LaunchPostBootSequence(
            launcher: "agent", prompt: "never into a chooser",
            isLive: { true }, isReady: { true },
            submit: { text, completion in writes.append(text); completion(true) },
            isBlockedByDialog: { true },
            schedule: { delay, work in jobs.append((now + delay, work)) })
        sequence.start()
        var steps = 0
        while let index = jobs.indices.min(by: { jobs[$0].0 < jobs[$1].0 }), steps < 5_000 {
            let next = jobs.remove(at: index)
            now = next.0
            next.1()
            steps += 1
        }
        XCTAssertEqual(writes, ["agent"])
        XCTAssertTrue(jobs.isEmpty, "no work is left after the bound")
        XCTAssertGreaterThanOrEqual(now, TimeInterval(LaunchPostBootSequence.maxDialogWaits) * LaunchPostBootSequence.dialogRecheck)
    }

    @MainActor
    func testPostBootNeverSendsPromptAfterFailedLauncherSubmission() {
        var writes: [String] = []
        let sequence = LaunchPostBootSequence(
            launcher: "copilot", prompt: "file instruction", isLive: { true }, isReady: { true },
            submit: { text, completion in writes.append(text); completion(false) },
            schedule: { _, _ in XCTFail("failed submission must not schedule a prompt") })
        sequence.start()
        XCTAssertEqual(writes, ["copilot"])
    }

    @MainActor
    func testPostBootCancelsPromptWhenAttachmentChangesDuringDelay() {
        var current = true
        var writes: [String] = []
        var delayed: (@MainActor () -> Void)?
        let sequence = LaunchPostBootSequence(
            launcher: "agent", prompt: "never send into replacement",
            isLive: { true }, isReady: { true },
            submit: { text, completion in writes.append(text); completion(true) },
            generationIsCurrent: { current },
            schedule: { _, work in delayed = work })
        sequence.start()
        XCTAssertEqual(writes, ["agent"])
        current = false
        delayed?()
        XCTAssertEqual(writes, ["agent"])
    }

    @MainActor
    func testPostBootCancelsWhenGenerationChangesBeforeLauncherCompletion() {
        var current = true
        var completion: ((Bool) -> Void)?
        let sequence = LaunchPostBootSequence(
            launcher: "agent", prompt: "never send into replacement",
            isLive: { true }, isReady: { true }, submit: { _, done in completion = done },
            generationIsCurrent: { current },
            schedule: { _, _ in XCTFail("stale launcher completion scheduled a prompt") })
        sequence.start()
        current = false
        completion?(true)
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
