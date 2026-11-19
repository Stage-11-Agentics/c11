import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// c11 does not copy cmux or c11 defaults on any bundle, including Release.
final class LegacyPrefsMigrationGateTests: XCTestCase {
    func testEveryBundleSkipsAndTheReaderIsNotCalled() {
        let bundles = [
            "com.stage11.c11",
            "com.stage11.c11",
            "com.stage11.c11.debug",
            "com.stage11.c11.debug",
            "com.stage11.c11.debug.tag1",
            "",
            "com.debugcorp.app",
            "com.stage11.c11.debugger",
        ]
        let environments: [[String: String]] = [
            [:],
            ["CMUX_DISABLE_LEGACY_MIGRATION": "1"],
            ["CMUX_DISABLE_LEGACY_MIGRATION": "0"],
            ["CMUX_DISABLE_LEGACY_MIGRATION": "true"],
        ]
        for bundle in bundles {
            for env in environments {
                XCTAssertTrue(
                    AppDelegate.legacyMigrationShouldSkip(bundleId: bundle, env: env),
                    "\(bundle) \(env)"
                )
            }
        }

        var reads = 0
        let imported = AppDelegate.importedLegacyPreferenceCount { _ in
            reads += 1
            return ["cmuxWelcomeShown": 1]
        }
        XCTAssertEqual(imported, 0)
        XCTAssertEqual(reads, 0)
    }
}
