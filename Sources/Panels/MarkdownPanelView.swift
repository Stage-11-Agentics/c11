import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// SwiftUI shell with a lazy, retained WKWebView reading surface.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    @ObservedObject private var themeManager = ThemeManager.shared
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void
    @ObservedObject var paneInteractionRuntime: AreaInteractionRuntime

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var isDropTargeted: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ThemeAppStorage.Keys.m1bMarkdownChromeMigrated, store: ThemeAppStorage.defaults)
    private var m1bMarkdownChromeMigrated = false

    var body: some View {
        Group {
            if panel.filePath == nil {
                emptyStateView
            } else if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownContentView
            }
        }
        .contextMenu {
            Button(String(
                localized: "surfaceManifest.menuItem",
                defaultValue: "Panel Details"
            )) {
                PanelManifestViewerWindowController.show(
                    workspaceId: panel.workspaceId,
                    surfaceId: panel.id,
                    kind: .markdown
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            if isVisibleInUI {
                // Observe left-clicks without intercepting them so markdown text
                // selection and link activation continue to use the native path.
                MarkdownPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .overlay {
            if let interaction = paneInteractionRuntime.active[panel.id] {
                AreaInteractionCardView(
                    panelId: panel.id,
                    interaction: interaction,
                    runtime: paneInteractionRuntime
                )
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Content

    private var markdownContentView: some View {
        Group {
            if isVisibleInUI {
                MarkdownWebContent(panel: panel, isFocused: isFocused)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state (unbound panel)

    private var emptyStateView: some View {
        let borderColor = isDropTargeted
            ? cmuxAccentColor().opacity(0.9)
            : (colorScheme == .dark
                ? Color.white.opacity(0.16)
                : Color.black.opacity(0.14))
        let fillColor = isDropTargeted
            ? cmuxAccentColor().opacity(0.08)
            : Color.clear

        return VStack(spacing: 20) {
            Spacer(minLength: 0)

            Image(systemName: "doc.richtext")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text(String(localized: "markdown.empty.title", defaultValue: "Open a markdown file"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Text(String(localized: "markdown.empty.subtitle", defaultValue: "Drop a .md file here, or click Open."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                presentOpenMarkdownPanel()
            } label: {
                Text(String(localized: "markdown.empty.openButton", defaultValue: "Open Markdown File…"))
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(cmuxAccentColor())

            Text(String(localized: "markdown.empty.spikePropaganda", defaultValue: "Plans, docs, receipts — the Spike runs on markdown. Drop in, one workspace."))
                .font(.system(size: 11))
                .italic()
                .foregroundColor(.secondary.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(fillColor)
                )
                .padding(24)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func presentOpenMarkdownPanel() {
        let panelOpen = NSOpenPanel()
        panelOpen.canChooseFiles = true
        panelOpen.canChooseDirectories = false
        panelOpen.allowsMultipleSelection = false
        panelOpen.allowedContentTypes = Self.markdownContentTypes
        panelOpen.prompt = String(localized: "markdown.empty.openPrompt", defaultValue: "Open")
        panelOpen.message = String(localized: "markdown.empty.openMessage", defaultValue: "Choose a markdown file to open.")
        if panelOpen.runModal() == .OK, let url = panelOpen.url {
            panel.bindFilePath(url.path)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let identifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return false }
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                panel.bindFilePath(url.path)
            }
        }
        return true
    }

    private static let markdownContentTypes: [UTType] = {
        var types: [UTType] = []
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        if let mdown = UTType(filenameExtension: "mdown") { types.append(mdown) }
        types.append(.plainText)
        types.append(.text)
        return types
    }()

    // MARK: - Theme

    private var backgroundColor: Color {
        if m1bMarkdownChromeMigrated, themeManager.isEnabled {
            let context = themeManager.makeContext(colorScheme: colorScheme)
            if let themed: NSColor = themeManager.resolve(.markdownChrome_background, context: context) {
                return Color(nsColor: themed)
            }
        }

        return colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

struct MarkdownWebContent: NSViewRepresentable {
    let panel: MarkdownPanel
    let isFocused: Bool

    final class Coordinator {
        let id = UUID()
        weak var panel: MarkdownPanel?
        init(_ panel: MarkdownPanel) { self.panel = panel }
    }
    func makeCoordinator() -> Coordinator { Coordinator(panel) }

    func makeNSView(context: Context) -> NSView {
        panel.setRendererVisible(true, hostID: context.coordinator.id)
        let renderer = panel.ensureRenderer()
        renderer.webView.allowsPanelFocus = isFocused
        let host = NSHostingView(rootView: MarkdownRendererContent(
            panel: panel,
            renderer: renderer,
            readerOutline: renderer.readerOutline
        ))
        return host
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.panel?.setRendererVisible(false, hostID: coordinator.id)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        panel.setRendererVisible(true, hostID: context.coordinator.id)
        if let view = panel.renderer?.webView {
            let changed = view.allowsPanelFocus != isFocused
            view.allowsPanelFocus = isFocused
            if changed && isFocused { view.requestPanelFocusIfAllowed() }
        }
        panel.renderer?.synchronize()
    }
}

private struct MarkdownRendererContent: View {
    @ObservedObject var panel: MarkdownPanel
    @ObservedObject var renderer: MarkdownWebRenderer
    @ObservedObject var readerOutline: MarkdownReaderOutlineState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: MarkdownReaderPalette { MarkdownReaderPalette(theme: panel.theme, colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownReaderToolbar(
                panel: panel,
                renderer: renderer,
                readout: renderer.readerReadout,
                readerOutline: readerOutline
            )
            Group {
                if renderer.failure {
                    VStack(spacing: 12) {
                        Text(String(localized: "markdown.rendererUnavailable.title", defaultValue: "Renderer unavailable"))
                            .font(.headline)
                        Text(String(localized: "markdown.rendererUnavailable.message", defaultValue: "The bundled markdown renderer could not be loaded."))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MarkdownWebViewHost(webView: renderer.webView)
                        .opacity(renderer.renderedRevision == nil ? 0 : 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MarkdownReaderToolbar: View {
    @ObservedObject var panel: MarkdownPanel
    @ObservedObject var renderer: MarkdownWebRenderer
    @ObservedObject var readout: MarkdownReaderReadoutState
    @ObservedObject var readerOutline: MarkdownReaderOutlineState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: MarkdownReaderPalette { MarkdownReaderPalette(theme: panel.theme, colorScheme: colorScheme) }
    private var outlineOpen: Bool {
        readerOutline.value.revision.isEmpty ? (panel.outlineOpen ?? false) : readerOutline.value.isOpen
    }
    private var sourceMode: Bool { readout.value.mode == "source" }
    private var scale: Double { panel.fontScale }
    private var progress: Double { min(max(readout.value.progress, 0), 1) }
    private var progressLabel: String {
        let percent = Int((progress * 100).rounded())
        let minutes = max(0, readout.value.minutesLeft)
        return String(format: String(localized: "markdown.reader.progress.format", defaultValue: "%d%% · %d min left"), percent, minutes)
    }
    private var breadcrumb: String {
        let path = readout.value.headingPath.filter { !$0.isEmpty }
        return ([panel.displayTitle] + path).filter { !$0.isEmpty }.joined(separator: "  ›  ")
    }

    private func breadcrumb(for width: CGFloat) -> String {
        guard width < 600 else { return breadcrumb }
        return readout.value.headingPath.last ?? panel.displayTitle
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    outlineButton(showLabel: geometry.size.width >= 700)
                    Text(breadcrumb(for: geometry.size.width))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .truncationMode(geometry.size.width < 600 ? .tail : .middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(breadcrumb)
                        .accessibilityIdentifier("MarkdownBreadcrumb")

                    if geometry.size.width >= 430 {
                        Text(progressLabel)
                            .font(.system(size: 10, design: .monospaced).monospacedDigit())
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 128, alignment: .trailing)
                            .accessibilityIdentifier("MarkdownProgressLabel")
                    }

                    controls
                }
                .padding(.horizontal, geometry.size.width < 360 ? 4 : 8)
                .frame(height: 35)

                GeometryReader { line in
                    ZStack(alignment: .leading) {
                        palette.rule.opacity(0.34)
                        palette.gold.frame(width: line.size.width * progress)
                    }
                }
                .frame(height: 1)
                .accessibilityHidden(true)
            }
            .background(palette.chrome)
        }
        .frame(height: 36)
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }

    private func outlineButton(showLabel: Bool) -> some View {
        Button { panel.toggleOutline() } label: {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                if showLabel {
                    Text(String(localized: "markdown.reader.outline.title", defaultValue: "Outline"))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .frame(width: showLabel ? 92 : 30, height: 26)
        }
        .foregroundStyle(palette.ink)
        .buttonStyle(MarkdownChromeButtonStyle(palette: palette, active: outlineOpen))
        .safeHelp(String(localized: "markdown.reader.outline.toggle", defaultValue: "Toggle outline (⇧⌘O)"))
        .accessibilityLabel(String(localized: "markdown.reader.outline.title", defaultValue: "Outline"))
        .accessibilityAddTraits(outlineOpen ? .isSelected : [])
        .accessibilityValue(outlineOpen
            ? String(localized: "markdown.reader.outline.state.shown", defaultValue: "Shown")
            : String(localized: "markdown.reader.outline.state.hidden", defaultValue: "Hidden")
        )
        .accessibilityIdentifier("MarkdownOutlineToggle")
    }

    private var controls: some View {
        HStack(spacing: 3) {
            Button { panel.requestFind() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(MarkdownOmnibarButtonStyle(palette: palette))
            .safeHelp(String(localized: "markdown.reader.find.open", defaultValue: "Find (⌘F)"))
            .accessibilityLabel(String(localized: "markdown.reader.find.open", defaultValue: "Find (⌘F)"))
            .accessibilityIdentifier("MarkdownFindButton")

            Button {
                renderer.call("setSourceMode", arguments: [!sourceMode])
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(MarkdownOmnibarButtonStyle(palette: palette, active: sourceMode))
            .safeHelp(String(localized: "markdown.reader.source.toggle", defaultValue: "Toggle source view"))
            .accessibilityLabel(String(localized: "markdown.reader.source.toggle", defaultValue: "Toggle source view"))
            .accessibilityAddTraits(sourceMode ? .isSelected : [])
            .accessibilityIdentifier("MarkdownSourceToggle")

            HStack(spacing: 2) {
                Button { panel.zoomOut() } label: {
                    Text("−").font(.system(size: 14, weight: .regular)).frame(width: 26, height: 26)
                }
                .buttonStyle(MarkdownOmnibarButtonStyle(palette: palette))
                .disabled(scale <= MarkdownPanel.fontScaleRange.lowerBound)
                .safeHelp(String(localized: "markdown.reader.size.decrease", defaultValue: "Decrease text size"))
                .accessibilityLabel(String(localized: "markdown.reader.size.decrease", defaultValue: "Decrease text size"))

                Button { panel.resetZoom() } label: {
                    Text("\(Int((scale * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced).monospacedDigit())
                        .foregroundStyle(palette.ink)
                        .frame(width: 42, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "markdown.reader.size.reset", defaultValue: "Reset text size"))
                .accessibilityLabel(String(localized: "markdown.reader.size.reset", defaultValue: "Reset text size"))
                .accessibilityValue("\(Int((scale * 100).rounded()))%")
                .accessibilityIdentifier("MarkdownTextScale")

                Button { panel.zoomIn() } label: {
                    Text("+").font(.system(size: 14, weight: .regular)).frame(width: 26, height: 26)
                }
                .buttonStyle(MarkdownOmnibarButtonStyle(palette: palette))
                .disabled(scale >= MarkdownPanel.fontScaleRange.upperBound)
                .safeHelp(String(localized: "markdown.reader.size.increase", defaultValue: "Increase text size"))
                .accessibilityLabel(String(localized: "markdown.reader.size.increase", defaultValue: "Increase text size"))
            }
            .padding(.horizontal, 2)
            .fixedSize()
            .background(palette.control.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))

            themeMenu

            Button { panel.openExternally() } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(MarkdownOmnibarButtonStyle(palette: palette))
            .frame(width: 22, height: 22)
            .safeHelp(String(
                format: String(localized: "markdown.reader.openExternal.help", defaultValue: "Open in %@"),
                panel.defaultExternalAppName
            ))
            .accessibilityLabel(String(
                format: String(localized: "markdown.reader.openExternal.help", defaultValue: "Open in %@"),
                panel.defaultExternalAppName
            ))
            .accessibilityIdentifier("MarkdownOpenExternalButton")
        }
        .fixedSize()
    }

    private var themeMenu: some View {
        Menu {
            Section(String(localized: "markdown.reader.theme.section", defaultValue: "Theme")) {
                if renderer.themeChoices.isEmpty {
                    themeChoice("system", label: String(localized: "markdown.reader.theme.system", defaultValue: "System"))
                    themeChoice("light", label: String(localized: "markdown.reader.theme.light", defaultValue: "Light"))
                    themeChoice("dark", label: String(localized: "markdown.reader.theme.dark", defaultValue: "Dark"))
                } else {
                    ForEach(renderer.themeChoices) { choice in themeChoice(choice) }
                }
            }
            Section(String(localized: "markdown.reader.typeface.section", defaultValue: "Typeface")) {
                if renderer.typefaceChoices.isEmpty {
                    typefaceChoice("theme", label: String(localized: "markdown.reader.typeface.theme", defaultValue: "Theme default"))
                    typefaceChoice("serif", label: String(localized: "markdown.reader.typeface.serif", defaultValue: "Serif"))
                    typefaceChoice("sans", label: String(localized: "markdown.reader.typeface.sans", defaultValue: "Sans"))
                    typefaceChoice("mono", label: String(localized: "markdown.reader.typeface.mono", defaultValue: "Mono"))
                } else {
                    ForEach(renderer.typefaceChoices) { choice in typefaceChoice(choice) }
                }
            }
        } label: {
            Image(systemName: themeIcon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(MarkdownOmnibarButtonStyle(palette: palette))
        .foregroundStyle(palette.ink)
        .frame(width: 22, height: 22)
        .safeHelp(String(localized: "markdown.reader.theme.open", defaultValue: "Theme and typeface"))
        .accessibilityLabel(String(localized: "markdown.reader.theme.open", defaultValue: "Theme and typeface"))
        .accessibilityIdentifier("MarkdownThemeMenu")
    }

    private var themeIcon: String {
        switch panel.theme {
        case "light": "sun.max"
        case "dark": "moon"
        default: "circle.lefthalf.filled"
        }
    }

    private func themeChoice(_ value: String, label: String) -> some View {
        Button {
            panel.setTheme(value)
        } label: {
            if panel.theme == value { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
    }

    private func themeChoice(_ choice: MarkdownReaderThemeChoice) -> some View {
        themeChoice(choice.id, label: localizedThemeLabel(choice))
    }

    private func typefaceChoice(_ value: String, label: String) -> some View {
        Button {
            panel.setTypeface(value)
        } label: {
            if panel.typeface == value { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
    }

    private func typefaceChoice(_ choice: MarkdownReaderTypefaceChoice) -> some View {
        typefaceChoice(choice.id, label: localizedTypefaceLabel(choice))
    }

    private func localizedThemeLabel(_ choice: MarkdownReaderThemeChoice) -> String {
        switch choice.id {
        case "system": String(localized: "markdown.reader.theme.system", defaultValue: "System")
        case "light": String(localized: "markdown.reader.theme.light", defaultValue: "Light")
        case "dark": String(localized: "markdown.reader.theme.dark", defaultValue: "Dark")
        default: choice.label
        }
    }

    private func localizedTypefaceLabel(_ choice: MarkdownReaderTypefaceChoice) -> String {
        switch choice.id {
        case "theme": String(localized: "markdown.reader.typeface.theme", defaultValue: "Theme default")
        case "serif": String(localized: "markdown.reader.typeface.serif", defaultValue: "Serif")
        case "sans": String(localized: "markdown.reader.typeface.sans", defaultValue: "Sans")
        case "mono": String(localized: "markdown.reader.typeface.mono", defaultValue: "Mono")
        default: choice.label
        }
    }
}

private struct MarkdownReaderPalette {
    let isDark: Bool
    var paper: Color { Color(nsColor: NSColor(calibratedWhite: isDark ? 0.06 : 0.985, alpha: 1)) }
    var chrome: Color { Color(nsColor: NSColor(calibratedWhite: isDark ? 0.055 : 0.93, alpha: 1)) }
    var ink: Color { Color(nsColor: NSColor(calibratedWhite: isDark ? 0.94 : 0.08, alpha: 1)) }
    var secondary: Color { Color(nsColor: NSColor(calibratedWhite: isDark ? 0.64 : 0.38, alpha: 1)) }
    var rule: Color { Color(nsColor: NSColor(calibratedWhite: isDark ? 0.35 : 0.7, alpha: 1)) }
    var control: Color { Color(nsColor: NSColor(calibratedWhite: isDark ? 0.22 : 0.84, alpha: 1)) }
    var selected: Color { Color(nsColor: NSColor(calibratedWhite: isDark ? 0.22 : 0.89, alpha: 1)) }
    var gold: Color { Color(red: 0.79, green: 0.66, blue: 0.30) }

    init(theme: String, colorScheme: ColorScheme) {
        isDark = theme == "dark" || (theme == "system" && colorScheme == .dark)
    }

}

private struct MarkdownChromeButtonStyle: ButtonStyle {
    let palette: MarkdownReaderPalette
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(palette.ink)
            .background(
                configuration.isPressed ? palette.ink.opacity(0.16) : (active ? palette.ink.opacity(0.08) : Color.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct MarkdownOmnibarButtonStyle: ButtonStyle {
    let palette: MarkdownReaderPalette
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        MarkdownOmnibarButtonStyleBody(configuration: configuration, palette: palette, active: active)
    }
}

private struct MarkdownOmnibarButtonStyleBody: View {
    let configuration: MarkdownOmnibarButtonStyle.Configuration
    let palette: MarkdownReaderPalette
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.16 }
        return isHovered || active ? 0.08 : 0
    }

    var body: some View {
        configuration.label
            .foregroundStyle(palette.ink)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.ink.opacity(backgroundOpacity))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct MarkdownWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct MarkdownPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> MarkdownPanelPointerObserverView {
        let view = MarkdownPanelPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: MarkdownPanelPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class MarkdownPanelPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func shouldHandle(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              let window,
              event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func handleEventIfNeeded(_ event: NSEvent) -> NSEvent {
        guard shouldHandle(event) else { return event }
        DispatchQueue.main.async { [weak self] in
            self?.onPointerDown?()
        }
        return event
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleEventIfNeeded(event) ?? event
        }
    }
}
