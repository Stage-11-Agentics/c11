import Foundation

/// Heuristic TUI / agent detector (c11mux Module 1).
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

    private let queue = DispatchQueue(label: "com.cmux.agent-detector", qos: .utility)

    private struct PanelKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private var ttyNames: [PanelKey: String] = [:]
    private var pendingKicks: Set<PanelKey> = []
    private var coalesceTimer: DispatchSourceTimer?
    private var scanInFlight = false
    private var sweepTimer: DispatchSourceTimer?

    // MARK: - Public API

    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames[key] = ttyName
            pendingKicks.insert(key)
            startCoalesce(delaySeconds: 0.25)
            startSweepTimerIfNeeded()
        }
    }

    func unregister(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames.removeValue(forKey: key)
            pendingKicks.remove(key)
        }
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
        }
        sweepTimer = timer
        timer.resume()
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
        let foregroundPerTTY = Self.runPS(ttyList: ttyList)

        for key in panelsToWrite {
            guard let tty = snapshot[key] else { continue }
            guard let info = foregroundPerTTY[tty] else {
                // TTY exists but no foreground process — skip (no-op).
                continue
            }
            let classification = Self.classify(comm: info.comm, args: info.args)
            SurfaceMetadataStore.shared.setInternal(
                workspaceId: key.workspaceId,
                surfaceId: key.panelId,
                key: "terminal_type",
                value: classification,
                source: .heuristic
            )
        }
    }

    // MARK: - ps parsing

    struct ProcInfo {
        let pid: Int
        let ppid: Int
        let tty: String
        let tpgid: Int
        let comm: String
        let args: String
    }

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
            guard let info = parsePSLine(String(line)) else { continue }
            // Foreground process: pid == tpgid.
            guard info.pid == info.tpgid else { continue }
            foreground[info.tty] = info
        }
        return foreground
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
        // Reconstruct args as everything after the 5th whitespace-split token
        // by finding the 5th space/tab boundary. Keeps the original spacing.
        var splits = 0
        var argsStart = trimmed.startIndex
        for idx in trimmed.indices {
            if trimmed[idx].isWhitespace {
                // Eat runs of whitespace.
                var cursor = idx
                while cursor < trimmed.endIndex, trimmed[cursor].isWhitespace {
                    cursor = trimmed.index(after: cursor)
                }
                splits += 1
                if splits == 5 {
                    argsStart = cursor
                    break
                }
            }
        }
        let args = splits >= 5 ? String(trimmed[argsStart...]) : parts[5...].joined(separator: " ")
        return ProcInfo(pid: pid, ppid: ppid, tty: tty, tpgid: tpgid, comm: comm, args: args)
    }

    // MARK: - Binary-match table

    private static let canonicalShells: Set<String> = ["zsh", "bash", "fish", "sh", "dash"]

    /// Classify a foreground process into a canonical `terminal_type` value.
    /// Exposed as `static` so tests can exercise the table without a live scan.
    static func classify(comm: String, args: String) -> String {
        let c = comm.lowercased()
        let a = args.lowercased()

        // Exact comm match on first-class TUIs.
        switch c {
        case "claude", "claude-code":
            return "claude-code"
        case "codex", "codex-cli":
            return "codex"
        case "kimi", "kimi-cli":
            return "kimi"
        case "opencode", "opencode-cli":
            return "opencode"
        default:
            break
        }

        // Node-wrapped CLIs: comm truncated to `node`, match via args substring.
        if c == "node" {
            if a.contains("claude-code") || a.contains("anthropic-ai/claude-code") || a.contains("/claude") {
                return "claude-code"
            }
            if a.contains("codex-cli") || a.contains("openai/codex") || a.contains("/codex") {
                return "codex"
            }
            if a.contains("kimi-cli") || a.contains("moonshot/kimi") || a.contains("/kimi") {
                return "kimi"
            }
            if a.contains("opencode-cli") || a.contains("sst/opencode") || a.contains("/opencode") {
                return "opencode"
            }
        }

        // Canonical shells → "shell".
        // `comm` from Darwin's ps may be `-zsh` for login shells.
        let strippedShell = c.hasPrefix("-") ? String(c.dropFirst()) : c
        if canonicalShells.contains(strippedShell) {
            return "shell"
        }

        return "unknown"
    }
}
