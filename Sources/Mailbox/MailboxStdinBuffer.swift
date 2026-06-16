import Foundation

/// Per-surface buffer + gating decision for `stdin` mailbox delivery (C11-144).
///
/// Pasting a framed `<c11-msg>` block straight into a recipient PTY is only
/// safe when that PTY is sitting at a shell prompt. If a foreground command is
/// running (a build, `vim`, a REPL — anything in raw or cooked mode that owns
/// stdin), the paste corrupts that program's input stream. This type gates the
/// push on c11's already-tracked `PanelShellActivityState`:
///
///   - `.promptIdle`     → inject now (safe).
///   - `.commandRunning` → buffer; flush when the shell returns to the prompt.
///   - `.unknown`        → buffer (conservative; never corrupt on a guess).
///
/// **Doorbell, not delivery.** The dispatcher always copies the envelope into
/// the recipient's filesystem inbox *before* invoking this handler, and the
/// receiver-pull cadence (`c11 mailbox recv --drain` at turn boundaries) is the
/// durable floor. So buffered entries that never flush — e.g. a long-lived
/// agent TUI that stays `.commandRunning` for hours and is delivered via pull
/// instead — are not lost. That floor is what lets the freshness window below
/// drop stale entries rather than dump them onto a bare shell.
///
/// **Pure and clock-injected.** No PTY, no `Workspace` instance, no ambient
/// clock — `now` is supplied by the caller — so the gating/buffer/flush logic
/// is deterministically unit-testable without a live terminal. All mutation in
/// production happens on the main actor (the dispatcher's writer hop and the
/// shell-state transition both land on main), so this is a plain value type
/// with no internal locking.
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

    /// Result of draining one surface's queue at a `→ .promptIdle` transition.
    struct FlushResult: Equatable {
        /// Entries young enough to inject, in FIFO order.
        var fresh: [Entry]
        /// Entries older than `freshnessWindow` — dropped from the buffer (the
        /// inbox + `recv --drain` floor still owns them) rather than injected.
        var expired: [Entry]
    }

    /// Max queued entries per surface. A broadcast storm into a busy surface
    /// can't grow the buffer without bound; the oldest is evicted (and the
    /// inbox floor still holds it). Generous: real handoff traffic is sparse.
    static let perSurfaceCap = 64

    /// Entries older than this at flush time are expired, not injected.
    ///
    /// This is the mechanism that separates the two `.commandRunning` regimes:
    /// a build or `vim` edit runs for seconds-to-minutes, so its buffered
    /// messages flush cleanly when it ends; an agent TUI runs for hours, so by
    /// the time it exits to a bare shell its buffered messages are stale and
    /// drop instead of pasting `<c11-msg>` junk onto the prompt (they were
    /// already delivered via the pull floor). 10 minutes comfortably covers
    /// normal foreground commands while staying well under an agent session.
    static let freshnessWindow: TimeInterval = 600

    private var queues: [UUID: [Entry]] = [:]

    /// Inject-now vs buffer, purely from the recipient's shell activity state.
    static func decide(state: Workspace.PanelShellActivityState) -> Decision {
        switch state {
        case .promptIdle:
            return .injectNow
        case .commandRunning, .unknown:
            return .buffer
        }
    }

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

    /// Remove and partition a surface's queue for flushing at a
    /// `→ .promptIdle` transition. Fresh entries (FIFO) are for injection;
    /// expired entries are for drop+log. Clears the surface's queue entirely.
    mutating func drainForFlush(surfaceId: UUID, now: Date) -> FlushResult {
        guard let queue = queues[surfaceId], !queue.isEmpty else {
            return FlushResult(fresh: [], expired: [])
        }
        queues.removeValue(forKey: surfaceId)
        var fresh: [Entry] = []
        var expired: [Entry] = []
        for entry in queue {
            if now.timeIntervalSince(entry.bufferedAt) <= Self.freshnessWindow {
                fresh.append(entry)
            } else {
                expired.append(entry)
            }
        }
        return FlushResult(fresh: fresh, expired: expired)
    }

    /// Drop a surface's queue outright (surface closed). Returns any entries
    /// that were pending so the caller can log the drop; the inbox floor still
    /// holds them for `recv --drain`.
    @discardableResult
    mutating func removeSurface(_ surfaceId: UUID) -> [Entry] {
        queues.removeValue(forKey: surfaceId) ?? []
    }

    /// Prune queues for surfaces no longer present (mirrors the metadata prune
    /// the socket fast-path runs).
    mutating func retainOnly(surfaceIds: Set<UUID>) {
        queues = queues.filter { surfaceIds.contains($0.key) }
    }

    func pendingCount(surfaceId: UUID) -> Int {
        queues[surfaceId]?.count ?? 0
    }

    var isEmpty: Bool {
        queues.values.allSatisfy { $0.isEmpty }
    }
}
