import Foundation

/// (C11-165 COR-1) Surface-ref validation seam for the v2/v1 socket
/// *write* handlers (`set_metadata`, `clear_metadata`, `set_title`,
/// `set_description`, `set_agent`, `trigger_flash`, `rename`, and the
/// v1 sidebar-metadata writes `set_status` / `set_progress` / `log`).
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
/// so the write family can reject empty **and** absent refs (never
/// falling back to focus). It is a pure function over the raw params
/// dict so the rejection contract is exercised from `c11LogicTests`
/// without standing up a socket frame loop — mirroring the C11-106
/// precedent `SocketMetadataSourceValidator`.
///
/// `requiredAnyOf` must name the key(s) that *pin the resolved
/// granularity* — e.g. `["surface_id"]` for surface metadata, not the
/// coarser `workspace_id`, because the resolver still falls to
/// `workspace.focusedPanelId` when only a workspace ref is present.
internal enum SocketSurfaceRefValidator {
    static let emptyRefCode = "empty_ref"
    static let missingRefCode = "missing_ref"

    /// Classification of one raw param value.
    enum RefState: Equatable {
        /// Key missing entirely.
        case absent
        /// Key present as a string that is empty/whitespace-only, or as a
        /// non-string value (a malformed ref — refs are always strings).
        case empty
        /// Key present as a non-empty, trimmed string.
        case present(String)
    }

    /// Classify `raw` where `raw` is the result of `params[key]` (an
    /// `Any?`). Only a missing key (`nil`) is `.absent`. An explicit JSON
    /// `null` arrives as `NSNull` and is `.empty`: the caller supplied a
    /// target key that cannot resolve, so optional-target commands must not
    /// mistake it for permission to use their focused-surface fallback.
    static func classify(_ raw: Any?) -> RefState {
        guard let raw else { return .absent }
        guard !(raw is NSNull) else { return .empty }
        guard let s = raw as? String else { return .empty }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .present(trimmed)
    }

    struct Rejection: Equatable {
        let code: String
        let message: String
    }

    /// Returns a `Rejection` when a write's surface targeting is invalid,
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
    ///     must be `.present` or the write is rejected (`missing_ref`,
    ///     no focused-surface fallback).
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
                    message: "surface ref '\(key)' was provided but empty — pass a concrete id (no focused-surface fallback for writes)"
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
                message: "no surface target — pass one of \(requiredAnyOf.joined(separator: ", ")) (no focused-surface fallback for writes)"
            )
        }
        return nil
    }
}
