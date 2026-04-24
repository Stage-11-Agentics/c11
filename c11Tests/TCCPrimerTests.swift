import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class TCCPrimerTests: XCTestCase {

    // MARK: - shouldPresent()

    func testShouldPresentReturnsTrueWhenShownKeyUnset() {
        let defaults = UserDefaults(suiteName: "TCCPrimerTests.\(UUID().uuidString)")!
        defaults.removeObject(forKey: TCCPrimer.shownKey)
        XCTAssertTrue(TCCPrimer.shouldPresent(defaults: defaults))
    }

    func testShouldPresentReturnsFalseWhenShownKeyTrue() {
        let defaults = UserDefaults(suiteName: "TCCPrimerTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: TCCPrimer.shownKey)
        XCTAssertFalse(TCCPrimer.shouldPresent(defaults: defaults))
    }

    // MARK: - migrateExistingUserIfNeeded()

    func testMigrationMarksShownWhenWelcomeAlreadySeen() {
        let defaults = UserDefaults(suiteName: "TCCPrimerTests.\(UUID().uuidString)")!
        defaults.removeObject(forKey: TCCPrimer.shownKey)
        defaults.set(true, forKey: WelcomeSettings.shownKey)
        TCCPrimer.migrateExistingUserIfNeeded(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: TCCPrimer.shownKey))
    }

    func testMigrationLeavesShownUnsetForFreshInstall() {
        let defaults = UserDefaults(suiteName: "TCCPrimerTests.\(UUID().uuidString)")!
        defaults.removeObject(forKey: TCCPrimer.shownKey)
        defaults.removeObject(forKey: WelcomeSettings.shownKey)
        TCCPrimer.migrateExistingUserIfNeeded(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: TCCPrimer.shownKey))
    }

    func testMigrationIsIdempotentOncePrimerExplicitlyShown() {
        // A user who already saw (or dismissed) the primer should not get
        // their setting flipped by a subsequent migration pass.
        let defaults = UserDefaults(suiteName: "TCCPrimerTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: TCCPrimer.shownKey)
        defaults.set(true, forKey: WelcomeSettings.shownKey)
        TCCPrimer.migrateExistingUserIfNeeded(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: TCCPrimer.shownKey))
    }

    func testMigrationDoesNotReopenAfterExplicitDeclineByUser() {
        // Explicit false (hypothetical "I don't want to be asked" preset)
        // must survive migration. Migration runs only when the key is truly
        // unset, per the `object(forKey:) == nil` guard.
        let defaults = UserDefaults(suiteName: "TCCPrimerTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: TCCPrimer.shownKey)
        defaults.set(true, forKey: WelcomeSettings.shownKey)
        TCCPrimer.migrateExistingUserIfNeeded(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: TCCPrimer.shownKey))
    }
}
