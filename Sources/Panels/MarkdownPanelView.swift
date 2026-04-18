import AppKit
import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

/// SwiftUI view that renders a MarkdownPanel's content using MarkdownUI.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var isDropTargeted: Bool = false
    @Environment(\.colorScheme) private var colorScheme

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
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Content

    private var markdownContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // File path breadcrumb
                filePathHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 16)

                // Rendered content segments
                if panel.segments.isEmpty {
                    Markdown(panel.content)
                        .markdownTheme(cmuxMarkdownTheme)
                        .textSelection(.enabled)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                } else {
                    ForEach(panel.segments) { segment in
                        segmentView(segment)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MarkdownSegment) -> some View {
        switch segment {
        case .markdown(_, let content):
            Markdown(content)
                .markdownTheme(cmuxMarkdownTheme)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        case .fencedCode(_, let language, let code, let image):
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            } else {
                fencedCodeFallbackView(language: language, code: code)
            }
        }
    }

    private func fencedCodeFallbackView(language: String, code: String) -> some View {
        let renderer = FencedCodeRendererRegistry.shared.renderer(for: language)
        return VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(colorScheme == .dark
                        ? Color(red: 0.9, green: 0.9, blue: 0.9)
                        : Color(red: 0.2, green: 0.2, blue: 0.2))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(colorScheme == .dark
                ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
                : Color(nsColor: NSColor(white: 0.93, alpha: 1.0)))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let renderer, !renderer.isAvailable, let hint = renderer.installHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
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
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    private var cmuxMarkdownTheme: Theme {
        let isDark = colorScheme == .dark

        return Theme()
            // Text
            .text {
                ForegroundColor(isDark ? .white.opacity(0.9) : .primary)
                FontSize(14)
            }
            // Headings
            .heading1 { configuration in
                VStack(alignment: .leading, spacing: 8) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(28)
                            ForegroundColor(isDark ? .white : .primary)
                        }
                    Divider()
                }
                .markdownMargin(top: 24, bottom: 16)
            }
            .heading2 { configuration in
                VStack(alignment: .leading, spacing: 6) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(22)
                            ForegroundColor(isDark ? .white : .primary)
                        }
                    Divider()
                }
                .markdownMargin(top: 20, bottom: 12)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(18)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(16)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(14)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(13)
                        ForegroundColor(isDark ? .white.opacity(0.7) : .secondary)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            // Code blocks
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(13)
                            ForegroundColor(isDark ? Color(red: 0.9, green: 0.9, blue: 0.9) : Color(red: 0.2, green: 0.2, blue: 0.2))
                        }
                        .padding(12)
                }
                .background(isDark
                    ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
                    : Color(nsColor: NSColor(white: 0.93, alpha: 1.0)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 8, bottom: 8)
            }
            // Inline code
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                ForegroundColor(isDark ? Color(red: 0.85, green: 0.6, blue: 0.95) : Color(red: 0.6, green: 0.2, blue: 0.7))
                BackgroundColor(isDark
                    ? Color(nsColor: NSColor(white: 0.18, alpha: 1.0))
                    : Color(nsColor: NSColor(white: 0.92, alpha: 1.0)))
            }
            // Block quotes
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isDark ? Color.white.opacity(0.2) : Color.gray.opacity(0.4))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(isDark ? .white.opacity(0.6) : .secondary)
                            FontSize(14)
                        }
                        .padding(.leading, 12)
                }
                .markdownMargin(top: 8, bottom: 8)
            }
            // Links
            .link {
                ForegroundColor(Color.accentColor)
            }
            // Strong
            .strong {
                FontWeight(.semibold)
            }
            // Tables
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(.init(color: isDark ? .white.opacity(0.15) : .gray.opacity(0.3)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            isDark
                                ? Color(nsColor: NSColor(white: 0.14, alpha: 1.0))
                                : Color(nsColor: NSColor(white: 0.96, alpha: 1.0)),
                            isDark
                                ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
                                : Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
                        )
                    )
                    .markdownMargin(top: 8, bottom: 8)
            }
            // Thematic break (horizontal rule)
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 16, bottom: 16)
            }
            // List items
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            // Paragraphs
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 8)
            }
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
