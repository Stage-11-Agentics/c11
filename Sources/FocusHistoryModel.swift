import Foundation
import CoreFoundation

/// Bounded attention metadata. Never stores titles, paths, URLs or transcript text.
struct FocusHistoryEntry: Equatable, Codable, Sendable {
    var workspaceId: UUID
    var panelId: UUID
    var seenAt: Date
    var dwell: TimeInterval
}

struct FocusHistorySnapshot: Codable, Equatable, Sendable {
    var entries: [FocusHistoryEntry]
    var index: Int?
}

struct FocusHistoryLocation: Equatable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
}

struct FocusHistoryNavigationState: Equatable {
    var back: FocusHistoryEntry?
    var forward: FocusHistoryEntry?
}

/// Event-driven seen history; the caller supplies time and live target locations.
struct FocusHistoryModel {
    static let defaultThreshold: TimeInterval = 1
    static let cap = 200
    let threshold: TimeInterval
    private(set) var entries: [FocusHistoryEntry] = []
    private(set) var index: Int?
    private var open: (workspaceId: UUID, panelId: UUID, startedAt: Date)?
    private var suppressLanding = false

    init(threshold: TimeInterval = Self.defaultThreshold) {
        self.threshold = threshold.isFinite ? max(0.2, min(30, threshold)) : Self.defaultThreshold
    }

    mutating func noteSeen(workspaceId: UUID?, panelId: UUID?, at now: Date) {
        if let panelId, let workspaceId, open?.panelId == panelId {
            open?.workspaceId = workspaceId
            return
        }
        finishVisit(at: now)
        if let workspaceId, let panelId {
            open = (workspaceId, panelId, now)
        }
    }

    private mutating func finishVisit(at now: Date, checkpoint: Bool = false) {
        guard let visit = open else { return }
        open = nil
        let dwell = now.timeIntervalSince(visit.startedAt)
        guard dwell.isFinite, dwell >= 0, checkpoint || dwell >= threshold else { return }
        let entry = FocusHistoryEntry(workspaceId: visit.workspaceId, panelId: visit.panelId,
                                      seenAt: visit.startedAt, dwell: dwell)
        append(entry)
    }

    private mutating func append(_ entry: FocusHistoryEntry) {
        if let index, entries[index].panelId == entry.panelId {
            // Repeated traversal landings preserve both the row and the forward branch.
            if !suppressLanding { entries[index] = entry }
            return
        }
        suppressLanding = false
        if let index { entries.removeSubrange((index + 1)..<entries.count) }
        entries.append(entry)
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
        index = entries.count - 1
    }

    /// Explicit user jumps retain both endpoints, even with no dwell. The caller
    /// brackets the whole jump so intermediate focus callbacks cannot add rows.
    mutating func recordExplicitJump(from source: FocusHistoryLocation?, to destination: FocusHistoryLocation,
                                     departedAt: Date, arrivedAt: Date) {
        guard source?.panelId != destination.panelId else { return }
        if let source {
            let startedAt = open?.panelId == source.panelId ? open!.startedAt : departedAt
            let dwell = departedAt.timeIntervalSince(startedAt)
            guard dwell.isFinite, dwell >= 0 else { return }
            append(FocusHistoryEntry(workspaceId: source.workspaceId, panelId: source.panelId,
                                     seenAt: startedAt, dwell: dwell))
        }
        append(FocusHistoryEntry(workspaceId: destination.workspaceId, panelId: destination.panelId,
                                 seenAt: arrivedAt, dwell: 0))
        open = (destination.workspaceId, destination.panelId, arrivedAt)
    }

    /// Finalize the source before moving the cursor. Restart it for a boundary no-op.
    mutating func prepareForNavigation(at now: Date) {
        let previous = open
        finishVisit(at: now, checkpoint: true)
        if let previous { open = (previous.workspaceId, previous.panelId, now) }
    }

    mutating func back(isLive: (UUID) -> Bool) -> FocusHistoryEntry? {
        step(back: true, isLive: isLive)
    }

    mutating func forward(isLive: (UUID) -> Bool) -> FocusHistoryEntry? {
        step(back: false, isLive: isLive)
    }

    /// Button/menu availability uses the same preparation and traversal as a
    /// click, including the current open visit, without consuming a history step.
    func navigationState(at now: Date, workspaceFor: (FocusHistoryEntry) -> UUID?) -> FocusHistoryNavigationState {
        var prepared = self
        prepared.reconcile(workspaceFor: workspaceFor)
        prepared.prepareForNavigation(at: now)
        var back = prepared
        var forward = prepared
        return FocusHistoryNavigationState(back: back.back(isLive: { _ in true }),
                                           forward: forward.forward(isLive: { _ in true }))
    }

    private mutating func step(back: Bool, isLive: (UUID) -> Bool) -> FocusHistoryEntry? {
        reconcile { entry in isLive(entry.panelId) ? entry.workspaceId : nil }
        guard let index else { return nil }
        var destination = index + (back ? -1 : 1)
        while entries.indices.contains(destination), entries[destination].panelId == entries[index].panelId {
            destination += back ? -1 : 1
        }
        guard entries.indices.contains(destination) else { return nil }
        self.index = destination
        suppressLanding = true
        // Selection emits the next seen transition. Do not finish the source twice.
        open = nil
        return entries[destination]
    }

    mutating func prune(panelId: UUID) {
        if open?.panelId == panelId { open = nil }
        removeEntries { $0.panelId == panelId }
    }

    private mutating func removeEntries(where shouldRemove: (FocusHistoryEntry) -> Bool) {
        let oldIndex = index
        var newIndex: Int?
        var survivors: [FocusHistoryEntry] = []
        for (offset, entry) in entries.enumerated() {
            if shouldRemove(entry) {
                if offset == oldIndex { suppressLanding = false }
                continue
            }
            if let oldIndex, offset <= oldIndex { newIndex = survivors.count }
            survivors.append(entry)
        }
        entries = survivors
        index = survivors.isEmpty ? nil : (newIndex ?? 0)
    }

    /// UUID lookup repairs moves and removes closed targets without reopening anything.
    mutating func reconcile(workspaceFor: (FocusHistoryEntry) -> UUID?) {
        removeEntries { workspaceFor($0) == nil }
        for offset in entries.indices {
            if let workspaceId = workspaceFor(entries[offset]) { entries[offset].workspaceId = workspaceId }
        }
    }

    func snapshot() -> FocusHistorySnapshot { FocusHistorySnapshot(entries: entries, index: index) }

    mutating func restore(_ snapshot: FocusHistorySnapshot) {
        // Decode/restore stays bounded, including older or malformed oversized payloads.
        let valid = snapshot.entries.enumerated().filter {
            $0.element.dwell.isFinite && $0.element.dwell >= 0 &&
            $0.element.seenAt.timeIntervalSince1970.isFinite
        }
        let retained = Array(valid.suffix(Self.cap))
        entries = retained.map(\.element)
        if entries.isEmpty {
            index = nil
        } else if let original = snapshot.index {
            index = retained.lastIndex(where: { $0.offset <= original }) ?? 0
        } else {
            index = entries.count - 1
        }
        open = nil
        suppressLanding = false
    }
}

/// Shared by the worker handler and behavioral tests. JSON booleans/floats are not limits.
enum FocusHistoryLimit {
    static let error = "limit must be an integer from 1 to 200"
    static func parse(_ value: Any?) -> Int? {
        guard let value else { return 50 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.int64Value >= 1, number.int64Value <= Int64(FocusHistoryModel.cap) else { return nil }
        return number.intValue
    }
}
