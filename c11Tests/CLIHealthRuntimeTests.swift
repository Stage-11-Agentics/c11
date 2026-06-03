import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class CLIHealthRuntimeTests: XCTestCase {

    private var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("health")
            .appendingPathComponent("golden", isDirectory: true)
    }

    // MARK: Sandboxed end-to-end

    func testCollectHealthEventsAcrossAllFourRails() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try scaffoldAllRails(in: tmp)

        let now = Date()
        let window = HealthCollectionWindow(
            mode: .defaultLast24h,
            since: now.addingTimeInterval(-24 * 3600),
            until: now
        )
        let allRails = Set(HealthEvent.Rail.allCases)
        let events = collectHealthEvents(window: window, rails: allRails, home: tmp.path)

        XCTAssertEqual(events.count, 4, "all four rails should each produce exactly one event")
        let railCounts = Dictionary(grouping: events, by: \.rail).mapValues(\.count)
        XCTAssertEqual(railCounts[.ips], 1)
        XCTAssertEqual(railCounts[.sentry], 1)
        XCTAssertEqual(railCounts[.metrickit], 1)
        XCTAssertEqual(railCounts[.sentinel], 1)

        // Reverse-chronological ordering.
        for i in 1..<events.count {
            XCTAssertGreaterThanOrEqual(
                events[i - 1].timestamp,
                events[i].timestamp,
                "events must be sorted reverse-chronologically"
            )
        }
    }

    func testJSONShapeContainsTopLevelKeys() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try scaffoldAllRails(in: tmp)

        let now = Date()
        let window = HealthCollectionWindow(
            mode: .defaultLast24h,
            since: now.addingTimeInterval(-24 * 3600),
            until: now
        )
        let allRails = Set(HealthEvent.Rail.allCases)
        let events = collectHealthEvents(window: window, rails: allRails, home: tmp.path)

        let data = try renderHealthJSON(
            events: events,
            window: window,
            rails: allRails,
            warnings: ["sample-warning"],
            home: tmp.path
        )
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["schema_version"] as? Int, healthJSONSchemaVersion)
        XCTAssertNotNil(obj["window"] as? [String: Any])
        XCTAssertNotNil(obj["rails"] as? [String: Any])
        XCTAssertNotNil(obj["events"] as? [[String: Any]])
        XCTAssertEqual(obj["warnings"] as? [String], ["sample-warning"])

        let rails = try XCTUnwrap(obj["rails"] as? [String: Any])
        for rail in HealthEvent.Rail.allCases {
            let railObj = try XCTUnwrap(rails[rail.rawValue] as? [String: Any])
            XCTAssertEqual(railObj["count"] as? Int, 1)
        }

        let evs = try XCTUnwrap(obj["events"] as? [[String: Any]])
        XCTAssertEqual(evs.count, 4)
        for ev in evs {
            XCTAssertNotNil(ev["timestamp"] as? String)
            XCTAssertNotNil(ev["rail"] as? String)
            XCTAssertNotNil(ev["severity"] as? String)
            XCTAssertNotNil(ev["summary"] as? String)
            let path = try XCTUnwrap(ev["path"] as? String)
            XCTAssertTrue(path.hasPrefix("~/"), "JSON paths must be redacted with ~ prefix; got \(path)")
            XCTAssertFalse(path.contains(tmp.path), "JSON paths must not leak the absolute home; got \(path)")
        }

        let win = try XCTUnwrap(obj["window"] as? [String: Any])
        XCTAssertEqual(win["mode"] as? String, "default-24h")
    }

    func testCollectHealthEventsHasStableTiebreak() throws {
        // Two events with the same timestamp across rails: the sort must
        // be deterministic so `--json` output never flaps for downstream
        // consumers (jq filters, CI gates, fleet aggregators).
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let now = Date()
        let stamp = filenameSafeISOForNow()

        // Two MetricKit files at the exact same parsed timestamp.
        let metricDir = tmp.appendingPathComponent("Library/Logs/c11/metrickit", isDirectory: true)
        try FileManager.default.createDirectory(at: metricDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: metricDir.appendingPathComponent("\(stamp)-crash1.json"))

        // Two sentinel files at the same parsed timestamp under different bundles.
        for bundle in ["com.stage11.c11.debug.aaa", "com.stage11.c11.debug.bbb"] {
            let sessionsDir = tmp.appendingPathComponent(
                "Library/Caches/\(bundle)/sessions",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            let body: [String: Any] = ["version": "0.44.1", "launched_at": ISO8601DateFormatter().string(from: now)]
            let data = try JSONSerialization.data(withJSONObject: body, options: [])
            try data.write(to: sessionsDir.appendingPathComponent("unclean-exit-\(stamp).json"))
        }

        let window = HealthCollectionWindow(
            mode: .defaultLast24h,
            since: now.addingTimeInterval(-24 * 3600),
            until: now.addingTimeInterval(60)
        )
        let allRails = Set(HealthEvent.Rail.allCases)
        let events1 = collectHealthEvents(window: window, rails: allRails, home: tmp.path)
        let events2 = collectHealthEvents(window: window, rails: allRails, home: tmp.path)

        XCTAssertEqual(events1.map(\.path), events2.map(\.path),
                       "two collections of identical disk state must produce identical event order")
    }

    func testGracefulOnEmptyHome() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let now = Date()
        let window = HealthCollectionWindow(
            mode: .defaultLast24h,
            since: now.addingTimeInterval(-24 * 3600),
            until: now
        )
        let events = collectHealthEvents(
            window: window,
            rails: Set(HealthEvent.Rail.allCases),
            home: tmp.path
        )
        XCTAssertTrue(events.isEmpty, "empty HOME must not error and must produce no events")
    }

    // MARK: Golden snapshots

    func testEmptyResultLineMatchesGolden() throws {
        let rendered = renderHealthTable([])
        let goldenURL = self.goldenURL.appendingPathComponent("empty.txt")
        let golden = try String(contentsOf: goldenURL, encoding: .utf8)
        XCTAssertEqual(rendered, golden)
    }

    func testEmptyResultLineReflectsRailFilter() {
        let rendered = renderHealthTable([], rails: [.sentinel])
        XCTAssertTrue(
            rendered.contains("across sentinel."),
            "empty line must name only the queried rail; got \(rendered)"
        )
        XCTAssertFalse(
            rendered.contains("ips, sentry, metrickit"),
            "empty line must not list rails the operator did not ask about; got \(rendered)"
        )
    }

    func testEmptyResultLineReflectsSinceWindow() {
        let now = Date()
        let window = HealthCollectionWindow(
            mode: .sinceDuration,
            since: now.addingTimeInterval(-30 * 60),
            until: now
        )
        let rendered = renderHealthTable([], rails: [.ips, .sentry], window: window)
        XCTAssertTrue(
            rendered.contains("in the last 30m"),
            "empty line must reflect the actual --since window; got \(rendered)"
        )
    }

    func testEmptyResultLineReflectsSinceBoot() {
        let now = Date()
        let window = HealthCollectionWindow(
            mode: .sinceBoot,
            since: now.addingTimeInterval(-3600),
            until: now
        )
        let rendered = renderHealthTable([], window: window)
        XCTAssertTrue(
            rendered.contains("nothing since boot"),
            "empty line must say 'since boot' for --since-boot mode; got \(rendered)"
        )
    }

    func testFourEventsTableMatchesGolden() throws {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let events: [HealthEvent] = [
            HealthEvent(
                timestamp: try XCTUnwrap(f.date(from: "2026-05-03T15:28:00.000Z")),
                rail: .sentinel,
                severity: .unclean_exit,
                summary: "0.44.1 (0.44.1.123) e6ce1be2",
                path: "/tmp/sentinel/unclean-exit-2026-05-03T15-28-00.000Z.json"
            ),
            HealthEvent(
                timestamp: try XCTUnwrap(f.date(from: "2026-05-03T15:19:00.000Z")),
                rail: .ips,
                severity: .crash,
                summary: "com.stage11.c11 bug_type=309 (00000000)",
                path: "/tmp/ips/sample.ips"
            ),
            HealthEvent(
                timestamp: try XCTUnwrap(f.date(from: "2026-05-03T14:30:00.000Z")),
                rail: .metrickit,
                severity: .hang,
                summary: "hang3",
                path: "/tmp/metrickit/hang.json"
            ),
            HealthEvent(
                timestamp: try XCTUnwrap(f.date(from: "2026-05-03T13:00:00.000Z")),
                rail: .sentry,
                severity: .queued,
                summary: "com.stage11.c11.debug.foo/envelope-1",
                path: "/tmp/sentry/envelope-1"
            ),
        ]

        let rendered = renderHealthTable(events, timeZone: TimeZone(identifier: "UTC"))
        let goldenURL = self.goldenURL.appendingPathComponent("four-events.txt")
        let golden = try String(contentsOf: goldenURL, encoding: .utf8)
        XCTAssertEqual(rendered, golden)
    }

    // MARK: Helpers

    private func makeTempHome() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-health-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve `/var/folders/...` → `/private/var/folders/...` via libc's
        // `realpath` so the path passed to `redactHomePath(_:home:)` matches
        // the resolved form FileManager enumeration returns for the same
        // files. Neither `URL.resolvingSymlinksInPath()` nor
        // `NSString.resolvingSymlinksInPath` resolves macOS's top-level `/var`
        // → `/private/var` symlink; only realpath(3) does the kernel-level
        // lookup.
        guard let resolved = dir.path.withCString({ realpath($0, nil) }) else {
            return dir
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func scaffoldAllRails(in home: URL) throws {
        let fm = FileManager.default

        // IPS rail: top-level c11-named .ips with a parseable first line.
        // Generate the timestamp dynamically so the parsed value is always
        // within the 24h window the test queries (the scanner now prefers
        // the JSON `timestamp` over mtime for since-filtering).
        let reportsDir = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try fm.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        let ipsTSFormatter = DateFormatter()
        ipsTSFormatter.locale = Locale(identifier: "en_US_POSIX")
        ipsTSFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        let ipsTimestamp = ipsTSFormatter.string(from: Date())
        let ipsBody = "{\"app_name\":\"c11\",\"app_version\":\"0.44.1\",\"bundleID\":\"com.stage11.c11\",\"bug_type\":\"309\",\"incident_id\":\"00000000-0000-0000-0000-000000000001\",\"timestamp\":\"" + ipsTimestamp + "\"}\n{\"crashed_thread\":0}\n"
        try ipsBody.data(using: .utf8)!.write(
            to: reportsDir.appendingPathComponent("c11-runtime-test.ips")
        )

        // Sentry rail: one envelope under a per-bundle dir.
        let envelopesDir = home.appendingPathComponent(
            "Library/Caches/com.stage11.c11.debug.runtime/io.sentry/envelopes",
            isDirectory: true
        )
        try fm.createDirectory(at: envelopesDir, withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: envelopesDir.appendingPathComponent("envelope-runtime"))

        // MetricKit rail: one valid kind file in the future window so the
        // since-cutoff (-24h) cannot accidentally drop it.
        let metricDir = home.appendingPathComponent("Library/Logs/c11/metrickit", isDirectory: true)
        try fm.createDirectory(at: metricDir, withIntermediateDirectories: true)
        let metricStamp = filenameSafeISOForNow()
        try Data("{}".utf8).write(
            to: metricDir.appendingPathComponent("\(metricStamp)-crash1.json")
        )

        // Sentinel rail: one unclean-exit archive with a fresh stamp.
        let sessionsDir = home.appendingPathComponent(
            "Library/Caches/com.stage11.c11.debug.runtime/sessions",
            isDirectory: true
        )
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sentinelBody: [String: Any] = [
            "version": "0.44.1",
            "build": "0.44.1.123",
            "commit": "e6ce1be28",
            "bundle_id": "com.stage11.c11.debug.runtime",
            "launched_at": ISO8601DateFormatter().string(from: Date()),
            "pid": 9999,
        ]
        let sentinelData = try JSONSerialization.data(
            withJSONObject: sentinelBody,
            options: [.prettyPrinted, .sortedKeys]
        )
        try sentinelData.write(
            to: sessionsDir.appendingPathComponent("unclean-exit-\(metricStamp).json")
        )
    }

    private func filenameSafeISOForNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
