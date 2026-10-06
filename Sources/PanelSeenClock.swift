import AppKit
import Foundation

// C11-243: per-tab "last seen" tracking.
//
// Definition. A tab (panel) is **being seen** while ALL of these hold:
//   1. it is the selected tab of the focused pane in its workspace,
//   2. that workspace is the selected workspace of its window,
//   3. that window is the key window and a c11 main terminal window,
//   4. c11 is the active (frontmost) app,
//   5. that window is on the active Space and not fully occluded,
//   6. the screen is not locked, in screensaver, or asleep (displays or system)
//      and the login session is active. These are independent reasons; one
//      clearing (a display waking) does not lift another (the lock screen).
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
// stamps ride the existing session snapshot cadence (`last_seen_at`), so the
// persisted value can lag by up to the autosave interval (8 s). Precision is
// one second on the socket. Closed panels are dropped via `forget(panelId:)`.

/// Pure state machine behind `lastSeenAt`. No AppKit, no clock of its own.
struct PanelSeenClock {
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
    /// The stored stop time, ignoring whether the panel is being seen right now.
    func storedStamp(_ panelId: UUID) -> Date? {
        stamps[panelId]
    }

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
final class PanelSeenTracker {
    static let shared = PanelSeenTracker()

    /// Independent reasons the operator cannot be looking at c11 even though its
    /// focus state is unchanged. Each is cleared only by its own counterpart, so a
    /// display waking while the lock screen is still up stays interrupted.
    enum InterruptReason: Hashable {
        case locked
        case screensaver
        case displaysAsleep
        case systemAsleep
        case sessionInactive
    }

    private var clock = PanelSeenClock()
    private(set) var interruptions: Set<InterruptReason> = []
    private let seenProvider: @MainActor () -> UUID?
    private let now: () -> Date
    private let screenLockedProvider: () -> Bool
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var distributedRelay: DistributedRelay?

    /// `seenProvider` answers "which panel is on screen in front of the operator";
    /// `now` is the clock. Both are injectable for tests.
    init(
        seenProvider: @escaping @MainActor () -> UUID? = { AppDelegate.shared?.operatorSeenPanelId() },
        now: @escaping () -> Date = { Date() },
        screenLockedProvider: @escaping () -> Bool = { PanelSeenTracker.systemScreenIsLocked() }
    ) {
        self.seenProvider = seenProvider
        self.now = now
        self.screenLockedProvider = screenLockedProvider
    }

    /// The window server's own view of the lock state; authoritative when a
    /// lock/unlock distributed notification was missed.
    nonisolated static func systemScreenIsLocked() -> Bool {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (dict?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Self-heal on activation. c11 cannot come to the front while the screensaver
    /// runs or the machine/displays sleep, so those reasons are stale by now (a
    /// missed `didstop`, or a sleep during the screensaver). The lock state is
    /// re-read from the window server instead of trusting notification pairing.
    func appBecameActive() {
        interruptions.subtract([.screensaver, .displaysAsleep, .systemAsleep])
        if screenLockedProvider() {
            interruptions.insert(.locked)
        } else {
            interruptions.remove(.locked)
        }
        refresh()
    }

    /// Recompute what the operator is looking at; stamp the previous panel if it
    /// changed. Cheap enough for selection/focus paths; do not call per keystroke.
    func refresh() {
        let seen = interruptions.isEmpty ? seenProvider() : nil
        guard seen != clock.current else { return }
        let date = now()
        clock.observe(seen: seen, at: date)
        FocusHistoryStore.shared.noteTransition(panelId: seen, at: date)
    }

    func setInterruption(_ reason: InterruptReason, active: Bool) {
        if active { interruptions.insert(reason) } else { interruptions.remove(reason) }
        refresh()
    }

    func lastSeenAt(panelId: UUID) -> Date? {
        clock.lastSeenAt(panelId, now: now())
    }

    /// The stored stop time without the "now while seen" substitution. Pair with
    /// `isBeingSeen` so a consumer can tell "now" from "a second ago".
    func storedLastSeenAt(panelId: UUID) -> Date? {
        clock.storedStamp(panelId)
    }

    func isBeingSeen(panelId: UUID) -> Bool {
        clock.current == panelId
    }

    func seed(panelId: UUID, at date: Date) {
        clock.seed(panelId, at: date)
    }

    /// Drop a closed panel's stamp. Not for detach/move, where the id survives.
    func forget(panelId: UUID) {
        clock.forget(panelId)
        FocusHistoryStore.shared.prune(panelId: panelId)
    }

    /// Idempotent. Observes app/window/Space/screen state; selection and focus
    /// paths call `refresh()` directly.
    func install() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        func add(_ center: NotificationCenter, _ name: Notification.Name, reason: InterruptReason? = nil, active: Bool = false) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let reason {
                        self.setInterruption(reason, active: active)
                    } else {
                        self.refresh()
                    }
                }
            }
            observers.append((center, token))
        }

        let activeToken = nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        observers.append((nc, activeToken))
        add(nc, NSApplication.didResignActiveNotification)
        add(nc, NSWindow.didBecomeKeyNotification)
        add(nc, NSWindow.didResignKeyNotification)
        add(nc, NSWindow.didChangeOcclusionStateNotification)
        add(ws, NSWorkspace.activeSpaceDidChangeNotification)
        add(ws, NSWorkspace.screensDidSleepNotification, reason: .displaysAsleep, active: true)
        add(ws, NSWorkspace.screensDidWakeNotification, reason: .displaysAsleep, active: false)
        add(ws, NSWorkspace.willSleepNotification, reason: .systemAsleep, active: true)
        add(ws, NSWorkspace.didWakeNotification, reason: .systemAsleep, active: false)
        add(ws, NSWorkspace.sessionDidResignActiveNotification, reason: .sessionInactive, active: true)
        add(ws, NSWorkspace.sessionDidBecomeActiveNotification, reason: .sessionInactive, active: false)
        // Distributed notifications are coalesced or suspended while c11 is in the
        // background unless registered with `.deliverImmediately`, which needs the
        // selector-based API.
        let relay = DistributedRelay { [weak self] name in
            guard let self else { return }
            switch name.rawValue {
            case "com.apple.screenIsLocked": self.setInterruption(.locked, active: true)
            case "com.apple.screenIsUnlocked": self.setInterruption(.locked, active: false)
            case "com.apple.screensaver.didstart": self.setInterruption(.screensaver, active: true)
            case "com.apple.screensaver.willstop", "com.apple.screensaver.didstop":
                self.setInterruption(.screensaver, active: false)
            default: break
            }
        }
        distributedRelay = relay
        for name in [
            "com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
            "com.apple.screensaver.didstart", "com.apple.screensaver.willstop",
            "com.apple.screensaver.didstop",
        ] {
            dnc.addObserver(
                relay,
                selector: #selector(DistributedRelay.received(_:)),
                name: Notification.Name(name),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        interruptions.formUnion(screenLockedProvider() ? [.locked] : [])
        refresh()
    }
}

/// Selector target for distributed notifications (the block API cannot set
/// `suspensionBehavior`). Hops to main before calling the handler.
private final class DistributedRelay: NSObject {
    private let handler: @MainActor (Notification.Name) -> Void

    init(handler: @escaping @MainActor (Notification.Name) -> Void) {
        self.handler = handler
    }

    @objc func received(_ note: Notification) {
        let name = note.name
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(name) }
        } else {
            DispatchQueue.main.async { [handler] in
                MainActor.assumeIsolated { handler(name) }
            }
        }
    }
}
