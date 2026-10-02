import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class JournalExportTests: XCTestCase {
    func testExportIsStableOrderedAndBodyFree() throws {
        let events = JournalAnalyticsFixture.lifecycleEvents()
        let filters = JournalQueryFilters(fromMs: 0, toMs: 9_000)
        let coverage = JournalAnalyticsFixture.coverage(highWater: 7)
        let first = try JournalExport.encode(events: events, baselines: [], coverage: coverage, filters: filters)
        let second = try JournalExport.encode(events: events, baselines: [], coverage: coverage, filters: filters)
        XCTAssertEqual(first, second)

        let lines = String(decoding: first, as: UTF8.self).split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 1)
        let objects = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.first?["record_type"] as? String, "manifest")
        let sequences = objects.compactMap { ($0["sequence"] as? NSNumber)?.int64Value }
        XCTAssertEqual(sequences, sequences.sorted())
        for object in objects {
            XCTAssertNil(object["prompt"])
            XCTAssertNil(object["body"])
            XCTAssertNil(object["cwd"])
        }
    }

    func testExportReportsRetentionGapsAndOmitsNewerBaselineAtCutoff() throws {
        let event = JournalAnalyticsFixture.lifecycleEvents()[2]
        var baseline = JournalSnapshot(owner: JournalOwner(tabID: JournalAnalyticsFixture.tab,
                                                            agentKind: "claude-code", sessionID: "analytics-session"),
                                       workspaceID: JournalAnalyticsFixture.workspace,
                                       appInstanceID: JournalAnalyticsFixture.app)
        baseline.lastSequence = 99
        let coverage = JournalAnalyticsFixture.coverage(highWater: 5, first: 3)
        let data = try JournalExport.encode(events: [event], baselines: [baseline], coverage: coverage,
                                            filters: JournalQueryFilters(fromMs: 0, toMs: 9_000))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let objects = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let manifest = try XCTUnwrap(objects.first)
        let manifestCoverage = try XCTUnwrap(manifest["coverage"] as? [String: Any])
        XCTAssertEqual(manifestCoverage["baseline_unavailable_at_cutoff"] as? Bool, true)
        XCTAssertEqual(manifestCoverage["incomplete"] as? Bool, true)
        XCTAssertTrue(objects.contains { $0["reason"] as? String == "retention" })
        XCTAssertTrue(objects.contains { $0["reason"] as? String == "baseline_unavailable_at_cutoff" })
        XCTAssertFalse(objects.contains { $0["record_type"] as? String == "current_state" })
        XCTAssertTrue(objects.contains { ($0["sequence"] as? NSNumber)?.int64Value == event.sequence })
    }

    func testExportAllowlistRetainsEventDimensionsAndNoGeneratedTimestamp() throws {
        let event = JournalAnalyticsFixture.lifecycleEvents()[3]
        let data = try JournalExport.encode(
            events: [event], baselines: [], coverage: JournalAnalyticsFixture.coverage(highWater: event.sequence),
            filters: JournalQueryFilters(fromMs: 0, toMs: 9_000))
        let object = try XCTUnwrap(String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().first)
        let eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any])
        XCTAssertEqual(eventObject["record_type"] as? String, "event")
        XCTAssertEqual(eventObject["kind"] as? String, JournalKind.stateChanged.rawValue)
        XCTAssertEqual(eventObject["signal"] as? String, JournalSignal.operatorResponse.rawValue)
        XCTAssertNotNil(eventObject["observed_tick_ns"])
        XCTAssertNotNil(eventObject["app_instance_id"])
        XCTAssertNil(eventObject["generated_at"])
        XCTAssertNil(eventObject["prompt"])
    }
}
