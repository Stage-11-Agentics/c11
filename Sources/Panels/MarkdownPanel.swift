import AppKit
import Foundation
import Combine

/// A segment of markdown content — either regular markdown or a mermaid diagram.
enum MarkdownSegment: Identifiable {
    case markdown(id: String, content: String)
    case mermaid(id: String, code: String, renderedImage: NSImage?)

    var id: String {
        switch self {
        case .markdown(let id, _): return id
        case .mermaid(let id, _, _): return id
        }
    }
}

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .markdown

    /// Absolute path to the markdown file being displayed.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published private(set) var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.richtext" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Parsed segments of the content (markdown + mermaid blocks).
    @Published private(set) var segments: [MarkdownSegment] = []

    /// Tracks the appearance used for the last mermaid render pass.
    private var lastRenderedDark: Bool?

    /// Observer for system appearance changes.
    private var appearanceObserver: NSObjectProtocol?

    // MARK: - File watching

    // nonisolated(unsafe) because deinit is not guaranteed to run on the
    // main actor, but DispatchSource.cancel() is thread-safe.
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.markdown-file-watch", qos: .utility)

    /// Maximum number of reattach attempts after a file delete/rename event.
    private static let maxReattachAttempts = 6
    /// Delay between reattach attempts (total window: attempts * delay = 3s).
    private static let reattachDelay: TimeInterval = 0.5

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            // Session restore can create a panel before the file is recreated.
            // Retry briefly so atomic-rename recreations can reconnect.
            scheduleReattach(attempt: 1)
        }
        startAppearanceObserver()
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
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            content = newContent
            isFileUnavailable = false
        } catch {
            // Fallback: try ISO Latin-1, which accepts all 256 byte values,
            // covering legacy encodings like Windows-1252.
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                content = decoded
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
        parseSegments()
    }

    // MARK: - Mermaid segment parsing

    /// Regex pattern to match fenced mermaid code blocks.
    private static let mermaidPattern = try! NSRegularExpression(
        pattern: "```mermaid\\s*\\n([\\s\\S]*?)```",
        options: []
    )

    /// Stable ID from segment index and content prefix.
    private static func segmentId(index: Int, content: String) -> String {
        let prefix = String(content.prefix(64))
        return "\(index):\(prefix.hashValue)"
    }

    /// Parse content into segments, splitting on mermaid fenced code blocks.
    private func parseSegments() {
        let text = content
        guard !text.isEmpty else {
            segments = []
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = Self.mermaidPattern.matches(in: text, range: fullRange)

        guard !matches.isEmpty else {
            // No mermaid blocks — single markdown segment
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
            // Extract mermaid code (capture group 1)
            let codeRange = match.range(at: 1)
            let code = nsText.substring(with: codeRange).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(.mermaid(id: Self.segmentId(index: segIndex, content: code), code: code, renderedImage: nil))
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

        // Preserve rendered images for segments whose content hasn't changed
        let oldSegments = segments
        for (i, seg) in result.enumerated() {
            if case .mermaid(let id, let code, _) = seg,
               let old = oldSegments.first(where: { $0.id == id }),
               case .mermaid(_, _, let oldImage) = old,
               oldImage != nil {
                result[i] = .mermaid(id: id, code: code, renderedImage: oldImage)
            }
        }

        segments = result
        renderMermaidSegments()
    }

    /// Render mermaid segments asynchronously and update when images are ready.
    private func renderMermaidSegments() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lastRenderedDark = isDark

        // Build set of active render keys so stale in-flight processes can be cancelled
        var activeKeys = Set<String>()
        for segment in segments {
            guard case .mermaid(_, let code, let existingImage) = segment else { continue }
            if existingImage != nil { continue }
            activeKeys.insert(MermaidRenderer.shared.renderCacheKey(code: code, isDark: isDark))
        }
        MermaidRenderer.shared.cancelRendersExcept(activeKeys: activeKeys)

        for (index, segment) in segments.enumerated() {
            guard case .mermaid(let id, let code, let existingImage) = segment else { continue }
            // Skip if already rendered
            if existingImage != nil { continue }
            MermaidRenderer.shared.render(code: code, isDark: isDark) { [weak self] image in
                guard let self else { return }
                guard index < self.segments.count,
                      case .mermaid(let currentId, _, _) = self.segments[index],
                      currentId == id else { return }
                self.segments[index] = .mermaid(id: id, code: code, renderedImage: image)
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
            if case .mermaid(let id, let code, let image) = segment, image != nil {
                segments[i] = .mermaid(id: id, code: code, renderedImage: nil)
            }
        }
        renderMermaidSegments()
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
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
                    self.loadFileContent()
                    if self.isFileUnavailable {
                        // File not yet replaced — retry until it reappears.
                        self.scheduleReattach(attempt: 1)
                    } else {
                        // File already replaced — reattach to the new inode immediately.
                        self.startFileWatcher()
                    }
                }
            } else {
                // Content changed — reload.
                DispatchQueue.main.async {
                    self.loadFileContent()
                }
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
                guard !self.isClosed else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
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
