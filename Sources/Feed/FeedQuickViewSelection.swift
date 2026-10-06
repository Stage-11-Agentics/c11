import Foundation

/// View state only. Filtering never mutates the Feed or attention-jump candidates.
struct FeedQuickViewSelection: Equatable {
    enum Filter: CaseIterable { case asks, turns }
    private(set) var filter: Filter = .asks
    private(set) var selectedPanelID: UUID?
    private(set) var visiblePanelIDs: [UUID] = []

    mutating func update(_ panelIDs: [UUID]) {
        let oldIndex = selectedPanelID.flatMap { visiblePanelIDs.firstIndex(of: $0) } ?? 0
        visiblePanelIDs = panelIDs
        if let selectedPanelID, panelIDs.contains(selectedPanelID) { return }
        selectedPanelID = panelIDs.isEmpty ? nil : panelIDs[min(oldIndex, panelIDs.count - 1)]
    }

    mutating func switchFilter(_ filter: Filter, panelIDs: [UUID]) {
        self.filter = filter
        visiblePanelIDs = panelIDs
        if let selectedPanelID, panelIDs.contains(selectedPanelID) { return }
        selectedPanelID = panelIDs.first
    }

    mutating func select(_ panelID: UUID) {
        guard visiblePanelIDs.contains(panelID) else { return }
        selectedPanelID = panelID
    }

    mutating func move(_ delta: Int) {
        guard !visiblePanelIDs.isEmpty else { return }
        let index = selectedPanelID.flatMap { visiblePanelIDs.firstIndex(of: $0) } ?? 0
        selectedPanelID = visiblePanelIDs[min(max(0, index + delta), visiblePanelIDs.count - 1)]
    }
}
