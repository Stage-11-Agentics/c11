import Foundation

enum AppNapActivityTransition: Equatable {
    case acquire
    case release
    case unchanged
}

/// The lifecycle policy for c11's App Nap opt-out that allows system idle sleep.
///
/// A connected socket client keeps the assertion active. The final
/// disconnect keeps it active for one idle window. The policy is pure so
/// connection churn and the release boundary can be tested without waiting on
/// process activity.
struct AppNapActivityPolicy {
    static let defaultIdleWindow: TimeInterval = 60

    let idleWindow: TimeInterval
    private(set) var connectedSocketClients = 0
    private(set) var holdsActivityAssertion = false
    private var lastWorkAt: TimeInterval?

    init(idleWindow: TimeInterval = defaultIdleWindow) {
        self.idleWindow = max(0, idleWindow)
    }

    var releaseDeadline: TimeInterval? {
        guard connectedSocketClients == 0, holdsActivityAssertion,
              let lastWorkAt else { return nil }
        return lastWorkAt + idleWindow
    }

    mutating func socketClientConnected(at uptime: TimeInterval) -> AppNapActivityTransition {
        connectedSocketClients += 1
        recordWork(at: uptime)
        return reconcile(at: uptime)
    }

    mutating func socketClientDisconnected(at uptime: TimeInterval) -> AppNapActivityTransition {
        guard connectedSocketClients > 0 else { return .unchanged }
        connectedSocketClients -= 1
        recordWork(at: uptime)
        return reconcile(at: uptime)
    }

    mutating func idleWindowElapsed(at uptime: TimeInterval) -> AppNapActivityTransition {
        reconcile(at: uptime)
    }

    private mutating func reconcile(at uptime: TimeInterval) -> AppNapActivityTransition {
        let hasRecentWork = lastWorkAt.map { uptime < $0 + idleWindow } ?? false
        let shouldHold = connectedSocketClients > 0 || hasRecentWork
        guard shouldHold != holdsActivityAssertion else { return .unchanged }

        holdsActivityAssertion = shouldHold
        if !shouldHold { lastWorkAt = nil }
        return shouldHold ? .acquire : .release
    }

    private mutating func recordWork(at uptime: TimeInterval) {
        lastWorkAt = max(lastWorkAt ?? uptime, uptime)
    }
}

/// Owns one ProcessInfo assertion for the whole app. Calls from the socket
/// accept/client threads and terminal renderer are coalesced onto one queue;
/// beginActivity and endActivity therefore never race across source threads
/// and never block a socket message or typing path.
final class AppNapActivityCoordinator: @unchecked Sendable {
    static let shared = AppNapActivityCoordinator()

    private let queue: DispatchQueue
    private let idleTimer: DispatchSourceTimer
    private let now: () -> TimeInterval
    private let beginActivity: (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol?
    private let endActivity: (NSObjectProtocol) -> Void
    private var policy: AppNapActivityPolicy
    private var activity: NSObjectProtocol?

    init(
        idleWindow: TimeInterval = AppNapActivityPolicy.defaultIdleWindow,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        beginActivity: @escaping (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol? = {
            options, reason in ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        },
        endActivity: @escaping (NSObjectProtocol) -> Void = {
            activity in ProcessInfo.processInfo.endActivity(activity)
        }
    ) {
        self.queue = DispatchQueue(label: "com.stage11.c11.app-nap-activity", qos: .userInitiated)
        self.now = now
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        self.policy = AppNapActivityPolicy(idleWindow: idleWindow)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.idleTimer = timer
        timer.setEventHandler { [weak self] in
            self?.idleTimerDidFire()
        }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
    }

    func socketClientDidConnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.apply(self.policy.socketClientConnected(at: self.now()))
        }
    }

    func socketClientDidDisconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.apply(self.policy.socketClientDisconnected(at: self.now()))
        }
    }

    /// Runs the real timer handler synchronously for coordinator-level tests.
    func fireIdleTimerForTesting() {
        queue.sync { idleTimerDidFire() }
    }

    /// Waits for previously enqueued socket events in coordinator-level tests.
    func drainForTesting() {
        queue.sync {}
    }

    private func idleTimerDidFire() {
        apply(policy.idleWindowElapsed(at: now()))
    }

    private func apply(_ transition: AppNapActivityTransition) {
        // This method, the policy, and the token are confined to `queue`.
        switch transition {
        case .acquire:
            if activity == nil {
                activity = beginActivity(
                    [.userInitiatedAllowingIdleSystemSleep],
                    "c11 is serving agent work"
                )
            }
        case .release:
            if let activity {
                endActivity(activity)
                self.activity = nil
            }
        case .unchanged:
            break
        }
        scheduleIdleTimer()
    }

    private func scheduleIdleTimer() {
        guard let deadline = policy.releaseDeadline else {
            idleTimer.schedule(deadline: .distantFuture)
            return
        }
        let delay = max(0, deadline - now())
        idleTimer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
    }
}
