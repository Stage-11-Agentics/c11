import AppKit
import SwiftUI

/// Resolved chrome colors used for the Settings-row thumbnails.
///
/// The existing System/Light/Dark thumbnails re-render through these tokens so they
/// serve as the live preview canvas — no separate preview pane needed.
public struct ChromeThemeTokens: Equatable, Sendable {
    public let background: NSColor
    public let surface: NSColor
    public let accent: NSColor
    public let foreground: NSColor
    public let separator: NSColor

    public init(background: NSColor, surface: NSColor, accent: NSColor, foreground: NSColor, separator: NSColor) {
        self.background = background
        self.surface = surface
        self.accent = accent
        self.foreground = foreground
        self.separator = separator
    }

    public static func resolve(for theme: C11muxTheme, scheme: ThemeContext.ColorScheme) -> ChromeThemeTokens {
        let snapshot = ResolvedThemeSnapshot(theme: theme)
        let ctx = ThemeContext(
            workspaceColor: nil,
            colorScheme: scheme,
            ghosttyBackgroundGeneration: 0
        )
        let titleBarBg = snapshot.resolveColor(role: .titleBar_background, context: ctx)
            ?? NSColor(white: scheme == .dark ? 0.12 : 0.98, alpha: 1)
        let tintBase = snapshot.resolveColor(role: .sidebar_tintBase, context: ctx)
            ?? NSColor(white: scheme == .dark ? 0.06 : 0.94, alpha: 1)
        let accent = snapshot.resolveColor(role: .sidebar_activeTabRailFallback, context: ctx)
            ?? NSColor.systemBlue
        let fg = snapshot.resolveColor(role: .titleBar_foreground, context: ctx)
            ?? NSColor.labelColor
        let sep = snapshot.resolveColor(role: .dividers_color, context: ctx)
            ?? NSColor.separatorColor

        return ChromeThemeTokens(
            background: tintBase,
            surface: titleBarBg,
            accent: accent,
            foreground: fg,
            separator: sep
        )
    }
}

