import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HealthFlagsTests: XCTestCase {

    // MARK: parseSinceFlag

    func testParseSinceMinutes() {
        XCTAssertEqual(parseSinceFlag("30m"), 30 * 60)
        XCTAssertEqual(parseSinceFlag("1m"), 60)
    }

    func testParseSinceHours() {
        XCTAssertEqual(parseSinceFlag("2h"), 2 * 3600)
        XCTAssertEqual(parseSinceFlag("24h"), 24 * 3600)
    }

    func testParseSinceDays() {
        XCTAssertEqual(parseSinceFlag("3d"), 3 * 86400)
    }

    func testParseSinceRejectsInvalid() {
        XCTAssertNil(parseSinceFlag(""))
        XCTAssertNil(parseSinceFlag("m"))
        XCTAssertNil(parseSinceFlag("0m"), "zero is rejected: an empty window is not a useful query")
        XCTAssertNil(parseSinceFlag("-1h"))
        XCTAssertNil(parseSinceFlag("3y"))
        XCTAssertNil(parseSinceFlag("abc"))
    }

    // MARK: parseHealthCLIArgs

    func testNoArgsDefaultsTo24h() throws {
        let opts = try parseHealthCLIArgs([])
        XCTAssertEqual(opts.mode, .defaultLast24h)
        XCTAssertNil(opts.railFilter)
        XCTAssertFalse(opts.json)
    }

    func testParsesSinceFlag() throws {
        let opts = try parseHealthCLIArgs(["--since", "30m"])
        XCTAssertEqual(opts.mode, .sinceDuration)
        XCTAssertEqual(opts.windowDuration, 30 * 60)
    }

    func testParsesSinceBoot() throws {
        let opts = try parseHealthCLIArgs(["--since-boot"])
        XCTAssertEqual(opts.mode, .sinceBoot)
    }

    func testParsesRailFilter() throws {
        let opts = try parseHealthCLIArgs(["--rail", "sentinel"])
        XCTAssertEqual(opts.railFilter, .sentinel)
    }

    func testParsesJSONFlag() throws {
        let opts = try parseHealthCLIArgs(["--json"])
        XCTAssertTrue(opts.json)
    }

    func testRejectsMutuallyExclusiveSinceFlags() {
        XCTAssertThrowsError(try parseHealthCLIArgs(["--since", "1h", "--since-boot"])) { error in
            if case HealthCLIError.mutuallyExclusiveSinceFlags = error {} else {
                XCTFail("expected .mutuallyExclusiveSinceFlags; got \(error)")
            }
        }
    }

    func testRejectsUnknownRail() {
        XCTAssertThrowsError(try parseHealthCLIArgs(["--rail", "bogus"])) { error in
            if case HealthCLIError.unknownRail = error {} else { XCTFail("expected .unknownRail; got \(error)") }
        }
    }

    func testRejectsInvalidSince() {
        XCTAssertThrowsError(try parseHealthCLIArgs(["--since", "1y"])) { error in
            if case HealthCLIError.invalidSinceValue = error {} else { XCTFail("expected .invalidSinceValue; got \(error)") }
        }
    }

    func testRejectsUnknownFlag() {
        XCTAssertThrowsError(try parseHealthCLIArgs(["--bogus"])) { error in
            if case HealthCLIError.unknownFlag = error {} else { XCTFail("expected .unknownFlag; got \(error)") }
        }
    }

    func testRejectsMissingValue() {
        XCTAssertThrowsError(try parseHealthCLIArgs(["--since"])) { error in
            if case HealthCLIError.missingValue = error {} else { XCTFail("expected .missingValue; got \(error)") }
        }
    }

    func testRejectsDuplicateRailFlag() {
        XCTAssertThrowsError(try parseHealthCLIArgs(["--rail", "ips", "--rail", "sentinel"])) { error in
            if case HealthCLIError.duplicateFlag(let f) = error {
                XCTAssertEqual(f, "--rail")
            } else {
                XCTFail("expected .duplicateFlag(\"--rail\"); got \(error)")
            }
        }
    }

    // MARK: bootTime

    func testBootTimeIsRecentPast() {
        let boot = bootTime()
        XCTAssertLessThan(boot, Date(), "boot time must be before now")
        let yearAgo = Date(timeIntervalSinceNow: -365 * 86400)
        XCTAssertGreaterThan(boot, yearAgo, "boot time must be within the last year on a normal machine")
    }

    func testBootTimeFallbackDoesNotEmitDiagnosticOnSuccess() {
        // sysctl works on macOS, so the success path must NOT call onFallback.
        var called = false
        _ = bootTime { _ in called = true }
        XCTAssertFalse(called, "kern.boottime succeeds on macOS; fallback diagnostic must not fire")
    }

    // MARK: warnings

    func testMetricKitBaselineWarningSilentWhenCountNonzero() {
        let result = metricKitBaselineWarning(
            home: "/nonexistent",
            bundleVersion: "0.44.1",
            metricKitCount: 5
        )
        XCTAssertNil(result)
    }

    func testMetricKitBaselineWarningSilentWhenNoMarker() {
        let tmp = NSTemporaryDirectory() + "c11-flags-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let result = metricKitBaselineWarning(
            home: tmp,
            bundleVersion: "0.44.1",
            metricKitCount: 0
        )
        XCTAssertNil(result, "no prior marker on disk means we have no baseline to compare against")
    }

    func testMetricKitBaselineWarningFiresOnRecentVersionBump() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11/sessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let priorTimestamp = now.addingTimeInterval(-3600)
        let priorLaunchedAt = isoFormatter.string(from: priorTimestamp)
        let priorStamp = filenameSafeISO(priorTimestamp)

        let priorBody: [String: Any] = [
            "version": "0.43.0",
            "build": "0.43.0.1",
            "commit": "abcdef12",
            "bundle_id": "com.stage11.c11",
            "launched_at": priorLaunchedAt,
            "pid": 12345,
        ]
        let data = try JSONSerialization.data(withJSONObject: priorBody, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sessionsDir.appendingPathComponent("unclean-exit-\(priorStamp).json"))

        let warning = metricKitBaselineWarning(
            home: tmp.path,
            bundleVersion: "0.44.1",
            metricKitCount: 0,
            now: now
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("0.43.0 to 0.44.1") == true)
    }

    func testMetricKitBaselineWarningSilentForOldVersionBump() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11/sessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldTimestamp = now.addingTimeInterval(-2 * 86400)
        let oldLaunchedAt = isoFormatter.string(from: oldTimestamp)
        let oldStamp = filenameSafeISO(oldTimestamp)

        let oldBody: [String: Any] = [
            "version": "0.43.0",
            "launched_at": oldLaunchedAt,
        ]
        let data = try JSONSerialization.data(withJSONObject: oldBody, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sessionsDir.appendingPathComponent("unclean-exit-\(oldStamp).json"))

        let warning = metricKitBaselineWarning(
            home: tmp.path,
            bundleVersion: "0.44.1",
            metricKitCount: 0,
            now: now
        )
        XCTAssertNil(warning, "version bumps older than 24h should not warn")
    }

    func testMetricKitBaselineWarningSilentWhenOnlyActiveJsonPresent() throws {
        // active.json is the *current* session; it must not be treated as a
        // prior-baseline marker. Without an unclean-exit archive, there is
        // no prior version to compare against, so the warning must stay silent
        // even after a version bump.
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11/sessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let activeBody: [String: Any] = [
            "version": "0.43.0",
            "launched_at": isoFormatter.string(from: now.addingTimeInterval(-60)),
        ]
        let data = try JSONSerialization.data(withJSONObject: activeBody, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sessionsDir.appendingPathComponent("active.json"))

        let warning = metricKitBaselineWarning(
            home: tmp.path,
            bundleVersion: "0.44.1",
            metricKitCount: 0,
            now: now
        )
        XCTAssertNil(warning, "active.json alone is the current session, not a prior baseline")
    }

    func testTelemetryAmbiguityFooterSilentWhenCacheMissing() {
        let result = telemetryAmbiguityFooter(home: "/nonexistent", sentryCount: 0)
        XCTAssertNil(result)
    }

    func testTelemetryAmbiguityFooterSilentWhenSentryCountNonzero() {
        XCTAssertNil(telemetryAmbiguityFooter(home: "/nonexistent", sentryCount: 1))
    }

    func testTelemetryAmbiguityFooterFiresWhenCacheExistsAndIsEmpty() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sentryDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11/io.sentry",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sentryDir, withIntermediateDirectories: true)

        let warning = telemetryAmbiguityFooter(home: tmp.path, sentryCount: 0)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("Sentry cache empty") == true)
    }

    func testTelemetryAmbiguityFooterSilentWhenCacheHasFile() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sentryDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11/io.sentry/envelopes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sentryDir, withIntermediateDirectories: true)
        try Data([0]).write(to: sentryDir.appendingPathComponent("queued"))

        // Note: sentryCount would be 1 in this scenario, so the early-return on
        // count would also silence the footer. We pass 0 here to specifically
        // exercise the disk check.
        let warning = telemetryAmbiguityFooter(home: tmp.path, sentryCount: 0)
        XCTAssertNil(warning, "non-empty cache must not produce the ambiguity footer")
    }

    func testTelemetryAmbiguityFooterFiresOnDebugBundleOnly() throws {
        // Regression: previously the footer hardcoded the production bundle
        // path and never fired on dev machines that only ran the debug build.
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let debugSentry = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11.debug.example/io.sentry",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: debugSentry, withIntermediateDirectories: true)

        let warning = telemetryAmbiguityFooter(home: tmp.path, sentryCount: 0)
        XCTAssertNotNil(warning, "an empty io.sentry under any c11* bundle must fire the footer")
    }

    func testTelemetryAmbiguityFooterSilentWhenAnyBundleHasEnvelope() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let emptyDebug = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11.debug.empty/io.sentry",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: emptyDebug, withIntermediateDirectories: true)
        let populated = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11.debug.populated/io.sentry/envelopes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: populated, withIntermediateDirectories: true)
        try Data([0]).write(to: populated.appendingPathComponent("env-1"))

        let warning = telemetryAmbiguityFooter(home: tmp.path, sentryCount: 0)
        XCTAssertNil(warning, "any bundle holding queued envelopes must silence the family-wide footer")
    }

    private func makeTempHome() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-flags-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func filenameSafeISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    // MARK: redactHomePath

    func testRedactHomePathReplacesPrefix() {
        let result = redactHomePath(
            "/Users/alice/Library/Caches/com.stage11.c11/io.sentry/envelopes/x",
            home: "/Users/alice"
        )
        XCTAssertEqual(result, "~/Library/Caches/com.stage11.c11/io.sentry/envelopes/x")
    }

    func testRedactHomePathHandlesTrailingSlashHome() {
        let result = redactHomePath("/Users/bob/Logs/x", home: "/Users/bob/")
        XCTAssertEqual(result, "~/Logs/x")
    }

    func testRedactHomePathLeavesUnrelatedPathUnchanged() {
        let result = redactHomePath("/var/db/something", home: "/Users/carol")
        XCTAssertEqual(result, "/var/db/something")
    }

    func testRedactHomePathDoesNotMatchPartialComponent() {
        // /Users/alice should not match /Users/alice2/...
        let result = redactHomePath("/Users/alice2/Logs", home: "/Users/alice")
        XCTAssertEqual(result, "/Users/alice2/Logs")
    }

    func testRedactHomePathExactMatch() {
        XCTAssertEqual(redactHomePath("/Users/dan", home: "/Users/dan"), "~")
    }
}
