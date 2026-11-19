import Foundation
import Combine

/// Coarse, shared clock that drives sidebar decay re-rendering.
///
/// C11-162 (Telemetry truth): sidebar status pills and progress
/// indicators need to visually age even when nothing else in the row
/// changes. Rather than each row spinning its own timer, a single shared
/// `~30s` timer bumps `now`; the decay child subviews observe this object
/// and re-render off it.
///
/// This is deliberately the *only* new timer introduced by the decay work,
/// and it is intentionally coarse — decay stages change on the order of
/// minutes, so a 30s cadence is plenty and keeps the main runloop quiet.
/// It must never be observed from `TabItemView`'s body (which is
/// `Equatable` to skip re-eval during typing) — only from the small child
/// pill / progress subviews.
final class SidebarDecayClock: ObservableObject {
    static let shared = SidebarDecayClock()

    /// Current coarse "now". Bumped by the repeating timer.
    @Published private(set) var now: Date = Date()

    /// Cadence of the single shared tick. Coarse on purpose.
    static let interval: TimeInterval = 30
    private let interval: TimeInterval

    private var timer: Timer?

    /// C11H-278: host-owned, true while no c11 window is visible. Paused, the
    /// clock runs no timer and publishes nothing; resuming publishes the
    /// current time once, so every aged label and pill catches up before the
    /// next tick. Set on main only (`WindowVisibilityGate`).
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                timer?.invalidate()
                timer = nil
            } else {
                now = Date()
                installTimer()
            }
        }
    }

    /// Whether the timer is running (diagnostics and tests).
    var isTicking: Bool { timer != nil }

    init(interval: TimeInterval = SidebarDecayClock.interval) {
        self.interval = interval
        // C11-162 (m4): the timer must be installed on the main runloop, and
        // `RunLoop.main.add` / the `@Published` bump are only main-safe there.
        // `.shared` is normally first touched from a SwiftUI view init (main),
        // but guard against an off-main first access so the tick can never
        // silently fail to schedule.
        if Thread.isMainThread {
            installTimer()
        } else {
            DispatchQueue.main.async { [weak self] in self?.installTimer() }
        }
    }

    private func installTimer() {
        guard !isPaused, timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // A tick already queued when the host paused must not publish.
            guard let self, !self.isPaused else { return }
            self.now = Date()
        }
        // Common mode so the tick keeps firing during scroll / tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }
}

/// C11H-278: how long ago a panel's description was edited, in the coarse
/// steps the operator reads at a glance. A stale description is a lie the
/// operator cannot otherwise detect; its age makes it visible.
enum DescriptionAge: Equatable {
    case justNow
    case minutes(Int)
    case hours(Int)
    case days(Int)
    /// More than 99 days: one bounded text, so a long-lived panel's age never
    /// outgrows its fixed slot.
    case overNinetyNineDays

    /// `full` reads "edited 12 min ago" (title bar, summary card); `compact`
    /// reads "12m" (sidebar agent rows, where a column is narrow).
    enum Style: Hashable {
        case full
        case compact
    }

    init(updatedAt: Date, now: Date) {
        let seconds = max(0, now.timeIntervalSince(updatedAt))
        switch seconds {
        case ..<60: self = .justNow
        case ..<3600: self = .minutes(Int(seconds / 60))
        case ..<86_400: self = .hours(Int(seconds / 3600))
        default:
            let days = Int(seconds / 86_400)
            self = days > 99 ? .overNinetyNineDays : .days(days)
        }
    }

    func text(_ style: Style) -> String {
        switch (self, style) {
        case (.justNow, .full):
            return String(localized: "descriptionAge.full.justNow", defaultValue: "edited just now")
        case (.minutes(let count), .full):
            return String(localized: "descriptionAge.full.minutes", defaultValue: "edited \(count) min ago")
        case (.hours(let count), .full):
            return String(localized: "descriptionAge.full.hours", defaultValue: "edited \(count) h ago")
        case (.days(let count), .full):
            return String(localized: "descriptionAge.full.days", defaultValue: "edited \(count) d ago")
        case (.overNinetyNineDays, .full):
            return String(localized: "descriptionAge.full.overNinetyNineDays", defaultValue: "edited 99+ d ago")
        case (.justNow, .compact):
            return String(localized: "descriptionAge.compact.justNow", defaultValue: "now")
        case (.minutes(let count), .compact):
            return String(localized: "descriptionAge.compact.minutes", defaultValue: "\(count)m")
        case (.hours(let count), .compact):
            return String(localized: "descriptionAge.compact.hours", defaultValue: "\(count)h")
        case (.days(let count), .compact):
            return String(localized: "descriptionAge.compact.days", defaultValue: "\(count)d")
        case (.overNinetyNineDays, .compact):
            return String(localized: "descriptionAge.compact.overNinetyNineDays", defaultValue: "99+d")
        }
    }

    /// Every text shape a style shows at its widest (two-digit counts; digits
    /// are tabular), so a slot measured from them holds every age.
    static let widthSamples: [DescriptionAge] = [.justNow, .minutes(59), .hours(23), .days(99), .overNinetyNineDays]
}
