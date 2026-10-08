import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import CoreFoundation
import Bonsplit
import WebKit

final class MarkdownVisibleStateBuffer: @unchecked Sendable {
    enum InitialWaitResult {
        case ready
        case timedOut
        case finished
    }

    private let condition = NSCondition()
    private var pending: [[String: Any]] = []
    private var lastState: [String: Any]?
    private var initialized = false
    private var initialPending = false
    private var finished = false

    var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }

    func begin(with state: [String: Any]) {
        let snapshot = Self.snapshot(state)
        condition.lock()
        defer { condition.unlock() }
        guard !finished else { return }
        pending.removeAll(keepingCapacity: true)
        lastState = snapshot
        initialized = true
        initialPending = true
        pending.append(snapshot)
        condition.broadcast()
    }

    func publish(_ state: [String: Any]) {
        let snapshot = Self.snapshot(state)
        condition.lock()
        defer { condition.unlock() }
        guard initialized, !finished else { return }
        if let lastState, NSDictionary(dictionary: lastState).isEqual(to: snapshot) { return }
        lastState = snapshot
        if pending.isEmpty {
            pending.append(snapshot)
        } else if initialPending {
            if pending.count == 1 { pending.append(snapshot) }
            else { pending[1] = snapshot }
        } else {
            pending[0] = snapshot
        }
        condition.signal()
    }

    /// A re-created reader supplies a fresh snapshot. Before the first snapshot
    /// it initializes the stream; afterward it is an ordinary state change.
    func beginOrPublish(_ state: [String: Any]) {
        let snapshot = Self.snapshot(state)
        condition.lock()
        defer { condition.unlock() }
        guard !finished else { return }
        if !initialized {
            pending.removeAll(keepingCapacity: true)
            lastState = snapshot
            initialized = true
            initialPending = true
            pending.append(snapshot)
            condition.broadcast()
            return
        }
        guard let lastState, !NSDictionary(dictionary: lastState).isEqual(to: snapshot) else { return }
        self.lastState = snapshot
        if pending.isEmpty {
            pending.append(snapshot)
        } else if initialPending {
            if pending.count == 1 { pending.append(snapshot) }
            else { pending[1] = snapshot }
        } else {
            pending[0] = snapshot
        }
        condition.signal()
    }

    func waitForInitialState(timeout: TimeInterval, shouldContinue: () -> Bool) -> InitialWaitResult {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !initialized && !finished {
            guard shouldContinue() else { return .finished }
            let nextCheck = min(deadline, Date(timeIntervalSinceNow: 0.5))
            if !condition.wait(until: nextCheck), !initialized && !finished, Date() >= deadline { return .timedOut }
        }
        return initialized ? .ready : .finished
    }

    func next(timeout: TimeInterval? = nil, onWaiting: (() -> Void)? = nil) -> [String: Any]? {
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && !finished {
            if let deadline {
                if !condition.wait(until: deadline), pending.isEmpty && !finished { return nil }
            } else {
                onWaiting?()
                condition.wait()
            }
        }
        guard !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        if initialPending { initialPending = false }
        return next
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    static func snapshotForResponse(_ state: [String: Any]) -> [String: Any] {
        let pane = state["pane"] as? [String: Any] ?? [:]
        let lines = state["lines"] as? [String: Any] ?? [:]
        return [
            "file": state["file"] ?? NSNull(),
            "heading_path": state["heading_path"] ?? [],
            "lines": [
                "first": lines["first"] ?? NSNull(),
                "last": lines["last"] ?? NSNull(),
                "total": lines["total"] ?? NSNull()
            ],
            "progress": state["progress"] ?? 0,
            "minutes_left": state["minutes_left"] ?? 0,
            "size": pane["size"] ?? NSNull(),
            "theme": state["theme"] ?? NSNull(),
            "typeface": state["typeface"] ?? NSNull(),
            "font_scale": state["font_scale"] ?? NSNull(),
            "find": state["find"] ?? NSNull(),
            "selection": state["selection"] ?? NSNull()
        ]
    }

    private static func snapshot(_ state: [String: Any]) -> [String: Any] {
        snapshotForResponse(state)
    }
}

private struct MarkdownPanelTarget {
    let workspace: Workspace
    let panel: MarkdownPanel
    let surfaceId: UUID
}

private final class MarkdownWebCallGate {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var readinessWaiter: UUID?

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !completed
    }

    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !completed else { return false }
        completed = true
        readinessWaiter = nil
        return true
    }

    func installReadinessWaiter(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !completed else { return false }
        readinessWaiter = id
        return true
    }

    func cancel() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        defer { readinessWaiter = nil }
        return readinessWaiter
    }
}

@MainActor
private final class MarkdownVisibleWatch {
    private weak var panel: MarkdownPanel?
    private let buffer: MarkdownVisibleStateBuffer
    private var observationID: UUID?
    private var activeRenderer: MarkdownWebRenderer?
    private var pinnedRenderer: MarkdownWebRenderer?
    private var readinessWaiter: UUID?

    init(panel: MarkdownPanel, buffer: MarkdownVisibleStateBuffer) {
        self.panel = panel
        self.buffer = buffer
    }

    func start() {
        guard let panel else { buffer.finish(); return }
        observationID = panel.observeReaderEvents { [weak self] event in self?.receive(event) }
        if !panel.isClosed { _ = panel.ensureRenderer() }
    }

    func stop() {
        if let observationID { panel?.removeReaderObserver(observationID) }
        observationID = nil
        if let renderer = activeRenderer { cancelPendingQuery(on: renderer) }
        activeRenderer = nil
    }

    private func receive(_ event: MarkdownPanelReaderEvent) {
        switch event {
        case .rendererAvailable(let renderer): attach(to: renderer)
        case .rendererEvicted(let renderer):
            guard activeRenderer === renderer else { return }
            cancelPendingQuery(on: renderer)
            activeRenderer = nil
        case .state(let state): buffer.publish(state)
        case .closed: buffer.finish()
        }
    }

    private func attach(to renderer: MarkdownWebRenderer) {
        guard activeRenderer !== renderer else { return }
        if let activeRenderer { cancelPendingQuery(on: activeRenderer) }
        activeRenderer = renderer
        renderer.beginAgentQuery()
        pinnedRenderer = renderer
        readinessWaiter = renderer.whenReadyAndRendered { [weak self, weak renderer] ready in
            guard let self, let renderer, self.activeRenderer === renderer else { return }
            self.readinessWaiter = nil
            guard ready else {
                self.releasePin(on: renderer)
                return
            }
            renderer.call("visible") { [weak self, weak renderer] result in
                guard let self, let renderer else { return }
                if self.activeRenderer === renderer,
                   case .success(let value) = result,
                   let state = value as? [String: Any] {
                    self.buffer.beginOrPublish(state)
                    renderer.publishObservedState(state)
                }
                self.releasePin(on: renderer)
            }
        }
    }

    private func cancelPendingQuery(on renderer: MarkdownWebRenderer) {
        if let readinessWaiter { renderer.cancelReadyAndRenderedWait(readinessWaiter) }
        readinessWaiter = nil
        releasePin(on: renderer)
    }

    private func releasePin(on renderer: MarkdownWebRenderer) {
        guard pinnedRenderer === renderer else { return }
        pinnedRenderer = nil
        renderer.endAgentQuery()
    }
}

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `markdown.*,feedback.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchMarkdownFeedback(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "feedback.open":
            return v2Result(id: id, self.v2FeedbackOpen(params: params))
        case "feedback.submit":
            return v2Result(id: id, self.v2FeedbackSubmit(params: params))
        case "markdown.open":
            return v2Result(id: id, self.v2MarkdownOpen(params: params))
        case "markdown.get_content":
            return v2Result(id: id, self.v2MarkdownGetContent(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    nonisolated func v2DispatchMarkdownWorker(_ method: String, params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.markdownAgentCLI) else {
            return .err(code: "unsupported", message: "Markdown agent commands are disabled", data: ["feature": CapabilityFeatures.ID.markdownAgentCLI.rawValue])
        }
        switch method {
        case "markdown.scroll": return v2MarkdownScroll(params: params)
        case "markdown.navigate": return v2MarkdownNavigate(params: params)
        case "markdown.history": return v2MarkdownHistory(params: params)
        case "markdown.links": return v2MarkdownLinks(params: params)
        case "markdown.visible":
            guard v2Bool(params, "watch") != true else {
                return .err(code: "invalid_params", message: "markdown.visible watch requires a streaming socket", data: nil)
            }
            return v2MarkdownVisible(params: params)
        case "markdown.theme": return v2MarkdownTheme(params: params)
        case "markdown.typeface": return v2MarkdownTypeface(params: params)
        case "markdown.font": return v2MarkdownFont(params: params)
        case "markdown.open_external": return v2MarkdownOpenExternal(params: params)
        default: return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
    }

    private nonisolated func v2MarkdownPanelTarget(
        params: [String: Any]
    ) -> (target: MarkdownPanelTarget?, error: V2CallResult?) {
        guard let panelRef = params["surface_id"] as? String else {
            return (nil, .err(code: "invalid_params", message: "Missing 'panel_id' parameter", data: ["field": "panel_id"]))
        }
        guard !panelRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, .err(code: "invalid_params", message: "'panel_id' must not be empty", data: ["field": "panel_id"]))
        }

        guard let resolved = v2BrowserMainHop({ () -> (target: MarkdownPanelTarget?, error: V2CallResult?) in
            self.v2RefreshKnownRefs()
            if let rejection = self.v2RejectUnresolvedTargetRefs(
                params,
                fallbackWorkspaceManager: self.v2ResolveWorkspaceManager(params: params)
            ) {
                return (target: nil, error: rejection)
            }
            guard let (workspace, surfaceId) = self.v2ResolveWorkspaceSurface(params: params) else {
                return (target: nil, error: V2CallResult.err(
                    code: "not_found", message: "Panel not found", data: ["panel_id": panelRef]
                ))
            }
            guard let panel = workspace.panels[surfaceId] as? MarkdownPanel else {
                if workspace.panels[surfaceId] == nil {
                    return (target: nil, error: V2CallResult.err(
                        code: "not_found", message: "Panel not found", data: ["panel_id": panelRef]
                    ))
                }
                return (target: nil, error: V2CallResult.err(
                    code: "invalid_params", message: "Panel is not a markdown panel", data: ["panel_id": panelRef]
                ))
            }
            return (target: MarkdownPanelTarget(workspace: workspace, panel: panel, surfaceId: surfaceId), error: nil)
        }) else {
            return (nil, v2BrowserMainHopTimeoutResult())
        }
        return resolved
    }

    private nonisolated func v2MarkdownWebCall(
        target: MarkdownPanelTarget,
        method: String,
        arguments: [Any] = [],
        timeout: TimeInterval = 8
    ) -> Result<Any, Error>? {
        guard let renderer = v2BrowserMainHop({ () -> MarkdownWebRenderer in
            let renderer = target.panel.ensureRenderer()
            renderer.beginAgentQuery()
            return renderer
        }) else { return nil }
        defer { _ = v2BrowserMainHop { renderer.endAgentQuery() } }
        let gate = MarkdownWebCallGate()
        let result: Result<Any, Error>? = v2AwaitCallback(timeout: timeout) { finish in
            Task { @MainActor in
                guard gate.begin() else { return }
                let waiter = renderer.whenReadyAndRendered { ready in
                    guard gate.begin() else { return }
                    guard ready else {
                        guard gate.complete() else { return }
                        finish(.failure(URLError(.resourceUnavailable)))
                        return
                    }
                    renderer.call(method, arguments: arguments) { value in
                        if method == "visible", case .success(let visible) = value,
                           let state = visible as? [String: Any] {
                            renderer.publishObservedState(state)
                        }
                        guard gate.complete() else { return }
                        finish(value)
                    }
                }
                if let waiter, !gate.installReadinessWaiter(waiter) {
                    renderer.cancelReadyAndRenderedWait(waiter)
                }
            }
        }
        if case .none = result, let waiter = gate.cancel() {
            _ = v2BrowserMainHop { renderer.cancelReadyAndRenderedWait(waiter) }
        }
        return result
    }

    /// A hidden WKWebView can finish the scroll command while WebKit suspends
    /// its animation-frame state publisher. Query the settled state directly
    /// so a markdown.visible --watch stream sees this command-driven change.
    private nonisolated func v2MarkdownPublishVisibleState(target: MarkdownPanelTarget) {
        _ = v2BrowserMainHop {
            guard let renderer = target.panel.renderer, renderer.isReadyForQueries else { return }
            renderer.beginAgentQuery()
            renderer.call("visible") { result in
                if case .success(let value) = result,
                   let state = value as? [String: Any] {
                    renderer.publishObservedState(state)
                }
                renderer.endAgentQuery()
            }
        }
    }

    private nonisolated func v2MarkdownScroll(params: [String: Any]) -> V2CallResult {
        guard let heading = v2String(params, "heading"), !heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'heading' parameter", data: ["field": "heading"])
        }
        guard heading.utf8.count <= 16 * 1024 else {
            return .err(code: "invalid_params", message: "Heading exceeds 16384 UTF-8 bytes", data: ["field": "heading"])
        }
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else { return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil) }
        guard let result = v2MarkdownWebCall(target: target, method: "scrollToHeading", arguments: [heading]) else {
            return .err(code: "not_ready", message: "Markdown renderer is not ready", data: ["panel_id": target.surfaceId.uuidString])
        }
        switch result {
        case .failure(let error):
            return .err(code: "request_failed", message: error.localizedDescription, data: nil)
        case .success(let value):
            guard let response = value as? [String: Any] else {
                return .err(code: "internal_error", message: "Markdown renderer returned an invalid scroll result", data: nil)
            }
            guard response["ok"] as? Bool == true else {
                if response["ambiguous"] as? Bool == true {
                    return .err(
                        code: "ambiguous",
                        message: "Markdown heading match is ambiguous",
                        data: [
                            "heading": heading,
                            "matches": response["matches"] ?? [],
                            "total": response["total"] ?? 0
                        ]
                    )
                }
                return .err(code: "not_found", message: "Markdown heading not found", data: ["heading": heading])
            }
            v2MarkdownPublishVisibleState(target: target)
            return .ok([
                "panel_id": target.surfaceId.uuidString,
                "scrolled": true,
                "heading": response["heading"] ?? NSNull()
            ])
        }
    }

    private nonisolated func v2MarkdownNavigate(params: [String: Any]) -> V2CallResult {
        guard let rawPath = v2String(params, "path"), !rawPath.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: ["field": "path"])
        }
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let path = NSString(string: expanded).standardizingPath
        guard path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil else {
            return .err(code: "invalid_params", message: "Path must be absolute", data: ["path": path])
        }
        let fragment = params["fragment"] as? String
        guard (fragment?.utf8.count ?? 0) <= 4096,
              params["fragment"] == nil || params["fragment"] is NSNull || fragment != nil else {
            return .err(code: "invalid_params", message: "Fragment exceeds 4096 UTF-8 bytes", data: ["field": "fragment"])
        }
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else {
            return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil)
        }
        let url = URL(fileURLWithPath: path)
        let response: V2CallResult? = v2AwaitCallback(timeout: 20) { finish in
            Task { @MainActor in
                let outcome = await target.panel.navigate(to: url, fragment: fragment, origin: .agentCLI)
                let data: [String: Any] = [
                    "panel_id": target.surfaceId.uuidString,
                    "path": target.panel.filePath ?? path,
                    "fragment": fragment as Any? ?? NSNull(),
                    "outcome": outcome.rawValue
                ]
                switch outcome {
                case .navigated, .unchanged:
                    finish(.ok(data))
                case .invalidTarget:
                    finish(.err(code: "invalid_params", message: "Markdown navigation target is invalid", data: data))
                case .notFound:
                    finish(.err(code: "not_found", message: "Markdown navigation target was not found", data: data))
                case .notReadable:
                    finish(.err(code: "permission_denied", message: "Markdown navigation target is not readable", data: data))
                case .outsideScope:
                    finish(.err(code: "permission_denied", message: "Markdown navigation target is outside its allowed scope", data: data))
                case .superseded:
                    finish(.err(code: "superseded", message: "A newer markdown navigation replaced this request", data: data))
                case .panelClosed:
                    finish(.err(code: "not_found", message: "Markdown panel closed during navigation", data: data))
                }
            }
        }
        return response ?? .err(code: "timeout", message: "Timed out navigating the markdown panel", data: ["panel_id": target.surfaceId.uuidString])
    }

    private nonisolated func v2MarkdownHistory(params: [String: Any]) -> V2CallResult {
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else {
            return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil)
        }
        guard let state = v2BrowserMainHop({
            (target.panel.filePath, target.panel.navigationHistory.jsonSnapshot())
        }) else {
            return v2BrowserMainHopTimeoutResult()
        }
        return .ok([
            "panel_id": target.surfaceId.uuidString,
            "path": state.0 as Any? ?? NSNull(),
            "history": state.1
        ])
    }

    private nonisolated func v2MarkdownLinks(params: [String: Any]) -> V2CallResult {
        guard v2Bool(params, "broken") == true else {
            return .err(code: "invalid_params", message: "markdown.links requires broken=true", data: ["field": "broken"])
        }
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else {
            return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil)
        }
        guard let boundPath = v2BrowserMainHop({ target.panel.filePath }) else {
            return v2BrowserMainHopTimeoutResult()
        }
        guard let sourcePath = boundPath else {
            return .err(code: "unavailable", message: "Markdown panel has no bound file", data: ["panel_id": target.surfaceId.uuidString])
        }
        guard let response = v2MarkdownWebCall(target: target, method: "linkIndex") else {
            return .err(code: "not_ready", message: "Markdown renderer is not ready", data: ["panel_id": target.surfaceId.uuidString])
        }
        guard case .success(let value) = response,
              let index = value as? [String: Any] else {
            if case .failure(let error) = response {
                return .err(code: "request_failed", message: error.localizedDescription, data: nil)
            }
            return .err(code: "internal_error", message: "Markdown renderer returned an invalid link index", data: nil)
        }

        let links = (index["links"] as? [[String: Any]] ?? []).prefix(1000)
        let sourceHeadings = index["headings"] as? [[String: Any]] ?? []
        let sourceSlugs = Set(sourceHeadings.compactMap { $0["slug"] as? String })
        let canonicalSourcePath = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL.path
        var brokenReasons: [Int: String] = [:]
        var inspectionPaths: [String] = []
        var inspectionContent: [String: String] = [:]
        var fragmentChecks: [Int: (path: String, fragment: String)] = [:]
        var truncated = (index["links"] as? [[String: Any]] ?? []).count > links.count

        for (offset, link) in links.enumerated() {
            guard let href = link["href"] as? String, href.utf8.count <= 16 * 1024 else {
                brokenReasons[offset] = "invalid_target"
                continue
            }
            switch MarkdownLinkTarget.resolve(href, documentPath: sourcePath) {
            case .anchor:
                guard href.hasPrefix("#"), let fragment = String(href.dropFirst()).removingPercentEncoding,
                      !fragment.isEmpty else {
                    brokenReasons[offset] = "invalid_fragment"
                    continue
                }
                if fragment.hasPrefix("fn-") || fragment.hasPrefix("fnref-") { continue }
                if !sourceSlugs.contains(fragment) { brokenReasons[offset] = "missing_fragment" }
            case .markdown(let url):
                let navigationTarget = MarkdownNavigationTarget(fileURL: url)
                switch MarkdownNavigationPolicy.prepare(
                    navigationTarget,
                    currentFilePath: sourcePath,
                    origin: .documentLink
                ) {
                case .rejected(let outcome):
                    brokenReasons[offset] = outcome.rawValue
                case .ready(let path, let content, _, _):
                    guard let fragment = navigationTarget.fragment else { continue }
                    let canonicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                    if canonicalPath == canonicalSourcePath {
                        if !sourceSlugs.contains(fragment) { brokenReasons[offset] = "missing_fragment" }
                    } else if let content {
                        if content.utf8.count > 1_048_576 || inspectionPaths.count >= 128 {
                            truncated = true
                            continue
                        }
                        if inspectionContent[canonicalPath] == nil {
                            inspectionContent[canonicalPath] = content
                            inspectionPaths.append(canonicalPath)
                        }
                        fragmentChecks[offset] = (canonicalPath, fragment)
                    }
                }
            case .blocked:
                brokenReasons[offset] = "blocked_target"
            case .web, .mailto:
                continue
            }
        }

        if !inspectionPaths.isEmpty {
            let markdown = inspectionPaths.compactMap { inspectionContent[$0] }
            if let inspected = v2MarkdownWebCall(
                target: target,
                method: "inspectMarkdowns",
                arguments: [markdown],
                timeout: 12
            ), case .success(let value) = inspected, let headingsByDocument = value as? [[[String: Any]]] {
                var headingSets: [String: Set<String>] = [:]
                for (path, headings) in zip(inspectionPaths, headingsByDocument) {
                    headingSets[path] = Set(headings.compactMap { $0["slug"] as? String })
                }
                for (linkIndex, check) in fragmentChecks where headingSets[check.path]?.contains(check.fragment) != true {
                    brokenReasons[linkIndex] = "missing_fragment"
                }
            } else {
                truncated = true
            }
        }

        let allLinks = index["links"] as? [[String: Any]] ?? []
        let broken = brokenReasons.keys.sorted().compactMap { linkIndex -> [String: Any]? in
            guard links.indices.contains(linkIndex) else { return nil }
            var entry = links[linkIndex]
            entry["broken"] = true
            entry["reason"] = brokenReasons[linkIndex]
            return entry
        }
        return .ok([
            "panel_id": target.surfaceId.uuidString,
            "path": sourcePath,
            "links": broken,
            "broken": broken,
            "total": allLinks.count,
            "truncated": truncated
        ])
    }

    private nonisolated func v2MarkdownVisible(params: [String: Any]) -> V2CallResult {
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else { return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil) }
        guard let result = v2MarkdownWebCall(target: target, method: "visible") else {
            return .err(code: "not_ready", message: "Markdown renderer is not ready", data: ["panel_id": target.surfaceId.uuidString])
        }
        switch result {
        case .failure(let error):
            return .err(code: "request_failed", message: error.localizedDescription, data: nil)
        case .success(let value):
            guard let state = value as? [String: Any] else {
                return .err(code: "internal_error", message: "Markdown renderer returned an invalid visible state", data: nil)
            }
            return .ok(MarkdownVisibleStateBuffer.snapshotForResponse(state))
        }
    }

    private nonisolated func v2MarkdownTheme(params: [String: Any]) -> V2CallResult {
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else { return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil) }
        let action = v2String(params, "action") ?? ""
        if action == "list" {
            guard let current = v2BrowserMainHop({ target.panel.theme }) else { return v2BrowserMainHopTimeoutResult() }
            return .ok(["themes": MarkdownPresentation.themeNames, "current": current])
        }
        guard action == "set", let name = v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Use action 'list' or 'set' with a theme name", data: nil)
        }
        guard MarkdownPresentation.themeNames.contains(name) else {
            return .err(code: "invalid_params", message: "Unknown markdown theme: \(name)", data: ["theme": name, "allowed": MarkdownPresentation.themeNames])
        }
        guard let applied = v2BrowserMainHop({ target.panel.setTheme(name) }) else { return v2BrowserMainHopTimeoutResult() }
        guard applied else { return .err(code: "invalid_params", message: "Unknown markdown theme: \(name)", data: ["theme": name]) }
        return .ok(["panel_id": target.surfaceId.uuidString, "theme": name, "applied": true])
    }

    private nonisolated func v2MarkdownTypeface(params: [String: Any]) -> V2CallResult {
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else { return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil) }
        let action = v2String(params, "action") ?? ""
        if action == "list" {
            guard let current = v2BrowserMainHop({ target.panel.typeface }) else { return v2BrowserMainHopTimeoutResult() }
            return .ok(["typefaces": MarkdownPresentation.typefaceNames, "current": current])
        }
        guard action == "set", let name = v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Use action 'list' or 'set' with a typeface name", data: nil)
        }
        guard MarkdownPresentation.typefaceNames.contains(name) else {
            return .err(code: "invalid_params", message: "Unknown markdown typeface: \(name)", data: ["typeface": name, "allowed": MarkdownPresentation.typefaceNames])
        }
        guard let applied = v2BrowserMainHop({ target.panel.setTypeface(name) }) else { return v2BrowserMainHopTimeoutResult() }
        guard applied else { return .err(code: "invalid_params", message: "Unknown markdown typeface: \(name)", data: ["typeface": name]) }
        return .ok(["panel_id": target.surfaceId.uuidString, "typeface": name, "applied": true])
    }

    private nonisolated func v2MarkdownFont(params: [String: Any]) -> V2CallResult {
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else { return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil) }
        guard let number = params["scale"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return .err(code: "invalid_params", message: "Missing numeric 'scale' parameter", data: ["field": "scale"])
        }
        let scale = number.doubleValue
        guard scale.isFinite, MarkdownPresentation.fontScaleRange.contains(scale) else {
            let scaleValue: Any = scale.isFinite ? NSNumber(value: scale) : String(describing: scale)
            return .err(code: "invalid_params", message: "Markdown font scale must be between 0.5 and 3.0", data: ["scale": scaleValue])
        }
        guard let result = v2BrowserMainHop({ () -> V2CallResult in
            guard target.panel.setFontScale(scale) else {
                return .err(code: "internal_error", message: "Could not update markdown font scale", data: nil)
            }
            return .ok(["panel_id": target.surfaceId.uuidString, "font_scale": target.panel.fontScale, "applied": true])
        }) else { return v2BrowserMainHopTimeoutResult() }
        return result
    }

    private nonisolated func v2MarkdownOpenExternal(params: [String: Any]) -> V2CallResult {
        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else { return resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil) }
        enum FileCheck {
            case unbound
            case unavailable(String)
            case ready(String)
        }
        guard let file = v2BrowserMainHop({ () -> FileCheck in
            guard let path = target.panel.filePath else {
                return .unbound
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else { return .unavailable(path) }
            return .ready(path)
        }) else { return v2BrowserMainHopTimeoutResult() }
        let path: String
        switch file {
        case .unbound:
            return .err(code: "unavailable", message: "Markdown panel has no bound file", data: ["panel_id": target.surfaceId.uuidString])
        case .unavailable(let unavailablePath):
            return .err(code: "unavailable", message: "Markdown file is unavailable or unreadable", data: ["path": unavailablePath])
        case .ready(let readyPath):
            path = readyPath
        }

        let opened: V2CallResult? = v2AwaitCallback(timeout: 8) { finish in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.open(URL(fileURLWithPath: path), configuration: configuration) { _, error in
                    if let error {
                        finish(.err(code: "request_failed", message: error.localizedDescription, data: ["path": path]))
                    } else {
                        finish(.ok(["panel_id": target.surfaceId.uuidString, "path": path, "opened": true]))
                    }
                }
            }
        }
        return opened ?? .err(code: "timeout", message: "Timed out opening markdown file externally", data: ["path": path])
    }

    /// The socket connection owns each streamed write. The read dispatch
    /// source only watches for peer closure; it never performs WebKit work.
    nonisolated func v2StreamMarkdownVisible(
        id: Any?,
        params: [String: Any],
        socket: Int32,
        shouldContinue: () -> Bool
    ) {
        let buffer = MarkdownVisibleStateBuffer()
        var watch: MarkdownVisibleWatch?
        let cancelled = DispatchSemaphore(value: 0)
        let disconnect = DispatchSource.makeReadSource(
            fileDescriptor: socket,
            queue: DispatchQueue(label: "com.stage11.c11.markdown-visible-watch-disconnect")
        )
        disconnect.setEventHandler {
            var byte: UInt8 = 0
            let count = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 || count > 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                buffer.finish()
            }
        }
        disconnect.setCancelHandler { cancelled.signal() }
        disconnect.resume()
        defer {
            disconnect.cancel()
            cancelled.wait()
            buffer.finish()
            if let watch { _ = v2BrowserMainHop { watch.stop() } }
        }

        guard CapabilityFeatures.current.supports(.markdownAgentCLI) else {
            _ = Self.writeSocketResponse(v2Result(id: id, .err(
                code: "unsupported", message: "Markdown agent commands are disabled",
                data: ["feature": CapabilityFeatures.ID.markdownAgentCLI.rawValue]
            )), to: socket)
            return
        }

        let resolved = v2MarkdownPanelTarget(params: params)
        guard let target = resolved.target else {
            _ = Self.writeSocketResponse(v2Result(id: id, resolved.error ?? .err(code: "not_found", message: "Panel not found", data: nil)), to: socket)
            return
        }

        guard let subscription = v2BrowserMainHop({ () -> MarkdownVisibleWatch in
            let subscription = MarkdownVisibleWatch(panel: target.panel, buffer: buffer)
            subscription.start()
            return subscription
        }) else {
            _ = Self.writeSocketResponse(v2Result(id: id, v2BrowserMainHopTimeoutResult()), to: socket)
            return
        }
        watch = subscription

        switch buffer.waitForInitialState(timeout: 8, shouldContinue: shouldContinue) {
        case .ready:
            break
        case .timedOut:
            _ = Self.writeSocketResponse(v2Result(id: id, .err(
                code: "timeout", message: "Timed out waiting for the markdown reader's initial state",
                data: ["panel_id": target.surfaceId.uuidString]
            )), to: socket)
            return
        case .finished:
            if shouldContinue() {
                _ = Self.writeSocketResponse(v2Result(id: id, .err(
                    code: "not_ready", message: "Markdown panel closed before its reader became ready",
                    data: ["panel_id": target.surfaceId.uuidString]
                )), to: socket)
            }
            return
        }

        while shouldContinue() {
            guard let state = buffer.next(timeout: 0.5) else {
                if buffer.isFinished { return }
                continue
            }
            let wrote = autoreleasepool {
                Self.writeSocketResponse(v2Result(id: id, .ok(state)), to: socket)
            }
            guard wrote else { return }
        }
    }

    private func v2FeedbackOpen(params: [String: Any]) -> V2CallResult {
        let workspaceId = v2UUID(params, "workspace_id")
        let windowId = v2UUID(params, "window_id")
        let shouldActivate = v2Bool(params, "activate") ?? false
        DispatchQueue.main.async {
            let targetWindow: NSWindow?
            if let windowId, let app = AppDelegate.shared {
                targetWindow = app.mainWindow(for: windowId)
            } else if let workspaceId, let app = AppDelegate.shared {
                targetWindow = app.mainWindowContainingWorkspace(workspaceId)
            } else {
                targetWindow = nil
            }

            if shouldActivate {
                if let targetWindow {
                    targetWindow.makeKeyAndOrderFront(nil)
                    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                } else {
                    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
            }

            FeedbackComposerBridge.openComposer(in: targetWindow)
        }
        return .ok(["opened": true])
    }

    // C11-165 COR-3: `feedback.submit` blocks the caller on a 35s semaphore
    // whose signaling `Task` (previously inheriting `@MainActor` from the
    // enclosing main-actor method) could never start while the caller ran on
    // main — the June audit's "always freezes main ~35s then fails". Marking
    // this `nonisolated` and dispatching it on the socket worker (see
    // TerminalController.socketWorkerV2Methods) means the `Task` runs on the
    // global executor and the `semaphore.wait` blocks the worker thread, not
    // main. FeedbackComposerBridge.submit is `static async` (not main-actor),
    // so nothing here needs a main hop.
    nonisolated func v2FeedbackSubmit(params: [String: Any]) -> V2CallResult {
        guard let email = params["email"] as? String else {
            return .err(code: "invalid_params", message: "Missing email", data: ["field": "email"])
        }
        guard let body = params["body"] as? String else {
            return .err(code: "invalid_params", message: "Missing body", data: ["field": "body"])
        }
        let imagePaths = params["image_paths"] as? [String] ?? []

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult = .err(code: "internal_error", message: "Feedback submission failed", data: nil)

        Task {
            let resolved: V2CallResult
            do {
                let attachmentCount = try await FeedbackComposerBridge.submit(
                    email: email,
                    message: body,
                    imagePaths: imagePaths
                )
                resolved = .ok([
                    "submitted": true,
                    "attachment_count": attachmentCount,
                ])
            } catch let error as FeedbackComposerBridgeError {
                let code: String
                switch error {
                case .invalidEmail, .emptyMessage, .messageTooLong, .tooManyImages, .invalidImagePath:
                    code = "invalid_params"
                case .submissionFailed:
                    code = "request_failed"
                }
                resolved = .err(code: code, message: error.localizedDescription, data: nil)
            } catch {
                resolved = .err(code: "internal_error", message: error.localizedDescription, data: nil)
            }

            result = resolved
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return .err(code: "timeout", message: "Feedback submission timed out", data: nil)
        }

        return result
    }

    private func v2MarkdownOpen(params: [String: Any]) -> V2CallResult {
        let rejection: V2CallResult? = v2MainSync {
            v2RefreshKnownRefs()
            return v2RejectUnresolvedTargetRefs(
                params,
                fallbackWorkspaceManager: v2ResolveWorkspaceManager(params: params)
            )
        }
        if let rejection { return rejection }
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }
        let fragment = params["fragment"] as? String
        guard (fragment?.utf8.count ?? 0) <= 4096,
              params["fragment"] == nil || params["fragment"] is NSNull || fragment != nil else {
            return .err(code: "invalid_params", message: "Invalid markdown fragment", data: ["field": "fragment"])
        }

        // Resolve the path (expand ~ and standardize)
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let filePath = NSString(string: expandedPath).standardizingPath

        // Reject paths that aren't absolute after resolution
        guard filePath.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "Path must be absolute: \(filePath)", data: ["path": filePath])
        }

        // Validate the file exists and is a regular file (not a directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return .err(code: "not_found", message: "File not found: \(filePath)", data: ["path": filePath])
        }
        guard !isDir.boolValue else {
            return .err(code: "invalid_params", message: "Path is a directory, not a file: \(filePath)", data: ["path": filePath])
        }
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return .err(code: "permission_denied", message: "File not readable: \(filePath)", data: ["path": filePath])
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
        v2MainSync {
            // M6 — if pane_id is supplied, locate the owning workspace across all
            // windows so `markdown.open --pane P` works standalone (spec: --pane
            // uniquely identifies). This takes precedence over workspace_id/window_id
            // (which may be injected from env vars by the CLI).
            var resolvedWorkspaceManager: WorkspaceManager = workspaceManager
            var resolvedWorkspace: Workspace?
            if v2HasNonNullParam(params, "pane_id") {
                guard let paneUUID = v2UUID(params, "pane_id") else {
                    result = .err(code: "invalid_params", message: "Invalid area_id", data: nil)
                    return
                }
                if let located = AppDelegate.shared?.locatePane(paneId: paneUUID) {
                    resolvedWorkspace = located.workspace
                    resolvedWorkspaceManager = located.workspaceManager
                }
            }
            guard let ws = resolvedWorkspace ?? v2ResolveWorkspace(params: params, workspaceManager: resolvedWorkspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: resolvedWorkspaceManager)
            v2MaybeSelectWorkspace(resolvedWorkspaceManager, workspace: ws)

            // M6 — if pane_id is supplied, open as a tab inside that pane (no split).
            if v2HasNonNullParam(params, "pane_id") {
                guard let paneUUID = v2UUID(params, "pane_id") else {
                    result = .err(code: "invalid_params", message: "Invalid area_id", data: nil)
                    return
                }
                guard let targetPaneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                    result = .err(code: "not_found", message: "Area not found in workspace", data: ["pane_id": paneUUID.uuidString])
                    return
                }

                let createdPanel = ws.newMarkdownPanel(
                    inPane: targetPaneId,
                    filePath: filePath,
                    fragment: fragment,
                    focus: v2FocusAllowed()
                )

                guard let markdownPanelId = createdPanel?.id else {
                    result = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
                    return
                }

                let windowId = v2ResolveWindowId(workspaceManager: resolvedWorkspaceManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": targetPaneId.id.uuidString,
                    "pane_ref": v2Ref(kind: .pane, uuid: targetPaneId.id),
                    "surface_id": markdownPanelId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: markdownPanelId),
                    "target_pane_id": targetPaneId.id.uuidString,
                    "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneId.id),
                    "path": filePath
                ])
                return
            }

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused panel to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source panel not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            let createdPanel = ws.newMarkdownSplit(
                from: sourceSurfaceId,
                orientation: .horizontal,
                filePath: filePath,
                fragment: fragment,
                focus: v2FocusAllowed()
            )

            guard let markdownPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: markdownPanelId)?.id
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": markdownPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: markdownPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "path": filePath
            ])
        }
        return result
    }

    private func v2MarkdownGetContent(params: [String: Any]) -> V2CallResult {
        let rejection: V2CallResult? = v2MainSync {
            v2RefreshKnownRefs()
            return v2RejectUnresolvedTargetRefs(
                params,
                fallbackWorkspaceManager: v2ResolveWorkspaceManager(params: params)
            )
        }
        if let rejection { return rejection }
        guard let resolved = v2ResolveWorkspaceSurface(params: params) else {
            return .err(code: "not_found", message: "Panel not found", data: nil)
        }
        let (ws, surfaceId) = resolved

        var payload: [String: Any]?
        var errResult: V2CallResult?
        v2MainSync {
            guard let panel = ws.panels[surfaceId] else {
                errResult = .err(code: "not_found", message: "Panel not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let markdown = panel as? MarkdownPanel else {
                errResult = .err(code: "invalid_params", message: "Panel is not a markdown panel", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let content = markdown.content
            let contentBytes = content.data(using: .utf8) ?? Data()
            let sha = SHA256.hash(data: contentBytes).map { String(format: "%02x", $0) }.joined()
            let softCap = 256 * 1024

            var out: [String: Any] = [
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "type": PanelType.markdown.rawValue,
                "file_path": markdown.filePath,
                "content_length": contentBytes.count,
                "content_sha256": sha,
                "is_file_unavailable": markdown.isFileUnavailable
            ]
            if contentBytes.count > softCap {
                out["truncated"] = true
                out["reason"] = "content_too_large"
            } else {
                out["content"] = content
            }
            payload = out
        }
        if let errResult { return errResult }
        guard let out = payload else {
            return .err(code: "not_found", message: "Panel not found", data: nil)
        }
        return .ok(out)
    }
}
