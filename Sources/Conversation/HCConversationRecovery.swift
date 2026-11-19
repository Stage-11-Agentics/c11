import Foundation

/// Inventory uncertainty is not process death. Read the current runtime at
/// each store commit, including after a slow transcript check or scrape.
///
/// Two questions, kept apart on purpose:
/// - `permitsDeadProcessRecovery`: is this surface's terminal dead right now?
///   It gates the Quit and no-resume bulk mutations, so only a current
///   `.ended` lifecycle answers yes. Past provenance never makes a live agent
///   eligible for suspension.
/// - `permitsRecoveryCommit`: may a late startup-audit result for the OLD
///   conversation still be committed? True in the same cases, and also while a
///   replacement of the ended terminal exists, because startup replacement can
///   advance past `.ended` before a slow audit finishes.
enum HCConversationRecoveryPolicy {
    private static func entry(
        _ surfaceID: String, savedPersistentPanels: Set<UUID>,
        lookup: (UUID) -> HCPanelRestoreState.Entry?
    ) -> (decided: Bool, entry: HCPanelRestoreState.Entry?) {
        guard let panelID = UUID(uuidString: surfaceID) else { return (true, nil) }
        guard let current = lookup(panelID) else { return (!savedPersistentPanels.contains(panelID), nil) }
        guard current.identity.persistence == .persistent else { return (true, nil) }
        return (false, current)
    }

    static func permitsDeadProcessRecovery(
        surfaceID: String,
        savedPersistentPanels: Set<UUID>,
        lookup: (UUID) -> HCPanelRestoreState.Entry? = { HCPanelRestoreState.shared.entry(for: $0) }
    ) -> Bool {
        let r = entry(surfaceID, savedPersistentPanels: savedPersistentPanels, lookup: lookup)
        guard let current = r.entry else { return r.decided }
        if case .ended = current.lifecycle { return true }
        return false
    }

    static func permitsRecoveryCommit(
        surfaceID: String,
        savedPersistentPanels: Set<UUID>,
        lookup: (UUID) -> HCPanelRestoreState.Entry? = { HCPanelRestoreState.shared.entry(for: $0) }
    ) -> Bool {
        if permitsDeadProcessRecovery(surfaceID: surfaceID, savedPersistentPanels: savedPersistentPanels,
                                      lookup: lookup) { return true }
        // A startup replacement can advance past `.ended` while a slow audit
        // is still in flight. The end evidence it replaced stays authoritative
        // for the old conversation only; it is never a liveness answer.
        guard let panelID = UUID(uuidString: surfaceID), let current = lookup(panelID) else { return false }
        return HCRecoveryEndedProof.replacedKey(current.creation) != nil
    }
}

/// Which ended terminal a conversation recovery answers to. The transient
/// `.ended` lifecycle is not enough: startup replacement publishes
/// ended, creationPending, then the bound replacement while the conversation
/// audit and transcript checks are still running. 3A retains the replaced end
/// evidence in the creation provenance, so recovery reads it from there too.
/// A restored survivor and a brand-new terminal have neither.
enum HCRecoveryEndedProof {
    struct Source: Equatable {
        let key: HCTerminalKey
        /// True when a replacement terminal was already being created.
        let replacementStarted: Bool
    }

    static func replacedKey(_ creation: HCCreationProvenance?) -> HCTerminalKey? {
        guard let creation, creation.outcome != .rejected else { return nil }
        return creation.replaces?.key
    }

    /// A replacement attempt that threw (no launch spec yet, no window, hidden
    /// panel) consumed nothing. Keep the plan only when a replacement is
    /// already underway, which startup's own attach started. Otherwise release
    /// the claim, so the next lifecycle publish plans this same end again
    /// instead of leaving it pending forever with no shell to type into.
    static func shouldReleasePlanAfterFailedReplacement(
        endedKey: HCTerminalKey, current: Source?
    ) -> Bool {
        current != Source(key: endedKey, replacementStarted: true)
    }

    static func source(lifecycle: HCLifecycle, creation: HCCreationProvenance?) -> Source? {
        // The current end wins over an older retained replacement.
        if case .ended(let proof) = lifecycle {
            guard let key = proof.key else { return nil }
            return Source(key: key, replacementStarted: false)
        }
        guard let key = replacedKey(creation) else { return nil }
        return Source(key: key, replacementStarted: true)
    }
}

/// Travels with a panel during a workspace move, like its native runtime.
struct HCPendingConversationRecovery {
    let endedKey: HCTerminalKey
    let operatorKeyAt: Date?
    let plan: Workspace.RestartCommand
    /// Planned from this launch's startup resolution of a restored terminal,
    /// marked where the snapshot is restored (C11H-38). Only these are asked
    /// about by Ask; an end that happens later in the session is ordinary
    /// recovery. Explicit provenance, not a clock.
    var launchScoped: Bool = false
    /// C11H-196: a host-end resume types only after the staggered queue
    /// admits it, so shown panels (whose own start already made the fresh
    /// terminal) are spaced like hidden ones. Other recoveries need no turn.
    var admitted: Bool = true
}

/// One submission per fresh terminal, including uncertain transport outcomes.
/// A second genuine terminal loss gets a different key and its own attempt.
/// C11H-272: a live shell an agent left takes one per empty prompt, so its
/// attempt is the terminal and that prompt's epoch.
@MainActor
final class HCConversationResumeSubmission {
    static let shared = HCConversationResumeSubmission()
    private struct Attempt: Hashable {
        let key: HCTerminalKey
        let epoch: Date?
    }
    private var attempted: Set<Attempt> = []

    func submit(
        panelID: UUID,
        attachment: any HCAttachment,
        attemptEpoch: Date? = nil,
        text: String,
        submitReturn: Bool,
        permitsResume: @escaping @MainActor @Sendable () -> Bool,
        // nil for a terminal with no screen (C11H-167): no screen receipt ever comes, and the caller decided
        // from hc's own status that it may type. permitsResume is still checked before the write.
        screenGuard: HCInputGuard?,
        returnGuard: HCInputGuard?,
        // The screen-independent recheck of a headless resume (C11H-167): asked with permitsResume before the
        // body and before the Return.
        eligibility: (@MainActor @Sendable () -> Bool)? = nil,
        // The owning runtime's `submitInput`: it records each outcome once and
        // latches the input fault. A raw `attachment.submit` would not report a
        // `.resume` outcome, so an uncertain write would be invisible.
        send: @escaping @MainActor (HCInputRequest) async -> HCInputOutcome
    ) async -> HCInputOutcome {
        guard permitsResume() else { return .refused(.guardRefused) }
        let key = attachment.key
        let attempt = Attempt(key: key, epoch: attemptEpoch)
        guard attempted.insert(attempt).inserted else { return .refused(.guardRefused) }
        let outcome = await send(HCInputRequest(
            operationID: UUID(), panelID: panelID, key: key,
            attachmentGeneration: attachment.generation, source: .resume,
            payload: Data(text.utf8), submitReturn: submitReturn,
            screenGuard: screenGuard.map { guardScreen in { receipt in permitsResume() && guardScreen(receipt) } },
            returnGuard: returnGuard.map { guardReturn in { receipt in permitsResume() && guardReturn(receipt) } },
            eligibility: eligibility.map { eligible in { await MainActor.run { permitsResume() && eligible() } } }
        ))
        // Refusal proves zero bytes. It permits a later explicit request with
        // a new screen guard; there is no automatic retry or replay here.
        if case .refused = outcome { attempted.remove(attempt) }
        return outcome
    }
}

extension HCConversationResumeSubmission {
    /// Production entry: every resume goes through the owning runtime, so an
    /// uncertain write latches its input fault and shows the interruption.
    func submit(
        panelID: UUID,
        runtime: HCPanelSession,
        attachment: any HCAttachment,
        attemptEpoch: Date? = nil,
        text: String,
        submitReturn: Bool,
        permitsResume: @escaping @MainActor @Sendable () -> Bool,
        screenGuard: HCInputGuard?,
        returnGuard: HCInputGuard?,
        eligibility: (@MainActor @Sendable () -> Bool)? = nil
    ) async -> HCInputOutcome {
        await submit(panelID: panelID, attachment: attachment, attemptEpoch: attemptEpoch, text: text, submitReturn: submitReturn,
            permitsResume: permitsResume, screenGuard: screenGuard, returnGuard: returnGuard, eligibility: eligibility,
            send: { await runtime.submitInput($0) })
    }
}

enum HCEndAllTargets {
    /// Include inventory-only terminals as well as visible and hidden panels.
    /// Exact terminal keys win over labels; duplicate UI references end once.
    /// C11H-205: an inventory-only terminal is ended only when it is this
    /// install's (`HCOwnerLabels.isThisInstalls`): End All used to end every
    /// live record, including a staging build's or another Mac's on the linked machine.
    static func identities(
        panels: [HCPanelIdentity], inventory: HCInventorySnapshot, appInstallID: String? = nil
    ) -> [HCPanelIdentity] {
        var result: [HCPanelIdentity] = []
        var keys = Set<HCTerminalKey>()
        var panelIDs = Set<UUID>()
        for panel in panels where panel.persistence == .persistent {
            let binding = inventory.panelBindings[panel.panelID]
            let bindingMatchesCreation = panel.creationID == nil || binding.flatMap {
                inventory.records[$0]?.labels["c11.creation"]?.lowercased()
            } == panel.creationID?.uuidString.lowercased()
            // A pending replacement may still have the old panel binding.
            // Leave its key unresolved until the current intent is proved.
            let key = panel.key ?? (bindingMatchesCreation ? binding : nil)
            if let key, !keys.insert(key).inserted { continue }
            guard panelIDs.insert(panel.panelID).inserted else { continue }
            result.append(HCPanelIdentity(panelID: panel.panelID, key: key,
                persistence: panel.persistence, creationID: panel.creationID, origin: panel.origin))
        }
        for record in inventory.records.values where record.state != .finished {
            guard !keys.contains(record.key), HCOwnerLabels.isThisInstalls(record, appInstallID: appInstallID) else { continue }
            keys.insert(record.key)
            let labeled = record.labels["c11.panel"].flatMap(UUID.init(uuidString:))
            let panelID = labeled.flatMap { panelIDs.contains($0) ? nil : $0 } ?? UUID()
            panelIDs.insert(panelID)
            result.append(HCPanelIdentity(panelID: panelID, key: record.key))
        }
        return result
    }
}
