import Foundation

/// View state only. Filtering never mutates the Feed or attention-jump candidates.
struct FeedQuickViewSelection: Equatable {
    enum Filter: CaseIterable { case asks, turns }
    private(set) var filter: Filter = .asks
    private(set) var selectedTabID: UUID?
    private(set) var visibleTabIDs: [UUID] = []

    mutating func update(_ tabIDs: [UUID]) {
        let oldIndex = selectedTabID.flatMap { visibleTabIDs.firstIndex(of: $0) } ?? 0
        visibleTabIDs = tabIDs
        if let selectedTabID, tabIDs.contains(selectedTabID) { return }
        selectedTabID = tabIDs.isEmpty ? nil : tabIDs[min(oldIndex, tabIDs.count - 1)]
    }

    mutating func switchFilter(_ filter: Filter, tabIDs: [UUID]) {
        self.filter = filter
        visibleTabIDs = tabIDs
        if let selectedTabID, tabIDs.contains(selectedTabID) { return }
        selectedTabID = tabIDs.first
    }

    mutating func select(_ tabID: UUID) {
        guard visibleTabIDs.contains(tabID) else { return }
        selectedTabID = tabID
    }

    mutating func move(_ delta: Int) {
        guard !visibleTabIDs.isEmpty else { return }
        let index = selectedTabID.flatMap { visibleTabIDs.firstIndex(of: $0) } ?? 0
        selectedTabID = visibleTabIDs[min(max(0, index + delta), visibleTabIDs.count - 1)]
    }
}
