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
        VStack(spacing: 0) {
            filePathHeader.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if isVisibleInUI {
                MarkdownWebContent(panel: panel, isFocused: isFocused)
            } else {
                Color.clear
            }
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text(panel.filePath ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
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

private struct MarkdownWebContent: NSViewRepresentable {
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
        let host = NSHostingView(rootView: MarkdownRendererContent(renderer: renderer))
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
    @ObservedObject var renderer: MarkdownWebRenderer

    var body: some View {
        if renderer.failure {
            VStack(spacing: 12) {
                Text(String(localized: "markdown.rendererUnavailable.title", defaultValue: "Renderer unavailable"))
                    .font(.headline)
                Text(String(localized: "markdown.rendererUnavailable.message", defaultValue: "The bundled markdown renderer could not be loaded."))
                    .foregroundColor(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MarkdownWebViewHost(webView: renderer.webView)
                .opacity(renderer.renderedRevision == nil ? 0 : 1)
        }
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
