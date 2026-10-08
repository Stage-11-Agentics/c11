import AppKit
import Foundation
import Combine

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let createdAt: Date?
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

    // MARK: - Durable presentation and lazy renderer

    @Published private(set) var presentation: MarkdownPresentation
    private(set) var renderer: MarkdownWebRenderer?
    @Published private(set) var isFindPresented = false
    @Published private(set) var isFindDismissed = false
    @Published private(set) var findQuery = ""
    @Published private(set) var findFocusRequestToken = 0
    private var cachedExternalAppPath: String?
    private var cachedExternalAppName: String?
    private var pendingFindUpdate: DispatchWorkItem?
    var fontScale: Double { presentation.fontScale }
    var theme: String { presentation.theme }
    var typeface: String { presentation.typeface }
    var outlineOpen: Bool? { presentation.outlineOpen }

    static let fontScaleRange = MarkdownPresentation.fontScaleRange
    static let fontScaleStep = MarkdownPresentation.fontScaleStep

    /// Interactive controls clamp; persisted malformed values use defaults.
    static func normalizedFontScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return (min(max(value, fontScaleRange.lowerBound), fontScaleRange.upperBound) * 10).rounded() / 10
    }

    @discardableResult func zoomIn() -> Bool { setFontScale(fontScale + Self.fontScaleStep) }
    @discardableResult func zoomOut() -> Bool { setFontScale(fontScale - Self.fontScaleStep) }
    @discardableResult func resetZoom() -> Bool { setFontScale(1.0) }

    @discardableResult
    func setFontScale(_ value: Double) -> Bool {
        presentation.fontScale = Self.normalizedFontScale(value)
        presentation.saveLastUsed(fields: [.fontScale])
        renderer?.synchronize()
        return true
    }

    @discardableResult
    func setTheme(_ value: String) -> Bool {
        guard MarkdownPresentation.themeNames.contains(value) else { return false }
        presentation.theme = value
        presentation.saveLastUsed(fields: [.theme])
        renderer?.synchronize()
        return true
    }

    @discardableResult
    func setTypeface(_ value: String) -> Bool {
        guard MarkdownPresentation.typefaceNames.contains(value) else { return false }
        presentation.typeface = value
        presentation.saveLastUsed(fields: [.typeface])
        renderer?.synchronize()
        return true
    }

    func setOutlineOpen(_ value: Bool?) {
        presentation.outlineOpen = value
        presentation.saveLastUsed(fields: [.outlineOpen])
        renderer?.synchronize()
    }

    func toggleOutline() {
        let bridgeOpen = renderer?.readerOutline.value.isOpen
        setOutlineOpen(!(presentation.outlineOpen ?? bridgeOpen ?? false))
    }

    func requestFind() {
        isFindDismissed = false
        isFindPresented = true
        findFocusRequestToken &+= 1
    }

    func setFindQuery(_ query: String) {
        isFindDismissed = false
        findQuery = query
        pendingFindUpdate?.cancel()
        pendingFindUpdate = nil
        guard !query.isEmpty else {
            renderer?.call("findClose")
            return
        }
        let update = DispatchWorkItem { [weak self] in
            self?.renderer?.call("find", arguments: [query])
        }
        pendingFindUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: update)
    }

    func findNext() {
        applyPendingFindUpdate()
        renderer?.call("findNext")
    }

    func findPrevious() {
        applyPendingFindUpdate()
        renderer?.call("findPrevious")
    }

    private func applyPendingFindUpdate() {
        guard let pendingFindUpdate else { return }
        pendingFindUpdate.cancel()
        self.pendingFindUpdate = nil
        if !findQuery.isEmpty { renderer?.call("find", arguments: [findQuery]) }
    }

    func closeFind() {
        guard isFindVisible else { return }
        isFindDismissed = true
        isFindPresented = false
        findQuery = ""
        pendingFindUpdate?.cancel()
        pendingFindUpdate = nil
        renderer?.call("findClose")
    }

    var isFindVisible: Bool {
        isFindPresented || !findQuery.isEmpty || (!isFindDismissed && renderer?.readerFind.value != nil)
    }

    @discardableResult
    func dismissReaderOverlay() -> Bool {
        if renderer?.state["diagram_open"] is Int {
            renderer?.call("closeDiagram")
            return true
        }
        if isFindVisible {
            closeFind()
            return true
        }
        let bridgeOpen = renderer?.readerOutline.value.isOpen
        guard presentation.outlineOpen ?? bridgeOpen ?? false else { return false }
        setOutlineOpen(false)
        return true
    }

    var defaultExternalAppName: String {
        guard let filePath else { return String(localized: "markdown.reader.defaultApp", defaultValue: "default app") }
        if cachedExternalAppPath == filePath, let cachedExternalAppName { return cachedExternalAppName }
        let fileURL = URL(fileURLWithPath: filePath)
        let appURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        let appBundle = appURL.flatMap { Bundle(url: $0) }
        let name = (appBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (appBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL?.deletingPathExtension().lastPathComponent
            ?? String(localized: "markdown.reader.defaultApp", defaultValue: "default app")
        cachedExternalAppPath = filePath
        cachedExternalAppName = name
        return name
    }

    @discardableResult
    func openExternally() -> Bool {
        guard let filePath else { return false }
        let fileURL = URL(fileURLWithPath: filePath)
        return NSWorkspace.shared.open(fileURL)
    }

    func applyRestoredFontScale(_ value: Double) {
        presentation.fontScale = MarkdownPresentation.normalizedFontScale(value)
        renderer?.synchronize()
    }

    func applyRestoredPresentation(_ snapshot: SessionMarkdownPanelSnapshot) {
        presentation = snapshot.presentation
        renderer?.synchronize()
    }

    private var visibleRendererHosts: Set<UUID> = []
    var isRendererVisible: Bool { !visibleRendererHosts.isEmpty }
    private(set) var readingPosition: MarkdownReadingPosition?
    private(set) var readingContent: String?

    func setRendererVisible(_ visible: Bool, hostID: UUID) {
        let previous = isRendererVisible
        if visible { visibleRendererHosts.insert(hostID) }
        else { visibleRendererHosts.remove(hostID) }
        if isRendererVisible != previous {
            renderer?.webView.setViewportVisible(isRendererVisible)
            MarkdownRendererCache.shared.visibilityChanged(self)
        }
    }

    func evictRenderer(_ renderer: MarkdownWebRenderer, position: MarkdownReadingPosition) {
        guard self.renderer === renderer else { return }
        readingPosition = position
        readingContent = content
        renderer.close()
        self.renderer = nil
    }

    func clearReadingContent(ifMatching content: String) {
        guard readingContent == content else { return }
        readingContent = nil
    }

    /// Called by the visible NSView host only; model construction never starts WebKit.
    func ensureRenderer() -> MarkdownWebRenderer {
        if let renderer { return renderer }
        let created = MarkdownWebRenderer(panel: self)
        renderer = created
        MarkdownRendererCache.shared.register(self)
        return created
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
    init(
        id: UUID? = nil,
        createdAt: Date? = Date(),
        workspaceId: UUID,
        filePath: String? = nil
    ) {
        self.id = id ?? UUID()
        self.createdAt = createdAt
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = Self.titleForFilePath(filePath)
        self.presentation = MarkdownPresentation.lastUsed()

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
        // Only focus a mounted renderer. Background socket focus never raises a window.
        if let view = renderer?.webView {
            view.allowsPanelFocus = true
            view.requestPanelFocusIfAllowed()
        }
    }

    func unfocus() {
        renderer?.webView.allowsPanelFocus = false
    }

    func close() {
        isClosed = true
        MarkdownRendererCache.shared.remove(self)
        stopFileWatcher()
        stopAppearanceObserver()
        renderer?.close()
        renderer = nil
        watchQueue.async { [weak self] in
            self?.pendingReload?.cancel()
            self?.pendingReload = nil
        }
    }

    func triggerFlash() {
        guard NotificationAreaFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
        guard let filePath else {
            content = ""
            isFileUnavailable = false
            renderer?.synchronize()
            return
        }
        applyExternalContent(Self.readContent(path: filePath), isLiveChange: false)
        // Tab sheet `active`: a load is not a change; seed from the file's mtime.
        lastContentChangeAt = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date
    }

    /// When the watched file's content last changed (mtime at load, then each
    /// live reload that actually changed the text). Plain store, not published.
    private(set) var lastContentChangeAt: Date?

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
    private func applyExternalContent(_ newContent: String?, isLiveChange: Bool = true) {
        guard !isClosed else { return }
        guard let newContent else {
            isFileUnavailable = true
            return
        }
        let wasUnavailable = isFileUnavailable
        isFileUnavailable = false
        guard newContent != content || wasUnavailable else { return }
        content = newContent
        if isLiveChange { lastContentChangeAt = Date() }
        renderer?.synchronize()
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
        renderer?.synchronize()
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
