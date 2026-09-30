import Foundation

// Per-tab signals behind the tab sheet's clocks (agent signals work).
//
// `active` means "how long since something was added to this tab", per type:
//   agent tab       last assistant message or tool result (`AgentModelDetection`)
//   plain terminal  max(scrollback grew while visible, last command start/finish)
//   markdown        last content change (file mtime at load)
//   browser         last page load
// Operator input is deliberately NOT part of `active`; it is its own clock,
// `touched`. Everything here is a plain `Date` store on a main-thread path: no
// publishing, no persistence, nothing that can touch typing latency.

/// Decides when a terminal's scrollback growth is real output.
///
/// Ghostty pushes `GHOSTTY_ACTION_SCROLLBAR {total, offset, len}` only when the
/// value changes, so in-place repaints (spinners, status lines) never arrive.
/// History rows are `total - len`; growth in history is output that scrolled.
/// Caveats handled here:
/// - a hidden surface emits nothing, and reveal or a resize brings one catch-up
///   or reflow event immediately: events inside a short settle window after a
///   visibility or size change re-baseline instead of stamping (later events,
///   including the first real output after a reveal, count);
/// - decreases (scrollback cap pruning, `clear`) only move the baseline down;
/// - leaving an alt-screen app restores the whole primary history at once
///   (history jumps from 0 to a screenful or more). Ghostty exposes no alt-screen
///   signal, so a jump from empty history larger than one screen re-baselines;
///   the cost is that a single first output bigger than a screen on a brand-new
///   terminal is not stamped, and the next event is.
struct ScrollbackGrowthTracker: Equatable {
    /// How long after a visibility or size change events are treated as
    /// catch-up or reflow rather than live output.
    static let settleWindow: TimeInterval = 0.5

    private var baseline: UInt64?
    private var settleUntil: Date = .distantPast

    /// The surface became visible or hidden.
    mutating func noteVisibilityChanged(at now: Date = Date()) {
        settleUntil = now.addingTimeInterval(Self.settleWindow)
    }
    /// The pixel size changed: reflow follows.
    mutating func noteResized(at now: Date = Date()) {
        settleUntil = now.addingTimeInterval(Self.settleWindow)
    }

    /// Feed one scrollbar event. Returns true when it is real output growth.
    mutating func observe(total: UInt64, len: UInt64, at now: Date = Date()) -> Bool {
        let history = total > len ? total - len : 0
        let previous = baseline
        baseline = history
        guard let previous else { return false }
        if now < settleUntil { return false }
        if previous == 0, history > len { return false }
        return history > previous
    }
}

/// Text for the sheet's non-date clocks.
enum TabSheetClockText {
    /// The app's language, not the region (like the sheet's own ages): a Russian
    /// UI on a US-region Mac reads Russian units.
    static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// `4m 12s`, `1h 5m`: localized abbreviated units, two at most.
    static func duration(_ seconds: TimeInterval, locale: Locale = appLocale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(0, seconds.rounded(.down))) ?? "0s"
    }

    /// `48K`, `1.2M`: compact and locale aware; small counts stay exact.
    static func count(_ value: Int, locale: Locale = appLocale) -> String {
        if value < 1_000 { return String(value) }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }
}
