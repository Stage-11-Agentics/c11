import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Host-free tests for the rail-tip trigger. Runs in `c11LogicTests`.
final class PanelRailTipPolicyTests: XCTestCase {

    private final class MemoryStore: PanelRailTipStoring {
        var stringsByKey: [String: [String]] = [:]
        var stringByKey: [String: String] = [:]
        var boolByKey: [String: Bool] = [:]
        private(set) var stringWrites = 0
        private(set) var boolWrites = 0

        func containsValue(forKey key: String) -> Bool {
            stringsByKey[key] != nil || stringByKey[key] != nil || boolByKey[key] != nil
        }
        func strings(forKey key: String) -> [String] { stringsByKey[key] ?? [] }
        func setStrings(_ values: [String], forKey key: String) {
            stringWrites += 1
            stringsByKey[key] = values
        }
        func string(forKey key: String) -> String? { stringByKey[key] }
        func setString(_ value: String?, forKey key: String) {
            stringWrites += 1
            if let value { stringByKey[key] = value } else { stringByKey.removeValue(forKey: key) }
        }
        func bool(forKey key: String) -> Bool { boolByKey[key] ?? false }
        func setBool(_ value: Bool, forKey key: String) {
            boolWrites += 1
            boolByKey[key] = value
        }
    }

    private func pacificCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func policy(_ store: MemoryStore, calendar: Calendar? = nil) -> PanelRailTipPolicy {
        PanelRailTipPolicy(calendar: calendar ?? pacificCalendar(), store: store)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, calendar: Calendar) -> Date {
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        return calendar.date(from: parts)!
    }

    private func seed(_ store: MemoryStore, _ days: [String]) {
        store.stringsByKey[PanelRailTipPolicy.overflowDaysKey] = days
    }

    // MARK: Recording

    func testOneOverflowMarkPerLocalDay() {
        let store = MemoryStore()
        let tip = policy(store)
        let now = day(2026, 9, 30, calendar: tip.calendar)
        XCTAssertTrue(tip.recordOverflow(now: now))
        XCTAssertEqual(store.stringWrites, 1)
        XCTAssertFalse(tip.recordOverflow(now: now.addingTimeInterval(60 * 60)))
        XCTAssertEqual(store.stringWrites, 1)
        XCTAssertEqual(store.stringsByKey[PanelRailTipPolicy.overflowDaysKey], ["2026-09-30"])
        XCTAssertTrue(tip.hasRecordedOverflow(on: now))
    }

    func testLocalCalendarIsGregorianInTheCurrentTimeZone() {
        let calendar = PanelRailTipPolicy.localCalendar()
        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.timeZone, TimeZone.current)
    }

    func testDayKeyUsesTheLocalCalendar() {
        let store = MemoryStore()
        let tip = policy(store)
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime]
        utc.timeZone = TimeZone(secondsFromGMT: 0)
        // 06:30 UTC is 23:30 the previous evening in Pacific daylight time.
        let instant = utc.date(from: "2026-09-30T06:30:00Z")!
        XCTAssertEqual(tip.dayKey(for: instant), "2026-09-29")
    }

    func testBlipUnderTwoSecondsDoesNotRecord() {
        let store = MemoryStore()
        let tip = policy(store)
        let since = day(2026, 9, 30, calendar: tip.calendar)
        XCTAssertFalse(PanelRailTipPolicy.sustained(since: since, now: since.addingTimeInterval(1.999), stillOverflowing: true))
        XCTAssertFalse(tip.recordSustainedOverflow(since: since, now: since.addingTimeInterval(1.999), stillOverflowing: true))
        XCTAssertFalse(tip.recordSustainedOverflow(since: since, now: since.addingTimeInterval(2), stillOverflowing: false))
        XCTAssertEqual(store.stringWrites, 0)
        XCTAssertFalse(tip.hasRecordedOverflow(on: since))
    }

    func testTwoSecondsOfOverflowRecordsOnce() {
        let store = MemoryStore()
        let tip = policy(store)
        let since = day(2026, 9, 30, calendar: tip.calendar)
        let now = since.addingTimeInterval(PanelRailTipPolicy.sustain)
        XCTAssertTrue(PanelRailTipPolicy.sustained(since: since, now: now, stillOverflowing: true))
        XCTAssertTrue(tip.recordSustainedOverflow(since: since, now: now, stillOverflowing: true))
        XCTAssertFalse(tip.recordSustainedOverflow(since: since, now: now.addingTimeInterval(5), stillOverflowing: true))
        XCTAssertEqual(store.stringWrites, 1)
        XCTAssertEqual(store.stringsByKey[PanelRailTipPolicy.overflowDaysKey], ["2026-09-30"])
    }

    func testStoredDaysTrimToTheNewestThirty() {
        let store = MemoryStore()
        let tip = policy(store)
        seed(store, (1...30).map { String(format: "2026-08-%02d", $0) })
        let now = day(2026, 8, 31, calendar: tip.calendar)
        XCTAssertTrue(tip.recordOverflow(now: now))
        let stored = store.stringsByKey[PanelRailTipPolicy.overflowDaysKey] ?? []
        XCTAssertEqual(stored.count, 30)
        XCTAssertFalse(stored.contains("2026-08-01"))
        XCTAssertTrue(stored.contains("2026-08-31"))
        XCTAssertTrue(stored.contains("2026-08-02"))
    }

    // MARK: Offering

    func testFourDaysInsideFourteenOffers() {
        let store = MemoryStore()
        let tip = policy(store)
        seed(store, ["2026-09-18", "2026-09-22", "2026-09-26", "2026-09-29"])
        let now = day(2026, 9, 30, calendar: tip.calendar)
        XCTAssertTrue(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
    }

    func testThreeDaysDoesNotOffer() {
        let store = MemoryStore()
        let tip = policy(store)
        seed(store, ["2026-09-18", "2026-09-22", "2026-09-26"])
        let now = day(2026, 9, 30, calendar: tip.calendar)
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
    }

    func testDayJustOutsideTheWindowDoesNotCount() {
        let store = MemoryStore()
        let tip = policy(store)
        let now = day(2026, 9, 30, calendar: tip.calendar)
        // 2026-09-17 is 13 days before the 30th, the first day inside the window.
        seed(store, ["2026-09-17", "2026-09-18", "2026-09-19", "2026-09-30"])
        XCTAssertTrue(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
        // 2026-09-16 is 14 days before, so only three days remain inside.
        seed(store, ["2026-09-16", "2026-09-18", "2026-09-19", "2026-09-30"])
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
    }

    func testOfferedYesterdayDoesNotOfferAgain() {
        let store = MemoryStore()
        let tip = policy(store)
        seed(store, ["2026-09-18", "2026-09-22", "2026-09-26", "2026-09-30"])
        tip.markOffered(now: day(2026, 9, 29, calendar: tip.calendar))
        XCTAssertFalse(tip.shouldOffer(now: day(2026, 9, 30, calendar: tip.calendar), layoutIsStrip: true, areaOverflowing: true))
    }

    func testOfferedThirtyCalendarDaysAgoCanOfferAgain() {
        let store = MemoryStore()
        let tip = policy(store)
        seed(store, ["2026-09-18", "2026-09-22", "2026-09-26", "2026-09-30"])
        tip.markOffered(now: day(2026, 8, 31, calendar: tip.calendar))
        XCTAssertTrue(tip.shouldOffer(now: day(2026, 9, 30, calendar: tip.calendar), layoutIsStrip: true, areaOverflowing: true))
        tip.markOffered(now: day(2026, 9, 1, calendar: tip.calendar))
        XCTAssertFalse(tip.shouldOffer(now: day(2026, 9, 30, calendar: tip.calendar), layoutIsStrip: true, areaOverflowing: true))
    }

    func testDismissBlocksForever() {
        let store = MemoryStore()
        let tip = policy(store)
        seed(store, ["2026-09-18", "2026-09-22", "2026-09-26", "2026-09-30"])
        let now = day(2026, 9, 30, calendar: tip.calendar)
        tip.dismiss()
        XCTAssertTrue(tip.isDismissed)
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
        XCTAssertFalse(tip.shouldOffer(now: day(2027, 9, 30, calendar: tip.calendar), layoutIsStrip: true, areaOverflowing: true))
    }

    func testRailLayoutHidesTheTipWithoutDismissingIt() {
        let store = MemoryStore()
        let tip = policy(store)
        seed(store, ["2026-09-18", "2026-09-22", "2026-09-26", "2026-09-30"])
        let now = day(2026, 9, 30, calendar: tip.calendar)
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: false, areaOverflowing: true))
        XCTAssertFalse(tip.isDismissed)
        XCTAssertEqual(store.boolWrites, 0)
    }

    func testQuietAreaDoesNotOffer() {
        let store = MemoryStore()
        let tip = policy(store)
        seed(store, ["2026-09-18", "2026-09-22", "2026-09-26", "2026-09-30"])
        XCTAssertFalse(tip.shouldOffer(now: day(2026, 9, 30, calendar: tip.calendar), layoutIsStrip: true, areaOverflowing: false))
    }

    func testForceOfferSkipsTheWaitAndClearsWhenShown() {
        let store = MemoryStore()
        let tip = policy(store)
        let now = day(2026, 9, 30, calendar: tip.calendar)
        store.boolByKey[PanelRailTipPolicy.forceOfferKey] = true
        XCTAssertTrue(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: false))
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: false, areaOverflowing: true))
        XCTAssertNil(store.stringsByKey[PanelRailTipPolicy.overflowDaysKey])

        // Showing the tip consumes the flag. A later force still skips a recent offer.
        tip.markOffered(now: day(2026, 9, 29, calendar: tip.calendar))
        XCTAssertEqual(store.boolByKey[PanelRailTipPolicy.forceOfferKey], false)
        XCTAssertEqual(store.boolWrites, 1)
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))

        store.boolByKey[PanelRailTipPolicy.forceOfferKey] = true
        XCTAssertTrue(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))

        tip.dismiss()
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
        XCTAssertTrue(tip.isForceOffer)

        store.boolByKey[PanelRailTipPolicy.dismissedKey] = false
        let writes = store.boolWrites
        tip.markOffered(now: now)
        XCTAssertFalse(tip.isForceOffer)
        XCTAssertEqual(store.boolWrites, writes + 1)
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
        tip.markOffered(now: now)
        XCTAssertEqual(store.boolWrites, writes + 1)
    }

    func testUndoLeavesTheTipEligibleAfterTheSpacingGap() {
        let store = MemoryStore()
        let tip = policy(store)
        let offeredOn = day(2026, 8, 31, calendar: tip.calendar)
        seed(store, ["2026-08-18", "2026-08-22", "2026-08-26", "2026-08-31"])
        XCTAssertTrue(tip.shouldOffer(now: offeredOn, layoutIsStrip: true, areaOverflowing: true))
        tip.markOffered(now: offeredOn)
        // Try Rail, then Undo: neither one dismisses, and Undo does not clear the stamp.
        XCTAssertFalse(tip.isDismissed)
        XCTAssertEqual(store.boolWrites, 0)
        XCTAssertEqual(store.stringByKey[PanelRailTipPolicy.lastOfferedKey], "2026-08-31")

        let nextDay = day(2026, 9, 1, calendar: tip.calendar)
        seed(store, ["2026-08-22", "2026-08-26", "2026-08-31", "2026-09-01"])
        XCTAssertFalse(tip.shouldOffer(now: nextDay, layoutIsStrip: true, areaOverflowing: true))

        let later = day(2026, 9, 30, calendar: tip.calendar)
        seed(store, ["2026-09-18", "2026-09-22", "2026-09-26", "2026-09-30"])
        XCTAssertTrue(tip.shouldOffer(now: later, layoutIsStrip: true, areaOverflowing: true))
        XCTAssertFalse(tip.isDismissed)
    }

    // MARK: Preview window and the layout write

    func testPreviewWindowKeepsTheSelectedRow() {
        XCTAssertEqual(PanelRailTipPreviewWindow.range(count: 8, selectedIndex: 0), 0..<4)
        XCTAssertEqual(PanelRailTipPreviewWindow.range(count: 8, selectedIndex: 2), 2..<6)
        XCTAssertEqual(PanelRailTipPreviewWindow.range(count: 8, selectedIndex: 7), 4..<8)
        XCTAssertEqual(PanelRailTipPreviewWindow.range(count: 2, selectedIndex: 1), 0..<2)
        XCTAssertEqual(PanelRailTipPreviewWindow.range(count: 0, selectedIndex: 0), 0..<0)
    }

    func testSetModeRoundTripUsesTheLayoutKey() {
        let suite = "c11.tabRailTip.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: defaults), .strip)
        PanelLayoutSettings.setMode(.rail, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: PanelLayoutSettings.modeKey), "rail")
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: defaults), .rail)
        PanelLayoutSettings.setMode(.strip, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: PanelLayoutSettings.modeKey), "strip")
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: defaults), .strip)
    }

    // MARK: Old `c11.tabRailTip.*` keys

    func testTipRecordLivesUnderThePanelKeys() {
        let suite = "c11.panelRailTip.keys.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tip = PanelRailTipPolicy(calendar: pacificCalendar(), store: UserDefaultsPanelRailTipStore(defaults: defaults))

        tip.dismiss()
        XCTAssertTrue(defaults.bool(forKey: "c11.panelRailTip.dismissed"))
        XCTAssertNil(defaults.object(forKey: "c11.tabRailTip.dismissed"))

        XCTAssertTrue(tip.recordOverflow(now: day(2026, 9, 30, calendar: tip.calendar)))
        XCTAssertEqual(defaults.stringArray(forKey: "c11.panelRailTip.overflowDays"), ["2026-09-30"])
        XCTAssertNil(defaults.object(forKey: "c11.tabRailTip.overflowDays"))
    }

    func testTipDismissedUnderTheOldKeyStaysDismissed() {
        let store = MemoryStore()
        store.boolByKey[PanelRailTipPolicy.legacyDismissedKey] = true
        let tip = policy(store)
        XCTAssertTrue(tip.isDismissed)
        seed(store, ["2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30"])
        let now = day(2026, 9, 30, calendar: tip.calendar)
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
        XCTAssertEqual(store.boolWrites, 0)
    }

    func testNewDismissedKeyShadowsTheOldOne() {
        let store = MemoryStore()
        store.boolByKey[PanelRailTipPolicy.legacyDismissedKey] = true
        store.boolByKey[PanelRailTipPolicy.dismissedKey] = false
        XCTAssertFalse(policy(store).isDismissed)
    }

    func testDismissWritesTheNewKeyOnly() {
        let store = MemoryStore()
        policy(store).dismiss()
        XCTAssertEqual(store.boolByKey[PanelRailTipPolicy.dismissedKey], true)
        XCTAssertNil(store.boolByKey[PanelRailTipPolicy.legacyDismissedKey])
    }

    func testOldForceOfferOffersOnceThenClearsForGood() {
        let store = MemoryStore()
        store.boolByKey[PanelRailTipPolicy.legacyForceOfferKey] = true
        let tip = policy(store)
        let now = day(2026, 9, 30, calendar: tip.calendar)
        XCTAssertTrue(tip.isForceOffer)
        XCTAssertTrue(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))
        tip.markOffered(now: now)
        XCTAssertFalse(tip.isForceOffer, "The old true must not fire the flag again")
        XCTAssertEqual(store.boolByKey[PanelRailTipPolicy.forceOfferKey], false)
        XCTAssertEqual(store.boolByKey[PanelRailTipPolicy.legacyForceOfferKey], true, "The old key is never deleted")
        XCTAssertFalse(tip.shouldOffer(now: now.addingTimeInterval(86_400), layoutIsStrip: true, areaOverflowing: true))
    }

    func testOldOverflowDaysAndLastOfferedCountUntilTheNewKeysExist() {
        let store = MemoryStore()
        store.stringsByKey[PanelRailTipPolicy.legacyOverflowDaysKey] = ["2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30"]
        let tip = policy(store)
        let now = day(2026, 9, 30, calendar: tip.calendar)
        XCTAssertTrue(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))

        store.stringByKey[PanelRailTipPolicy.legacyLastOfferedKey] = "2026-09-29"
        XCTAssertFalse(tip.shouldOffer(now: now, layoutIsStrip: true, areaOverflowing: true))

        // Recording a new day carries the old days into the new key.
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertTrue(tip.recordOverflow(now: tomorrow))
        XCTAssertEqual(store.stringsByKey[PanelRailTipPolicy.overflowDaysKey],
                       ["2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01"])
        XCTAssertEqual(store.stringsByKey[PanelRailTipPolicy.legacyOverflowDaysKey]?.count, 4)
    }

    func testOldKeysThroughTheUserDefaultsStore() {
        let suite = "c11.tabRailTip.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PanelRailTipPolicy.legacyDismissedKey)
        defaults.set(true, forKey: PanelRailTipPolicy.legacyForceOfferKey)
        let tip = PanelRailTipPolicy(calendar: pacificCalendar(), store: UserDefaultsPanelRailTipStore(defaults: defaults))
        XCTAssertTrue(tip.isDismissed)
        XCTAssertTrue(tip.isForceOffer)

        tip.clearForceOffer()
        XCTAssertFalse(tip.isForceOffer)
        XCTAssertEqual(defaults.object(forKey: PanelRailTipPolicy.forceOfferKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: PanelRailTipPolicy.legacyForceOfferKey) as? Bool, true)
        XCTAssertTrue(tip.isDismissed, "Clearing the flag leaves the dismissal alone")
    }
}
