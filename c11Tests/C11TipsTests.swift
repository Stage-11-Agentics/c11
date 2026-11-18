import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-127 part 2: when a contextual tip may show, and which restored
/// terminals count as having kept running.
final class C11TipsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "C11TipsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testEachTipShowsOnceAndNeverUnderQA() {
        let defaults = defaults()
        XCTAssertTrue(C11TipPolicy.mayOffer(.keptRunning, qa: .off, shown: C11TipPolicy.shown(defaults: defaults)))
        XCTAssertFalse(C11TipPolicy.mayOffer(.keptRunning, qa: .on(.fresh), shown: []))
        XCTAssertFalse(C11TipPolicy.mayOffer(.endSession, qa: .on(.resume), shown: []))
        C11TipPolicy.markShown(.keptRunning, defaults: defaults)
        C11TipPolicy.markShown(.keptRunning, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: C11TipPolicy.shownKey), ["keptRunning"])
        let shown = C11TipPolicy.shown(defaults: defaults)
        XCTAssertFalse(C11TipPolicy.mayOffer(.keptRunning, qa: .off, shown: shown))
        XCTAssertTrue(C11TipPolicy.mayOffer(.remoteLabel, qa: .off, shown: shown), "tips are independent")
    }

    func testUnknownStoredNamesAreIgnored() {
        let defaults = defaults()
        defaults.set(["somethingElse", "endSession"], forKey: C11TipPolicy.shownKey)
        XCTAssertEqual(C11TipPolicy.shown(defaults: defaults), [.endSession])
    }

    func testSurvivorsAreRestoredTerminalsStillLiveWithTheirSavedKey() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let restored: [UUID: HCTerminalKey] = [a: HCTerminalKey(owningCoreID: "core", localAddress: "t1"), b: HCTerminalKey(owningCoreID: "core", localAddress: "t2"),
                                               c: HCTerminalKey(owningCoreID: "core", localAddress: "t3"), d: HCTerminalKey(owningCoreID: "core", localAddress: "studio/t4")]
        let live: [UUID: HCTerminalKey] = [a: HCTerminalKey(owningCoreID: "core", localAddress: "t1"),        // kept running
                                           b: HCTerminalKey(owningCoreID: "core", localAddress: "t9"),        // ended, recreated with a new key
                                           d: HCTerminalKey(owningCoreID: "core", localAddress: "studio/t4")]  // kept running on another machine
        XCTAssertEqual(C11TipPolicy.survivors(restored: restored) { live[$0] }, 2)
        XCTAssertEqual(C11TipPolicy.survivors(restored: [:]) { live[$0] }, 0)
    }

    func testKeptRunningCopyNamesTheCount() {
        // Locale-independent: the count and the machine name reach the text,
        // and one terminal reads differently from several.
        let one = C11TipPolicy.copy(.keptRunning, count: 1).title
        let five = C11TipPolicy.copy(.keptRunning, count: 5).title
        XCTAssertTrue(five.contains("5"))
        XCTAssertNotEqual(one, five)
        XCTAssertTrue(C11TipPolicy.copy(.remoteLabel, machine: "Studio").title.contains("Studio"))
    }

    @MainActor
    func testTipsWaitWhileBlockedAndAreAskedForOnce() {
        let defaults = defaults()
        let center = C11TipCenter(defaults: defaults, qa: { .off })
        var blocked = true
        center.isBlocked = { blocked }
        // Blocked (the What's different decision is pending): kept, unrecorded.
        center.offer(.endSession) { nil }
        center.offer(.endSession) { nil }
        XCTAssertEqual(center.pendingTips, [.endSession], "one request per tip")
        XCTAssertTrue(C11TipPolicy.shown(defaults: defaults).isEmpty)
        // Unblocked with no anchor on screen yet: kept for a retry, unrecorded.
        blocked = false
        center.resume()
        XCTAssertEqual(center.pendingTips, [.endSession])
        XCTAssertTrue(C11TipPolicy.shown(defaults: defaults).isEmpty)
    }

    @MainActor
    func testAShownTipIsNeverOfferedAgainAndQAOffersNothing() {
        let defaults = defaults()
        C11TipPolicy.markShown(.remoteLabel, defaults: defaults)
        let center = C11TipCenter(defaults: defaults, qa: { .off })
        center.isBlocked = { true }
        center.offer(.remoteLabel, machine: "Studio") { nil }
        XCTAssertEqual(center.pendingTips, [])
        let qaCenter = C11TipCenter(defaults: self.defaults(), qa: { .on(.fresh) })
        qaCenter.isBlocked = { true }
        qaCenter.offer(.keptRunning, count: 3) { nil }
        XCTAssertEqual(qaCenter.pendingTips, [])
    }
}
