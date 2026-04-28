import Foundation

/// Per-surface `lastActivityTimestamp` primitive used by the Codex scrape
/// filter ("mtime ≥ surface lastActivityTimestamp" disambiguates which
/// session belongs to which pane after restart).
///
/// Updated by:
/// - terminal input (`TerminalSurface.sendText`),
/// - `c11 conversation claim` (wrapper-claim at TUI launch),
/// - explicit calls from snapshot capture / hook-push paths.
///
/// **Off-main + debounced**: callers post into the tracker via a dedicated
/// serial queue; the public API never blocks the caller. Per c11's CLAUDE.md
/// typing-latency policy, this is NEVER touched from `forceRefresh`,
/// `hitTest`, or `TabItemView` body. `sendText` is acceptable — it is
/// already off the typing hot path (`writeTextData` does the bracketed-paste
/// write itself; `sendText` only wraps).
///
/// Persisted in workspace snapshots as part of `SessionPanelSnapshot`
/// (added in step 8).
public final class SurfaceActivityTracker: @unchecked Sendable {
    public static let shared = SurfaceActivityTracker()

    /// Debounce window. Two updates within this interval coalesce.
    public static let debounceInterval: TimeInterval = 0.250

    private let queue = DispatchQueue(
        label: "com.stage11.c11.surface-activity",
        qos: .utility
    )
    /// Map of surfaceId → most recent activity timestamp. All access is
    /// serialised through `queue` so reads are consistent.
    private var lastActivity: [String: Date] = [:]
    /// Map of surfaceId → next-allowed update time (for debounce). Burst
    /// writes are dropped silently; the *first* write in a window wins so
    /// the timestamp tracks the leading edge of a burst, not the trailing.
    private var nextAllowed: [String: Date] = [:]

    public init() {}

    /// Public entry point: record activity for `surfaceId`. Returns
    /// immediately; the actual store update happens off-thread.
    public func recordActivity(surfaceId: String, at: Date = Date()) {
        let normalised = surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if let allowed = self.nextAllowed[normalised], at < allowed {
                // Within the debounce window — drop. The leading-edge value
                // already captures the burst.
                return
            }
            self.lastActivity[normalised] = at
            self.nextAllowed[normalised] = at.addingTimeInterval(Self.debounceInterval)
        }
    }

    /// Synchronous read. Suitable for the snapshot-capture path and the
    /// strategy-input bundle; returns the last recorded timestamp or nil.
    public func lastActivity(for surfaceId: String) -> Date? {
        let normalised = surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return nil }
        return queue.sync {
            self.lastActivity[normalised]
        }
    }

    /// Bulk seed from a snapshot at restore time. Replaces the current
    /// contents.
    public func seed(from records: [String: Date]) {
        queue.sync {
            self.lastActivity = records
            // Reset debounce floor — a restore is its own "new window."
            self.nextAllowed = [:]
        }
    }

    /// Bulk read for snapshot capture. Returns a copy of the live map.
    public func snapshot() -> [String: Date] {
        queue.sync {
            return self.lastActivity
        }
    }

    /// Clear a single surface (used by `c11 conversation clear`).
    public func clear(surfaceId: String) {
        let normalised = surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return }
        queue.sync {
            self.lastActivity.removeValue(forKey: normalised)
            self.nextAllowed.removeValue(forKey: normalised)
        }
    }

    /// Reset everything. Test-support; not used in the production path.
    public func resetAll() {
        queue.sync {
            self.lastActivity.removeAll()
            self.nextAllowed.removeAll()
        }
    }
}
