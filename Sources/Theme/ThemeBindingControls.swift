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

/// The two chrome-theme dropdowns + Apply-to-both / Open folder / Reload button row.
/// Composed beneath the existing System/Light/Dark thumbnails in `ThemePickerRow`.
struct ThemeBindingControls: View {
    @ObservedObject var themeManager: ThemeManager
    @AppStorage(ThemeManager.defaultLightSlotKey) private var activeLight: String = "stage11"
    @AppStorage(ThemeManager.defaultDarkSlotKey) private var activeDark: String = "stage11"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(String(
                    localized: "settings.app.theme.lightSlot",
                    defaultValue: "Light chrome:"
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)

                themeMenu(selection: $activeLight)
                    .frame(minWidth: 140)
            }

            HStack(alignment: .center, spacing: 10) {
                Text(String(
                    localized: "settings.app.theme.darkSlot",
                    defaultValue: "Dark chrome:"
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)

                themeMenu(selection: $activeDark)
                    .frame(minWidth: 140)
            }

            HStack(spacing: 8) {
                Button(String(
                    localized: "settings.app.theme.applyToBoth",
                    defaultValue: "Apply to both"
                )) {
                    activeDark = activeLight
                }
                .controlSize(.small)

                Button(String(
                    localized: "settings.app.theme.openFolder",
                    defaultValue: "Open themes folder"
                )) {
                    openThemesFolder()
                }
                .controlSize(.small)

                Button(String(
                    localized: "settings.app.theme.reload",
                    defaultValue: "Reload"
                )) {
                    themeManager.forceReloadUserThemes()
                }
                .controlSize(.small)
            }
        }
        .onChange(of: activeLight) { _ in themeManager.forceReloadUserThemes() }
        .onChange(of: activeDark) { _ in themeManager.forceReloadUserThemes() }
    }

    @ViewBuilder
    private func themeMenu(selection: Binding<String>) -> some View {
        Picker(selection: selection, label: EmptyView()) {
            ForEach(themeManager.availableThemes, id: \.identity.name) { descriptor in
                HStack(spacing: 6) {
                    Text(descriptor.identity.displayName)
                    if descriptor.source == .builtin {
                        Text(String(
                            localized: "settings.app.theme.builtinBadge",
                            defaultValue: "Built-in"
                        ))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    if descriptor.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
                .tag(descriptor.identity.name)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func openThemesFolder() {
        let url = themeManager.userThemesDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
