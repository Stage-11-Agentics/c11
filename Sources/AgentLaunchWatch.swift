import Foundation
#if DEBUG
import Bonsplit
#endif

/// Pathfinder (2026-11-03): did a launched agent actually start? Both of Atin's
/// first launches onto linked machines failed on screen ("You've hit your weekly
/// limit", "claude: command not found") while c11 showed "Awaiting first task".
/// For a short window after every agent launch, c11 reads the new panel's
/// screen for known failure signatures and its journal for a turn edge, and
/// says plainly what happened. This is the pure part: no AppKit, no clock.
enum AgentLaunchWatch {
    enum Verdict: String, Equatable, Sendable {
        /// Still watching.
        case pending
        /// The agent is up: a turn ended, it has worked a while, or its composer is ready.
        case ready
        /// A failure signature is on screen; the agent did not start.
        case failed
        /// The agent is up but stopped on a question only the operator can answer.
        case needsOperator = "needs_operator"
        /// The window ended with no failure and no sign of the agent either.
        case quiet
    }

    enum Cause: String, Equatable, Sendable {
        case notInstalled = "not_installed"
        case usageLimit = "usage_limit"
        case notLoggedIn = "not_logged_in"
        case apiError = "api_error"
        case trustFolder = "trust_folder"

        var verdict: Verdict { self == .trustFolder ? .needsOperator : .failed }
    }

    struct Finding: Equatable, Sendable {
        let cause: Cause
        /// The screen line that matched, trimmed and capped.
        let line: String
    }

    /// How long a launch is watched before it is left alone.
    static let window: TimeInterval = 60
    /// After a "needs operator" finding, how long c11 keeps watching for the
    /// agent to come up, so it can clear its own note.
    static let operatorWindow: TimeInterval = 180
    /// A prompted agent that has been in its first turn this long with no
    /// failure on screen is working, not failing.
    static let workingSettle: TimeInterval = 8

    /// Scan a screen for failure signatures, matched only in the forms the
    /// shell and Claude Code draw them, anchored at a line's start, so prose
    /// that mentions them ("let me check the API error") never matches.
    ///
    /// Before the agent is known to run, a line may start with the phrase
    /// itself or after Claude's markers (`⏺`, `⎿`, `●`, `│`), and the shell's
    /// "command not found" counts when it names `binary` (the launch line's
    /// command). Once a turn has started, the transcript is the agent's: only
    /// Claude's own error forms behind its `⏺`/`⎿`/`●` marker count, and
    /// shell-level signatures never do. A wrapped line is joined with the
    /// next before matching, so `You've hit your` / `weekly limit` matches.
    static func scan(_ screen: String, binary: String?, agentStarted: Bool) -> Finding? {
        var best: (rank: Int, finding: Finding)?
        let bin = binary.map { ($0 as NSString).lastPathComponent.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        let lines = screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            let joined = next.isEmpty ? line : line + " " + next
            guard let hit = match(line, joined: joined, binary: bin, agentStarted: agentStarted) else { continue }
            if best.map({ hit.rank < $0.rank }) ?? true {
                // Shell lines never wrap into the next; only Claude's own lines report joined.
                let shown = hit.cause == .notInstalled ? line : joined
                best = (hit.rank, Finding(cause: hit.cause, line: String(shown.prefix(200))))
            }
        }
        return best?.finding
    }

    /// Claude Code's line markers: the reply bullet (U+23FA, or U+25CF in some
    /// fonts), the result elbow and the box edge.
    private static let replyMarkers: Set<Character> = ["⏺", "●", "⎿"]
    private static let allMarkers: Set<Character> = ["⏺", "●", "⎿", "│", "❯", ">"]

    private static func match(_ line: String, joined: String, binary: String?, agentStarted: Bool)
        -> (rank: Int, cause: Cause)? {
        let lower = line.lowercased()
        if !agentStarted {
            // zsh: `zsh: command not found: claude`; bash/sh: `bash: claude: command not found`.
            if let binary {
                if lower.hasSuffix("command not found: \(binary)") || lower.hasSuffix("\(binary): command not found") {
                    return (0, .notInstalled)
                }
            } else if lower.hasSuffix("command not found") || lower.contains(": command not found: ") {
                return (0, .notInstalled)
            }
            // The kit's and c11's Claude wrapper: `Error: claude not found in PATH`.
            if lower.hasPrefix("error: "), lower.hasSuffix(" not found in path"),
               binary.map({ lower == "error: \($0) not found in path" }) ?? true {
                return (0, .notInstalled)
            }
        }
        // Strip Claude's markers; once a turn runs, one of its reply markers is required.
        let first = line.first
        if agentStarted, !(first.map { replyMarkers.contains($0) } ?? false) { return nil }
        let body = String(joined.drop { allMarkers.contains($0) || $0 == " " }).lowercased()
        if body.range(of: #"^you(?:'|’|ʼ)ve hit your [a-z0-9 -]{0,24}limit\b"#, options: .regularExpression) != nil {
            return (1, .usageLimit)
        }
        if body.range(of: #"^(?:login expired|not logged in\b(?!\s*to\b)|invalid api key\s*[·∙•]\s*please run /login|please run /login\b)"#,
                      options: .regularExpression) != nil {
            return (2, .notLoggedIn)
        }
        // `⎿  API Error: 500 …` or `API Error (529 …)`; not while Claude says it is retrying.
        if body.range(of: #"^api error(?::| \()"#, options: .regularExpression) != nil, !body.contains("retrying") {
            return (3, .apiError)
        }
        // Claude's folder-trust question (its title line), drawn only before the agent starts.
        if !agentStarted, body.hasPrefix("quick safety check: is this a project you created or one you trust")
            || body.hasPrefix("is this a project you created or one you trust")
            || body.hasPrefix("do you trust the files in this folder") {
            return (4, .trustFolder)
        }
        return nil
    }

    struct Rules: Equatable, Sendable {
        let binary: String?
        /// The launch carried a first prompt, so a ready composer is not yet proof.
        let hasPrompt: Bool
        let startedAt: Date
        let deadline: Date
    }

    struct Observation: Equatable, Sendable {
        var screen: String?
        /// The harness's composer is drawn and waiting (Claude Code only).
        var composerReady = false
        var turnStartedAt: Date?
        var turnEndedAt: Date?
        var now: Date
    }

    struct Outcome: Equatable, Sendable {
        let verdict: Verdict
        let finding: Finding?
        /// What decided it: `turn_ended`, `working`, `composer_ready`, `window_ended`, or the cause.
        let evidence: String
    }

    /// One look. Nil means keep watching.
    static func evaluate(_ observation: Observation, rules: Rules) -> Outcome? {
        // A turn edge from before this launch (a reused panel) is not this agent's.
        let floor = rules.startedAt.addingTimeInterval(-1)
        let turnStarted = observation.turnStartedAt.flatMap { $0 >= floor ? $0 : nil }
        let turnEnded = observation.turnEndedAt.flatMap { $0 >= floor ? $0 : nil }
        let agentStarted = turnStarted != nil || turnEnded != nil || observation.composerReady
        if let screen = observation.screen,
           let finding = scan(screen, binary: rules.binary, agentStarted: agentStarted) {
            return Outcome(verdict: finding.cause.verdict, finding: finding, evidence: finding.cause.rawValue)
        }
        if turnEnded != nil {
            return Outcome(verdict: .ready, finding: nil, evidence: "turn_ended")
        }
        if let turnStarted, observation.now.timeIntervalSince(turnStarted) >= workingSettle {
            return Outcome(verdict: .ready, finding: nil, evidence: "working")
        }
        if !rules.hasPrompt, observation.composerReady {
            return Outcome(verdict: .ready, finding: nil, evidence: "composer_ready")
        }
        if observation.now >= rules.deadline {
            return Outcome(verdict: .quiet, finding: nil, evidence: "window_ended")
        }
        return nil
    }

    /// The one plain sentence the panel's description and flag carry.
    static func sentence(for cause: Cause, agent: String, machine: String, binary: String?, folder: String?) -> String {
        switch cause {
        case .notInstalled:
            return String(format: String(localized: "agentLaunchWatch.notInstalled",
                defaultValue: "%1$@ on %2$@ didn't start: %3$@ is not installed there."),
                agent, machine, binary ?? agent)
        case .usageLimit:
            return String(format: String(localized: "agentLaunchWatch.usageLimit",
                defaultValue: "%1$@ on %2$@ didn't start: its account there hit a usage limit."),
                agent, machine)
        case .notLoggedIn:
            return String(format: String(localized: "agentLaunchWatch.notLoggedIn",
                defaultValue: "%1$@ on %2$@ didn't start: it is not logged in there."),
                agent, machine)
        case .apiError:
            return String(format: String(localized: "agentLaunchWatch.apiError",
                defaultValue: "%1$@ on %2$@ hit an API error while starting."),
                agent, machine)
        case .trustFolder:
            return String(format: String(localized: "agentLaunchWatch.trustFolder",
                defaultValue: "%1$@ on %2$@ is waiting for you to trust %3$@."),
                agent, machine, folder ?? String(localized: "agentLaunchWatch.thisFolder", defaultValue: "this folder"))
        }
    }

    /// `~/x` for a path under `home`, else the path.
    static func abbreviate(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The command a launch line runs: its first word, minus any `KEY=value` prefixes.
    static func binary(ofLaunchLine line: String) -> String? {
        for word in line.split(separator: " ") {
            let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if token.isEmpty || token == "exec" || token == "env" { continue }
            if token.contains("="), !token.hasPrefix("/") { continue }
            return (token as NSString).lastPathComponent
        }
        return nil
    }
}

/// The live half: one main-runloop timer for every watched launch. Each tick
/// looks at no more than `looksPerTick` panels (the ones looked at longest
/// ago), each with one non-blocking viewport read (`try_read_text`: a busy
/// renderer skips the look rather than waiting) and, for an unprompted Claude,
/// one non-blocking prompt-region read. Tick cost is measured against a 2 ms
/// budget, logged in DEBUG and reported as `tick_ms_max`. Verdicts are kept
/// (lock-guarded) so `agent.launch_status` can answer off-main.
@MainActor
final class AgentLaunchWatcher {
    static let shared = AgentLaunchWatcher()

    struct Launch {
        let workspaceId: UUID
        let panelId: UUID
        /// The harness kind (`claude-code`), for the composer classifier.
        let kind: String
        let agentName: String
        let binary: String?
        let hasPrompt: Bool
        /// hc's machine name, or nil for this Mac.
        let machine: String?
        /// The folder the agent was asked to start in, as the operator reads it.
        /// Nil for a remote launch with no explicit folder: the note then names
        /// the folder hc reports the agent in, else "this folder".
        let folder: String?
    }

    struct Report: Sendable {
        let verdict: AgentLaunchWatch.Verdict
        let cause: AgentLaunchWatch.Cause?
        let message: String?
        let line: String?
        let evidence: String?
        let machine: String
        let startedAt: Date
        let decidedAt: Date?
        var tickMsMax: Double = 0

        var payload: [String: Any] {
            var out: [String: Any] = [
                "verdict": verdict.rawValue,
                "machine": machine,
                "seconds": Int(((decidedAt ?? Date()).timeIntervalSince(startedAt)).rounded()),
                "tick_ms_max": (tickMsMax * 100).rounded() / 100,
            ]
            out["cause"] = cause?.rawValue ?? NSNull()
            out["message"] = message ?? NSNull()
            out["line"] = line ?? NSNull()
            out["evidence"] = evidence ?? NSNull()
            return out
        }
    }

    private struct Watch {
        let launch: Launch
        let machineLabel: String
        let startedAt: Date
        var rules: AgentLaunchWatch.Rules
        /// The note c11 wrote on the panel, so it clears only its own.
        var note: String?
        var verdict: AgentLaunchWatch.Verdict = .pending
        var lastLookAt: Date = .distantPast
        var tickMsMax: Double = 0
    }

    private var watches: [UUID: Watch] = [:]
    private var timer: Timer?
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var reports: [UUID: Report] = [:]

    /// Seconds between ticks.
    static let interval: TimeInterval = 1
    /// Panels looked at per tick; with more launches in flight each is looked
    /// at less often instead of the tick growing.
    static let looksPerTick = 3
    /// Lines from the bottom of the viewport that are matched.
    static let bottomLines = 40
    static let tickBudgetMs = 2.0

    func start(_ launch: Launch) {
        let now = Date()
        let machineLabel: String = launch.machine.map {
            MachineRoster.shared.entry(id: $0)?.name ?? HCMachineTarget.displayName($0)
        } ?? String(localized: "agentLaunchWatch.thisMac", defaultValue: "this Mac")
        let rules = AgentLaunchWatch.Rules(binary: launch.binary, hasPrompt: launch.hasPrompt,
                                           startedAt: now, deadline: now.addingTimeInterval(AgentLaunchWatch.window))
        watches[launch.panelId] = Watch(launch: launch, machineLabel: machineLabel, startedAt: now, rules: rules)
        publish(launch.panelId, Report(verdict: .pending, cause: nil, message: nil, line: nil, evidence: nil,
                                       machine: launch.machine ?? "local", startedAt: now, decidedAt: nil))
        if timer == nil {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
                MainActor.assumeIsolated { AgentLaunchWatcher.shared.tick() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// The latest verdict for a launched panel, from any thread.
    nonisolated static func report(panelId: UUID) -> Report? {
        lock.lock(); defer { lock.unlock() }
        return reports[panelId]
    }

    private func publish(_ panelId: UUID, _ report: Report) {
        Self.lock.lock()
        // Keep the table small: verdicts older than ten minutes go.
        let cutoff = Date().addingTimeInterval(-600)
        Self.reports = Self.reports.filter { $0.value.startedAt > cutoff }
        Self.reports[panelId] = report
        Self.lock.unlock()
    }

    private func tick() {
        let tickStart = DispatchTime.now().uptimeNanoseconds
        let now = Date()
        let due = watches.values.sorted { $0.lastLookAt < $1.lastLookAt }.prefix(Self.looksPerTick)
        for watch in due {
            look(at: watch, now: now)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - tickStart) / 1e6
        for id in watches.keys where ms > (watches[id]?.tickMsMax ?? 0) {
            watches[id]?.tickMsMax = ms
        }
#if DEBUG
        dlog("agent.launchWatch.tick watched=\(watches.count) looked=\(due.count) ms=\(String(format: "%.2f", ms))"
             + (ms > Self.tickBudgetMs ? " over_budget" : ""))
#endif
        if watches.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func look(at watch: Watch, now: Date) {
        let panelId = watch.launch.panelId
        watches[panelId]?.lastLookAt = now
        guard let found = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId, preferredWorkspaceId: watch.launch.workspaceId),
              let terminal = found.workspace.terminalPanel(for: panelId) else {
            watches.removeValue(forKey: panelId)
            return
        }
        var observation = AgentLaunchWatch.Observation(now: now)
        observation.turnStartedAt = JournalCoordinator.shared.cachedTurnStartedMs(panelID: panelId).map(Self.date)
        observation.turnEndedAt = JournalCoordinator.shared.cachedLastTurnEndedMs(panelID: panelId).map(Self.date)
        if let surface = terminal.surface.surface {
            if case .success(let bytes) = TerminalController.shared.captureTerminalReadBytes(
                surface: surface, includeScrollback: false, isAbandoned: { false }),
               let viewport = bytes.viewport {
                let text = String(decoding: viewport, as: UTF8.self)
                observation.screen = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .suffix(Self.bottomLines).joined(separator: "\n")
            }
            // Only an unprompted Claude is judged ready by its composer.
            if watch.launch.kind == AgentType.claudeCode.rawValue, !watch.launch.hasPrompt,
               observation.turnStartedAt == nil,
               let region = TerminalController.shared.capturePromptInputRegion(surface: surface, harness: watch.launch.kind) {
                let state = PromptInputClassifier.classify(region, harness: watch.launch.kind).state
                observation.composerReady = state == .empty || state == .suggestion
            }
        }
        guard let outcome = AgentLaunchWatch.evaluate(observation, rules: watch.rules) else { return }
        apply(outcome, to: watches[panelId] ?? watch, workspace: found.workspace, terminal: terminal, now: now)
    }

    private func apply(_ outcome: AgentLaunchWatch.Outcome, to watch: Watch, workspace: Workspace,
                       terminal: TerminalPanel, now: Date) {
        let panelId = watch.launch.panelId
        var watch = watch
        // A question still up on a later look changes nothing: same note, same deadline.
        if outcome.verdict == .needsOperator, watch.verdict == .needsOperator { return }
        var message: String?
        if let finding = outcome.finding {
            message = AgentLaunchWatch.sentence(for: finding.cause, agent: watch.launch.agentName,
                                                machine: watch.machineLabel, binary: watch.launch.binary,
                                                folder: watch.launch.folder ?? Self.remoteFolder(terminal))
        }
        var report = Report(verdict: outcome.verdict, cause: outcome.finding?.cause, message: message,
                            line: outcome.finding?.line, evidence: outcome.evidence,
                            machine: watch.launch.machine ?? "local", startedAt: watch.startedAt, decidedAt: now)
        report.tickMsMax = watch.tickMsMax
        publish(panelId, report)
        switch outcome.verdict {
        case .failed:
            if let message { note(message, workspace: workspace, panelId: panelId) }
            watches.removeValue(forKey: panelId)
        case .needsOperator:
            if let message {
                note(message, workspace: workspace, panelId: panelId)
                watch.note = message
            }
            // Keep watching, once, for the operator's answer: when the agent
            // comes up, c11 clears its own note and lowers its own flag.
            watch.verdict = .needsOperator
            watch.rules = AgentLaunchWatch.Rules(binary: watch.rules.binary, hasPrompt: watch.rules.hasPrompt,
                                                 startedAt: watch.rules.startedAt,
                                                 deadline: now.addingTimeInterval(AgentLaunchWatch.operatorWindow))
            watches[panelId] = watch
        case .ready, .quiet, .pending:
            if let note = watch.note {
                clear(note, workspace: workspace, panelId: panelId, lowerFlag: outcome.verdict == .ready)
            }
            watches.removeValue(forKey: panelId)
        }
#if DEBUG
        dlog("agent.launchWatch panel=\(panelId.uuidString.prefix(8)) verdict=\(outcome.verdict.rawValue) evidence=\(outcome.evidence)")
#endif
    }

    /// Where hc says the remote agent is now; nil (read "this folder") when it
    /// does not say. A remote fallback to home is never named as the folder asked for.
    private static func remoteFolder(_ terminal: TerminalPanel) -> String? {
        guard let cwd = terminal.surface.hcRemoteSource?.record?.foreground?.cwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// The description and a flag, raised by c11 itself (`by: c11`): a
    /// launch that did not start needs the operator, whoever launched it.
    private func note(_ message: String, workspace: Workspace, panelId: UUID) {
        _ = try? PanelMetadataStore.shared.setMetadata(
            workspaceId: workspace.id, surfaceId: panelId,
            partial: [MetadataKey.description: message], mode: .merge, source: .declare)
        workspace.objectWillChange.send()
        workspace.maybeAutoExpandTitleBar(panelId: panelId)
        _ = try? PanelAttentionService.shared.raise(
            workspaceId: workspace.id, surfaceId: panelId, reason: String(message.prefix(256)), by: .c11,
            title: workspace.panelTitle(panelId: panelId))
    }

    /// Clear c11's own note, and on `lowerFlag` its own flag, each only while
    /// it still carries c11's sentence.
    private func clear(_ message: String, workspace: Workspace, panelId: UUID, lowerFlag: Bool) {
        let metadata = PanelMetadataStore.shared.getMetadata(workspaceId: workspace.id, surfaceId: panelId).metadata
        if metadata[MetadataKey.description] as? String == message {
            _ = try? PanelMetadataStore.shared.clearMetadata(
                workspaceId: workspace.id, surfaceId: panelId, keys: [MetadataKey.description], source: .declare)
            workspace.objectWillChange.send()
        }
        if lowerFlag, metadata[MetadataKey.flag] as? String == String(message.prefix(256)) {
            _ = try? PanelAttentionService.shared.lower(workspaceId: workspace.id, surfaceId: panelId, by: .c11)
        }
    }

    private nonisolated static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
