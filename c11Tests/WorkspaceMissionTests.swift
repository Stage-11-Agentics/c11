import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceMissionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func read(_ root: URL) -> WorkspaceMission? {
        DispatchQueue.global(qos: .utility).sync { WorkspaceMissionFile.read(root: root.path) }
    }

    private func readDocument(_ root: URL) -> WorkspaceProjectDocument? {
        DispatchQueue.global(qos: .utility).sync { WorkspaceMissionFile.readDocument(root: root.path) }
    }

    func testCaptainOnlyFileDoesNotBecomeMissionProse() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C11.md")
        for text in ["**Captain.** project-captain\n", "# Project\n\n## Captain\n\nproject-captain\n"] {
            try text.write(to: file, atomically: true, encoding: .utf8)
            let document = try XCTUnwrap(readDocument(root))
            XCTAssertEqual(document.path, file.path)
            XCTAssertEqual(document.captain, "project-captain")
            XCTAssertNil(document.mission)
            XCTAssertNil(read(root), "the captain address must never be injected as mission prose")
        }
    }

    func testMarkedCaptainValuesAcceptBackticksInBoldAndHeadingForms() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C11.md")
        for declaration in [
            "**Captain.** `project-captain`",
            "**Captain:** `project-captain`",
            "**Captain**: `project-captain`",
            "**Captain** `project-captain`",
            "## Captain\n\n`project-captain`",
        ] {
            try (declaration + "\n\n## Mission\nMake the project useful.\n")
                .write(to: file, atomically: true, encoding: .utf8)
            let document = try XCTUnwrap(readDocument(root))
            XCTAssertEqual(document.captain, "project-captain", declaration)
            XCTAssertEqual(document.mission?.paragraph, "Make the project useful.", declaration)
        }
    }

    func testCaptainValueUnwrapsOnlyOneCompleteBacktickPair() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C11.md")
        let cases: [(String, String?)] = [
            ("``project-captain``", "`project-captain`"),
            ("`project-captain", "`project-captain"),
            ("project-captain`", "project-captain`"),
            ("project`captain", "project`captain"),
            ("`", "`"),
            ("``", nil),
        ]
        for (value, expected) in cases {
            for declaration in ["**Captain.** \(value)", "## Captain\n\n\(value)"] {
                try (declaration + "\n").write(to: file, atomically: true, encoding: .utf8)
                let document = try XCTUnwrap(readDocument(root))
                XCTAssertEqual(document.captain, expected, declaration)
                XCTAssertNil(document.mission, declaration)
            }
        }
    }

    func testUnmarkedCaptainProseDoesNotSeedMetadataOrDisappearFromMission() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C11.md")
        let prose = "Captain: prose-only"
        for declaration in ["", "\n\n**Captain.** `project-captain`"] {
            try ("# Project\n\n" + prose + declaration + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            let document = try XCTUnwrap(readDocument(root))
            XCTAssertEqual(document.captain, declaration.isEmpty ? nil : "project-captain")
            XCTAssertEqual(document.mission?.paragraph, prose)
        }
    }

    func testCaptainMarkersIgnoreCommentsFencesQuotesAndKeepFirstValidAddress() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        # Project
        <!-- **Captain.** `comment-captain` -->
        ```markdown
        **Captain.** `fenced-captain`
        ```
        > **Captain.** `quoted-captain`
        **Captain.**
        **Captain.** \(String(repeating: "x", count: 257))
        ## Mission
        Make the project useful.
        ## Captain
        project-captain
        ## Another workspace
        **Captain.** second-captain
        """.write(to: root.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        let document = try XCTUnwrap(readDocument(root))
        XCTAssertEqual(document.captain, "project-captain")
        XCTAssertEqual(document.mission?.paragraph, "Make the project useful.")
    }

    func testLongerFenceKeepsNestedExamplesOutOfCaptainAndMission() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for marker in ["`", "~"] {
            let outer = String(repeating: marker, count: 4)
            let inner = String(repeating: marker, count: 3)
            let text = """
            \(outer)markdown
            \(inner)swift
            **Captain.** example
            **Mission.** Example mission.
            \(inner)
            **Captain.** after-short-fence-example
            **Mission.** After short fence example.
            \(outer)not-a-closing-fence
            **Captain.** still-example
            \(outer)
            **Captain.** real
            **Mission.** Real mission.
            """
            try text.write(to: root.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
            let document = try XCTUnwrap(readDocument(root))
            XCTAssertEqual(document.captain, "real")
            XCTAssertEqual(document.mission?.paragraph, "Real mission.")
        }
    }

    @MainActor
    func testDocumentMonitorSharesOneReadAndPublishesCaptainOnlyChangesAndDeletion() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C11.md")
        try "## Mission\nSame mission.\n\n**Captain.** first\n".write(to: file, atomically: true, encoding: .utf8)
        let reads = MissionReadCounter()
        let monitor = WorkspaceMissionMonitor(interval: 0.05, documentReader: { root in
            XCTAssertFalse(Thread.isMainThread)
            reads.increment()
            return WorkspaceMissionFile.readDocument(root: root)
        })
        let first = expectation(description: "both subscribers receive first captain")
        let changed = expectation(description: "both subscribers receive captain-only edit")
        let deleted = expectation(description: "both subscribers receive file deletion")
        for item in [first, changed, deleted] { item.expectedFulfillmentCount = 2; item.assertForOverFulfill = true }
        let receive: WorkspaceMissionMonitor.DocumentReceiver = { document in
            if document != nil { XCTAssertEqual(document?.mission?.summary, "Same mission.") }
            switch document?.captain {
            case "first": first.fulfill()
            case "second": changed.fulfill()
            case nil: deleted.fulfill()
            default: XCTFail("unexpected captain")
            }
        }
        let one = monitor.observeDocument(root: root.path, receive: receive)
        let two = monitor.observeDocument(root: root.path, receive: receive)
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(reads.value, 1)
        try "## Mission\nSame mission.\n\n**Captain.** second\n".write(to: file, atomically: true, encoding: .utf8)
        await fulfillment(of: [changed], timeout: 2)
        try FileManager.default.removeItem(at: file)
        await fulfillment(of: [deleted], timeout: 2)
        withExtendedLifetime((one, two)) {}
    }

    @MainActor
    func testCaptainBindingRejectsOldReadWhenRootReturnsToSamePath() async throws {
        let firstRoot = try directory()
        let secondRoot = try directory()
        defer { try? FileManager.default.removeItem(at: firstRoot); try? FileManager.default.removeItem(at: secondRoot) }
        try "**Captain.** old\n".write(to: firstRoot.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        try "**Captain.** elsewhere\n".write(to: secondRoot.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        let started = expectation(description: "first read captured old bytes")
        let applied = expectation(description: "current root receives new bytes")
        let release = DispatchSemaphore(value: 0)
        let reads = MissionReadCounter()
        let monitor = WorkspaceMissionMonitor(interval: 0.05, documentReader: { root in
            let value = WorkspaceMissionFile.readDocument(root: root)
            if root == firstRoot.path {
                reads.increment()
                if reads.value == 1 {
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 3)
                }
            }
            return value
        })
        var captains: [String] = []
        var latest: WorkspaceProjectDocument?
        let binding = WorkspaceMissionBinding(monitor: monitor, receiveDocument: { document in
            latest = document
            if let captain = document?.captain { captains.append(captain) }
            if document?.captain == "new" { applied.fulfill() }
        })
        binding.setRoot(firstRoot.path)
        await fulfillment(of: [started], timeout: 2)
        binding.setRoot(secondRoot.path)
        try "**Captain.** new\n".write(to: firstRoot.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        binding.setRoot(firstRoot.path)
        release.signal()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(captains, ["new"], "the first root's old callback must not match a later subscription to that root")
        binding.setRoot(nil)
        XCTAssertNil(latest)
    }

    func testUsesMarkedMissionRatherThanDocumentTitleOrPreamble() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        # C11.md: Project
        This is an explanatory preamble.

        ## Project workspace
        **Mission.** Build a solid,
        [agent-native](https://example.invalid) home. Ship useful primitives.

        ## Another workspace
        **Mission.** A different project.
        """.write(to: root.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        let mission = try XCTUnwrap(read(root))
        XCTAssertEqual(mission.summary, "Build a solid, agent-native home.")
        XCTAssertEqual(mission.paragraph, "Build a solid, agent-native home. Ship useful primitives.")
        XCTAssertEqual(mission.path, root.appendingPathComponent("C11.md").path)
    }

    func testHeadingPlainFallbackAndIgnoredExamples() {
        XCTAssertEqual(WorkspaceMissionFile.missionParagraph("# Project\n\n## Mission\n\nExplore broadly.\n\n## Now\nOther notes."), "Explore broadly.")
        XCTAssertEqual(WorkspaceMissionFile.missionParagraph("# Project\n\nFirst plain\nparagraph.\n\nSecond."), "First plain paragraph.")
        XCTAssertEqual(WorkspaceMissionFile.missionParagraph("<!--\n**Mission.** Hidden.\n-->\n```md\n## Mission\nExample.\n```\n## Mission\nReal mission."), "Real mission.")
        XCTAssertNil(WorkspaceMissionFile.missionParagraph("# Heading only\n\n```\nbody\n```"))
    }

    func testBoundedReadRejectsEmptyBinaryOversizedNonregularAndSymlink() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C11.md")
        XCTAssertNil(read(root))
        for data in [Data(), Data([0xFF, 0xFE]), Data("**Mission.** Hi\0there".utf8),
                     Data(repeating: 65, count: WorkspaceMissionFile.byteLimit + 1)] {
            try data.write(to: file, options: .atomic)
            XCTAssertNil(read(root))
        }
        try Data(repeating: 65, count: WorkspaceMissionFile.byteLimit).write(to: file, options: .atomic)
        XCTAssertNotNil(read(root))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertNil(read(root))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        let before = Date()
        XCTAssertNil(read(root))
        XCTAssertLessThan(Date().timeIntervalSince(before), 1, "FIFO must not wait for a writer")
        try FileManager.default.removeItem(at: file)
        let other = root.appendingPathComponent("other.md")
        try "Other agent's notes.".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertNil(read(root))
    }

    func testReadDoesNotModifyFileAndNeverSearchesParents() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C11.md")
        let bytes = Data("## Mission\n\nBuild boldly.\n".utf8)
        try bytes.write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertNotNil(read(root))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        let child = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        XCTAssertNil(read(child))
        XCTAssertNil(WorkspaceMissionFile.path(root: nil))
        XCTAssertNil(WorkspaceMissionFile.path(root: "relative"))
    }

    @MainActor
    func testMonitorTracksAtomicReplacementDeletionRecreationAndSharesReads() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("C11.md")
        try "First.".write(to: file, atomically: true, encoding: .utf8)
        let reads = MissionReadCounter()
        let observedRoot = root.path
        let monitor = WorkspaceMissionMonitor(interval: 0.05) { root in
            XCTAssertFalse(Thread.isMainThread)
            if root == observedRoot { reads.increment() }
            return WorkspaceMissionFile.read(root: root)
        }
        let initial = expectation(description: "both shared-root subscribers")
        initial.expectedFulfillmentCount = 2
        let changed = expectation(description: "atomic replacement")
        changed.expectedFulfillmentCount = 2
        let deleted = expectation(description: "deletion")
        deleted.expectedFulfillmentCount = 2
        let recreated = expectation(description: "recreated")
        recreated.expectedFulfillmentCount = 2
        for item in [initial, changed, deleted, recreated] { item.assertForOverFulfill = true }
        let receive: WorkspaceMissionMonitor.Receiver = { value in
            switch value?.summary {
            case "First.": initial.fulfill()
            case "Second.": changed.fulfill()
            case nil: deleted.fulfill()
            case "Third.": recreated.fulfill()
            default: XCTFail("Unexpected mission")
            }
        }
        var first: WorkspaceMissionMonitor.Subscription? = monitor.observe(root: root.path, receive: receive)
        var second: WorkspaceMissionMonitor.Subscription? = monitor.observe(root: root.path, receive: receive)
        await fulfillment(of: [initial], timeout: 2)
        XCTAssertEqual(reads.value, 1)
        try "Second.".write(to: file, atomically: true, encoding: .utf8)
        await fulfillment(of: [changed], timeout: 2)
        try FileManager.default.removeItem(at: file)
        await fulfillment(of: [deleted], timeout: 2)
        try "Third.".write(to: file, atomically: true, encoding: .utf8)
        await fulfillment(of: [recreated], timeout: 2)
        XCTAssertGreaterThanOrEqual(reads.value, 4)
        // Atomic-save metadata can settle across more than one poll. Require
        // another read, but never another publication (over-fulfillment fails).
        let beforeIdenticalSave = reads.value
        try "Third.".write(to: file, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(2)
        while reads.value == beforeIdenticalSave && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(reads.value, beforeIdenticalSave)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        first = nil; second = nil
        // A new root's callback follows both unsubscriptions on the same
        // serial queue and keeps polling active, making cleanup observable.
        let sentinelRoot = try directory()
        defer { try? FileManager.default.removeItem(at: sentinelRoot) }
        try "Sentinel.".write(to: sentinelRoot.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        let sentinelReady = expectation(description: "unsubscribe queue drained")
        // Only the first delivery proves the queue drained. Later polls can land
        // after this test tears down sentinelRoot, so they must not assert.
        let sentinelDeliveries = MissionReadCounter()
        var sentinel: WorkspaceMissionMonitor.Subscription? = monitor.observe(root: sentinelRoot.path) { value in
            sentinelDeliveries.increment()
            guard sentinelDeliveries.value == 1 else { return }
            XCTAssertEqual(value?.summary, "Sentinel.")
            sentinelReady.fulfill()
        }
        await fulfillment(of: [sentinelReady], timeout: 2)
        let afterUnsubscribe = reads.value
        try "Fourth.".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(reads.value, afterUnsubscribe, "last unsubscribe must stop reading this root")
        XCTAssertNotNil(sentinel)
        sentinel = nil
    }

    @MainActor
    func testRootChangeDropsAnInFlightRead() async throws {
        let first = try directory()
        let second = try directory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try "Old root.".write(to: first.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        try "New root.".write(to: second.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        let started = expectation(description: "old root read started")
        let updated = expectation(description: "new root applied")
        let releaseRead = DispatchSemaphore(value: 0)
        let monitor = WorkspaceMissionMonitor(interval: 0.05) { root in
            if root == first.path {
                started.fulfill()
                _ = releaseRead.wait(timeout: .now() + 3)
            }
            return WorkspaceMissionFile.read(root: root)
        }
        var values: [String] = []
        var last: WorkspaceMission?
        let binding = WorkspaceMissionBinding(monitor: monitor) { value in
            last = value
            if let summary = value?.summary { values.append(summary) }
            if value?.summary == "New root." { updated.fulfill() }
        }
        binding.setRoot(first.path)
        await fulfillment(of: [started], timeout: 2)
        binding.setRoot(second.path)
        releaseRead.signal()
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(values, ["New root."])
        binding.setRoot(nil)
        XCTAssertNil(last)
    }

    func testMissionLaunchOverridesInheritedContextInARealShell() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oddRoot = root.appendingPathComponent("space ' $ shell")
        try FileManager.default.createDirectory(at: oddRoot, withIntermediateDirectories: true)
        try "Mission.".write(to: oddRoot.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        let context = WorkspaceMissionLaunchContext(mission: try XCTUnwrap(read(oddRoot)))
        let empty = WorkspaceMissionLaunchContext(mission: nil)
        XCTAssertEqual(context.environment(["C11_MISSION_FILE": "/wrong", "UNCHANGED": "yes"])["UNCHANGED"], "yes")
        for (launch, expected) in [(context, context.mission!.path), (empty, "")] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", launch.command("/usr/bin/printenv C11_MISSION_FILE")]
            process.environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("C11_SOCKET") && !$0.key.hasPrefix("CMUX_SOCKET")
            }.merging(["C11_MISSION_FILE": "/wrong"]) { _, new in new }
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), expected + "\n")
        }
    }

    /// C11H-51: `C11_MISSION_FILE` names a file on this Mac. A launch on another
    /// machine never reads the local mission and keeps the environment and launch
    /// line it was asked for, with or without a prompt, in every delivery shape.
    func testRemoteLaunchKeepsItsOwnEnvironmentAndCommandWithAndWithoutAPrompt() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Local mission.".write(to: root.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        var remoteReads = 0
        let remote = WorkspaceMissionLaunchContext.forLaunch(isRemote: true, missionRoot: root.path) { _ in
            remoteReads += 1
            return nil
        }
        XCTAssertNil(remote)
        XCTAssertEqual(remoteReads, 0, "a remote launch never reads this Mac's mission")
        let local = WorkspaceMissionLaunchContext.forLaunch(isRemote: false, missionRoot: root.path)
        let localPath = try XCTUnwrap(local?.mission?.path)

        let requested = ["C11_MISSION_FILE": "/remote/project/C11.md", "REMOTE_ONLY": "1"]
        XCTAssertEqual(remote.environment(requested), requested, "the remote override survives")
        XCTAssertEqual(local.environment(requested)["C11_MISSION_FILE"], localPath)
        XCTAssertEqual(local.environment(requested)["REMOTE_ONLY"], "1")

        let store = LaunchPromptStore(rootDirectory: root.appendingPathComponent("runtime"))
        let staged = try store.stage(prompt: "Task.")
        defer { store.discard(staged) }
        for promptPath in [nil, staged.url.path] {
            for mode: AgentPromptDelivery in [.positional, .flag("--prompt"), .postBoot] {
                let plan = LaunchPromptDelivery.compose(command: "agent-cli --model x", delivery: mode, promptFilePath: promptPath)
                let label = "\(mode) prompt=\(promptPath != nil)"
                XCTAssertEqual(remote.command(plan.launchLine), plan.launchLine, label)
                XCTAssertFalse(remote.command(plan.launchLine).contains("C11_MISSION_FILE"), label)
                XCTAssertTrue(local.command(plan.launchLine).hasPrefix("export C11_MISSION_FILE="), label)
                XCTAssertTrue(local.command(plan.launchLine).contains(localPath), label)
            }
        }
    }

    func testMissionEnvironmentAndUnchangedTaskReachEveryDeliveryShape() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Shared mission.".write(to: root.appendingPathComponent("C11.md"), atomically: true, encoding: .utf8)
        let context = WorkspaceMissionLaunchContext(mission: try XCTUnwrap(read(root)))
        let body = "\nExact task ' \" $ text.\n  "
        let store = LaunchPromptStore(rootDirectory: root.appendingPathComponent("runtime"))
        let staged = try store.stage(prompt: body)
        defer { store.discard(staged) }
        let script = """
        import json, os, pathlib, sys
        args = [a for a in sys.argv[1:] if a != '--prompt']
        instruction = args[0] if args else input()
        prefix, suffix = 'Read the file at ', ' and follow it exactly.'
        assert instruction.startswith(prefix) and instruction.endswith(suffix)
        print(json.dumps({'path': os.environ['C11_MISSION_FILE'], 'body': pathlib.Path(instruction[len(prefix):-len(suffix)]).read_text()}))
        """
        let command = "/usr/bin/python3 -c " + DefaultAgentResolver.shellQuote(script)
        for mode: AgentPromptDelivery in [.positional, .flag("--prompt"), .postBoot] {
            let plan = LaunchPromptDelivery.compose(command: command, delivery: mode, promptFilePath: staged.url.path)
            let process = Process()
            let output = Pipe()
            let input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", context.command(plan.launchLine)]
            process.environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("C11_SOCKET") && !$0.key.hasPrefix("CMUX_SOCKET")
            }
            process.standardOutput = output
            process.standardInput = input
            try process.run()
            if let delayed = plan.delayedPrompt { input.fileHandleForWriting.write(Data((delayed + "\n").utf8)) }
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(receipt["path"], context.mission?.path)
            XCTAssertEqual(receipt["body"], body)
        }
    }
}

private final class MissionReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
