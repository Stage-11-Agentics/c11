import Darwin
import Foundation
#if DEBUG
import Bonsplit
#endif

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

    private struct PanelKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private var ttyNames: [PanelKey: String] = [:]
    private var detectedTerminalTypes: [PanelKey: String] = [:]
    /// Foreground pid per panel from the last scan. Only Kimi uses it: its
    /// session file is found from the process (`KimiWireLocator`).
    private var foregroundPIDs: [PanelKey: Int32] = [:]
    private var pendingKicks: Set<PanelKey> = []
    private var recoveringPanels: Set<PanelKey> = []
    private var recoveryRoots: [PanelKey: HCProcessIdentity] = [:]
    /// C11H-328: terminals on another machine, by the kind that machine's hc
    /// reports for their foreground (`HCRemoteStatusBinding`). They have no
    /// local TTY, so nothing scans them and no model or process lookup runs
    /// for them; they join the fleet sweep (screen look, report retention,
    /// edges) as local panels do.
    private var remoteKinds: [PanelKey: String] = [:]
    private let scan: (String) -> [String: ProcInfo]
    private let sweepModels: ([AgentModelDetector.Target], [(workspaceId: UUID, surfaceId: UUID)]) -> Void

    /// C11H-320: how long a panel whose last terminal unregistered may take
    /// to register again (a move between workspaces) before its fleet reports
    /// and screen look are retired.
    private let retireGrace: TimeInterval
    private let sweepInterval: TimeInterval

    /// C11H-328: what one periodic sweep hands the fleet.
    struct FleetSweep: Equatable {
        /// Every panel with a known kind, local or on another machine.
        let candidates: [FleetScreenMonitor.Candidate]
        /// The panels whose hook reports and screen looks are kept.
        let livePanels: Set<UUID>
    }
    private let fleetSweep: (FleetSweep) -> Void

    init(scan: @escaping (String) -> [String: ProcInfo] = AgentDetector.runPS,
         sweepModels: @escaping ([AgentModelDetector.Target], [(workspaceId: UUID, surfaceId: UUID)]) -> Void = {
             AgentModelDetector.shared.sweep(agents: $0, plain: $1)
         },
         retireGrace: TimeInterval = 2,
         sweepInterval: TimeInterval = 10,
         fleetSweep: @escaping (FleetSweep) -> Void = AgentDetector.sweepFleet) {
        self.scan = scan
        self.sweepModels = sweepModels
        self.retireGrace = retireGrace
        self.sweepInterval = sweepInterval
        self.fleetSweep = fleetSweep
    }

    /// C11H-320: forget closed panels, look at idle agents' screens, and
    /// announce blocked and stalled edges (always on; cheap).
    static func sweepFleet(_ sweep: FleetSweep) {
        AgentReportStore.shared.retain(livePanels: sweep.livePanels)
        FleetScreenMonitor.shared.retain(livePanels: sweep.livePanels)
        FleetScreenMonitor.shared.sweep(sweep.candidates)
        AgentEdgeMonitor.shared.evaluate(sweep.candidates)
    }

    private var coalesceTimer: DispatchSourceTimer?
    private var scanInFlight = false
    private var sweepTimer: DispatchSourceTimer?

    // MARK: - Public API

    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String, recoverAgent: Bool = false, rootProcess: HCProcessIdentity? = nil) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames[key] = ttyName
            AgentReportStore.shared.restore(panelId: panelId)
            FleetScreenMonitor.shared.restore(panelId: panelId)
            if recoverAgent { recoveringPanels.insert(key) }
            if let rootProcess { recoveryRoots[key] = rootProcess }
            pendingKicks.insert(key)
            startCoalesce(delaySeconds: 0.25)
            startSweepTimerIfNeeded()
        }
    }

    func unregister(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames.removeValue(forKey: key)
            // C11H-328: a remote panel leaves by the same call (a move notes it again).
            remoteKinds.removeValue(forKey: key)
            detectedTerminalTypes.removeValue(forKey: key)
            foregroundPIDs.removeValue(forKey: key)
            pendingKicks.remove(key)
            recoveringPanels.remove(key)
            recoveryRoots.removeValue(forKey: key)
            retireUnlessRegistered(panelId)
        }
    }

    /// C11H-328: a terminal on another machine whose hc names its foreground
    /// `kind`. An agent leaving it (for a shell or another agent) takes its
    /// reports and look with it, as a local scan's does.
    func noteRemote(workspaceId: UUID, panelId: UUID, kind: String) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            let previous = remoteKinds[key]
            remoteKinds[key] = kind
            AgentReportStore.shared.restore(panelId: panelId)
            FleetScreenMonitor.shared.restore(panelId: panelId)
            if Self.endsAgentReports(from: previous, to: kind) {
                AgentReportStore.shared.remove(panelId: panelId)
                FleetScreenMonitor.shared.forget(panelId: panelId)
            }
            startSweepTimerIfNeeded()
        }
    }

    /// C11H-320: a closed panel's report text and screen look leave memory
    /// now, not at a sweep that may never run (its last terminal). Queue only.
    private func retireUnlessRegistered(_ panelId: UUID) {
        guard !isRegistered(panelId) else { return }
        queue.asyncAfter(deadline: .now() + retireGrace) { [self] in
            guard !isRegistered(panelId) else { return }
            AgentReportStore.shared.retire(panelId: panelId)
            FleetScreenMonitor.shared.retire(panelId: panelId)
        }
    }

    /// For tests: the kind a remote panel was last noted with.
    func remoteKindForTesting(workspaceId: UUID, panelId: UUID) -> String? {
        queue.sync { remoteKinds[PanelKey(workspaceId: workspaceId, panelId: panelId)] }
    }

    private func isRegistered(_ panelId: UUID) -> Bool {
        ttyNames.keys.contains { $0.panelId == panelId } || remoteKinds.keys.contains { $0.panelId == panelId }
    }

    /// Request a scan for a specific panel. Coalesces with others.
    func kick(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
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
        // Surviving agents do not emit a new prompt or launch edge. Read their
        // existing session signals on this first scan, inside the 10 s budget.
        if !pendingKicks.isDisjoint(with: recoveringPanels) { refreshModels() }
        pendingKicks.removeAll()
    }

    private func startSweepTimerIfNeeded() {
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + sweepInterval, repeating: sweepInterval)
        timer.setEventHandler { [weak self] in self?.periodicSweep() }
        sweepTimer = timer
        timer.resume()
    }

    private func periodicSweep() {
        guard !ttyNames.isEmpty || !remoteKinds.isEmpty else {
            sweepTimer?.cancel()
            sweepTimer = nil
            // C11H-320 PR 3: the last agents went with their terminals.
            AgentEdgeMonitor.shared.evaluate([])
            return
        }
        runScan(panelsToWrite: Set(ttyNames.keys))
        // C11-162 (TEL-5) — coarse liveness recompute rides the existing
        // 10 s sweep on this utility queue: zero new timer, zero hot-path
        // work. Decays stale `working` surfaces to `idle` as a backstop
        // for missed prompt reports.
        for key in ttyNames.keys {
            PanelLivenessDeriver.reconcile(
                surfaceId: key.panelId,
                workspaceId: key.workspaceId,
                detectedTerminalType: detectedTerminalTypes[key]
            )
        }
        let localPanels = Set(ttyNames.keys.map(\.panelId))
        PanelLivenessDeriver.retainSurfaceState(forLiveSurfaces: localPanels)
        PromptCacheReportStore.shared.retain(livePanels: localPanels)
        fleetSweep(fleetSweepInput())
        // C11H-328: a remote panel's model is never looked up here.
        if !ttyNames.isEmpty { refreshModels() }
    }

    /// Local panels with a scanned kind, then panels on other machines.
    private func fleetSweepInput() -> FleetSweep {
        var candidates = ttyNames.keys.compactMap { key in
            detectedTerminalTypes[key].map {
                FleetScreenMonitor.Candidate(workspaceId: key.workspaceId, panelId: key.panelId, kind: $0)
            }
        }
        let local = Set(candidates.map(\.panelId))
        for (key, kind) in remoteKinds where !local.contains(key.panelId) {
            candidates.append(.init(workspaceId: key.workspaceId, panelId: key.panelId, kind: kind))
        }
        let live = Set(ttyNames.keys.map(\.panelId)).union(remoteKinds.keys.map(\.panelId))
        return FleetSweep(candidates: candidates, livePanels: live)
    }

    private func refreshModels() {
        var targets: [AgentModelDetector.Target] = []
        var plain: [(workspaceId: UUID, surfaceId: UUID)] = []
        for key in ttyNames.keys {
            if let kind = AgentIdentityPolicy.normalizedKind(detectedTerminalTypes[key]),
               AgentIdentityPolicy.isAgentKind(kind) {
                targets.append(.init(workspaceId: key.workspaceId, surfaceId: key.panelId, kind: kind,
                                     pid: kind == "kimi" ? foregroundPIDs[key] : nil))
            } else if detectedTerminalTypes[key] != nil {
                plain.append((key.workspaceId, key.panelId))
            }
        }
        sweepModels(targets, plain)
    }

    // MARK: - Scan

    private func runScan(panelsToWrite: Set<PanelKey>) {
        scanInFlight = true
        defer { scanInFlight = false }
        guard !ttyNames.isEmpty else { return }

        // Scan across *all* registered TTYs — one ps fork, doesn't matter
        // whether we were kicked for a subset. We'll only write metadata for
        // the panels that were kicked, though.
        let snapshot = ttyNames
        let uniqueTTYs = Set(snapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")
        let foregroundPerTTY = scan(ttyList)

        for key in panelsToWrite {
            guard let tty = snapshot[key] else { continue }
            // A holder loss can release this tty before inventory catches up.
            // Never attribute a later terminal reusing it to the restored panel.
            if let root = recoveryRoots[key] {
                guard let facts = HCAgentRecoveryKernel.readProcess(root.pid), facts.identity == root,
                      facts.controllingTTYDevice == TerminalPIDResolver.ttyDevice(for: tty).map({ UInt32(bitPattern: $0) }) else {
                    continue
                }
            }
            guard let info = foregroundPerTTY[tty] else {
                // TTY exists but no foreground process — skip (no-op).
                foregroundPIDs.removeValue(forKey: key)
                continue
            }
            foregroundPIDs[key] = Int32(truncatingIfNeeded: info.pid)
            let classification = Self.classify(ProcessFacts(
                comm: info.comm,
                args: info.args,
                executablePath: info.executablePath
            ))
            let previousClassification = detectedTerminalTypes[key]
            let detectionChanged = previousClassification != classification
            if detectionChanged {
                detectedTerminalTypes[key] = classification
                if Self.endsPromptCacheReports(from: previousClassification, to: classification) {
                    PromptCacheReportStore.shared.remove(panelId: key.panelId)
                }
                // C11H-320: an agent that left takes its account, message and
                // screen with it. A shell becoming an agent keeps them: that
                // agent's own SessionStart can report before this scan sees it.
                if Self.endsAgentReports(from: previousClassification, to: classification) {
                    AgentReportStore.shared.remove(panelId: key.panelId)
                    FleetScreenMonitor.shared.forget(panelId: key.panelId)
                }
            }
            let changed = PanelMetadataStore.shared.setInternal(
                workspaceId: key.workspaceId,
                surfaceId: key.panelId,
                key: "terminal_type",
                value: classification,
                source: .heuristic
            )
            let recoveredProcess: MailboxStdinBuffer.AgentProcess?
            if recoveringPanels.contains(key), AgentIdentityPolicy.isAgentKind(classification),
               let pid = Int32(exactly: info.pid),
               let facts = MailboxAgentForeground.processTerminalInfo(pid: pid),
               !facts.isZombie, facts.startTime > 0,
               facts.terminalDevice == TerminalPIDResolver.ttyDevice(for: tty),
               facts.processGroup == facts.terminalForegroundGroup {
                recoveredProcess = .init(pid: pid, startTime: facts.startTime)
            } else {
                recoveredProcess = nil
            }
            #if DEBUG
            if recoveringPanels.contains(key) {
                dlog("agent.recover panel=\(key.panelId.uuidString.prefix(8)) tty=\(tty) pid=\(info.pid) kind=\(classification) relearn=\(recoveredProcess != nil)")
            }
            #endif
            if changed || detectionChanged || recoveredProcess != nil {
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
                            workspace.syncSurfacePanelActivityStateForPanel(key.panelId)
                        }
                        if let recoveredProcess {
                            workspace.relearnMailboxAgentProcess(surfaceId: key.panelId, process: recoveredProcess)
                        }
                    }
                }
            }
        }
    }

    /// Prompt cache reports describe the agent that sent them. They end when
    /// the panel returns to its shell or another agent takes the foreground,
    /// not when a tool the agent opened (an editor) briefly does.
    static func endsPromptCacheReports(from previous: String?, to next: String) -> Bool {
        guard let previous, previous != next else { return false }
        return next == "shell" || AgentIdentityPolicy.isAgentKind(next)
    }

    /// C11H-320: the agent that reported a panel's account, final message and
    /// failure left it: it became a shell or another agent. A shell becoming
    /// an agent keeps them (that agent's own SessionStart can report before a
    /// scan sees it), and so does an agent whose editor or tool briefly holds
    /// the foreground (`unknown`).
    static func endsAgentReports(from previous: String?, to next: String) -> Bool {
        guard let previous, previous != next, AgentIdentityPolicy.isAgentKind(previous) else { return false }
        return next == "shell" || AgentIdentityPolicy.isAgentKind(next)
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

    static func classify(
        _ facts: ProcessFacts,
        wrapperDirectories: [String] = bundledWrapperDirectories
    ) -> String {
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

        // C11H-191: a seat in an Incus container runs as `incus exec <container> [options]
        // -- <command>`, so the terminal's foreground is `incus`. The command is the first
        // word after `--`, and only it names the agent: later words are its arguments
        // (`-- tail -f /var/log/codex` is not Codex). A launcher that wraps the harness in a
        // shell names the harness as argv[0] instead (`exec -a`), which the loop above reads.
        if names.contains("incus") {
            let tokens = args.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count > 1, tokens[1] == "exec", let dash = tokens.firstIndex(of: "--"),
               dash + 1 < tokens.count {
                let base = basename(tokens[dash + 1])
                for manifest in AgentRegistry.shared.all where manifest.detectComms.contains(base) {
                    return manifest.kind
                }
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
                // c11's own `Resources/bin/<agent>` wrappers are bash scripts
                // that exec the real agent. While one runs, the shell is not
                // evidence that an agent exited: report `unknown` so the
                // declared terminal type stays in force (C11-553).
                if isBundledAgentWrapper(args: args, directories: wrapperDirectories) {
                    return "unknown"
                }
                return "shell"
            }
        }

        return "unknown"
    }

    /// This app's `Contents/Resources/bin`, lowercased, as the shell sees it
    /// on PATH and with symlinks resolved. Empty outside an app bundle.
    static let bundledWrapperDirectories: [String] = {
        guard let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true) else { return [] }
        let paths = [bin.path, bin.standardizedFileURL.path, bin.resolvingSymlinksInPath().path]
        return Array(Set(paths.map { $0.lowercased() })).filter { !$0.isEmpty }
    }()

    /// True when a shell's script operand (the word after argv0) is one of
    /// the agent wrappers in `directories`. The directory is matched as a
    /// prefix, so a bundle path with spaces (`c11 DEV <tag>.app`) still
    /// matches. A script elsewhere with an agent's name is not a wrapper.
    static func isBundledAgentWrapper(args: String, directories: [String]) -> Bool {
        let line = args.lowercased()
        guard !directories.isEmpty,
              let argv0End = line.firstIndex(where: \.isWhitespace) else { return false }
        let operand = line[argv0End...].drop(while: \.isWhitespace)
        for directory in directories {
            let lowered = directory.lowercased()
            let prefix = lowered.hasSuffix("/") ? lowered : lowered + "/"
            guard operand.hasPrefix(prefix) else { continue }
            let rest = operand.dropFirst(prefix.count)
            let name = String(rest.prefix(while: { !$0.isWhitespace }))
            guard !name.isEmpty, !name.contains("/") else { continue }
            if AgentRegistry.shared.all.contains(where: { $0.detectComms.contains(name) }) { return true }
        }
        return false
    }

    private static func basename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    private static func isRuntime(_ name: String) -> Bool {
        name == "node" || name == "bun" || name == "deno" || name.hasPrefix("python")
    }
}
