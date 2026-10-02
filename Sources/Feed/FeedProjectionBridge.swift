import Foundation

/// Applies journal and attention snapshots off the keystroke path.
/// Ask events come only from blocked-request changes. Scope, suppression, and display notes do not emit them.
/// `feed.list` reads the cached inputs on the socket worker. This ticket has no UI consumer,
/// so publishing does not hop to main.
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

    init() {}

    func noteJournal(tabID: UUID, snapshot: JournalSnapshot?, eventID: UUID? = nil) {
        let snapshot = snapshot
        queue.async { [self] in
            if let snapshot {
                let prior = self.journal[tabID]
                self.journal[tabID] = snapshot
                let sameAsk = prior.flatMap(FeedProjector.blockingKind) == FeedProjector.blockingKind(snapshot)
                    && prior?.requestID == snapshot.requestID
                if FeedProjector.blockingKind(snapshot) != nil, snapshot.confirmation == .confirmed {
                    if let eventID {
                        self.currentAskEventIDs[tabID] = eventID
                    } else if !sameAsk {
                        self.currentAskEventIDs.removeValue(forKey: tabID)
                    }
                } else {
                    self.currentAskEventIDs.removeValue(forKey: tabID)
                }
            } else {
                self.journal.removeValue(forKey: tabID)
                self.currentAskEventIDs.removeValue(forKey: tabID)
                self.cache.drop(tabID: tabID)
            }
            let events = self.tracker.consume(tabID: tabID, snapshot: snapshot)
            for event in events {
                let payload = event.jsonObject()
                if event.action == .opened {
                    EventEmitter.shared.emitAskOpened(workspace: event.workspaceID, surface: event.tabID, payload: payload)
                } else {
                    EventEmitter.shared.emitAskClosed(workspace: event.workspaceID, surface: event.tabID, payload: payload)
                }
            }
            self.cache.prune(openRequests: self.journal.mapValues { snap in
                FeedProjector.blockingKind(snap) == nil ? nil : snap.requestID
            })
        }
    }

    func noteAttention(_ snapshot: TabAttentionSnapshot) {
        let fact = FeedAttentionFact(
            workspaceID: snapshot.workspaceId,
            tabID: snapshot.surfaceId,
            flagReason: snapshot.flagReason,
            flagRaisedAtMs: snapshot.flagRaisedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
            flagCallerTabID: snapshot.flagCallerTabId,
            suppressed: snapshot.suppressed
        )
        queue.async { [self] in
            if fact.isFlagged || fact.suppressed {
                self.attention[fact.tabID] = fact
            } else {
                self.attention.removeValue(forKey: fact.tabID)
            }
        }
    }

    func replaceAttention(_ snapshots: [TabAttentionSnapshot]) {
        let facts = snapshots.map { snapshot in
            FeedAttentionFact(
                workspaceID: snapshot.workspaceId,
                tabID: snapshot.surfaceId,
                flagReason: snapshot.flagReason,
                flagRaisedAtMs: snapshot.flagRaisedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                flagCallerTabID: snapshot.flagCallerTabId,
                suppressed: snapshot.suppressed
            )
        }
        queue.async { [self] in
            self.attention = Dictionary(uniqueKeysWithValues: facts.map { ($0.tabID, $0) })
        }
    }

    /// Returns a fixed error code, or nil when the note is cached.
    func acceptNote(
        tabID: UUID,
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
            let live = journal[tabID] ?? JournalCoordinator.shared.snapshot(tabID: tabID)
            guard let live,
                  FeedProjector.blockingKind(live) != nil,
                  live.requestID == requestID,
                  self.currentAskEventIDs[tabID] == eventID,
                  live.workspaceID == workspaceID,
                  live.owner.tabID == tabID,
                  live.owner.agentKind == agentKind,
                  live.owner.sessionID == sessionID else {
                return FeedNoteError.unmatched.rawValue
            }
            if journal[tabID] == nil { journal[tabID] = live }
            let note = FeedDisplayNote(eventID: eventID, requestID: requestID, prompt: prompt, options: options)
            do {
                try cache.store(tabID: tabID, note: note)
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
            let rows = FeedProjector.project(
                journalRows: Array(journal.values),
                attention: Array(attention.values),
                notes: cache.notesByTab(),
                scope: scope
            )
            return [
                "scope": scope.rawValue,
                "instance": EventEmitter.shared.currentInstance() ?? NSNull(),
                "rows": rows.map { $0.jsonObject() },
            ]
        }
    }
}
