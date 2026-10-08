import Foundation

/// (C11-165 COR-1; C11-251) Explicit-target validation seam for v2/v1 socket
/// writes and selected-workspace-protected sidebar commands. Write handlers
/// include `set_metadata`, `clear_metadata`, `set_title`, `set_description`,
/// `set_agent`, `trigger_flash`, `rename`, and v1 `set_status` / `set_progress`
/// / `log`; C11-251 also uses it for sidebar clear/list/state commands.
///
/// The June 2026 audit (P0.2) found that an empty or absent surface ref
/// silently *defaults to the operator-focused surface* on every write
/// path, so a sub-agent stomps a peer's terminal/metadata with an
/// identical-looking `OK`. Root cause: `v2String` (and `v2UUID`) trim
/// then return `nil`, collapsing "key absent", "explicit null", and
/// "present-but-empty" into the same `nil` — after which handlers do
/// `?? focusedPanelId`.
///
/// This validator distinguishes the three raw states *before* resolution
/// so callers can reject empty **and** absent refs (never falling back to
/// selected context). It is a pure function over the raw params
/// dict so the rejection contract is exercised from `c11LogicTests`
/// without standing up a socket frame loop — mirroring the C11-106
/// precedent `SocketMetadataSourceValidator`.
///
/// `requiredAnyOf` must name the key(s) that *pin the resolved
/// granularity* — e.g. `["surface_id"]` for surface metadata, not the
/// coarser `workspace_id`, because the resolver still falls to
/// `workspace.focusedPanelId` when only a workspace ref is present.
internal enum SocketPanelRefValidator {
    static let emptyRefCode = "empty_ref"
    static let missingRefCode = "missing_ref"

    /// Classification of one raw param value.
    enum RefState: Equatable {
        /// Key missing entirely, or present as JSON `null` (`NSNull`).
        case absent
        /// Key present as a string that is empty/whitespace-only, or as a
        /// non-string value (a malformed ref — refs are always strings).
        case empty
        /// Key present as a non-empty, trimmed string.
        case present(String)
    }

    /// Classify `raw` where `raw` is the result of `params[key]` (an
    /// `Any?`). A missing key arrives as `nil`; an explicit JSON null as
    /// `NSNull`; both are `.absent`.
    static func classify(_ raw: Any?) -> RefState {
        guard let raw, !(raw is NSNull) else { return .absent }
        guard let s = raw as? String else { return .empty }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .present(trimmed)
    }

    struct Rejection: Equatable {
        let code: String
        let message: String
    }

    /// Returns a `Rejection` when an operation's required target is invalid,
    /// or `nil` to accept.
    ///
    /// - Parameters:
    ///   - params: the raw request params (v2) or a synthesized dict of
    ///     option strings (v1). Presence is read directly, so
    ///     absent/`NSNull`/empty are distinguished.
    ///   - targetKeys: every key that may carry a target ref; any one of
    ///     them present-but-empty is rejected (`empty_ref`) even if it is
    ///     not required — an explicitly-empty ref is always a bug.
    ///   - requiredAnyOf: the granularity-pinning key(s); at least one
    ///     must be `.present` or the operation is rejected (`missing_ref`,
    ///     no selected-context fallback).
    static func rejection(
        params: [String: Any],
        targetKeys: [String],
        requiredAnyOf: [String]
    ) -> Rejection? {
        // (1) Any target key explicitly present-but-empty is always a bug.
        for key in targetKeys {
            if case .empty = classify(params[key]) {
                return Rejection(
                    code: emptyRefCode,
                    message: String(localized: "socket.tabRef.empty.noSelectedFallback", defaultValue: "A panel reference was provided but empty; pass a concrete id (no selected-context fallback).")
                )
            }
        }
        // (2) Require an explicit, granularity-pinning target.
        let hasTarget = requiredAnyOf.contains { key in
            if case .present = classify(params[key]) { return true }
            return false
        }
        if !hasTarget {
            return Rejection(
                code: missingRefCode,
                message: String(localized: "socket.tabRef.missing.noSelectedFallback", defaultValue: "No panel target was provided; pass an explicit panel or workspace id (no selected-context fallback).")
            )
        }
        return nil
    }
}
