import Foundation

/// Per-tab buffer + gating decision for `stdin` mailbox delivery.
///
/// Pasting a framed `<c11-msg>` block into a recipient PTY is only safe at a
/// moment the recipient will read it as fresh input. Two kinds of recipient:
///
/// **Agent tabs** (Claude Code, Codex, Grok, ...). The agent TUI keeps its
/// shell in one long-running command for life, so the shell state says
/// nothing. The gate is the agent's own turn edge, which c11 learns from
/// explicit lifecycle reports (`report_agent_activity`, hooks, the Codex
/// turn-complete notify), from the turn ends in Codex and Grok transcripts
/// (stamped with the agent's clock), and from every submit Return typed into
/// the tab:
///
///   - at its prompt, no operator draft, and the prompt edge is newer than
///     our last push → inject now;
///   - mid-turn, or no turn edge known yet → buffer, flush at the next
///     prompt edge (one paste, one submitted turn for everything queued);
///   - the operator has typed since the last submit (a draft may sit in the
///     composer) → buffer until the next prompt edge after a submit. There is
///     no quiet-window timeout: a paste after a pause would still splice onto
///     the draft and submit it.
///
/// Notification-driven idleness (a Claude permission prompt, an unread
/// badge) never opens the gate: a paste there answers the prompt.
///
/// **Nothing else is ever typed into.** A paste plus Return into a shell,
/// `vim`, a pipeline or an agent that is not reading its terminal runs or
/// corrupts whatever is there. So the push types only into an interactive
/// agent (its wrapper's `C11_AGENT_INTERACTIVE_PID` on its turn edges) whose
/// process group the kernel reports as the terminal's foreground
/// (`MailboxAgentForeground`). Mail for any other tab, or for an agent that
/// is busy, backgrounded or gone, buffers; a shell prompt edge (the agent
/// exited, or there never was one) drops the buffer. The inbox keeps it all.
///
/// **Doorbell, not delivery.** The dispatcher always copies the envelope into
/// the recipient's filesystem inbox *before* invoking this handler, and the
/// push claims it from there (`MailboxIO.claim`) at inject time. Anything
/// buffered, evicted or expired stays in the inbox for `c11 mailbox recv
/// --drain`.
///
/// **Pure and clock-injected.** No PTY, no `Workspace` instance, no ambient
/// clock. All mutation in production happens on the main actor, so this is a
/// plain value type with no internal locking.
struct MailboxStdinBuffer {

    /// One queued framed block awaiting a safe moment to inject. `block` is the
    /// fully-formatted, XML-escaped `<c11-msg>` string; `id`/`recipientName`
    /// are carried so the flush path can log a coherent `handler` event for
    /// `c11 mailbox trace`.
    struct Entry: Equatable {
        let id: String
        let recipientName: String
        let block: String
        let bufferedAt: Date
    }

    enum Decision: Equatable {
        case injectNow
        case buffer
    }

    /// The last agent turn edge c11 saw for a tab.
    struct AgentTurn: Equatable {
        var atPrompt: Bool
        var since: Date
    }

    /// What the flush is reacting to.
    enum FlushTrigger: Equatable {
        /// The agent reached its prompt: everything queued is deliverable.
        case agentPrompt
        /// The shell returned to its prompt: no agent is reading the
        /// terminal, so everything queued drops (the inbox keeps it).
        case shellPrompt
    }

    /// Result of draining one surface's queue.
    struct FlushResult: Equatable {
        /// Entries to inject, in FIFO order.
        var fresh: [Entry]
        /// Entries dropped from the buffer rather than injected (the inbox +
        /// `recv --drain` floor still owns them).
        var expired: [Entry]
    }

    /// Max queued entries per surface. A broadcast storm into a busy surface
    /// can't grow the buffer without bound; the oldest is evicted (and the
    /// inbox floor still holds it). Generous: real handoff traffic is sparse.
    static let perSurfaceCap = 64

    private var queues: [UUID: [Entry]] = [:]
    private var turns: [UUID: AgentTurn] = [:]
    private var lastSubmitAt: [UUID: Date] = [:]
    private var lastPushAt: [UUID: Date] = [:]
    /// Tabs with a push between its claim and its submit Return. Nothing else
    /// is typed into them until it finishes.
    private var pushesInFlight: Set<UUID> = []
    /// The interactive agent process each tab's turn edges came from
    /// (`C11_AGENT_INTERACTIVE_PID`). A push types only while this process's
    /// group owns the tab's terminal.
    private var agentPids: [UUID: AgentProcess] = [:]

    /// An interactive agent process, pinned by its start time so a later
    /// process that reuses the PID (an editor, a shell) is never mistaken
    /// for it.
    struct AgentProcess: Equatable {
        let pid: pid_t
        let startTime: UInt64?
    }

    /// Inject-now vs buffer for an agent tab. Pure: every input is passed in.
    static func decideAgent(
        turn: AgentTurn?,
        lastSubmitAt: Date?,
        lastOperatorKeyAt: Date?,
        lastPushAt: Date?
    ) -> Decision {
        guard let turn, turn.atPrompt else { return .buffer }
        // Our last push has not produced a turn yet (its Return lands 200 ms
        // after the paste); a second paste now would join the first.
        if let lastPushAt, lastPushAt >= turn.since { return .buffer }
        // A keystroke after the last submit may be sitting in the composer.
        if let lastOperatorKeyAt, lastOperatorKeyAt > (lastSubmitAt ?? .distantPast) {
            return .buffer
        }
        return .injectNow
    }

    /// The full gate for one tab. `isAgentKind` is the tab's detected or
    /// declared terminal type being an agent; a recorded turn edge also marks
    /// the tab as an agent. `agentOwnsTerminal` is the kernel's answer for
    /// the tab's interactive agent process (`MailboxAgentForeground`); the
    /// shell-integration state is deliberately not an input, because it is
    /// not reliable while an agent runs (a launched agent's tab can still
    /// read `promptIdle`).
    func decide(
        surfaceId: UUID,
        isAgentKind: Bool,
        agentOwnsTerminal: Bool,
        lastOperatorKeyAt: Date?,
        ignoringInFlight: Bool = false
    ) -> Decision {
        if !ignoringInFlight, pushesInFlight.contains(surfaceId) { return .buffer }
        // No interactive agent reading the terminal: nothing to type into.
        guard agentOwnsTerminal, isAgent(surfaceId: surfaceId, isAgentKind: isAgentKind) else {
            return .buffer
        }
        return Self.decideAgent(
            turn: turns[surfaceId],
            lastSubmitAt: lastSubmitAt[surfaceId],
            lastOperatorKeyAt: lastOperatorKeyAt,
            lastPushAt: lastPushAt[surfaceId]
        )
    }

    /// What a push does once its claims come back to main. The recipient
    /// must still be the kind it was admitted as: mail admitted at an agent's
    /// prompt is never typed into the shell that agent exited to.
    enum PushVerdict: Equatable {
        /// Type the claimed blocks now.
        case paste
        /// Same recipient, but the gate closed meanwhile (a draft, a new
        /// turn, a command started, the surface detached): undo the claims
        /// and wait for the next edge.
        case requeue
        /// The agent the mail was admitted for has exited: undo the claims
        /// and drop the entries; the inbox keeps them for a drain.
        case drop
    }

    /// Pure re-check after the claim hop. `admittedTurn` is the agent's turn
    /// record when the push was admitted; any change to it means the prompt
    /// the push was admitted for is gone.
    static func pushVerdict(
        admittedAs trigger: FlushTrigger,
        admittedTurn: AgentTurn?,
        turn: AgentTurn?,
        lastSubmitAt: Date?,
        lastOperatorKeyAt: Date?,
        lastPushAt: Date?,
        surfaceAttached: Bool,
        agentOwnsTerminal: Bool = true
    ) -> PushVerdict {
        switch trigger {
        case .agentPrompt:
            // Fail closed: if the agent's process group is not the terminal's
            // foreground reader (it exited, went to the background, or
            // another program such as `vim` or the shell is reading), the
            // mail goes back to the inbox instead of into that reader.
            guard let turn, agentOwnsTerminal else { return .drop }
            guard turn == admittedTurn,
                  decideAgent(
                      turn: turn,
                      lastSubmitAt: lastSubmitAt,
                      lastOperatorKeyAt: lastOperatorKeyAt,
                      lastPushAt: lastPushAt
                  ) == .injectNow else { return .requeue }
        case .shellPrompt:
            // Nothing is ever typed at a shell prompt.
            return .drop
        }
        return surfaceAttached ? .paste : .requeue
    }

    /// `pushVerdict` against this buffer's own clocks for `surfaceId`.
    func pushVerdict(
        surfaceId: UUID,
        admittedAs trigger: FlushTrigger,
        admittedTurn: AgentTurn?,
        lastOperatorKeyAt: Date?,
        surfaceAttached: Bool,
        agentOwnsTerminal: Bool = true
    ) -> PushVerdict {
        Self.pushVerdict(
            admittedAs: trigger,
            admittedTurn: admittedTurn,
            turn: turns[surfaceId],
            lastSubmitAt: lastSubmitAt[surfaceId],
            lastOperatorKeyAt: lastOperatorKeyAt,
            lastPushAt: lastPushAt[surfaceId],
            surfaceAttached: surfaceAttached,
            agentOwnsTerminal: agentOwnsTerminal
        )
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

    /// A submit Return reached the tab (operator, text box, `c11 send`, or a
    /// push). `at` is the Return's own event time, captured where the key was
    /// handled: the edge reaches this buffer after an off-main hop, and a
    /// keystroke typed in between must still read as a draft. Clears any
    /// draft and, for a known agent, starts a turn.
    mutating func noteSubmit(surfaceId: UUID, at eventAt: Date) {
        lastSubmitAt[surfaceId] = max(lastSubmitAt[surfaceId] ?? .distantPast, eventAt)
        if let turn = turns[surfaceId], eventAt >= turn.since {
            noteAgentTurn(surfaceId: surfaceId, atPrompt: false, at: eventAt)
        }
    }

    mutating func notePush(surfaceId: UUID, at now: Date) {
        lastPushAt[surfaceId] = now
    }

    // MARK: - Push in flight

    func isPushInFlight(surfaceId: UUID) -> Bool {
        pushesInFlight.contains(surfaceId)
    }

    mutating func beginPush(surfaceId: UUID) {
        pushesInFlight.insert(surfaceId)
    }

    /// `typedAt` is when the paste went in, when its submit Return was
    /// dispatched; `nil` when nothing reached the tab.
    mutating func endPush(surfaceId: UUID, typedAt: Date?) {
        pushesInFlight.remove(surfaceId)
        if let typedAt { lastPushAt[surfaceId] = typedAt }
    }

    /// Put entries a push claimed but could not type back at the head of
    /// the queue, ahead of anything that arrived meanwhile. Returns the
    /// oldest entries evicted past the cap.
    @discardableResult
    mutating func requeueFront(surfaceId: UUID, entries: [Entry]) -> [Entry] {
        guard !entries.isEmpty else { return [] }
        var queue = entries + (queues[surfaceId] ?? [])
        var evicted: [Entry] = []
        while queue.count > Self.perSurfaceCap {
            evicted.append(queue.removeFirst())
        }
        queues[surfaceId] = queue
        return evicted
    }

    /// The tab's shell is back at its prompt: whatever agent ran there has
    /// exited, so its turn edges no longer describe the tab.
    mutating func forgetAgent(surfaceId: UUID) {
        turns.removeValue(forKey: surfaceId)
        lastPushAt.removeValue(forKey: surfaceId)
        agentPids.removeValue(forKey: surfaceId)
    }

    /// Record (or clear, with `nil`) the interactive agent process behind
    /// the tab's turn edges. A report for the PID already recorded keeps its
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

    /// Append an entry to a surface's FIFO queue. Returns the evicted entry if
    /// the per-surface cap was exceeded (oldest dropped), else `nil`.
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

    /// Remove and partition a surface's queue for a flush. Clears the
    /// surface's queue entirely.
    mutating func drainForFlush(
        surfaceId: UUID,
        now: Date,
        trigger: FlushTrigger
    ) -> FlushResult {
        guard let queue = queues[surfaceId], !queue.isEmpty else {
            return FlushResult(fresh: [], expired: [])
        }
        queues.removeValue(forKey: surfaceId)
        var fresh: [Entry] = []
        var expired: [Entry] = []
        for entry in queue {
            switch trigger {
            case .agentPrompt:
                fresh.append(entry)
            case .shellPrompt:
                expired.append(entry)
            }
        }
        return FlushResult(fresh: fresh, expired: expired)
    }

    /// One paste for a batch of blocks, so a flush submits a single turn.
    static func joinedBlock(_ entries: [Entry]) -> String {
        entries.map(\.block).joined()
    }

    /// Drop a surface's queue outright (surface closed). Returns any entries
    /// that were pending so the caller can log the drop; the inbox floor still
    /// holds them for `recv --drain`.
    @discardableResult
    mutating func removeSurface(_ surfaceId: UUID) -> [Entry] {
        turns.removeValue(forKey: surfaceId)
        lastSubmitAt.removeValue(forKey: surfaceId)
        lastPushAt.removeValue(forKey: surfaceId)
        pushesInFlight.remove(surfaceId)
        agentPids.removeValue(forKey: surfaceId)
        return queues.removeValue(forKey: surfaceId) ?? []
    }

    /// Prune queues for surfaces no longer present (mirrors the metadata prune
    /// the socket fast-path runs).
    mutating func retainOnly(surfaceIds: Set<UUID>) {
        queues = queues.filter { surfaceIds.contains($0.key) }
        turns = turns.filter { surfaceIds.contains($0.key) }
        lastSubmitAt = lastSubmitAt.filter { surfaceIds.contains($0.key) }
        lastPushAt = lastPushAt.filter { surfaceIds.contains($0.key) }
        agentPids = agentPids.filter { surfaceIds.contains($0.key) }
    }

    func pendingCount(surfaceId: UUID) -> Int {
        queues[surfaceId]?.count ?? 0
    }

    var isEmpty: Bool {
        queues.values.allSatisfy { $0.isEmpty }
    }
}

/// Class box so the delivery sequence can mutate the buffer and then flush
/// without an `inout` that overlaps the flush. Workspace holds one of these.
final class MailboxStdinBufferStore {
    var buffer = MailboxStdinBuffer()
}

/// The stdin delivery sequence Workspace runs: admit, idle flush, claim, and
/// the post-claim verdict. Tests call these functions; they do not restage them.
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
    }

    struct Prepared {
        var fresh: [MailboxStdinBuffer.Entry]
        var expired: [MailboxStdinBuffer.Entry]
        var admittedTurn: MailboxStdinBuffer.AgentTurn?
        /// `beginPush` ran because there is something to claim.
        var started: Bool
    }

    enum Step {
        case finished(retry: Bool)
        case undo(entries: [MailboxStdinBuffer.Entry], lines: [LogLine], retry: Bool)
        case paste(entries: [MailboxStdinBuffer.Entry], block: String)
    }

    struct PasteRecord {
        var lines: [LogLine]
        var retry: Bool
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

    /// Admit one block: enqueue, and push immediately when the gate is open.
    static func deliver(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        entry: MailboxStdinBuffer.Entry,
        gate: Gate,
        logEvicted: (MailboxStdinBuffer.Entry) -> Void,
        push: (_ immediateId: String?) -> Void
    ) -> AdmitResult {
        var decision = state.buffer.decide(
            surfaceId: surfaceId,
            isAgentKind: gate.isAgentKind,
            agentOwnsTerminal: gate.ownsTerminal,
            lastOperatorKeyAt: gate.lastOperatorKeyAt
        )
        if gate.inputTransactionActive { decision = .buffer }
        let immediate = decision == .injectNow
            && state.buffer.pendingCount(surfaceId: surfaceId) == 0
        if let evicted = state.buffer.enqueue(surfaceId: surfaceId, entry: entry) {
            logEvicted(evicted)
        }
        if decision == .injectNow {
            push(immediate ? entry.id : nil)
        }
        let bytes = entry.block.utf8.count
        return immediate ? .ok(bytes: bytes) : .buffered(bytes: bytes)
    }

    /// Gate check, drain, and `beginPush`. Nil means the push did not start
    /// and the queue was left in place. `started == false` means the queue
    /// was drained into `expired` only.
    static func prepare(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        trigger: MailboxStdinBuffer.FlushTrigger,
        now: Date,
        gate: Gate
    ) -> Prepared? {
        guard gate.panelPresent,
              state.buffer.pendingCount(surfaceId: surfaceId) > 0,
              !state.buffer.isPushInFlight(surfaceId: surfaceId) else { return nil }
        if trigger == .agentPrompt {
            guard !gate.inputTransactionActive,
                  state.buffer.decide(
                      surfaceId: surfaceId,
                      isAgentKind: true,
                      agentOwnsTerminal: gate.ownsTerminal,
                      lastOperatorKeyAt: gate.lastOperatorKeyAt
                  ) == .injectNow else { return nil }
        }
        let flush = state.buffer.drainForFlush(surfaceId: surfaceId, now: now, trigger: trigger)
        let started = !flush.fresh.isEmpty
        if started {
            state.buffer.beginPush(surfaceId: surfaceId)
        }
        return Prepared(
            fresh: flush.fresh,
            expired: flush.expired,
            admittedTurn: state.buffer.agentTurn(surfaceId: surfaceId),
            started: started
        )
    }

    /// Claim each fresh envelope. A `.gone` result is a drain that already
    /// owns the file: it is logged and not pasted.
    static func claim(
        entries: [MailboxStdinBuffer.Entry],
        inbox: URL,
        logSkipped: (MailboxStdinBuffer.Entry) -> Void,
        logFailed: (MailboxStdinBuffer.Entry, Int32) -> Void
    ) -> [MailboxStdinBuffer.Entry] {
        var claimed: [MailboxStdinBuffer.Entry] = []
        for entry in entries {
            switch MailboxIO.claimResult(id: entry.id, inbox: inbox) {
            case .claimed:
                claimed.append(entry)
            case .gone:
                // A drain took it first: nothing to type for it.
                logSkipped(entry)
            case .failed(let code):
                logFailed(entry, code)
            }
        }
        return claimed
    }

    /// Verdict after the claims. `.paste` has not ended the push; the caller
    /// records the terminal's submit through `notePasteResult`.
    static func complete(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        claimed: [MailboxStdinBuffer.Entry],
        trigger: MailboxStdinBuffer.FlushTrigger,
        admittedTurn: MailboxStdinBuffer.AgentTurn?,
        admittedInputEpoch: UInt64,
        gate: Gate
    ) -> Step {
        guard !claimed.isEmpty else {
            state.buffer.endPush(surfaceId: surfaceId, typedAt: nil)
            return .finished(retry: true)
        }
        guard gate.panelPresent else {
            state.buffer.endPush(surfaceId: surfaceId, typedAt: nil)
            return .undo(entries: claimed, lines: entries(claimed, outcome: .closed), retry: false)
        }
        var verdict = state.buffer.pushVerdict(
            surfaceId: surfaceId,
            admittedAs: trigger,
            admittedTurn: admittedTurn,
            lastOperatorKeyAt: gate.lastOperatorKeyAt,
            surfaceAttached: gate.surfaceAttached,
            agentOwnsTerminal: trigger == .agentPrompt ? gate.ownsTerminal : true
        )
        if verdict == .paste,
           gate.inputTransactionActive || gate.inputTransactionEpoch != admittedInputEpoch {
            verdict = .requeue
        }
        switch verdict {
        case .drop:
            state.buffer.endPush(surfaceId: surfaceId, typedAt: nil)
            return .undo(entries: claimed, lines: entries(claimed, outcome: .expired), retry: true)
        case .requeue:
            let evicted = state.buffer.requeueFront(surfaceId: surfaceId, entries: claimed)
            state.buffer.endPush(surfaceId: surfaceId, typedAt: nil)
            return .undo(entries: claimed, lines: requeueLines(claimed, evicted: evicted), retry: true)
        case .paste:
            return .paste(entries: claimed, block: MailboxStdinBuffer.joinedBlock(claimed))
        }
    }

    /// The terminal reported whether the submit Return was dispatched.
    static func notePasteResult(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        entries: [MailboxStdinBuffer.Entry],
        immediateId: String?,
        dispatched: Bool,
        typedAt: Date,
        preReturnVerdict: MailboxStdinBuffer.PushVerdict,
        panelPresent: Bool
    ) -> PasteRecord {
        if dispatched {
            state.buffer.endPush(surfaceId: surfaceId, typedAt: typedAt)
            let lines = entries.compactMap { entry -> LogLine? in
                guard entry.id != immediateId else { return nil }
                return LogLine(entry: entry, outcome: .flushed, bytes: entry.block.utf8.count)
            }
            return PasteRecord(lines: lines, retry: false)
        }
        if panelPresent, preReturnVerdict == .requeue {
            let evicted = state.buffer.requeueFront(surfaceId: surfaceId, entries: entries)
            state.buffer.endPush(surfaceId: surfaceId, typedAt: nil)
            return PasteRecord(lines: requeueLines(entries, evicted: evicted), retry: true)
        }
        let outcome: MailboxDispatchLog.HandlerOutcome =
            panelPresent && preReturnVerdict == .drop ? .expired : .closed
        state.buffer.endPush(surfaceId: surfaceId, typedAt: nil)
        return PasteRecord(lines: entries.map { LogLine(entry: $0, outcome: outcome, bytes: nil) }, retry: true)
    }

    /// Synchronous push used by logic tests. Workspace's push is this same
    /// order with the claim hop off the main actor and the paste on the terminal.
    static func perform(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        trigger: MailboxStdinBuffer.FlushTrigger,
        immediateId: String?,
        now: Date,
        gate: Gate,
        inbox: URL,
        log: (LogLine) -> Void,
        logFailed: (MailboxStdinBuffer.Entry, Int32) -> Void,
        paste: (_ block: String) -> Bool
    ) {
        guard let prepared = prepare(
            state: state,
            surfaceId: surfaceId,
            trigger: trigger,
            now: now,
            gate: gate
        ) else { return }
        for entry in prepared.expired {
            log(LogLine(entry: entry, outcome: .expired, bytes: nil))
        }
        guard prepared.started else { return }
        let claimed = claim(
            entries: prepared.fresh,
            inbox: inbox,
            logSkipped: { log(LogLine(entry: $0, outcome: .skipped, bytes: nil)) },
            logFailed: logFailed
        )
        switch complete(
            state: state,
            surfaceId: surfaceId,
            claimed: claimed,
            trigger: trigger,
            admittedTurn: prepared.admittedTurn,
            admittedInputEpoch: gate.inputTransactionEpoch,
            gate: gate
        ) {
        case .finished(_):
            break
        case .undo(let entries, let lines, _):
            for entry in entries {
                _ = MailboxIO.unclaim(id: entry.id, inbox: inbox)
            }
            for line in lines { log(line) }
        case .paste(let entries, let block):
            let dispatched = paste(block)
            let recorded = notePasteResult(
                state: state,
                surfaceId: surfaceId,
                entries: entries,
                immediateId: immediateId,
                dispatched: dispatched,
                typedAt: now,
                preReturnVerdict: dispatched ? .paste : .drop,
                panelPresent: gate.panelPresent
            )
            if !dispatched {
                for entry in entries {
                    _ = MailboxIO.unclaim(id: entry.id, inbox: inbox)
                }
            }
            for line in recorded.lines { log(line) }
        }
    }

    private static func entries(
        _ claimed: [MailboxStdinBuffer.Entry],
        outcome: MailboxDispatchLog.HandlerOutcome
    ) -> [LogLine] {
        claimed.map { LogLine(entry: $0, outcome: outcome, bytes: nil) }
    }

    private static func requeueLines(
        _ claimed: [MailboxStdinBuffer.Entry],
        evicted: [MailboxStdinBuffer.Entry]
    ) -> [LogLine] {
        var lines: [LogLine] = []
        for entry in claimed where !evicted.contains(entry) {
            lines.append(LogLine(entry: entry, outcome: .buffered, bytes: nil))
        }
        for entry in evicted {
            lines.append(LogLine(entry: entry, outcome: .evicted, bytes: nil))
        }
        return lines
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
