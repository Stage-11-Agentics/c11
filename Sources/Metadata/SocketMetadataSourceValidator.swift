import Foundation

/// (C11-106 AC16) Source-validation seam for the v2 socket
/// `set_metadata` / `clear_metadata` handlers. Extracted from the
/// four duplicated inline checks in `TerminalController.swift` so
/// the rejection contract can be exercised from `c11LogicTests`
/// without standing up a full socket frame loop.
///
/// External callers (CLI / socket / IPC) MUST NOT write
/// `source=derived` — that precedence tier is reserved for
/// c11-internal writers (`TabManager.applyDerivedWorktreeBranchMetadata`,
/// future derivers). Without this gate, an agent could write
/// `source=derived` and claim its values are system-computed,
/// nullifying the meaning of the precedence tier.
///
/// Returns `nil` for an acceptable source (`.explicit`, `.declare`,
/// `.osc`, `.heuristic`). Returns the canonical `(code, message)`
/// pair when the source is `.derived` and should be rejected.
internal enum SocketMetadataSourceValidator {
    static let invalidSourceCode = "invalid_source"
    static let invalidSourceMessage = "source 'derived' is reserved for c11-internal writers"

    static func externalRejectionMessage(for source: MetadataSource) -> (code: String, message: String)? {
        if source == .derived {
            return (code: invalidSourceCode, message: invalidSourceMessage)
        }
        return nil
    }
}
