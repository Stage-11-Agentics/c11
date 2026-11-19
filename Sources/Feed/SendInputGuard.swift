import Foundation

enum SendInputGuardStatus: String, Equatable, Sendable {
    case checked
    case unknown
    case refused
    case overridden
}

enum SendInputGuardDecision: Equatable {
    case deliver(SendInputGuardStatus)
    case refuse(reason: String)
    case unavailable
}

enum SendInputGuard {
    static func targetIsCurrent<Workspace: AnyObject, PanelObject: AnyObject>(
        expectedWorkspace: Workspace,
        currentWorkspaces: [Workspace],
        expectedPanel: PanelObject,
        currentPanel: PanelObject?
    ) -> Bool {
        currentWorkspaces.contains { $0 === expectedWorkspace } && currentPanel === expectedPanel
    }

    static func decide(
        state: PromptInputState,
        allowUnguarded: Bool
    ) -> SendInputGuardDecision {
        if allowUnguarded {
            return .deliver(.overridden)
        }
        switch state {
        case .draft:
            return .refuse(reason: "draft")
        case .dialog:
            return .refuse(reason: "dialog")
        case .empty, .suggestion:
            return .deliver(.checked)
        case .unknown, .unavailable:
            return .deliver(.unknown)
        }
    }

    /// Keeps the write behind the same decision seam exercised by unit tests.
    @discardableResult
    static func perform(
        state: PromptInputState,
        allowUnguarded: Bool,
        targetAvailable: Bool = true,
        deliver: () -> Void
    ) -> SendInputGuardDecision {
        guard targetAvailable else { return .unavailable }
        let decision = decide(state: state, allowUnguarded: allowUnguarded)
        if case .deliver = decision { deliver() }
        return decision
    }
}

/// C11H-298: a written Return is only bytes. A TUI can take it as part of the
/// typed text (a Return inside its paste burst) or a chooser can eat it, and
/// the line then sits unsent in the composer. So a send to an agent at its
/// prompt watches, after the Return, for the agent's own evidence that its
/// turn started, and reports the send submitted only on that evidence.
enum SendSubmitConfirmation {
    /// The facts read just before the text was typed, and again after the
    /// Return. Nil fields are facts c11 does not have for this panel.
    struct Facts: Equatable, Sendable {
        /// hc's record of the program's own OSC 7501 report.
        var hcStatus: String?
        var hcStatusMs: Int64?
        var hcTurn: Int64?
        /// The live lifecycle journal (hooks, transcripts); nil when it has
        /// no live snapshot for the panel.
        var journalPhase: JournalPhase?
        var journalSinceMs: Int64?
        /// The journal's turn identity (a hook's prompt, hc's turn counter). A turn that came and went between
        /// looks shows as a new identity; a timestamp filled in later for the same turn does not.
        var journalTurnID: String?
        /// The prompt as read from the screen; nil on a panel with no screen.
        var prompt: PromptInputState?
        /// A fingerprint of the screen rows the prompt was read from (`frame(of:)`). A look whose rows match the
        /// baseline's is a frame from before the text was typed, and says nothing about the Return.
        var frame: Int?

        init(hcStatus: String? = nil, hcStatusMs: Int64? = nil, hcTurn: Int64? = nil,
             journalPhase: JournalPhase? = nil, journalSinceMs: Int64? = nil, journalTurnID: String? = nil,
             prompt: PromptInputState? = nil, frame: Int? = nil) {
            self.hcStatus = hcStatus
            self.hcStatusMs = hcStatusMs
            self.hcTurn = hcTurn
            self.journalPhase = journalPhase
            self.journalSinceMs = journalSinceMs
            self.journalTurnID = journalTurnID
            self.prompt = prompt
            self.frame = frame
        }

        var journalTurnOpen: Bool { journalPhase == .working || journalPhase == .blocked }
        var hcTurnOpen: Bool { hcStatus == "working" || hcStatus == "blocked" }
    }

    enum Expectation: Equatable, Sendable {
        /// An agent at its prompt took a line: its turn must start.
        case turnStart
        /// Nothing to wait on. The reason is a log-safe token: `no_return`,
        /// `bare_return`, `local_command` (a slash command or `!` shell line
        /// starts no turn), `not_agent`, `agent_working` (the line queues behind
        /// the running turn), `prompt_unknown`, `unguarded`.
        case none(String)
    }

    enum Verdict: Equatable, Sendable {
        /// The token names the evidence: `journal_turn`, `hc_status`,
        /// `hc_turn` or `composer_empty`.
        case confirmed(String)
        case pending
        /// `composer_holds_text`, `dialog` or `no_turn_start`.
        case unconfirmed(String)
    }

    /// Whether a recognized agent owns a terminal shown on screen: its declared or detected kind, or hc's
    /// foreground. Separate from whether c11 can read its composer (omp and GitHub Copilot have no reader).
    static func screenTargetIsAgent(harness: String?, record: HCTerminalRecord?) -> Bool {
        AgentIdentityPolicy.isAgentKind(harness) || HCRemoteMailboxForeground.agentOwnsTerminal(record)
    }

    /// JSON `submitted`: for an agent, only its confirmed take; for any other program, the Return written.
    static func submittedField(verdict: Verdict?, agentOwned: Bool, returnWritten: Bool) -> Bool {
        switch verdict {
        case .confirmed?: return true
        case .unconfirmed?, .pending?: return false
        case nil: return agentOwned ? false : returnWritten
        }
    }

    /// The screen rows a prompt was read from, fingerprinted within this process.
    static func frame(of region: PromptRegionSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(region.text)
        hasher.combine(region.cursorX)
        hasher.combine(region.cursorY)
        hasher.combine(region.rows.count)
        return hasher.finalize()
    }

    /// A line the agent handles itself, without a turn: a slash command (`/clear`, `/model opus`) or a `!` shell
    /// line. An absolute path (`/Users/me/brief.md, read it`) is a message, not a command.
    static func isLocalCommand(_ body: String) -> Bool {
        let trimmed = body.drop { $0 == " " || $0 == "\t" }
        if trimmed.first == "!" { return true }
        guard trimmed.first == "/" else { return false }
        let token = trimmed.dropFirst().prefix { !$0.isWhitespace }
        guard let first = token.first, first.isLetter else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
    }

    /// How long a send waits for the turn after its Return.
    nonisolated(unsafe) static var waitSeconds: TimeInterval = 3.0
    static let pollNanoseconds: UInt64 = 100_000_000

    /// - Parameters:
    ///   - screen: the send was guarded by a read of the panel's screen
    ///     (false: a panel with no screen, decided by hc's status).
    ///   - isAgent: an agent owns the terminal (hc's foreground program, a
    ///     status report, or the panel's agent kind).
    static func expectation(wantsReturn: Bool, bodyIsEmpty: Bool, screen: Bool, isAgent: Bool,
                            unguarded: Bool, baseline: Facts, localCommand: Bool = false) -> Expectation {
        guard wantsReturn else { return .none("no_return") }
        guard !bodyIsEmpty else { return .none("bare_return") }
        guard !localCommand else { return .none("local_command") }
        guard isAgent else { return .none("not_agent") }
        if screen {
            // A composer read on screen: it empties when the line is taken,
            // whether the turn starts now or the line queues behind one.
            switch baseline.prompt {
            case .empty?, .suggestion?: return .turnStart
            case .draft?, .dialog?: return unguarded ? .none("unguarded") : .none("prompt_unknown")
            case .unknown?, .unavailable?, nil: return .none("prompt_unknown")
            }
        }
        // No screen: only a new turn can confirm, and an agent mid-turn queues the line.
        if baseline.journalTurnOpen { return .none("agent_working") }
        switch baseline.hcStatus {
        case "idle", "done": return .turnStart
        case "working": return .none("agent_working")
        default: return .none("unguarded")
        }
    }

    /// Looks every `pollNanoseconds` until a verdict or the deadline; the look before the deadline is final.
    /// `look` returns nil when it could not read (a busy main thread); a final nil is no turn start.
    /// `look` is given how long it may block, never past the deadline, so the send answers inside its bound.
    /// The last look, inside the final poll interval, runs at once on whatever time is left.
    static func wait(baseline: Facts, deadline: Date, now: () -> Date = Date.init,
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                     look: (_ timeout: TimeInterval) -> Facts?) -> Verdict {
        let interval = Double(pollNanoseconds) / 1_000_000_000
        while true {
            let before = deadline.timeIntervalSince(now())
            guard before > 0 else { return .unconfirmed("no_turn_start") }
            var final = before < interval * 1.5
            if !final { sleep(interval) }
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { return .unconfirmed("no_turn_start") }
            final = final || remaining < interval * 0.5
            guard let facts = look(min(1, remaining)) else {
                if final { return .unconfirmed("no_turn_start") }
                continue
            }
            let verdict = judge(baseline: baseline, now: facts, final: final)
            if verdict != .pending { return verdict }
            if final { return .unconfirmed("no_turn_start") }
        }
    }

    /// C11H-305: one look the waiting thread schedules elsewhere (the main actor) and waits on for at most
    /// `timeout`. A look still unstarted when the wait gives up is cancelled and never runs `capture`, so a busy
    /// main thread does not work through a queue of late looks no one reads. One already running finishes and is
    /// ignored.
    static func timedLook(timeout: TimeInterval, schedule: (@escaping @Sendable () -> Void) -> Void,
                          capture: @escaping @Sendable () -> Facts?) -> Facts? {
        let look = TimedLook()
        schedule {
            guard look.begin() else { return }
            look.finish(capture())
        }
        return look.wait(timeout: timeout)
    }

    final class TimedLook: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var facts: Facts?
        private let done = DispatchSemaphore(value: 0)

        /// False once the waiter has given up: the look must not run.
        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !cancelled
        }

        func finish(_ value: Facts?) {
            lock.lock(); facts = value; lock.unlock()
            done.signal()
        }

        func wait(timeout: TimeInterval) -> Facts? {
            if done.wait(timeout: .now() + max(0, timeout)) == .success {
                lock.lock(); defer { lock.unlock() }
                return facts
            }
            lock.lock(); cancelled = true; lock.unlock()
            return nil
        }
    }

    /// `wait` for a caller already on main (the mailbox doorbell): it suspends between looks instead of
    /// blocking a thread, and its looks never block.
    @MainActor
    static func waitOnMain(baseline: Facts, deadline: Date, look: @MainActor () -> Facts?) async -> Verdict {
        let interval = Double(pollNanoseconds) / 1_000_000_000
        while true {
            let before = deadline.timeIntervalSinceNow
            guard before > 0, !Task.isCancelled else { return .unconfirmed("no_turn_start") }
            var final = before < interval * 1.5
            if !final {
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                // A late wake is the last look; the look itself never blocks.
                final = deadline.timeIntervalSinceNow < interval * 0.5
            }
            guard let facts = look() else {
                if final { return .unconfirmed("no_turn_start") }
                continue
            }
            let verdict = judge(baseline: baseline, now: facts, final: final)
            if verdict != .pending { return verdict }
            if final { return .unconfirmed("no_turn_start") }
        }
    }

    /// One look after the Return. `final` is the last look before the bound.
    ///
    /// The composer outranks everything: a line still in it was not taken, whatever else moved. A turn already
    /// open at the baseline is the agent's own work, so its edges prove nothing about this line; only the
    /// composer can. An empty composer counts only from a frame drawn after the baseline.
    static func judge(baseline: Facts, now: Facts, final: Bool) -> Verdict {
        if now.prompt == .draft { return final ? .unconfirmed("composer_holds_text") : .pending }
        let turnWasOpen = baseline.journalTurnOpen || baseline.hcTurnOpen
        if !turnWasOpen, let evidence = turnEvidence(baseline: baseline, now: now) { return .confirmed(evidence) }
        let staleFrame = now.frame != nil && now.frame == baseline.frame
        switch now.prompt {
        case .empty?, .suggestion?:
            if !staleFrame { return .confirmed("composer_empty") }
            return final ? .unconfirmed("no_turn_start") : .pending
        case .dialog?:
            return final ? .unconfirmed("dialog") : .pending
        case .draft?, .unknown?, .unavailable?, nil:
            return final ? .unconfirmed("no_turn_start") : .pending
        }
    }

    /// The agent's own record of a turn that started after the baseline, or nil.
    ///
    /// Journal evidence needs a journal the baseline already saw. A journal that first becomes live during the
    /// wait (a restored panel's snapshot leaving history, a reconnect republishing retained state) shows the
    /// state it already had, which proves no new turn.
    private static func turnEvidence(baseline: Facts, now: Facts) -> String? {
        if baseline.journalPhase != nil {
            if now.journalTurnOpen,
               !baseline.journalTurnOpen || (now.journalSinceMs ?? 0) > (baseline.journalSinceMs ?? 0) {
                return "journal_turn"
            }
            // A whole turn already came and went between looks: the journal is idle again under a new turn
            // identity, compared with an identity the baseline held. A newer time alone is not a turn: hc can
            // fill in the retained time of the same status and turn after a reconnect, with no input taken.
            if now.journalPhase == .idle, let before = baseline.journalTurnID, let turn = now.journalTurnID,
               turn != before {
                return "journal_turn"
            }
        }
        if now.hcTurnOpen,
           !baseline.hcTurnOpen || (now.hcStatusMs ?? 0) > (baseline.hcStatusMs ?? 0) {
            return "hc_status"
        }
        if let turn = now.hcTurn, turn > (baseline.hcTurn ?? turn) { return "hc_turn" }
        return nil
    }
}
