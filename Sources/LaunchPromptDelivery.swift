import Foundation

/// Pure composition shared by typed, saved-config, Settings and existing-tab
/// launch paths. The caller stages the body off-main before composing.
enum LaunchPromptDelivery {
    struct Plan: Equatable {
        let launchLine: String
        let delayedPrompt: String?
    }

    static func instruction(path: String) -> String {
        "Read the file at \(path) and follow it exactly."
    }

    static func compose(command: String, delivery: AgentPromptDelivery, promptFilePath: String?) -> Plan {
        guard let promptFilePath else { return Plan(launchLine: command, delayedPrompt: nil) }
        let instruction = instruction(path: promptFilePath)
        switch delivery {
        case .positional:
            return Plan(launchLine: command + " " + DefaultAgentResolver.shellQuote(instruction), delayedPrompt: nil)
        case .flag(let name):
            return Plan(launchLine: command + " " + name + " " + DefaultAgentResolver.shellQuote(instruction), delayedPrompt: nil)
        case .postBoot:
            return Plan(launchLine: command, delayedPrompt: instruction)
        }
    }
}

/// Launch-scoped main admission with one overall response deadline. Unlike a
/// commit gate that waits indefinitely after work begins, the socket worker
/// must also return if a running main operation stalls. Running work retains
/// responsibility for its prompt lifetime; only unstarted work is cancelled.
final class AgentLaunchDeadlineGate<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private let deadline: Date
    private let operation: () -> Value
    private var running = false
    private var cancelled = false
    private var completed = false
    private var value: Value?

    init(deadline: Date, operation: @escaping () -> Value) {
        self.deadline = deadline
        self.operation = operation
    }

    func enqueueOnMain() {
        enqueue { DispatchQueue.main.async(execute: $0) }
    }

    func enqueue(using schedule: (@escaping @Sendable () -> Void) -> Void) {
        schedule { [self] in
            condition.lock()
            guard !cancelled, Date() < deadline else {
                cancelled = true
                condition.broadcast()
                condition.unlock()
                return
            }
            running = true
            condition.unlock()
            let result = operation()
            condition.lock()
            value = result
            completed = true
            condition.broadcast()
            condition.unlock()
        }
    }

    func wait() -> Value? {
        condition.lock()
        defer { condition.unlock() }
        while !completed && !cancelled {
            if !condition.wait(until: deadline) {
                if !running { cancelled = true }
                return nil
            }
        }
        return value
    }

    var cancelledBeforeStart: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled && !running
    }
}

/// Launch-only sequencing: an unattached terminal never receives two submit
/// requests in its single pending-submit buffer. The best-effort TUI delay
/// begins at the existing helper's actual Return completion, not at dispatch.
@MainActor
final class LaunchPostBootSequence {
    typealias Submit = (String, @escaping (Bool) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let launcher: String
    private let prompt: String
    private let isLive: () -> Bool
    private let isReady: () -> Bool
    private let submit: Submit
    private let schedule: Schedule
    private var completed = false

    init(launcher: String, prompt: String, isLive: @escaping () -> Bool,
         isReady: @escaping () -> Bool, submit: @escaping Submit,
         schedule: @escaping Schedule = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
         }) {
        self.launcher = launcher
        self.prompt = prompt
        self.isLive = isLive
        self.isReady = isReady
        self.submit = submit
        self.schedule = schedule
    }

    func start() { attempt(launcher, isLauncher: true) }

    private func attempt(_ text: String, isLauncher: Bool) {
        guard !completed else { return }
        guard isLive() else { completed = true; return }
        guard isReady() else {
            // Only a pending launch retries; no ongoing work after delivery
            // or tab close, and no filesystem or process scan on this path.
            schedule(0.25) { self.attempt(text, isLauncher: isLauncher) }
            return
        }
        submit(text) { submitted in
            guard !self.completed else { return }
            guard submitted, self.isLive() else {
                // A teardown after paste may leave a draft; never retry it or
                // assume it was submitted, and never send the second prompt.
                self.completed = true
                return
            }
            if isLauncher {
                self.schedule(2.5) { self.attempt(self.prompt, isLauncher: false) }
            } else {
                self.completed = true
            }
        }
    }
}
