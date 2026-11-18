import AppKit
import SwiftUI

/// Settings > Appearance > Theme. Every theme as a live preview of the operator's own
/// window, cropped to its top-left corner: the title bar, the first workspace cards and a
/// sliver of terminal, painted through the same style code the real sidebar uses. A click
/// makes that theme the one theme and applies its paired terminal theme, if it names one.
struct ThemePreviewGallery: View {
    var body: some View {
        if let manager = AppDelegate.shared?.workspaceManager {
            LiveThemePreviewGallery(workspaceManager: manager)
        } else {
            ThemePreviewGalleryContent(workspaces: [], selectedWorkspaceId: nil)
        }
    }
}

private struct LiveThemePreviewGallery: View {
    @ObservedObject var workspaceManager: WorkspaceManager

    var body: some View {
        ThemePreviewGalleryContent(
            workspaces: Array(workspaceManager.workspaces.prefix(2)),
            selectedWorkspaceId: workspaceManager.selectedWorkspaceId
        )
    }
}

private struct ThemePreviewGalleryContent: View {
    let workspaces: [Workspace]
    let selectedWorkspaceId: UUID?

    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage(C11SidebarBackground.storageKey) private var sidebarBackground = C11SidebarBackground.defaultValue.rawValue
    @AppStorage(ChromeScaleSettings.presetKey) private var scalePresetRaw = ChromeScaleSettings.defaultPreset.rawValue
    @AppStorage(ChromeScaleSettings.customMultiplierKey) private var scaleCustom: Double = Double(ChromeScaleSettings.defaultCustomMultiplier)

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 300), spacing: 14, alignment: .top)]

    private var scale: CGFloat {
        ChromeScaleSettings.multiplier(presetRaw: scalePresetRaw, customMultiplier: scaleCustom)
    }

    /// The order Settings shows the bundled themes in: the house themes first.
    static let bundledOrder = ["stage11", "c11", "nocturne", "bigboard", "datasheet-mono", "terminal-grid", "outrun-horizon"]

    private var bundled: [ThemeManager.ThemeDescriptor] {
        themeManager.availableThemes
            .filter { $0.source == .builtin }
            .sorted { lhs, rhs in
                let order = Self.bundledOrder
                return (order.firstIndex(of: lhs.identity.name) ?? order.count, lhs.identity.name)
                    < (order.firstIndex(of: rhs.identity.name) ?? order.count, rhs.identity.name)
            }
    }

    private var yours: [ThemeManager.ThemeDescriptor] {
        themeManager.availableThemes.filter { $0.source == .user }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "settings.theme.gallery.subtitle",
                defaultValue: "Colors the window, the sidebar and the panel title bars. A theme marked + terminal also sets the terminal colors. Each preview is your own window in that theme."
            ))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            grid(bundled)

            HStack {
                Text(String(localized: "settings.theme.yourThemes", defaultValue: "Your themes"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(String(localized: "settings.theme.openFolder.button", defaultValue: "Open Folder")) {
                    openThemesFolder()
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("SettingsThemeOpenFolder")
                Button(String(localized: "settings.theme.reload.button", defaultValue: "Reload")) {
                    themeManager.forceReloadUserThemes()
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("SettingsThemeReload")
            }
            .padding(.top, 4)

            if yours.isEmpty {
                Text(String(localized: "settings.theme.yourThemes.empty", defaultValue: "Themes you add to the themes folder show here."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                grid(yours)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ descriptors: [ThemeManager.ThemeDescriptor]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(descriptors, id: \.identity.name) { descriptor in
                if let theme = themeManager.theme(named: descriptor.identity.name) {
                    tile(descriptor: descriptor, theme: theme)
                }
            }
        }
    }

    private func tile(descriptor: ThemeManager.ThemeDescriptor, theme: C11Theme) -> some View {
        let name = descriptor.identity.name
        let selected = name == themeManager.active.identity.name
        let pair = theme.pairedTerminalTheme
        return Button {
            ThemePicking.pick(name)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ThemeWindowPreview(
                    paint: ThemePreviewPaint.cached(theme: theme, sidebarBackground: sidebarBackground),
                    workspaces: workspaces,
                    selectedWorkspaceId: selectedWorkspaceId,
                    scale: scale
                )
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1)
                        .padding(selected ? -3 : 0)
                )
                HStack(spacing: 5) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                    }
                    Text(descriptor.identity.displayName).lineLimit(1)
                    if descriptor.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    }
                }
                .font(.callout)
                Text(pair == nil
                     ? String(localized: "settings.theme.pair.windowOnly", defaultValue: "window only")
                     : String(localized: "settings.theme.pair.terminal", defaultValue: "+ terminal"))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(descriptor.warning ?? descriptor.identity.displayName)
        .accessibilityIdentifier("SettingsThemeTile.\(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func openThemesFolder() {
        let url = themeManager.userThemesDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// What a Settings pick does: the theme becomes the one theme, and a theme that names a
/// paired terminal theme sets the terminal too, day and night, through the managed block in
/// this app's own `config.ghostty` (the block `themes set --with-terminal` writes). Returns
/// the config written, or nil when the terminal was left alone.
@MainActor
enum ThemePicking {
    @discardableResult
    static func pick(
        _ name: String,
        themes: ThemeManager = .shared,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        reload: () -> Void = { GhosttyApp.shared.reloadConfiguration(source: "settings.theme") }
    ) -> URL? {
        guard themes.setActiveTheme(name: name),
              let pair = themes.theme(named: name)?.pairedTerminalTheme else { return nil }
        // No bundle id, no write: never fall back to the installed app's file.
        guard let bundleIdentifier,
              let url = TerminalThemeOverride.appConfigURL(bundleIdentifier: bundleIdentifier, applicationSupport: applicationSupport)
        else {
            ThemeDiagnostics.loader("settings pick theme=\(name) terminal unchanged: no bundle identifier")
            return nil
        }
        do {
            try TerminalThemeOverride.write(settingTheme: TerminalThemeOverride.value(pairing: pair), to: url)
            reload()
            ThemeDiagnostics.loader("settings pick theme=\(name) terminal=\(pair) config=\(url.path)")
            return url
        } catch {
            ThemeDiagnostics.loader("settings pick theme=\(name) terminal unchanged: \(error)")
            return nil
        }
    }
}

/// The colours one theme paints a preview with, resolved through the same code the real
/// chrome uses: `ChromeThemeTokens` for the title bar, `SidebarThemeStyle` for the cards,
/// the sidebar backdrop resolver, and the paired Ghostty theme's own background.
@MainActor
struct ThemePreviewPaint {
    let titleBar: Color
    let titleText: Color
    let sidebar: Color
    let backdrop: SidebarBackdropStyle?
    let cardFill: Color
    let cardFillActive: Color
    let cardBorder: Color
    let cardBorderActive: Color
    let cardText: Color
    let cardTextSecondary: Color
    let separator: Color
    /// The paired Ghostty theme's colours; nil for a theme that leaves the terminal alone,
    /// whose preview shows the terminal's live default background.
    let pairedTerminal: GhosttyThemeColors.Colors?

    private struct CacheEntry {
        let theme: C11Theme
        let sidebarBackground: String
        let paint: ThemePreviewPaint
    }

    private static var cache: [String: CacheEntry] = [:]

    /// The paint for `theme`, resolved once per theme content and sidebar setting, so a
    /// gallery re-render (a Ghostty background tick, a workspace change) resolves nothing.
    static func cached(theme: C11Theme, sidebarBackground: String) -> ThemePreviewPaint {
        let name = theme.identity.name
        if let hit = cache[name], hit.sidebarBackground == sidebarBackground, hit.theme == theme {
            return hit.paint
        }
        let paint = ThemePreviewPaint(theme: theme, sidebarBackground: sidebarBackground)
        cache[name] = CacheEntry(theme: theme, sidebarBackground: sidebarBackground, paint: paint)
        return paint
    }

    init(theme: C11Theme, sidebarBackground: String) {
        let tokens = ChromeThemeTokens.resolve(for: theme, scheme: .dark)
        let context = ThemeContext(workspaceColor: nil, colorScheme: .dark, ghosttyBackgroundGeneration: 0)
        let snapshot = ResolvedThemeSnapshot(theme: theme)
        let themed = theme.identity.schema >= 2
        let style = themed ? SidebarThemeStyle(snapshot: snapshot, context: context) : .unset
        let themeBackdrop: SidebarBackdropStyle? = themed ? SidebarBackdropStyle.fromTheme(
            kind: snapshot.resolveStyleString(.backdropKind),
            color: snapshot.resolveStyleColor(.backdropColor, context: context),
            gradient: snapshot.resolveStyleGradient(.backdropGradient, context: context),
            grid: snapshot.resolveStyleString(.backdropGrid),
            gridColor: snapshot.resolveStyleColor(.backdropGridColor, context: context),
            gridTop: snapshot.resolveStyleNumber(.backdropGridTop)
        ) : nil

        titleBar = Color(nsColor: tokens.surface)
        titleText = Color(nsColor: tokens.foreground)
        sidebar = Color(nsColor: tokens.background)
        backdrop = C11SidebarBackground.backdrop(raw: sidebarBackground, colorScheme: .dark, theme: themeBackdrop)
        cardFill = style.cardFill ?? Color(nsColor: .controlBackgroundColor)
        cardFillActive = style.cardFillActive ?? style.cardFill ?? Color(nsColor: .controlBackgroundColor)
        cardBorder = style.cardBorder ?? Color.white.opacity(0.08)
        cardBorderActive = style.cardBorderActive ?? Color(nsColor: tokens.accent)
        cardText = style.cardText ?? .primary
        cardTextSecondary = style.cardTextSecondary ?? .secondary
        separator = Color(nsColor: tokens.separator)

        pairedTerminal = theme.pairedTerminalTheme.flatMap(GhosttyThemeColors.bundled(named:))
    }
}

/// Background and foreground of a Ghostty theme bundled with c11 (`ghostty/themes/<name>`).
@MainActor
enum GhosttyThemeColors {
    struct Colors: Equatable {
        let background: NSColor
        let foreground: NSColor
    }

    private static var cache: [String: Colors?] = [:]

    static func bundled(named name: String) -> Colors? {
        if let hit = cache[name] { return hit }
        let url = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty/themes", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        let parsed = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(parse)
        cache[name] = parsed
        return parsed
    }

    /// The `background` and `foreground` lines of a Ghostty theme file.
    nonisolated static func parse(_ text: String) -> Colors? {
        var values: [String: NSColor] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "background" || parts[0] == "foreground",
                  let color = hexColor(parts[1]) else { continue }
            values[parts[0]] = color
        }
        guard let bg = values["background"], let fg = values["foreground"] else { return nil }
        return Colors(background: bg, foreground: fg)
    }

    nonisolated static func hexColor(_ raw: String) -> NSColor? {
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The top-left corner of a c11 window, drawn at a fixed design size and scaled to fit.
private struct ThemeWindowPreview: View {
    let paint: ThemePreviewPaint
    let workspaces: [Workspace]
    let selectedWorkspaceId: UUID?
    let scale: CGFloat

    /// The crop, in points of a real window: the title bar, most of the sidebar, a sliver of terminal.
    private static let design = CGSize(width: 250, height: 156)
    private static let sidebarWidth: CGFloat = 177
    private static let lights = [
        Color(red: 1, green: 0.37, blue: 0.34),
        Color(red: 1, green: 0.74, blue: 0.18),
        Color(red: 0.16, green: 0.78, blue: 0.25)
    ]

    var body: some View {
        GeometryReader { geo in
            canvas
                .frame(width: Self.design.width, height: Self.design.height, alignment: .topLeading)
                .scaleEffect(geo.size.width / Self.design.width, anchor: .topLeading)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var selected: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceId } ?? workspaces.first
    }

    private var canvas: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Self.lights[i]).frame(width: 9, height: 9)
                }
                Group {
                    if let selected {
                        PreviewWorkspaceTitle(workspace: selected)
                    } else {
                        Text(Self.placeholderTitle(1))
                    }
                }
                .textCase(.uppercase)
                .font(.system(size: 9 * scale, weight: .medium, design: .monospaced))
                .kerning(0.6)
                .foregroundColor(paint.titleText)
                .lineLimit(1)
                .padding(.leading, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 28 * scale)
            .background(paint.titleBar)
            .overlay(alignment: .bottom) { paint.separator.frame(height: 1) }

            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    paint.sidebar
                    if let backdrop = paint.backdrop {
                        SidebarBackdropView(style: backdrop)
                    }
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        if workspaces.isEmpty {
                            PreviewCard(title: Self.placeholderTitle(1), detail: "~", active: true, paint: paint, scale: scale)
                            PreviewCard(title: Self.placeholderTitle(2), detail: "~", active: false, paint: paint, scale: scale)
                        } else {
                            ForEach(workspaces) { ws in
                                ObservedPreviewCard(workspace: ws, active: ws.id == selected?.id, paint: paint, scale: scale)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(width: Self.sidebarWidth)
                .overlay(alignment: .trailing) { paint.separator.frame(width: 1) }

                ZStack(alignment: .topLeading) {
                    terminalBackground
                    (Text("$ ").foregroundColor(terminalForeground) + Text("▍").foregroundColor(terminalForeground.opacity(0.6)))
                        .font(.system(size: 9, design: .monospaced))
                        .padding(8)
                }
            }
        }
        .background(paint.titleBar)
    }

    /// A theme with no paired terminal theme leaves the terminal as it is, so its preview
    /// shows the terminal's live default background.
    private var terminalBackground: Color {
        Color(nsColor: paint.pairedTerminal?.background ?? GhosttyApp.shared.defaultBackgroundColor)
    }

    private var terminalForeground: Color {
        Color(nsColor: paint.pairedTerminal?.foreground ?? NSColor(white: 0.8, alpha: 1))
    }

    private static func placeholderTitle(_ n: Int) -> String {
        String(localized: "settings.theme.preview.workspace", defaultValue: "Workspace \(n)")
    }
}

/// The workspace's live name, for the preview's title bar.
private struct PreviewWorkspaceTitle: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Text(workspace.customTitle ?? workspace.title)
    }
}

/// A workspace card that follows the workspace's live name and folder.
private struct ObservedPreviewCard: View {
    @ObservedObject var workspace: Workspace
    let active: Bool
    let paint: ThemePreviewPaint
    let scale: CGFloat

    var body: some View {
        PreviewCard(
            title: workspace.customTitle ?? workspace.title,
            detail: (workspace.currentDirectory as NSString).abbreviatingWithTildeInPath,
            active: active,
            paint: paint,
            scale: scale
        )
    }
}

private struct PreviewCard: View {
    let title: String
    let detail: String
    let active: Bool
    let paint: ThemePreviewPaint
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundColor(paint.cardText)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 8.5 * scale))
                .foregroundColor(paint.cardTextSecondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(active ? paint.cardFillActive : paint.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(active ? paint.cardBorderActive : paint.cardBorder, lineWidth: 1)
        )
    }
}
