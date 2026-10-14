import Foundation

/// Per-panel queue of mailbox envelopes waiting for a doorbell ring.
///
/// The dispatcher copies each envelope into the recipient's inbox before this
/// queue sees it. The ring types one invitation line. It does not paste a
/// `<c11-msg>` block and it does not claim the file. `c11 mailbox recv --ack`
/// and Claude's Stop hook are what move the file to `_read/`.
///
/// **Agent panels.** The shell stays `.commandRunning` for the life of the
/// TUI, so the gate is the agent's own turn edge (`report_agent_activity`,
/// hooks, the Codex turn-complete notify, transcript turn ends, and every
/// submit Return):
///
///   - at its prompt, and the prompt edge is newer than the last submit →
///     the prompt is open and the doorbell may ring;
///   - mid-turn → the envelope stays queued until the next prompt edge. A
///     turn holds while the journal says it is in progress (a long tool call
///     with no output included), or while its working edge or submit is
///     younger than `unsupportedWorkingDecay`;
///   - no turn edge since the agent attached, or a working state nothing
///     supports any more → unknown. Unknown may ring, and the ring still
///     needs the screen to show an empty composer (C11-398);
///   - an operator key does not close the prompt. The doorbell waits out a
///     short quiet window, then rings if the composer is still empty.
///
/// **Nothing else is typed into.** A line plus Return into a shell, `vim`,
/// a pipeline, or an agent that is not reading its terminal would run or
/// corrupt whatever is there. The ring types only into an interactive agent
/// (its wrapper's `C11_AGENT_INTERACTIVE_PID`) whose process group the kernel
/// reports as the terminal's foreground (`MailboxAgentForeground`). Mail for
/// any other panel stays in the inbox. A shell prompt edge drops this queue
/// and types nothing. The inbox keeps the envelopes.
///
/// **Pure and clock-injected.** No PTY and no `Workspace` instance. Production
/// mutates this on the main actor.
struct MailboxStdinBuffer {

    /// One queued envelope. `block` is the framed text kept for the dispatch
    /// log. The ring does not type it.
    struct Entry: Equatable {
        let id: String
        let recipientName: String
        let block: String
        let bufferedAt: Date
    }

    /// The last agent turn edge c11 saw for a panel.
    struct AgentTurn: Equatable {
        var atPrompt: Bool
        var since: Date
    }

    /// What a queue drop is reacting to. An agent prompt rings. A shell
    /// prompt drops the queue and types nothing.
    enum FlushTrigger: Equatable {
        case agentPrompt
        case shellPrompt
    }

    /// What the turn clock allows. `unknown` may ring only through the same
    /// screen read as `open`.
    enum PromptGate: Equatable {
        case open
        case unknown
        case closed
    }

    /// Max queued entries per panel. A broadcast storm into a busy panel
    /// can't grow the queue without bound; the oldest is evicted and the
    /// inbox still holds it.
    static let perSurfaceCap = 64

    /// A working edge or submit with no journal turn behind it holds the gate
    /// this long, then reads as unknown. A real turn start reaches the journal
    /// within seconds (a hook at once, a transcript poll within 10 s).
    static let unsupportedWorkingDecay: TimeInterval = 120

    private var queues: [UUID: [Entry]] = [:]
    private var turns: [UUID: AgentTurn] = [:]
    private var lastSubmitAt: [UUID: Date] = [:]
    /// The newest agent report or attach, deduplicated or not. A Return is
    /// only taken back while nothing from the agent has arrived since.
    private var lastReportedAt: [UUID: Date] = [:]
    /// When the agent's session last started or re-attached.
    private var attachedAt: [UUID: Date] = [:]
    /// The interactive agent process each panel's turn edges came from
    /// (`C11_AGENT_INTERACTIVE_PID`). A ring types only while this process's
    /// group owns the panel's terminal.
    private var agentPids: [UUID: AgentProcess] = [:]

    /// An interactive agent process, pinned by its start time so a later
    /// process that reuses the PID (an editor, a shell) is never mistaken
    /// for it.
    struct AgentProcess: Equatable {
        let pid: pid_t
        let startTime: UInt64?
    }

    /// Whether the doorbell may look at the screen. `open`: the agent
    /// reported its prompt. `closed`: not an agent that owns its terminal, or
    /// a turn some signal still supports. `unknown`: nothing says the agent is
    /// mid-turn. An operator key newer than the last submit does not close
    /// the prompt: the doorbell waits out that key, then rings.
    ///
    /// `journalTurnOpen` is the journal's live working or blocked phase. It
    /// is what holds a long tool call that prints nothing.
    func promptGate(
        surfaceId: UUID,
        isAgentKind: Bool,
        agentOwnsTerminal: Bool,
        journalTurnOpen: Bool,
        now: Date
    ) -> PromptGate {
        guard agentOwnsTerminal, isAgent(surfaceId: surfaceId, isAgentKind: isAgentKind) else {
            return .closed
        }
        if let turn = turns[surfaceId], turn.atPrompt { return .open }
        if journalTurnOpen { return .closed }
        if let deadline = workingDecayDeadline(surfaceId: surfaceId), now < deadline { return .closed }
        return .unknown
    }

    /// When an unsupported working edge or submit stops holding the gate.
    /// Nil when there is none. The caller looks again at this time.
    func workingDecayDeadline(surfaceId: UUID) -> Date? {
        var newest = lastSubmitAt[surfaceId]
        if let turn = turns[surfaceId], !turn.atPrompt {
            newest = max(newest ?? turn.since, turn.since)
        }
        return newest?.addingTimeInterval(Self.unsupportedWorkingDecay)
    }

    func isAgent(surfaceId: UUID, isAgentKind: Bool) -> Bool {
        isAgentKind || turns[surfaceId] != nil
    }

    // MARK: - Agent turn edges

    /// An explicit lifecycle report: the agent reached its prompt
    /// (`atPrompt: true`) or started working. A prompt edge stamped before the
    /// newest submit is stale: the agent has had input since. A transcript
    /// turn end carries the agent's own clock, so one polled late is caught
    /// here; hook and wrapper edges are stamped when c11 receives them.
    mutating func noteAgentTurn(surfaceId: UUID, atPrompt: Bool, at now: Date) {
        lastReportedAt[surfaceId] = max(lastReportedAt[surfaceId] ?? now, now)
        setTurn(surfaceId: surfaceId, atPrompt: atPrompt, at: now)
    }

    private mutating func setTurn(surfaceId: UUID, atPrompt: Bool, at now: Date) {
        if atPrompt, let lastSubmit = lastSubmitAt[surfaceId], now < lastSubmit { return }
        if let current = turns[surfaceId], current.atPrompt == atPrompt { return }
        turns[surfaceId] = AgentTurn(atPrompt: atPrompt, since: now)
    }

    /// A submit Return reached the panel (operator, text box, `c11 send`, or
    /// a ring). `at` is the Return's own event time, captured where the key
    /// was handled: the edge reaches this buffer after an off-main hop, and a
    /// keystroke typed in between must still read as a draft. For a known
    /// agent, starts a turn.
    mutating func noteSubmit(surfaceId: UUID, at eventAt: Date) {
        lastSubmitAt[surfaceId] = max(lastSubmitAt[surfaceId] ?? .distantPast, eventAt)
        if let turn = turns[surfaceId], eventAt >= turn.since {
            setTurn(surfaceId: surfaceId, atPrompt: false, at: eventAt)
        }
    }

    /// The turn state just before a socket Return lands on a composer that
    /// reads empty or a suggestion (C11-407).
    struct NoOpReturnMark: Equatable {
        let at: Date
        let turn: AgentTurn?
        let lastSubmit: Date?
    }

    func noOpReturnMark(surfaceId: UUID, at: Date) -> NoOpReturnMark {
        NoOpReturnMark(at: at, turn: turns[surfaceId], lastSubmit: lastSubmitAt[surfaceId])
    }

    /// Take back the submit edges a socket Return recorded when the composer
    /// showed it started no turn. Only while nothing else moved the turn: no
    /// agent report or attach since the mark, and the turn is the one the
    /// mark saw or the working state those submits made. A prompt the mark
    /// saw comes back as a new idle period, so mail that arrived after the
    /// Return is not skipped as already rung. True when it took them back.
    mutating func retractNoOpReturn(surfaceId: UUID, mark: NoOpReturnMark, now: Date) -> Bool {
        guard let submitted = lastSubmitAt[surfaceId], submitted >= mark.at,
              (lastReportedAt[surfaceId] ?? .distantPast) < mark.at else { return false }
        let current = turns[surfaceId]
        let movedBySubmit = current.map { !$0.atPrompt && $0.since >= mark.at } ?? false
        guard current == mark.turn || movedBySubmit else { return false }
        lastSubmitAt[surfaceId] = mark.lastSubmit
        if let turn = mark.turn, turn.atPrompt {
            turns[surfaceId] = AgentTurn(atPrompt: true, since: max(now, submitted))
        } else {
            turns[surfaceId] = mark.turn
        }
        return true
    }

    /// A session started or re-attached at `at` (`JournalMailboxBoundary`
    /// `attached`). Turn edges and submits from before it describe an earlier
    /// process, or the Return that launched this one, so the turn is unknown
    /// again. A newer edge stays.
    mutating func noteAgentAttached(surfaceId: UUID, at: Date) {
        lastReportedAt[surfaceId] = max(lastReportedAt[surfaceId] ?? at, at)
        attachedAt[surfaceId] = max(attachedAt[surfaceId] ?? at, at)
        if let turn = turns[surfaceId], turn.since <= at {
            turns.removeValue(forKey: surfaceId)
        }
        if let submit = lastSubmitAt[surfaceId], submit <= at {
            lastSubmitAt.removeValue(forKey: surfaceId)
        }
    }

    /// The panel's shell is back at its prompt: whatever agent ran there has
    /// exited, so its turn edges no longer describe the panel.
    mutating func forgetAgent(surfaceId: UUID) {
        turns.removeValue(forKey: surfaceId)
        lastReportedAt.removeValue(forKey: surfaceId)
        attachedAt.removeValue(forKey: surfaceId)
        agentPids.removeValue(forKey: surfaceId)
    }

    /// Record (or clear, with `nil`) the interactive agent process behind
    /// the panel's turn edges. A report for the PID already recorded keeps its
    /// pinned start time.
    mutating func noteAgentProcess(surfaceId: UUID, process: AgentProcess?) {
        guard let process else {
            agentPids.removeValue(forKey: surfaceId)
            return
        }
        if agentPids[surfaceId]?.pid == process.pid, agentPids[surfaceId]?.startTime != nil { return }
        agentPids[surfaceId] = process
    }

    func agentProcess(surfaceId: UUID) -> AgentProcess? {
        agentPids[surfaceId]
    }

    func agentPid(surfaceId: UUID) -> pid_t? {
        agentPids[surfaceId]?.pid
    }

    func agentTurn(surfaceId: UUID) -> AgentTurn? {
        turns[surfaceId]
    }

    /// The ring's idle period. A turn edge names it. With none, each attach
    /// is its own period, so a ring before a `/clear` or a second resume does
    /// not hold the mail that follows it.
    func ringEpoch(surfaceId: UUID) -> String {
        if let turn = turns[surfaceId] {
            return MailboxDoorbell.promptEpoch(since: turn.since, atPrompt: turn.atPrompt)
        }
        guard let attached = attachedAt[surfaceId] else { return "none" }
        return "\(Int64((attached.timeIntervalSince1970 * 1000).rounded()))|attach"
    }

    // MARK: - Queue

    /// Append an entry. Returns the evicted entry when the cap was exceeded
    /// (oldest dropped), else `nil`.
    @discardableResult
    mutating func enqueue(surfaceId: UUID, entry: Entry) -> Entry? {
        var queue = queues[surfaceId] ?? []
        queue.append(entry)
        var evicted: Entry?
        if queue.count > Self.perSurfaceCap {
            evicted = queue.removeFirst()
        }
        queues[surfaceId] = queue
        return evicted
    }

    func queuedEntries(surfaceId: UUID) -> [Entry] {
        queues[surfaceId] ?? []
    }

    /// Drop the queue only. Turn edges stay. A shell prompt uses this so a
    /// later ring cannot type into the shell. The inbox still holds the mail.
    mutating func takeQueue(surfaceId: UUID) -> [Entry] {
        queues.removeValue(forKey: surfaceId) ?? []
    }

    /// Remove one queued envelope. The inbox copy is untouched.
    mutating func removeQueued(surfaceId: UUID, id: String) -> Entry? {
        guard var queue = queues[surfaceId],
              let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = queue.remove(at: index)
        if queue.isEmpty {
            queues.removeValue(forKey: surfaceId)
        } else {
            queues[surfaceId] = queue
        }
        return removed
    }

    /// Drop a panel's queue outright (panel closed). Returns any entries
    /// that were pending so the caller can log the drop; the inbox still
    /// holds them.
    @discardableResult
    mutating func removeSurface(_ surfaceId: UUID) -> [Entry] {
        turns.removeValue(forKey: surfaceId)
        lastSubmitAt.removeValue(forKey: surfaceId)
        lastReportedAt.removeValue(forKey: surfaceId)
        attachedAt.removeValue(forKey: surfaceId)
        agentPids.removeValue(forKey: surfaceId)
        return queues.removeValue(forKey: surfaceId) ?? []
    }

    /// Prune queues for panels no longer present.
    mutating func retainOnly(surfaceIds: Set<UUID>) {
        queues = queues.filter { surfaceIds.contains($0.key) }
        turns = turns.filter { surfaceIds.contains($0.key) }
        lastSubmitAt = lastSubmitAt.filter { surfaceIds.contains($0.key) }
        lastReportedAt = lastReportedAt.filter { surfaceIds.contains($0.key) }
        attachedAt = attachedAt.filter { surfaceIds.contains($0.key) }
        agentPids = agentPids.filter { surfaceIds.contains($0.key) }
    }

    func pendingCount(surfaceId: UUID) -> Int {
        queues[surfaceId]?.count ?? 0
    }

    var isEmpty: Bool {
        queues.values.allSatisfy { $0.isEmpty }
    }
}

/// Class box so the delivery sequence can mutate the buffer and then ring
/// without an `inout` that overlaps the ring. Workspace holds one of these.
final class MailboxStdinBufferStore {
    var buffer = MailboxStdinBuffer()
    var doorbell = MailboxDoorbell.Ledgers()
}

/// Admit one envelope onto the doorbell queue. Tests call `deliver`; they
/// do not restage it. Nothing here pastes a block or claims the inbox file.
enum MailboxStdinDelivery {
    struct Gate: Equatable {
        var panelPresent: Bool = true
        var isAgentKind: Bool = true
        var ownsTerminal: Bool = false
        var lastOperatorKeyAt: Date? = nil
        var inputTransactionActive: Bool = false
        var inputTransactionEpoch: UInt64 = 0
        var surfaceAttached: Bool = true
        /// The journal is live and its phase is working or blocked.
        var journalTurnOpen: Bool = false
        var now: Date = Date()
    }

    struct LogLine {
        var entry: MailboxStdinBuffer.Entry
        var outcome: MailboxDispatchLog.HandlerOutcome
        var bytes: Int?
    }

    enum AdmitResult: Equatable {
        case ok(bytes: Int)
        case buffered(bytes: Int)
        /// The doorbell line, or a wait. A `.keep` stays `.buffered`.
        /// The block is never pasted.
        case doorbell(bytes: Int, effect: MailboxDoorbell.Arrival)
    }

    /// A reported lifecycle edge. An idle edge is the only one that flushes.
    static func noteReported(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        activity: SidebarActivityState,
        at eventAt: Date,
        agentPid: pid_t?,
        processStartTime: UInt64?,
        flush: () -> Void
    ) {
        if let agentPid {
            state.buffer.noteAgentProcess(
                surfaceId: surfaceId,
                process: .init(pid: agentPid, startTime: processStartTime)
            )
        }
        state.buffer.noteAgentTurn(surfaceId: surfaceId, atPrompt: activity == .idle, at: eventAt)
        if activity == .idle {
            flush()
        }
    }

    /// Admit one envelope: enqueue it, and ring when the agent is at its
    /// prompt or its turn is unknown. Nothing is pasted. The inbox copy is not
    /// claimed here.
    ///
    /// A live agent TUI keeps the shell `.commandRunning` for life, so that is
    /// never turn evidence. Mid-turn this gate only enqueues; a turn held only
    /// by its decay window reports the deadline through `noteHeldUntil`. The
    /// Bool asks for a prompt-screen read; callers pass false first.
    static func deliver(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        entry: MailboxStdinBuffer.Entry,
        gate: Gate,
        logEvicted: (MailboxStdinBuffer.Entry) -> Void,
        ringInput: ((Bool) -> MailboxDoorbell.Input)? = nil,
        noteRing: ((MailboxDoorbell.Decision, MailboxDoorbell.Arrival) -> Void)? = nil,
        noteHeldUntil: ((Date) -> Void)? = nil,
        noteInputTransactionHeld: (() -> Void)? = nil
    ) -> AdmitResult {
        if let evicted = state.buffer.enqueue(surfaceId: surfaceId, entry: entry) {
            logEvicted(evicted)
        }
        let bytes = entry.block.utf8.count
        let promptGate = state.buffer.promptGate(
            surfaceId: surfaceId,
            isAgentKind: gate.isAgentKind,
            agentOwnsTerminal: gate.ownsTerminal,
            journalTurnOpen: gate.journalTurnOpen,
            now: gate.now
        )
        if promptGate == .closed, let deadline = heldUntil(state: state, surfaceId: surfaceId, gate: gate) {
            noteHeldUntil?(deadline)
        }
        if gate.inputTransactionActive {
            noteInputTransactionHeld?()
            return .buffered(bytes: bytes)
        }
        guard promptGate != .closed, let ringInput else {
            return .buffered(bytes: bytes)
        }
        var input = ringInput(false)
        if MailboxDoorbell.needsPrompt(input) {
            input = ringInput(true)
        }
        let ring = MailboxDoorbell.decide(input)
        let effect = MailboxDoorbell.arrival(for: ring)
        noteRing?(ring, effect)
        switch effect {
        case .keep:
            return .buffered(bytes: bytes)
        case .ring, .deferRing:
            return .doorbell(bytes: bytes, effect: effect)
        }
    }

    /// A live journal in a working or blocked phase: the harness says a turn
    /// is in progress, however long it has been quiet. A restored or ended
    /// row says nothing about the process running now.
    static func journalTurnOpen(_ snapshot: JournalSnapshot?) -> Bool {
        guard let snapshot, !snapshot.isHistorical else { return false }
        return snapshot.phase == .working || snapshot.phase == .blocked
    }

    /// Codex can publish `turn_aborted` and the following `task_started` as
    /// separate events. Hold a doorbell through that brief idle transition.
    static func journalInterruptionSettling(_ snapshot: JournalSnapshot?, now: Date) -> Bool {
        guard let snapshot, snapshot.owner.agentKind == "codex",
              snapshot.adapter == .codexTranscript, !snapshot.isHistorical,
              snapshot.phase == .idle, snapshot.turnOutcome == "interrupted" else { return false }
        let ageMs = Int64(now.timeIntervalSince1970 * 1_000) - snapshot.observedAtMs
        return ageMs >= 0 && ageMs < 1_000
    }

    /// The decay deadline when only an unsupported working edge or submit
    /// closes the gate. Nil when the gate is closed for any other reason (a
    /// live journal turn, a panel that is not an agent's) and the next edge
    /// reopens it.
    static func heldUntil(state: MailboxStdinBufferStore, surfaceId: UUID, gate: Gate) -> Date? {
        guard gate.ownsTerminal, !gate.journalTurnOpen,
              state.buffer.isAgent(surfaceId: surfaceId, isAgentKind: gate.isAgentKind),
              state.buffer.agentTurn(surfaceId: surfaceId)?.atPrompt != true,
              let deadline = state.buffer.workingDecayDeadline(surfaceId: surfaceId),
              gate.now < deadline else { return nil }
        return deadline
    }
}

/// Who the kernel says is reading a terminal. The mailbox push types into an
/// agent tab only while the agent's own process group is the foreground
/// process group of the agent's controlling terminal, and that terminal is
/// the tab's. One `sysctl(KERN_PROC_PID)` per check; no file I/O.
enum MailboxAgentForeground {

    /// The fields of `kinfo_proc` the check needs.
    struct ProcessTerminalInfo: Equatable {
        /// The process's own process group.
        let processGroup: pid_t
        /// The foreground process group of its controlling terminal.
        let terminalForegroundGroup: pid_t
        /// Its controlling terminal (`NODEV` when it has none).
        let terminalDevice: dev_t
        let isZombie: Bool
        /// Process start time in microseconds since the epoch.
        var startTime: UInt64 = 0
    }

    /// Pure decision. Fails closed on a missing process, a different process
    /// reusing the registered PID (start time mismatch), a zombie, no
    /// controlling terminal, a non-foreground group, a tab tty c11 does not
    /// know (nil) or that differs from the agent's, and a terminal in
    /// canonical (line) mode. An interactive TUI waiting for input holds its
    /// tty non-canonical; a print or one-shot run leaves it canonical, and
    /// anything typed there would be read by the shell after it exits. That
    /// last check needs no argv parsing, so it covers every one-shot form a
    /// wrapper does not recognize. `terminalIsCanonical` nil (unreadable)
    /// fails closed too.
    static func agentOwnsTerminal(
        _ info: ProcessTerminalInfo?,
        expectedStartTime: UInt64?,
        panelTerminalDevice: dev_t?,
        terminalIsCanonical: Bool?
    ) -> Bool {
        guard let info, !info.isZombie,
              // Still the process that registered, not a later PID reuse.
              let expectedStartTime, info.startTime == expectedStartTime,
              info.terminalDevice != -1,  // NODEV: no controlling terminal
              info.processGroup > 0,
              info.terminalForegroundGroup == info.processGroup,
              let panelTerminalDevice, panelTerminalDevice == info.terminalDevice,
              terminalIsCanonical == false else { return false }
        return true
    }

    /// Whether the terminal at `path` is in canonical (line) mode, read with
    /// `tcgetattr` on a non-blocking, non-controlling read-only descriptor.
    /// `nil` when it cannot be opened or read.
    static func terminalIsCanonical(path: String) -> Bool? {
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var attrs = termios()
        guard tcgetattr(fd, &attrs) == 0 else { return nil }
        return (attrs.c_lflag & tcflag_t(ICANON)) != 0
    }

    /// Live read for `pid`, or nil when the process does not exist.
    static func processTerminalInfo(pid: pid_t) -> ProcessTerminalInfo? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return ProcessTerminalInfo(
            processGroup: info.kp_eproc.e_pgid,
            terminalForegroundGroup: info.kp_eproc.e_tpgid,
            terminalDevice: info.kp_eproc.e_tdev,
            isZombie: Int32(info.kp_proc.p_stat) == SZOMB,
            startTime: UInt64(info.kp_proc.p_starttime.tv_sec) * 1_000_000
                + UInt64(info.kp_proc.p_starttime.tv_usec)
        )
    }

    /// Live check for a registered agent process against the tab's tty name. A tab
    /// whose tty c11 has not been told (no shell-integration `report_tty`)
    /// cannot be verified and never receives a push.
    static func agentOwnsTerminal(process: MailboxStdinBuffer.AgentProcess?, panelTTYName: String?) -> Bool {
        guard let process, let panelTTYName else { return false }
        let path = panelTTYName.hasPrefix("/") ? panelTTYName : "/dev/\(panelTTYName)"
        guard let panelDevice = TerminalPIDResolver.ttyDevice(for: path) else { return false }
        let info = processTerminalInfo(pid: process.pid)
        // The process checks first: the termios read opens the device.
        guard agentOwnsTerminal(
            info, expectedStartTime: process.startTime,
            panelTerminalDevice: panelDevice, terminalIsCanonical: false
        ) else { return false }
        return agentOwnsTerminal(
            info, expectedStartTime: process.startTime,
            panelTerminalDevice: panelDevice, terminalIsCanonical: terminalIsCanonical(path: path)
        )
    }
}

/// C11-407. A socket Return on a composer that holds nothing to submit
/// (empty, or only a suggestion, by the panel's own reader) starts no turn,
/// but it is recorded as a submit and closes the ring gate. The socket
/// path reads the composer before the Return, which is not the operator's
/// typing path, and looks again after `settle`: an unchanged composer and no
/// agent report in between mean no turn started, so that submit is taken
/// back. A keystroke Return is never read here.
enum MailboxNoOpReturn {
    /// How long after the Return the composer is read again. A real submit
    /// clears or changes it within a frame or two.
    static let settle: TimeInterval = 1.0

    struct Probe: Equatable {
        let region: PromptRegionSnapshot
        let mark: MailboxStdinBuffer.NoOpReturnMark
    }

    /// A composer a Return cannot submit from.
    static func admits(_ state: PromptInputState) -> Bool {
        state == .empty || state == .suggestion
    }

    /// A socket Return waits for the paste-settle delay. Refresh its no-op
    /// probe at that boundary so text the operator entered during the wait
    /// cannot later be mistaken for an empty submit and reopened as idle.
    /// A bare socket Return that was safe at dispatch time is suppressed if
    /// the fresh composer read can no longer prove it is empty or a suggestion.
    static func shouldSubmitDelayedReturn(initial: Probe?, recapture: () -> Probe?) -> Bool {
        guard initial != nil else { return true }
        return recapture() != nil
    }

    /// The Return changed nothing on screen: the same complete capture, cell
    /// for cell, with the cursor where it was. Any change keeps the submit.
    static func unchanged(before: PromptRegionSnapshot, after: PromptRegionSnapshot) -> Bool {
        before.complete && after.complete && before == after
    }

    /// Take the submit back only when the composer still reads empty or a
    /// suggestion, nothing on screen changed, and the journal shows no turn.
    static func shouldRetract(
        probe: Probe,
        after: PromptRegionSnapshot?,
        afterState: PromptInputState?,
        journalTurnOpen: Bool
    ) -> Bool {
        guard !journalTurnOpen, let after, let afterState, admits(afterState) else { return false }
        return unchanged(before: probe.region, after: after)
    }
}
