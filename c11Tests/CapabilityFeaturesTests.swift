import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class CapabilityFeaturesTests: XCTestCase {
    func testCurrentAdvertisesBrowserProfilesAndFeedAsks() {
        let featureIDs = Set(CapabilityFeatures.current.payload.compactMap { $0["id"] as? String })
        XCTAssertTrue(featureIDs.contains(CapabilityFeatures.ID.browserProfiles.rawValue))
        XCTAssertTrue(featureIDs.contains(CapabilityFeatures.ID.feedAsks.rawValue))
    }

    func testDisabledAndMissingFeaturesNeverExecute() throws {
        let registry = CapabilityFeatures(entries: [
            .init(id: .terminalSelection, version: 3, enabled: false)
        ])
        var executions = 0
        for id in [CapabilityFeatures.ID.terminalSelection, .rawSend] {
            XCTAssertThrowsError(try registry.dispatch(id) { executions += 1 }) { error in
                XCTAssertEqual((error as? CapabilityFeatures.Unsupported)?.id, id)
            }
        }
        XCTAssertEqual(executions, 0)
        XCTAssertTrue(registry.payload.isEmpty)
    }

    func testEnablingEntryAdmitsBehaviorAndAdvertisesVersion() throws {
        let registry = CapabilityFeatures(entries: [
            .init(id: .offlineEvents, version: 7, enabled: true),
            .init(id: .rawSend, version: 1, enabled: false)
        ])
        let result = try registry.dispatch(.offlineEvents) { "fixture event" }
        XCTAssertEqual(result, "fixture event")
        XCTAssertEqual(registry.payload.count, 1)
        XCTAssertEqual(registry.payload.first?["id"] as? String, "events.offline")
        XCTAssertEqual(registry.payload.first?["version"] as? Int, 7)
    }
}
