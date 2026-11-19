import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral tests for `HangLogRotator`, the size cap behind the local hang
/// log. Everything runs against a real temp directory: the rotator's whole job
/// is filesystem bookkeeping, so a fake filesystem would test nothing.
///
/// Payloads are runs of a single uppercase letter chosen to be absent from the
/// rotation header, which makes "which generation holds which episode" a
/// straight substring check.
final class HangLogRotatorTests: XCTestCase {

    private var directory: URL!
    private var logURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-hang-rotator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("hang.log")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private static let stampedHeaderPrefix = "=== c11 hang.rotated TS previous="

    private func makeRotator(
        cap: Int,
        generations: Int = 2,
        sizeProbe: @escaping HangLogRotator.SizeProbe = HangLogRotator.fileSize
    ) -> HangLogRotator {
        HangLogRotator(
            logURL: logURL,
            capBytes: cap,
            generations: generations,
            timestamp: { "TS" },
            sizeProbe: sizeProbe
        )
    }

    /// `count` bytes of a single ASCII letter, so byte length equals `count`.
    private func payload(_ marker: Character, _ count: Int) -> String {
        String(repeating: String(marker), count: count)
    }

    private func generation(_ index: Int) -> URL {
        URL(fileURLWithPath: logURL.path + ".\(index)")
    }

    private func text(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func byteCount(_ url: URL) -> Int {
        (try? Data(contentsOf: url))?.count ?? 0
    }

    private func directoryFileNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names)
    }

    private func totalFootprint() -> Int {
        directoryFileNames().reduce(0) { $0 + byteCount(directory.appendingPathComponent($1)) }
    }

    // MARK: Tests

    func testAppendsUnderTheCapNeverRotate() {
        var rotator = makeRotator(cap: 4096)
        rotator.append(payload("X", 100))
        rotator.append(payload("Y", 100))
        rotator.append(payload("Z", 100), episodeBoundary: true)

        XCTAssertEqual(byteCount(logURL), 300)
        XCTAssertEqual(directoryFileNames(), ["hang.log"])
        XCTAssertFalse(text(logURL).contains("hang.rotated"))
    }

    func testCrossingTheCapRotatesOnceAndHeadsTheNewFile() {
        var rotator = makeRotator(cap: 1000)
        rotator.append(payload("X", 600))
        rotator.append(payload("Y", 600))

        // The record that would have overflowed the cap opened a new file.
        XCTAssertEqual(text(generation(1)), payload("X", 600))
        XCTAssertFalse(exists(generation(2)))

        let live = text(logURL)
        XCTAssertTrue(
            live.hasPrefix(Self.stampedHeaderPrefix + "hang.log.1 capBytes=1000 ===\n"),
            "new file should open with the rotation header, got: \(live.prefix(120))"
        )
        XCTAssertTrue(live.contains(payload("Y", 600)))
        XCTAssertFalse(live.contains("X"))
    }

    func testGenerationsShiftDownAndTheOldestIsDeleted() {
        var rotator = makeRotator(cap: 1000, generations: 2)
        for marker in ["X", "Y", "Z", "W"] {
            rotator.append(payload(Character(marker), 600))
        }

        // Four 600-byte records against a 1000-byte cap means three rotations.
        XCTAssertTrue(text(logURL).contains(payload("W", 600)))
        XCTAssertTrue(text(generation(1)).contains(payload("Z", 600)))
        XCTAssertTrue(text(generation(2)).contains(payload("Y", 600)))
        XCTAssertFalse(exists(generation(3)))

        // X was the oldest and has been dropped off the end.
        for name in directoryFileNames() {
            XCTAssertFalse(
                text(directory.appendingPathComponent(name)).contains("X"),
                "\(name) still holds the evicted generation"
            )
        }
    }

    func testFootprintStaysBoundedAcrossManyRotations() {
        let cap = 4096
        var rotator = makeRotator(cap: cap, generations: 2)
        for index in 0..<200 {
            rotator.append(payload("X", 500), episodeBoundary: index % 5 == 4)
        }

        XCTAssertTrue(
            directoryFileNames().isSubset(of: ["hang.log", "hang.log.1", "hang.log.2"]),
            "unexpected files left behind: \(directoryFileNames())"
        )
        for name in directoryFileNames() {
            XCTAssertLessThanOrEqual(byteCount(directory.appendingPathComponent(name)), cap)
        }
        // 100 KB written, ~12 KB retained.
        XCTAssertLessThanOrEqual(totalFootprint(), 3 * cap)
    }

    func testRotationWaitsForTheEpisodeBoundaryPastTheSoftCap() {
        var rotator = makeRotator(cap: 1000)
        // 800 bytes is past the 750-byte soft cap but under the hard cap.
        rotator.append(payload("X", 800))
        XCTAssertFalse(exists(generation(1)), "mid-episode append must not rotate below the hard cap")
        XCTAssertEqual(byteCount(logURL), 800)

        rotator.append(payload("Y", 50), episodeBoundary: true)

        // The closing record joined its own episode before the file rotated.
        let archived = text(generation(1))
        XCTAssertEqual(archived, payload("X", 800) + payload("Y", 50))

        let live = text(logURL)
        XCTAssertTrue(live.hasPrefix(Self.stampedHeaderPrefix + "hang.log.1 capBytes=1000 ==="))
        XCTAssertFalse(live.contains("X"))
        XCTAssertFalse(live.contains("Y"))
    }

    func testASingleOversizedEpisodeStillRotatesMidEpisode() {
        let cap = 2000
        var rotator = makeRotator(cap: cap, generations: 2)
        // No boundary is ever reached: one unbroken episode of 40 KB.
        for _ in 0..<80 {
            rotator.append(payload("X", 500), episodeBoundary: false)
        }

        XCTAssertTrue(exists(generation(1)), "an episode that never ends must still rotate")
        for name in directoryFileNames() {
            XCTAssertLessThanOrEqual(byteCount(directory.appendingPathComponent(name)), cap)
        }
        XCTAssertLessThanOrEqual(totalFootprint(), 3 * cap)
    }

    func testFileSizeIsProbedExactlyOnceAcrossManyAppends() {
        var probes = 0
        var rotator = makeRotator(cap: 4096, sizeProbe: { url in
            probes += 1
            return HangLogRotator.fileSize(url)
        })
        for _ in 0..<25 {
            rotator.append(payload("X", 10))
        }

        XCTAssertEqual(probes, 1, "the rotator must stat the log once, not on every append")
        XCTAssertEqual(byteCount(logURL), 250)
    }

    func testAPreexistingOversizedLogIsDiscardedRatherThanArchived() throws {
        // Stands in for the uncapped log left by an older build.
        try Data(payload("X", 5000).utf8).write(to: logURL)

        let cap = 1000
        var rotator = makeRotator(cap: cap, generations: 2)
        rotator.append(payload("Y", 10))

        XCTAssertFalse(
            exists(generation(1)),
            "an already-oversized log must not be archived, or the footprint bound breaks"
        )
        let live = text(logURL)
        XCTAssertTrue(live.hasPrefix(Self.stampedHeaderPrefix + "discarded capBytes=1000 ==="))
        XCTAssertTrue(live.hasSuffix(payload("Y", 10)))
        XCTAssertLessThanOrEqual(totalFootprint(), 3 * cap)
    }

    func testCreatesTheLogDirectoryWhenItIsMissing() {
        logURL = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("hang.log")

        var rotator = makeRotator(cap: 4096)
        rotator.append(payload("X", 32))

        XCTAssertEqual(text(logURL), payload("X", 32))
    }

    func testANonPositiveCapDisablesRotationEntirely() {
        var rotator = makeRotator(cap: 0)
        for _ in 0..<20 {
            rotator.append(payload("X", 100), episodeBoundary: true)
        }

        XCTAssertEqual(byteCount(logURL), 2000)
        XCTAssertEqual(directoryFileNames(), ["hang.log"])
    }
}

/// C11H-293: the workspace switch log. Real temp files, like the rotator above.
final class WorkspaceSwitchTimingLogTests: XCTestCase {
    private var directory: URL!
    private let metadata = WorkspaceSwitchMetadata(build: "release", version: "2.0.0 (200)", bundleId: "com.stage11.c11")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-switch-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func timing(dtMs: Int = 431, hidden: TimeInterval? = 40.04) -> WorkspaceSwitchTiming {
        WorkspaceSwitchTiming(at: Date(timeIntervalSince1970: 1_800_000_000), holdMs: 420, dtMs: dtMs, panels: 6,
                              workspaces: 9, hiddenSeconds: hidden, cause: "shortcut")
    }

    private func log(_ url: URL, capBytes: Int = WorkspaceSwitchTimingLog.defaultCapBytes) -> WorkspaceSwitchTimingLog {
        let metadata = metadata
        return WorkspaceSwitchTimingLog(url: url, capBytes: capBytes, metadata: { metadata })
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    // MARK: The switch-to-record handoff (WorkspaceSwitchRecorder)

    private final class Sink {
        var records: [WorkspaceSwitchTiming] = []
    }

    private func recorder(_ sink: Sink) -> WorkspaceSwitchRecorder {
        WorkspaceSwitchRecorder(sink: { sink.records.append($0) })
    }

    func testACompletedSwitchReachesTheSinkOnceWithWhatItShowed() throws {
        let sink = Sink()
        var recorder = recorder(sink)
        let (a, b) = (UUID(), UUID())
        let pending = recorder.begin(from: a, to: b, panels: 6, cause: "shortcut", liveWorkspaceCount: 2, liveWorkspaceIds: { [a, b] }, now: 100)
        XCTAssertTrue(recorder.finish(pending, workspaces: 9, blockStartedAt: 100.43, dtMs: 445,
                                      at: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(sink.records, [WorkspaceSwitchTiming(at: Date(timeIntervalSince1970: 1_800_000_000), holdMs: 430,
                                                            dtMs: 445, panels: 6, workspaces: 9, hiddenSeconds: nil,
                                                            cause: "shortcut")])
    }

    func testHiddenTimeIsSinceThisWindowLastDeselectedTheWorkspace() throws {
        let sink = Sink()
        var recorder = recorder(sink)
        let (a, b) = (UUID(), UUID())
        let live: () -> Set<UUID> = { [a, b] }
        // begin and finish are separate statements, as in WorkspaceManager: nested, finish would read
        // the recorder from before begin ran.
        let first = recorder.begin(from: a, to: b, panels: 6, cause: "shortcut", liveWorkspaceCount: 2, liveWorkspaceIds: live, now: 100)
        recorder.finish(first, workspaces: 2, blockStartedAt: 100.4, dtMs: 400)
        let back = recorder.begin(from: b, to: a, panels: 6, cause: "sidebar", liveWorkspaceCount: 2, liveWorkspaceIds: live, now: 105)
        recorder.finish(back, workspaces: 2, blockStartedAt: 105.4, dtMs: 400)
        let again = recorder.begin(from: a, to: b, panels: 6, cause: "shortcut", liveWorkspaceCount: 2, liveWorkspaceIds: live, now: 150)
        recorder.finish(again, workspaces: 2, blockStartedAt: 150.4, dtMs: 400)
        XCTAssertEqual(sink.records.map(\.warmth), ["first", "warm", "cold"])
        XCTAssertEqual(sink.records.map(\.hiddenSeconds), [nil, 5, 45])
        XCTAssertEqual(sink.records.map(\.cause), ["shortcut", "sidebar", "shortcut"])
    }

    func testASupersededSwitchIsNotRecorded() {
        let sink = Sink()
        var recorder = recorder(sink)
        let (a, b, c) = (UUID(), UUID(), UUID())
        let first = recorder.begin(from: a, to: b, panels: 6, cause: "shortcut", liveWorkspaceCount: 3, liveWorkspaceIds: { [a, b, c] }, now: 100)
        let second = recorder.begin(from: b, to: c, panels: 3, cause: "shortcut", liveWorkspaceCount: 3, liveWorkspaceIds: { [a, b, c] }, now: 100.1)
        XCTAssertFalse(recorder.finish(first, workspaces: 3, blockStartedAt: 100.5, dtMs: 500))
        XCTAssertTrue(recorder.finish(second, workspaces: 3, blockStartedAt: 100.5, dtMs: 400))
        XCTAssertEqual(sink.records.map(\.panels), [3])
    }

    func testASwitchToNoWorkspaceIsNotRecordedButStillHidesThePrevious() {
        let sink = Sink()
        var recorder = recorder(sink)
        let a = UUID()
        let away = recorder.begin(from: a, to: nil, panels: 0, cause: "menu", liveWorkspaceCount: 1, liveWorkspaceIds: { [a] }, now: 100)
        XCTAssertFalse(recorder.finish(away, workspaces: 0, blockStartedAt: 100.1, dtMs: 50))
        XCTAssertTrue(sink.records.isEmpty)
        let back = recorder.begin(from: nil, to: a, panels: 1, cause: "menu", liveWorkspaceCount: 1, liveWorkspaceIds: { [a] }, now: 110)
        recorder.finish(back, workspaces: 1, blockStartedAt: 110.1, dtMs: 50)
        XCTAssertEqual(sink.records.map(\.hiddenSeconds), [10])
    }

    func testDeselectTimesOfClosedWorkspacesArePruned() {
        var recorder = recorder(Sink())
        let keep = UUID()
        var previous: UUID? = keep
        for _ in 0...(1 + WorkspaceSwitchRecorder.pruneSlack) {
            let next = UUID()
            _ = recorder.begin(from: previous, to: next, panels: 1, cause: "shortcut", liveWorkspaceCount: 1,
                               liveWorkspaceIds: { [keep] }, now: 1)
            previous = next
        }
        XCTAssertLessThanOrEqual(recorder.deselectedAt.count, 1 + WorkspaceSwitchRecorder.pruneSlack)
        XCTAssertNotNil(recorder.deselectedAt[keep])
    }

    func testSwitchingAmongManyOpenWorkspacesNeverRebuildsTheLiveSet() {
        // 100 open workspaces, every one visited and deselected: the deselect times are all live, so
        // no switch may pay for building the live-id set and filtering (C11H-293 repair 2).
        var recorder = recorder(Sink())
        let ids = (0..<100).map { _ in UUID() }
        var liveSetBuilds = 0
        let live: () -> Set<UUID> = { liveSetBuilds += 1; return Set(ids) }
        var previous: UUID?
        for round in 0..<3 {
            for (index, id) in ids.enumerated() {
                _ = recorder.begin(from: previous, to: id, panels: 6, cause: "shortcut", liveWorkspaceCount: ids.count,
                                   liveWorkspaceIds: live, now: Double(round * 1000 + index))
                previous = id
            }
        }
        XCTAssertEqual(recorder.deselectedAt.count, ids.count)
        XCTAssertEqual(liveSetBuilds, 0, "switches among live workspaces must not rebuild the live-id set")
    }

    // MARK: The line and the writer

    func testLineCarriesTheSwitchAndClassifiesWarmth() throws {
        let line = timing().jsonLine(metadata: metadata)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["hold_ms"] as? Int, 420)
        XCTAssertEqual(object["dt_ms"] as? Int, 431)
        XCTAssertEqual(object["panels"] as? Int, 6)
        XCTAssertEqual(object["workspaces"] as? Int, 9)
        XCTAssertEqual(object["hidden_s"] as? Double, 40.0)
        XCTAssertEqual(object["warmth"] as? String, "cold")
        XCTAssertEqual(object["cause"] as? String, "shortcut")
        XCTAssertEqual(object["build"] as? String, "release")
        XCTAssertEqual(object["version"] as? String, "2.0.0 (200)")
        XCTAssertEqual(object["bundle_id"] as? String, "com.stage11.c11")
        XCTAssertNotNil(object["at"] as? String)

        XCTAssertEqual(timing(hidden: 5).warmth, "warm")
        XCTAssertEqual(timing(hidden: nil).warmth, "first")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(timing(hidden: nil).jsonLine(metadata: metadata).utf8))
                                  as? [String: Any])
        XCTAssertTrue(first["hidden_s"] is NSNull)
    }

    private final class ThreadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String: [Bool]] = [:]
        func note(_ name: String) { lock.lock(); calls[name, default: []].append(Thread.isMainThread); lock.unlock() }
        func onMain(_ name: String) -> [Bool] { lock.lock(); defer { lock.unlock() }; return calls[name] ?? [] }
    }

    func testSetupAndFormattingRunOffTheCallersThreadOnFirstUse() throws {
        XCTAssertTrue(Thread.isMainThread)
        let url = directory.appendingPathComponent("workspace-switch.jsonl")
        let threads = ThreadLog()
        let metadata = metadata
        let log = WorkspaceSwitchTimingLog(destination: {
            threads.note("destination")
            return url
        }, metadata: {
            threads.note("metadata")
            return metadata
        })
        log.record(timing())
        log.record(timing())
        log.drain()
        XCTAssertEqual(threads.onMain("destination"), [false], "the destination resolves once, on the log's queue")
        XCTAssertEqual(threads.onMain("metadata"), [false], "metadata, and the formatting that needs it, stay off main")
        XCTAssertEqual(try lines(url).count, 2)
    }

    func testEachRecordAppendsOneLine() throws {
        let url = directory.appendingPathComponent("logs/workspace-switch.jsonl")
        let log = log(url)
        for dt in [431, 12, 650] { log.record(timing(dtMs: dt)) }
        log.drain()
        XCTAssertEqual(try lines(url).compactMap { $0["dt_ms"] as? Int }, [431, 12, 650])
    }

    func testTwoWritersSharingTheFileKeepEveryLineWhole() throws {
        // Two c11 processes (release and an untagged staging build) can share the file.
        let url = directory.appendingPathComponent("workspace-switch.jsonl")
        let first = log(url)
        let second = log(url)
        for dt in 0..<50 {
            first.record(timing(dtMs: dt))
            second.record(timing(dtMs: 1000 + dt))
        }
        first.drain()
        second.drain()
        let values = try lines(url).compactMap { $0["dt_ms"] as? Int }
        XCTAssertEqual(values.sorted(), Array(0..<50) + Array(1000..<1050))
    }

    func testAWriterWaitsForTheLockAnotherProcessHolds() throws {
        let url = directory.appendingPathComponent("workspace-switch.jsonl")
        let held = open(url.path + ".lock", O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(held, 0)
        XCTAssertEqual(flock(held, LOCK_EX), 0)
        let log = log(url)
        log.record(timing())
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing is written while the lock is held")
        flock(held, LOCK_UN)
        close(held)
        log.drain()
        XCTAssertEqual(try lines(url).count, 1)
    }

    func testTheLogNeverWritesThroughASymlink() throws {
        let url = directory.appendingPathComponent("workspace-switch.jsonl")
        let target = directory.appendingPathComponent("elsewhere.txt")
        try Data("keep\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let log = log(url)
        log.record(timing())
        log.drain()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep\n")
    }

    func testPastTheCapTheFileMovesAsideAndANewOneStarts() throws {
        let url = directory.appendingPathComponent("workspace-switch.jsonl")
        let lineBytes = timing().jsonLine(metadata: metadata).utf8.count
        let log = log(url, capBytes: lineBytes * 3)
        for dt in 1...5 { log.record(timing(dtMs: dt)) }
        log.drain()
        let archive = url.appendingPathExtension("1")
        XCTAssertEqual(try lines(archive).compactMap { $0["dt_ms"] as? Int }, [1, 2, 3])
        XCTAssertEqual(try lines(url).compactMap { $0["dt_ms"] as? Int }, [4, 5])
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThanOrEqual(size, lineBytes * 3)
    }

    func testPathPrefersTheOverrideThenTheTagThenTheLogsFolder() {
        XCTAssertEqual(WorkspaceSwitchTimingLog.resolveURL(environment: ["C11_SWITCH_LOG": "/tmp/x.jsonl", "C11_TAG": "t"]).path,
                       "/tmp/x.jsonl")
        XCTAssertEqual(WorkspaceSwitchTimingLog.resolveURL(environment: ["C11_TAG": "my tag"]).path,
                       C11UserRuntime.directoryPath() + "/c11-workspace-switch-my-tag.jsonl")
        let production = WorkspaceSwitchTimingLog.resolveURL(environment: [:]).path
        XCTAssertTrue(production.hasSuffix("/Library/Logs/\(C11Identity.logsDirectoryName)/workspace-switch.jsonl"),
                      production)
    }
}
