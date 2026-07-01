import XCTest
import Foundation

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Guards the SUSparkleErrorDomain(4005) graceful-failure handling: a 4005
/// (the auto-updater downloaded an update but couldn't launch its installer —
/// e.g. a damaged Sparkle.framework) must route the user to a "download the
/// latest manually" path, NOT the misleading "move c11 into Applications" copy.
/// Genuine location errors (1003 disk-image / 1005 translocated) keep the
/// move-to-Applications guidance. Pure logic, lives in the c11LogicTests target.
/// See notes/sparkle-4005-investigation-2026-06-30.md.
final class UpdateInstallerFailureMappingTests: XCTestCase {
    // Matches SUSparkleErrorDomain ("SUSparkleErrorDomain") without importing Sparkle.
    private func sparkle(_ code: Int) -> NSError {
        NSError(domain: "SUSparkleErrorDomain", code: code)
    }

    func testInstallerLaunchFailureClassification() {
        XCTAssertTrue(UpdateViewModel.isInstallerLaunchFailure(sparkle(4005)))
        XCTAssertTrue(UpdateViewModel.isInstallerLaunchFailure(sparkle(1003)))
        XCTAssertTrue(UpdateViewModel.isInstallerLaunchFailure(sparkle(1005)))
        // Download/network/feed failures are retryable, not manual-download cases.
        XCTAssertFalse(UpdateViewModel.isInstallerLaunchFailure(sparkle(2001)))
        XCTAssertFalse(UpdateViewModel.isInstallerLaunchFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    func test4005DirectsToManualDownloadNotMoveToApplications() {
        let title = UpdateViewModel.userFacingErrorTitle(for: sparkle(4005))
        let message = UpdateViewModel.userFacingErrorMessage(for: sparkle(4005))
        // The old dead-end ("c11 needs to live in Applications" / "Move c11 into
        // Applications and relaunch") was wrong when the app is already installed.
        XCTAssertFalse(title.localizedCaseInsensitiveContains("needs to live"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("Move c11 into Applications"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("download"))
    }

    func testLocationErrorsStillSuggestMoving() {
        for code in [1003, 1005] {
            let message = UpdateViewModel.userFacingErrorMessage(for: sparkle(code))
            XCTAssertTrue(message.localizedCaseInsensitiveContains("Applications"),
                          "code \(code) should still mention Applications")
        }
    }

    func testReleasesPageURLIsValidHTTPS() {
        let url = URL(string: UpdateViewModel.releasesPageURLString)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "https")
    }
}
