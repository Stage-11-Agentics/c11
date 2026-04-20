import AppKit
import SwiftUI

extension ThemeManager {
    /// Resolves the workspace's custom color to a display-ready `NSColor` through the
    /// same brightening pipeline used by sidebar tabs (`WorkspaceTabColorSettings.displayNSColor`).
    /// Returns `nil` when the workspace has no custom color set — callers should fall back to
    /// the theme's `$background` or a neutral surface color.
    ///
    /// Used by `WorkspaceFrame` and future chrome surfaces that need the `$workspaceColor`
    /// variable resolved against the current appearance before it enters the theme resolver.
    @MainActor
    public static func resolvedWorkspaceDisplayColor(
        hex: String?,
        colorScheme: ThemeContext.ColorScheme,
        forceBright: Bool = false
    ) -> NSColor? {
        guard let hex else { return nil }
        let swiftUIScheme: ColorScheme = colorScheme == .dark ? .dark : .light
        return WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: swiftUIScheme,
            forceBright: forceBright
        )
    }
}
