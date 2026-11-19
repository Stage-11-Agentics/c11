import Foundation

// C11H-101: a panel made just before a quit must reach disk.
//
// The periodic autosave can trail a structural change by minutes. The
// debouncer below saves shortly after the change. The SIGTERM quit itself is
// C11H-100's `TerminationSignalQuit`, installed once the startup restore is
// ready; this file adds no signal handling. Plain Foundation with an injected
// scheduler, so the tests need no timer or app.

// MARK: - Debounced layout save

/// Coalesces "the layout changed" requests into one save, a short delay after
/// the first request in a burst.
///
/// Call `request` from the main thread when a panel is created, closed, moved
/// or renamed. A request is a flag test and, at most, one scheduled block, so
/// it is safe on any structural-change path; it never reads the layout and
/// never saves inline. The delay is measured from the FIRST request of a
/// burst, not the last, so a steady stream of titles cannot postpone the save
/// indefinitely.
final class SessionSaveDebouncer {
    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    /// Long enough to merge the several mutations of one operator action (a
    /// split creates a panel, retitles it and moves focus), short enough that
    /// a panel made just before a quit is already on disk.
    static let defaultDelay: TimeInterval = 2

    private let delay: TimeInterval
    private let schedule: Schedule
    private let fire: (_ sources: [String]) -> Void
    private var pendingSources: [String] = []
    private var armed = false
    private var generation = 0

    init(
        delay: TimeInterval = SessionSaveDebouncer.defaultDelay,
        schedule: @escaping Schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        fire: @escaping (_ sources: [String]) -> Void
    ) {
        self.delay = delay
        self.schedule = schedule
        self.fire = fire
    }

    /// True while a save is waiting on its delay.
    var isPending: Bool { armed }

    func request(source: String) {
        if !pendingSources.contains(source) { pendingSources.append(source) }
        guard !armed else { return }
        armed = true
        let expected = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == expected, self.armed else { return }
            self.armed = false
            let sources = self.pendingSources
            self.pendingSources = []
            self.fire(sources)
        }
    }

    /// Drops a waiting save. Used once the app is terminating: the final
    /// snapshot covers everything, and a late debounced write must not race it.
    func cancel() {
        generation += 1
        armed = false
        pendingSources = []
    }
}
