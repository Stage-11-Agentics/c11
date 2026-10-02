import Foundation

/// Converts bounded transcript observations into the allowlisted J2 journal
/// draft. The detector remains a file reader; this producer owns the
/// transcript provenance and the bounded handoff to JournalCoordinator.
final class JournalTranscriptProducer: @unchecked Sendable {
    static let shared = JournalTranscriptProducer()

    private struct OwnerKey: Hashable {
        let tabID: UUID
        let workspaceID: UUID
        let agentKind: String
        let sessionID: String
    }

    private let queue = DispatchQueue(label: "com.stage11.c11.journal-transcript", qos: .utility)
    private let lock = NSLock()
    private let budgets = JournalBudgets()
    private var pendingCount = 0
    private var pendingBytes = 0
    private var gapNeeded: Set<OwnerKey> = []
    private var gapEnqueued: Set<OwnerKey> = []
    private var gapPublished: Set<OwnerKey> = []
    private var droppedDraftCount = 0

    /// The producer's drop count is diagnostic only. It is intentionally not
    /// persisted and carries no transcript content.
    var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedDraftCount
    }

    func submit(
        target: AgentModelDetector.Target,
        ref: ConversationRef,
        lifecycle: [TranscriptLifecycleObservation],
        coverage: TranscriptCoverage,
        now: Date = Date()
    ) {
        guard ["codex", "grok"].contains(target.kind), !ref.placeholder else { return }
        let key = OwnerKey(tabID: target.surfaceId, workspaceID: target.workspaceId,
                           agentKind: target.kind, sessionID: ref.id)
        if case .gap = coverage { requireGap(for: key) }

        if shouldEnqueueGap(for: key),
           let draft = Self.makeGapDraft(target: target, ref: ref, emittedAt: now) {
            _ = enqueue(draft, for: key, isGap: true)
        }

        for observation in lifecycle {
            guard let draft = Self.makeDraft(observation: observation, target: target,
                                             ref: ref, emittedAt: now) else {
                requireGap(for: key)
                recordDrop(for: key)
                continue
            }
            _ = enqueue(draft, for: key, isGap: false)
        }
    }

    static func makeDraft(
        observation: TranscriptLifecycleObservation,
        target: AgentModelDetector.Target,
        ref: ConversationRef,
        emittedAt: Date
    ) -> JournalDraft? {
        guard ["codex", "grok"].contains(target.kind), !ref.placeholder, !ref.id.isEmpty,
              [.turnStarted, .turnCompleted, .turnInterrupted].contains(observation.kind),
              !observation.isChild,
              let adapter = adapter(for: target.kind) else { return nil }
        var draft = JournalDraft(
            kind: observation.kind,
            emittedAtMs: epochMilliseconds(emittedAt),
            agentKind: target.kind,
            source: adapter.source,
            adapter: adapter,
            nativeEvent: observation.nativeEvent
        )
        draft.tabID = target.surfaceId
        draft.workspaceID = target.workspaceId
        draft.sessionID = ref.id
        draft.turnID = observation.turnID
        draft.isChild = observation.isChild
        if let occurredAt = observation.occurredAt {
            draft.occurredAtMs = epochMilliseconds(occurredAt)
            draft.timeQuality = .nativeLocal
        }
        guard (try? draft.validate()) != nil else { return nil }
        return draft
    }

    static func makeGapDraft(
        target: AgentModelDetector.Target,
        ref: ConversationRef,
        emittedAt: Date
    ) -> JournalDraft? {
        guard ["codex", "grok"].contains(target.kind), !ref.placeholder, !ref.id.isEmpty else { return nil }
        var draft = JournalDraft(
            kind: .stateChanged,
            emittedAtMs: epochMilliseconds(emittedAt),
            agentKind: target.kind,
            source: .c11,
            adapter: .c11,
            nativeEvent: "adapter_gap"
        )
        draft.tabID = target.surfaceId
        draft.workspaceID = target.workspaceId
        draft.sessionID = ref.id
        draft.signal = .adapterGap
        guard (try? draft.validate()) != nil else { return nil }
        return draft
    }

    private static func adapter(for kind: String) -> JournalAdapter? {
        switch kind {
        case "codex": return .codexTranscript
        case "grok": return .grokTranscript
        default: return nil
        }
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        max(0, Int64((date.timeIntervalSince1970 * 1000).rounded(.towardZero)))
    }

    private func shouldEnqueueGap(for key: OwnerKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gapNeeded.contains(key) && !gapEnqueued.contains(key) && !gapPublished.contains(key)
    }

    private func requireGap(for key: OwnerKey) {
        lock.lock()
        if !gapPublished.contains(key) { gapNeeded.insert(key) }
        trimCoverageSetsLocked()
        lock.unlock()
    }

    private func recordDrop(for key: OwnerKey) {
        lock.lock()
        droppedDraftCount += 1
        if !gapPublished.contains(key) { gapNeeded.insert(key) }
        trimCoverageSetsLocked()
        lock.unlock()
    }

    @discardableResult
    private func enqueue(_ draft: JournalDraft, for key: OwnerKey, isGap: Bool) -> Bool {
        guard let bytes = try? draft.canonicalData() else {
            recordDrop(for: key)
            return false
        }
        let byteCount = bytes.count
        lock.lock()
        if isGap && (gapEnqueued.contains(key) || gapPublished.contains(key)) {
            lock.unlock()
            return true
        }
        guard pendingCount < budgets.queueEntries,
              pendingBytes + byteCount <= budgets.queueBytes else {
            droppedDraftCount += 1
            if !gapPublished.contains(key) { gapNeeded.insert(key) }
            trimCoverageSetsLocked()
            lock.unlock()
            return false
        }
        pendingCount += 1
        pendingBytes += byteCount
        if isGap { gapEnqueued.insert(key) }
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let succeeded: Bool
            do {
                _ = try JournalCoordinator.shared.append(draft)
                succeeded = true
            } catch {
                succeeded = false
            }
            self.finished(key: key, bytes: byteCount, isGap: isGap, succeeded: succeeded)
        }
        return true
    }

    private func finished(key: OwnerKey, bytes: Int, isGap: Bool, succeeded: Bool) {
        lock.lock()
        pendingCount = max(0, pendingCount - 1)
        pendingBytes = max(0, pendingBytes - bytes)
        if isGap {
            gapEnqueued.remove(key)
            if succeeded {
                gapNeeded.remove(key)
                gapPublished.insert(key)
            } else {
                gapNeeded.insert(key)
            }
        } else if !succeeded && !gapPublished.contains(key) {
            gapNeeded.insert(key)
            droppedDraftCount += 1
        }
        trimCoverageSetsLocked()
        lock.unlock()
    }

    private func trimCoverageSetsLocked() {
        // A surface/session key is c11-owned, but sessions can be short-lived.
        // Keep this diagnostic state bounded independently of journal retention.
        while gapNeeded.count > 512, let first = gapNeeded.first { gapNeeded.remove(first) }
        while gapEnqueued.count > 512, let first = gapEnqueued.first { gapEnqueued.remove(first) }
        while gapPublished.count > 512, let first = gapPublished.first { gapPublished.remove(first) }
    }
}
