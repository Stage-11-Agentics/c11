import CryptoKit
import Foundation

/// Pure composition shared by typed, saved-config, Settings and existing-tab
/// launch paths. The caller stages the body off-main before composing.
enum LaunchPromptDelivery {
    struct Plan: Equatable {
        let launchLine: String
        let delayedPrompt: String?
    }

    /// The longest headline the first message carries, so the launch line stays short.
    static let headlineLimit = 360

    /// What the agent's first message says. A `headline` (one line the caller
    /// wants the operator to see, such as what the task is) leads; the body
    /// itself stays in the owned file.
    static func instruction(path: String, headline: String? = nil) -> String {
        let pointer = "Read the file at \(path) and follow it exactly."
        guard let headline = sanitizedHeadline(headline) else { return pointer }
        return headline + " " + pointer
    }

    /// One printable line of at most `headlineLimit` characters, or nil when empty.
    /// It starts with a letter, digit, quote or bracket: a leading `-`, `/` or `!`
    /// could read as an agent CLI option, a slash command or a shell escape.
    static func sanitizedHeadline(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        var line = printable.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        while let first = line.first, !(first.isLetter || first.isNumber || "\"'“‘«([".contains(first)) {
            line.removeFirst()
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        if line.count > headlineLimit {
            line = String(line.prefix(headlineLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return line
    }

    static func compose(command: String, delivery: AgentPromptDelivery, promptFilePath: String?,
                        headline: String? = nil) -> Plan {
        guard let promptFilePath else { return Plan(launchLine: command, delayedPrompt: nil) }
        let instruction = instruction(path: promptFilePath, headline: headline)
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
    private let generationIsCurrent: () -> Bool
    private let isBlockedByDialog: () -> Bool
    private var completed = false {
        didSet { if completed, !oldValue { onFinished?() } }
    }
    private var dialogWaits = 0
    private var headlessWaits = 0
    /// C11H-116: set when the terminal has no Ghostty surface. Returns the agent's readiness from hc's own status
    /// (nil when a surface exists, which keeps the screen-receipt path).
    private let headlessReadiness: () -> HCAgentReadiness?
    /// The prompt will not be delivered; the reason is shown to the operator. Never typed into a dialog.
    private let onFailure: (String) -> Void
    private let onFinished: (() -> Void)?
    static let maxHeadlessWaits = 1200          // at 0.5 s: ten minutes for the agent to reach its prompt
    nonisolated(unsafe) static var headlessRecheck: TimeInterval = 0.5
    /// How long after the launcher line the prompt is attempted (the TUI needs time to boot).
    nonisolated(unsafe) static var promptDelay: TimeInterval = 2.5

    /// How long the prompt waits for a TUI chooser to be answered: one look a
    /// second, so ten minutes. Past that the prompt is dropped, never typed.
    static let maxDialogWaits = 600
    static let dialogRecheck: TimeInterval = 1

    init(launcher: String, prompt: String, isLive: @escaping () -> Bool,
         isReady: @escaping () -> Bool, submit: @escaping Submit,
         generationIsCurrent: @escaping () -> Bool = { true },
         isBlockedByDialog: @escaping () -> Bool = { false },
         headlessReadiness: @escaping () -> HCAgentReadiness? = { nil },
         onFailure: @escaping (String) -> Void = { _ in },
         onFinished: (() -> Void)? = nil,
         schedule: @escaping Schedule = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
         }) {
        self.launcher = launcher
        self.prompt = prompt
        self.isLive = isLive
        self.isReady = isReady
        self.submit = submit
        self.schedule = schedule
        self.generationIsCurrent = generationIsCurrent
        self.isBlockedByDialog = isBlockedByDialog
        self.headlessReadiness = headlessReadiness
        self.onFailure = onFailure
        self.onFinished = onFinished
    }

    func start() { attempt(launcher, isLauncher: true) }

    private func attempt(_ text: String, isLauncher: Bool) {
        guard !completed else { return }
        guard isLive(), generationIsCurrent() else { completed = true; return }
        guard isReady() else {
            // Only a pending launch retries; no ongoing work after delivery
            // or tab close, and no filesystem or process scan on this path.
            schedule(0.25) { self.attempt(text, isLauncher: isLauncher) }
            return
        }
        // The prompt's Return answers whatever the TUI is showing. Behind a
        // chooser (Claude's folder-trust check highlights `No, exit`) it would
        // pick the highlighted option, so the prompt waits for a person to
        // answer and is never typed into a chooser. The launcher line goes to
        // a shell and is not held.
        if !isLauncher, let readiness = headlessReadiness() {
            // No screen: hc's agent status is the gate. Only an agent idle at its prompt takes the prompt.
            switch readiness {
            case .ready: break
            case .blocked:
                completed = true
                onFailure("blocked")
                return
            case .waiting:
                headlessWaits += 1
                if headlessWaits > Self.maxHeadlessWaits {
                    completed = true
                    onFailure("timeout")
                    return
                }
                schedule(Self.headlessRecheck) { self.attempt(text, isLauncher: false) }
                return
            }
        } else if !isLauncher, isBlockedByDialog() {
            dialogWaits += 1
            if dialogWaits > Self.maxDialogWaits { completed = true; return }
            schedule(Self.dialogRecheck) { self.attempt(text, isLauncher: false) }
            return
        }
        submit(text) { submitted in
            guard !self.completed else { return }
            guard submitted, self.isLive(), self.generationIsCurrent() else {
                // A teardown after paste may leave a draft; never retry it or
                // assume it was submitted, and never send the second prompt.
                self.completed = true
                return
            }
            if isLauncher {
                self.schedule(Self.promptDelay) { self.attempt(self.prompt, isLauncher: false) }
            } else {
                self.completed = true
            }
        }
    }
}

/// What makes two `launch-agent` requests the same launch, for the pending-retry check (C11H-116): the
/// workspace, the machine and everything that shapes what runs: agent, model, effort, task, prompt, the
/// resolved working directory, the explicit environment, the command override, the system-prompt setting and
/// the prompt headline.
/// Two launches differing in any of them are distinct (e.g. two worktrees of one task).
enum LaunchIdentity {
    static func key(workspaceID: UUID, machine: String, request: AgentLaunchRequest, cwd: String?) -> String {
        var parts: [String] = [workspaceID.uuidString, machine, request.kind, request.model ?? "", request.effort ?? "",
                               request.task ?? "", cwd ?? "", request.commandOverride ?? "",
                               request.systemPrompt.map { String(describing: $0) } ?? "",
                               request.promptHeadline ?? ""]
        parts.append(request.extraEnv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1F}"))
        parts.append(SHA256.hash(data: Data((request.prompt ?? "").utf8)).map { String(format: "%02x", $0) }.joined())
        return parts.joined(separator: "\u{1E}")
    }
}

/// Binds a launch to the input generation it started under. The post-boot
/// prompt and its Return may only reach that same terminal attachment: a
/// replaced surface or a new hc epoch during the (seconds-long) delay cancels
/// both. Unbound means the launcher has not been submitted yet.
final class LaunchGenerationBinding<Stamp> {
    private var stamp: Stamp?

    func bindIfNeeded(_ capture: () -> Stamp) {
        if stamp == nil { stamp = capture() }
    }

    /// The prompt may be submitted: the launch is bound, still live, and its
    /// generation is current.
    func admitsSubmit(isLive: Bool, isCurrent: (Stamp) -> Bool) -> Bool {
        guard let stamp else { return false }
        return isLive && isCurrent(stamp)
    }

    /// Before the launcher is submitted there is nothing to be stale against.
    func isCurrent(_ check: (Stamp) -> Bool) -> Bool {
        guard let stamp else { return true }
        return check(stamp)
    }
}
