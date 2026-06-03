import Foundation

/// Pure decision for the `c11 claude-hook session-end` "preserve metadata
/// during shutdown" guard.
///
/// Background: Claude Code's SessionEnd hook fires when the claude process
/// exits. On a Cmd+Q the c11 app is shutting down — it kills its terminals,
/// claude exits, SessionEnd fires. Without a guard, the hook would clear
/// `claude.session_id` from the surface metadata and race the snapshot
/// capture in `applicationShouldTerminate`, losing per-pane session ids and
/// breaking auto-resume on next launch (the registry's resolver returns nil
/// when the id is missing, so the wrapper just launches a fresh claude).
///
/// The CLI queries c11's terminating state via `system.ping` (250 ms). On
/// `true` the clear is skipped. On any failure (socket already torn down,
/// slow shutdown, old c11 binary missing the field), the CLI also skips the
/// clear: never tombstone on socket-uncertainty. Designed per
/// `synthesis-action.md` B4 of the conversation-store plan; PR #95
/// (conversation-store) replaces this rail entirely with a per-kind
/// strategy that captures and resumes via a richer transition rule.
///
/// Lives in `Sources/` (linked into both the c11 app target and the c11-cli
/// target) so the c11Tests target can unit-test the matcher directly
/// without dragging the CLI's `SocketClient` into the app module.
public enum SessionEndShutdownPolicy {
    /// Outcome of the CLI's `system.ping` query against the c11 socket.
    ///
    /// `success(isTerminating:)` carries the value of the new
    /// `is_terminating_app` field. Old c11 binaries without the field are
    /// represented as `success(isTerminating: false)` — they exhibit the
    /// pre-fix clear-always behavior, which is the existing-bug baseline.
    /// `failure` is everything else: socket unreachable, timeout, malformed
    /// response — all collapsed into one preserve-the-metadata branch.
    public enum PingOutcome: Equatable {
        case success(isTerminating: Bool)
        case failure
    }

    /// Returns `true` when SessionEnd should preserve the surface metadata
    /// (skip the clear). Two cases preserve:
    ///
    /// - `success(isTerminating: true)` — c11 confirmed it is shutting
    ///   down. Clearing the metadata now races the snapshot capture.
    /// - `failure` — socket query did not return cleanly. The safer call
    ///   is to preserve: the worst case is a stale `claude.session_id` on
    ///   a future SessionStart write (which overwrites the same key). The
    ///   alternative — clearing on uncertainty — silently breaks resume.
    public static func shouldPreserve(outcome: PingOutcome) -> Bool {
        switch outcome {
        case .success(let isTerminating):
            return isTerminating
        case .failure:
            return true
        }
    }
}
