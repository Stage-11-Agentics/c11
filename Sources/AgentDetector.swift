import Darwin
import Foundation

/// Heuristic TUI / agent detector (c11 Module 1).
///
/// For every surface with a registered TTY (`Workspace.surfaceTTYNames`), runs
/// a single `ps -t <ttys>` to pick the foreground process per TTY, applies the
/// binary-match table, and writes `terminal_type` into M2's per-surface
/// metadata via the in-process accessor (no socket round-trip).
///
/// Precedence is gated at the store level: heuristic writes never overwrite
/// `declare`, `osc`, or `explicit` values.
///
/// Runs at:
///   - Surface creation (via `reportTTY` hook, 250 ms debounce).
///   - `agent_kick` (shell integration precmd/preexec hook).
///   - 10 s periodic sweep (safety net).
///   - Focus change (caller invokes `kick`).
final class AgentDetector: @unchecked Sendable {
    static let shared = AgentDetector()

    private let queue = DispatchQueue(label: "com.stage11.c11.agent-detector", qos: .utility)

    private struct TabKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private var ttyNames: [TabKey: String] = [:]
    private var detectedTerminalTypes: [TabKey: String] = [:]
    private var pendingKicks: Set<TabKey> = []
    private var coalesceTimer: DispatchSourceTimer?
    private var scanInFlight = false
    private var sweepTimer: DispatchSourceTimer?

    // MARK: - Public API

    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        queue.async { [self] in
            let key = TabKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames[key] = ttyName
            pendingKicks.insert(key)
            startCoalesce(delaySeconds: 0.25)
            startSweepTimerIfNeeded()
        }
    }

    func unregister(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = TabKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames.removeValue(forKey: key)
            detectedTerminalTypes.removeValue(forKey: key)
            pendingKicks.remove(key)
        }
    }

    /// Request a scan for a specific panel. Coalesces with others.
    func kick(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = TabKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != nil else { return }
            pendingKicks.insert(key)
            startCoalesce(delaySeconds: 0.2)
        }
    }

    // MARK: - Coalesce + periodic sweep

    private func startCoalesce(delaySeconds: Double) {
        guard coalesceTimer == nil, !scanInFlight else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delaySeconds)
        timer.setEventHandler { [weak self] in
            self?.coalesceFired()
        }
        coalesceTimer = timer
        timer.resume()
    }

    private func coalesceFired() {
        coalesceTimer?.cancel()
        coalesceTimer = nil
        guard !pendingKicks.isEmpty else { return }
        runScan(panelsToWrite: pendingKicks)
        pendingKicks.removeAll()
    }

    private func startSweepTimerIfNeeded() {
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.ttyNames.isEmpty else {
                self.sweepTimer?.cancel()
                self.sweepTimer = nil
                return
            }
            self.runScan(panelsToWrite: Set(self.ttyNames.keys))
            // C11-162 (TEL-5) — coarse liveness recompute rides the existing
            // 10 s sweep on this utility queue: zero new timer, zero hot-path
            // work. Decays stale `working` surfaces to `idle` as a backstop
            // for missed prompt reports.
            for key in self.ttyNames.keys {
                TabLivenessDeriver.reconcile(
                    surfaceId: key.panelId,
                    workspaceId: key.workspaceId,
                    detectedTerminalType: self.detectedTerminalTypes[key]
                )
            }
            TabLivenessDeriver.retainPromptCacheState(forLiveSurfaces: Set(self.ttyNames.keys.map(\.panelId)))
            // Live model detection rides the same sweep: tail each agent's own
            // session file off-main; surfaces with no agent in front clear any
            // derived model left by a session that ended.
            var modelTargets: [AgentModelDetector.Target] = []
            var plainSurfaces: [(workspaceId: UUID, surfaceId: UUID)] = []
            for key in self.ttyNames.keys {
                if let kind = AgentIdentityPolicy.normalizedKind(self.detectedTerminalTypes[key]),
                   AgentIdentityPolicy.isAgentKind(kind) {
                    modelTargets.append(.init(workspaceId: key.workspaceId, surfaceId: key.panelId, kind: kind))
                } else if self.detectedTerminalTypes[key] != nil {
                    plainSurfaces.append((key.workspaceId, key.panelId))
                }
            }
            AgentModelDetector.shared.sweep(agents: modelTargets, plain: plainSurfaces)
        }
        sweepTimer = timer
        timer.resume()
    }

    // MARK: - Scan

    private func runScan(panelsToWrite tabsToWrite: Set<TabKey>) {
        scanInFlight = true
        defer { scanInFlight = false }
        guard !ttyNames.isEmpty else { return }

        // Scan across *all* registered TTYs — one ps fork, doesn't matter
        // whether we were kicked for a subset. We'll only write metadata for
        // the panels that were kicked, though.
        let snapshot = ttyNames
        let uniqueTTYs = Set(snapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")
        let foregroundPerTTY = Self.runPS(ttyList: ttyList)

        for key in tabsToWrite {
            guard let tty = snapshot[key] else { continue }
            guard let info = foregroundPerTTY[tty] else {
                // TTY exists but no foreground process — skip (no-op).
                continue
            }
            let classification = Self.classify(ProcessFacts(
                comm: info.comm,
                args: info.args,
                executablePath: info.executablePath
            ))
            let detectionChanged = detectedTerminalTypes[key] != classification
            if detectionChanged {
                detectedTerminalTypes[key] = classification
            }
            let changed = TabMetadataStore.shared.setInternal(
                workspaceId: key.workspaceId,
                surfaceId: key.panelId,
                key: "terminal_type",
                value: classification,
                source: .heuristic
            )
            if changed || detectionChanged {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let workspaceManager = AppDelegate.shared?.workspaceManagerFor(workspaceId: key.workspaceId),
                              let workspace = workspaceManager.workspaces.first(where: { $0.id == key.workspaceId }) else {
                            return
                        }
                        workspace.setDetectedTerminalType(
                            classification,
                            forSurface: key.panelId
                        )
                        if changed && !detectionChanged {
                            workspace.syncSurfaceTabActivityStateForTab(key.panelId)
                        }
                    }
                }
            }
        }
    }

    // MARK: - ps parsing

    /// Identity the classifier can see without a live process.
    ///
    /// `comm` is the `ps` column, which keeps at most 16 characters of
    /// argv[0]. `args` is the argv line. `executablePath` is `proc_pidpath`
    /// for a foreground pid from a scan; tests set it directly.
    struct ProcessFacts: Equatable {
        var comm: String
        var args: String
        var executablePath: String?

        init(comm: String, args: String, executablePath: String? = nil) {
            self.comm = comm
            self.args = args
            self.executablePath = executablePath
        }
    }

    struct ProcInfo {
        let pid: Int
        let ppid: Int
        let tty: String
        let tpgid: Int
        let comm: String
        let args: String
        var executablePath: String? = nil
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` (4 * MAXPATHLEN). The macro is not imported.
    private static let pidPathCapacity = 4 * Int(MAXPATHLEN)

    /// Run `ps -t tty1,tty2,... -o pid=,ppid=,tty=,tpgid=,comm=,args=` and
    /// pick the foreground process per TTY (the one whose pid == tpgid).
    /// Returns map tty -> ProcInfo.
    static func runPS(ttyList: String) -> [String: ProcInfo] {
        guard !ttyList.isEmpty else { return [:] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", ttyList, "-o", "pid=,ppid=,tty=,tpgid=,comm=,args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var foreground: [String: ProcInfo] = [:]
        for line in output.split(separator: "\n") {
            guard var info = parsePSLine(String(line)) else { continue }
            // Foreground process: pid == tpgid.
            guard info.pid == info.tpgid else { continue }
            // One syscall per foreground pid. `ps` has already clipped comm;
            // this is the untruncated executable path.
            info.executablePath = executablePath(for: Int32(info.pid))
            foreground[info.tty] = info
        }
        return foreground
    }

    /// Full executable path from `proc_pidpath`, or nil if `pid` is gone.
    /// Internal so a test can call it for this process.
    static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: pidPathCapacity)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func parsePSLine(_ line: String) -> ProcInfo? {
        // Columns: pid ppid tty tpgid comm args...
        // `comm` is single-token (no spaces); `args` can have spaces.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 6 else { return nil }
        guard let pid = Int(parts[0]),
              let ppid = Int(parts[1]),
              let tpgid = Int(parts[3]) else { return nil }
        let tty = parts[2]
        let comm = parts[4]
        // Everything after the 5th column is argv. A padding run is one
        // column. Counting every space shifts the boundary: on a `ttysNNN`
        // line (two-space pad, the shape `ps -t` prints) it lands on `comm`,
        // so argv0 is the 16-character clip; the wider `??` pad lands on `tpgid`.
        var index = trimmed.startIndex
        var splits = 0
        var argsStart = trimmed.endIndex
        while index < trimmed.endIndex {
            if trimmed[index].isWhitespace {
                while index < trimmed.endIndex, trimmed[index].isWhitespace {
                    index = trimmed.index(after: index)
                }
                splits += 1
                if splits == 5 {
                    argsStart = index
                    break
                }
            } else {
                index = trimmed.index(after: index)
            }
        }
        let args = splits >= 5
            ? String(trimmed[argsStart...])
            : parts[5...].joined(separator: " ")
        return ProcInfo(pid: pid, ppid: ppid, tty: tty, tpgid: tpgid, comm: comm, args: args)
    }

    // MARK: - Binary-match table

    private static let canonicalShells: Set<String> = ["zsh", "bash", "fish", "sh", "dash"]

    /// Classify a foreground process into a canonical `terminal_type` value.
    /// Exposed as `static` so tests can exercise the table without a live scan.
    static func classify(comm: String, args: String) -> String {
        classify(ProcessFacts(comm: comm, args: args))
    }

    static func classify(_ facts: ProcessFacts) -> String {
        let comm = facts.comm.lowercased()
        let args = facts.args.lowercased()
        // `ps` comm is argv[0] clipped to 16 characters, so a long path loses
        // its basename (`/private/tmp/claude-501/.../claude` becomes
        // `/private/tmp/cla`). The basename has to come from the full argv0
        // or from `proc_pidpath`. Later argv tokens are user input and are
        // not agent names, except on the interpreter rail below.
        var names: [String] = [comm, basename(comm)]
        if let executablePath = facts.executablePath?.lowercased(), !executablePath.isEmpty {
            names.append(basename(executablePath))
        }
        if let argv0 = args.split(whereSeparator: \.isWhitespace).first {
            names.append(basename(String(argv0)))
        }

        for name in names {
            for manifest in AgentRegistry.shared.all where manifest.detectComms.contains(name) {
                return manifest.kind
            }
        }

        // Interpreter-wrapped CLIs: the runtime is `node`/`bun`/`deno`/`python*`
        // and the agent identity lives in the args. A long runtime path is
        // clipped in `comm`, so the runtime name is taken from the same
        // untruncated basenames as above. Two invocation shapes:
        //  - module path (`node …/@anthropic-ai/claude-code/cli.js`) → match a
        //    distinctive args substring.
        //  - shim/symlink (`bun /Users/x/.bun/bin/omp`, `python …/bin/kimi`)
        //    → the module path isn't in argv, but the invoked script's basename
        //    is the agent's binary name. (Matching only the *last* path
        //    component avoids false positives from mid-path directory names.)
        if names.contains(where: isRuntime) {
            for manifest in AgentRegistry.shared.all
            where manifest.detectNodeArgsSubstrings.contains(where: { args.contains($0) }) {
                return manifest.kind
            }
            for token in args.split(separator: " ") {
                let base = basename(String(token))
                for manifest in AgentRegistry.shared.all where manifest.detectComms.contains(base) {
                    return manifest.kind
                }
            }
        }

        // Canonical shells → "shell".
        // `comm` from Darwin's ps may be `-zsh` for login shells.
        for name in names {
            let stripped = name.hasPrefix("-") ? String(name.dropFirst()) : name
            if canonicalShells.contains(stripped) {
                return "shell"
            }
        }

        return "unknown"
    }

    private static func basename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    private static func isRuntime(_ name: String) -> Bool {
        name == "node" || name == "bun" || name == "deno" || name.hasPrefix("python")
    }
}
