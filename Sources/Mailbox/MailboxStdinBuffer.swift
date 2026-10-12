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
///   - mid-turn, or no turn edge yet → the envelope stays queued until the
///     next prompt edge;
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

    /// Max queued entries per panel. A broadcast storm into a busy panel
    /// can't grow the queue without bound; the oldest is evicted and the
    /// inbox still holds it.
    static let perSurfaceCap = 64

    private var queues: [UUID: [Entry]] = [:]
    private var turns: [UUID: AgentTurn] = [:]
    private var lastSubmitAt: [UUID: Date] = [:]
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

    /// The agent is at its prompt and could be typed into. An operator key
    /// newer than the last submit does not close this: the doorbell waits
    /// out that key, then rings.
    func promptIsOpen(
        surfaceId: UUID,
        isAgentKind: Bool,
        agentOwnsTerminal: Bool
    ) -> Bool {
        guard agentOwnsTerminal, isAgent(surfaceId: surfaceId, isAgentKind: isAgentKind) else {
            return false
        }
        guard let turn = turns[surfaceId], turn.atPrompt else { return false }
        return true
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
            noteAgentTurn(surfaceId: surfaceId, atPrompt: false, at: eventAt)
        }
    }

    /// The panel's shell is back at its prompt: whatever agent ran there has
    /// exited, so its turn edges no longer describe the panel.
    mutating func forgetAgent(surfaceId: UUID) {
        turns.removeValue(forKey: surfaceId)
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
        agentPids.removeValue(forKey: surfaceId)
        return queues.removeValue(forKey: surfaceId) ?? []
    }

    /// Prune queues for panels no longer present.
    mutating func retainOnly(surfaceIds: Set<UUID>) {
        queues = queues.filter { surfaceIds.contains($0.key) }
        turns = turns.filter { surfaceIds.contains($0.key) }
        lastSubmitAt = lastSubmitAt.filter { surfaceIds.contains($0.key) }
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
    /// prompt. `push` is never called. The inbox copy is not claimed here.
    ///
    /// A live agent TUI keeps the shell `.commandRunning` for life. Without
    /// a prompt edge this gate only enqueues. The Bool asks for a
    /// prompt-screen read; callers pass false first.
    static func deliver(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        entry: MailboxStdinBuffer.Entry,
        gate: Gate,
        logEvicted: (MailboxStdinBuffer.Entry) -> Void,
        push: (_ immediateId: String?) -> Void,
        ringInput: ((Bool) -> MailboxDoorbell.Input)? = nil,
        noteRing: ((MailboxDoorbell.Decision, MailboxDoorbell.Arrival) -> Void)? = nil
    ) -> AdmitResult {
        if let evicted = state.buffer.enqueue(surfaceId: surfaceId, entry: entry) {
            logEvicted(evicted)
        }
        let bytes = entry.block.utf8.count
        let promptOpen = !gate.inputTransactionActive && state.buffer.promptIsOpen(
            surfaceId: surfaceId,
            isAgentKind: gate.isAgentKind,
            agentOwnsTerminal: gate.ownsTerminal
        )
        // `push` stays in the signature so a regression that pastes a block
        // is visible to tests. Delivery does not call it.
        _ = push
        guard promptOpen, let ringInput else {
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
