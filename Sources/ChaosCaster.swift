import AppKit
import Foundation

// MARK: - Chaos Wizard settings (C11H-199)

enum ChaosSettings {
    /// The folder every cast builds inside. Unset means `~/Chaos`.
    static let rootPathKey = "c11.chaos.rootPath"

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Chaos", isDirectory: true)
    }

    /// Safe off the main thread (a read).
    static func root(defaults: UserDefaults = .standard) -> URL {
        if let raw = defaults.string(forKey: rootPathKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultRoot
    }

    /// Writes go on main (AGENTS.md: UserDefaults writes on main only).
    @MainActor
    static func setRoot(_ url: URL?, defaults: UserDefaults = .standard) {
        if let url { defaults.set(url.path, forKey: rootPathKey) } else { defaults.removeObject(forKey: rootPathKey) }
    }

    /// The deck: `<root>/DECK.md` when present, section by section, else the built-in one.
    static func deck(root: URL = root()) -> ChaosDeck {
        let url = root.appendingPathComponent(ChaosDeck.fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .builtIn }
        return ChaosDeck.parse(markdown: text)
    }

    /// Create `<root>/DECK.md` from the built-in deck when it is missing; return its URL.
    static func ensureDeckFile(root: URL = root()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(ChaosDeck.fileName)
        if !fm.fileExists(atPath: url.path) {
            try ChaosDeck.builtIn.markdown().write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// The workspace and folder color: a wizard's magenta, distinct from the
    /// violet of flags and the yellow of working agents.
    static let colorHex = "#B8327A"
    static let groupName = "Chaos"
    static let groupIcon = "wand.and.stars"
}

// MARK: - Who plays each piece

enum ChaosEnsemble {
    /// The configs for `count` pieces. `.two`, `.four` and `.one` use the default on
    /// every piece. `.ensemble` starts with the default, then takes saved
    /// configs in library order, a new harness each time while one is left,
    /// then any other launchable config, then the default again.
    static func artists(mode: ChaosMode, count: Int, configs: [SavedAgentConfig], defaultConfig: SavedAgentConfig) -> [SavedAgentConfig] {
        guard count > 0 else { return [] }
        guard mode == .ensemble else { return Array(repeating: defaultConfig, count: count) }
        var picked = [defaultConfig]
        let candidates = configs
            .filter { $0.id != defaultConfig.id && !$0.config.isProvablyUnlaunchable }
            .sorted { $0.order < $1.order }
        var harnesses: Set<String> = [defaultConfig.config.harness]
        for c in candidates where picked.count < count && !harnesses.contains(c.config.harness) {
            picked.append(c)
            harnesses.insert(c.config.harness)
        }
        for c in candidates where picked.count < count && !picked.contains(where: { $0.id == c.id }) {
            picked.append(c)
        }
        while picked.count < count { picked.append(defaultConfig) }
        return picked
    }
}

// MARK: - The cast

/// One prepared piece: where it is built, who builds it, what they are told.
struct ChaosCastSlot {
    var index: Int
    var piece: ChaosPiece
    var studio: URL
    var artist: SavedAgentConfig
    var prompt: String
}

/// Everything about a cast before an agent starts.
struct ChaosCastPlan {
    var mode: ChaosMode
    var seed: UInt64
    var root: URL
    var run: URL
    var workspaceTitle: String
    var slots: [ChaosCastSlot]

    func json(includePrompts: Bool) -> [String: Any] {
        [
            "mode": mode.rawValue,
            "seed": String(seed),
            "root": root.path,
            "run": run.path,
            "workspace_title": workspaceTitle,
            "pieces": slots.map { slot -> [String: Any] in
                var item: [String: Any] = [
                    "index": slot.index + 1,
                    "title": slot.piece.premise.title,
                    "premise": slot.piece.premise.text,
                    "medium": slot.piece.medium,
                    "constraint": slot.piece.constraint,
                    "studio": slot.studio.path,
                    "agent": slot.artist.name,
                    "config_id": slot.artist.id,
                    "headline": ChaosPrompt.headline(piece: slot.piece, index: slot.index, artistCount: slots.count),
                ]
                if includePrompts { item["prompt"] = slot.prompt }
                return item
            },
        ]
    }
}

struct ChaosCastError: Error {
    var code: String
    var message: String
}

enum ChaosCaster {
    /// The run folder's name and the workspace title for a cast at `date`, local time.
    static func names(at date: Date, timeZone: TimeZone = .current) -> (folder: String, title: String) {
        let folder = DateFormatter()
        folder.locale = Locale(identifier: "en_US_POSIX")
        folder.timeZone = timeZone
        folder.dateFormat = "yyyy-MM-dd-HHmm"
        let title = DateFormatter()
        title.locale = Locale(identifier: "en_US_POSIX")
        title.timeZone = timeZone
        title.dateFormat = "HH:mm"
        return (folder.string(from: date), "Chaos \(title.string(from: date))")
    }

    /// A fresh draw of `mode.pieceCount` pieces from the current deck.
    static func draw(mode: ChaosMode, seed: UInt64? = nil) -> (seed: UInt64, pieces: [ChaosPiece]) {
        let seed = seed ?? UInt64.random(in: 1...UInt64.max)
        return (seed, ChaosSettings.deck().draw(count: mode.pieceCount, seed: seed))
    }

    /// Plan a cast without touching disk. Off-main safe.
    static func plan(mode: ChaosMode, seed: UInt64, pieces: [ChaosPiece],
                     date: Date = Date(), cli: String = "c11") -> ChaosCastPlan {
        let root = ChaosSettings.root()
        let names = names(at: date)
        var run = root.appendingPathComponent(names.folder, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: run.path) {
            run = root.appendingPathComponent("\(names.folder)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        let store = AgentConfigLibraryStore.shared
        let artists = ChaosEnsemble.artists(mode: mode, count: pieces.count,
                                            configs: store.current.configs, defaultConfig: store.effectiveDefault())
        let slots = pieces.enumerated().map { i, piece -> ChaosCastSlot in
            let studio = run.appendingPathComponent(piece.studioName(index: i), isDirectory: true)
            return ChaosCastSlot(
                index: i, piece: piece, studio: studio, artist: artists[i],
                prompt: ChaosPrompt.compose(piece: piece, studio: studio.path, artistCount: pieces.count, cli: cli)
            )
        }
        return ChaosCastPlan(mode: mode, seed: seed, root: root, run: run, workspaceTitle: names.title,
                             slots: slots)
    }

    /// Create the run and studio folders, the commission files, the gallery
    /// pages and the cast record. Off-main.
    static func prepareFolders(_ plan: ChaosCastPlan, date: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plan.root, withIntermediateDirectories: true)
        // Without intermediates this fails when the folder exists, so two casts
        // in the same minute can never share a run folder.
        try fm.createDirectory(at: plan.run, withIntermediateDirectories: false)
        for slot in plan.slots {
            try fm.createDirectory(at: slot.studio, withIntermediateDirectories: true)
            try slot.prompt.write(to: slot.studio.appendingPathComponent("COMMISSION.md"), atomically: true, encoding: .utf8)
        }
        let entries = plan.slots.map {
            ChaosGallery.Entry(studio: $0.studio.lastPathComponent, piece: $0.piece, agent: $0.artist.name)
        }
        try ChaosGallery.runPage(title: plan.workspaceTitle, entries: entries)
            .write(to: plan.run.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        var record = plan.json(includePrompts: false)
        record["created"] = ISO8601DateFormatter.string(from: date, timeZone: .current,
                                                       formatOptions: [.withInternetDateTime])
        record["status"] = "casting"
        try writeRecord(record, run: plan.run)
    }

    static func writeRecord(_ record: [String: Any], run: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: run.appendingPathComponent("chaos-run.json"), options: .atomic)
    }

    /// The cast's result, once every launch has answered: the run record, the
    /// cast log line and the gallery all say what really happened.
    static func recordOutcome(_ outcome: Outcome, created: Date) {
        var record = outcome.json()
        record["created"] = ISO8601DateFormatter.string(from: created, timeZone: .current,
                                                       formatOptions: [.withInternetDateTime])
        record["status"] = outcome.error == nil ? "cast" : (outcome.launched.isEmpty ? "failed" : "partial")
        try? writeRecord(record, run: outcome.plan.run)
        appendCastLog(root: outcome.plan.root, record: record)
        writeRootGallery(root: outcome.plan.root)
    }

    /// The Chaos root's gallery page. Not `index.html`: the operator may point
    /// the root at a folder that already has one.
    static let galleryFileName = "gallery.html"

    /// Rebuild `<root>/gallery.html` from every run folder's `chaos-run.json`.
    static func writeRootGallery(root: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        var runs: [ChaosGallery.RunSummary] = []
        for name in names.sorted(by: >) {
            let url = root.appendingPathComponent(name).appendingPathComponent("chaos-run.json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["status"] as? String != "failed" else { continue }
            let pieces = (obj["pieces"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            runs.append(.init(folder: name, title: obj["workspace_title"] as? String ?? name, pieces: pieces))
        }
        try? ChaosGallery.rootPage(runs: runs)
            .write(to: root.appendingPathComponent(galleryFileName), atomically: true, encoding: .utf8)
    }

    /// One JSON line per cast in `<root>/casts.jsonl`, for agents diagnosing a run.
    static func appendCastLog(root: URL, record: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        // One O_APPEND write per line, so casts finishing together never overwrite each other.
        let path = root.appendingPathComponent("casts.jsonl").path
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        line.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    struct Launched {
        var index: Int
        var surfaceId: String
        var paneId: String?
    }

    struct Outcome {
        var plan: ChaosCastPlan
        var workspaceId: UUID?
        var launched: [Launched]
        var warnings: [String]
        var error: ChaosCastError?

        func json() -> [String: Any] {
            var out = plan.json(includePrompts: false)
            out["workspace_id"] = workspaceId?.uuidString ?? NSNull()
            out["launched"] = launched.map { ["index": $0.index + 1, "panel_id": $0.surfaceId, "area_id": $0.paneId ?? NSNull()] as [String: Any] }
            out["warnings"] = warnings
            if let error { out["error"] = ["code": error.code, "message": error.message] }
            return out
        }
    }

    /// Where piece `i` goes: piece 1 opens the workspace, then the grid fills
    /// right of 1, below 1, below 2, so four pieces make two columns of two.
    static func placement(index: Int) -> (anchor: Int, split: String)? {
        switch index {
        case 1: return (0, "right")
        case 2: return (0, "down")
        case 3: return (1, "down")
        default: return nil
        }
    }

    /// Launch the plan's agents through `config.launch`'s one mapping onto
    /// `agent.launch`. Must run off main (agent.launch refuses main). The
    /// workspace is titled, colored and filed as soon as piece 1 opens it, so
    /// the operator watches the grid fill in. `select` is for operator
    /// gestures only: the new workspace is selected then, and only while the
    /// window still shows `expectedSelection` (the workspace selected at the click).
    static func cast(_ plan: ChaosCastPlan, controller: TerminalController, windowRef: String?,
                     callerPanelId: String? = nil, select: Bool, expectedSelection: UUID? = nil) -> Outcome {
        let created = Date()
        var outcome = Outcome(plan: plan, workspaceId: nil, launched: [], warnings: [], error: nil)
        guard !Thread.isMainThread else {
            outcome.error = ChaosCastError(code: "internal_error", message: "chaos cast must run off the main thread")
            return outcome
        }
        var plan = plan
        do {
            do {
                try prepareFolders(plan, date: created)
            } catch CocoaError.fileWriteFileExists {
                // Another cast claimed this minute's folder first: plan the next free one.
                plan = Self.plan(mode: plan.mode, seed: plan.seed, pieces: plan.slots.map(\.piece), date: created)
                outcome.plan = plan
                try prepareFolders(plan, date: created)
            }
        } catch {
            outcome.error = ChaosCastError(code: "chaos_folder_failed",
                                           message: "Could not create \(plan.run.path): \(error.localizedDescription)")
            return outcome
        }
        var panes: [Int: String] = [:]
        for slot in plan.slots {
            var params = TerminalController.agentLaunchParams(for: slot.artist, prompt: slot.prompt)
            params["cwd"] = slot.studio.path
            params["title"] = slot.piece.premise.title
            params["prompt_headline"] = ChaosPrompt.headline(piece: slot.piece, index: slot.index,
                                                            artistCount: plan.slots.count)
            params["focus"] = false
            params["source"] = AgentLaunchSource.chaos.rawValue
            if let windowRef { params["window_id"] = windowRef }
            if let callerPanelId { params["caller_surface_id"] = callerPanelId }
            if slot.index == 0 {
                params["new_workspace"] = true
            } else {
                guard let workspaceId = outcome.workspaceId,
                      let place = placement(index: slot.index), let anchorPane = panes[place.anchor] else {
                    outcome.error = ChaosCastError(code: "chaos_layout_failed",
                                                   message: "Piece \(slot.index + 1) has no area to open beside")
                    break
                }
                params["workspace_id"] = workspaceId.uuidString
                params["pane_id"] = anchorPane
                params["split"] = place.split
            }
            switch controller.v2AgentLaunch(params: params) {
            case .ok(let payload):
                let result = payload as? [String: Any] ?? [:]
                let pane = result["pane_id"] as? String
                if let pane { panes[slot.index] = pane }
                outcome.launched.append(Launched(index: slot.index, surfaceId: result["surface_id"] as? String ?? "", paneId: pane))
                outcome.warnings += (result["warnings"] as? [String] ?? []).map { "\(slot.index + 1): \($0)" }
                if slot.index == 0, let ws = (result["workspace_id"] as? String).flatMap(UUID.init(uuidString:)) {
                    outcome.workspaceId = ws
                    let dressed = onMain {
                        dressWorkspace(id: ws, title: plan.workspaceTitle, select: select, expectedSelection: expectedSelection)
                    }
                    if !dressed { outcome.warnings.append("The workspace was not titled: the app was busy") }
                }
            case .err(let code, let message, _):
                outcome.error = ChaosCastError(code: code, message: "Piece \(slot.index + 1) (\(slot.artist.name)): \(message)")
            }
            if outcome.error != nil { break }
        }
        recordOutcome(outcome, created: created)
        return outcome
    }

    /// Run `body` on main, waiting at most `seconds`, with the caller's socket
    /// context (its focus policy) carried across. Returns false when main did
    /// not get to it in time; it then never runs.
    static func onMain(seconds: TimeInterval = 8, _ body: @escaping @MainActor () -> Void) -> Bool {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
            return true
        }
        let gate = ChaosMainGate()
        let done = DispatchSemaphore(value: 0)
        let context = SocketCommandContext.current
        DispatchQueue.main.async {
            if gate.start() {
                SocketCommandContext.withContext(context) { MainActor.assumeIsolated { body() } }
            }
            done.signal()
        }
        if done.wait(timeout: .now() + seconds) == .timedOut {
            return !gate.cancel()
        }
        return true
    }

    /// Title, color and folder the new workspace; select it for an operator gesture.
    @MainActor
    private static func dressWorkspace(id: UUID, title: String, select: Bool, expectedSelection: UUID?) {
        guard let manager = AppDelegate.shared?.workspaceManagerFor(workspaceId: id),
              let workspace = manager.workspaces.first(where: { $0.id == id }) else { return }
        workspace.setCustomTitle(title)
        workspace.setCustomColor(ChaosSettings.colorHex)
        let group = manager.workspaceGroups.first(where: { $0.name == ChaosSettings.groupName })
            ?? (try? manager.createWorkspaceGroup(name: ChaosSettings.groupName, color: ChaosSettings.colorHex,
                                                  icon: ChaosSettings.groupIcon))
        if let group, workspace.groupId == nil {
            try? manager.moveWorkspaceToGroup(workspaceId: id, groupId: group.id)
        }
        // Never pull the operator away from a workspace they moved to while the cast ran.
        if select, expectedSelection == nil || manager.selectedWorkspaceId == expectedSelection {
            manager.selectWorkspace(workspace, cause: "chaos")
        }
    }
}

/// Pending, started or cancelled: a main-thread block that missed its deadline never runs late.
final class ChaosMainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0 // 0 pending, 1 started, 2 cancelled

    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == 0 else { return false }
        state = 1
        return true
    }

    /// True when the block had not started and now never will.
    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == 0 else { return false }
        state = 2
        return true
    }
}
