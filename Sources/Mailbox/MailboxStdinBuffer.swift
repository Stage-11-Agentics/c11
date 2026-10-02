import Foundation

/// Per-tab buffer + gating decision for `stdin` mailbox delivery.
///
/// Pasting a framed `<c11-msg>` block into a recipient PTY is only safe at a
/// moment the recipient will read it as fresh input. Two kinds of recipient:
///
/// **Agent tabs** (Claude Code, Codex, Grok, ...). The agent TUI keeps its
/// shell in one long-running command for life, so the shell state says
/// nothing. The gate is the agent's own turn edge, which c11 learns from
/// explicit lifecycle reports (`report_agent_activity`, the Codex
/// turn-complete notify) and from every submit Return typed into the tab:
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
/// **Plain shells**: `.promptIdle` → inject; `.commandRunning` / `.unknown`
/// → buffer and flush when the shell returns to its prompt. An agent tab
/// whose shell is back at `.promptIdle` has exited, so the shell rule applies
/// and its buffered agent blocks drop instead of landing on a bare shell.
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
    /// `c11 mailbox trace`. `forAgent` records which gate buffered it.
    struct Entry: Equatable {
        let id: String
        let recipientName: String
        let block: String
        let bufferedAt: Date
        var forAgent: Bool = false
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
        /// The shell returned to its prompt: shell entries flush if fresh;
        /// agent entries drop because their agent has exited.
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

    /// Shell entries older than this at flush time are expired, not
    /// injected: a message buffered behind a long foreground command is stale
    /// by the time the prompt returns. Agent entries never expire; an agent
    /// reaches its prompt many times an hour and the message is still meant
    /// for it.
    static let freshnessWindow: TimeInterval = 600

    private var queues: [UUID: [Entry]] = [:]
    private var turns: [UUID: AgentTurn] = [:]
    private var lastSubmitAt: [UUID: Date] = [:]
    private var lastPushAt: [UUID: Date] = [:]
    /// Tabs with a push between its claim and its submit Return. Nothing else
    /// is typed into them until it finishes.
    private var pushesInFlight: Set<UUID> = []

    /// Inject-now vs buffer for a plain shell, purely from its activity state.
    static func decide(state: Workspace.TabShellActivityState) -> Decision {
        switch state {
        case .promptIdle:
            return .injectNow
        case .commandRunning, .unknown:
            return .buffer
        }
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
    /// the tab as an agent.
    func decide(
        surfaceId: UUID,
        shell: Workspace.TabShellActivityState,
        isAgentKind: Bool,
        lastOperatorKeyAt: Date?,
        ignoringInFlight: Bool = false
    ) -> Decision {
        if !ignoringInFlight, pushesInFlight.contains(surfaceId) { return .buffer }
        if shell == .promptIdle { return .injectNow }
        guard isAgent(surfaceId: surfaceId, isAgentKind: isAgentKind) else {
            return Self.decide(state: shell)
        }
        return Self.decideAgent(
            turn: turns[surfaceId],
            lastSubmitAt: lastSubmitAt[surfaceId],
            lastOperatorKeyAt: lastOperatorKeyAt,
            lastPushAt: lastPushAt[surfaceId]
        )
    }

    func isAgent(surfaceId: UUID, isAgentKind: Bool) -> Bool {
        isAgentKind || turns[surfaceId] != nil
    }

    // MARK: - Agent turn edges

    /// An explicit lifecycle report: the agent reached its prompt
    /// (`atPrompt: true`) or started working.
    mutating func noteAgentTurn(surfaceId: UUID, atPrompt: Bool, at now: Date) {
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
        trigger: FlushTrigger = .shellPrompt
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
                if !entry.forAgent,
                   now.timeIntervalSince(entry.bufferedAt) <= Self.freshnessWindow {
                    fresh.append(entry)
                } else {
                    expired.append(entry)
                }
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
        return queues.removeValue(forKey: surfaceId) ?? []
    }

    /// Prune queues for surfaces no longer present (mirrors the metadata prune
    /// the socket fast-path runs).
    mutating func retainOnly(surfaceIds: Set<UUID>) {
        queues = queues.filter { surfaceIds.contains($0.key) }
        turns = turns.filter { surfaceIds.contains($0.key) }
        lastSubmitAt = lastSubmitAt.filter { surfaceIds.contains($0.key) }
        lastPushAt = lastPushAt.filter { surfaceIds.contains($0.key) }
    }

    func pendingCount(surfaceId: UUID) -> Int {
        queues[surfaceId]?.count ?? 0
    }

    var isEmpty: Bool {
        queues.values.allSatisfy { $0.isEmpty }
    }
}
