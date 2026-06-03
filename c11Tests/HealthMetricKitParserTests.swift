import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HealthMetricKitParserTests: XCTestCase {

    func testParsesCrashKind() {
        let result = parseMetricKitFilename("2026-05-03T15-19-00.123Z-crash1.json")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, "crash1")
    }

    func testParsesHangKind() {
        let result = parseMetricKitFilename("2026-05-03T15-19-00.456Z-hang3.json")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, "hang3")
    }

    func testParsesCrashHangMixedKind() {
        let result = parseMetricKitFilename("2026-05-03T15-19-00.789Z-crash1-hang2.json")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, "crash1-hang2")
    }

    func testParsesResourceKind() {
        let result = parseMetricKitFilename("2026-05-03T15-19-01.000Z-disk1-cpu1.json")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, "disk1-cpu1")
    }

    func testParsesDiagnosticKind() {
        let result = parseMetricKitFilename("2026-05-03T15-19-01.234Z-diagnostic.json")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, "diagnostic")
    }

    func testSkipsMetricKind() {
        XCTAssertNil(
            parseMetricKitFilename("2026-05-03T15-19-01.456Z-metric.json"),
            "metric rows are MXMetricPayload baselines, not diagnostics; must be skipped in v1"
        )
    }

    func testRejectsMalformedNames() {
        XCTAssertNil(parseMetricKitFilename("bogus-not-a-stamp.json"))
        XCTAssertNil(parseMetricKitFilename(""))
        XCTAssertNil(parseMetricKitFilename(".json"))
        XCTAssertNil(parseMetricKitFilename("2026-05-03T15-19-00Z-crash1.json"),
                     "missing fractional-seconds component must be rejected")
        XCTAssertNil(parseMetricKitFilename("2026-05-03T15-19-00.123Z-bogus.json"),
                     "unknown kind tokens must be rejected")
        XCTAssertNil(parseMetricKitFilename("2026-05-03T15-19-00.123Z-crash.json"),
                     "category tokens must include a count suffix")
    }

    func testStampParsesAsUTC() {
        let result = parseMetricKitFilename("2026-05-03T15-19-00.123Z-crash1.json")
        let timestamp = result?.timestamp
        XCTAssertNotNil(timestamp)

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = f.date(from: "2026-05-03T15:19:00.123Z")
        XCTAssertEqual(timestamp, expected)
    }

    func testScanMetricKitPicksUpFiles() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let metricDir = tmp.appendingPathComponent("Library/Logs/c11/metrickit", isDirectory: true)
        try FileManager.default.createDirectory(at: metricDir, withIntermediateDirectories: true)

        let names = [
            "2026-05-03T15-19-00.123Z-crash1.json",
            "2026-05-03T15-19-00.456Z-hang3.json",
            "2026-05-03T15-19-01.234Z-diagnostic.json",
            "2026-05-03T15-19-01.456Z-metric.json",
            "bogus-not-a-stamp.json",
        ]
        for name in names {
            try Data("{}".utf8).write(to: metricDir.appendingPathComponent(name))
        }

        let events = scanMetricKit(home: tmp.path, since: Date.distantPast)
        // metric and bogus filtered, leaving 3 valid rows.
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.allSatisfy { $0.rail == .metrickit })

        let summaries = Set(events.map(\.summary))
        XCTAssertEqual(summaries, ["crash1", "hang3", "diagnostic"])
    }

    func testScanMetricKitGracefulOnMissingDirectory() {
        let events = scanMetricKit(home: "/nonexistent/path-1234", since: Date.distantPast)
        XCTAssertTrue(events.isEmpty)
    }

    private func makeTempHome() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-health-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
