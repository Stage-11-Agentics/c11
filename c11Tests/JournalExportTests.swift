import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class JournalExportTests: XCTestCase {
    private func render(events: [JournalEvent], baselines: [JournalSnapshot],
                        coverage: JournalQueryCoverage, filters: JournalQueryFilters) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().appendingPathComponent("journal-export-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.ndjson")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        let writer = try JournalExport.StreamWriter(handle: handle, coverage: coverage, filters: filters)
        let ordered = events.sorted { $0.sequence < $1.sequence }
        for start in stride(from: 0, to: ordered.count, by: 2) {
            try writer.consume(Array(ordered[start..<min(start + 2, ordered.count)]))
        }
        try writer.finish(baselines: baselines)
        try handle.close()
        return try Data(contentsOf: url)
    }

    func testExportIsStableOrderedAndBodyFree() throws {
        let events = JournalAnalyticsFixture.lifecycleEvents()
        let filters = JournalQueryFilters(fromMs: 0, toMs: 9_000)
        let coverage = JournalAnalyticsFixture.coverage(highWater: 7)
        let first = try render(events: events, baselines: [], coverage: coverage, filters: filters)
        let second = try render(events: events, baselines: [], coverage: coverage, filters: filters)
        XCTAssertEqual(first, second)

        let lines = String(decoding: first, as: UTF8.self).split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 1)
        let objects = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.first?["record_type"] as? String, "manifest")
        XCTAssertEqual(objects.last?["record_type"] as? String, "coverage_summary")
        XCTAssertEqual(objects.last?["incomplete"] as? Bool, false)
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
        var baseline = JournalSnapshot(owner: JournalOwner(panelID: JournalAnalyticsFixture.panel,
                                                            agentKind: "claude-code", sessionID: "analytics-session"),
                                       workspaceID: JournalAnalyticsFixture.workspace,
                                       appInstanceID: JournalAnalyticsFixture.app)
        baseline.lastSequence = 99
        let coverage = JournalAnalyticsFixture.coverage(highWater: 5, first: 3)
        let data = try render(events: [event], baselines: [baseline], coverage: coverage,
                              filters: JournalQueryFilters(fromMs: 0, toMs: 9_000))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let objects = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let manifest = try XCTUnwrap(objects.first)
        let manifestCoverage = try XCTUnwrap(manifest["coverage"] as? [String: Any])
        XCTAssertEqual(manifestCoverage["incomplete"] as? Bool, true)
        XCTAssertTrue(objects.contains { $0["reason"] as? String == "retention" })
        XCTAssertTrue(objects.contains { $0["reason"] as? String == "baseline_unavailable_at_cutoff" })
        XCTAssertEqual(objects.last?["incomplete"] as? Bool, true)
        XCTAssertFalse(objects.contains { $0["record_type"] as? String == "current_state" })
        XCTAssertTrue(objects.contains { ($0["sequence"] as? NSNumber)?.int64Value == event.sequence })
    }

    func testExportAllowlistRetainsEventDimensionsAndNoGeneratedTimestamp() throws {
        let event = JournalAnalyticsFixture.lifecycleEvents()[3]
        let data = try render(
            events: [event], baselines: [], coverage: JournalAnalyticsFixture.coverage(highWater: event.sequence),
            filters: JournalQueryFilters(fromMs: 0, toMs: 9_000))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let eventLine = try XCTUnwrap(lines.first { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return false
            }
            return object["record_type"] as? String == "event"
        })
        let eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(eventLine.utf8)) as? [String: Any])
        XCTAssertEqual(eventObject["record_type"] as? String, "event")
        XCTAssertEqual(eventObject["kind"] as? String, JournalKind.stateChanged.rawValue)
        XCTAssertEqual(eventObject["signal"] as? String, JournalSignal.operatorResponse.rawValue)
        XCTAssertNotNil(eventObject["observed_tick_ns"])
        XCTAssertNotNil(eventObject["app_instance_id"])
        XCTAssertNil(eventObject["generated_at"])
        XCTAssertNil(eventObject["prompt"])
    }

    // C11-337: export records carry the panel spelling beside the legacy tab spelling.
    func testExportEventAndCurrentStateEmitPanelIdBesideTabId() throws {
        let event = JournalAnalyticsFixture.lifecycleEvents()[3]
        var baseline = JournalSnapshot(owner: JournalOwner(panelID: JournalAnalyticsFixture.panel,
                                                            agentKind: "claude-code", sessionID: "analytics-session"),
                                       workspaceID: JournalAnalyticsFixture.workspace,
                                       appInstanceID: JournalAnalyticsFixture.app)
        baseline.lastSequence = event.sequence
        let data = try render(
            events: [event], baselines: [baseline],
            coverage: JournalAnalyticsFixture.coverage(highWater: event.sequence),
            filters: JournalQueryFilters(fromMs: 0, toMs: 9_000))
        let objects = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        for recordType in ["event", "current_state"] {
            let record = try XCTUnwrap(objects.first { $0["record_type"] as? String == recordType }, recordType)
            XCTAssertEqual(record["panel_id"] as? String, JournalAnalyticsFixture.panel.uuidString, recordType)
            XCTAssertEqual(record["tab_id"] as? String, JournalAnalyticsFixture.panel.uuidString, recordType)
            XCTAssertNil(record["surface_id"], recordType)
        }
    }

    func testEmptyInitialPageStillEmitsTheFrozenHighWaterTailGap() throws {
        let coverage = JournalQueryCoverage(retainedFromMs: 5_000, firstAvailableSequence: 4,
                                            highWaterSequence: 7, incomplete: false,
                                            uncertainCount: 0, censoredCount: 0, sources: [:],
                                            lastObservationMs: 5_000)
        let data = try render(events: [], baselines: [], coverage: coverage,
                              filters: JournalQueryFilters(fromMs: 5_000, toMs: 5_000))
        let objects = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertTrue(objects.contains {
            $0["reason"] as? String == "unavailable_after_snapshot"
                && ($0["from_sequence"] as? NSNumber)?.int64Value == 4
                && ($0["to_sequence"] as? NSNumber)?.int64Value == 7
                && $0["incomplete"] as? Bool == true
        })
        XCTAssertEqual(objects.last?["record_type"] as? String, "coverage_summary")
        XCTAssertEqual(objects.last?["incomplete"] as? Bool, true)
    }

    func testPagedExportReportsRowsClearedAfterFrozenHighWater() throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().appendingPathComponent("journal-export-clear-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now: Int64 = 1_000
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory),
                                     instanceID: JournalAnalyticsFixture.app,
                                     clock: { now }, tickClock: { UInt64(now) * 1_000_000 })
        for _ in 0..<3 {
            now += 1_000
            var draft = JournalTestData.draft(.stateChanged, at: now)
            draft.eventID = UUID()
            _ = try store.append(draft: draft, context: JournalContext(eligible: true))
        }
        let frozen = try store.coverage()
        let baselines = try store.baselines()
        let coverage = JournalQueryCoverage(retainedFromMs: 2_000, firstAvailableSequence: frozen.first,
                                            highWaterSequence: frozen.highWater, incomplete: false,
                                            uncertainCount: 0, censoredCount: 0, sources: [:],
                                            lastObservationMs: frozen.lastObservation)
        let filters = JournalQueryFilters(fromMs: 0, toMs: 10_000)
        let output = directory.appendingPathComponent("race.ndjson")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        let writer = try JournalExport.StreamWriter(handle: handle, coverage: coverage, filters: filters)
        let firstPage = try store.readPage(after: frozen.first - 1, through: frozen.highWater, limit: 1)
        XCTAssertEqual(firstPage.count, 1)
        try writer.consume(firstPage)

        try store.clear()
        let secondPage = try store.readPage(after: firstPage[0].sequence,
                                            through: frozen.highWater, limit: 1)
        XCTAssertTrue(secondPage.isEmpty)
        try writer.finish(baselines: baselines)
        try handle.close()

        let objects = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertTrue(objects.contains {
            $0["reason"] as? String == "unavailable_after_snapshot"
                && ($0["from_sequence"] as? NSNumber)?.int64Value == 2
                && ($0["to_sequence"] as? NSNumber)?.int64Value == frozen.highWater
        })
        XCTAssertEqual(objects.last?["incomplete"] as? Bool, true)
    }
}
