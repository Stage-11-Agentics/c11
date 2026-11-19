import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-228: `c11 show` on a linked machine records the show in that
/// machine's hc store and asks c11 only while its heartbeat is fresh.
final class ShowCLIRecordTests: XCTestCase {
    private let panel = UUID()
    private let now: Int64 = 1_800_000_000_000
    private var folder: URL!
    private var page: String!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("show-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        page = folder.appendingPathComponent("page.html").path
        try Data("<h1>hi</h1>".utf8).write(to: URL(fileURLWithPath: page))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private struct Unreachable: Error, CustomStringConvertible {
        var description: String { "relay_unreachable: c11 did not answer through the machine link; nothing ran" }
    }

    private func docs(fresh: Bool) throws -> FakeRelayDocs {
        let docs = FakeRelayDocs()
        if fresh { _ = try docs.set(C11Relay.seenName, value: C11Relay.seenValue(at: now - 2000), version: 0) }
        return docs
    }

    private func record(_ docs: FakeRelayDocs) -> ShowRecord? {
        ShowRecord(panel: panel, value: docs.value(ShowRecord.name(panel: panel)))
    }

    private func show(_ docs: FakeRelayDocs, target: String? = nil, id: String = UUID().uuidString.lowercased(),
                      call: (ShowSourceSpec, String?) throws -> [String: Any] = { _, _ in
                          XCTFail("c11 was asked while away"); return [:]
                      }) throws -> ShowCLIRecord.Outcome {
        try ShowCLIRecord.openRelayed(target: target ?? page, dir: nil, cwd: "/", home: NSHomeDirectory(),
                                      store: docs, panel: panel, now: now, makeID: { id }, call: call)
    }

    func testAwayRecordsWaitingWithoutAskingC11h() throws {
        let docs = try docs(fresh: false)
        guard case .recorded = try show(docs) else { return XCTFail("expected the away outcome") }
        XCTAssertEqual(record(docs)?.entries.map(\.state), [.waiting])
        XCTAssertTrue(ShowCLIRecord.awayLine().contains("recorded; c11 is away; it will load when the Mac wakes"))
    }

    func testFreshRecordsLiveThenCallsWithTheRecordID() throws {
        let docs = try docs(fresh: true)
        let id = UUID().uuidString.lowercased()
        var stateDuringCall: ShowRecord.State?
        let outcome = try show(docs, id: id) { source, recordID in
            XCTAssertEqual(recordID, id)
            XCTAssertEqual(source.kind, .path)
            stateDuringCall = self.record(docs)?.entries.first?.state
            return ["action": "opened"]
        }
        guard case .answered(let result) = outcome else { return XCTFail("expected c11's answer") }
        XCTAssertEqual(result["action"] as? String, "opened")
        XCTAssertEqual(stateDuringCall, .live)
    }

    func testFreshButUnreachableTurnsTheEntryWaiting() throws {
        let errors: [Error] = [Unreachable(), C11RelayCallError.unreachable(spooled: false, spoolFull: false)]
        for error in errors {
            let docs = try docs(fresh: true)
            guard case .recorded = try show(docs, call: { _, _ in throw error }) else { return XCTFail("expected the away outcome") }
            XCTAssertEqual(record(docs)?.entries.map(\.state), [.waiting])
        }
    }

    func testARefusalLeavesNoEntryAndIsReported() throws {
        let docs = try docs(fresh: true)
        XCTAssertThrowsError(try show(docs, call: { _, _ in
            throw C11RelayCallError.refused(code: ShowSpec.Code.refusedURL, message: "loopback")
        }))
        XCTAssertEqual(record(docs)?.entries.count, 0)
    }

    func testMissingPathFailsBeforeAnyWrite() throws {
        let docs = try docs(fresh: true)
        let written = docs.sets.count
        XCTAssertThrowsError(try show(docs, target: folder.appendingPathComponent("gone.html").path)) { error in
            XCTAssertEqual((error as? ShowCLIRecord.Failure)?.code, ShowSpec.Code.notFound)
        }
        XCTAssertEqual(docs.sets.count, written)
    }

    func testReshowOfTheSameSourceKeepsOneEntry() throws {
        let docs = try docs(fresh: false)
        _ = try show(docs, id: UUID().uuidString.lowercased())
        let second = UUID().uuidString.lowercased()
        _ = try show(docs, target: folder.appendingPathComponent("./page.html").path, id: second)
        XCTAssertEqual(record(docs)?.entries.map(\.id), [second])
    }

    func testOverEightMegabytesIsRefused() throws {
        let big = folder.appendingPathComponent("big.html")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ShowSpec.maxBytes + 1))
        try handle.close()
        let docs = try docs(fresh: false)
        XCTAssertThrowsError(try show(docs, target: big.path)) { error in
            XCTAssertEqual((error as? ShowCLIRecord.Failure)?.code, ShowSpec.Code.tooLarge)
        }
        XCTAssertNil(record(docs))
    }

    func testAwayAndUnwritableIsUnrecorded() throws {
        final class Broken: C11RelayDocStore {
            func get(_ name: String) throws -> (value: Any?, version: UInt64) { throw C11RelayStoreError.unavailable("not allowed") }
            func set(_ name: String, value: Any?, version: UInt64) throws -> UInt64 { throw C11RelayStoreError.unavailable("not allowed") }
        }
        XCTAssertThrowsError(try ShowCLIRecord.openRelayed(target: page, dir: nil, cwd: "/", home: nil, store: Broken(),
                                                          panel: panel, now: now, call: { _, _ in [:] })) { error in
            XCTAssertEqual((error as? ShowCLIRecord.Failure)?.code, "show_unrecorded")
        }
    }

    func testCloseWhileAwayMarksTheRecordClosed() throws {
        let docs = try docs(fresh: false)
        _ = try show(docs)
        let source = ShowCLIRecord.resolveForClose(target: page, dir: nil, cwd: "/", home: nil)
        guard case .recorded = try ShowCLIRecord.closeRelayed(source: source, store: docs, panel: panel, now: now,
                                                             call: { XCTFail("c11 was asked while away"); return [:] })
        else { return XCTFail("expected the away outcome") }
        XCTAssertEqual(record(docs)?.entries.map(\.state), [.closed])
    }

    func testTargetsResolveHere() throws {
        XCTAssertTrue(ShowCLIRecord.isURL("http://studio:5173"))
        XCTAssertTrue(ShowCLIRecord.isURL("file:///tmp/x.html"))
        XCTAssertFalse(ShowCLIRecord.isURL("docs/x.html"))
        XCTAssertFalse(ShowCLIRecord.isURL("mailto:x"))
        XCTAssertEqual(ShowCLIRecord.absolute("~/x.html", cwd: "/w", home: "/home/a"), "/home/a/x.html")
        XCTAssertEqual(ShowCLIRecord.absolute("x.html", cwd: "/w", home: "/home/a"), "/w/x.html")
        let source = try ShowCLIRecord.resolve(target: "page.html", dir: ".", cwd: folder.path, home: nil)
        XCTAssertEqual(source.target, ShowCLIRecord.realPath(page))
        XCTAssertEqual(source.dir, ShowCLIRecord.realPath(folder.path))
        XCTAssertThrowsError(try ShowCLIRecord.resolve(target: page, dir: page, cwd: "/", home: nil)) { error in
            XCTAssertEqual((error as? ShowCLIRecord.Failure)?.code, ShowSpec.Code.badDir)
        }
        XCTAssertEqual(try ShowCLIRecord.waitSeconds("500"), ShowSpec.waitSecondsRange.upperBound)
        XCTAssertEqual(try ShowCLIRecord.waitSeconds(nil), ShowSpec.defaultWaitSeconds)
    }
}
