import AppKit
import Bonsplit
import SwiftUI

// Feature views a schema-2 theme switches on under `[ornaments]`
// (docs/c11-theme-schema-2.md). Each is off unless the theme names it, and
// draws in space the layout already reserves: none changes a view's size.

enum ThemeOrnaments {
    /// `ornaments.scanlines` as an overlay opacity: nil when unset or not
    /// above 0 (off), capped at 1.
    static func scanlinesOpacity(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return min(value, 1)
    }

    /// The scanline opacity of the theme a window shows (the active theme when
    /// `windowThemeName` is nil); nil for schema-1 themes and when off.
    @MainActor
    static func scanlinesOpacity(_ manager: ThemeManager, windowThemeName: String? = nil) -> Double? {
        guard manager.themeOwnsChrome(windowThemeName: windowThemeName) else { return nil }
        let context = manager.makeContext(
            colorScheme: ThemeManager.currentColorScheme(),
            windowThemeName: windowThemeName
        )
        return scanlinesOpacity(manager.style(.ornamentScanlines, context: context))
    }
}

/// Lays the theme's scanlines over a chrome surface (titlebar, description
/// bar, sidebar). Never apply it to a view that holds terminal cells.
struct ThemeScanlinesModifier: ViewModifier {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.c11WindowThemeName) private var windowThemeName

    func body(content: Content) -> some View {
        content.overlay {
            if let opacity = ThemeOrnaments.scanlinesOpacity(themeManager, windowThemeName: windowThemeName) {
                BonsplitScanlines(opacity: opacity)
            }
        }
    }
}

extension View {
    /// The theme's scanline overlay on chrome; draws nothing unless a theme sets `ornaments.scanlines`.
    func themeScanlines() -> some View {
        modifier(ThemeScanlinesModifier())
    }
}

/// Big Board's titlebar clock (`ornaments.titlebarClock`): a LIVE tag in the
/// accent, this computer's name, the local time to the second and its zone,
/// tracked mono caps. It ticks once a second while it is on screen, and it
/// exists only while the active theme switches it on.
struct ThemeTitlebarClock: View {
    struct Style: Equatable {
        var accent: Color
        var primary: Color
        var secondary: Color
        /// The theme's `type.mono` family; nil is SF Mono.
        var monoFamily: String?
    }

    let style: Style
    var machineName: String = LocalSessionPlacementFeed.localHostName

    /// The theme's clock, or nil when the context's theme (the window's
    /// override, else the active theme) leaves it off.
    @MainActor
    static func style(
        _ manager: ThemeManager,
        context: ThemeContext,
        primary: Color,
        secondary: Color
    ) -> Style? {
        guard manager.themeOwnsChrome(context: context),
              (manager.style(.ornamentTitlebarClock, context: context) as Bool?) == true else { return nil }
        let theme = manager.theme(for: context)
        // The accent is the strip's active indicator when the theme names it
        // (Big Board's `$accent`), else the title's own colour.
        var accent = primary
        if theme.stringValue(for: .tabBar_activeIndicator) != nil,
           let color: NSColor = manager.resolve(.tabBar_activeIndicator, context: context) {
            accent = Color(nsColor: color)
        }
        var secondary = secondary
        if theme.stringValue(for: .titleBar_foregroundSecondary) != nil,
           let color: NSColor = manager.resolve(.titleBar_foregroundSecondary, context: context) {
            secondary = Color(nsColor: color)
        }
        let mono: String? = manager.style(.typeMono, context: context)
        return Style(accent: accent, primary: primary, secondary: secondary, monoFamily: mono)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 10) {
                Text(String(localized: "titlebar.clock.live", defaultValue: "LIVE"))
                    .font(font(9.5, weight: .semibold))
                    .tracking(9.5 * 0.12)
                    .foregroundColor(style.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Rectangle().strokeBorder(style.accent, lineWidth: 1))
                Text(machineName.uppercased())
                    .font(font(11))
                    .tracking(11 * 0.12)
                    .foregroundColor(style.secondary)
                    .lineLimit(1)
                Text(Self.timeText(timeline.date))
                    .font(font(15, weight: .semibold))
                    .monospacedDigit()
                    .tracking(15 * 0.1)
                    .foregroundColor(style.primary)
                Text(Self.zoneText(timeline.date))
                    .font(font(11))
                    .tracking(11 * 0.12)
                    .foregroundColor(style.secondary)
            }
            .fixedSize()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        ThemeFontFamily.font(named: style.monoFamily ?? "system-mono", size: size, weight: weight, defaultDesign: .monospaced)
    }

    /// `HH:MM:SS`, 24-hour, in `timeZone` (the Mac's own by default).
    nonisolated static func timeText(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let style = Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            timeZone: timeZone,
            calendar: calendar
        )
        return date.formatted(style)
    }

    /// The zone's short name at `date` (PST or PDT), else its GMT offset.
    nonisolated static func zoneText(_ date: Date, timeZone: TimeZone = .current) -> String {
        (timeZone.abbreviation(for: date) ?? timeZone.identifier).uppercased()
    }
}
