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
    private let interval: TimeInterval = 30

    private var timer: Timer?

    private init() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        // Common mode so the tick keeps firing during scroll / tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }
}
