import Foundation

enum AppNapActivityTransition: Equatable {
    case acquire
    case release
    case unchanged
}

/// The lifecycle policy for c11's user-initiated activity assertion.
///
/// A connected socket client keeps the assertion active. After the final
/// client disconnects, recent terminal output or the disconnect itself keeps
/// it active for one idle window. The policy is pure so connection churn and
/// the release boundary can be tested without waiting on process activity.
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

    mutating func terminalOutput(at uptime: TimeInterval) -> AppNapActivityTransition {
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

    private let queue = DispatchQueue(label: "com.stage11.c11.app-nap-activity", qos: .userInitiated)
    private let idleTimer: DispatchSourceTimer
    private let outputSignalLock = NSLock()
    private var policy = AppNapActivityPolicy()
    private var activity: NSObjectProtocol?
    private var lastOutputSignalAt: TimeInterval?

    private init() {
        idleTimer = DispatchSource.makeTimerSource(queue: queue)
        idleTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.apply(self.policy.idleWindowElapsed(at: now))
        }
        idleTimer.schedule(deadline: .distantFuture)
        idleTimer.resume()
    }

    func socketClientDidConnect() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.apply(self.policy.socketClientConnected(at: now))
        }
    }

    func socketClientDidDisconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.apply(self.policy.socketClientDisconnected(at: now))
        }
    }

    /// Called only when visible terminal scrollback grows, not for each key or
    /// socket message. At most one update per second reaches the state queue.
    func noteTerminalOutput() {
        let now = ProcessInfo.processInfo.systemUptime
        outputSignalLock.lock()
        if let lastOutputSignalAt, now - lastOutputSignalAt < 1 {
            outputSignalLock.unlock()
            return
        }
        lastOutputSignalAt = now
        outputSignalLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let eventTime = ProcessInfo.processInfo.systemUptime
            self.apply(self.policy.terminalOutput(at: eventTime))
        }
    }

    private func apply(_ transition: AppNapActivityTransition) {
        // This method, the policy, and the token are confined to `queue`.
        switch transition {
        case .acquire:
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated],
                    reason: "c11 is serving agent work"
                )
            }
        case .release:
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
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
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        idleTimer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
    }
}
