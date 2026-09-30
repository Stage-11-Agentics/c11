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
/// - a hidden surface emits nothing, and the first event after visibility
///   returns is a catch-up delta: it re-baselines instead of stamping;
/// - resize and reflow move the count: the first event after a size change
///   re-baselines;
/// - decreases (scrollback cap pruning, `clear`) only move the baseline down;
/// - an alt-screen TUI never grows scrollback, so it reads as no output.
struct ScrollbackGrowthTracker: Equatable {
    private var baseline: UInt64?
    private var rebaselineNext = true

    /// The surface became visible or hidden: the next event is not a live delta.
    mutating func noteVisibilityChanged() { rebaselineNext = true }
    /// The pixel size changed: the next event may be a reflow.
    mutating func noteResized() { rebaselineNext = true }

    /// Feed one scrollbar event. Returns true when it is real output growth.
    mutating func observe(total: UInt64, len: UInt64) -> Bool {
        let history = total > len ? total - len : 0
        defer { baseline = history }
        if rebaselineNext {
            rebaselineNext = false
            return false
        }
        guard let baseline else { return false }
        return history > baseline
    }
}

/// Text for the sheet's non-date clocks.
enum TabSheetClockText {
    /// `4m 12s`, `1h 5m`: localized abbreviated units, two at most.
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(0, seconds.rounded(.down))) ?? "0s"
    }

    /// `48K`, `1.2M`: compact and locale aware; small counts stay exact.
    static func count(_ value: Int) -> String {
        if value < 1_000 { return String(value) }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
