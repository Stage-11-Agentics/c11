import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HealthSentinelParserTests: XCTestCase {

    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("health")
            .appendingPathComponent("sentinel", isDirectory: true)
    }

    func testParsesFixtureUncleanExit() throws {
        let url = fixturesURL.appendingPathComponent("unclean-exit-2026-05-03T15-19-00.123Z.json")
        let event = try XCTUnwrap(parseUncleanExitFile(at: url, since: Date.distantPast))
        XCTAssertEqual(event.rail, .sentinel)
        XCTAssertEqual(event.severity, .unclean_exit)
        XCTAssertTrue(event.summary.contains("0.44.1"))
        XCTAssertTrue(event.summary.contains("0.44.1.123"))
        XCTAssertTrue(event.summary.contains("e6ce1be2"),
                      "summary must include the 8-char short commit hash")
    }

    func testTimestampParsedFromFilename() throws {
        let url = fixturesURL.appendingPathComponent("unclean-exit-2026-05-03T15-19-00.123Z.json")
        let event = try XCTUnwrap(parseUncleanExitFile(at: url, since: Date.distantPast))

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = f.date(from: "2026-05-03T15:19:00.123Z")
        XCTAssertEqual(event.timestamp, expected)
    }

    func testCorruptBodyRendersUnknownPlaceholders() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-health-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let target = tmp.appendingPathComponent("unclean-exit-2026-05-03T15-19-00.123Z.json")
        try Data("not valid json".utf8).write(to: target)

        let event = try XCTUnwrap(parseUncleanExitFile(at: target, since: Date.distantPast))
        XCTAssertEqual(event.severity, .unclean_exit,
                       "corrupt-body rows must still surface; the file's presence is the signal")
        XCTAssertEqual(event.summary, "unknown (unknown) unknown",
                       "corrupt body must render 'unknown' placeholders, not '?' or '????????'")
    }

    func testMissingJSONKeysRenderUnknownPlaceholders() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-health-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let target = tmp.appendingPathComponent("unclean-exit-2026-05-03T15-19-00.123Z.json")
        try Data("{}".utf8).write(to: target)

        let event = try XCTUnwrap(parseUncleanExitFile(at: target, since: Date.distantPast))
        XCTAssertEqual(event.summary, "unknown (unknown) unknown")
    }

    func testRejectsWhenStampPredatesSince() throws {
        let url = fixturesURL.appendingPathComponent("unclean-exit-2026-05-03T15-19-00.123Z.json")
        let cutoff = ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z")!
        XCTAssertNil(parseUncleanExitFile(at: url, since: cutoff))
    }

    func testScanLaunchSentinelFindsArchivedFile() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11.debug.foo/sessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let fixture = try Data(
            contentsOf: fixturesURL.appendingPathComponent("unclean-exit-2026-05-03T15-19-00.123Z.json")
        )
        let target = sessionsDir.appendingPathComponent("unclean-exit-2026-05-03T15-19-00.123Z.json")
        try fixture.write(to: target)

        let events = scanLaunchSentinel(home: tmp.path, since: Date.distantPast)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.rail, .sentinel)
        XCTAssertEqual(events.first?.severity, .unclean_exit)
    }

    func testScanLaunchSentinelIgnoresActiveJSON() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11/sessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sessionsDir.appendingPathComponent("active.json"))

        let events = scanLaunchSentinel(home: tmp.path, since: Date.distantPast)
        XCTAssertTrue(events.isEmpty, "active.json represents the live session, not an unclean exit")
    }

    func testScanLaunchSentinelIgnoresNonC11Bundles() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent(
            "Library/Caches/com.example.other/sessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: sessionsDir.appendingPathComponent("unclean-exit-2026-05-03T15-19-00.123Z.json")
        )

        let events = scanLaunchSentinel(home: tmp.path, since: Date.distantPast)
        XCTAssertTrue(events.isEmpty)
    }

    func testScanLaunchSentinelGracefulOnMissingDirectory() {
        let events = scanLaunchSentinel(home: "/nonexistent/path-1234", since: Date.distantPast)
        XCTAssertTrue(events.isEmpty)
    }

    private func makeTempHome() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-health-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
