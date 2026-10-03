import Foundation

struct FeedAnswerProjectionRow: Equatable {
    let row: FeedRow
    let owner: JournalOwner?
    let sequence: Int64?
    let askEventID: UUID?
}

enum FeedAnswerStartKind: Equatable {
    case flag
    case turnEnd
}

/// Identity of the feed row a reply was submitted for. The journal sequence
/// prevents a delayed Return from answering a later ask in the same tab.
struct FeedAnswerIdentity: Equatable {
    let workspaceID: UUID
    let tabID: UUID
    let owner: JournalOwner
    let sequence: Int64
    let askEventID: UUID?
    let startKind: FeedAnswerStartKind
    let flagEpoch: Date?
}

enum FeedAnswerEligibility {
    static func capture(
        workspaceID: UUID,
        tabID: UUID,
        targetWorkspaceID: UUID?,
        owner: JournalOwner?,
        snapshot: JournalSnapshot?,
        attention: TabAttentionSnapshot,
        projectedRow: FeedAnswerProjectionRow?
    ) -> FeedAnswerIdentity? {
        guard targetWorkspaceID == workspaceID,
              let owner,
              let snapshot,
              let projectedRow,
              owner == snapshot.owner,
              owner.tabID == tabID,
              snapshot.workspaceID == workspaceID,
              projectedRow.row.workspaceID == workspaceID,
              projectedRow.row.tabID == tabID,
              projectedRow.owner == owner,
              projectedRow.sequence == snapshot.lastSequence,
              attention.isFlagged ? projectedRow.row.flag != nil : projectedRow.row.kind == .turnEnd,
              FeedProjector.blockingKind(snapshot) == nil,
              attention.workspaceId == workspaceID,
              attention.surfaceId == tabID else { return nil }

        if attention.isFlagged {
            guard let epoch = attention.flagRaisedAt else { return nil }
            return FeedAnswerIdentity(
                workspaceID: workspaceID,
                tabID: tabID,
                owner: owner,
                sequence: snapshot.lastSequence,
                askEventID: projectedRow.askEventID,
                startKind: .flag,
                flagEpoch: epoch
            )
        }
        guard FeedProjector.isTurnEnd(snapshot) else { return nil }
        return FeedAnswerIdentity(
            workspaceID: workspaceID,
            tabID: tabID,
            owner: owner,
            sequence: snapshot.lastSequence,
            askEventID: projectedRow.askEventID,
            startKind: .turnEnd,
            flagEpoch: nil
        )
    }

    /// Rechecks the exact row before the delayed Return. A replaced flag epoch
    /// remains an eligible target, but it cannot be lowered by this reply.
    static func stillEligible(
        _ identity: FeedAnswerIdentity,
        targetWorkspaceID: UUID?,
        owner: JournalOwner?,
        snapshot: JournalSnapshot?,
        attention: TabAttentionSnapshot
    ) -> Bool {
        guard targetWorkspaceID == identity.workspaceID,
              owner == identity.owner,
              let snapshot,
              snapshot.owner == identity.owner,
              snapshot.workspaceID == identity.workspaceID,
              snapshot.lastSequence == identity.sequence,
              FeedProjector.blockingKind(snapshot) == nil,
              attention.workspaceId == identity.workspaceID,
              attention.surfaceId == identity.tabID else { return false }

        switch identity.startKind {
        case .flag:
            return attention.isFlagged && attention.flagRaisedAt != nil
        case .turnEnd:
            return FeedProjector.isTurnEnd(snapshot)
        }
    }
}

enum FeedAnswerSubmitOutcome: Equatable {
    case targetLost
    case pastedNotSubmitted
    case submitUnconfirmed
    case submitted(flagLowered: Bool, flagEpoch: String?)
}

enum FeedAnswerTextPolicy {
    static func refusalCode(for text: String) -> String? {
        text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
            ? "multiline_unsupported"
            : nil
    }
}

enum FeedAnswerTiming {
    // Give pasted text a bounded settle period before the exact composer and
    // target checks that guard the synthetic Return.
    static let additionalPasteSettleMilliseconds = 350

    static func returnDelayMilliseconds(baseDelayMs: Int, debugHoldMs: Int) -> Int {
        max(0, baseDelayMs) + additionalPasteSettleMilliseconds + max(0, debugHoldMs)
    }
}

enum FeedAnswerComposerCheck: Equatable {
    case matches
    case notVisible
    case changed

    static func compare(state: PromptInputState, composer: String?, expected: String) -> Self {
        switch state {
        case .empty, .suggestion:
            return .notVisible
        case .draft:
            guard let composer else { return .changed }
            if composer == expected { return .matches }
            return expected.hasPrefix(composer) ? .notVisible : .changed
        case .dialog, .unknown, .unavailable:
            return .changed
        }
    }
}

/// Last check before the delayed Return. This stays in the logic layer so the
/// close-during-paste race exercises the same fail-closed decision in tests
/// and in the terminal commit path.
enum FeedAnswerPreReturnCheck {
    static func outcome(
        targetIsCurrent: Bool,
        rowIsCurrent: Bool,
        operatorInputUnchanged: Bool,
        composer: FeedAnswerComposerCheck?
    ) -> FeedAnswerSubmitOutcome? {
        guard targetIsCurrent else { return .targetLost }
        guard rowIsCurrent, operatorInputUnchanged else { return .pastedNotSubmitted }
        guard let composer else { return nil }
        switch composer {
        case .matches: return nil
        case .notVisible: return .submitUnconfirmed
        case .changed: return .pastedNotSubmitted
        }
    }
}

struct FeedAnswerFailureDisposition: Equatable {
    let code: String
    let retry: String

    static func make(for outcome: FeedAnswerSubmitOutcome) -> Self? {
        switch outcome {
        case .targetLost: return Self(code: "target_lost", retry: "unsafe")
        case .pastedNotSubmitted: return Self(code: "pasted_not_submitted", retry: "unsafe")
        case .submitUnconfirmed: return Self(code: "submit_unconfirmed", retry: "unsafe")
        case .submitted: return nil
        }
    }
}

#if DEBUG
/// One-shot test control for holding a feed answer after paste, before its
/// Return callback is queued. It is absent from Release builds.
final class FeedAnswerDebugHold: @unchecked Sendable {
    static let shared = FeedAnswerDebugHold()

    private struct ArmedHold {
        let tabID: UUID
        let milliseconds: Int
    }

    private let lock = NSLock()
    private var armed: ArmedHold?

    @discardableResult
    func arm(tabID: UUID, milliseconds: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard armed == nil, (1...5_000).contains(milliseconds) else { return false }
        armed = ArmedHold(tabID: tabID, milliseconds: milliseconds)
        return true
    }

    func consume(tabID: UUID) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let armed, armed.tabID == tabID else { return nil }
        self.armed = nil
        return armed.milliseconds
    }

    func clear(tabID: UUID) {
        lock.lock()
        if armed?.tabID == tabID { armed = nil }
        lock.unlock()
    }
}
#endif

enum FeedAnswerFlagLowerOutcome {
    case lowered
    case replaced
    case unavailable
}

/// The caller supplies the result captured from `ghostty_surface_key`. A
/// failed/native-unconfirmed key path can never lower the flag or claim an answer.
enum FeedAnswerHandoff {
    static func outcome(
        nativeHandoff: Bool,
        startKind: FeedAnswerStartKind,
        lowerFlag: () -> FeedAnswerFlagLowerOutcome
    ) -> FeedAnswerSubmitOutcome {
        guard nativeHandoff else { return .submitUnconfirmed }
        guard startKind == .flag else { return .submitted(flagLowered: false, flagEpoch: nil) }
        switch lowerFlag() {
        case .lowered: return .submitted(flagLowered: true, flagEpoch: nil)
        case .replaced: return .submitted(flagLowered: false, flagEpoch: "replaced")
        case .unavailable: return .submitted(flagLowered: false, flagEpoch: "unavailable")
        }
    }
}

/// Coalesces only concurrent feed-answer calls for one tab. Other socket
/// commands retain their existing input-transaction behavior.
enum FeedAnswerInFlight {
    private static let lock = NSLock()
    private static var tabIDs: Set<UUID> = []

    static func begin(tabID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tabIDs.insert(tabID).inserted
    }

    static func end(tabID: UUID) {
        lock.lock()
        tabIDs.remove(tabID)
        lock.unlock()
    }
}
