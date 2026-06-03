import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HealthSentryParserTests: XCTestCase {

    func testFindsTwoEnvelopesUnderPerBundleDir() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let envelopesDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11.debug.foo/io.sentry/envelopes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: envelopesDir, withIntermediateDirectories: true)
        try Data([0]).write(to: envelopesDir.appendingPathComponent("envelope-empty"))
        try Data(repeating: 0xAB, count: 64).write(to: envelopesDir.appendingPathComponent("envelope-small"))

        let events = scanSentryQueued(home: tmp.path, since: Date.distantPast)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.rail == .sentry })
        XCTAssertTrue(events.allSatisfy { $0.severity == .queued })
        XCTAssertTrue(events.allSatisfy { $0.summary.hasPrefix("com.stage11.c11.debug.foo/") })
    }

    func testIncludesLegacyC11muxBundles() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let legacy = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11mux/io.sentry/envelopes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([0]).write(to: legacy.appendingPathComponent("legacy-envelope"))

        let events = scanSentryQueued(home: tmp.path, since: Date.distantPast)
        XCTAssertEqual(events.count, 1, "legacy c11mux bundles must remain in scope for v1")
        XCTAssertEqual(events.first?.summary, "com.stage11.c11mux/legacy-envelope")
    }

    func testSkipsBundlesWithoutIoSentryDir() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11.no-sentry-dir",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let events = scanSentryQueued(home: tmp.path, since: Date.distantPast)
        XCTAssertTrue(events.isEmpty)
    }

    func testIgnoresNonC11Bundles() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let unrelated = tmp.appendingPathComponent(
            "Library/Caches/com.example.other/io.sentry/envelopes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data([0]).write(to: unrelated.appendingPathComponent("envelope"))

        let events = scanSentryQueued(home: tmp.path, since: Date.distantPast)
        XCTAssertTrue(events.isEmpty)
    }

    func testRespectsSinceWindow() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let envelopesDir = tmp.appendingPathComponent(
            "Library/Caches/com.stage11.c11/io.sentry/envelopes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: envelopesDir, withIntermediateDirectories: true)
        let target = envelopesDir.appendingPathComponent("old-envelope")
        try Data([0]).write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: target.path
        )

        XCTAssertTrue(scanSentryQueued(home: tmp.path, since: Date(timeIntervalSinceNow: -60)).isEmpty)
        XCTAssertEqual(scanSentryQueued(home: tmp.path, since: Date(timeIntervalSinceNow: -7200)).count, 1)
    }

    func testGracefulOnMissingCachesDir() {
        let events = scanSentryQueued(home: "/nonexistent/path-1234", since: Date.distantPast)
        XCTAssertTrue(events.isEmpty)
    }

    private func makeTempHome() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-health-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
