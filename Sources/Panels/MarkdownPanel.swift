import AppKit
import Foundation
import Combine

@MainActor
protocol MarkdownPanelReaderCommanding: AnyObject {
    var readerOutlineIsOpen: Bool { get }
    func synchronize()
    func call(_ method: String)
    func openFind(focusAllowed: Bool)
}

enum MarkdownPanelReaderEvent {
    case rendererAvailable(MarkdownWebRenderer)
    case rendererEvicted(MarkdownWebRenderer)
    case state([String: Any])
    case closed
}

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

    /// Navigation history is transient and belongs to this panel only.
    @Published private(set) var navigationHistory = MarkdownNavigationHistory()
    private(set) var pendingNavigationFragment: String?
    private(set) var pendingNavigationPosition: MarkdownReadingPosition?
    private var navigationGeneration = 0
    var currentNavigationToken: Int { navigationGeneration }

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
    private var readerCommandRendererOverride: (any MarkdownPanelReaderCommanding)?
    var readerCommandRendererForTesting: (any MarkdownPanelReaderCommanding)? {
        get { readerCommandRendererOverride }
        set { readerCommandRendererOverride = newValue }
    }
    private var readerCommandRenderer: (any MarkdownPanelReaderCommanding)? {
        readerCommandRendererOverride ?? renderer
    }
    private var cachedExternalAppPath: String?
    private var cachedExternalAppName: String?
    private var latestRendererState: [String: Any] = [:]
    var fontScale: Double { presentation.fontScale }
    var theme: String { presentation.theme }
    var typeface: String { presentation.typeface }
    var outlineOpen: Bool? { presentation.outlineOpen }
    var canNavigateBack: Bool { navigationHistory.canGoBack }
    var canNavigateForward: Bool { navigationHistory.canGoForward }
    var navigationTarget: MarkdownNavigationTarget? { navigationHistory.current?.target }

    /// Navigate this panel without changing workspace or panel selection.
    /// Target validation and disk reads run away from the main actor.
    @discardableResult
    func navigate(
        to fileURL: URL,
        fragment: String?,
        origin: MarkdownNavigationOrigin
    ) async -> MarkdownNavigationOutcome {
        await performNavigation(
            to: MarkdownNavigationTarget(fileURL: fileURL, fragment: fragment),
            origin: origin,
            preserving: nil,
            pageAlreadyHandled: false,
            historyDestination: nil,
            historyEntry: nil,
            cancellation: nil
        )
    }

    /// Socket navigation uses a cancellation token so a timed-out caller can
    /// revoke the request before it mutates this panel.
    @discardableResult
    func navigate(
        to fileURL: URL,
        fragment: String?,
        origin: MarkdownNavigationOrigin,
        cancellation: MarkdownNavigationCancellation
    ) async -> MarkdownNavigationOutcome {
        await performNavigation(
            to: MarkdownNavigationTarget(fileURL: fileURL, fragment: fragment),
            origin: origin,
            preserving: nil,
            pageAlreadyHandled: false,
            historyDestination: nil,
            historyEntry: nil,
            cancellation: cancellation
        )
    }

    @discardableResult
    func navigateBack() async -> MarkdownNavigationOutcome {
        await navigateHistory(backward: true)
    }

    @discardableResult
    func navigateForward() async -> MarkdownNavigationOutcome {
        await navigateHistory(backward: false)
    }

    /// Called after the bundled page has validated and applied a same-page
    /// anchor jump. The supplied position is captured before that jump.
    @discardableResult
    func navigateFromDocumentLink(
        to fileURL: URL,
        fragment: String?,
        position: MarkdownReadingPosition?,
        pageAlreadyHandled: Bool,
        navigationToken: Int? = nil
    ) async -> MarkdownNavigationOutcome {
        await performNavigation(
            to: MarkdownNavigationTarget(fileURL: fileURL, fragment: fragment),
            origin: .documentLink,
            preserving: position,
            pageAlreadyHandled: pageAlreadyHandled,
            historyDestination: nil,
            historyEntry: nil,
            cancellation: nil,
            navigationToken: navigationToken
        )
    }

    /// Reserves the current navigation before an async link action starts.
    /// Page-applied anchors use this synchronously so an older position restore
    /// cannot scroll after WebKit has already moved to the new anchor.
    @discardableResult
    func beginNavigationIntent() -> Int {
        navigationGeneration &+= 1
        renderer?.advanceNavigation(to: navigationGeneration)
        return navigationGeneration
    }

    func isCurrentNavigation(_ token: Int) -> Bool {
        !isClosed && token == navigationGeneration
    }

    func prepareDocumentLink(
        _ fileURL: URL,
        maximumContentBytes: Int = MarkdownNavigationPolicy.maximumNavigationContentBytes
    ) async -> MarkdownNavigationPreparation {
        let currentPath = filePath
        let target = MarkdownNavigationTarget(fileURL: fileURL)
        return await Task.detached(priority: .userInitiated) {
            MarkdownNavigationPolicy.prepare(
                target,
                currentFilePath: currentPath,
                origin: .documentLink,
                maximumContentBytes: maximumContentBytes
            )
        }.value
    }

    private func navigateHistory(backward: Bool) async -> MarkdownNavigationOutcome {
        guard !isClosed else { return .panelClosed }
        guard let destination = navigationHistory.target(backward: backward) else { return .unchanged }
        return await performNavigation(
            to: destination.entry.target,
            origin: .history,
            preserving: nil,
            pageAlreadyHandled: false,
            historyDestination: destination.index,
            historyEntry: destination.entry,
            cancellation: nil
        )
    }

    private func performNavigation(
        to target: MarkdownNavigationTarget,
        origin: MarkdownNavigationOrigin,
        preserving suppliedPosition: MarkdownReadingPosition?,
        pageAlreadyHandled: Bool,
        historyDestination: Int?,
        historyEntry: MarkdownNavigationEntry?,
        cancellation: MarkdownNavigationCancellation?,
        navigationToken: Int? = nil
    ) async -> MarkdownNavigationOutcome {
        guard !isClosed else { return .panelClosed }
        guard cancellation?.isCancelled != true else { return .superseded }
        let isCurrentTarget = historyDestination == nil && navigationHistory.current?.target == target
        if isCurrentTarget, target.fragment == nil { return .unchanged }

        let generation = navigationToken ?? beginNavigationIntent()
        guard isCurrentNavigation(generation) else { return .superseded }
        let currentPath = filePath
        let position: MarkdownReadingPosition?
        if let suppliedPosition { position = suppliedPosition }
        else { position = await captureNavigationPosition() }
        guard !isClosed else { return .panelClosed }
        guard generation == navigationGeneration else { return .superseded }
        guard cancellation?.isCancelled != true else { return .superseded }

        let preparation = await Task.detached(priority: .userInitiated) {
            MarkdownNavigationPolicy.prepare(
                target,
                currentFilePath: currentPath,
                origin: historyEntry == nil ? origin : .history,
                scopeRootPath: historyEntry?.scopeRootPath,
                allowOutsideScope: historyEntry?.origin == .agentCLI
            )
        }.value
        guard !isClosed else { return .panelClosed }
        guard generation == navigationGeneration else { return .superseded }
        guard cancellation?.isCancelled != true else { return .superseded }

        switch preparation {
        case .rejected(let outcome):
            return outcome
        case .ready(let path, let preparedContent, let modificationDate, let scopeRootPath):
            let sameDocument = currentPath.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == path
            } ?? false
            var historyMoved = true
            let commit = {
                if !sameDocument {
                    self.stopFileWatcher()
                    self.filePath = path
                    self.displayTitle = Self.titleForFilePath(path)
                    self.content = preparedContent ?? ""
                    self.readingContent = nil
                    self.readingPosition = nil
                    self.isFileUnavailable = false
                    self.lastContentChangeAt = modificationDate
                    self.startFileWatcher()
                }

                if isCurrentTarget {
                    // Repeating an explicit fragment navigation is an action:
                    // reapply the fragment without growing history.
                    self.pendingNavigationPosition = nil
                } else if let historyDestination, let historyEntry {
                    guard self.navigationHistory.move(to: historyDestination, preserving: position) != nil else {
                        historyMoved = false
                        return
                    }
                    self.pendingNavigationPosition = historyEntry.readingPosition
                } else {
                    self.navigationHistory.push(
                        target,
                        origin: origin,
                        scopeRootPath: scopeRootPath,
                        preserving: position
                    )
                    self.pendingNavigationPosition = nil
                }
                self.pendingNavigationFragment = target.fragment

                if sameDocument {
                    if !pageAlreadyHandled && (!isCurrentTarget || target.fragment != nil) {
                        self.renderer?.navigateWithinDocument(
                            position: self.pendingNavigationPosition,
                            fragment: target.fragment,
                            navigationToken: generation
                        )
                    }
                } else {
                    self.renderer?.prepareNavigation(
                        position: self.pendingNavigationPosition,
                        fragment: target.fragment,
                        navigationToken: generation
                    )
                    self.renderer?.synchronize()
                }
            }
            let requestIsActive: Bool
            if let cancellation {
                requestIsActive = cancellation.commitIfActive(commit)
            } else {
                commit()
                requestIsActive = true
            }
            guard requestIsActive, historyMoved else { return .superseded }
            return .navigated
        }
    }

    private func captureNavigationPosition() async -> MarkdownReadingPosition? {
        guard let renderer else { return readingPosition }
        return await withCheckedContinuation { continuation in
            renderer.captureReadingPosition { position in
                continuation.resume(returning: position)
            }
        }
    }

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
        publishModelPresentationState()
        renderer?.synchronize()
        return true
    }

    @discardableResult
    func setTheme(_ value: String) -> Bool {
        guard MarkdownPresentation.themeNames.contains(value) else { return false }
        presentation.theme = value
        presentation.saveLastUsed(fields: [.theme])
        publishModelPresentationState()
        renderer?.synchronize()
        return true
    }

    @discardableResult
    func setTypeface(_ value: String) -> Bool {
        guard MarkdownPresentation.typefaceNames.contains(value) else { return false }
        presentation.typeface = value
        presentation.saveLastUsed(fields: [.typeface])
        publishModelPresentationState()
        renderer?.synchronize()
        return true
    }

    func setOutlineOpen(_ value: Bool?) {
        presentation.outlineOpen = value
        presentation.saveLastUsed(fields: [.outlineOpen])
        publishModelPresentationState()
        readerCommandRenderer?.synchronize()
    }

    func recordPageOutlineDismissal() {
        setOutlineOpen(false)
    }

    func toggleOutline() {
        let bridgeOpen = readerCommandRenderer?.readerOutlineIsOpen
        setOutlineOpen(!(presentation.outlineOpen ?? bridgeOpen ?? false))
    }

    func requestFind() {
        let focusAllowed = renderer?.webView.allowsPanelFocus == true
        readerCommandRenderer?.openFind(focusAllowed: focusAllowed)
        if focusAllowed, let renderer {
            renderer.webView.requestPanelFocusIfAllowed()
        }
    }

    func findNext() {
        readerCommandRenderer?.call("findNext")
    }

    func findPrevious() {
        readerCommandRenderer?.call("findPrevious")
    }

    func closeFind() {
        readerCommandRenderer?.call("findClose")
    }

    var isFindVisible: Bool {
        renderer?.readerFind.value?.isOpen == true
    }

    @discardableResult
    func dismissReaderOverlay(pageConsumedEscape: Bool) -> Bool {
        guard !pageConsumedEscape else { return false }
        let bridgeOpen = readerCommandRenderer?.readerOutlineIsOpen
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
        publishModelPresentationState()
        renderer?.synchronize()
    }

    func applyRestoredPresentation(_ snapshot: SessionMarkdownPanelSnapshot) {
        presentation = snapshot.presentation
        publishModelPresentationState()
        renderer?.synchronize()
    }

    private var visibleRendererHosts: Set<UUID> = []
    var isRendererVisible: Bool { !visibleRendererHosts.isEmpty }
    private(set) var readingPosition: MarkdownReadingPosition?
    private(set) var readingContent: String?
    private(set) var lastKnownViewportSize = NSSize(width: 800, height: 600)
    private var readerObservers: [UUID: (MarkdownPanelReaderEvent) -> Void] = [:]

    func rememberViewportSize(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 100, size.height >= 100,
              size.width <= 20_000, size.height <= 20_000 else { return }
        lastKnownViewportSize = size
    }

    @discardableResult
    func observeReaderEvents(_ observer: @escaping (MarkdownPanelReaderEvent) -> Void) -> UUID {
        let id = UUID()
        guard !isClosed else {
            observer(.closed)
            return id
        }
        readerObservers[id] = observer
        if let renderer { observer(.rendererAvailable(renderer)) }
        return id
    }

    func removeReaderObserver(_ id: UUID) {
        readerObservers.removeValue(forKey: id)
    }

    func publishRendererState(_ state: [String: Any]) {
        let compact = Self.compactReaderState(state)
        latestRendererState = compact
        notifyReaderObservers(.state(compact))
    }

    private static func compactReaderState(_ state: [String: Any]) -> [String: Any] {
        let pane = state["pane"] as? [String: Any] ?? [:]
        let lines = state["lines"] as? [String: Any] ?? [:]
        let headings = (state["heading_path"] as? [String] ?? []).prefix(32).map { String($0.prefix(512)) }
        let find = state["find"] as? [String: Any]
        let boundedFind: Any
        if let find {
            boundedFind = [
                "query": String((find["query"] as? String ?? "").prefix(8192)),
                "matches": find["matches"] ?? 0,
                "current": find["current"] ?? 0
            ]
        }
        else { boundedFind = NSNull() }
        let selection = state["selection"] as? String
        let boundedSelection: Any = selection.map { String($0.prefix(120)) as Any } ?? NSNull()
        return [
            "file": String((state["file"] as? String ?? "").prefix(4096)),
            "heading_path": headings,
            "lines": ["first": lines["first"] ?? NSNull(), "last": lines["last"] ?? NSNull(), "total": lines["total"] ?? NSNull()],
            "progress": state["progress"] ?? 0,
            "minutes_left": state["minutes_left"] ?? 0,
            "pane": ["width": pane["width"] ?? NSNull(), "effectiveWidth": pane["effectiveWidth"] ?? NSNull(), "size": pane["size"] ?? NSNull()],
            "theme": state["theme"] ?? NSNull(),
            "typeface": state["typeface"] ?? NSNull(),
            "font_scale": state["font_scale"] ?? NSNull(),
            "find": boundedFind,
            "selection": boundedSelection
        ]
    }

    private func publishModelPresentationState() {
        guard !latestRendererState.isEmpty else { return }
        var state = latestRendererState
        var themeState = state["theme"] as? [String: Any] ?? [:]
        themeState["choice"] = theme
        if theme == "light" || theme == "dark" { themeState["resolved"] = theme }
        state["theme"] = themeState
        var typefaceState = state["typeface"] as? [String: Any] ?? [:]
        typefaceState["choice"] = typeface
        state["typeface"] = typefaceState
        state["font_scale"] = fontScale
        var outlineState = state["outline"] as? [String: Any] ?? [:]
        if let outlineOpen { outlineState["open"] = outlineOpen }
        state["outline"] = outlineState
        state["file"] = filePath ?? ""
        var paneState = state["pane"] as? [String: Any] ?? [:]
        paneState["width"] = Int(lastKnownViewportSize.width)
        paneState["effectiveWidth"] = Double(lastKnownViewportSize.width) / fontScale
        state["pane"] = paneState
        latestRendererState = state
        notifyReaderObservers(.state(state))
    }

    private func notifyReaderObservers(_ event: MarkdownPanelReaderEvent) {
        for observer in Array(readerObservers.values) { observer(event) }
    }

    func setRendererVisible(_ visible: Bool, hostID: UUID) {
        let previous = isRendererVisible
        if visible { visibleRendererHosts.insert(hostID) }
        else { visibleRendererHosts.remove(hostID) }
        if isRendererVisible != previous {
            renderer?.webView.setViewportVisible(isRendererVisible)
            if !isRendererVisible, let size = renderer?.webView.frame.size {
                rememberViewportSize(size)
            }
            MarkdownRendererCache.shared.visibilityChanged(self)
        }
    }

    func evictRenderer(_ renderer: MarkdownWebRenderer, position: MarkdownReadingPosition) {
        guard self.renderer === renderer else { return }
        readingPosition = position
        readingContent = content
        rememberViewportSize(renderer.webView.frame.size)
        notifyReaderObservers(.rendererEvicted(renderer))
        renderer.close()
        self.renderer = nil
    }

    func clearReadingContent(ifMatching content: String) {
        guard readingContent == content else { return }
        readingContent = nil
    }

    /// The visible host or an explicit agent read may create WebKit; model
    /// construction alone remains renderer-free.
    func ensureRenderer() -> MarkdownWebRenderer {
        if let renderer { return renderer }
        let created = MarkdownWebRenderer(panel: self)
        renderer = created
        MarkdownRendererCache.shared.register(self)
        notifyReaderObservers(.rendererAvailable(created))
        return created
    }

    func takePendingNavigation() -> (position: MarkdownReadingPosition?, fragment: String?) {
        let pending = (pendingNavigationPosition, pendingNavigationFragment)
        clearPendingNavigation()
        return pending
    }

    func clearPendingNavigation() {
        pendingNavigationPosition = nil
        pendingNavigationFragment = nil
    }

    /// Observer for system appearance changes.
    private var appearanceObserver: NSObjectProtocol?

    // MARK: - File watching

    // nonisolated(unsafe) because deinit is not guaranteed to run on the
    // main actor, but DispatchSource.cancel() is thread-safe.
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private(set) var isClosed: Bool = false
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
        filePath: String? = nil,
        fragment: String? = nil,
        initialNavigationOrigin: MarkdownNavigationOrigin = .agentCLI,
        initialNavigationScopeRootPath: String? = nil
    ) {
        self.id = id ?? UUID()
        self.createdAt = createdAt
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = Self.titleForFilePath(filePath)
        self.pendingNavigationFragment = filePath == nil ? nil : fragment
        self.presentation = MarkdownPresentation.lastUsed()
        navigationHistory.reset(
            to: filePath.map { MarkdownNavigationTarget(fileURL: URL(fileURLWithPath: $0), fragment: fragment) },
            origin: initialNavigationOrigin,
            scopeRootPath: initialNavigationScopeRootPath
        )

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
        navigationHistory.reset(to: MarkdownNavigationTarget(fileURL: URL(fileURLWithPath: path)), origin: .agentCLI)
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
        navigationGeneration &+= 1
        notifyReaderObservers(.closed)
        readerObservers.removeAll()
        MarkdownRendererCache.shared.remove(self)
        stopFileWatcher()
        stopAppearanceObserver()
        renderer?.close()
        renderer = nil
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
        applyExternalContent(Self.readContent(path: filePath), forPath: filePath, isLiveChange: false)
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
    func applyExternalContent(_ newContent: String?, forPath capturedPath: String, isLiveChange: Bool = true) {
        guard !isClosed else { return }
        // A watcher read may finish after navigation switched this panel to a
        // different document. Cancellation narrows the window; this path check
        // is the correctness guard for callbacks already in flight.
        guard capturedPath == filePath else { return }
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
                    self.applyExternalContent(result, forPath: path)
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
        watchQueue.async { [self] in
            pendingReload?.cancel()
            pendingReload = nil
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

@MainActor
enum MarkdownReaderShortcutRouter {
    static func routeNavigationHistory(event: NSEvent, panel: MarkdownPanel?) -> Bool {
        guard let panel, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else {
            return false
        }
        switch event.charactersIgnoringModifiers {
        case "[": Task { @MainActor [weak panel] in _ = await panel?.navigateBack() }
        case "]": Task { @MainActor [weak panel] in _ = await panel?.navigateForward() }
        default: return false
        }
        return true
    }

    static func routeOutlineToggle(
        event: NSEvent,
        panel: MarkdownPanel?,
        matches: (NSEvent, StoredShortcut) -> Bool
    ) -> Bool {
        guard let panel,
              matches(event, KeyboardShortcutSettings.shortcut(for: .toggleMarkdownOutline)) else { return false }
        panel.toggleOutline()
        return true
    }
}

extension MarkdownPanelReaderCommanding {
    func openFind(focusAllowed: Bool) {
        _ = focusAllowed
        call("openFind")
    }
}
