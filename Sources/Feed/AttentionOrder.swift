import Foundation

/// Shared presentation order, not another lifecycle reducer. Missing clocks sort last.
enum AttentionOrder {
    struct Target: Hashable {
        let workspaceID: UUID
        let panelID: UUID
    }

    struct Candidate: Equatable {
        let target: Target
        let notificationID: UUID?
    }

    struct UnreadFact {
        let target: Target
        let notificationID: UUID
        let createdAt: Date
    }

    static func precedes(time lhsTime: Int64?, target lhs: Target, time rhsTime: Int64?, target rhs: Target) -> Bool {
        if lhsTime != rhsTime {
            guard let lhsTime else { return false }
            guard let rhsTime else { return true }
            return lhsTime < rhsTime
        }
        if lhs.panelID != rhs.panelID { return lhs.panelID.uuidString < rhs.panelID.uuidString }
        return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
    }

    static func isOpenAsk(_ row: FeedRow) -> Bool {
        row.blocking == true && row.state == "open" && [.question, .plan, .permission].contains(row.kind)
    }

    static func ordered(_ rows: [FeedRow]) -> [FeedRow] {
        rows.sorted { lhs, rhs in
            func tier(_ row: FeedRow) -> Int { row.flag != nil ? 0 : (isOpenAsk(row) ? 1 : 2) }
            if tier(lhs) != tier(rhs) { return tier(lhs) < tier(rhs) }
            return precedes(
                time: lhs.flag != nil ? lhs.flag?.raisedAtMs : lhs.openedAtMs,
                target: Target(workspaceID: lhs.workspaceID, panelID: lhs.panelID),
                time: rhs.flag != nil ? rhs.flag?.raisedAtMs : rhs.openedAtMs,
                target: Target(workspaceID: rhs.workspaceID, panelID: rhs.panelID)
            )
        }
    }

    static func unreadTail(_ facts: [UnreadFact]) -> [Candidate] {
        let ordered = facts.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            if lhs.target != rhs.target {
                return precedes(time: nil, target: lhs.target, time: nil, target: rhs.target)
            }
            return lhs.notificationID.uuidString < rhs.notificationID.uuidString
        }
        var seen: Set<Target> = []
        return ordered.compactMap { fact in
            guard seen.insert(fact.target).inserted else { return nil }
            return Candidate(target: fact.target, notificationID: fact.notificationID)
        }
    }

    /// Prefix is already ordered by the Feed projector. No sort on a keypress.
    static func candidates(rows: [FeedRow], unreadTail: [Candidate]) -> [Candidate] {
        var seen: Set<Target> = []
        let prefix = rows.compactMap { row -> Candidate? in
            guard row.flag != nil || isOpenAsk(row) else { return nil }
            let target = Target(workspaceID: row.workspaceID, panelID: row.panelID)
            guard seen.insert(target).inserted else { return nil }
            return Candidate(target: target, notificationID: nil)
        }
        return prefix + unreadTail.filter { seen.insert($0.target).inserted }
    }

    @discardableResult
    static func openFirst(_ candidates: [Candidate], open: (Candidate) -> Bool) -> Candidate? {
        candidates.first(where: open)
    }
}

struct FeedProjectionSnapshot: Equatable {
    let rows: [FeedRow]
    static let empty = FeedProjectionSnapshot(rows: [])
    var attentionRows: [FeedRow] {
        rows.filter { $0.flag != nil || AttentionOrder.isOpenAsk($0) }.map { row in
            guard row.kind == .turnEnd else { return row }
            // A finished turn may still carry a flag; attention presents just that flag.
            return FeedRow(workspaceID: row.workspaceID, panelID: row.panelID, kind: nil,
                prompt: nil, options: nil, promptAvailable: false, source: nil, sourceRank: nil,
                openedAtMs: nil, state: nil, requestID: nil, confirmation: nil, blocking: nil, flag: row.flag)
        }
    }
    var flagCount: Int { rows.lazy.filter { $0.flag != nil }.count }
    var openAskCount: Int { rows.lazy.filter(AttentionOrder.isOpenAsk).count }
}
