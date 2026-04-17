import AppKit
import SwiftUI

/// Theme choice for a markdown panel. `auto` follows the macOS appearance;
/// `gold` is the Stage 11 brand theme (void background, gold accent).
enum MarkdownThemeChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case light
    case dark
    case gold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return String(localized: "markdown.theme.auto", defaultValue: "Auto")
        case .light: return String(localized: "markdown.theme.light", defaultValue: "Light")
        case .dark: return String(localized: "markdown.theme.dark", defaultValue: "Dark")
        case .gold: return String(localized: "markdown.theme.gold", defaultValue: "Stage 11 Gold")
        }
    }

    /// SF Symbol shown in the header toolbar for the current selection.
    var iconName: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .gold: return "sparkles"
        }
    }

    /// Next choice in the cycle order (Auto → Light → Dark → Gold → Auto …).
    var next: MarkdownThemeChoice {
        switch self {
        case .auto: return .light
        case .light: return .dark
        case .dark: return .gold
        case .gold: return .auto
        }
    }

    /// Resolve to a concrete palette given the current system ColorScheme.
    func palette(systemColorScheme: ColorScheme) -> MarkdownPalette {
        switch self {
        case .auto:
            return systemColorScheme == .dark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        case .gold:
            return .gold
        }
    }
}

/// Concrete color palette used by `MarkdownPanelView` when rendering content.
///
/// Each palette is a pre-baked set of colors for a single theme. Gold pulls
/// directly from `BrandColors` (the canonical Stage 11 palette); light and
/// dark mirror the pre-existing MarkdownUI styling so behavior is preserved
/// when the user opts to stay on system appearance.
struct MarkdownPalette {
    var isDark: Bool
    var background: Color
    var body: Color
    var heading: Color
    var secondary: Color
    var codeBlockBackground: Color
    var codeBlockForeground: Color
    var inlineCodeForeground: Color
    var inlineCodeBackground: Color
    var blockquoteBar: Color
    var blockquoteText: Color
    var link: Color
    var divider: Color
    var tableBorder: Color
    var tableRowA: Color
    var tableRowB: Color

    /// True if mermaid diagrams should render in their dark theme.
    var mermaidUsesDarkTheme: Bool { isDark }

    static let light = MarkdownPalette(
        isDark: false,
        background: Color(nsColor: NSColor(white: 0.98, alpha: 1.0)),
        body: .primary,
        heading: .primary,
        secondary: .secondary,
        codeBlockBackground: Color(nsColor: NSColor(white: 0.93, alpha: 1.0)),
        codeBlockForeground: Color(red: 0.2, green: 0.2, blue: 0.2),
        inlineCodeForeground: Color(red: 0.6, green: 0.2, blue: 0.7),
        inlineCodeBackground: Color(nsColor: NSColor(white: 0.92, alpha: 1.0)),
        blockquoteBar: Color.gray.opacity(0.4),
        blockquoteText: .secondary,
        link: .accentColor,
        divider: Color.gray.opacity(0.3),
        tableBorder: Color.gray.opacity(0.3),
        tableRowA: Color(nsColor: NSColor(white: 0.96, alpha: 1.0)),
        tableRowB: Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
    )

    static let dark = MarkdownPalette(
        isDark: true,
        background: Color(nsColor: NSColor(white: 0.12, alpha: 1.0)),
        body: .white.opacity(0.9),
        heading: .white,
        secondary: .white.opacity(0.6),
        codeBlockBackground: Color(nsColor: NSColor(white: 0.08, alpha: 1.0)),
        codeBlockForeground: Color(red: 0.9, green: 0.9, blue: 0.9),
        inlineCodeForeground: Color(red: 0.85, green: 0.6, blue: 0.95),
        inlineCodeBackground: Color(nsColor: NSColor(white: 0.18, alpha: 1.0)),
        blockquoteBar: Color.white.opacity(0.2),
        blockquoteText: .white.opacity(0.6),
        link: .accentColor,
        divider: Color.white.opacity(0.15),
        tableBorder: Color.white.opacity(0.15),
        tableRowA: Color(nsColor: NSColor(white: 0.14, alpha: 1.0)),
        tableRowB: Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
    )

    /// Stage 11 void-dominant palette. Gold is the single accent, used for
    /// headings, links, and inline code. Body text stays at `#e8e8e8` for
    /// extended-reading comfort.
    static let gold = MarkdownPalette(
        isDark: true,
        background: BrandColors.blackSwiftUI,
        body: BrandColors.whiteSwiftUI,
        heading: BrandColors.goldSwiftUI,
        secondary: BrandColors.dimSwiftUI,
        codeBlockBackground: BrandColors.surfaceSwiftUI,
        codeBlockForeground: BrandColors.whiteSwiftUI,
        inlineCodeForeground: BrandColors.goldSwiftUI,
        inlineCodeBackground: BrandColors.goldFaintSwiftUI,
        blockquoteBar: BrandColors.goldSwiftUI,
        blockquoteText: BrandColors.whiteSwiftUI.opacity(0.75),
        link: BrandColors.goldSwiftUI,
        divider: BrandColors.ruleSwiftUI,
        tableBorder: BrandColors.ruleSwiftUI,
        tableRowA: BrandColors.surfaceSwiftUI,
        tableRowB: BrandColors.blackSwiftUI
    )
}
