import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HealthIPSParserTests: XCTestCase {

    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("health")
            .appendingPathComponent("ips", isDirectory: true)
    }

    func testParsesCrashFirstLine() throws {
        let url = fixturesURL.appendingPathComponent("sample-crash.ips")
        let body = try String(contentsOf: url, encoding: .utf8)
        guard let firstLine = body.split(separator: "\n").first else {
            XCTFail("fixture has no first line")
            return
        }
        let header = try XCTUnwrap(parseIPSFirstLine(String(firstLine)))
        XCTAssertEqual(header.bundleID, "com.stage11.c11")
        XCTAssertEqual(header.bugType, "309")
        XCTAssertEqual(header.incidentID, "00000000-0000-0000-0000-000000000001")
        let expected = parseIPSTimestamp("2026-05-03 15:19:00.000 -0400")
        XCTAssertNotNil(expected)
        XCTAssertEqual(header.timestamp, expected,
                       "first-line `timestamp` must round-trip through parseIPSTimestamp")
    }

    func testParseIPSTimestampHandlesAppleFormat() {
        let date = parseIPSTimestamp("2026-05-03 15:19:00.000 -0400")
        XCTAssertNotNil(date)

        let utc = parseIPSTimestamp("2026-05-03 15:19:00.000 +0000")
        XCTAssertNotNil(utc)

        XCTAssertNil(parseIPSTimestamp(""))
        XCTAssertNil(parseIPSTimestamp("not a date"))
        XCTAssertNil(parseIPSTimestamp("2026-05-03T15:19:00Z"),
                     "ISO-8601 form is not the IPS first-line format and must not parse")
    }

    func testParsesHangFirstLine() throws {
        let url = fixturesURL.appendingPathComponent("sample-hang.ips")
        let body = try String(contentsOf: url, encoding: .utf8)
        guard let firstLine = body.split(separator: "\n").first else {
            XCTFail("fixture has no first line")
            return
        }
        let header = try XCTUnwrap(parseIPSFirstLine(String(firstLine)))
        XCTAssertEqual(header.bundleID, "com.stage11.c11")
        XCTAssertEqual(header.incidentID, "00000000-0000-0000-0000-000000000002")
    }

    func testRejectsMalformedFirstLine() {
        XCTAssertNil(parseIPSFirstLine(""))
        XCTAssertNil(parseIPSFirstLine("not json"))
        XCTAssertNil(parseIPSFirstLine("[\"array\"]"))
    }

    func testScanIPSPicksUpTopLevelC11File() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reportsDir = tmp.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        let crashFixture = try Data(contentsOf: fixturesURL.appendingPathComponent("sample-crash.ips"))
        let target = reportsDir.appendingPathComponent("c11-2026-05-03-151900.ips")
        try crashFixture.write(to: target)

        let events = scanIPS(home: tmp.path, since: Date.distantPast)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.rail, .ips)
        XCTAssertEqual(events.first?.severity, .crash)
        XCTAssertTrue(events.first?.summary.contains("com.stage11.c11") == true)
    }

    func testScanIPSPicksUpPerBundleSubdirFile() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleDir = tmp.appendingPathComponent(
            "Library/Logs/DiagnosticReports/com.stage11.c11.debug.foo",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let crashFixture = try Data(contentsOf: fixturesURL.appendingPathComponent("sample-crash.ips"))
        let target = bundleDir.appendingPathComponent("Crash-2026-05-03-151900.ips")
        try crashFixture.write(to: target)

        let events = scanIPS(home: tmp.path, since: Date.distantPast)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.rail, .ips)
    }

    func testScanIPSSkipsTopLevelNonC11File() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reportsDir = tmp.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        let crashFixture = try Data(contentsOf: fixturesURL.appendingPathComponent("sample-crash.ips"))
        let unrelated = reportsDir.appendingPathComponent("Safari-2026-05-03-151900.ips")
        try crashFixture.write(to: unrelated)

        let events = scanIPS(home: tmp.path, since: Date.distantPast)
        XCTAssertTrue(events.isEmpty, "non-c11 IPS files at top level must be ignored")
    }

    func testScanIPSUsesParsedTimestampForSinceFilter() throws {
        // The OS-reported timestamp must beat file mtime as the basis for
        // --since filtering. CrashReporter can finish writing the file
        // long after the actual crash, so mtime is a strictly worse proxy
        // when the first-line JSON carries a timestamp.
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reportsDir = tmp.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        let crashTime = Date(timeIntervalSinceNow: -10 * 60)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        let crashTimeStr = f.string(from: crashTime)

        let body = "{\"app_name\":\"c11\",\"bundleID\":\"com.stage11.c11\",\"bug_type\":\"309\",\"incident_id\":\"abc12345-0000-0000-0000-000000000000\",\"timestamp\":\"" + crashTimeStr + "\"}\n"
        let target = reportsDir.appendingPathComponent("c11-runtime.ips")
        try Data(body.utf8).write(to: target)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: target.path
        )

        let events = scanIPS(home: tmp.path, since: Date(timeIntervalSinceNow: -30 * 60))
        XCTAssertEqual(events.count, 1,
                       "parsed timestamp (10m ago) must be used; mtime (1h ago) would have filtered this out")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(
            event.timestamp.timeIntervalSinceReferenceDate,
            crashTime.timeIntervalSinceReferenceDate,
            accuracy: 0.01,
            "row timestamp must come from the first-line JSON, not file mtime"
        )
    }

    func testScanIPSFallsBackToMtimeWhenTimestampMissing() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reportsDir = tmp.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        let body = "{\"app_name\":\"c11\",\"bundleID\":\"com.stage11.c11\",\"bug_type\":\"309\",\"incident_id\":\"xyz98765-0000-0000-0000-000000000000\"}\n"
        let target = reportsDir.appendingPathComponent("c11-fallback.ips")
        try Data(body.utf8).write(to: target)

        let oneHourAgo = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes(
            [.modificationDate: oneHourAgo],
            ofItemAtPath: target.path
        )

        let recent = scanIPS(home: tmp.path, since: Date(timeIntervalSinceNow: -60))
        XCTAssertTrue(recent.isEmpty,
                      "without a parsed timestamp, mtime is the fallback and the recent window excludes 1h-old files")

        let wide = scanIPS(home: tmp.path, since: Date(timeIntervalSinceNow: -7200))
        XCTAssertEqual(wide.count, 1,
                       "wide window includes the 1h-old mtime fallback")
    }

    func testScanIPSMalformedTimestampFallsBackToMtime() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reportsDir = tmp.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        let body = "{\"bundleID\":\"com.stage11.c11\",\"bug_type\":\"309\",\"incident_id\":\"id1\",\"timestamp\":\"not-a-real-timestamp\"}\n"
        let target = reportsDir.appendingPathComponent("c11-malformed-ts.ips")
        try Data(body.utf8).write(to: target)

        let recent = scanIPS(home: tmp.path, since: Date(timeIntervalSinceNow: -60))
        XCTAssertEqual(recent.count, 1,
                       "malformed timestamp must fall back to mtime (which is 'now') silently")
    }

    // c11-2.0:begin-keep (the retired c11h line is the foreign one here)
    func testScanIPSIgnoresForeignTopLevelAndForeignBundleDirectories() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reports = tmp.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let foreignDir = reports.appendingPathComponent("com.stage11.c11h", isDirectory: true)
        let ownDir = reports.appendingPathComponent("com.stage11.c11.debug.foo", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ownDir, withIntermediateDirectories: true)
        let body = Data("{\"bundleID\":\"com.stage11.c11h\",\"bug_type\":\"309\"}\n".utf8)
        try body.write(to: reports.appendingPathComponent("c11h-review-fixture.ips"))
        try body.write(to: reports.appendingPathComponent("c11mux-review-fixture.ips"))
        try body.write(to: reports.appendingPathComponent("c11-review-fixture.ips"))
        try body.write(to: foreignDir.appendingPathComponent("Crash.ips"))
        try body.write(to: ownDir.appendingPathComponent("Crash.ips"))

        let paths = scanIPS(home: tmp.path, since: .distantPast).map(\.path)
        XCTAssertEqual(paths.filter { $0.contains("c11-review-fixture.ips") }.count, 1)
        XCTAssertEqual(paths.filter { $0.contains("/com.stage11.c11.debug.foo/") }.count, 1)
        XCTAssertTrue(paths.allSatisfy { !$0.contains("c11h-review-fixture.ips") && !$0.contains("c11mux-review-fixture.ips") })
        XCTAssertTrue(paths.allSatisfy { !$0.contains("/com.stage11.c11h/") })
    }
    // c11-2.0:end-keep

    // c11-2.0:begin-keep (the retired c11h line is the foreign one here)
    func testTopLevelIPSNamesStayInsideC11() {
        for name in [
            "c11.ips",
            "c11-2026-05-03-151900.ips",
            "c11.runtime.ips",
            "c11 fallback.ips",
            "com.stage11.c11.ips",
            "com.stage11.c11.debug.foo.ips",
            "Crash-com.stage11.c11-2026.ips",
        ] {
            XCTAssertTrue(isC11TopLevelIPSFileName(name), name)
        }
        for name in [
            "c11h.ips",
            "c11h-2026-05-03-151900.ips",
            "c11mux.ips",
            "c11mux-review.ips",
            "cmux.ips",
            "com.stage11.c11h.ips",
            "com.stage11.c11h.debug.ips",
            "com.stage11.c11hh.ips",
            "notes.ips",
        ] {
            XCTAssertFalse(isC11TopLevelIPSFileName(name), name)
        }
    }
    // c11-2.0:end-keep

    func testScanIPSGracefulOnMissingDirectory() {
        let events = scanIPS(home: "/nonexistent/path-that-cannot-exist-1234", since: Date.distantPast)
        XCTAssertTrue(events.isEmpty)
    }

    private func makeTempHome() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-health-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
