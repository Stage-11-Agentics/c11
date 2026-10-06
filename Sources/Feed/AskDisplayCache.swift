import Foundation

/// Process-local prompt text. Discarded on exit. Never written to the journal or the event log.
final class AskDisplayCache: @unchecked Sendable {
    static let maxNotes = FeedNoteLimits.maxNotes
    static let maxBytes = FeedNoteLimits.maxBytes
    static let maxPromptBytes = FeedNoteLimits.maxPromptBytes
    static let maxOptions = FeedNoteLimits.maxOptions
    static let maxLabelBytes = FeedNoteLimits.maxLabelBytes

    private struct Stored {
        var note: FeedDisplayNote
        var panelID: UUID
        var bytes: Int
    }

    private var byEvent: [UUID: Stored] = [:]
    private var byRequest: [UUID: [String: UUID]] = [:]
    private var totalBytes = 0

    var count: Int { byEvent.count }
    var accountedBytes: Int { totalBytes }

    func note(panelID: UUID, requestID: String) -> FeedDisplayNote? {
        guard let eventID = byRequest[panelID]?[requestID] else { return nil }
        return byEvent[eventID]?.note
    }

    func notesByPanel() -> [UUID: [String: FeedDisplayNote]] {
        var result: [UUID: [String: FeedDisplayNote]] = [:]
        for stored in byEvent.values {
            result[stored.panelID, default: [:]][stored.note.requestID] = stored.note
        }
        return result
    }

    func store(panelID: UUID, note: FeedDisplayNote) throws {
        let bytes = Self.accountedBytes(prompt: note.prompt, options: note.options)
        try Self.validateBounds(prompt: note.prompt, options: note.options)
        let previous = byEvent[note.eventID]
        let replacingRequest = byRequest[panelID]?[note.requestID]
        let previousForRequest = replacingRequest.flatMap { byEvent[$0] }
        var nextBytes = totalBytes + bytes
        var nextCount = byEvent.count + 1
        if let previous {
            nextBytes -= previous.bytes
            nextCount -= 1
        }
        if let previousForRequest, previousForRequest.note.eventID != note.eventID {
            nextBytes -= previousForRequest.bytes
            nextCount -= 1
        }
        guard nextCount <= Self.maxNotes, nextBytes <= Self.maxBytes else { throw FeedNoteError.overflow }
        if let previous, previous.panelID != panelID || previous.note.requestID != note.requestID {
            byRequest[previous.panelID]?[previous.note.requestID] = nil
        }
        if let previousForRequest, previousForRequest.note.eventID != note.eventID {
            byEvent.removeValue(forKey: previousForRequest.note.eventID)
            byRequest[previousForRequest.panelID]?[previousForRequest.note.requestID] = nil
        }
        byEvent[note.eventID] = Stored(note: note, panelID: panelID, bytes: bytes)
        byRequest[panelID, default: [:]][note.requestID] = note.eventID
        totalBytes = nextBytes
    }

    func prune(openRequests: [UUID: String?]) {
        let open = openRequests.compactMapValues { $0 }
        let stale = byEvent.values.filter { open[$0.panelID] != $0.note.requestID }.map(\.note.eventID)
        for eventID in stale { drop(eventID: eventID) }
    }

    func drop(panelID: UUID) {
        let ids = Array(byRequest[panelID]?.values ?? Dictionary<String, UUID>().values)
        for eventID in ids { drop(eventID: eventID) }
        byRequest.removeValue(forKey: panelID)
    }

    private func drop(eventID: UUID) {
        guard let stored = byEvent.removeValue(forKey: eventID) else { return }
        totalBytes -= stored.bytes
        if byRequest[stored.panelID]?[stored.note.requestID] == eventID {
            byRequest[stored.panelID]?[stored.note.requestID] = nil
        }
    }

    static func accountedBytes(prompt: String?, options: [String]?) -> Int {
        (prompt?.utf8.count ?? 0) + (options ?? []).reduce(0) { $0 + $1.utf8.count }
    }

    static func validateBounds(prompt: String?, options: [String]?) throws {
        if let prompt, prompt.utf8.count > maxPromptBytes { throw FeedNoteError.oversize }
        if let options {
            if options.count > maxOptions { throw FeedNoteError.oversize }
            if options.contains(where: { $0.utf8.count > maxLabelBytes }) { throw FeedNoteError.oversize }
        }
    }
}
