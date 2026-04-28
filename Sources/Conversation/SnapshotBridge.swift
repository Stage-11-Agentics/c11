import Foundation

/// One-release backward-compat bridge for the C11-24 conversation store.
///
/// Snapshots written by 0.43.0 (opt-in) and 0.44.0-pre (default-on) carry
/// the per-surface session id in `surface.metadata["claude.session_id"]`
/// (the legacy reserved key). Snapshots written by 0.44.0+ carry it in
/// `SessionPanelSnapshot.surfaceConversations.active` (the new
/// embedded field).
///
/// The bridge runs at restore time. For each panel snapshot:
/// 1. If `surfaceConversations.active` is already set, use it as-is.
/// 2. Else, if `surface.metadata["claude.session_id"]` is present and
///    valid, lift into a synthetic `ConversationRef(kind: claude-code,
///    id: <value>, capturedVia: .scrape, state: .unknown,
///    diagnosticReason: "lifted from legacy claude.session_id metadata")`
///    and seed the store. State is `.unknown` because the legacy snapshot
///    didn't carry lifecycle info — the next-launch scrape (or operator
///    interaction) reclassifies.
///
/// **Deprecation:** removed in 0.46.0 / v1.1, whichever ships later. See
/// the TODO marker in `seedFromSnapshot(_:)`.
public enum WorkspaceSnapshotConversationBridge {

    /// Seed `ConversationStore.shared` from a workspace snapshot. Walks
    /// every panel; honors the new field first; falls back to the legacy
    /// reserved-metadata read for one release window.
    ///
    /// Calls into the actor synchronously via a 1 s bounded semaphore.
    /// Called from the main-actor restore path (TabManager →
    /// AppDelegate); the wait is acceptable on this rare seam.
    public static func seedFromSnapshot(_ snapshot: AppSessionSnapshot) {
        var liftedCount = 0
        var nativeCount = 0
        let sema = DispatchSemaphore(value: 0)
        Task {
            for window in snapshot.windows {
                for ws in window.tabManager.workspaces {
                    for panel in ws.panels {
                        guard panel.type == .terminal else { continue }
                        let surfaceId = panel.id.uuidString
                        if let conv = panel.surfaceConversations,
                           let active = conv.active {
                            await ConversationStore.shared.recordScrape(
                                surfaceId: surfaceId, ref: active
                            )
                            nativeCount += 1
                            continue
                        }
                        // TODO(0.46.0 / v1.1): remove this legacy bridge
                        // once snapshots from 0.43.0/0.44.0-pre have aged
                        // out. Tracked alongside the
                        // CMUX_DISABLE_CONVERSATION_STORE kill switch.
                        if let lifted = liftLegacyClaudeSessionId(panel) {
                            await ConversationStore.shared.recordScrape(
                                surfaceId: surfaceId, ref: lifted
                            )
                            liftedCount += 1
                        }
                    }
                }
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 1.0)
        #if DEBUG
        print("conversation.bridge.seed native=\(nativeCount) lifted=\(liftedCount)")
        #endif
    }

    /// Synchronous helper for tests. Returns the synthesized ref iff the
    /// legacy metadata key is present + valid.
    public static func liftLegacyClaudeSessionId(
        _ panel: SessionPanelSnapshot
    ) -> ConversationRef? {
        guard let metadata = panel.metadata else { return nil }
        guard case .string(let raw)? = metadata[SurfaceMetadataKeyName.claudeSessionId] else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Defence-in-depth: validate against the same UUID v4 grammar
        // the SurfaceMetadataStore validator enforces, so a corrupt
        // legacy key cannot leak into a synthesized ref.
        guard isValidConversationUUID(trimmed) else { return nil }
        // Lift cwd if available — the panel snapshot's `directory` field
        // carries it in the legacy schema.
        let cwd = panel.directory.flatMap { $0.isEmpty ? nil : $0 }
        return ConversationRef(
            kind: "claude-code",
            id: trimmed,
            placeholder: false,
            cwd: cwd,
            capturedAt: Date(),
            capturedVia: .scrape,
            state: .unknown,
            diagnosticReason: "lifted from legacy claude.session_id metadata"
        )
    }
}
