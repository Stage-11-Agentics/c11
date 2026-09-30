import AppKit
import Foundation

// C11-243: per-tab "last seen" tracking.
//
// Definition. A tab (panel) is **being seen** while ALL of these hold:
//   1. it is the selected tab of the focused pane in its workspace,
//   2. that workspace is the selected workspace of its window,
//   3. that window is the key window and a c11 main terminal window,
//   4. c11 is the active (frontmost) app,
//   5. the screen is not locked or asleep and the login session is active.
// At most one panel in the whole app is being seen at any moment.
//
// `lastSeenAt` is the moment a panel last STOPPED being seen. While a panel is
// being seen it reports "now". A panel that was never seen (and has no
// persisted stamp) reports nil.
//
// Design. "Being seen" is a pure function of live focus state, recomputed by
// `SurfaceSeenTracker.refresh()` from the events that can change it (tab
// selection, pane focus, workspace switch, key window, app activation, screen
// lock/sleep). Each refresh compares the new seen-panel to the previous one and
// stamps the previous panel on a change. Because the answer is derived from
// what is on screen, every transition out is stamped by construction, and a
// programmatic focus change while c11 is in the background stamps nothing
// (nothing was being seen). A socket/CLI command that changes the visible tab
// while the operator IS looking does stamp the tab that left the screen: the
// operator genuinely stopped seeing it, so the stamp is accurate.
//
// Cost. Refresh runs on the main thread from selection/focus/app events only
// (never from keystroke, hit-test, or `forceRefresh` paths). The steady state is
// a handful of property reads and an equality check; a `Date` is allocated only
// when the seen-panel actually changes. Nothing is written to disk here: the
// stamps ride the existing session snapshot cadence (`last_seen_at`).

/// Pure state machine behind `lastSeenAt`. No AppKit, no clock of its own.
struct SurfaceSeenClock {
    /// The panel being seen right now, if any.
    private(set) var current: UUID?
    private var stamps: [UUID: Date] = [:]

    /// Record the latest seen-panel. Returns true when it changed. The panel
    /// that stopped being seen is stamped with `now`.
    @discardableResult
    mutating func observe(seen: UUID?, at now: Date) -> Bool {
        guard seen != current else { return false }
        if let previous = current {
            stamps[previous] = now
        }
        current = seen
        return true
    }

    /// `now` while `panelId` is being seen, else its last stop time (or nil).
    func lastSeenAt(_ panelId: UUID, now: Date) -> Date? {
        if panelId == current { return now }
        return stamps[panelId]
    }

    /// Restore a persisted stamp. Never overrides a live observation.
    mutating func seed(_ panelId: UUID, at date: Date) {
        guard panelId != current else { return }
        if let existing = stamps[panelId], existing >= date { return }
        stamps[panelId] = date
    }

    mutating func forget(_ panelId: UUID) {
        stamps.removeValue(forKey: panelId)
        if current == panelId { current = nil }
    }
}

@MainActor
final class SurfaceSeenTracker {
    static let shared = SurfaceSeenTracker()

    private var clock = SurfaceSeenClock()
    /// True while the screen is locked/asleep or the login session is inactive.
    private var interrupted = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private init() {}

    /// Recompute what the operator is looking at; stamp the previous panel if it
    /// changed. Cheap enough for selection/focus paths; do not call per keystroke.
    func refresh() {
        let seen = interrupted ? nil : AppDelegate.shared?.operatorSeenPanelId()
        guard seen != clock.current else { return }
        clock.observe(seen: seen, at: Date())
    }

    func lastSeenAt(panelId: UUID) -> Date? {
        clock.lastSeenAt(panelId, now: Date())
    }

    func isBeingSeen(panelId: UUID) -> Bool {
        clock.current == panelId
    }

    func seed(panelId: UUID, at date: Date) {
        clock.seed(panelId, at: date)
    }

    func forget(panelId: UUID) {
        clock.forget(panelId)
    }

    /// Idempotent. Observes app/window/screen state; selection and focus paths
    /// call `refresh()` directly.
    func install() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        func add(_ center: NotificationCenter, _ name: Notification.Name, interrupt: Bool? = nil) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let interrupt { self.interrupted = interrupt }
                    self.refresh()
                }
            }
            observers.append((center, token))
        }

        add(nc, NSApplication.didBecomeActiveNotification)
        add(nc, NSApplication.didResignActiveNotification)
        add(nc, NSWindow.didBecomeKeyNotification)
        add(nc, NSWindow.didResignKeyNotification)
        add(ws, NSWorkspace.screensDidSleepNotification, interrupt: true)
        add(ws, NSWorkspace.screensDidWakeNotification, interrupt: false)
        add(ws, NSWorkspace.willSleepNotification, interrupt: true)
        add(ws, NSWorkspace.didWakeNotification, interrupt: false)
        add(ws, NSWorkspace.sessionDidResignActiveNotification, interrupt: true)
        add(ws, NSWorkspace.sessionDidBecomeActiveNotification, interrupt: false)
        add(dnc, Notification.Name("com.apple.screenIsLocked"), interrupt: true)
        add(dnc, Notification.Name("com.apple.screenIsUnlocked"), interrupt: false)
        refresh()
    }
}
