import Foundation

/// Read and write the three tip keys. The app uses `UserDefaults`; tests use
/// an in-memory store. Nothing here touches the network, logs, or the socket.
protocol TabRailTipStoring: AnyObject {
    func strings(forKey key: String) -> [String]
    func setStrings(_ values: [String], forKey key: String)
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
    func bool(forKey key: String) -> Bool
    func setBool(_ value: Bool, forKey key: String)
}

/// The app's tip record, in the same defaults domain as `tabLayoutMode`.
final class UserDefaultsTabRailTipStore: TabRailTipStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func strings(forKey key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func setStrings(_ values: [String], forKey key: String) {
        defaults.set(values, forKey: key)
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func setString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Which tabs the tip's miniature rail draws. The selected row stays inside
/// the window, matching the prototype: a slice of at most `limit` rows.
enum TabRailTipPreviewWindow {
    static func range(count: Int, selectedIndex: Int, limit: Int = 4) -> Range<Int> {
        let capped = min(max(limit, 0), count)
        guard capped > 0 else { return 0..<0 }
        let index = min(max(selectedIndex, 0), count - 1)
        let from = min(index, count - capped)
        return from..<(from + capped)
    }
}

/// When to record an overflow day and when a new tip may start.
///
/// An overflow day is one local calendar day. The tip may start when 4 of
/// those days fall in the last 14, Tab Layout is still Tabs, the area in
/// front is overflowing, the tip has not been dismissed, and at least 30
/// calendar days have passed since it was last shown.
///
/// `dismissed` is set only by Don't show again. Try Rail, Undo, and a
/// Settings change to Rail do not set it. Rail hides the tip while that
/// layout is on (`layoutIsTabs` is false). Undo does not clear
/// `lastOffered`, so the tip waits out the 30-day gap and can return under
/// this same rule. The host keeps its own "this offer is on screen" flag:
/// `shouldOffer` means a new offer may start, and it becomes false as soon
/// as the tip is stamped.
///
/// `forceOffer` skips the 4-day count and the 30-day gap for one showing.
/// It does not skip dismissal, Tabs layout, or a quiet area. Stamping the
/// offer clears it.
struct TabRailTipPolicy {
    static let overflowDaysKey = "c11.tabRailTip.overflowDays"
    static let lastOfferedKey = "c11.tabRailTip.lastOffered"
    static let dismissedKey = "c11.tabRailTip.dismissed"
    /// One-shot. The next qualifying area offers the tip, then this clears.
    static let forceOfferKey = "c11.tabRailTip.forceOffer"
    static let overflowWindowDays = 14
    static let overflowDaysRequired = 4
    static let offerSpacingDays = 30
    static let maxStoredDays = 30
    /// A resize blip shorter than this does not count as an overflow day.
    static let sustain: TimeInterval = 2

    /// Gregorian, in a chosen time zone. The app uses `localCalendar()` and
    /// refreshes it when the day or zone changes. Tests pass their own.
    var calendar: Calendar
    let store: TabRailTipStoring

    /// Gregorian calendar in the current time zone. Day keys must not follow
    /// `Calendar.current`, whose identifier can be something other than Gregorian.
    static func localCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// True when the overflow is still going and has lasted at least `sustain`.
    static func sustained(since: Date, now: Date, stillOverflowing: Bool) -> Bool {
        stillOverflowing && now.timeIntervalSince(since) >= sustain
    }

    /// Local calendar day, `yyyy-MM-dd`, from the calendar's components.
    /// Not an ISO-8601 instant: a date just after UTC midnight can still be
    /// the previous local day.
    func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func hasRecordedOverflow(on now: Date) -> Bool {
        storedDayKeys().contains(dayKey(for: now))
    }

    /// Records `now`'s local day. Returns false, and does not write, when
    /// that day is already stored. Keeps the newest `maxStoredDays` keys.
    @discardableResult
    func recordOverflow(now: Date) -> Bool {
        let key = dayKey(for: now)
        var days = storedDayKeys()
        guard !days.contains(key) else { return false }
        days.append(key)
        days.sort()
        if days.count > Self.maxStoredDays {
            days = Array(days.suffix(Self.maxStoredDays))
        }
        store.setStrings(days, forKey: Self.overflowDaysKey)
        return true
    }

    /// Records today only when `sustained` is true. A cleared overflow, or
    /// one younger than `sustain`, does not write.
    @discardableResult
    func recordSustainedOverflow(since: Date, now: Date, stillOverflowing: Bool) -> Bool {
        guard Self.sustained(since: since, now: now, stillOverflowing: stillOverflowing) else {
            return false
        }
        return recordOverflow(now: now)
    }

    func shouldOffer(now: Date, layoutIsTabs: Bool, areaOverflowing: Bool) -> Bool {
        guard layoutIsTabs, areaOverflowing, !isDismissed else { return false }
        if isForceOffer { return true }
        guard spacingAllowsOffer(now: now) else { return false }
        return overflowCount(inWindowEndingAt: now) >= Self.overflowDaysRequired
    }

    func markOffered(now: Date) {
        store.setString(dayKey(for: now), forKey: Self.lastOfferedKey)
        clearForceOffer()
    }

    /// Drops the one-shot flag. No write when it is already clear.
    func clearForceOffer() {
        guard isForceOffer else { return }
        store.setBool(false, forKey: Self.forceOfferKey)
    }

    var isForceOffer: Bool {
        store.bool(forKey: Self.forceOfferKey)
    }

    func dismiss() {
        store.setBool(true, forKey: Self.dismissedKey)
    }

    var isDismissed: Bool {
        store.bool(forKey: Self.dismissedKey)
    }

    private func spacingAllowsOffer(now: Date) -> Bool {
        guard let raw = store.string(forKey: Self.lastOfferedKey),
              let offered = date(fromDayKey: raw) else {
            return true
        }
        let from = calendar.startOfDay(for: offered)
        let to = calendar.startOfDay(for: now)
        let gap = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return gap >= Self.offerSpacingDays
    }

    /// Today and the 13 days before it. A day 14 calendar days ago is outside.
    private func overflowCount(inWindowEndingAt now: Date) -> Int {
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(Self.overflowWindowDays - 1), to: end) else {
            return 0
        }
        return storedDayKeys().reduce(into: 0) { count, key in
            guard let day = date(fromDayKey: key) else { return }
            let startOfDay = calendar.startOfDay(for: day)
            if startOfDay >= start && startOfDay <= end {
                count += 1
            }
        }
    }

    private func storedDayKeys() -> [String] {
        store.strings(forKey: Self.overflowDaysKey).filter { date(fromDayKey: $0) != nil }
    }

    private func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }
}
