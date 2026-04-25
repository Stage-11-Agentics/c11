import Foundation

/// String-shape predicate for "the c11 app is not reachable on its control
/// socket on this machine for me." Used by the CLI's claude-hook dispatch
/// and other advisory pathways that should no-op (not fail) when there is
/// nothing to talk to.
///
/// c11 is single-user. The predicate collapses three orthogonal shapes —
/// socket file missing, listener refusing, socket owned by a different uid
/// — into one advisory signal. If multi-user support ever lands, revisit
/// and split `failed` from advisory.
///
/// Lives in `Sources/` (shared by the c11 app target and c11-cli target)
/// so the c11Tests target can unit-test the matcher directly without
/// dragging `CLIError` (CLI-local) into the app module.
public enum CLIAdvisoryConnectivity {
    public static func isAdvisoryHookConnectivity(message m: String) -> Bool {
        return m.contains("Socket not found")
            || m.contains("socket not found")
            || m.contains("c11 app did not start in time")
            || m.contains("Connection refused")
            || m.contains("Failed to connect")
            || m.contains("No such file or directory")
            || m.contains("Permission denied")
            || m.contains("Operation not permitted")
            || m.contains("Resource temporarily unavailable")
    }
}
