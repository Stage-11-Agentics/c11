import Foundation
import Combine

/// Applies journal and attention snapshots off the keystroke path.
/// Ask events come only from blocked-request changes. Scope, suppression, and display notes do not emit them.
/// Sorts only on this worker; consumers receive immutable snapshots on their chosen queue.
final class FeedProjectionBridge: @unchecked Sendable {
    static let shared = FeedProjectionBridge()

    private let queue = DispatchQueue(label: "com.stage11.c11.feed-projection", qos: .utility)
    private var journal: [UUID: JournalSnapshot] = [:]
    // The structural event that produced the current live snapshot. This is
    // process-local join state; replay/baseline projections deliberately have
    // no identity and cannot receive a display note.
    private var currentAskEventIDs: [UUID: UUID] = [:]
    private var attention: [UUID: FeedAttentionFact] = [:]
    private var tracker = FeedAskTracker()
    private let cache = AskDisplayCache()
    private var projected = FeedProjectionSnapshot.empty
    private let snapshotLock = NSLock()
    private var publishedSnapshot = FeedProjectionSnapshot.empty
    private var publishedAnswerRows: [UUID: FeedAnswerProjectionRow] = [:]
    private let changes = CurrentValueSubject<FeedProjectionSnapshot, Never>(.empty)
    var snapshots: AnyPublisher<FeedProjectionSnapshot, Never> { changes.eraseToAnyPublisher() }

    /// UI reads never wait behind journal processing or sorting.
    func snapshot() -> FeedProjectionSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return publishedSnapshot
    }

    /// Current immutable C11-264 row identity for a guarded answer. This is a
    /// lock-only read; projection and ordering stay on the utility queue.
    func answerRow(panelID: UUID) -> FeedAnswerProjectionRow? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return publishedAnswerRows[panelID]
    }

    private func refreshProjection() {
        let rows = FeedProjector.project(
            journalRows: Array(journal.values), attention: Array(attention.values),
            notes: cache.notesByPanel(), scope: .all
        )
        let next = FeedProjectionSnapshot(rows: rows)
        var answerRows: [UUID: FeedAnswerProjectionRow] = [:]
        answerRows.reserveCapacity(rows.count)
        for row in rows {
            let snapshot = journal[row.panelID]
            answerRows[row.panelID] = FeedAnswerProjectionRow(
                row: row,
                owner: snapshot?.owner,
                sequence: snapshot?.lastSequence,
                askEventID: currentAskEventIDs[row.panelID]
            )
        }
        let projectionChanged = next != projected
        projected = next
        snapshotLock.lock()
        publishedAnswerRows = answerRows
        if projectionChanged { publishedSnapshot = next }
        snapshotLock.unlock()
        if projectionChanged { changes.send(next) }
    }

    init() {}

    func noteJournal(panelID: UUID, snapshot: JournalSnapshot?, eventID: UUID? = nil) {
        let snapshot = snapshot
        queue.async { [self] in
            if let snapshot {
                let prior = self.journal[panelID]
                self.journal[panelID] = snapshot
                let sameAsk = prior.flatMap(FeedProjector.blockingKind) == FeedProjector.blockingKind(snapshot)
                    && prior?.requestID == snapshot.requestID
                if FeedProjector.blockingKind(snapshot) != nil, snapshot.confirmation == .confirmed {
                    if let eventID {
                        self.currentAskEventIDs[panelID] = eventID
                    } else if !sameAsk {
                        self.currentAskEventIDs.removeValue(forKey: panelID)
                    }
                } else {
                    self.currentAskEventIDs.removeValue(forKey: panelID)
                }
            } else {
                self.journal.removeValue(forKey: panelID)
                self.currentAskEventIDs.removeValue(forKey: panelID)
                self.cache.drop(panelID: panelID)
            }
            let events = self.tracker.consume(panelID: panelID, snapshot: snapshot)
            for event in events {
                let payload = event.jsonObject()
                if event.action == .opened {
                    EventEmitter.shared.emitAskOpened(workspace: event.workspaceID, surface: event.panelID, payload: payload)
                } else {
                    EventEmitter.shared.emitAskClosed(workspace: event.workspaceID, surface: event.panelID, payload: payload)
                }
            }
            self.cache.prune(openRequests: self.journal.mapValues { snap in
                FeedProjector.blockingKind(snap) == nil ? nil : snap.requestID
            })
            self.refreshProjection()
        }
    }

    func noteAttention(_ snapshot: PanelAttentionSnapshot) {
        let fact = FeedAttentionFact(
            workspaceID: snapshot.workspaceId,
            panelID: snapshot.surfaceId,
            flagReason: snapshot.flagReason,
            flagRaisedAtMs: snapshot.flagRaisedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
            flagCallerPanelID: snapshot.flagCallerPanelId,
            suppressed: snapshot.suppressed
        )
        queue.async { [self] in
            if fact.isFlagged || fact.suppressed {
                self.attention[fact.panelID] = fact
            } else {
                self.attention.removeValue(forKey: fact.panelID)
            }
            self.refreshProjection()
        }
    }

    func replaceAttention(_ snapshots: [PanelAttentionSnapshot]) {
        let facts = snapshots.map { snapshot in
            FeedAttentionFact(
                workspaceID: snapshot.workspaceId,
                panelID: snapshot.surfaceId,
                flagReason: snapshot.flagReason,
                flagRaisedAtMs: snapshot.flagRaisedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                flagCallerPanelID: snapshot.flagCallerPanelId,
                suppressed: snapshot.suppressed
            )
        }
        queue.async { [self] in
            self.attention = Dictionary(uniqueKeysWithValues: facts.map { ($0.panelID, $0) })
            self.refreshProjection()
        }
    }

    // Authoritative tab removal is distinct from journal owner changes: only
    // the former removes flags and suppression along with the ask.
    func removePanel(workspaceID: UUID, panelID: UUID) {
        queue.async { [self] in
            if attention[panelID]?.workspaceID == workspaceID { attention.removeValue(forKey: panelID) }
            if journal[panelID]?.workspaceID == workspaceID { retirePanel(panelID) }
            refreshProjection()
        }
    }

    func pruneWorkspace(workspaceID: UUID, validPanelIDs: Set<UUID>) {
        queue.async { [self] in
            let removed = Set(attention.values.filter { $0.workspaceID == workspaceID }.map(\.panelID))
                .union(journal.values.filter { $0.workspaceID == workspaceID }.map { $0.owner.panelID })
                .subtracting(validPanelIDs)
            for panelID in removed {
                attention.removeValue(forKey: panelID)
                retirePanel(panelID)
            }
            refreshProjection()
        }
    }

    private func retirePanel(_ panelID: UUID) {
        journal.removeValue(forKey: panelID)
        currentAskEventIDs.removeValue(forKey: panelID)
        cache.drop(panelID: panelID)
        for event in tracker.consume(panelID: panelID, snapshot: nil) {
            EventEmitter.shared.emitAskClosed(workspace: event.workspaceID, surface: event.panelID, payload: event.jsonObject())
        }
    }

    /// Returns a fixed error code, or nil when the note is cached.
    func acceptNote(
        panelID: UUID,
        workspaceID: UUID,
        agentKind: String,
        sessionID: String,
        eventID: UUID,
        requestID: String?,
        prompt: String?,
        options: [String]?
    ) -> String? {
        queue.sync {
            guard let requestID, !requestID.isEmpty else { return FeedNoteError.unmatched.rawValue }
            let live = journal[panelID] ?? JournalCoordinator.shared.snapshot(panelID: panelID)
            guard let live,
                  FeedProjector.blockingKind(live) != nil,
                  live.requestID == requestID,
                  self.currentAskEventIDs[panelID] == eventID,
                  live.workspaceID == workspaceID,
                  live.owner.panelID == panelID,
                  live.owner.agentKind == agentKind,
                  live.owner.sessionID == sessionID else {
                return FeedNoteError.unmatched.rawValue
            }
            if journal[panelID] == nil { journal[panelID] = live }
            let note = FeedDisplayNote(eventID: eventID, requestID: requestID, prompt: prompt, options: options)
            do {
                try cache.store(panelID: panelID, note: note)
                refreshProjection()
                return nil
            } catch let error as FeedNoteError {
                return error.rawValue
            } catch {
                return FeedNoteError.unmatched.rawValue
            }
        }
    }

    func list(scope: FeedScope) -> [String: Any] {
        queue.sync {
            let rows = scope == .all ? projected.rows : projected.attentionRows
            return [
                "scope": scope.rawValue,
                "instance": EventEmitter.shared.currentInstance() ?? NSNull(),
                "rows": rows.map { $0.jsonObject() },
            ]
        }
    }
}
