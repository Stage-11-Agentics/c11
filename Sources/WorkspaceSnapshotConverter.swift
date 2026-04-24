import Foundation

// IMPORTANT: This file is intentionally `Foundation`-only. No AppKit. No
// stores. No `ProcessInfo`. No file I/O. A reviewer should be able to
// extract this file and a test file and run the tests on Linux. The env
// gate (`C11_SESSION_RESUME`) is resolved at the CLI layer, and the
// restart-registry command synthesis happens inside the executor at apply
// time — not here.

/// Pure, `nonisolated` translation from a loaded `WorkspaceSnapshotFile`
/// envelope to a `WorkspaceApplyPlan` the executor can apply. Phase 1
/// snapshots wrap a plan, so the converter's current job is shape-only:
/// verify versions, hand back `snapshot.plan`. Keeping the conversion a
/// dedicated seam now means Phase 2+ (browser history, markdown
/// scrollback, non-plan enrichments) can layer in without the CLI/socket
/// layers reaching into envelope internals.
enum WorkspaceSnapshotConverter {

    /// Envelope schema versions this converter accepts. Phase 1 ships `1`.
    /// Bumping the envelope format adds a version here; the plan version
    /// check delegates to the executor's own allow-list.
    static let supportedEnvelopeVersions: Set<Int> = [1]

    /// Plan schema versions the converter admits. Kept identical to
    /// `WorkspaceLayoutExecutor.supportedPlanVersions` (Phase 0 ships `1`)
    /// but duplicated as a literal so this file stays decoupled from the
    /// executor and portable (Linux-friendly).
    ///
    /// If you bump `WorkspaceLayoutExecutor.supportedPlanVersions`, bump
    /// this set too — both sides must agree. The test suite covers
    /// `versionUnsupported` (envelope) and `planVersionUnsupported` (plan)
    /// so a mismatch fails loudly.
    static let supportedPlanVersions: Set<Int> = [1]

    enum ConverterError: Error, Equatable {
        /// Envelope `version` not in `supportedEnvelopeVersions`.
        case versionUnsupported(Int)
        /// Embedded `plan.version` not in `supportedPlanVersions`. Split
        /// from the envelope case so callers can report the right knob.
        case planVersionUnsupported(Int)
        /// Reserved for future structural checks the converter might add
        /// (e.g., a cross-field invariant that outlives the envelope
        /// schema number). Currently unused; kept in the enum so adding a
        /// new failure mode later is a non-breaking extension.
        case planDecodeFailed(String)

        var code: String {
            switch self {
            case .versionUnsupported: return "snapshot_version_unsupported"
            case .planVersionUnsupported: return "snapshot_plan_version_unsupported"
            case .planDecodeFailed: return "snapshot_plan_decode_failed"
            }
        }

        var message: String {
            switch self {
            case .versionUnsupported(let v):
                return "WorkspaceSnapshotFile.version=\(v) unsupported (Phase 1 accepts \(Self.sortedList(WorkspaceSnapshotConverter.supportedEnvelopeVersions)))"
            case .planVersionUnsupported(let v):
                return "WorkspaceSnapshotFile.plan.version=\(v) unsupported (Phase 1 accepts \(Self.sortedList(WorkspaceSnapshotConverter.supportedPlanVersions)))"
            case .planDecodeFailed(let detail):
                return "snapshot plan decode failed: \(detail)"
            }
        }

        private static func sortedList(_ set: Set<Int>) -> String {
            "[\(set.sorted().map(String.init).joined(separator: ","))]"
        }
    }

    /// Pure conversion from a loaded snapshot envelope to a plan the
    /// executor can apply. Does NOT materialize the restart-registry
    /// command — that happens at apply time inside the executor so
    /// Blueprints get the same behavior without duplicate logic. Does
    /// NOT read env vars, touch stores, or hit AppKit.
    nonisolated static func applyPlan(
        from snapshot: WorkspaceSnapshotFile
    ) -> Result<WorkspaceApplyPlan, ConverterError> {
        if !supportedEnvelopeVersions.contains(snapshot.version) {
            return .failure(.versionUnsupported(snapshot.version))
        }
        if !supportedPlanVersions.contains(snapshot.plan.version) {
            return .failure(.planVersionUnsupported(snapshot.plan.version))
        }
        return .success(snapshot.plan)
    }
}
