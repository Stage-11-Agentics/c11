import Foundation

/// Pure value type mapping raw unread count → presentation state for the
/// jump-to-latest-unread status-bar button. Kept free of SwiftUI and AppKit
/// so it is trivially unit-testable under the `cmuxTests` target.
struct StatusBarButtonDisplay: Equatable {
    let unreadCount: Int
    let isEnabled: Bool
    let badgeText: String?

    init(unreadCount: Int) {
        let count = max(0, unreadCount)
        self.unreadCount = count
        self.isEnabled = count > 0
        self.badgeText = Self.badgeText(for: count)
    }

    /// Two-digit cap matches `MenuBarBadgeLabelFormatter.badgeText(for:)`
    /// (AppDelegate.swift) and `TerminalNotificationStore.dockBadgeLabel`
    /// so the bar agrees with the menu-bar and dock surfaces.
    private static func badgeText(for count: Int) -> String? {
        guard count > 0 else { return nil }
        if count > 99 { return "99+" }
        return String(count)
    }
}
