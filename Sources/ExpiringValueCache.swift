import Foundation

/// C11-196: LaunchServices-backed AppKit lookups are synchronous XPC round trips.
///
/// `NSApplication.activationPolicy()`, `NSWorkspace.fullPath(forApplication:)`,
/// `NSWorkspace.urlForApplication(withBundleIdentifier:)` and
/// `NSWorkspace.icon(forFile:)` all reach `launchservicesd` through
/// `xpc_connection_send_message_with_reply_sync`, and nothing bounds that wait.
/// Sentry hang captures for c11 show main parked in
/// `_dispatch_mach_send_and_wait_for_reply` under `_LSCopyApplicationInformation`
/// for tens of seconds at a time. A single such call is unavoidable; issuing one
/// per keystroke, per render pass, or per `UserDefaults.didChangeNotification` is
/// not.
///
/// `ExpiringValueCache` is the seam that turns those repeated lookups into one
/// lookup per TTL window. It deliberately keeps the last value past expiry so a
/// caller that cannot block (a SwiftUI update pass, a command-palette refresh)
/// can serve the stale answer immediately and recompute off the main thread.
///
/// Thread-safe: every accessor takes an internal lock, so a background refresh
/// and a main-thread read can race safely.
final class ExpiringValueCache<Value> {
    /// How the stored value relates to the TTL window.
    enum Freshness: Equatable {
        /// Nothing has been stored yet.
        case missing
        /// A value is stored and still inside the TTL window.
        case fresh
        /// A value is stored but the TTL window has elapsed.
        case stale
    }

    private let ttl: TimeInterval
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var storedValue: Value?
    private var storedAt: TimeInterval?

    /// - Parameters:
    ///   - ttl: How long a stored value stays `.fresh`. Must be >= 0.
    ///   - now: Monotonic clock source. Defaults to `systemUptime` so a wall-clock
    ///     or NTP adjustment mid-window cannot make a value look arbitrarily old
    ///     or arbitrarily new.
    init(
        ttl: TimeInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.ttl = max(0, ttl)
        self.now = now
    }

    var freshness: Freshness {
        lock.lock()
        defer { lock.unlock() }
        return freshnessLocked()
    }

    /// The last stored value, regardless of age. `nil` only before the first store.
    func peek() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    /// Replace the stored value and restart the TTL window.
    func store(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storedValue = value
        storedAt = now()
    }

    /// Drop the stored value. The next `value(orCompute:)` recomputes.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        storedValue = nil
        storedAt = nil
    }

    /// Return the cached value when fresh, otherwise compute, store, and return.
    ///
    /// `compute` runs on the caller's thread, so this blocks the caller for the
    /// duration of the underlying XPC wait. Use it where a blocking first call is
    /// acceptable and repetition is not.
    func value(orCompute compute: () -> Value) -> Value {
        lock.lock()
        if freshnessLocked() == .fresh, let storedValue {
            lock.unlock()
            return storedValue
        }
        lock.unlock()

        // Compute outside the lock: `compute` can park on synchronous XPC for a
        // long time and must not hold off a concurrent `peek()`/`store()`.
        let computed = compute()
        store(computed)
        return computed
    }

    /// Never blocks when any value has ever been stored.
    ///
    /// Returns the cached value immediately (even if stale) and, when it is stale
    /// or missing, hands `refresh` to `scheduleRefresh` so the recompute happens
    /// off the caller's thread. Only the very first call, before anything has been
    /// stored, returns `nil`.
    ///
    /// At most one refresh is in flight at a time; calls made while a refresh is
    /// running return the current value without scheduling another.
    func valueRefreshingInBackground(
        scheduleRefresh: (@escaping () -> Void) -> Void,
        refresh: @escaping () -> Value
    ) -> Value? {
        lock.lock()
        let current = storedValue
        let needsRefresh = freshnessLocked() != .fresh && !refreshInFlight
        if needsRefresh {
            refreshInFlight = true
        }
        lock.unlock()

        guard needsRefresh else { return current }

        scheduleRefresh { [weak self] in
            guard let self else { return }
            let value = refresh()
            self.store(value)
            self.lock.lock()
            self.refreshInFlight = false
            self.lock.unlock()
        }

        return current
    }

    private var refreshInFlight = false

    private func freshnessLocked() -> Freshness {
        guard storedValue != nil, let storedAt else { return .missing }
        return (now() - storedAt) < ttl ? .fresh : .stale
    }
}
