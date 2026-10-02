import Foundation

enum JournalReplayPolicy {
    static func restored(_ baseline: JournalSnapshot) -> JournalSnapshot {
        var copy = baseline
        copy.confirmation = .unconfirmed
        copy.connection = .disconnected
        return copy
    }

    static func attention(_ baseline: JournalSnapshot, matching owner: JournalOwner?) -> JournalSnapshot? {
        guard baseline.owner == owner, baseline.paintsAttention else { return nil }
        return restored(baseline)
    }
}
