import AppKit
import Foundation
import Combine

/// A segment of markdown content — either regular markdown or a rendered fenced code block.
enum MarkdownSegment: Identifiable {
    case markdown(id: String, content: String)
    /// `errorHint` is set when the most recent render attempt failed and the
    /// renderer surfaced operator-actionable diagnostic text (e.g. missing
    /// runtime dependency with a copy-pasteable install command). nil when the
    /// segment has not yet been rendered, is rendering, or rendered cleanly.
    case fencedCode(id: String, language: String, code: String, renderedImage: NSImage?, errorHint: String?)

    var id: String {
        switch self {
        case .markdown(let id, _): return id
        case .fencedCode(let id, _, _, _, _): return id
        }
    }
}

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .markdown

    /// Absolute path to the markdown file being displayed, or nil when the
    /// panel is unbound (empty state — user hasn't picked a file yet).
    @Published private(set) var filePath: String?

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published private(set) var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.richtext" }

    /// Whether the file has been deleted or is unreadable. Always false for
    /// an unbound panel (nil filePath) — the empty state is a distinct mode.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Parsed segments of the content (markdown + mermaid blocks).
    @Published private(set) var segments: [MarkdownSegment] = []

    /// Tracks the appearance used for the last mermaid render pass.
    private var lastRenderedDark: Bool?

    // MARK: - Font scale (zoom)

    /// Multiplier applied to all theme font sizes. 1.0 = default.
    @Published private(set) var fontScale: Double

    static let fontScaleRange: ClosedRange<Double> = 0.5...3.0
    static let fontScaleStep: Double = 0.1
    private static let fontScaleDefaultsKey = "markdown.fontScale.lastUsed"

    /// Clamp to the supported range and round to one step's precision so
    /// repeated +/- cycles don't accumulate floating-point drift.
    static func normalizedFontScale(_ value: Double) -> Double {
        let clamped = min(max(value, fontScaleRange.lowerBound), fontScaleRange.upperBound)
        return (clamped * 10).rounded() / 10
    }

    private static func lastUsedFontScale() -> Double {
        let stored = UserDefaults.standard.double(forKey: fontScaleDefaultsKey)
        guard stored > 0 else { return 1.0 }
        return normalizedFontScale(stored)
    }

    @discardableResult
    func zoomIn() -> Bool {
        setFontScale(fontScale + Self.fontScaleStep)
    }

    @discardableResult
    func zoomOut() -> Bool {
        setFontScale(fontScale - Self.fontScaleStep)
    }

    @discardableResult
    func resetZoom() -> Bool {
        setFontScale(1.0)
    }

    /// Restore a persisted scale without updating the last-used default.
    func applyRestoredFontScale(_ value: Double) {
        fontScale = Self.normalizedFontScale(value)
    }

    private func setFontScale(_ value: Double) -> Bool {
        let normalized = Self.normalizedFontScale(value)
        guard normalized != fontScale else { return true }
        fontScale = normalized
        UserDefaults.standard.set(normalized, forKey: Self.fontScaleDefaultsKey)
        return true
    }

    /// Observer for system appearance changes.
    private var appearanceObserver: NSObjectProtocol?

    // MARK: - File watching

    // nonisolated(unsafe) because deinit is not guaranteed to run on the
    // main actor, but DispatchSource.cancel() is thread-safe.
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private nonisolated let watchQueue = DispatchQueue(label: "com.stage11.c11.markdown-file-watch", qos: .utility)

    /// Pending debounced reload. Accessed only on `watchQueue`.
    private nonisolated(unsafe) var pendingReload: DispatchWorkItem?
    /// Trailing debounce applied to watcher-driven reloads so agents
    /// stream-appending to a watched file coalesce into one reparse per
    /// burst instead of one per write event.
    private static let reloadDebounce: TimeInterval = 0.15

    /// Maximum number of reattach attempts after a file delete/rename event.
    private static let maxReattachAttempts = 6
    /// Delay between reattach attempts (total window: attempts * delay = 3s).
    private static let reattachDelay: TimeInterval = 0.5

    // MARK: - Init

    /// - Parameter id: Stable panel UUID. Pass `nil` for fresh creation; pass a
    ///   snapshot's panel id during session restore to keep IDs stable across
    ///   app restarts (Tier 1 persistence, Phase 1).
    /// - Parameter filePath: Absolute path to a markdown file, or `nil` to
    ///   create an unbound panel (empty state — user binds via drag-drop or
    ///   the in-panel "Open Markdown File" button).
    init(id: UUID? = nil, workspaceId: UUID, filePath: String? = nil) {
        self.id = id ?? UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = Self.titleForFilePath(filePath)
        self.fontScale = Self.lastUsedFontScale()

        if filePath != nil {
            loadFileContent()
            startFileWatcher()
            if isFileUnavailable && fileWatchSource == nil {
                // Session restore can create a panel before the file is recreated.
                // Retry briefly so atomic-rename recreations can reconnect.
                scheduleReattach(attempt: 1)
            }
        }
        startAppearanceObserver()
    }

    private static func titleForFilePath(_ filePath: String?) -> String {
        guard let filePath else {
            return String(localized: "markdown.untitled", defaultValue: "Untitled")
        }
        return (filePath as NSString).lastPathComponent
    }

    /// Bind this panel to a markdown file post-construction. Called from the
    /// empty-state UI after the user drops a file or picks one via NSOpenPanel.
    /// No-op if the panel is already bound — rebinding requires a fresh panel.
    func bindFilePath(_ path: String) {
        guard filePath == nil, !isClosed else { return }
        filePath = path
        displayTitle = Self.titleForFilePath(path)
        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            scheduleReattach(attempt: 1)
        }
    }

    // MARK: - Panel protocol

    func focus() {
        // Markdown panel is read-only; no first responder to manage.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        isClosed = true
        stopFileWatcher()
        stopAppearanceObserver()
        watchQueue.async { [weak self] in
            self?.pendingReload?.cancel()
            self?.pendingReload = nil
        }
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
        guard let filePath else {
            content = ""
            isFileUnavailable = false
            parseSegments()
            return
        }
        applyExternalContent(Self.readContent(path: filePath))
    }

    /// Read file content with the UTF-8 → ISO Latin-1 fallback chain.
    /// Safe to call from any queue.
    private nonisolated static func readContent(path: String) -> String? {
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return content
        }
        // Fallback: try ISO Latin-1, which accepts all 256 byte values,
        // covering legacy encodings like Windows-1252.
        if let data = FileManager.default.contents(atPath: path),
           let decoded = String(data: data, encoding: .isoLatin1) {
            return decoded
        }
        return nil
    }

    /// Apply content produced by a read (sync or debounced). Skips the
    /// reparse + republish entirely when the content is unchanged, which is
    /// the common case for spurious watcher events.
    private func applyExternalContent(_ newContent: String?) {
        guard !isClosed else { return }
        guard let newContent else {
            isFileUnavailable = true
            return
        }
        let wasUnavailable = isFileUnavailable
        isFileUnavailable = false
        guard newContent != content || wasUnavailable else { return }
        content = newContent
        parseSegments()
    }

    /// Schedule a debounced reload on the watch queue. Coalesces bursts of
    /// file events; the file read happens off the main thread.
    private nonisolated func scheduleDebouncedReload(path: String) {
        watchQueue.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let result = Self.readContent(path: path)
                DispatchQueue.main.async {
                    self.applyExternalContent(result)
                }
            }
            self.pendingReload = item
            self.watchQueue.asyncAfter(deadline: .now() + Self.reloadDebounce, execute: item)
        }
    }

    // MARK: - Fenced code segment parsing

    /// Stable ID from segment index and full content. Hashing the whole
    /// content (not a prefix) guarantees the ID changes whenever the segment
    /// changes — a prefix hash let edits past the prefix keep a stale ID,
    /// which preserved outdated rendered diagrams indefinitely.
    static func segmentId(index: Int, content: String) -> String {
        "\(index):\(content.count):\(content.hashValue)"
    }

    /// Compiled fenced-code pattern cached per tag set. Renderers register at
    /// app startup, so in practice this compiles once.
    private static var cachedFencedCodePattern: (tags: Set<String>, regex: NSRegularExpression?)?

    /// Build a regex that matches fenced code blocks for all registered renderer tags.
    /// Pattern captures: group 1 = language tag, group 2 = code content.
    private static func buildFencedCodePattern() -> NSRegularExpression? {
        let tags = FencedCodeRendererRegistry.shared.supportedTags
        guard !tags.isEmpty else { return nil }
        if let cached = cachedFencedCodePattern, cached.tags == tags {
            return cached.regex
        }
        let escaped = tags.map { NSRegularExpression.escapedPattern(for: $0) }
        let alternation = escaped.joined(separator: "|")
        let pattern = "```(\(alternation))\\s*\\n([\\s\\S]*?)```"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        cachedFencedCodePattern = (tags, regex)
        return regex
    }

    /// Parse content into segments, splitting on fenced code blocks with registered renderers.
    private func parseSegments() {
        let text = content
        guard !text.isEmpty else {
            segments = []
            return
        }

        guard let pattern = Self.buildFencedCodePattern() else {
            // No renderers registered — plain markdown
            segments = [.markdown(id: Self.segmentId(index: 0, content: text), content: text)]
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = pattern.matches(in: text, range: fullRange)

        guard !matches.isEmpty else {
            segments = [.markdown(id: Self.segmentId(index: 0, content: text), content: text)]
            return
        }

        var result: [MarkdownSegment] = []
        var lastEnd = 0
        var segIndex = 0

        for match in matches {
            let matchRange = match.range
            // Add preceding markdown text
            if matchRange.location > lastEnd {
                let mdRange = NSRange(location: lastEnd, length: matchRange.location - lastEnd)
                let mdText = nsText.substring(with: mdRange)
                if !mdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(id: Self.segmentId(index: segIndex, content: mdText), content: mdText))
                    segIndex += 1
                }
            }
            // Extract language tag (capture group 1) and code (capture group 2)
            let langRange = match.range(at: 1)
            let language = nsText.substring(with: langRange).lowercased()
            let codeRange = match.range(at: 2)
            let code = nsText.substring(with: codeRange).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(.fencedCode(id: Self.segmentId(index: segIndex, content: code), language: language, code: code, renderedImage: nil, errorHint: nil))
            segIndex += 1
            lastEnd = matchRange.location + matchRange.length
        }

        // Add trailing markdown text
        if lastEnd < nsText.length {
            let mdText = nsText.substring(from: lastEnd)
            if !mdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(id: Self.segmentId(index: segIndex, content: mdText), content: mdText))
            }
        }

        // Preserve rendered images for segments whose content hasn't changed.
        // Drop any prior errorHint — a fresh parse should re-render and recompute.
        let oldSegments = segments
        for (i, seg) in result.enumerated() {
            if case .fencedCode(let id, let lang, let code, _, _) = seg,
               let old = oldSegments.first(where: { $0.id == id }),
               case .fencedCode(_, _, _, let oldImage, _) = old,
               oldImage != nil {
                result[i] = .fencedCode(id: id, language: lang, code: code, renderedImage: oldImage, errorHint: nil)
            }
        }

        segments = result
        renderFencedCodeSegments()
    }

    /// Render fenced code segments asynchronously via their registered renderers.
    private func renderFencedCodeSegments() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lastRenderedDark = isDark

        let registry = FencedCodeRendererRegistry.shared

        // Build active keys per renderer for cancellation
        var activeKeysByRenderer: [String: Set<String>] = [:]
        for segment in segments {
            guard case .fencedCode(_, let language, let code, let existingImage, _) = segment else { continue }
            if existingImage != nil { continue }
            guard let renderer = registry.renderer(for: language) else { continue }
            let key = renderer.renderCacheKey(code: code, isDark: isDark)
            activeKeysByRenderer[language, default: []].insert(key)
        }
        for (language, keys) in activeKeysByRenderer {
            registry.renderer(for: language)?.cancelRendersExcept(activeKeys: keys)
        }

        for (index, segment) in segments.enumerated() {
            guard case .fencedCode(let id, let language, let code, let existingImage, _) = segment else { continue }
            if existingImage != nil { continue }
            guard let renderer = registry.renderer(for: language) else { continue }
            renderer.render(code: code, isDark: isDark) { [weak self] image, hint in
                guard let self else { return }
                guard index < self.segments.count,
                      case .fencedCode(let currentId, _, _, _, _) = self.segments[index],
                      currentId == id else { return }
                self.segments[index] = .fencedCode(id: id, language: language, code: code, renderedImage: image, errorHint: hint)
            }
        }
    }

    // MARK: - Appearance change observation

    private func startAppearanceObserver() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppearanceChangeIfNeeded()
        }
        // Also observe the effective appearance key path
        // NSApp posts this when system appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    private func stopAppearanceObserver() {
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
            appearanceObserver = nil
        }
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private nonisolated func systemAppearanceDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppearanceChangeIfNeeded()
        }
    }

    private func handleAppearanceChangeIfNeeded() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard isDark != lastRenderedDark else { return }
        // Clear rendered images so they re-render with the new theme
        for (i, segment) in segments.enumerated() {
            if case .fencedCode(let id, let lang, let code, let image, _) = segment, image != nil {
                segments[i] = .fencedCode(id: id, language: lang, code: code, renderedImage: nil, errorHint: nil)
            }
        }
        renderFencedCodeSegments()
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        guard let filePath else { return }
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was deleted or renamed. The old file descriptor points to
                // a stale inode, so we must always stop and reattach the watcher
                // even if the new file is already readable (atomic save case).
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    guard let path = self.filePath else { return }
                    if FileManager.default.fileExists(atPath: path) {
                        // File already replaced — reattach to the new inode
                        // immediately; content loads via the debounced path.
                        self.startFileWatcher()
                        self.scheduleDebouncedReload(path: path)
                    } else {
                        // File not yet replaced — retry until it reappears.
                        self.isFileUnavailable = true
                        self.scheduleReattach(attempt: 1)
                    }
                }
            } else {
                // Content changed — reload (debounced, read off-main).
                self.scheduleDebouncedReload(path: filePath)
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    /// Retry reattaching the file watcher up to `maxReattachAttempts` times.
    /// Each attempt checks if the file has reappeared. Bails out early if
    /// the panel has been closed.
    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed, let filePath = self.filePath else { return }
                if FileManager.default.fileExists(atPath: filePath) {
                    self.isFileUnavailable = false
                    self.loadFileContent()
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        // File descriptor is closed by the cancel handler.
        fileDescriptor = -1
    }

    deinit {
        // DispatchSource cancel is safe from any thread.
        fileWatchSource?.cancel()
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
