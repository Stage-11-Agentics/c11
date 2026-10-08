import Foundation
import Combine
import Bonsplit

/// Transient reading state survives WebKit eviction; durable preferences stay on the panel.
struct MarkdownReadingPosition: Equatable, Sendable {
    var line: Int = 1
    var offset: Double = 0
    var sourceMode = false
    var findQuery = ""
    var findOpen = false

    init() {}
    init?(state: [String: Any]) {
        guard let lines = state["lines"] as? [String: Any], let line = lines["first"] as? Int else { return nil }
        self.line = max(1, line)
        let offset = lines["offset"] as? Double ?? 0
        self.offset = offset.isFinite ? min(max(offset, -1_000_000), 1_000_000) : 0
        sourceMode = state["mode"] as? String == "source"
        let find = state["find"] as? [String: Any]
        let query = find?["query"] as? String ?? ""
        findQuery = String(query.prefix(8192))
        findOpen = find?["open"] as? Bool ?? false
    }
}

struct MarkdownNavigationTarget: Equatable, Sendable {
    let fileURL: URL
    let fragment: String?

    init(fileURL: URL, fragment: String? = nil) {
        var normalized = fileURL
        var resolvedFragment = fragment
        if var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) {
            if resolvedFragment == nil { resolvedFragment = components.fragment }
            components.fragment = nil
            normalized = components.url ?? fileURL
        }
        self.fileURL = normalized.standardizedFileURL
        self.fragment = resolvedFragment?.isEmpty == true ? nil : resolvedFragment
    }
}

enum MarkdownNavigationOrigin: String, Sendable {
    case documentLink
    case agentCLI
    case palette
    case backlink
    case history
}

enum MarkdownNavigationOutcome: Equatable, Sendable {
    case navigated
    case unchanged
    case invalidTarget
    case notFound
    case notReadable
    case outsideScope
    case superseded
    case panelClosed
}

struct MarkdownNavigationEntry: Equatable, Sendable {
    let target: MarkdownNavigationTarget
    let origin: MarkdownNavigationOrigin
    let scopeRootPath: String?
    var readingPosition: MarkdownReadingPosition?
}

struct MarkdownNavigationHistory: Equatable, Sendable {
    private(set) var entries: [MarkdownNavigationEntry] = []
    private(set) var currentIndex = -1

    private static let maximumEntries = 100

    var current: MarkdownNavigationEntry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex >= 0 && currentIndex < entries.count - 1 }

    mutating func reset(
        to target: MarkdownNavigationTarget?,
        origin: MarkdownNavigationOrigin = .agentCLI,
        scopeRootPath: String? = nil
    ) {
        entries = target.map {
            [MarkdownNavigationEntry(target: $0, origin: origin, scopeRootPath: scopeRootPath, readingPosition: nil)]
        } ?? []
        currentIndex = target == nil ? -1 : 0
    }

    @discardableResult
    mutating func push(
        _ target: MarkdownNavigationTarget,
        origin: MarkdownNavigationOrigin,
        scopeRootPath: String?,
        preserving position: MarkdownReadingPosition?
    ) -> Bool {
        guard currentIndex >= 0 else {
            entries = [MarkdownNavigationEntry(
                target: target, origin: origin, scopeRootPath: scopeRootPath, readingPosition: nil
            )]
            currentIndex = 0
            return true
        }

        if let position { entries[currentIndex].readingPosition = position }
        guard entries[currentIndex].target != target else { return false }
        entries = Array(entries.prefix(currentIndex + 1))
        entries.append(MarkdownNavigationEntry(
            target: target, origin: origin, scopeRootPath: scopeRootPath, readingPosition: nil
        ))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        currentIndex = entries.count - 1
        return true
    }

    func target(backward: Bool) -> (index: Int, entry: MarkdownNavigationEntry)? {
        let destination = currentIndex + (backward ? -1 : 1)
        guard entries.indices.contains(destination) else { return nil }
        return (destination, entries[destination])
    }

    @discardableResult
    mutating func move(to destination: Int, preserving position: MarkdownReadingPosition?) -> MarkdownNavigationEntry? {
        guard entries.indices.contains(destination) else { return nil }
        if currentIndex >= 0, let position { entries[currentIndex].readingPosition = position }
        currentIndex = destination
        return entries[currentIndex]
    }

    func jsonSnapshot() -> [String: Any] {
        [
            "index": currentIndex,
            "entries": entries.enumerated().map { index, entry in
                var value: [String: Any] = [
                    "index": index,
                    "path": entry.target.fileURL.path,
                    "fragment": entry.target.fragment as Any? ?? NSNull(),
                    "origin": entry.origin.rawValue
                ]
                if let position = entry.readingPosition {
                    value["position"] = [
                        "line": position.line,
                        "offset": position.offset,
                        "source_mode": position.sourceMode,
                        "find_query": position.findQuery,
                        "find_open": position.findOpen
                    ]
                } else {
                    value["position"] = NSNull()
                }
                return value
            }
        ]
    }
}

/// The app keeps all visible readers plus four recently hidden readers. Capture
/// is asynchronous; visibility and query epochs are checked again before teardown.
@MainActor
final class MarkdownRendererCache {
    static let shared = MarkdownRendererCache()
    let evictions = PassthroughSubject<UUID, Never>()
    let visibilityChanges = PassthroughSubject<UUID, Never>()
    private var policy = MarkdownRendererRetentionPolicy()
    @MainActor private final class Entry {
        weak var panel: MarkdownPanel?
        weak var renderer: MarkdownWebRenderer?
        var epoch = 0
        var capture: UUID?
        init(_ panel: MarkdownPanel) { self.panel = panel; renderer = panel.renderer }
    }
    private var entries: [UUID: Entry] = [:]

    func register(_ panel: MarkdownPanel) {
        entries[panel.id] = Entry(panel)
        policy.insert(panel.id)
        policy.setVisible(panel.id, panel.isRendererVisible)
        reconsider()
    }

    func visibilityChanged(_ panel: MarkdownPanel) {
        guard let entry = entries[panel.id] else { return }
#if DEBUG
        if !panel.isRendererVisible, let renderer = panel.renderer,
           let position = MarkdownReadingPosition(state: renderer.state) {
            dlog("markdown.renderer.hidden panel=\(panel.id.uuidString) line=\(position.line) offset=\(position.offset) width=\(renderer.webView.frame.width) height=\(renderer.webView.frame.height)")
        }
#endif
        entry.epoch += 1
        policy.setVisible(panel.id, panel.isRendererVisible)
        visibilityChanges.send(panel.id)
        reconsider()
    }

    func queryStarted(_ panel: MarkdownPanel) {
        guard let entry = entries[panel.id] else { return }
        entry.epoch += 1
        policy.setPinned(panel.id, true)
    }

    func queryFinished(_ panel: MarkdownPanel) {
        guard entries[panel.id] != nil else { return }
        policy.setPinned(panel.id, panel.renderer?.hasQueriesInFlight == true)
        reconsider()
    }

    func remove(_ panel: MarkdownPanel) {
        entries.removeValue(forKey: panel.id)
        policy.remove(panel.id)
        reconsider()
    }

    func reconsider() {
        for (id, entry) in entries where entry.panel == nil {
            entry.renderer?.close()
            entries.removeValue(forKey: id)
            policy.remove(id)
        }
        for id in policy.evictionCandidates {
            guard let entry = entries[id], entry.capture == nil,
                  let panel = entry.panel, let renderer = panel.renderer,
                  !renderer.hasQueriesInFlight, renderer.canCaptureReadingPosition else { continue }
            let token = UUID(), epoch = entry.epoch
            entry.capture = token
            renderer.captureReadingPosition { [weak self, weak panel, weak renderer] position in
                guard let self, let panel, let renderer,
                      let current = self.entries[id], current.capture == token else { return }
                current.capture = nil
                if current.epoch == epoch, !panel.isRendererVisible,
                   !renderer.hasQueriesInFlight, panel.renderer === renderer,
                   self.policy.evictionCandidates.contains(id) {
                    self.entries.removeValue(forKey: id)
                    self.policy.remove(id)
                    panel.evictRenderer(renderer, position: position)
                    self.evictions.send(id)
#if DEBUG
                    dlog("markdown.renderer.evicted panel=\(id.uuidString) line=\(position.line) offset=\(position.offset) source=\(position.sourceMode ? 1 : 0) width=\(renderer.webView.frame.width) height=\(renderer.webView.frame.height)")
#endif
                }
                self.reconsider()
            }
        }
    }
}
