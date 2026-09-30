import AppKit
import Foundation

// C11-240 phase 2: socket surface for the New Workspace picker's recents and
// pins. It shares the picker's model (`CreateWorkspaceRecents`), ranking
// (`RecentsFuzzy` via `RecentsQueryResolver`) and creation pipeline
// (`AppDelegate.applyWorkspacePlanInPreferredMainWindow`), so an agent and the
// sheet always agree. An open sheet reloads on `didChangeNotification`.
extension TerminalController {
    func v2DispatchWorkspaceRecents(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "workspace.recents.list":
            return v2Result(id: id, v2RecentsList(params: params))
        case "workspace.recents.pin":
            return v2Result(id: id, v2RecentsPin(params: params, pin: true))
        case "workspace.recents.unpin":
            return v2Result(id: id, v2RecentsPin(params: params, pin: false))
        case "workspace.recents.remove":
            return v2Result(id: id, v2RecentsRemove(params: params))
        case "workspace.recents.resolve":
            return v2Result(id: id, v2RecentsResolve(params: params))
        case "workspace.create_in_directory":
            return v2Result(id: id, v2WorkspaceCreateInDirectory(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    // MARK: Shared helpers

    private func v2RecentsState() -> Result<CreateWorkspaceRecents.State, V2CallResult> {
        switch CreateWorkspaceRecents.loadOutcome() {
        case .ok(let state):
            return .success(state)
        case .unreadable:
            return .failure(.err(
                code: "recents_unreadable",
                message: "Saved recents could not be decoded; nothing was changed.",
                data: nil
            ))
        }
    }

    /// Stat many paths through a bounded pool with one shared deadline, so a
    /// hung network mount cannot stall the socket. Paths that do not answer in
    /// time are absent from the result.
    private func v2StatDirectories(_ paths: [String], deadline: TimeInterval = 2.0) -> [String: Bool] {
        DirectoryProbe().statAll(paths, deadline: deadline)
    }

    private func v2OpenRoots() -> Set<String> {
        v2MainSync {
            MainActor.assumeIsolated { AppDelegate.shared?.openWorkspaceRootDirectories() ?? [] }
        }
    }

    /// A `path` param is an explicit path or a fuzzy query resolved with the
    /// picker's ranking. Ties fail loudly with the candidates.
    private func v2RecentsResolveQuery(
        _ raw: String,
        entries: [RecentDirectory],
        cwd: String?
    ) -> Result<String, V2CallResult> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch RecentsQueryResolver.resolve(query: raw, entries: entries, home: home, cwd: cwd ?? home) {
        case .path(let p), .match(let p):
            return .success(p)
        case .ambiguous(let candidates):
            return .failure(.err(
                code: "ambiguous",
                message: "'\(raw)' matches several recents equally: " + candidates.joined(separator: ", "),
                data: ["candidates": candidates]
            ))
        case .none:
            return .failure(.err(code: "not_found", message: "No recent directory matches '\(raw)'", data: nil))
        }
    }

    private func v2RecentPayload(
        _ entry: RecentDirectory,
        pins: [String],
        open: Set<String>,
        exists: Bool?
    ) -> [String: Any] {
        let pinIndex = pins.firstIndex(of: entry.path)
        return [
            "path": entry.path,
            "name": entry.displayName,
            "last_opened_at": ISO8601DateFormatter().string(from: entry.lastOpenedAt),
            "open_count": entry.openCount,
            "pinned": pinIndex != nil,
            "pin_index": v2OrNull(pinIndex.map { $0 + 1 }),
            "open": open.contains(RecentsPath.normalize(entry.path)),
            "exists": v2OrNull(exists),
        ]
    }

    // MARK: workspace.recents.*

    /// `workspace.recents.list` {pinned?: bool}. Newest first, or pin order
    /// when `pinned` is true. `pin_index` is 1-based, the number on the ⌘N badge.
    private func v2RecentsList(params: [String: Any]) -> V2CallResult {
        let state: CreateWorkspaceRecents.State
        switch v2RecentsState() {
        case .success(let s): state = s
        case .failure(let err): return err
        }
        let pinnedOnly = (params["pinned"] as? Bool) ?? false
        let ordered: [RecentDirectory]
        if pinnedOnly {
            ordered = state.pins.compactMap { p in state.entries.first(where: { $0.path == p }) }
        } else {
            ordered = RecentsOrdering.sorted(state.entries, by: .recent)
        }
        let exists = v2StatDirectories(ordered.map(\.path))
        let open = v2OpenRoots()
        return .ok([
            "recents": ordered.map { v2RecentPayload($0, pins: state.pins, open: open, exists: exists[$0.path]) },
            "count": ordered.count,
            "total": state.entries.count,
        ])
    }

    /// `workspace.recents.pin` {path, at?: 1-based} / `workspace.recents.unpin` {path}.
    private func v2RecentsPin(params: [String: Any], pin: Bool) -> V2CallResult {
        guard let raw = params["path"] as? String, !raw.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'path'", data: nil)
        }
        let state: CreateWorkspaceRecents.State
        switch v2RecentsState() {
        case .success(let s): state = s
        case .failure(let err): return err
        }
        let path: String
        switch v2RecentsResolveQuery(raw, entries: state.entries, cwd: params["cwd"] as? String) {
        case .success(let p): path = p
        case .failure(let err): return err
        }
        guard state.entries.contains(where: { $0.path == path }) else {
            return .err(code: "not_found", message: "'\(path)' is not in recents", data: nil)
        }
        let at = (params["at"] as? Int).map { max(1, $0) - 1 }
        if pin && params["at"] != nil && at == nil {
            return .err(code: "invalid_params", message: "'at' must be an integer >= 1", data: nil)
        }
        CreateWorkspaceRecents.mutate { s in
            if pin { s.pin(path, at: at) } else { s.unpin(path) }
        }
        let after = CreateWorkspaceRecents.loadState()
        let idx = after.pins.firstIndex(of: path)
        return .ok([
            "path": path,
            "pinned": idx != nil,
            "pin_index": v2OrNull(idx.map { $0 + 1 }),
            "pins": after.pins,
        ])
    }

    /// `workspace.recents.remove` {path}: drops the entry and its pin.
    private func v2RecentsRemove(params: [String: Any]) -> V2CallResult {
        guard let raw = params["path"] as? String, !raw.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'path'", data: nil)
        }
        let state: CreateWorkspaceRecents.State
        switch v2RecentsState() {
        case .success(let s): state = s
        case .failure(let err): return err
        }
        let path: String
        switch v2RecentsResolveQuery(raw, entries: state.entries, cwd: params["cwd"] as? String) {
        case .success(let p): path = p
        case .failure(let err): return err
        }
        guard state.entries.contains(where: { $0.path == path }) else {
            return .err(code: "not_found", message: "'\(path)' is not in recents", data: nil)
        }
        CreateWorkspaceRecents.mutate { $0.remove(path) }
        return .ok(["path": path, "removed": true])
    }

    /// `workspace.recents.resolve` {query, cwd?}: what `workspace new --dir`
    /// would open, without opening it.
    private func v2RecentsResolve(params: [String: Any]) -> V2CallResult {
        guard let raw = params["query"] as? String, !raw.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'query'", data: nil)
        }
        let state: CreateWorkspaceRecents.State
        switch v2RecentsState() {
        case .success(let s): state = s
        case .failure(let err): return err
        }
        switch v2RecentsResolveQuery(raw, entries: state.entries, cwd: params["cwd"] as? String) {
        case .failure(let err):
            return err
        case .success(let path):
            let exists = v2StatDirectories([path])[path]
            return .ok([
                "path": path,
                "recent": state.entries.contains(where: { $0.path == path }),
                "exists": v2OrNull(exists),
            ])
        }
    }

    // MARK: workspace.create_in_directory

    private static let starterLayoutFiles: [String: String] = [
        "starter:one-column": "basic-terminal", "one-column": "basic-terminal", "single": "basic-terminal",
        "starter:two-columns": "side-by-side", "two-columns": "side-by-side",
        "starter:quad": "quad-terminal", "quad": "quad-terminal",
        "starter:two-by-three": "two-by-three", "two-by-three": "two-by-three",
    ]

    /// A blueprint id (`starter:quad`, `saved:<url>`), starter short name,
    /// blueprint name, or file path.
    private func v2LayoutPlan(_ layout: String?, directory: String) -> Result<WorkspaceApplyPlan, V2CallResult> {
        let store = WorkspaceBlueprintStore()
        let index = store.merged(cwd: URL(fileURLWithPath: directory))
        let wanted = (layout?.isEmpty == false ? layout : nil)
            ?? CreateWorkspaceLastLayout.load()
            ?? "starter:one-column"
        var match: WorkspaceBlueprintIndex?
        if wanted.hasPrefix("saved:") {
            let url = String(wanted.dropFirst("saved:".count))
            match = index.first(where: { $0.url == url })
        } else {
            let name = Self.starterLayoutFiles[wanted] ?? wanted
            match = index.first(where: { $0.name == name })
        }
        do {
            if let match {
                return .success(try store.read(url: URL(fileURLWithPath: match.url)).plan)
            }
            let path = (wanted as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                return .success(try store.read(url: URL(fileURLWithPath: path)).plan)
            }
        } catch {
            return .failure(.err(code: "layout_unreadable", message: "Could not load layout '\(wanted)': \(error)", data: nil))
        }
        return .failure(.err(
            code: "layout_not_found",
            message: "No layout '\(wanted)'. Try a starter (quad, two-columns, two-by-three, one-column) or a blueprint name.",
            data: ["known": index.map(\.name)]
        ))
    }

    /// `workspace.create_in_directory` {dir, layout?, name?, launch_agent?}.
    /// `dir` is a path or a fuzzy query over recents, ranked like the picker.
    /// Creates through the picker's own pipeline, so the open is recorded in
    /// recents exactly as a sheet creation is.
    private func v2WorkspaceCreateInDirectory(params: [String: Any]) -> V2CallResult {
        guard let raw = params["dir"] as? String, !raw.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'dir'", data: nil)
        }
        let state: CreateWorkspaceRecents.State
        switch v2RecentsState() {
        case .success(let s): state = s
        case .failure(let err): return err
        }
        let cwd = params["cwd"] as? String
        var resolved: String?
        // A real subdirectory of the caller's directory beats a fuzzy guess.
        if let candidate = RecentsQueryResolver.cwdCandidate(query: raw, cwd: cwd ?? ""),
           v2StatDirectories([candidate])[candidate] == true {
            resolved = candidate
        }
        let path: String
        if let resolved {
            path = resolved
        } else {
            switch v2RecentsResolveQuery(raw, entries: state.entries, cwd: cwd) {
            case .success(let p): path = p
            case .failure(let err): return err
            }
        }
        // Path stat is answered in time or the call fails: never create blind.
        guard let exists = v2StatDirectories([path])[path] else {
            return .err(code: "timeout", message: "Could not stat '\(path)' (unresponsive mount?)", data: nil)
        }
        guard exists else {
            return .err(code: "directory_missing", message: "'\(path)' does not exist, so no workspace was created", data: ["path": path])
        }
        let plan: WorkspaceApplyPlan
        switch v2LayoutPlan(params["layout"] as? String, directory: path) {
        case .success(let p): plan = p
        case .failure(let err): return err
        }
        let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let launchAgent = (params["launch_agent"] as? Bool) ?? false
        let focus = v2FocusAllowed()

        let created: UUID? = v2MainSync {
            MainActor.assumeIsolated {
                AppDelegate.shared?.applyWorkspacePlanInPreferredMainWindow(
                    plan: plan,
                    workingDirectory: path,
                    workspaceName: (name?.isEmpty == false) ? name : RecentsPath.lastComponent(path),
                    launchAgent: launchAgent,
                    debugSource: "socket.workspace.create_in_directory",
                    activate: focus
                )
            }
        }
        guard let created else {
            return .err(code: "create_failed", message: "Workspace creation failed", data: nil)
        }
        return .ok([
            "workspace_id": created.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: created),
            "path": path,
            "title": (name?.isEmpty == false) ? name! : RecentsPath.lastComponent(path),
            "recorded": true,
        ])
    }
}
