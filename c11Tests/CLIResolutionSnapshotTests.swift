import XCTest
import Darwin

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Shared fixtures for the CLI resolution tests. It declares no tests: the tests live in the
/// subclasses below so xcodebuild can run them on separate parallel workers (C11H-30).
class CLIResolutionTestCase: XCTestCase {

    fileprivate let codexID = "ddd11111-2222-3333-4444-555566667777"

    fileprivate func makeInputs(
        env: [String: String],
        commands: [String: String?] = [:],
        existing: Set<String> = [],
        versions: [String: String] = [:]
    ) -> CLIResolutionInputs {
        return CLIResolutionInputs(
            environment: env,
            commandLookup: { name in commands[name] ?? nil },
            executableExists: { path in existing.contains(path) },
            versionLookup: { path in versions[path] }
        )
    }

    // MARK: - Status classification





    // MARK: - cmux coexistence note

    // MARK: - Trimming and edge cases


    // MARK: - JSON shape


    // MARK: - Argument parsing




    // MARK: - Default command lookup helper

    // MARK: - C11-206 shared resume decisions

    fileprivate func resumeInput(
        mode: ResumeRecoveryMode,
        ownership: ResumeOwnershipStatus = .unique,
        placeholder: Bool = false,
        state: ResumePersistedState = .suspended,
        idValid: Bool = true,
        transcript: ResumeTranscriptEvidence = .verified
    ) -> ResumeDecisionInput {
        ResumeDecisionInput(
            mode: mode,
            ownership: ownership,
            kind: "codex",
            id: codexID,
            placeholder: placeholder,
            state: state,
            exactIDValid: idValid,
            transcriptEvidence: transcript
        )
    }









    fileprivate var panelTargetReadCommands: [[String]] {
        [
            ["identify"],
            ["read-screen"],
            ["read-selection"],
            ["input-state"],
            ["retry-input"],
            ["get-metadata"],
            ["get-titlebar-state"],
            ["family"],
            ["panel-color", "get"],
            ["markdown-content"],
            ["markdown", "backlinks"],
            ["markdown", "visible"],
            ["markdown", "history"],
            ["markdown", "links"],
            ["browser", "get-url"],
            ["browser", "snapshot"],
            ["browser", "identify"],
            ["browser", "eval"],
            ["browser", "wait", "--selector", ".ready"],
            ["browser", "screenshot"],
            ["browser", "get", "title"],
            ["browser", "is", "visible"],
            ["browser", "find", "text"],
            ["browser", "panel", "list"],
            ["browser", "state", "save"],
            ["browser", "network", "requests"],
            ["browser", "cookies", "get"],
            ["browser", "storage", "local", "get"],
            ["browser", "console", "list"],
            ["browser", "errors", "list"],
            ["get-url"],
            ["is-webview-focused"],
            ["conversation", "list"],
            ["conversation", "get"],
            ["mailbox", "recv"],
            ["mailbox", "inbox-dir"],
            ["capture-pane"],
            ["capturep"],
            ["pipe-pane", "--command", "cat"],
        ]
    }



































    fileprivate func assertPanelTargetRejected(
        expected: String,
        command: [String],
        flag: String,
        value: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        var args = command + [flag]
        if let value { args.append(value) }
        guard let result = runCLI(args, file: file, line: line) else { return false }
        guard result.status == 1,
              result.stdout.isEmpty,
              result.stderr == "Error: \(expected)\n" else {
            XCTFail(
                "Expected CLI to reject before socket I/O with 'Error: \(expected)', " +
                "got status \(result.status), stdout=\(result.stdout.debugDescription), " +
                "stderr=\(result.stderr.debugDescription)",
                file: file,
                line: line
            )
            return false
        }
        return true
    }

    @discardableResult
    fileprivate func assertCommandReachesSocket(
        _ command: [String],
        method: String? = nil,
        environmentOverrides: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket", file: file, line: line)
            return false
        }
        var environment = [
            "C11_WORKSPACE_ID": "11111111-2222-3333-4444-555566667777",
            "C11_PANEL_ID": socket.panelIDForAssertions,
        ]
        environment.merge(environmentOverrides) { _, new in new }
        guard let result = runCLI(command, socketPath: socket.path, environmentOverrides: environment, file: file, line: line) else {
            return false
        }
        guard result.status == 0 else {
            XCTFail("Expected \(command) to succeed, got stderr=\(result.stderr.debugDescription)", file: file, line: line)
            return false
        }
        guard !result.stderr.localizedCaseInsensitiveContains("unknown flag") else {
            XCTFail("Preflight rejected \(command): \(result.stderr)", file: file, line: line)
            return false
        }
        guard socket.waitUntilFinished() else {
            XCTFail("Expected \(command) to reach the fake socket", file: file, line: line)
            return false
        }
        guard !socket.requests.isEmpty else {
            XCTFail("Expected a request for \(command)", file: file, line: line)
            return false
        }
        if let method,
           !socket.requests.contains(where: { $0["method"] as? String == method }) {
            XCTFail("Expected \(method) for \(command), got \(socket.requests)", file: file, line: line)
            return false
        }
        return true
    }

    fileprivate func assertBrowserReadReachesSocket(
        _ command: [String],
        method: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket", file: file, line: line)
            return false
        }
        guard let result = runCLI(command, socketPath: socket.path, file: file, line: line) else { return false }
        guard result.status == 0 else {
            XCTFail("Expected (command) to succeed, got stderr=\(result.stderr.debugDescription)", file: file, line: line)
            return false
        }
        guard socket.waitUntilFinished() else {
            XCTFail("fake socket did not finish serving (command)", file: file, line: line)
            return false
        }
        guard let request = socket.requests.first(where: { $0["method"] as? String == method }) else {
            XCTFail("Expected (method) request, got \(socket.requests)", file: file, line: line)
            return false
        }
        let params = request["params"] as? [String: Any]
        guard params?["panel_id"] as? String == "panel:1" else {
            XCTFail("Expected panel_id panel:1, got \(String(describing: params?["panel_id"]))", file: file, line: line)
            return false
        }
        return true
    }

    fileprivate func runCLI(
        _ args: [String],
        socketPath: String? = nil,
        passSocketFlag: Bool = true,
        environmentOverrides: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (status: Int32, stdout: String, stderr: String)? {
        do {
            let cli = try bundledCLI()
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = cli
            process.arguments = passSocketFlag
                ? ["--socket", socketPath ?? "/tmp/c11-panel-target-test-\(UUID().uuidString).sock"] + args
                : args
            var environment = ProcessInfo.processInfo.environment
            for key in [
                "C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH",
                "C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID",
                "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID",
                "C11_WORKSPACE_ID", "CMUX_WORKSPACE_ID",
            ] {
                environment.removeValue(forKey: key)
            }
            environment.merge(environmentOverrides) { _, new in new }
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr
            // Wait for the process notification directly: waitUntilExit polls a
            // run loop and adds a delay to every short-lived CLI invocation.
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            if exited.wait(timeout: .now() + 15) == .timedOut {
                process.terminate()
                XCTFail("Bundled c11 CLI did not exit within 15 seconds", file: file, line: line)
                return nil
            }
            return (
                process.terminationStatus,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: stderrData, as: UTF8.self)
            )
        } catch {
            XCTFail("Could not run bundled c11 CLI: \(error)", file: file, line: line)
            return nil
        }
    }

    fileprivate func bundledCLI() throws -> URL {
        var products = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            for appName in ["c11 DEV.app", "c11.app", "c11 DEV.app", "c11.app"] {
                let cli = products.appendingPathComponent(appName + "/Contents/Resources/bin/c11")
                if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
            }
            products.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: products.path])
    }

    fileprivate final class CapturedCLISocket {
        let path = "/tmp/c11-cli-panel-target-\(UUID().uuidString).sock"
        private let listenerFD: Int32
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var capturedRequests: [[String: Any]] = []
        private var capturedLegacyCommands: [String] = []
        private let panelID = "ddd11111-2222-3333-4444-555566667777"
        var panelIDForAssertions: String { panelID }

        var requests: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequests
        }

        var legacyCommands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return capturedLegacyCommands
        }

        init() throws {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Self.posixError("socket") }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path) - 1
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) { destination in
                    let raw = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                    strncpy(raw, source, pathCapacity)
                }
            }
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                Darwin.close(fd)
                throw Self.posixError("bind")
            }
            guard Darwin.listen(fd, 1) == 0 else {
                Darwin.close(fd)
                Darwin.unlink(path)
                throw Self.posixError("listen")
            }
            listenerFD = fd
            // Its own thread, not a GCD worker: hundreds of these in one test
            // must not exhaust the shared pool.
            let server = Thread { [self] in serveOneClient() }
            server.stackSize = 1 << 18
            server.start()
        }

        deinit {
            Darwin.close(listenerFD)
            Darwin.unlink(path)
        }

        func waitUntilFinished(timeout: TimeInterval = 2) -> Bool {
            finished.wait(timeout: .now() + timeout) == .success
        }

        private var resultOverrides: [String: [String: Any]] = [:]
        private var requestHandler: (([String: Any]) -> [String: Any]?)?

        /// Route-aware replies for commands that enumerate multiple windows/workspaces.
        func reply(using handler: @escaping ([String: Any]) -> [String: Any]?) {
            lock.lock()
            requestHandler = handler
            lock.unlock()
        }

        /// Answer `method` with `result` instead of the default reply.
        func reply(to method: String, with result: [String: Any]) {
            lock.lock()
            resultOverrides[method] = result
            lock.unlock()
        }

        private func serveOneClient() {
            defer { finished.signal() }
            // A CLI that never connects (a preflight rejection) must not hold
            // this thread forever.
            var descriptor = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 20_000) > 0 else { return }
            var clientAddress = sockaddr_un()
            var clientAddressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.accept(listenerFD, sockaddrPointer, &clientAddressLength)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = bytes.withUnsafeMutableBufferPointer { buffer in
                    Darwin.read(clientFD, buffer.baseAddress, buffer.count)
                }
                if count <= 0 { return }
                pending.append(contentsOf: bytes[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                        guard let legacyCommand = String(data: line, encoding: .utf8) else { continue }
                        if legacyCommand.hasPrefix("auth ") {
                            respond("OK", on: clientFD)
                            continue
                        }
                        lock.lock()
                        capturedLegacyCommands.append(legacyCommand)
                        capturedRequests.append(["legacy_command": legacyCommand])
                        lock.unlock()
                        respond("OK", on: clientFD)
                        continue
                    }
                    lock.lock()
                    capturedRequests.append(request)
                    lock.unlock()
                    respond(to: request, on: clientFD)
                }
            }
        }

        private func respond(to request: [String: Any], on clientFD: Int32) {
            let method = request["method"] as? String ?? ""
            lock.lock()
            let override = resultOverrides[method]
            let handler = requestHandler
            lock.unlock()
            let routed = handler?(request)
            let result: [String: Any]
            switch method {
            case _ where routed != nil:
                result = routed ?? [:]
            case _ where override != nil:
                result = override ?? [:]
            case "system.capabilities":
                result = ["features": [["id": "vocabulary.workspace_area_panel"]]]
            case "panel.list":
                result = ["panels": [["id": panelID, "ref": "panel:1", "index": 1]]]
            case "panel.read_text":
                result = ["text": "captured"]
            case "browser.eval":
                result = ["value": "evaluated"]
            case "panel.set_metadata":
                result = ["applied": ["title": true, "description": true], "reasons": [:]]
            default:
                result = [:]
            }
            let envelope: [String: Any] = [
                "id": request["id"] ?? "test",
                "ok": true,
                "result": result,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
            respond(String(decoding: data, as: UTF8.self), on: clientFD)
        }

        private func respond(_ response: String, on clientFD: Int32) {
            var output = Array((response + "\n").utf8)
            while !output.isEmpty {
                let written = output.withUnsafeBytes { raw in
                    Darwin.write(clientFD, raw.baseAddress, raw.count)
                }
                if written <= 0 { return }
                output.removeFirst(written)
            }
        }

        private static func posixError(_ operation: String) -> NSError {
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "CLI fake socket \(operation) failed"]
            )
        }
    }
}

// MARK: - C11-525: generated links resolve live identity without navigation

extension CLIResolutionTestCase {
    fileprivate static let linkWindowA = "a1111111-1111-4111-8111-111111111111"
    fileprivate static let linkWindowB = "b1111111-1111-4111-8111-111111111111"
    fileprivate static let linkWorkspaceA = "a2222222-2222-4222-8222-222222222222"
    fileprivate static let linkWorkspaceB = "b2222222-2222-4222-8222-222222222222"
    fileprivate static let linkPanelA = "a3333333-3333-4333-8333-333333333333"
    fileprivate static let linkPanelB = "b3333333-3333-4333-8333-333333333333"

    fileprivate func makeLinkSocket() throws -> CapturedCLISocket {
        let socket = try CapturedCLISocket()
        socket.reply { request in
            let params = request["params"] as? [String: Any] ?? [:]
            switch request["method"] as? String {
            case "window.list":
                return ["windows": [
                    ["id": Self.linkWindowA, "ref": "window:1", "index": 0],
                    ["id": Self.linkWindowB, "ref": "window:2", "index": 1],
                ]]
            case "workspace.list":
                if params["window_id"] as? String == Self.linkWindowA {
                    return ["workspaces": [["id": Self.linkWorkspaceA, "ref": "workspace:1", "index": 0, "title": "First project"]]]
                }
                if params["window_id"] as? String == Self.linkWindowB {
                    return ["workspaces": [["id": Self.linkWorkspaceB, "ref": "workspace:2", "index": 0, "title": "Second\nproject"]]]
                }
                return ["workspaces": []]
            case "panel.list":
                if params["workspace_id"] as? String == Self.linkWorkspaceA,
                   params["window_id"] as? String == Self.linkWindowA {
                    return ["panels": [["id": Self.linkPanelA, "ref": "panel:1", "index": 0, "title": "First agent"]]]
                }
                if params["workspace_id"] as? String == Self.linkWorkspaceB,
                   params["window_id"] as? String == Self.linkWindowB {
                    return ["panels": [["id": Self.linkPanelB, "ref": "panel:2", "index": 0, "title": "[Agent]\u{1B}\u{07}\nTwo"]]]
                }
                return ["panels": []]
            default: return nil
            }
        }
        return socket
    }

    fileprivate func assertLinkInventoryOnly(_ socket: CapturedCLISocket, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(socket.waitUntilFinished(), file: file, line: line)
        let allowed: Set<String> = ["system.capabilities", "window.list", "workspace.list", "panel.list"]
        let unexpected = socket.requests.filter { !allowed.contains($0["method"] as? String ?? "") }
        XCTAssertTrue(unexpected.isEmpty, "Unexpected link requests: \(unexpected)", file: file, line: line)
    }


    func testMailboxSendWithoutACallerPanelNamesTheMissingPanel() throws {
        // C11-480 (ov-459): the error is localized and says what is wrong
        // with C11_PANEL_ID, whether it is absent or not a UUID.
        for panel in [nil, "not-a-uuid"] as [String?] {
            let socket = try CapturedCLISocket()
            var environment = ["C11_WORKSPACE_ID": Self.linkWorkspaceA]
            if let panel { environment["C11_PANEL_ID"] = panel }
            guard let result = runCLI(["mailbox", "send", "--to", "peer", "hello"],
                                      socketPath: socket.path, environmentOverrides: environment) else { return }
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderr.contains("C11_PANEL_ID is missing or is not a valid panel UUID. Pass --from <panel> to override."),
                          "\(panel ?? "unset"): \(result.stderr)")
        }
    }



}

// MARK: - C11-334: declared flags match what each parser reads

extension CLIResolutionTestCase {
    fileprivate static let declPanelID = "ddd11111-2222-3333-4444-555566667777"
    fileprivate static let declWorkspaceID = "11111111-2222-3333-4444-555566667777"

    /// Argv that c11 1.1.3 accepted and the r1/r2 reviews of PR #737 found
    /// rejected: trailing `--json`, `--name=value`, parser-read aliases, and
    /// words the parser takes as text. Run with no socket, so nothing mutates;
    /// a preflight rejection is the only "unknown flag" these can print.
    fileprivate static let previouslyAcceptedArgv: [[String]] = [
        // r1 kit
        ["set-status", "k", "v", "--panel", "panel:1"], ["set-status", "k", "v", "--tab", "panel:1"],
        ["set-status", "k", "v", "--panel=panel:1"], ["set-status", "k", "v", "--priority", "5"],
        ["set-status", "k", "v", "--url", "http://x"], ["set-status", "k", "v", "--format", "markdown"],
        ["set-progress", "0.5", "--panel", "panel:1"], ["log", "--panel", "panel:1", "msg"],
        ["log", "--level", "error", "--panel", "panel:1", "--", "msg"], ["clear-status", "k", "--panel", "panel:1"],
        ["identify", "--json"], ["capabilities", "--json"], ["read-selection", "--panel", "panel:1", "--json"],
        ["list-panels", "--json"], ["sidebar-state", "--json"], ["drag-panel-to-split", "--panel", "panel:1", "right", "--json"],
        ["refresh-panels", "--json"], ["new-split", "right", "--json"], ["focus-panel", "--panel", "panel:1", "--json"],
        ["raise-flag", "--panel", "panel:1", "--json", "why"], ["raise-flag", "--workspace", "workspace:1", "--panel", "panel:1", "why"],
        ["lower-flag", "--window", "window:1", "--panel", "panel:1"], ["clear-notifications", "--workspace", "workspace:1"],
        ["set-metadata", "--panel", "panel:1", "--json-input", "{\"a\":1}"], ["set-metadata", "--panel", "panel:1", "--body", "{\"a\":1}"],
        ["get-metadata", "--panel", "panel:1", "--include-sources"], ["get-workspace-metadata", "--key", "description"],
        ["set-workspace-description", "--value", "hello"], ["set-workspace-icon", "--value", "x"],
        ["browser", "panel:1", "scroll", "--dy", "800", "--snapshot-after"],
        ["set-status", "k", "- item"], ["set-status", "k", "-3", "failing"], ["set-status", "k", "--", "-3", "failing"],
        ["log", "- bullet"], ["set-title", "--panel", "panel:1", "--", "-draft"],
        ["browser", "panel:1", "type", "sel", "--", "--literal"], ["browser", "panel:1", "fill", "sel", "--", "--x"],
        ["__tmux-compat", "select-layout", "-t", "@1", "tiled"],
        ["__tmux-compat", "set-option", "-p", "-t", "%1", "pane-border-style", "fg=blue"],
        ["new-split", "right", "--force"], ["new-area", "right", "--force"], ["restore", "snap", "--replace"],
        // r2 kit
        ["tree", "--json"], ["tree", "--all", "--json"], ["family", "--json"], ["family", "--panel", "panel:1", "--json"],
        ["agents", "--json"], ["doctor", "--json"], ["health", "--json"], ["guide", "--json"], ["guide", "api", "--json"],
        ["list-snapshots", "--json"], ["reorder-workspaces", "--order", "workspace:1", "--dry-run", "--json"],
        ["get-metadata", "--panel", "panel:1", "--json"], ["get-workspace-metadata", "--json"],
        ["clear-workspace-metadata", "--key", "k", "--json"], ["markdown-content", "--panel", "panel:1", "--json"],
        ["ping", "--json"], ["list-windows", "--json"], ["current-workspace", "--json"], ["list-areas", "--json"],
        ["list-area-panels", "--json"], ["close-panel", "--panel", "panel:1", "--json"],
        ["send", "--panel", "panel:1", "hi", "--json"], ["notify", "--title", "t", "--json"],
        ["set-agent", "--panel", "panel:1", "--type", "claude-code", "--json"], ["themes", "list", "--json"],
        ["events", "tail", "--json"], ["capture-pane", "--panel", "panel:1", "--json"],
        ["get-metadata", "--panel", "panel:1", "--key=title"], ["clear-metadata", "--panel", "panel:1", "--key=title"],
        ["clear-workspace-metadata", "--key=description"], ["config", "stats", "--window=7d"], ["config", "stats", "--by=harness"],
        ["skill", "status", "--tool=claude"],
        ["usage", "--since=1d", "--state-root=/nonexistent-c11-334", "--claude-root=/nonexistent-c11-334", "--codex-root=/nonexistent-c11-334"],
        ["conversation", "claim", "--panel", "panel:1", "--kind", "claude-code", "--id", "abc"],
        ["conversation", "tombstone", "--tab", "panel:1", "--kind", "claude-code", "--id", "abc"],
        ["feed", "--tab", "panel:1", "open"], ["browser", "panel:1", "scrollintoview", "--selector", "#x"],
        ["browser", "--panel", "panel:1", "scrollinto", "#x", "--snapshot-after"],
        ["respawn-pane", "--panel", "panel:1", "ls", "-la"], ["pipe-pane", "--panel", "panel:1", "grep", "-v", "foo"],
        ["set-hook", "pane-exited", "echo", "-n", "done"],
        ["__tmux-compat", "send-keys", "-t", "%1", "git", "log", "--oneline", "Enter"],
        ["__tmux-compat", "split-window", "-v", "npm", "run", "dev", "--port", "3000"],
        // r2 grok and the r2 text-region findings
        ["rpc", "system.capabilities", "--json"], ["paste", "--json", "hello"],
        ["clear-metadata", "--key", "title", "--json"], ["clear-workspace-metadata", "description", "--json"],
        ["browser", "panel:1", "type", "#q", "--verbose"], ["browser", "panel:1", "fill", "#q", "hello", "--world"],
        ["browser", "panel:1", "dialog", "accept", "--force"], ["browser", "panel:1", "addscript", "x", "=", "--y"],
        ["notify", "--title", "t", "--body", "-body"],
    ]








    /// One argv per command path. A parser queries every option name on the
    /// path it takes, present or not, so one run checks the whole path.
    fileprivate static let declarationPaths: [[String]] = {
        let p = declPanelID
        let w = declWorkspaceID
        return [
            ["ping"], ["capabilities"], ["brand"], ["identify"], ["list-windows"], ["current-window"],
            ["focus-window", "--window", "window:1"], ["move-workspace-to-window", "--workspace", w, "--window", "window:1"],
            ["move-panel", "--panel", p, "--workspace", w], ["reorder-panel", "--panel", p, "--index", "0"],
            ["reorder-workspace", "--workspace", w, "--index", "0"], ["reorder-workspaces", "--order", w, "--dry-run"],
            ["workspace-group", "list"], ["workspace-group", "create", "--name", "g"],
            ["workspace-action", "--action", "pin", "--workspace", w], ["panel-action", "--action", "pin", "--panel", p],
            ["rename-panel", "--panel", p, "title"], ["set-title", "--panel", p, "t"], ["set-description", "--panel", p, "d"],
            ["set-panel-icon", "--panel", p, "x"], ["set-panel-color", "--panel", p, "teal"], ["get-titlebar-state", "--panel", p],
            ["list-workspaces"], ["snapshot", "--workspace", w], ["list-snapshots"], ["new-workspace", "--title", "t"],
            ["new-split", "right", "--panel", p], ["list-areas"], ["list-area-panels"], ["tree"], ["tree", "--all"],
            ["family", "--panel", p], ["focus-area", "--area", "area:1"], ["new-area", "right"],
            ["launch-agent", "--type", "codex", "--workspace", w], ["raise-flag", "--panel", p, "why"], ["lower-flag", "--panel", p],
            ["delegate", "--panel", p], ["new-panel", "--type", "terminal"], ["close-panel", "--panel", p],
            ["area-confirm", "--panel", p, "--title", "t"], ["drag-panel-to-split", "--panel", p, "right"], ["refresh-panels"],
            ["panel-health"], ["trigger-flash", "--panel", p], ["cancel-flash", "--panel", p], ["list-panels"],
            ["focus-panel", "--panel", p], ["close-workspace", "--workspace", w], ["select-workspace", "--workspace", w],
            ["rename-workspace", "--workspace", w, "name"], ["rename-window", "name"],
            ["set-workspace-root", "--workspace", w, "/tmp"], ["get-workspace-root", "--workspace", w], ["current-workspace"],
            ["read-selection", "--panel", p], ["input-state", "--panel", p], ["retry-input", "--panel", p], ["read-screen", "--panel", p],
            ["send", "--panel", p, "--workspace", w, "hi"], ["paste", "--panel", p, "--workspace", w, "hi"],
            ["send-key", "--panel", p, "--workspace", w, "enter"], ["notify", "--title", "t"],
            ["feed", "list"], ["feed", "open", p], ["list-notifications"], ["clear-notifications"],
            ["set-status", "k", "v"], ["clear-status", "k"], ["list-status"], ["set-progress", "0.5"], ["clear-progress"],
            ["log", "msg"], ["clear-log"], ["list-log"], ["sidebar-state"], ["set-agent", "--panel", p, "--type", "codex"],
            ["set-metadata", "--panel", p, "--key", "k", "--value", "v"], ["get-metadata", "--panel", p],
            ["clear-metadata", "--panel", p, "--key", "k"], ["set-workspace-metadata", "--key", "k", "--value", "v"],
            ["get-workspace-metadata"], ["clear-workspace-metadata", "--key", "k"],
            ["set-workspace-description", "--value", "d"], ["set-workspace-icon", "--value", "x"],
            ["conversation", "get", "--panel", p], ["conversation", "list"], ["conversation", "claim", "--panel", p, "--kind", "codex", "--id", "abc"],
            ["conversation", "push", "--panel", p, "--kind", "codex", "--id", "abc"],
            ["conversation", "tombstone", "--panel", p, "--kind", "codex", "--id", "abc"],
            ["app", "status"], ["capture-pane", "--panel", p], ["resize-pane", "--pane", "area:1", "-L"],
            ["pipe-pane", "--panel", p, "--command", "cat"], ["swap-pane", "--pane", "area:1", "--target-pane", "area:2"],
            ["last-pane"], ["clear-history", "--panel", p], ["paste-buffer", "--name", "missing-c11-334"],
            ["respawn-pane", "--panel", p, "true"], ["display-message", "-p", "hi"],
            ["browser", p, "url"], ["browser", p, "snapshot"], ["browser", p, "eval", "1"], ["browser", p, "wait", "--selector", "x"],
            ["browser", p, "click", "#x"], ["browser", p, "type", "#x", "hi"], ["browser", p, "press", "enter"],
            ["browser", p, "select", "#x", "v"], ["browser", p, "scroll", "--dy", "1"], ["browser", p, "get", "text", "#x"],
            ["browser", p, "get", "attr", "#x", "--attr", "a"], ["browser", p, "is", "visible", "#x"],
            ["browser", p, "find", "role", "button"], ["browser", p, "frame", "main"], ["browser", p, "dialog", "dismiss"],
            ["browser", p, "cookies", "get"], ["browser", p, "storage", "local", "get"], ["browser", p, "panel", "list"],
            ["browser", p, "console", "list"], ["browser", p, "highlight", "#x"], ["browser", p, "addscript", "1"],
            ["browser", p, "network", "requests"], ["browser", p, "keep-live", "status"], ["browser", "identify"],
            ["browser", "profiles", "list"], ["open-browser", "https://example.invalid"], ["get-url", "--panel", p],
            ["markdown", "visible", "--panel", p], ["markdown", "links", "--panel", p], ["markdown-content", "--panel", p],
            ["themes", "list"], ["workspace-color", "get"], ["panel-color", "get", "--panel", p],
            ["mailbox", "inbox-dir", "--panel", p], ["mailbox", "view"], ["messages", "view"],
            ["workspace", "recents", "list"], ["guide"], ["history", "--limit", "1"],
            ["config", "list"], ["config", "stats"], ["config", "launch", "missing-c11-334"],
            ["doctor"], ["health"], ["agents"], ["events", "tail"], ["journal", "query"], ["skill", "status"],
            ["model-costs", "list"], ["report"], ["state", "verify"], ["default-agent", "launch"], ["new-window"],
            ["close-window", "--window", "window:1"], ["workspace-group", "add", "--group", "g", "--workspaces", w],
            ["themes", "get"], ["ui", "themes", "list"], ["set-app-focus", "clear"], ["simulate-app-active"],
            ["ssh-session-end", "--relay-port", "1"], ["mailbox", "recv", "--peek"], ["markdown", "open", "/tmp/c11-334.md"],
            ["workspace", "export-blueprint", "--workspace", w, "--out", "/dev/null"], ["get-titlebar-state"],
            ["resize-window", "--window", "window:1", "10", "10"], ["break-pane", "--pane", "area:1"],
            // C11H-197: window names, placement, displays, window themes.
            ["window", "list"], ["window", "name", "--window", "window:1", "--clear"],
            ["window", "move", "--window", "window:1", "--fill"], ["display", "list"],
            ["themes", "get", "--window", "window:1"],
            ["join-pane", "--target-pane", "area:1"], ["browser", p, "screenshot", "--out", "/dev/null"],
            ["browser", p, "download", "--path", "/dev/null"], ["browser", p, "dom", "--selector", "x"],
            ["browser", p, "locator", "--selector", "x"], ["browser", p, "back"], ["browser", p, "goto", "https://example.invalid"],
        ]
    }()

    /// Names a parser reads only to reject them, keyed by command path.
    /// Preflight rejects them before discovery instead: same outcome, earlier.
    fileprivate static let readOnlyToReject: [String: Set<String>] = [
        // "--workspace is not supported in v1"
        "conversation list": ["--workspace"],
        // `feed` takes these before its verb, then rejects the ones a verb does not use.
        "feed list": ["--panel", "--surface", "--tab", "--workspace"],
        "feed open": ["--scope"],
        // Markdown agent verbs reject routing flags other than --panel.
        "markdown links": ["--area", "--pane", "--window", "--workspace"],
        "markdown visible": ["--area", "--pane", "--window", "--workspace"],
    ]

    /// One run of every declaration path, shared by the two whole-surface
    /// tests in this class so the surface is walked once per test process
    /// (C11H-30). Each path is its own CLI process, socket and log; run them
    /// side by side so the whole command surface fits the run budget.
    fileprivate static let declarationWalkLock = NSLock()
    fileprivate static var declarationWalkCache: [([String], DeclarationRunResult)]?
    fileprivate static func declarationWalk(cli: URL) throws -> [([String], DeclarationRunResult)] {
        declarationWalkLock.lock(); defer { declarationWalkLock.unlock() }
        if let cached = declarationWalkCache { return cached }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11-334-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = declarationPaths
        let lock = NSLock()
        var results = [DeclarationRunResult?](repeating: nil, count: paths.count)
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let run = declarationRun(argv: paths[index], cli: cli, directory: directory) { try CapturedCLISocket() }
            lock.lock(); results[index] = run; lock.unlock()
        }
        let walk = zip(paths, results.map { $0! }).map { ($0, $1) }
        declarationWalkCache = walk
        return walk
    }

    /// Runs one path with the read log on. Returns nil when every name the
    /// parser read is declared and the path declares its positional arity,
    /// else a line naming what is wrong.
    fileprivate static func declarationFinding(argv: [String], result: DeclarationRunResult) -> String? {
        switch result {
        case .failure(let message):
            return message
        case .success(let run):
            let label = argv.joined(separator: " ")
            var problems: [String] = []
            let undeclared = run.queried
                .subtracting(run.accepted)
                .subtracting(readOnlyToReject.first(where: { label.hasPrefix($0.key + " ") || label == $0.key })?.value ?? [])
                .subtracting(["--help", "-h"])
            if !undeclared.isEmpty { problems.append("parser reads \(undeclared.sorted()) not declared") }
            if run.arity == "unchecked" { problems.append("no positional arity declared") }
            return problems.isEmpty ? nil : "\(label): " + problems.joined(separator: "; ")
        }
    }

    fileprivate struct DeclarationRun {
        var stderr: String
        var queried: Set<String>
        var accepted: Set<String>
        var arity: String
        var positionals: Int
        var requests: [[String: Any]]
    }

    fileprivate enum DeclarationRunResult {
        case success(DeclarationRun)
        case failure(String)
    }

    fileprivate static func declarationRun(
        argv: [String],
        cli: URL,
        directory: URL,
        expectRejection: Bool = false,
        makeSocket: () throws -> CapturedCLISocket
    ) -> DeclarationRunResult {
        let label = argv.joined(separator: " ")
        guard let socket = try? makeSocket() else { return .failure("\(label): could not create a fake socket") }
        let log = directory.appendingPathComponent("\(UUID().uuidString).json")
        let process = Process()
        process.executableURL = cli
        process.arguments = ["--socket", socket.path] + argv
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("C11_") || key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["C11_CLI_FLAG_READ_LOG"] = log.path
        environment["C11_WORKSPACE_ID"] = declWorkspaceID
        environment["C11_PANEL_ID"] = declPanelID
        environment["HOME"] = directory.path
        // Foundation's home ignores HOME; without this, `report` reads the host's real state.
        environment["CFFIXED_USER_HOME"] = directory.path
        process.environment = environment
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failure("\(label): could not run the CLI: \(error)") }
        if exited.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            return .failure("\(label): CLI did not exit within 15 seconds")
        }
        let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if expectRejection {
            // A rejected argv never connects. The CLI has exited, so a
            // connection it did make is already queued: wait for the server
            // to finish reading it, or a short moment when there is none.
            _ = socket.waitUntilFinished(timeout: 0.1)
            return .success(DeclarationRun(stderr: errorText, queried: [], accepted: [], arity: "", positionals: 0, requests: socket.requests))
        }
        if errorText.localizedCaseInsensitiveContains("unknown flag")
            || errorText.localizedCaseInsensitiveContains("unexpected argument") {
            return .failure("\(label): rejected by preflight: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let data = try? Data(contentsOf: log),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queried = object["queried"] as? [String],
              let acceptedByCommand = object["accepted"] as? [String: [String]],
              let arityByCommand = object["arity"] as? [String: String],
              let positionalsByCommand = object["positionals"] as? [String: Int],
              let command = acceptedByCommand.keys.first else {
            return .failure("\(label): no read log (the path wrote no declaration)")
        }
        return .success(DeclarationRun(
            stderr: errorText,
            queried: Set(queried),
            accepted: Set(acceptedByCommand.values.flatMap { $0 }),
            arity: arityByCommand[command] ?? "unchecked",
            positionals: positionalsByCommand[command] ?? 0,
            requests: socket.requests
        ))
    }

}

// MARK: - C11-481: positional arity and explicit close targets

extension CLIResolutionTestCase {
    fileprivate static let closeCaller = "ddd11111-2222-3333-4444-555566667777"
    fileprivate static let closeOther = "eee11111-2222-3333-4444-555566667777"
    fileprivate static let closeWorkspace = "11111111-2222-3333-4444-555566667777"

    fileprivate func runClose(_ argv: [String], environment: [String: String]? = nil, configure: (CapturedCLISocket) -> Void = { _ in })
        -> (result: (status: Int32, stdout: String, stderr: String), socket: CapturedCLISocket)? {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return nil
        }
        configure(socket)
        let env = environment ?? ["C11_PANEL_ID": Self.closeCaller, "C11_WORKSPACE_ID": Self.closeWorkspace]
        guard let result = runCLI(argv, socketPath: socket.path, environmentOverrides: env) else { return nil }
        return (result, socket)
    }








    fileprivate func identityInstances(_ stdout: String) throws -> [String] {
        let object = try identityJSONObject(stdout)
        return try XCTUnwrap(object["instances"] as? [String])
    }

    fileprivate func identityHealthPaths(_ stdout: String) throws -> [String] {
        let object = try identityJSONObject(stdout)
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        return events.compactMap { $0["path"] as? String }
    }

    fileprivate func identityStringField(_ stdout: String, key: String) throws -> String {
        let object = try identityJSONObject(stdout)
        return try XCTUnwrap(object[key] as? String)
    }

    fileprivate func identityJSONObject(_ stdout: String) throws -> [String: Any] {
        let data = Data(stdout.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - CLIResolutionSnapshotTests

final class CLIResolutionSnapshotTests: CLIResolutionTestCase {}

extension CLIResolutionSnapshotTests {
    func testClosePanelExpectedTitleIsSentAndSuccessNamesTheRequestedPanel() {
        let panelID = "e1111111-2222-3333-4444-555566667777"
        let panelRef = "panel:224"
        let workspaceID = "f2222222-3333-4444-8555-666677778888"
        let title = "Theme \"Engine\"\nLead"
        guard let run = runClose(
            ["close-panel", "--panel", panelID, "--expect-title", title],
            configure: {
                $0.reply(to: "panel.close", with: [
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:1",
                    "panel_id": panelID,
                    "panel_ref": panelRef,
                    "panel_title": title,
                    "session_end": "none",
                ])
            }
        ) else { return }

        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        XCTAssertEqual(run.result.stdout, "OK \(panelRef) workspace:1 \(panelID) \"Theme \\\"Engine\\\"\\nLead\"\n")
        XCTAssertTrue(run.socket.waitUntilFinished())
        let close = run.socket.requests.first(where: { $0["method"] as? String == "panel.close" })
        let params = close?["params"] as? [String: Any]
        XCTAssertEqual(params?["expected_title"] as? String, title)
        XCTAssertEqual(params?["panel_id"] as? String, panelID)
    }

    func testClosePanelExpectedTitleDoesNotRepeatUUIDWithUUIDIdFormat() {
        let panelID = "e1111111-2222-3333-4444-555566667777"
        let workspaceID = "f2222222-3333-4444-8555-666677778888"
        let title = "Theme Engine Lead"
        guard let run = runClose(
            ["close-panel", "--panel", panelID, "--expect-title", title, "--id-format", "uuids"],
            configure: {
                $0.reply(to: "panel.close", with: [
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:1",
                    "panel_id": panelID,
                    "panel_ref": "panel:224",
                    "panel_title": title,
                    "session_end": "none",
                ])
            }
        ) else { return }

        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        XCTAssertEqual(run.result.stdout, "OK \(panelID) \(workspaceID) \"\(title)\"\n")
        XCTAssertTrue(run.socket.waitUntilFinished())
    }

    func testStatusOkWhenBundledAndPathAgree() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/Applications/c11.app/Contents/Resources/bin:/usr/local/bin:/usr/bin",
            ],
            commands: ["c11": bundled, "cmux": nil],
            existing: [bundled]
        ))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertTrue(snapshot.pathFixApplied)
        XCTAssertEqual(snapshot.bundledCliPath, bundled)
        XCTAssertEqual(snapshot.c11OnPath, bundled)
        XCTAssertNil(snapshot.cmuxOnPath)
        XCTAssertTrue(snapshot.notes.isEmpty)
    }

    func testStatusMismatchWhenC11OnPathIsNotBundled() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let stale = "/usr/local/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/usr/local/bin:/usr/bin",
            ],
            commands: ["c11": stale, "cmux": nil],
            existing: [bundled, stale]
        ))
        XCTAssertEqual(snapshot.status, .mismatch)
        XCTAssertFalse(snapshot.pathFixApplied, "bundled bin dir is not first on PATH")
        XCTAssertEqual(snapshot.c11OnPath, stale)
        XCTAssertTrue(snapshot.notes.contains(where: { $0.contains("not the active bundle") }))
    }

    func testStatusNoBundleWhenEnvUnset() {
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: ["PATH": "/usr/local/bin:/usr/bin"],
            commands: ["c11": "/usr/local/bin/c11", "cmux": "/usr/local/bin/cmux"]
        ))
        XCTAssertEqual(snapshot.status, .noBundle)
        XCTAssertNil(snapshot.bundledCliPath)
        XCTAssertEqual(snapshot.c11OnPath, "/usr/local/bin/c11")
        XCTAssertTrue(snapshot.notes.contains(where: { $0.contains("CMUX_BUNDLED_CLI_PATH") }))
    }

    func testCmuxNoteFiresWhenUpstreamCmuxOnPath() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let upstreamCmux = "/opt/homebrew/bin/cmux"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/Applications/c11.app/Contents/Resources/bin:/opt/homebrew/bin",
            ],
            commands: ["c11": bundled, "cmux": upstreamCmux],
            existing: [bundled, upstreamCmux]
        ))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.cmuxOnPath, upstreamCmux)
        XCTAssertTrue(
            snapshot.notes.contains(where: { $0.contains("intentional") }),
            "Doctor should explain that an upstream cmux is intentional, not a bug"
        )
    }

    func testWhitespaceAroundEnvValuesIsTolerated() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": "  \(bundled)  ",
                "PATH": "/Applications/c11.app/Contents/Resources/bin:/usr/bin",
            ],
            commands: ["c11": "  \(bundled)\n", "cmux": nil],
            existing: [bundled]
        ))
        XCTAssertEqual(snapshot.bundledCliPath, bundled)
        XCTAssertEqual(snapshot.c11OnPath, bundled)
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testJSONShapeIsStable() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/Applications/c11.app/Contents/Resources/bin:/usr/bin",
            ],
            commands: ["c11": bundled, "cmux": nil],
            existing: [bundled],
            versions: [bundled: "0.46.0"]
        ))
        let dict = snapshot.toJSONDictionary()

        XCTAssertEqual(dict["status"] as? String, "ok")
        XCTAssertEqual(dict["bundled_cli_path"] as? String, bundled)
        XCTAssertEqual(dict["c11_on_path"] as? String, bundled)
        XCTAssertEqual(dict["bundled_cli_version"] as? String, "0.46.0")
        XCTAssertEqual(dict["c11_on_path_version"] as? String, "0.46.0")
        XCTAssertEqual(dict["path_fix_applied"] as? Bool, true)
        XCTAssertEqual(dict["path"] as? [String], [
            "/Applications/c11.app/Contents/Resources/bin",
            "/usr/bin",
        ])
        XCTAssertEqual(dict["notes"] as? [String], [])
        XCTAssertNil(dict["cmux_on_path"], "Omit unset fields rather than serialize null")
    }

    func testJSONOmitsAbsentBundleAndCommands() {
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: ["PATH": "/usr/bin"]
        ))
        let dict = snapshot.toJSONDictionary()

        XCTAssertEqual(dict["status"] as? String, "no_bundle")
        XCTAssertNil(dict["bundled_cli_path"])
        XCTAssertNil(dict["c11_on_path"])
        XCTAssertNil(dict["cmux_on_path"])
    }

    func testParseDoctorArgsDefault() throws {
        let opts = try parseDoctorCLIArgs([])
        XCTAssertFalse(opts.json)
    }

    func testParseDoctorArgsJsonFlag() throws {
        let opts = try parseDoctorCLIArgs(["--json"])
        XCTAssertTrue(opts.json)
    }

    func testParseDoctorArgsTolerablesHelp() throws {
        // Help is dispatched upstream; the parser should not error on it.
        let opts = try parseDoctorCLIArgs(["--help"])
        XCTAssertFalse(opts.json)
    }

    func testCodexCleanDecisionEmitsExactResumeCommand() {
        XCTAssertEqual(
            ResumeDecisionEngine.decide(resumeInput(mode: .clean, transcript: .notRequired)),
            .command(ResumeCommand(text: "codex resume --yolo '\(codexID)'"))
        )
    }

    func testNoResumeOverridesUnauditedOwnership() {
        guard case .skip(let code, _) = ResumeDecisionEngine.decide(
            resumeInput(mode: .noResume, ownership: .unaudited)
        ) else {
            return XCTFail("no-resume must always skip")
        }
        XCTAssertEqual(code, .policyNoResume)
    }

    func testUnsafeIdentityIsATypedSkip() {
        guard case .skip(let duplicate, _) = ResumeDecisionEngine.decide(
            resumeInput(mode: .clean, ownership: .duplicate)
        ) else {
            return XCTFail("duplicate ownership must skip")
        }
        XCTAssertEqual(duplicate, .duplicateOwnership)

        guard case .skip(let placeholder, _) = ResumeDecisionEngine.decide(
            resumeInput(mode: .clean, placeholder: true)
        ) else {
            return XCTFail("placeholder must skip")
        }
        XCTAssertEqual(placeholder, .placeholder)
    }

    func testDelayedFinalStoreReadReturnsCompletedValueNotEmptyFallback() {
        let outcome: BoundedLifecycleOutcome<[String: String]> = BoundedLifecycleWait.run(
            timeout: 1.0
        ) {
            try await Task.sleep(nanoseconds: 20_000_000)
            return ["surface-1": "newly-resolved-exact-id"]
        }
        guard case .completed(let rows) = outcome else {
            return XCTFail("delayed read within budget must complete")
        }
        XCTAssertEqual(rows, ["surface-1": "newly-resolved-exact-id"])
    }

    func testDelayedDurableWriteMustCompleteBeforeCleanPromotion() {
        XCTAssertFalse(CleanPersistencePromotionPolicy.allowsPromotion(
            resolutionCompleted: true,
            finalStoreReadCompleted: true,
            durableSnapshotWriteCompleted: false
        ))

        let outcome: BoundedLifecycleOutcome<Bool> = BoundedLifecycleWait.run(timeout: 1.0) {
            try await Task.sleep(nanoseconds: 20_000_000)
            return true
        }
        guard case .completed(let durable) = outcome else {
            return XCTFail("durable write should complete inside budget")
        }
        XCTAssertTrue(CleanPersistencePromotionPolicy.allowsPromotion(
            resolutionCompleted: true,
            finalStoreReadCompleted: true,
            durableSnapshotWriteCompleted: durable
        ))
    }

    func testValidAliasesAndOmittedPanelRefsReachReadRequest() {
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let cases: [(flag: String, reference: String, expectedPanelID: String)] = [
            ("--panel", codexID, codexID),
            ("--surface", "panel:1", "panel:1"),
            ("--tab", "1", "panel:1"),
        ]
        for item in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                ["read-screen", "--workspace", workspaceID, item.flag, item.reference],
                socketPath: socket.path,
                environmentOverrides: ["C11_TRACE": "1"]
            ) else { return }
            XCTAssertEqual(result.status, 0, "\(result.stderr) requests=\(socket.requests)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving")
            let read = socket.requests.first(where: { $0["method"] as? String == "panel.read_text" })
            let params = read?["params"] as? [String: Any]
            XCTAssertEqual(params?["panel_id"] as? String, item.expectedPanelID)
            XCTAssertEqual(params?["workspace_id"] as? String, workspaceID)
        }

        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["read-screen"],
            socketPath: socket.path,
            environmentOverrides: [
                "C11_TRACE": "1",
                "CMUX_WORKSPACE_ID": workspaceID,
                "C11_PANEL_ID": codexID,
            ]
        ) else { return }
        XCTAssertEqual(result.status, 0, "\(result.stderr) requests=\(socket.requests)")
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving")
        let read = socket.requests.first(where: { $0["method"] as? String == "panel.read_text" })
        let params = read?["params"] as? [String: Any]
        XCTAssertEqual(params?["panel_id"] as? String, codexID)
        // C11-491: the environment's workspace goes stale when the panel
        // moves, and c11 finds a panel UUID in any workspace.
        XCTAssertNil(params?["workspace_id"])

        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["browser", "panel:1", "eval", "--panel", "--json"],
            socketPath: socket.path
        ) else { return }
        XCTAssertEqual(result.status, 0, "\(result.stderr) requests=\(socket.requests)")
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving")
        let eval = socket.requests.first(where: { $0["method"] as? String == "browser.eval" })
        let evalParams = eval?["params"] as? [String: Any]
        XCTAssertEqual(evalParams?["panel_id"] as? String, "panel:1")
        XCTAssertEqual(evalParams?["script"] as? String, "--panel")

        let browserReads: [(command: [String], method: String)] = [
            (["browser", "panel:1", "wait", "--selector", ".ready"], "browser.wait"),
            (["browser", "--panel", "panel:1", "wait", "--selector", ".ready"], "browser.wait"),
            (["browser", "panel:1", "screenshot"], "browser.screenshot"),
            (["browser", "--surface", "panel:1", "screenshot"], "browser.screenshot"),
            (["browser", "panel:1", "console", "list"], "browser.console.list"),
            (["browser", "--tab", "panel:1", "console", "list"], "browser.console.list"),
            (["browser", "panel:1", "errors", "list"], "browser.errors.list"),
            (["browser", "--panel", "panel:1", "errors", "list"], "browser.errors.list"),
        ]
        for item in browserReads {
            guard assertBrowserReadReachesSocket(item.command, method: item.method) else { return }
        }
    }

    func testPanelPreflightMatchesCommandOptionBoundaries() {
        guard let help = runCLI(["read-screen", "--help", "--panel"]) else { return }
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.contains("Usage: c11 read-screen"))
        XCTAssertEqual(help.stderr, "")

        guard let missing = runCLI(["identify", "--title", "--panel"]) else { return }
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertEqual(missing.stderr, "Error: --panel requires a value\n")

        guard let emptyAfterTerminator = runCLI(["identify", "--", "--panel", ""]) else { return }
        XCTAssertEqual(emptyAfterTerminator.status, 1)
        XCTAssertEqual(emptyAfterTerminator.stdout, "")
        XCTAssertEqual(emptyAfterTerminator.stderr, "Error: empty_ref: --panel was provided but empty\n")

        guard let missingPanelAfterMissingEvent = runCLI(["mailbox", "recv", "--event", "--panel"]) else { return }
        XCTAssertEqual(missingPanelAfterMissingEvent.status, 1)
        XCTAssertEqual(missingPanelAfterMissingEvent.stdout, "")
        XCTAssertEqual(missingPanelAfterMissingEvent.stderr, "Error: --panel requires a value\n")

    }

    func testBrowserStatePathMayLookLikePanelFlag() {
        for verb in ["save", "load"] {
            guard let result = runCLI(["browser", "panel:1", "state", verb, "--panel"]) else { return }
            XCTAssertEqual(result.status, 1)
            XCTAssertFalse(result.stderr.contains("--panel requires a value"), result.stderr)
            XCTAssertFalse(result.stderr.contains("empty_ref: --panel was provided but empty"), result.stderr)
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("socket"), result.stderr)
        }
    }

    func testFlagShapedOptionValuesAreNotMistakenForPanelTargets() {
        for args in [
            ["new-workspace", "--title", "--panel"],
            ["markdown", "scroll", "--panel", "panel:1", "--heading", "--panel"],
            ["browser", "eval", "--script", "--panel"],
        ] {
            guard let result = runCLI(args) else { return }
            XCTAssertEqual(result.status, 1, result.stderr)
            XCTAssertFalse(result.stderr.contains("--panel requires a value"), result.stderr)
            XCTAssertFalse(result.stderr.contains("empty_ref: --panel was provided but empty"), result.stderr)
        }
    }

    func testMissingWorkspaceOptionValueDoesNotFallBackToCallerTarget() {
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["close-panel", "--workspace"],
            socketPath: socket.path,
            environmentOverrides: ["C11_WORKSPACE_ID": workspaceID, "C11_PANEL_ID": panelID]
        ) else { return }
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("--workspace requires a value"), result.stderr)
        XCTAssertFalse(
            socket.requests.contains(where: { $0["method"] as? String == "panel.close" }),
            "missing --workspace value fell back to the caller target: \(socket.requests)"
        )
    }

    func testWorkspaceMetadataJSONTypesEmptyReplaceAndSourcesReachSocket() throws {
        let workspaceID = UUID().uuidString
        let cases: [([String], String, ([String: Any]) -> Void)] = [
            (["set-workspace-metadata", "--json-input", "{}", "--mode", "replace", "--json"], "workspace.set_metadata", {
                XCTAssertEqual(($0["metadata"] as? [String: Any])?.count, 0)
                XCTAssertEqual($0["mode"] as? String, "replace")
            }),
            (["set-workspace-metadata", "--json", "{\"items\":[1,true,null],\"nested\":{\"ok\":true}}"], "workspace.set_metadata", {
                let metadata = $0["metadata"] as? [String: Any]
                XCTAssertEqual((metadata?["items"] as? [Any])?.count, 3)
                XCTAssertTrue((metadata?["nested"] as? [String: Bool])?["ok"] == true)
            }),
            (["set-workspace-metadata", "--key", "done", "--value", "true", "--type", "bool", "--source", "declare"], "workspace.set_metadata", {
                XCTAssertEqual(($0["metadata"] as? [String: Bool])?["done"], true)
                XCTAssertEqual($0["source"] as? String, "declare")
            }),
            (["set-workspace-metadata", "amount", "0.25", "--type", "number"], "workspace.set_metadata", {
                XCTAssertEqual(($0["metadata"] as? [String: Double])?["amount"], 0.25)
            }),
            (["set-workspace-metadata", "optional", "null", "--type", "json"], "workspace.set_metadata", {
                XCTAssertTrue(($0["metadata"] as? [String: Any])?["optional"] is NSNull)
            }),
            (["get-workspace-metadata", "--key", "captain", "--key", "icon", "--sources"], "workspace.get_metadata", {
                XCTAssertEqual($0["keys"] as? [String], ["captain", "icon"])
                XCTAssertEqual($0["include_sources"] as? Bool, true)
            }),
            (["clear-workspace-metadata", "captain", "--source", "osc"], "workspace.clear_metadata", {
                XCTAssertEqual($0["keys"] as? [String], ["captain"])
                XCTAssertEqual($0["source"] as? String, "osc")
            })
        ]
        for (command, method, check) in cases {
            let socket = try CapturedCLISocket()
            guard let result = runCLI(command + ["--workspace", workspaceID], socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, result.stderr)
            let request = try XCTUnwrap(socket.requests.first { $0["method"] as? String == method })
            check(try XCTUnwrap(request["params"] as? [String: Any]))
        }
    }

    func testWorkspaceMetadataCommandsDoNotReadTheWorkspaceValueAsAKey() {
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let cases: [(command: [String], method: String, check: ([String: Any]) -> Void)] = [
            (["get-workspace-metadata", "--workspace", workspaceID], "workspace.get_metadata", { params in
                XCTAssertNil(params["key"], "a listing must not filter by the --workspace value: \(params)")
            }),
            (["get-workspace-metadata", "--workspace", workspaceID, "goal"], "workspace.get_metadata", { params in
                XCTAssertEqual(params["keys"] as? [String], ["goal"])
            }),
            (["set-workspace-metadata", "--workspace", workspaceID, "goal", "ship", "it"], "workspace.set_metadata", { params in
                XCTAssertEqual((params["metadata"] as? [String: String])?["goal"], "ship it")
            }),
            (["clear-workspace-metadata", "--workspace", workspaceID, "goal"], "workspace.clear_metadata", { params in
                XCTAssertEqual(params["keys"] as? [String], ["goal"])
            }),
            (["set-workspace-description", "--workspace", workspaceID, "hello"], "workspace.set_metadata", { params in
                XCTAssertEqual(params["key"] as? String, "description")
                XCTAssertEqual(params["value"] as? String, "hello")
            }),
        ]
        for item in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(item.command, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, "\(item.command): \(result.stderr)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(item.command)")
            guard let request = socket.requests.first(where: { $0["method"] as? String == item.method }) else {
                XCTFail("Expected \(item.method) for \(item.command), got \(socket.requests)")
                continue
            }
            let params = request["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["workspace_id"] as? String, workspaceID, "\(item.command)")
            item.check(params)
        }
    }

    func testKnownFlagsAndHiddenAliasesStillReachTheirHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [(command: [String], method: String)] = [
            (["new-workspace", "--title", "C11-334 documented flag"], "workspace.create"),
            (["new-split", "right", "--force"], "panel.split"),
            (["new-area", "right", "--force"], "area.create"),
            (["new-panel", "--no-focus"], "panel.create"),
            (["rename-panel", "--title", "C11-334 renamed panel"], "panel.action"),
            (["launch-agent", "--type", "codex", "--no-focus"], "agent.launch"),
            (["break-pane", "--no-focus"], "area.break"),
            (["join-pane", "--target-pane", "area:1", "--no-focus"], "area.join"),
            (["focus-tab", "--tab", panelID], "panel.focus"),
            (["focus-tab", "--surface", panelID], "panel.focus"),
            (["focus-area", "--pane", panelID], "area.focus"),
            (["conversation", "list", "--tab", panelID], "conversation.list"),
            (["workspace-color", "set", "--workspace", "workspace:1", "teal"], "workspace.set_custom_color"),
            (["panel-color", "get", "--workspace", "workspace:1", "--panel", panelID], "panel.list"),
            (["feed", "list", "--scope", "all", "--json"], "feed.list"),
            (["workspace", "recents", "list", "--pinned", "--json"], "workspace.recents.list"),
            (["history", "--limit", "5", "--json"], "history.list"),
            (["app", "restart", "--no-resume"], "app.restart"),
            (["restore", "snap", "--replace"], "snapshot.restore"),
            (["markdown-content", "--panel", panelID], "markdown.get_content"),
            (["ssh-session-end", "--relay-port", "1", "--workspace", "11111111-2222-3333-4444-555566667777", "--panel", panelID], "workspace.remote.terminal_session_end"),
        ]

        for item in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            let environmentOverrides = item.command.first == "restore"
                ? ["C11_WORKSPACE_ID": "11111111-2222-3333-4444-555566667777"]
                : [:]
            guard let result = runCLI(
                item.command,
                socketPath: socket.path,
                environmentOverrides: environmentOverrides
            ) else { return }
            XCTAssertEqual(result.status, 0, "\(item.command): \(result.stderr)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(item.command)")
            XCTAssertTrue(
                socket.requests.contains(where: { $0["method"] as? String == item.method }),
                "Expected \(item.method) for \(item.command), got \(socket.requests)"
            )
            if item.command.contains("--no-focus"),
               let request = socket.requests.first(where: { $0["method"] as? String == item.method }) {
                XCTAssertEqual(
                    (request["params"] as? [String: Any])?["focus"] as? Bool,
                    false,
                    "--no-focus must reach \(item.method) as focus=false"
                )
            }
        }
    }

    func testLeadingDashTextAndEndOfOptionsRemainLiteral() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let cases: [([String], String?, String?)] = [
            (["set-status", "k", "- item", "--panel", panelID], "- item", nil),
            (["set-status", "k", "-3 failing", "--panel", panelID], "-3 failing", nil),
            (["set-status", "k", "--", "-3 failing", "--panel", panelID], "-3 failing", nil),
            (["set-progress", "-0.5", "--panel", panelID], "-0.5", nil),
            (["log", "- bullet", "--panel", panelID], "- bullet", nil),
            (["send", "--", "-n"], nil, "panel.send_text"),
            (["set-title", "--panel", panelID, "--", "-draft"], nil, "panel.set_metadata"),
            (["rename-workspace", "--", "--backend"], nil, "workspace.rename"),
            (["notify", "--title", "t", "--body", "-body"], nil, "notification.create_for_panel"),
            (["browser", panelID, "type", "sel", "--", "--literal"], nil, "browser.type"),
            (["browser", panelID, "fill", "sel", "--", "--x"], nil, "browser.fill"),
        ]
        for (command, legacyText, method) in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                command,
                socketPath: socket.path,
                environmentOverrides: ["C11_WORKSPACE_ID": workspaceID, "C11_PANEL_ID": panelID]
            ) else { return }
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(command)")
            if let legacyText {
                XCTAssertTrue(
                    socket.legacyCommands.contains(where: { $0.contains(legacyText) }),
                    "Expected literal text \(legacyText.debugDescription) in \(socket.legacyCommands)"
                )
            }
            if let method {
                guard let request = socket.requests.first(where: { $0["method"] as? String == method }) else {
                    XCTFail("Expected \(method) for \(command), got \(socket.requests)")
                    continue
                }
                let params = request["params"] as? [String: Any]
                if command.first == "set-title" {
                    XCTAssertEqual((params?["metadata"] as? [String: String])?["title"], "-draft")
                } else if command.first == "notify" {
                    XCTAssertEqual(params?["title"] as? String, "t")
                    XCTAssertEqual(params?["body"] as? String, "-body")
                } else if command.first == "rename-workspace" {
                    XCTAssertEqual(params?["title"] as? String, "--backend")
                } else {
                    let expectedText = command.first == "send" ? "-n" : (command.last == "--x" ? "--x" : "--literal")
                    XCTAssertEqual(params?["text"] as? String, expectedText)
                }
            }
        }
    }

    /// C11H-392 (Opus 7 on #384): a wrong --artifacts folder is refused before
    /// the consent question, not after the operator answered it.
    func testMachineLinkRefusesAMissingArtifactsFolderBeforeAskingConsent() {
        guard let result = runCLI(["machine", "link", "--host", "c11-preflight.invalid", "--artifacts", "/nonexistent-c11-artifacts"]) else { return }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("--artifacts /nonexistent-c11-artifacts is not a folder"), result.stderr)
        XCTAssertFalse(result.stdout.contains("c11-preflight.invalid"), "consent was asked first: \(result.stdout)")
    }

    func testPreviouslyAcceptedFlagsAcrossSpecializedParsersPassPreflight() throws {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let laterErrorsAreNotPreflightRejections: [[String]] = [
            ["feed", "open", "--tab", panelID, "--workspace", "workspace:1"],
            ["navigate", "https://example.invalid", "--allow-insecure-http"],
            ["browser-reload", "--snapshot-after"],
            ["mailbox", "inbox-dir", "--tab", panelID],
            ["agent-hook", "working", "--native-event", "agent_start"],
            // C11H-392: a Linux machine's files from a folder; the missing folder fails after preflight.
            ["machine", "link", "--host", "c11-preflight.invalid", "--yes", "--artifacts", "/nonexistent-c11-artifacts"],
        ]
        for command in laterErrorsAreNotPreflightRejections {
            guard let result = runCLI(command) else { return }
            XCTAssertNotEqual(result.status, 0, "These probes need runtime state: \(command)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(command): \(result.stderr)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-cli-preflight-\(UUID().uuidString)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for command in [
            ["usage", "--journal", state.appendingPathComponent("journal.sqlite3").path,
             "--state-root", state.path, "--claude-root", claude.path, "--codex-root", codex.path,
             "--since", "all", "--utc", "--json"],
            ["report", "--state-root", state.path, "--claude-root", claude.path, "--codex-root", codex.path,
             "--instance", "test-instance", "--by", "panel", "--format", "json"],
        ] {
            guard let result = runCLI(command) else { return }
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(command): \(result.stderr)")
        }

        guard let skillPath = runCLI(["skill", "path", "--json"]) else { return }
        XCTAssertEqual(skillPath.status, 0, skillPath.stderr)
        XCTAssertTrue(skillPath.stdout.contains("\"path\""), skillPath.stdout)

        guard let setTitleFromFile = runCLI(["set-title", "--from-file", "/dev/null"]) else { return }
        XCTAssertNotEqual(setTitleFromFile.status, 0, "An empty title must fail")
        XCTAssertFalse(setTitleFromFile.stderr.localizedCaseInsensitiveContains("unknown flag"), setTitleFromFile.stderr)

        guard let journalQuery = runCLI([
            "journal", "query", "--bundle-id", "com.stage11.c11", "--agent", "codex",
            "--model", "codex", "--workspace", "00000000-0000-0000-0000-000000000001",
            "--from", "0", "--to", "1", "--stall-ms", "1000",
        ]) else { return }
        XCTAssertFalse(journalQuery.stderr.localizedCaseInsensitiveContains("unknown option"), journalQuery.stderr)
        XCTAssertFalse(journalQuery.stderr.localizedCaseInsensitiveContains("unknown flag"), journalQuery.stderr)

        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex", isDirectory: true), withIntermediateDirectories: true)
        guard let skillInstall = runCLI(
            ["skill", "install", "--tool", "codex", "--home", home.path, "--dry-run"],
            environmentOverrides: ["HOME": home.path]
        ) else { return }
        // C11H-36 (#93): c11 installs its own skill again, so a dry run into an
        // existing tool home succeeds; the probe checks the flags are accepted.
        XCTAssertEqual(skillInstall.status, 0, skillInstall.stderr)
        XCTAssertFalse(skillInstall.stderr.localizedCaseInsensitiveContains("unknown flag"), skillInstall.stderr)

        guard let workspaceApply = runCLI(["workspace-apply", "--file", "/dev/null"]) else { return }
        XCTAssertNotEqual(workspaceApply.status, 0, "An empty plan file must fail")
        XCTAssertFalse(workspaceApply.stderr.localizedCaseInsensitiveContains("unknown flag"), workspaceApply.stderr)

        guard let treeSocket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let treeOptions = runCLI(
            ["tree", "--window", "--layout", "--no-layout", "--canvas-cols", "80", "--out", "/dev/null", "--report"],
            socketPath: treeSocket.path
        ) else { return }
        XCTAssertNotEqual(treeOptions.status, 0, "Conflicting tree layout flags must fail")
        XCTAssertTrue(treeOptions.stderr.contains("--layout and --no-layout"), treeOptions.stderr)
        XCTAssertFalse(treeOptions.stderr.localizedCaseInsensitiveContains("unknown flag"), treeOptions.stderr)
    }

    func testTmuxCompatValueFlagPassesPreflight() {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["__tmux-compat", "new-window", "-n", "C11-334 probe"],
            socketPath: socket.path
        ) else { return }
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving tmux compatibility request")
        XCTAssertTrue(
            socket.requests.contains(where: { $0["method"] as? String == "workspace.create" }),
            "Expected tmux new-window to reach workspace.create, got \(socket.requests)"
        )
    }

    func testMailboxSendKeepsFlagShapedBodyAfterTerminator() {
        guard let result = runCLI(["mailbox", "send", "--to", "watcher", "--", "--nope"]) else { return }
        XCTAssertNotEqual(result.status, 0, "A runtime socket is required to send mailbox content")
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown option"), result.stderr)
    }

    func testLinkRejectsInvalidArgumentsBeforeSocketDiscovery() {
        let cases: [([String], String)] = [
            (["link"], "requires --panel or --workspace"),
            (["link", "--panel"], "requires a value"),
            (["link", "--workspace"], "requires a value"),
            (["link", "--panel", ""], "empty value"),
            (["link", "--workspace="], "empty value"),
            (["link", "--panel", "--json"], "requires a value"),
            (["link", "--panel", "panel:1", "--format", "html"], "must be url, markdown, or osc8"),
            (["link", "--panel", "panel:1", "--format"], "requires a value"),
            (["link", "--panel", "panel:1", "--format="], "empty value"),
            (["link", "--panel", "panel:1", "--tab", "panel:2"], "only be supplied once"),
            (["link", "--workspace", "workspace:1", "--workspace", "workspace:2"], "only be supplied once"),
            (["link", "--panel", "workspace:1"], "invalid panel target"),
            (["link", "--panel", "self"], "invalid panel target"),
            (["link", "--workspace", "workspace:1", "extra"], "unexpected argument"),
            (["link", "--workspace", "workspace:1", "--", "extra"], "unexpected argument"),
            (["link", "--workspace", "workspace:1", "--bogus"], "unknown flag"),
        ]
        for (argv, expected) in cases {
            guard let result = runCLI(argv, environmentOverrides: ["C11_PANEL_ID": Self.linkPanelA, "C11_WORKSPACE_ID": Self.linkWorkspaceA]) else { return }
            XCTAssertNotEqual(result.status, 0, "\(argv)")
            XCTAssertTrue(result.stderr.contains(expected), "\(argv): \(result.stderr)")
            XCTAssertFalse(result.stderr.contains("Socket not found"), "\(argv): input must fail before connection")
        }
    }

    func testPreviouslyAcceptedArgvFromReviewCorporaPassesPreflight() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("c11-334-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var rejected: [String] = []
        for argv in Self.previouslyAcceptedArgv {
            guard let result = runCLI(
                argv,
                socketPath: "/tmp/c11-334-no-socket-\(UUID().uuidString).sock",
                environmentOverrides: ["HOME": home.path]
            ) else { return }
            if result.stderr.localizedCaseInsensitiveContains("unknown flag")
                || result.stderr.localizedCaseInsensitiveContains("requires a value")
                || result.stderr.localizedCaseInsensitiveContains("unexpected argument") {
                rejected.append("\(argv.joined(separator: " ")) -> \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        XCTAssertEqual(rejected, [], rejected.joined(separator: "\n"))
    }

    /// A post-command `--json` is the global output switch, so handlers that
    /// print JSON only for `c11 --json <command>` honor it too.
    func testPostCommandJSONMatchesGlobalJSON() {
        func stdout(_ argv: [String]) -> String? {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return nil }
            XCTAssertEqual(result.status, 0, "\(argv): \(result.stderr)")
            XCTAssertTrue(socket.requests.contains(where: { $0["method"] as? String == "panel.get_metadata" }), "\(socket.requests)")
            return result.stdout
        }
        let global = stdout(["--json", "get-metadata", "--panel", Self.declPanelID])
        let trailing = stdout(["get-metadata", "--panel", Self.declPanelID, "--json"])
        XCTAssertEqual(trailing, global)
        XCTAssertTrue(trailing?.hasPrefix("{") ?? false, trailing ?? "")
    }

    // MARK: - C11-569: --json and --id-format after a command's own flags

    /// One run of the bundled CLI against its own fake socket: exit status,
    /// output, and every request it sent without its per-run id.
    private func globalFlagRun(
        _ argv: [String],
        home: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (status: Int32, stdout: String, stderr: String, requests: [String])? {
        guard let socket = try? CapturedCLISocket(),
              let result = runCLI(
                  argv,
                  socketPath: socket.path,
                  environmentOverrides: [
                      "HOME": home,
                      "C11_WORKSPACE_ID": "11111111-2222-3333-4444-555566667777",
                      "C11_PANEL_ID": Self.declPanelID,
                  ],
                  file: file,
                  line: line
              )
        else { return nil }
        _ = socket.waitUntilFinished()
        let requests = socket.requests.map { request -> String in
            var request = request
            request.removeValue(forKey: "id")
            let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        return (result.status, result.stdout, result.stderr, requests)
    }

    /// JSON output with sorted keys (dictionary order varies per run);
    /// anything else as printed.
    private static func canonicalOutput(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        else { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private func temporaryHome() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-569-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// `--json` and `--id-format <fmt>` after any command's own flags behave
    /// exactly as the leading global form: same requests, same output, same
    /// exit status. Before C11-569 strict parsers (new-workspace, mailbox)
    /// rejected a trailing `--json`, and every command without its own
    /// `--id-format` rejected that.
    func testTrailingGlobalOutputFlagsMatchTheLeadingForm() {
        let cases: [(leading: [String], trailing: [String])] = [
            (["--json", "new-workspace", "--title", "X"], ["new-workspace", "--title", "X", "--json"]),
            (["--json", "new-workspace"], ["new-workspace", "--json"]),
            (["--json", "mailbox", "recv"], ["mailbox", "recv", "--json"]),
            (["--json", "mailbox", "recv", "--ack"], ["mailbox", "recv", "--ack", "--json"]),
            (["--id-format", "both", "list-workspaces"], ["list-workspaces", "--id-format", "both"]),
            (["--id-format", "both", "tree"], ["tree", "--id-format", "both"]),
            (["--id-format", "both", "mailbox", "recv"], ["mailbox", "recv", "--id-format", "both"]),
            (["--id-format", "uuids", "--json", "new-workspace"], ["new-workspace", "--id-format=uuids", "--json"]),
            (["--id-format", "refs", "new-workspace", "--title", "x"], ["new-workspace", "--id-format", "refs", "--title", "x"]),
            (["--json", "--id-format", "both", "tree", "--all"], ["tree", "--json", "--all", "--id-format", "both"]),
        ]
        for (leading, trailing) in cases {
            let home = temporaryHome()
            guard let global = globalFlagRun(leading, home: home),
                  let after = globalFlagRun(trailing, home: home) else { return }
            XCTAssertFalse(after.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(trailing): \(after.stderr)")
            XCTAssertEqual(after.status, global.status, "\(trailing): \(after.stderr) vs \(global.stderr)")
            XCTAssertEqual(Self.canonicalOutput(after.stdout), Self.canonicalOutput(global.stdout), "\(trailing)")
            XCTAssertEqual(after.requests, global.requests, "\(trailing)")
            XCTAssertFalse(after.requests.isEmpty, "\(trailing) never reached the socket: \(after.stderr)")
        }
    }

    /// The JSON switch really switches: a trailing `--json` prints the same
    /// JSON object as the leading form, not the plain-text reply.
    func testTrailingJSONOnStrictCommandPrintsJSON() {
        let home = temporaryHome()
        guard let plain = globalFlagRun(["new-workspace", "--title", "X"], home: home),
              let after = globalFlagRun(["new-workspace", "--title", "X", "--json"], home: home) else { return }
        XCTAssertEqual(after.status, 0, after.stderr)
        XCTAssertTrue(after.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), after.stdout)
        XCTAssertNotEqual(after.stdout, plain.stdout)
    }

    /// After `--`, in trailing command lines and in tmux words, `--json` and
    /// `--id-format` stay literal text and do not switch the output.
    func testGlobalOutputFlagsStayLiteralInTextPositions() {
        let p = Self.declPanelID
        let cases: [(argv: [String], method: String, key: String, expected: String)] = [
            (["respawn-pane", "--panel", p, "echo", "--json"], "panel.send_text", "text", "echo --json\n"),
            (["respawn-pane", "--panel", p, "echo", "--id-format", "both"], "panel.send_text", "text", "echo --id-format both\n"),
            (["respawn-pane", "--panel", p, "--", "--json"], "panel.send_text", "text", "--json\n"),
            (["send", "--panel", p, "--", "--json"], "panel.send_text", "text", "--json"),
            (["browser", p, "type", "#x", "--", "--json"], "browser.type", "text", "--json"),
            (["browser", p, "fill", "#x", "--", "--id-format", "both"], "browser.fill", "text", "--id-format both"),
        ]
        for (argv, method, key, expected) in cases {
            guard let run = globalFlagRun(argv, home: temporaryHome()) else { return }
            XCTAssertEqual(run.status, 0, "\(argv): \(run.stderr)")
            XCTAssertFalse(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), "\(argv) switched to JSON: \(run.stdout)")
            let params = run.requests
                .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .first(where: { $0["method"] as? String == method })?["params"] as? [String: Any]
            let value = params?[key] as? String
            XCTAssertTrue(value?.hasPrefix(expected) ?? false, "\(argv): \(key) = \(String(describing: value))")
        }
        // tmux words after the first non-option are the keys typed: the shim
        // owns its argv, so `--json` there neither fails nor switches output.
        guard let tmux = globalFlagRun(["__tmux-compat", "send-keys", "-t", "%1", "echo", "--json", "Enter"], home: temporaryHome())
        else { return }
        XCTAssertFalse(tmux.stderr.localizedCaseInsensitiveContains("unknown flag"), tmux.stderr)
        XCTAssertFalse(tmux.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), tmux.stdout)
    }

    /// `ssh <dest> -- <cmd>`: a `--json` in the remote command line is part of
    /// that command and does not switch the output. (The ssh parser takes a
    /// flag-shaped remote word only after `--`.)
    func testSSHRemoteCommandKeepsLiteralJSONWord() throws {
        let tmp = temporaryHome()
        guard let socket = try? CapturedCLISocket(),
              let result = runCLI(
                  ["ssh", "example.invalid", "--", "echo", "--json"],
                  socketPath: socket.path,
                  environmentOverrides: ["HOME": tmp, "TMPDIR": tmp + "/"]
              )
        else { return }
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), result.stdout)
        _ = socket.waitUntilFinished()
        let params = try XCTUnwrap(
            socket.requests.first(where: { $0["method"] as? String == "workspace.create" })?["params"] as? [String: Any],
            "\(socket.requests) \(result.stderr)"
        )
        let quotedPath = try XCTUnwrap(params["initial_command"] as? String)
        let path = quotedPath.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let script = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(script.contains("echo") && script.contains("--json"), script)
    }

    /// `set-metadata --json <value>` is that command's own option: its value
    /// reaches the request and the output stays plain.
    func testSetMetadataOwnJSONOptionKeepsItsValue() {
        guard let run = globalFlagRun(
            ["set-metadata", "--panel", Self.declPanelID, "--json", "{\"c11_569\":\"kept\"}"],
            home: temporaryHome()
        ) else { return }
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertFalse(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), run.stdout)
        XCTAssertTrue(
            run.requests.contains { $0.contains("panel.set_metadata") && $0.contains("c11_569") && $0.contains("kept") },
            "\(run.requests)"
        )
    }

    /// Unknown flags are still refused before socket discovery, beside a
    /// trailing global flag; a trailing `--id-format` needs its value.
    func testUnknownFlagBesideTrailingGlobalFlagStillFailsOffline() {
        let cases: [([String], String)] = [
            (["new-workspace", "--json", "--not-a-real-flag"], "unknown flag"),
            (["mailbox", "recv", "--id-format", "both", "--not-a-real-flag"], "unknown flag"),
            (["tree", "--not-a-real-flag", "--json"], "unknown flag"),
            (["tree", "--id-format"], "--id-format requires a value"),
            (["list-workspaces", "--id-format", "--"], "--id-format requires a value"),
        ]
        for (argv, message) in cases {
            // No listener at the default path: a socket attempt would say so.
            guard let result = runCLI(argv) else { return }
            XCTAssertNotEqual(result.status, 0, "\(argv)")
            XCTAssertEqual(result.stdout, "", "\(argv)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains(message), "\(argv): \(result.stderr)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("socket not found"), "\(argv): \(result.stderr)")
        }
    }

    /// Declared options reach the request with their values in every position
    /// a parser reads them: inline targets before a verb, inline options in
    /// browser text verbs, and trailing-command options. Literal text keeps
    /// its words (PR #737 r3).
    func testDeclaredOptionsReachRequestPayloadsWithTheirValues() {
        let p = Self.declPanelID
        let cases: [(argv: [String], method: String, expected: [String: String])] = [
            (["respawn-pane", "--panel=\(p)", "--command=echo hello"], "panel.send_text", ["panel_id": p, "text": "echo hello\n"]),
            (["respawn-pane", "--panel", p, "ls", "-la"], "panel.send_text", ["text": "ls -la\n"]),
            (["respawn-pane", "ls", "-la"], "panel.send_text", ["text": "ls -la\n"]),
            (["browser", "--panel=\(p)", "click", "--selector", "#x"], "browser.click", ["panel_id": p, "selector": "#x"]),
            (["browser", "--tab=\(p)", "click", "--selector", "#x"], "browser.click", ["panel_id": p, "selector": "#x"]),
            (["browser", "--surface=\(p)", "click", "--selector", "#x"], "browser.click", ["panel_id": p, "selector": "#x"]),
            (["markdown", "--panel=\(p)", "scroll", "--heading=Intro"], "markdown.scroll", ["panel_id": p, "heading": "Intro"]),
            (["browser", p, "type", "--selector=#x", "--text=hello"], "browser.type", ["selector": "#x", "text": "hello"]),
            (["browser", p, "fill", "--selector=#x", "--text=hello"], "browser.fill", ["selector": "#x", "text": "hello"]),
            (["browser", p, "fill", "--selector", "#x", "--text=hello"], "browser.fill", ["text": "hello"]),
            (["browser", p, "type", "#x", "--", "--text=hello"], "browser.type", ["selector": "#x", "text": "--text=hello"]),
            (["browser", p, "type", "#x", "--verbose"], "browser.type", ["text": "--verbose"]),
            (["browser", p, "fill", "#x", "hello", "--world"], "browser.fill", ["text": "hello --world"]),
            (["browser", p, "eval", "--script=1+1"], "browser.eval", ["script": "1+1"]),
            (["browser", p, "eval", "1+1", "--x"], "browser.eval", ["script": "1+1 --x"]),
            (["browser", p, "addinitscript", "--script=window.x=1"], "browser.addinitscript", ["script": "window.x=1"]),
            (["browser", p, "addscript", "--script=window.x=1"], "browser.addscript", ["script": "window.x=1"]),
            (["browser", p, "addstyle", "--css=body{color:red}"], "browser.addstyle", ["css": "body{color:red}"]),
        ]
        for (argv, method, expected) in cases {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, "\(argv): \(result.stderr)")
            _ = socket.waitUntilFinished()
            guard let params = socket.requests.first(where: { $0["method"] as? String == method })?["params"] as? [String: Any] else {
                XCTFail("\(argv): expected \(method), got \(socket.requests)")
                continue
            }
            for (key, value) in expected {
                XCTAssertEqual(params[key] as? String, value, "\(argv): \(key)")
            }
        }
    }

    /// A target-shaped word that is another option's value is text: it never
    /// retargets the command and keeps all its characters (PR #737 r4 V1).
    func testTargetShapedOptionValueStaysTextAndKeepsCallerTarget() {
        let caller = Self.declPanelID
        let other = "eee11111-2222-3333-4444-555566667777"
        let otherWorkspace = "fff11111-2222-3333-4444-555566667777"
        let cases: [(argv: [String], method: String, expected: [String: String], absent: [String])] = [
            (["notify", "--body", "--panel=\(other)"], "notification.create_for_panel", ["panel_id": caller, "body": "--panel=\(other)"], []),
            (["notify", "--body", "--tab=\(other)"], "notification.create_for_panel", ["panel_id": caller, "body": "--tab=\(other)"], []),
            (["notify", "--body", "--surface=\(other)"], "notification.create_for_panel", ["panel_id": caller, "body": "--surface=\(other)"], []),
            (["notify", "--body", "--workspace=\(otherWorkspace)"], "notification.create_for_panel", ["panel_id": caller, "body": "--workspace=\(otherWorkspace)"], ["workspace_id"]),
            (["respawn-pane", "--command", "--panel=\(other)"], "panel.send_text", ["text": "--panel=\(other)\n"], ["panel_id"]),
        ]
        for (argv, method, expected, absent) in cases {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path, environmentOverrides: ["C11_PANEL_ID": caller])
            else { return }
            XCTAssertEqual(result.status, 0, "\(argv): \(result.stderr)")
            _ = socket.waitUntilFinished()
            guard let params = socket.requests.first(where: { $0["method"] as? String == method })?["params"] as? [String: Any] else {
                XCTFail("\(argv): expected \(method), got \(socket.requests)")
                continue
            }
            for (key, value) in expected {
                XCTAssertEqual(params[key] as? String, value, "\(argv): \(key)")
            }
            for key in absent {
                XCTAssertNil(params[key], "\(argv): unexpected \(key)")
            }
        }
    }

    /// An unknown option beside a trailing-command parser's own options fails
    /// before the CLI connects; words after the first positional stay text.
    func testTrailingCommandParsersRejectUnknownOptionsBeforeConnecting() {
        let cases: [[String]] = [
            ["respawn-pane", "--command", "true", "--not-a-real-flag"],
            ["pipe-pane", "--command", "cat", "--not-a-real-flag"],
            ["set-hook", "--list", "--not-a-real-flag"],
        ]
        for argv in cases {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return }
            XCTAssertNotEqual(result.status, 0, "\(argv)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(argv): \(result.stderr)")
            XCTAssertTrue(socket.requests.isEmpty, "\(argv) reached the socket: \(socket.requests)")
            XCTAssertTrue(socket.legacyCommands.isEmpty, "\(argv) reached the socket: \(socket.legacyCommands)")
        }
    }

    /// The skill documents tmux's `resize-pane -L 500`; the amount word is
    /// read, not dropped, now that a stray word would be rejected.
    func testResizePaneReadsTmuxStyleAmountWord() {
        for (argv, amount) in [(["resize-pane", "--pane", "area:1", "-L", "500"], 500), (["resize-pane", "--pane", "area:1", "-R", "--amount", "7"], 7)] {
            guard let run = runClose(argv) else { return }
            XCTAssertEqual(run.result.status, 0, "\(argv): \(run.result.stderr)")
            _ = run.socket.waitUntilFinished()
            let params = run.socket.requests.first(where: { $0["method"] as? String == "area.resize" })?["params"] as? [String: Any]
            XCTAssertEqual(params?["amount"] as? Int, amount, "\(argv): \(run.socket.requests)")
        }
    }

    // c11-2.0:begin-keep (the retired c11h line is the foreign one here)
    /// Offline report, health, and the remote-daemon cache read the c11
    /// state root of the supplied home. A sibling c11h tree is not a source.
    func testOfflineDiagnosticsStayInsideTheFixtureC11Home() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("c11-cli-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let c11hEvents = home.appendingPathComponent("Library/Application Support/c11h/events", isDirectory: true)
        let c11Events = home.appendingPathComponent("Library/Application Support/c11/events", isDirectory: true)
        let reports = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let foreignReports = reports.appendingPathComponent("com.stage11.c11h", isDirectory: true)
        let empty = home.appendingPathComponent("empty-transcripts", isDirectory: true)
        for dir in [c11hEvents, c11Events, reports, foreignReports, empty] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let line = { (instance: String) -> Data in
            Data("{\"v\":1,\"instance\":\"\(instance)\",\"seq\":1,\"ts\":\"2026-10-31T12:00:00.000Z\",\"type\":\"log.opened\",\"payload\":{}}\n".utf8)
        }
        try line("com.stage11.c11h-123456").write(to: c11hEvents.appendingPathComponent("events-com.stage11.c11h-123456.ndjson"))
        try line("com.stage11.c11-123456").write(to: c11Events.appendingPathComponent("events-com.stage11.c11-123456.ndjson"))

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        let ips = Data("{\"bundleID\":\"com.stage11.c11h\",\"bug_type\":\"309\",\"timestamp\":\"\(stamp.string(from: Date()))\"}\n".utf8)
        try ips.write(to: reports.appendingPathComponent("c11-review-fixture.ips"))
        try ips.write(to: reports.appendingPathComponent("c11h-review-fixture.ips"))
        try ips.write(to: foreignReports.appendingPathComponent("Crash.ips"))

        let env = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "C11_ACTIVITY_HISTORY_DIRECTORY": "",
        ]
        let reportArgs = ["--format", "json", "--claude-root", empty.path, "--codex-root", empty.path]

        guard let report = runCLI(["report"] + reportArgs, environmentOverrides: env) else { return }
        XCTAssertEqual(report.status, 0, report.stderr)
        XCTAssertEqual(try identityInstances(report.stdout), ["com.stage11.c11-123456"])

        guard let all = runCLI(["report", "--all-instances"] + reportArgs, environmentOverrides: env) else { return }
        XCTAssertEqual(all.status, 0, all.stderr)
        XCTAssertEqual(try identityInstances(all.stdout), ["com.stage11.c11-123456"])

        guard let health = runCLI(["health", "--json", "--rail", "ips"], environmentOverrides: env) else { return }
        XCTAssertEqual(health.status, 0, health.stderr)
        let events = try identityHealthPaths(health.stdout)
        XCTAssertEqual(events.count, 1, health.stdout)
        XCTAssertTrue(events[0].contains("c11-review-fixture.ips"), events[0])
        XCTAssertFalse(events[0].contains("c11h-review-fixture.ips"))
        XCTAssertFalse(events[0].contains("/com.stage11.c11h/"))

        guard let daemon = runCLI(["remote-daemon-status", "--json"], environmentOverrides: env) else { return }
        XCTAssertEqual(daemon.status, 0, daemon.stderr)
        let cache = try identityStringField(daemon.stdout, key: "cache_path")
        XCTAssertTrue(cache.contains(home.lastPathComponent), cache)
        XCTAssertTrue(cache.contains("/c11/remote-daemons"), cache)
        XCTAssertFalse(cache.contains("/Application Support/c11h/"), cache)

        guard let help = runCLI(["list-snapshots", "--help"]) else { return }
        XCTAssertEqual(help.status, 0, help.stderr)
        XCTAssertTrue(help.stdout.contains("~/.c11-snapshots"))
        XCTAssertFalse(help.stdout.contains("~/.c11h-snapshots"))
        XCTAssertFalse(help.stdout.contains("~/.cmux-snapshots"))
    }
    // c11-2.0:end-keep
}

// MARK: - CLIPreflightRejectionTests

final class CLIPreflightRejectionTests: CLIResolutionTestCase {}

extension CLIPreflightRejectionTests {
    func testStatusMissingWhenC11NotOnPath() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/usr/bin:/bin",
            ],
            commands: ["c11": nil, "cmux": nil],
            existing: [bundled]
        ))
        XCTAssertEqual(snapshot.status, .missing)
        XCTAssertNil(snapshot.c11OnPath)
        XCTAssertTrue(snapshot.notes.contains(where: { $0.contains("_cmux_fix_path") }))
    }

    func testStatusMismatchWhenBundledFileMissing() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/usr/bin",
            ],
            commands: ["c11": "/usr/bin/c11", "cmux": nil],
            existing: ["/usr/bin/c11"]  // bundled file does not exist
        ))
        XCTAssertEqual(snapshot.status, .mismatch)
        XCTAssertTrue(snapshot.notes.contains(where: { $0.contains("not an executable file") }))
    }

    func testEmptyEnvValuesAreNormalizedToNil() {
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": "   ",
                "PATH": "/usr/bin",
            ]
        ))
        XCTAssertNil(snapshot.bundledCliPath)
        XCTAssertEqual(snapshot.status, .noBundle)
    }

    func testParseDoctorArgsRejectsUnknownFlag() {
        XCTAssertThrowsError(try parseDoctorCLIArgs(["--unknown"])) { error in
            guard let err = error as? DoctorCLIError else {
                XCTFail("expected DoctorCLIError, got \(error)")
                return
            }
            switch err {
            case .unknownFlag(let f): XCTAssertEqual(f, "--unknown")
            }
        }
    }

    func testDefaultCommandLookupSkipsEmptyPathEntries() {
        // PATH is allowed to contain empty entries (e.g. "::"). Make sure we
        // don't try to resolve them as ".".
        let env = ["PATH": "::/usr/bin"]
        // Use a name that almost certainly doesn't exist so the lookup
        // exhausts the path without crashing on the empty entries.
        let result = defaultCommandLookup("__c11_doctor_does_not_exist__", environment: env)
        XCTAssertNil(result)
    }

    func testCodexDirtyDecisionRequiresVerifiedTranscript() {
        XCTAssertEqual(
            ResumeDecisionEngine.decide(resumeInput(mode: .dirty, transcript: .verified)),
            .command(ResumeCommand(text: "codex resume --yolo '\(codexID)'"))
        )
        guard case .skip(let code, _) = ResumeDecisionEngine.decide(
            resumeInput(mode: .dirty, transcript: .missing)
        ) else {
            return XCTFail("missing dirty transcript must skip")
        }
        XCTAssertEqual(code, .transcriptMissing)
    }

    func testTimedOutFinalStoreReadCannotBecomeEmptySuccess() {
        let outcome: BoundedLifecycleOutcome<[String: String]> = BoundedLifecycleWait.run(
            timeout: 0.005
        ) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return ["surface-1": "late-value"]
        }
        guard case .timedOut = outcome else {
            return XCTFail("late store read must report timeout, not an empty map")
        }
        XCTAssertFalse(CleanPersistencePromotionPolicy.allowsPromotion(
            resolutionCompleted: true,
            finalStoreReadCompleted: false,
            durableSnapshotWriteCompleted: true
        ))
    }

    func testFailedOrTimedOutDurableWriteNeverPromotesClean() {
        for tuple in [
            (resolution: false, read: true, write: true),
            (resolution: true, read: false, write: true),
            (resolution: true, read: true, write: false),
        ] {
            XCTAssertFalse(CleanPersistencePromotionPolicy.allowsPromotion(
                resolutionCompleted: tuple.resolution,
                finalStoreReadCompleted: tuple.read,
                durableSnapshotWriteCompleted: tuple.write
            ))
        }
    }

    func testAppRecoveryModeResolverFailsClosedAndNoResumeOverrides() {
        let states: [(ShutdownSentinel.PriorShutdown, ResumeRecoveryMode)] = [
            (.clean(at: Date(timeIntervalSince1970: 1)), .clean),
            (.dirty(launchedAt: nil), .dirty),
            (.missing, .dirty),
            (.unreadable, .dirty),
            (.invalid, .dirty),
        ]
        for (prior, expected) in states {
            XCTAssertEqual(
                ShutdownSentinel.resolveRecoveryMode(
                    explicitNoResume: false,
                    priorShutdown: prior
                ),
                expected
            )
            XCTAssertEqual(
                ShutdownSentinel.resolveRecoveryMode(
                    explicitNoResume: true,
                    priorShutdown: prior
                ),
                .noResume
            )
        }
    }

    /// Every command meets one of the six empty-ref spellings, and every spelling
    /// meets several commands: a covering set, not the full cross product, so
    /// the class stays inside the 30 s run budget (C11H-30).
    func testPanelTargetReadCommandsRejectEmptyRefsBeforeSocketIO() {
        let forms: [(flag: String, value: String?)] = [
            ("--panel", ""), ("--surface=", nil), ("--tab", ""),
            ("--panel=", nil), ("--surface", ""), ("--tab=", nil),
        ]
        for (index, command) in panelTargetReadCommands.enumerated() {
            let form = forms[index % forms.count]
            guard assertPanelTargetRejected(
                expected: "empty_ref: --panel was provided but empty",
                command: command,
                flag: form.flag,
                value: form.value
            ) else { return }
        }
    }

    /// Covering set as above, offset so each command meets a different alias
    /// than its empty-ref case.
    func testPanelTargetReadCommandsReportMissingValuesBeforeSocketIO() {
        let flags = ["--panel", "--surface", "--tab"]
        for (index, command) in panelTargetReadCommands.enumerated() {
            guard assertPanelTargetRejected(
                expected: "--panel requires a value",
                command: command,
                flag: flags[(index + 1) % flags.count]
            ) else { return }
        }
    }

    func testClosePanelRejectsEmptyAndMissingTargetsBeforeSocketIO() {
        for flag in ["--panel", "--surface", "--tab"] {
            guard assertPanelTargetRejected(
                expected: "empty_ref: --panel was provided but empty",
                command: ["close-panel"],
                flag: flag,
                value: ""
            ) else { return }
            guard assertPanelTargetRejected(
                expected: "--panel requires a value",
                command: ["close-panel"],
                flag: flag
            ) else { return }
        }
        for flag in ["--panel=", "--surface=", "--tab="] {
            guard let result = runCLI(["close-panel", flag]) else { return }
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "Error: empty_ref: --panel was provided but empty\n")
        }
        guard let afterTerminator = runCLI(["close-panel", "--", "--panel"]) else { return }
        XCTAssertEqual(afterTerminator.status, 1)
        XCTAssertEqual(afterTerminator.stdout, "")
        XCTAssertEqual(afterTerminator.stderr, "Error: --panel requires a value\n")
    }

    func testBrowserReadSubcommandsRejectInvalidPanelFlagsBeforeSocketIO() {
        let cases: [(command: [String], flag: String, value: String?, expected: String)] = [
            (
                ["browser", "panel:1", "get", "title", "--selector"],
                "--panel=",
                nil,
                "empty_ref: --panel was provided but empty"
            ),
            (
                ["browser", "panel:1", "is", "visible"],
                "--panel",
                nil,
                "--panel requires a value"
            ),
            (
                ["browser", "panel:1", "find", "text", "needle"],
                "--surface",
                nil,
                "--panel requires a value"
            ),
            (
                ["browser", "panel:1", "wait", "--selector", ".ready"],
                "--tab=",
                nil,
                "empty_ref: --panel was provided but empty"
            ),
            (
                ["browser", "panel:1", "screenshot"],
                "--panel",
                nil,
                "--panel requires a value"
            ),
            (
                ["browser", "panel:1", "console", "list"],
                "--surface",
                nil,
                "--panel requires a value"
            ),
            (
                ["browser", "panel:1", "errors", "list"],
                "--panel=",
                nil,
                "empty_ref: --panel was provided but empty"
            ),
        ]
        for item in cases {
            _ = assertPanelTargetRejected(
                expected: item.expected,
                command: item.command,
                flag: item.flag,
                value: item.value
            )
        }
    }

    func testValueOptionDoesNotHideEmptyPanelFlag() {
        let aliases = ["--panel", "--surface", "--tab"]
        for alias in aliases {
            for value in ["", nil] as [String?] {
                var command = ["get-metadata", "--key", alias]
                if let value { command.append(value) }
                guard let result = runCLI(command) else { return }
                XCTAssertEqual(result.status, 1, "\(command): \(result.stderr)")
                XCTAssertEqual(result.stdout, "", "\(command)")
                XCTAssertEqual(
                    result.stderr,
                    value == nil
                        ? "Error: --panel requires a value\n"
                        : "Error: empty_ref: --panel was provided but empty\n",
                    "\(command)"
                )
            }
        }

        let invalidPanelTargets: [[String]] = [
            ["read-screen", "--lines", "--panel", ""],
            ["capture-pane", "--lines", "--panel", ""],
            ["capturep", "--lines", "--panel", ""],
            ["pipe-pane", "--command", "--panel", ""],
            ["pipe-pane", "--command", "--panel"],
        ]
        for command in invalidPanelTargets {
            guard let result = runCLI(command) else { return }
            XCTAssertEqual(result.status, 1, "\(command): \(result.stderr)")
            XCTAssertEqual(result.stdout, "", "\(command)")
            XCTAssertEqual(
                result.stderr,
                command.last == "--panel"
                    ? "Error: --panel requires a value\n"
                    : "Error: empty_ref: --panel was provided but empty\n",
                "\(command)"
            )
        }

        let literalValues: [[String]] = [
            ["browser", "eval", "--script", "--panel"],
            ["markdown", "scroll", "--panel", "panel:1", "--heading", "--panel"],
            ["browser", "panel:1", "state", "save", "--panel"],
        ]
        for command in literalValues {
            guard let result = runCLI(command) else { return }
            XCTAssertEqual(result.status, 1, "\(command): \(result.stderr)")
            XCTAssertEqual(result.stdout, "", "\(command)")
            XCTAssertFalse(result.stderr.contains("--panel requires a value"), "\(command): \(result.stderr)")
            XCTAssertFalse(result.stderr.contains("empty_ref: --panel was provided but empty"), "\(command): \(result.stderr)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("socket"), "\(command): \(result.stderr)")
        }
    }

    func testBooleanOptionDoesNotHideMissingPanelValue() {
        guard let result = runCLI(["read-selection", "--json", "--panel"]) else { return }
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "Error: --panel requires a value\n")
    }

    func testUnknownFlagsFailBeforeSocketDiscovery() {
        let cases: [[String]] = [
            ["new-workspace", "--title", "C11-334 probe", "--not-a-real-flag"],
            ["new-split", "right", "--not-a-real-flag"],
            ["launch-agent", "--type", "codex", "--not-a-real-flag"],
            ["browser", "open", "https://example.invalid", "--not-a-real-flag"],
            ["browser", "open", "https://example.invalid", "--selector", ".ready"],
            ["guide", "--not-a-real-flag"],
            ["usage", "--not-a-real-flag"],
            ["report", "--not-a-real-flag"],
            ["journal", "query", "--not-a-real-flag"],
            ["agent-event", "append", "--not-a-real-flag"],
            ["themes", "clear", "--not-a-real-flag"],
            ["model-costs", "rm", "claude-opus-4-7", "--in", "1"],
            ["history", "back", "--limit", "5"],
            ["history", "--limit", "5", "back"],
            ["feed", "list", "--workspace", "workspace:1"],
            ["feed", "open", "panel:1", "--scope", "all"],
            ["workspace", "recents", "unpin", "~/Projects/site", "--at", "1"],
            ["__tmux-compat", "new-window", "--not-a-real-flag"],
            ["claude-mailbox", "--not-a-real-flag"],
        ]

        for command in cases {
            guard let result = runCLI(command) else { return }
            XCTAssertNotEqual(result.status, 0, "\(command)")
            XCTAssertEqual(result.stdout, "", "\(command)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("socket not found"), result.stderr)
        }
    }

    func testStateSaveRejectsUnexpectedArgumentAfterEndOfOptionsBeforeMutation() {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["state", "save", "--scrollback", "--", "--bogus"],
            socketPath: socket.path
        ) else { return }
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unexpected argument"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(
            socket.requests.contains(where: { $0["method"] as? String == "session.save" }),
            "unexpected state save argument reached mutation: \(socket.requests)"
        )
    }

    func testClearNotificationsRejectsUnexpectedTextAfterEndOfOptionsBeforeMutation() {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["clear-notifications", "--", "--not-a-real-flag"],
            socketPath: socket.path
        ) else { return }
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unexpected argument"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(
            socket.requests.contains(where: { ($0["legacy_command"] as? String)?.hasPrefix("clear_notifications") == true }),
            "unexpected clear-notifications text reached mutation: \(socket.requests)"
        )
    }

    func testUnknownCreateFlagDoesNotReachMutationHandler() {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["new-split", "right", "--not-a-real-flag"],
            socketPath: socket.path
        ) else { return }
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(
            socket.requests.contains(where: { $0["method"] as? String == "panel.split" }),
            "unknown option reached panel.split: \(socket.requests)"
        )
    }

    func testFlagAfterEndOfOptionsDoesNotMutate() {
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [([String], Set<String>)] = [
            (["close-panel", "--", "--not-a-real-flag"], ["panel.close"]),
            (["new-panel", "--", "--not-a-real-flag"], ["panel.create"]),
            (["new-split", "right", "--", "--not-a-real-flag"], ["panel.split"]),
            (["clear-log", "--", "--not-a-real-flag"], []),
            (["clear-progress", "--", "--not-a-real-flag"], []),
            (["set-progress", "0.5", "--", "--not-a-real-flag"], []),
            (["set-status", "build", "ok", "--", "--not-a-real-flag"], []),
            (["notify", "--title", "t", "--", "-body"], ["notification.create_for_panel"]),
            (["notify", "--", "--not-a-real-flag"], ["notification.create_for_panel"]),
        ]

        for (command, mutatingMethods) in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                command,
                socketPath: socket.path,
                environmentOverrides: ["C11_WORKSPACE_ID": workspaceID, "C11_PANEL_ID": panelID]
            ) else { return }
            XCTAssertNotEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertTrue(
                result.stderr.localizedCaseInsensitiveContains("unknown flag")
                    || result.stderr.localizedCaseInsensitiveContains("unexpected argument"),
                "Expected a flag validation error for \(command), got \(result.stderr)"
            )
            XCTAssertFalse(
                socket.requests.contains(where: { mutatingMethods.contains($0["method"] as? String ?? "") }),
                "Mutation reached the socket for \(command): \(socket.requests)"
            )
            XCTAssertTrue(socket.legacyCommands.isEmpty, "Legacy mutation reached the socket for \(command): \(socket.legacyCommands)")
        }
    }

    func testReadSelectionJsonIsNotAnUnknownFlag() {
        XCTAssertTrue(assertCommandReachesSocket(
            ["read-selection", "--panel", "ddd11111-2222-3333-4444-555566667777", "--json"],
            method: "panel.read_selection"
        ))
    }

    func testSidebarStateJsonIsNotAnUnknownFlag() {
        XCTAssertTrue(assertCommandReachesSocket(
            ["sidebar-state", "--json", "--workspace", "11111111-2222-3333-4444-555566667777"],
            method: "sidebar.state"
        ))
    }

    func testDragPanelToSplitJsonIsNotAnUnknownFlag() {
        XCTAssertTrue(assertCommandReachesSocket(
            ["drag-panel-to-split", "--workspace", "11111111-2222-3333-4444-555566667777",
             "--panel", "ddd11111-2222-3333-4444-555566667777", "right", "--json"],
            method: "panel.drag_to_split"
        ))
    }

    func testClearStatusRejectsWindowFlagBeforeMutation() {
        guard let result = runCLI(["clear-status", "build", "--window", "window:1"]) else { return }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("unknown flag '--window'"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("socket not found"), result.stderr)
    }

    func testCustomFlagSpecsRecognizeHiddenAliasesBeforeLaterUnknownFlags() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [([String], String)] = [
            (["conversation", "list", "--tab", panelID, "--not-a-real-flag"], "--not-a-real-flag"),
            (["default-agent", "launch", "--agent", "codex", "--in-tab", panelID, "--not-a-real-flag"], "--not-a-real-flag"),
        ]

        for (command, expectedFlag) in cases {
            guard let result = runCLI(command) else { return }
            XCTAssertEqual(result.status, 1, "\(command): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("unknown flag '\(expectedFlag)'"), result.stderr)
            XCTAssertFalse(result.stderr.contains("unknown flag '--tab'"), result.stderr)
            XCTAssertFalse(result.stderr.contains("unknown flag '--in-tab'"), result.stderr)
        }
    }

    func testFocusTabRejectsUnknownWorkspaceBeforeFocusMutation() {
        for workspaceOption in [["--workspace", "workspace:9999"], ["--workspace=workspace:9999"]] {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                ["focus-tab", "--tab", socket.panelIDForAssertions] + workspaceOption,
                socketPath: socket.path
            ) else { return }
            XCTAssertNotEqual(result.status, 0, "\(workspaceOption): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("not_found"), "\(workspaceOption): \(result.stderr)")
            XCTAssertFalse(
                socket.requests.contains(where: { $0["method"] as? String == "panel.focus" }),
                "invalid workspace reached panel.focus: \(socket.requests)"
            )
        }
    }

    func testLinkRejectsUnknownUUIDsAndRefsInsteadOfUsingCaller() throws {
        for argv in [
            ["link", "--panel", "ffffffff-ffff-4fff-8fff-ffffffffffff"],
            ["link", "--workspace", "ffffffff-ffff-4fff-8fff-ffffffffffff"],
            ["link", "--panel", "panel:999"],
            ["link", "--workspace", "workspace:999"],
        ] {
            let socket = try makeLinkSocket()
            let result = try XCTUnwrap(runCLI(argv, socketPath: socket.path, environmentOverrides: ["C11_PANEL_ID": Self.linkPanelA, "C11_WORKSPACE_ID": Self.linkWorkspaceA]))
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderr.contains("not_found:"), result.stderr)
            XCTAssertTrue(result.stdout.isEmpty)
            assertLinkInventoryOnly(socket)
        }
    }

    func testLinkRequiresUniqueIndexAndAcceptsExplicitScope() throws {
        for argv in [["link", "--panel", "0"], ["link", "--workspace", "0"]] {
            let socket = try makeLinkSocket()
            let result = try XCTUnwrap(runCLI(argv, socketPath: socket.path))
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderr.contains("ambiguous"), result.stderr)
            assertLinkInventoryOnly(socket)
        }
        let socket = try makeLinkSocket()
        let result = try XCTUnwrap(runCLI(["link", "--panel", "0", "--workspace", "workspace:2"], socketPath: socket.path))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "c11://panel/\(Self.linkPanelB)\n")
        assertLinkInventoryOnly(socket)
    }

    /// With `--script`, `eval` takes no positional text, so an unknown flag
    /// fails before any browser request (PR #737 r4 V2).
    func testBrowserEvalWithScriptOptionRejectsUnknownFlag() {
        for argv in [
            ["browser", Self.declPanelID, "eval", "--script", "1+1", "--not-a-real-flag"],
            ["browser", Self.declPanelID, "eval", "--script=1+1", "--not-a-real-flag"],
        ] {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return }
            XCTAssertNotEqual(result.status, 0, "\(argv)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(argv): \(result.stderr)")
            XCTAssertFalse(socket.requests.contains(where: { $0["method"] as? String == "browser.eval" }), "\(argv): \(socket.requests)")
        }
    }

    /// The C11-481 incident: a stray ref is rejected before the CLI connects,
    /// and the hint names an option only when the command takes it.
    func testStrayPositionalFailsBeforeSocketWithOptionHint() {
        let cases: [(argv: [String], stderr: String)] = [
            (["close-panel", "panel:268"], "Error: close-panel: unexpected argument 'panel:268'. Did you mean --panel panel:268?\n"),
            (["close-tab", "--panel", "panel:1", "panel:268"], "Error: close-panel: unexpected argument 'panel:268'. Did you mean --panel panel:268?\n"),
            (["close-panel", "--panel", "panel:1", "--", "panel:268"], "Error: close-panel: unexpected argument 'panel:268'. Did you mean --panel panel:268?\n"),
            (["identify", "panel:268"], "Error: identify: unexpected argument 'panel:268'. Did you mean --panel panel:268?\n"),
            (["close-workspace", "--workspace", "workspace:1", "workspace:2"], "Error: close-workspace: unexpected argument 'workspace:2'. Did you mean --workspace workspace:2?\n"),
            (["ping", "panel:268"], "Error: ping: unexpected argument 'panel:268'.\n"),
            (["list-windows", "extra"], "Error: list-windows: unexpected argument 'extra'.\n"),
        ]
        for (argv, stderr) in cases {
            guard let run = runClose(argv) else { return }
            XCTAssertNotEqual(run.result.status, 0, "\(argv)")
            XCTAssertEqual(run.result.stderr, stderr, "\(argv)")
            XCTAssertTrue(run.socket.requests.isEmpty, "\(argv) reached the socket: \(run.socket.requests)")
        }
    }

    /// No close falls back to `C11_PANEL_ID` or the focused panel.
    func testCloseCommandsWithoutTargetFailBeforeSocket() {
        let cases: [[String]] = [
            ["close-panel"], ["close-tab"], ["close-surface"],
            ["close-panel", "--workspace", Self.closeWorkspace],
            ["panel-action", "--action", "close-right"], ["panel-action", "close-others"],
            ["panel-action", "--workspace", Self.closeWorkspace, "--action", "close-left"],
            ["workspace-action", "close-below"], ["workspace-action", "--action", "close-above"],
            // The handler runs the last --action and trims it, as the server does.
            ["panel-action", "--action", "pin", "--action", "close-right"],
            ["panel-action", "--action=pin", "--action=close-right"],
            ["panel-action", " close-right"], ["panel-action", "--action", " Close-Others "],
            ["tab-action", "--action", "pin", "--action", "close-left"],
            ["workspace-action", "--action", "pin", "--action", "close-below"],
            ["workspace-action", "--action=pin", "--action=close-above"],
            ["workspace-action", " close-below"],
        ]
        for argv in cases {
            guard let run = runClose(argv) else { return }
            XCTAssertNotEqual(run.result.status, 0, "\(argv)")
            XCTAssertTrue(run.result.stderr.contains(" require"), "\(argv): \(run.result.stderr)")
            XCTAssertTrue(run.socket.requests.isEmpty, "\(argv) reached the socket: \(run.socket.requests)")
        }
    }

    /// `self` with no caller in the environment is an error, not the focused panel.
    func testSelfCloseTargetWithoutCallerEnvironmentFails() {
        for argv in [["close-panel", "--panel", "self"], ["close-workspace", "--workspace", "self"]] {
            guard let run = runClose(argv, environment: [:]) else { return }
            XCTAssertNotEqual(run.result.status, 0, "\(argv)")
            XCTAssertTrue(run.result.stderr.contains("self needs a c11 terminal"), "\(argv): \(run.result.stderr)")
            XCTAssertFalse(
                run.socket.requests.contains(where: { ["panel.close", "workspace.close"].contains($0["method"] as? String ?? "") }),
                "\(argv): \(run.socket.requests)"
            )
        }
    }

    func testTmuxKillVerbsRequireATarget() {
        for argv in [
            ["__tmux-compat", "kill-pane"], ["__tmux-compat", "kill-window"],
            ["__tmux-compat", "killp"], ["__tmux-compat", "killw"],
            ["__tmux-compat", "kill-pane", "-t", ""], ["__tmux-compat", "kill-window", "-t", ""],
            ["__tmux-compat", "killp", "-t", "  "], ["__tmux-compat", "killw", "-t", " "],
        ] {
            guard let run = runClose(argv) else { return }
            XCTAssertNotEqual(run.result.status, 0, "\(argv)")
            XCTAssertTrue(run.result.stderr.contains("requires -t"), "\(argv): \(run.result.stderr)")
            XCTAssertFalse(
                run.socket.requests.contains(where: { ["panel.close", "workspace.close"].contains($0["method"] as? String ?? "") }),
                "\(argv): \(run.socket.requests)"
            )
        }
    }
}

// MARK: - CLIHandlerRoutingTests

final class CLIHandlerRoutingTests: CLIResolutionTestCase {}

extension CLIHandlerRoutingTests {
    func testMailboxSendBodyThatLooksLikePanelFlagRemainsBodyText() {
        for flagShapedBody in ["--panel", "--surface", "--tab"] {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                ["mailbox", "send", "--body", flagShapedBody],
                socketPath: socket.path
            ) else { return }
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "Error: A mailbox envelope needs --to or --topic.\n")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving")
            XCTAssertTrue(socket.requests.isEmpty, "mailbox send should reject before writing to the socket")
        }
    }

    func testBrowserScrollSnapshotAfterReachesHandler() {
        XCTAssertTrue(assertCommandReachesSocket(
            ["browser", "--panel", "ddd11111-2222-3333-4444-555566667777",
             "scroll", "--dy", "100", "--snapshot-after"],
            method: "browser.scroll"
        ))
    }

    func testSidebarMetadataParserOptionsAndAliasesReachHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [[String]] = [
            ["set-status", "k", "v", "--panel", panelID, "--priority", "5", "--url", "http://x", "--format", "markdown"],
            ["set-status", "k", "v", "--tab", "panel:1"],
            ["set-status", "k", "v", "--panel=panel:1"],
            ["set-progress", "0.5", "--panel", panelID, "--label", "build"],
            ["log", "--level", "error", "--source", "build", "--panel", panelID, "--", "- literal"],
            ["clear-status", "build", "--panel", panelID],
        ]
        for command in cases {
            XCTAssertTrue(assertCommandReachesSocket(command), "Rejected or failed to reach socket: \(command)")
        }
    }

    func testParserAcceptedMetadataAndAttentionOptionsReachHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let cases: [([String], String)] = [
            (["set-metadata", "--panel", panelID, "--json-input", "{\"k\":\"v\"}"], "panel.set_metadata"),
            (["set-metadata", "--panel", panelID, "--body", "{\"k\":\"v\"}"], "panel.set_metadata"),
            (["get-metadata", "--panel", panelID, "--include-sources"], "panel.get_metadata"),
            (["get-workspace-metadata", "--workspace", workspaceID, "--key", "description"], "workspace.get_metadata"),
            (["set-workspace-description", "--workspace", workspaceID, "--value", "hello"], "workspace.set_metadata"),
            (["set-workspace-icon", "--workspace", workspaceID, "--value", "sf:star.fill"], "workspace.set_metadata"),
            (["raise-flag", "--workspace", workspaceID, "--panel", panelID, "--by", "operator", "--json", "reason"], "flag.raise"),
            (["raise-flag", "--panel", panelID, "--kind", "chief-of-staff", "reason"], "flag.raise"),
            (["flag-kind", "list"], "flag.kind.list"),
            (["flag-kind", "set", "--id", "release-review", "--name", "Release Review", "--color", "pink", "--emoji", "🧪"], "flag.kind.set"),
            (["flag-kind", "rm", "--id", "release-review"], "flag.kind.rm"),
            (["machine", "list", "--json"], "machine.list"),
            (["machine", "set", "--id", "studio", "--name", "Studio", "--color", "#3FA7D6"], "machine.set"),
            (["machine", "set", "--id", "local", "--clear-name", "--clear-color"], "machine.set"),
            (["machine", "rm", "--id", "studio"], "machine.rm"),
            (["lower-flag", "--window", "window:1", "--panel", panelID, "--json"], "flag.lower"),
        ]
        for (command, method) in cases {
            XCTAssertTrue(assertCommandReachesSocket(command, method: method), "Rejected or missed \(method): \(command)")
        }
        XCTAssertTrue(assertCommandReachesSocket(
            ["clear-notifications", "--workspace", workspaceID]
        ))

        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let missingKind = runCLI(
            ["raise-flag", "--panel", socket.panelIDForAssertions, "--kind"],
            socketPath: socket.path
        ) else { return }
        XCTAssertNotEqual(missingKind.status, 0)
        // The CLI has exited, so a connection it made is already queued.
        XCTAssertFalse(socket.waitUntilFinished(timeout: 0.2), "a missing --kind value must fail before socket I/O")
        XCTAssertTrue(socket.requests.isEmpty)

        guard let adHocSocket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let adHocColor = runCLI(
            ["raise-flag", "--panel", adHocSocket.panelIDForAssertions, "--color", "red", "reason"],
            socketPath: adHocSocket.path
        ) else { return }
        XCTAssertNotEqual(adHocColor.status, 0)
        XCTAssertTrue(adHocColor.stderr.contains("unknown flag '--color'"), adHocColor.stderr)
        XCTAssertTrue(adHocSocket.requests.isEmpty, "per-raise colors must fail before socket I/O")
    }

    /// C11H-126: a `machine set` that changes nothing, or both sets and
    /// clears one field, fails before any socket I/O.
    func testMachineSetWithoutAChangeFailsBeforeTheSocket() {
        for args in [
            ["machine", "set", "--id", "studio"],
            ["machine", "set", "--id", "studio", "--name", "A", "--clear-name"],
            ["machine", "set", "--name", "A"],
        ] {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(args, socketPath: socket.path) else { return }
            XCTAssertNotEqual(result.status, 0, "\(args)")
            XCTAssertTrue(socket.requests.isEmpty, "\(args) must fail before socket I/O")
        }
    }

    /// C11H-332: linking gives c11 a shell on that machine as the operator,
    /// so inside a c11 terminal (an agent's tool shell included) `--yes` is
    /// refused before anything is reached; outside one, a non-terminal stdin
    /// without `--yes` is still refused. Fails with the guard removed (the
    /// command would go on to resolve hc and try SSH).
    func testMachineLinkRefusesYesInsideAC11Terminal() {
        guard let inside = runCLI(["machine", "link", "--host", "studio", "--yes"],
                                  environmentOverrides: ["C11_PANEL_ID": UUID().uuidString]) else { return }
        XCTAssertNotEqual(inside.status, 0)
        XCTAssertTrue(inside.stderr.contains("--yes isn't accepted inside a c11 terminal"), inside.stderr)
        XCTAssertTrue(inside.stderr.contains("a shell on studio as you"), inside.stderr)
        guard let unasked = runCLI(["machine", "link", "--host", "studio"]) else { return }
        XCTAssertNotEqual(unasked.status, 0)
        XCTAssertTrue(unasked.stdout.contains("Linking gives c11 a shell on studio as you."), "the consent is printed first: \(unasked.stdout)")
        XCTAssertTrue(unasked.stderr.contains("not confirmed"), unasked.stderr)
    }

    /// C11H-332: `machine audit` reads the log file, so it answers with no app
    /// and no socket at all.
    func testMachineAuditWorksWithoutASocket() {
        guard let result = runCLI(["machine", "audit", "--json", "--limit", "1"]) else { return }
        XCTAssertEqual(result.status, 0, result.stderr)
        let object = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
        XCTAssertNotNil(object?["records"] as? [Any], result.stdout)
        // Spawned from a test, the CLI reads a scratch log, never the real one.
        XCTAssertNotNil(object?["path"] as? String, result.stdout)
        XCTAssertFalse((object?["path"] as? String)?.contains("/Library/Application Support/") == true, result.stdout)
        guard let bad = runCLI(["machine", "audit", "--kind", "everything"]) else { return }
        XCTAssertNotEqual(bad.status, 0)
        XCTAssertTrue(bad.stderr.contains("remote_launch"), "an unknown kind lists the kinds: \(bad.stderr)")
    }

    func testClaudeTeamsTmuxConfigurationCommandsRemainNoOps() {
        let cases: [[String]] = [
            ["__tmux-compat", "select-layout", "-t", "@1", "tiled"],
            ["__tmux-compat", "select-layout", "-t", "@1", "main-vertical"],
            ["__tmux-compat", "set-option", "-p", "-t", "%1", "pane-border-style", "fg=blue"],
            ["__tmux-compat", "set-option", "-w", "-t", "@1", "pane-border-status", "top"],
            ["__tmux-compat", "set-option", "-p", "-t", "%1", "remain-on-exit", "failed"],
            ["__tmux-compat", "set-window-option", "-t", "@1", "pane-base-index", "1"],
            ["__tmux-compat", "setw", "-t", "@1", "pane-base-index", "1"],
            ["__tmux-compat", "source-file", "-q", "~/.tmux.conf"],
            ["__tmux-compat", "refresh-client", "-S"],
            ["__tmux-compat", "attach-session", "-t", "@1"],
            ["__tmux-compat", "detach-client", "-E"],
        ]
        for command in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(command, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(command)")
            XCTAssertTrue(socket.requests.isEmpty, "no-op issued a request: \(socket.requests)")
        }
    }

    func testBrowserScriptAndStyleOptionsReachHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [([String], String)] = [
            (["browser", "--panel", panelID, "addscript", "--script", "console.log(1)"], "browser.addscript"),
            (["browser", "--panel", panelID, "addstyle", "--css", "body{}"], "browser.addstyle"),
        ]

        for (command, method) in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(command, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(command)")
            XCTAssertTrue(
                socket.requests.contains(where: { $0["method"] as? String == method }),
                "Expected \(method) for \(command), got \(socket.requests)"
            )
        }
    }

    func testClaudeTeamsForwardsChildFlagsWithoutC11Preflight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-cli-claude-teams-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let received = root.appendingPathComponent("claude-args.txt")
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$C11_CLI_TEST_CLAUDE_ARGS\"\nexit 17\n"
            .write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        guard let result = runCLI(
            ["claude-teams", "--continue", "--model", "sonnet"],
            environmentOverrides: [
                "PATH": bin.path,
                "HOME": home.path,
                "C11_CLI_TEST_CLAUDE_ARGS": received.path,
            ]
        ) else { return }
        XCTAssertEqual(result.status, 17, result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertEqual(
            try String(contentsOf: received, encoding: .utf8),
            "--teammate-mode\nauto\n--continue\n--model\nsonnet\n"
        )
    }

    func testLinkFormatsAndJSONResolveLivePanelAcrossWindows() throws {
        let url = "c11://panel/\(Self.linkPanelB)"
        let markdown = "[\\[Agent\\] Two](\(url))"
        let osc8 = "\u{1B}]8;;\(url)\u{1B}\\[Agent] Two\u{1B}]8;;\u{1B}\\"
        for (format, expected) in [("url", url), ("markdown", markdown), ("osc8", osc8)] {
            let socket = try makeLinkSocket()
            let result = try XCTUnwrap(runCLI(["link", "--panel=panel:2", "--format=\(format)"], socketPath: socket.path))
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.stdout, expected + "\n")
            assertLinkInventoryOnly(socket)
        }
        let socket = try makeLinkSocket()
        let result = try XCTUnwrap(runCLI(["--id-format", "refs", "link", "--tab", Self.linkPanelB.uppercased(), "--json"], socketPath: socket.path))
        XCTAssertEqual(result.status, 0, result.stderr)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, "panel")
        XCTAssertEqual(payload["id"] as? String, Self.linkPanelB)
        XCTAssertEqual(payload["title"] as? String, "[Agent] Two")
        XCTAssertEqual(payload["url"] as? String, url)
        XCTAssertEqual(payload["markdown"] as? String, markdown)
        XCTAssertEqual(payload["osc8"] as? String, osc8)
        XCTAssertFalse(result.stdout.contains("\u{1B}"))
        XCTAssertEqual((payload["workspace"] as? [String: Any])?["id"] as? String, Self.linkWorkspaceB)
        XCTAssertEqual((payload["workspace"] as? [String: Any])?["title"] as? String, "Second project")
        assertLinkInventoryOnly(socket)
    }

    func testLinkHonorsWindowAndWorkspaceScope() throws {
        let cases: [([String], String?)] = [
            (["--window", "window:2", "link", "--workspace", "workspace:2"], "c11://workspace/\(Self.linkWorkspaceB)"),
            (["--window", "window:2", "link", "--panel", "panel:2", "--workspace", "workspace:2"], "c11://panel/\(Self.linkPanelB)"),
            (["--window", "window:1", "link", "--workspace", Self.linkWorkspaceB], nil),
            (["--window", "window:1", "link", "--panel", Self.linkPanelB], nil),
            (["link", "--panel", "panel:2", "--workspace", Self.linkWorkspaceA], nil),
        ]
        for (argv, expected) in cases {
            let socket = try makeLinkSocket()
            let result = try XCTUnwrap(runCLI(argv, socketPath: socket.path))
            if let expected {
                XCTAssertEqual(result.status, 0, result.stderr)
                XCTAssertEqual(result.stdout, expected + "\n")
            } else {
                XCTAssertNotEqual(result.status, 0)
                XCTAssertTrue(result.stderr.contains("not_found:"), result.stderr)
                XCTAssertTrue(result.stdout.isEmpty)
            }
            if argv.first == "--window" {
                let expectedWindow = argv[1] == "window:1" ? Self.linkWindowA : Self.linkWindowB
                for request in socket.requests where ["workspace.list", "panel.list"].contains(request["method"] as? String ?? "") {
                    XCTAssertEqual((request["params"] as? [String: Any])?["window_id"] as? String, expectedWindow)
                }
            }
            assertLinkInventoryOnly(socket)
        }
    }

    /// `--name=value` reaches the parser as `--name value`, so every parser
    /// reads the `=` form of every declared value option.
    func testInlineValueOptionReachesParserAsSeparatedValue() {
        func request(_ argv: [String]) -> [String: Any]? {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return nil }
            XCTAssertEqual(result.status, 0, "\(argv): \(result.stderr)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(argv)")
            return socket.requests.first(where: { $0["method"] as? String == "panel.get_metadata" })?["params"] as? [String: Any]
        }
        let panel = Self.declPanelID
        let separated = request(["get-metadata", "--panel", panel, "--key", "title"])
        let inline = request(["get-metadata", "--panel=\(panel)", "--key=title"])
        XCTAssertEqual(separated?["keys"] as? [String], ["title"])
        XCTAssertEqual(inline?["keys"] as? [String], ["title"])
        XCTAssertEqual(inline?["panel_id"] as? String, separated?["panel_id"] as? String)
        XCTAssertNotNil(inline?["panel_id"])
    }

    /// Words after a trailing-command parser's options are the command line.
    func testTrailingCommandTextReachesHandler() {
        guard let socket = try? CapturedCLISocket(),
              let result = runCLI(["respawn-pane", "--panel", Self.declPanelID, "ls", "-la"], socketPath: socket.path)
        else { return }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving respawn-pane")
        let text = socket.requests.first(where: { $0["method"] as? String == "panel.send_text" })?["params"]
            .flatMap { ($0 as? [String: Any])?["text"] as? String }
        XCTAssertTrue(text?.hasSuffix("ls -la\n") ?? false, String(describing: text))
    }

    /// An explicit ref, or `self`, closes exactly that target.
    func testCloseCommandsCloseExactlyTheNamedOrSelfTarget() {
        let cases: [(argv: [String], method: String, key: String, value: String)] = [
            (["close-panel", "--panel", Self.closeOther], "panel.close", "panel_id", Self.closeOther),
            (["close-panel", "--panel=\(Self.closeOther)"], "panel.close", "panel_id", Self.closeOther),
            (["close-panel", "--panel", "self"], "panel.close", "panel_id", Self.closeCaller),
            (["close-tab", "--tab", "self"], "panel.close", "panel_id", Self.closeCaller),
            (["close-surface", "--surface", "self"], "panel.close", "panel_id", Self.closeCaller),
            (["close-workspace", "--workspace", "self"], "workspace.close", "workspace_id", Self.closeWorkspace),
            (["panel-action", "--panel", "self", "--action", "close-right"], "panel.action", "panel_id", Self.closeCaller),
            (["workspace-action", "--workspace", "self", "close-below"], "workspace.action", "workspace_id", Self.closeWorkspace),
        ]
        for (argv, method, key, value) in cases {
            guard let run = runClose(argv) else { return }
            XCTAssertEqual(run.result.status, 0, "\(argv): \(run.result.stderr)")
            _ = run.socket.waitUntilFinished()
            let params = run.socket.requests.first(where: { $0["method"] as? String == method })?["params"] as? [String: Any]
            XCTAssertEqual(params?[key] as? String, value, "\(argv): \(run.socket.requests)")
        }
    }

    func testCloseWindowSelfClosesTheCallersWindow() {
        let window = "bbb11111-2222-3333-4444-555566667777"
        guard let run = runClose(["close-window", "--window", "self"], configure: {
            $0.reply(to: "system.identify", with: ["caller": ["window_id": window]])
        }) else { return }
        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        _ = run.socket.waitUntilFinished()
        let identify = run.socket.requests.first(where: { $0["method"] as? String == "system.identify" })?["params"] as? [String: Any]
        XCTAssertEqual((identify?["caller"] as? [String: Any])?["workspace_id"] as? String, Self.closeWorkspace)
        XCTAssertEqual(run.socket.legacyCommands, ["close_window \(window)"])
    }
}

// MARK: - CLIDeclaredSurfaceTests

final class CLIDeclaredSurfaceTests: CLIResolutionTestCase {}

extension CLIDeclaredSurfaceTests {
    func testEveryFlagAParserReadsIsDeclared() throws {
        signal(SIGPIPE, SIG_IGN)
        let cli = try bundledCLI()
        var findings: [String] = []
        for (argv, run) in try Self.declarationWalk(cli: cli) {
            if let finding = Self.declarationFinding(argv: argv, result: run) { findings.append(finding) }
        }
        XCTAssertEqual(findings.sorted(), [], findings.sorted().joined(separator: "\n"))
    }

    /// For every path with a bounded arity, one word past the bound fails
    /// before the socket with "unexpected argument".
    func testEveryBoundedArityRejectsOneMoreWord() throws {
        // The fake socket may answer a CLI that already exited.
        signal(SIGPIPE, SIG_IGN)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11-481-arity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = try bundledCLI()
        let lock = NSLock()
        var findings: [String] = []
        var bounded = 0
        let walk = try Self.declarationWalk(cli: cli)
        DispatchQueue.concurrentPerform(iterations: walk.count) { index in
            let (argv, first) = walk[index]
            guard case .success(let run) = first,
                  run.arity.hasPrefix("atMost:"), let limit = Int(run.arity.dropFirst("atMost:".count)) else { return }
            let extra = Array(repeating: "stray-c11-481", count: max(1, limit - run.positionals + 1))
            let label = (argv + extra).joined(separator: " ")
            var finding: String?
            switch Self.declarationRun(argv: argv + extra, cli: cli, directory: directory, expectRejection: true, makeSocket: { try CapturedCLISocket() }) {
            case .failure(let message):
                finding = message
            case .success(let rejected):
                if !rejected.stderr.contains("unexpected argument 'stray-c11-481'") {
                    finding = "\(label): not rejected as a stray word: \(rejected.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                } else if !rejected.requests.isEmpty {
                    finding = "\(label): reached the socket: \(rejected.requests)"
                }
            }
            lock.lock()
            bounded += 1
            if let finding { findings.append(finding) }
            lock.unlock()
        }
        XCTAssertEqual(findings.sorted(), [], findings.sorted().joined(separator: "\n"))
        XCTAssertGreaterThan(bounded, 50, "expected most paths to declare a bound")
    }
}

// MARK: - C11H-170: themes set --with-terminal

/// `c11 themes set --with-terminal`, run through the bundled CLI against a fake socket.
/// The terminal override goes to a temporary file (`C11_QA_TERMINAL_THEME_CONFIG`), so no
/// test writes this machine's real one. Bundled themes are read from the built app, and
/// Ghostty files are checked with the app's own Ghostty helper.
final class CLIThemesWithTerminalTests: CLIResolutionTestCase {
    private static let bundledPairs: [String: String] = [
        "datasheet-mono": "c11-datasheet-mono",
        "terminal-grid": "c11-terminal-grid",
        "outrun-horizon": "c11-outrun-horizon",
        "nocturne": "c11-nocturne",
        "bigboard": "c11-bigboard",
    ]

    /// The keys of `--json`'s `terminal` object, the same in every outcome.
    private static let terminalKeys: Set<String> = [
        "applied", "reason", "error", "paired_theme", "light", "dark", "raw_value", "config_path",
        "reload_requested", "reload_target_bundle_id",
    ]

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11-170-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func temporaryConfig() throws -> URL {
        try temporaryDirectory().appendingPathComponent("config.ghostty")
    }

    private func qaEnvironment(_ config: URL) -> [String: String] {
        ["C11_QA_LAUNCH": "fresh", "C11_QA_TERMINAL_THEME_CONFIG": config.path, "GHOSTTY_RESOURCES_DIR": "", "XDG_DATA_DIRS": ""]
    }

    /// The built app's `Contents/Resources`.
    private func bundleResources() throws -> URL {
        try bundledCLI().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Runs the app's bundled Ghostty helper on `config`; nil when the build carries the stub
    /// a zig-less build installs.
    private func ghosttyValidate(_ config: URL) throws -> (status: Int32, output: String)? {
        let resources = try bundleResources()
        let helper = resources.appendingPathComponent("bin/ghostty")
        let head = try FileHandle(forReadingFrom: helper).readData(ofLength: 2)
        if head == Data("#!".utf8) { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = helper
        process.arguments = ["+validate-config", "--config-file=\(config.path)"]
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTTY_RESOURCES_DIR"] = resources.appendingPathComponent("ghostty").path
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if exited.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            XCTFail("Ghostty helper did not exit within 10 seconds")
            return nil
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func assertGhosttyAccepts(_ config: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let result = try ghosttyValidate(config) else {
            throw XCTSkip("this build carries the Ghostty helper stub")
        }
        XCTAssertEqual(result.status, 0, "\(config.lastPathComponent): \(result.output)", file: file, line: line)
    }

    /// A socket whose `nocturne` pairs with `pair`; nil leaves the key out, as an app from
    /// before pairing does.
    private func themeSocket(pair: Any?, listReply: [String: Any]? = nil) throws -> CapturedCLISocket {
        let socket = try CapturedCLISocket()
        socket.reply { request in
            let params = request["params"] as? [String: Any] ?? [:]
            switch request["method"] as? String {
            case "theme.list":
                if let listReply { return listReply }
                var nocturne: [String: Any] = ["name": "nocturne", "display_name": "Nocturne", "source": "builtin", "schema": 2, "is_active": false]
                if let pair { nocturne[TerminalThemePairing.pairKey] = pair }
                return ["themes": [nocturne], "active": "stage11"]
            case "theme.set_active":
                return ["ok": true, "name": params["name"] ?? "", TerminalThemePairing.pairKey: pair ?? NSNull()]
            default:
                return nil
            }
        }
        return socket
    }

    private func methods(_ socket: CapturedCLISocket) -> [String] {
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish")
        return socket.requests.compactMap { $0["method"] as? String }.filter { $0.hasPrefix("theme.") }
    }

    private func contents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func terminalObject(_ stdout: String) throws -> [String: Any] {
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        let terminal = try XCTUnwrap(payload["terminal"] as? [String: Any])
        XCTAssertEqual(Set(terminal.keys), Self.terminalKeys)
        return terminal
    }

    // MARK: The bundle

    func testBundledChromeThemesPairAsDesigned() throws {
        let directory = try bundleResources().appendingPathComponent("c11-themes")
        var names: Set<String> = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "toml" {
            let theme = try C11Theme.fromToml(try TomlSubsetParser.parse(file: url.path, source: try String(contentsOf: url, encoding: .utf8)))
            names.insert(theme.identity.name)
            XCTAssertEqual(theme.pairedTerminalTheme, Self.bundledPairs[theme.identity.name], theme.identity.name)
        }
        XCTAssertTrue(names.isSuperset(of: Set(Self.bundledPairs.keys).union(["c11", "stage11"])), "\(names.sorted())")
    }

    func testEveryBundledPairIsAThemeGhosttyAccepts() throws {
        let themes = try bundleResources().appendingPathComponent("ghostty/themes")
        for pair in Self.bundledPairs.values.sorted() {
            try assertGhosttyAccepts(themes.appendingPathComponent(pair))
        }
    }

    func testBundleShipsEveryPairedTerminalTheme() throws {
        let config = try temporaryConfig()
        let result = try XCTUnwrap(runCLI(["terminal-theme", "list", "--json"], environmentOverrides: qaEnvironment(config)))
        XCTAssertEqual(result.status, 0, result.stderr)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let names = Set((payload["themes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        let pairs = Set(Self.bundledPairs.values)
        XCTAssertTrue(pairs.isSubset(of: names), "missing \(pairs.subtracting(names).sorted())")
        XCTAssertEqual(payload["config_path"] as? String, config.path)
    }

    // MARK: Applying the pair

    func testWithTerminalSetsThePairDayAndNight() throws {
        let config = try temporaryConfig()
        let socket = try themeSocket(pair: "c11-nocturne")
        let result = try XCTUnwrap(runCLI(["themes", "set", "nocturne", "--with-terminal"], socketPath: socket.path,
                                          environmentOverrides: qaEnvironment(config)))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(methods(socket), ["theme.list", "theme.set_active"])
        XCTAssertTrue(contents(config)?.contains("theme = light:c11-nocturne,dark:c11-nocturne") == true, contents(config) ?? "no config")
        XCTAssertTrue(result.stdout.contains("OK theme=nocturne terminal_light=c11-nocturne terminal_dark=c11-nocturne"), result.stdout)
        try assertGhosttyAccepts(config)
    }

    func testWithTerminalReplacesTheTerminalThemeAndKeepsTheRestOfTheFile() throws {
        let config = try temporaryConfig()
        try "font-size = 13\n\n# cmux themes start\ntheme = light:Catppuccin Latte,dark:Catppuccin Mocha\n# cmux themes end\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let socket = try themeSocket(pair: "c11-nocturne")
        let result = try XCTUnwrap(runCLI(["themes", "set", "nocturne", "--with-terminal", "--json"],
                                          socketPath: socket.path, environmentOverrides: qaEnvironment(config)))
        XCTAssertEqual(result.status, 0, result.stderr)
        let written = contents(config) ?? ""
        XCTAssertTrue(written.contains("theme = light:c11-nocturne,dark:c11-nocturne"), written)
        XCTAssertFalse(written.contains("Catppuccin"), written)
        XCTAssertTrue(written.contains("font-size = 13"), written)
        let terminal = try terminalObject(result.stdout)
        XCTAssertEqual(terminal["applied"] as? Bool, true)
        XCTAssertEqual(terminal["light"] as? String, "c11-nocturne")
        XCTAssertEqual(terminal["dark"] as? String, "c11-nocturne")
        XCTAssertEqual(terminal["config_path"] as? String, config.path)
        XCTAssertTrue(terminal["reason"] is NSNull)
        try assertGhosttyAccepts(config)
    }

    /// c11 has one theme: `--slot` is refused with the command to run instead, before
    /// anything reaches the app or the terminal config.
    func testTheRetiredSlotOptionIsRefusedAndChangesNothing() throws {
        let config = try temporaryConfig()
        for args in [["themes", "set", "nocturne", "--slot", "dark", "--with-terminal"], ["themes", "get", "--slot", "light"]] {
            let socket = try themeSocket(pair: "c11-nocturne")
            let result = try XCTUnwrap(runCLI(args, socketPath: socket.path, environmentOverrides: qaEnvironment(config)))
            XCTAssertNotEqual(result.status, 0, args.joined(separator: " "))
            XCTAssertTrue(result.stderr.contains("--slot is gone"), result.stderr)
            XCTAssertTrue(result.stderr.contains("c11 themes \(args[1])"), result.stderr)
            XCTAssertTrue(socket.requests.compactMap { $0["method"] as? String }.filter { $0.hasPrefix("theme.") }.isEmpty)
            XCTAssertNil(contents(config))
        }
    }

    func testTerminalThemeSetOneSlotWithNoThemeWritesBothHalves() throws {
        let config = try temporaryConfig()
        let result = try XCTUnwrap(runCLI(["terminal-theme", "set", "--dark", "c11-bigboard"], environmentOverrides: qaEnvironment(config)))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(contents(config)?.contains("theme = light:c11-bigboard,dark:c11-bigboard") == true, contents(config) ?? "no config")
        try assertGhosttyAccepts(config)
    }

    // MARK: Outcomes that leave the terminal alone

    func testThemeWithoutAPairSetsTheChromeAndLeavesTheTerminal() throws {
        let config = try temporaryConfig()
        let socket = try themeSocket(pair: NSNull())
        let result = try XCTUnwrap(runCLI(["themes", "set", "nocturne", "--with-terminal", "--json"], socketPath: socket.path,
                                          environmentOverrides: qaEnvironment(config)))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(methods(socket), ["theme.list", "theme.set_active"])
        XCTAssertNil(contents(config))
        let terminal = try terminalObject(result.stdout)
        XCTAssertEqual(terminal["applied"] as? Bool, false)
        XCTAssertEqual(terminal["reason"] as? String, "no_pair")
    }

    func testTerminalWriteFailureSaysTheChromeChanged() throws {
        // A regular file where the config's folder should be: the write cannot happen.
        let blocker = try temporaryDirectory().appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let config = blocker.appendingPathComponent("config.ghostty")
        for json in [false, true] {
            let socket = try themeSocket(pair: "c11-nocturne")
            let result = try XCTUnwrap(runCLI(["themes", "set", "nocturne", "--with-terminal"] + (json ? ["--json"] : []),
                                              socketPath: socket.path, environmentOverrides: qaEnvironment(config)))
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderr.contains("theme set to nocturne; terminal unchanged"), result.stderr)
            XCTAssertEqual(methods(socket), ["theme.list", "theme.set_active"])
            if json {
                let terminal = try terminalObject(result.stdout)
                XCTAssertEqual(terminal["applied"] as? Bool, false)
                XCTAssertEqual(terminal["reason"] as? String, "write_failed")
                XCTAssertNotNil(terminal["error"] as? String)
            }
        }
    }

    // MARK: Outcomes that change nothing

    func testPairThatIsNotInstalledChangesNothing() throws {
        let config = try temporaryConfig()
        let socket = try themeSocket(pair: "c11-no-such-terminal-theme")
        let result = try XCTUnwrap(runCLI(["themes", "set", "nocturne", "--with-terminal"], socketPath: socket.path,
                                          environmentOverrides: qaEnvironment(config)))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not installed; nothing changed"), result.stderr)
        XCTAssertEqual(methods(socket), ["theme.list"])
        XCTAssertNil(contents(config))
    }

    func testAppWithoutPairingChangesNothing() throws {
        let config = try temporaryConfig()
        let socket = try themeSocket(pair: nil)
        let result = try XCTUnwrap(runCLI(["themes", "set", "nocturne", "--with-terminal"], socketPath: socket.path,
                                          environmentOverrides: qaEnvironment(config)))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("does not report terminal pairs"), result.stderr)
        XCTAssertEqual(methods(socket), ["theme.list"])
        XCTAssertNil(contents(config))
    }

    func testUnreadableThemeListChangesNothing() throws {
        let config = try temporaryConfig()
        for reply: [String: Any] in [[:], ["ok": false, "error": "theme engine busy"]] {
            let socket = try themeSocket(pair: "c11-nocturne", listReply: reply)
            let result = try XCTUnwrap(runCLI(["themes", "set", "nocturne", "--with-terminal"], socketPath: socket.path,
                                              environmentOverrides: qaEnvironment(config)))
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderr.contains("could not read terminal pairs"), result.stderr)
            XCTAssertTrue(result.stderr.contains("nothing changed"), result.stderr)
            XCTAssertEqual(methods(socket), ["theme.list"])
            XCTAssertNil(contents(config))
        }
    }

    func testWithoutTheFlagTheTerminalIsUntouched() throws {
        let config = try temporaryConfig()
        let socket = try themeSocket(pair: "c11-nocturne")
        let result = try XCTUnwrap(runCLI(["themes", "set", "nocturne"], socketPath: socket.path,
                                          environmentOverrides: qaEnvironment(config)))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(methods(socket), ["theme.set_active"])
        XCTAssertNil(contents(config))
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK theme=nocturne")
    }
}

// MARK: - C11H-236: config launch argv boundaries

extension CLIResolutionSnapshotTests {
    /// The `config.launch` params the real CLI sends to a disposable socket.
    private func configLaunchParams(
        _ args: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let socket = try CapturedCLISocket()
        let result = try XCTUnwrap(runCLI(args, socketPath: socket.path), file: file, line: line)
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish", file: file, line: line)
        let launch = socket.requests.first { $0["method"] as? String == "config.launch" }
        let params = launch?["params"] as? [String: Any]
        return try XCTUnwrap(params, "no config.launch in \(socket.requests)", file: file, line: line)
    }

    func testConfigLaunchLiteralFlagValuesDoNotDelegate() throws {
        let cases: [(args: [String], key: String, value: String)] = [
            (["config", "launch", "Opus", "--title=--delegated"], "title", "--delegated"),
            (["config", "launch", "Opus", "--prompt=--delegated"], "prompt", "--delegated"),
            (["config", "launch", "Opus", "--title=--suppressed"], "title", "--suppressed"),
            (["config", "launch", "Opus", "--prompt=--suppressed"], "prompt", "--suppressed"),
            (["config", "launch", "Opus", "--title", "--delegated"], "title", "--delegated"),
            (["config", "launch", "Opus", "--prompt", "--suppressed"], "prompt", "--suppressed"),
            (["config", "launch", "Opus", "--workspace=--delegated"], "workspace", "--delegated"),
            (["config", "launch", "Opus", "--area", "--suppressed"], "pane", "--suppressed"),
        ]
        for sample in cases {
            let params = try configLaunchParams(sample.args)
            XCTAssertEqual(params["config"] as? String, "Opus", "\(sample.args)")
            XCTAssertNil(params["delegated"], "\(sample.args)")
            XCTAssertNil(params["suppressed"], "\(sample.args)")
            XCTAssertEqual(params[sample.key] as? String, sample.value, "\(sample.args)")
        }
    }

    func testConfigLaunchDelegatedBeforeTheNameFindsTheName() throws {
        for flag in ["--delegated", "--suppressed"] {
            let params = try configLaunchParams(["config", "launch", flag, "Opus"])
            XCTAssertEqual(params["config"] as? String, "Opus", flag)
            XCTAssertEqual(params["delegated"] as? Bool, true, flag)
            XCTAssertEqual(params["suppressed"] as? Bool, true, flag)
            XCTAssertNil(params["title"], flag)
        }
    }

    func testConfigLaunchDelegatedFlagStillDelegatesWhenTheTitleLooksLikeAFlag() throws {
        let params = try configLaunchParams([
            "config", "launch", "--delegated", "Opus", "--title=--suppressed",
        ])
        XCTAssertEqual(params["config"] as? String, "Opus")
        XCTAssertEqual(params["delegated"] as? Bool, true)
        XCTAssertEqual(params["suppressed"] as? Bool, true)
        XCTAssertEqual(params["title"] as? String, "--suppressed")
    }
}

/// C11H-299: the workspace-metadata commands address a workspace group with
/// `--group`, through the `workspace.group.*_metadata` methods.
extension CLIResolutionSnapshotTests {
    func testWorkspaceMetadataGroupFlagRoutesToGroupMethods() throws {
        let groupID = UUID().uuidString
        let cases: [([String], String, ([String: Any]) -> Void)] = [
            (["set-workspace-metadata", "--group", groupID, "captain", "acme-captain"], "workspace.group.set_metadata", {
                XCTAssertEqual(($0["metadata"] as? [String: String])?["captain"], "acme-captain")
                XCTAssertEqual($0["source"] as? String, "explicit")
            }),
            (["get-workspace-metadata", "--group", groupID, "--key", "captain", "--sources"], "workspace.group.get_metadata", {
                XCTAssertEqual($0["keys"] as? [String], ["captain"])
                XCTAssertEqual($0["include_sources"] as? Bool, true)
            }),
            (["clear-workspace-metadata", "--group", groupID, "--key", "captain"], "workspace.group.clear_metadata", {
                XCTAssertEqual($0["keys"] as? [String], ["captain"])
            })
        ]
        for (command, method, check) in cases {
            let socket = try CapturedCLISocket()
            guard let result = runCLI(command, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, result.stderr)
            let request = try XCTUnwrap(socket.requests.first { $0["method"] as? String == method }, "\(command)")
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["group_id"] as? String, groupID)
            XCTAssertNil(params["workspace_id"], "a group write never names a workspace")
            check(params)
            XCTAssertFalse(socket.requests.contains { ($0["method"] as? String)?.hasPrefix("workspace.") == true
                && ($0["method"] as? String)?.hasPrefix("workspace.group.") == false },
                "no workspace metadata method is sent for --group")
        }
    }

    func testWorkspaceMetadataRefusesBothGroupAndWorkspace() throws {
        let socket = try CapturedCLISocket()
        guard let result = runCLI(["set-workspace-metadata", "--group", UUID().uuidString,
                                   "--workspace", UUID().uuidString, "captain", "x"], socketPath: socket.path) else { return }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("--group"), result.stderr)
        XCTAssertFalse(socket.requests.contains { ($0["method"] as? String)?.hasSuffix("set_metadata") == true })
    }

    func testWorkspaceMetadataWindowFlagNeedsGroup() throws {
        let socket = try CapturedCLISocket()
        guard let result = runCLI(["get-workspace-metadata", "--workspace", UUID().uuidString,
                                   "--window", UUID().uuidString], socketPath: socket.path) else { return }
        XCTAssertNotEqual(result.status, 0, "--window never chooses a workspace")
        XCTAssertTrue(result.stderr.contains("--window"), result.stderr)
        XCTAssertFalse(socket.requests.contains { ($0["method"] as? String)?.hasSuffix("get_metadata") == true })
    }
}


// MARK: - C11H-282: a socket variable that is not c11's is refused by name, never replaced

final class CLISocketOverrideTests: CLIResolutionTestCase {}

extension CLISocketOverrideTests {
    /// A 1.x script's own socket in any of the four variables: the CLI exits 1
    /// naming the variable, the path and the way out, instead of driving
    /// another c11 without a word. No socket is probed, so parallel tests'
    /// sockets are never touched.
    func testForeignSocketVariableIsRefusedByNameNotReplaced() {
        let foreign = "/tmp/mine-\(UUID().uuidString).sock"
        for key in ["C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
            guard let result = runCLI(["ping"], passSocketFlag: false,
                                      environmentOverrides: [key: foreign]) else { return }
            XCTAssertEqual(result.status, 1, "\(key): \(result.stdout) \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("\(key)=\(foreign) is not a c11 socket"), "\(key): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("--socket \(foreign)"), result.stderr)
            XCTAssertFalse(result.stderr.contains("Socket not found"), result.stderr)
        }
    }

    /// The highest-precedence variable decides: a foreign `C11_SOCKET` is
    /// refused even when a lower variable names a live c11 socket.
    func testForeignVariableIsNotSkippedForALowerOne() throws {
        let socket = try CapturedCLISocket()
        let foreign = "/tmp/mine-\(UUID().uuidString).sock"
        guard let result = runCLI(["ping"], passSocketFlag: false, environmentOverrides: [
            "C11_SOCKET": foreign, "CMUX_SOCKET_PATH": socket.path,
        ]) else { return }
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("C11_SOCKET=\(foreign) is not a c11 socket"), result.stderr)
        XCTAssertTrue(socket.legacyCommands.isEmpty, "\(socket.legacyCommands)")
    }

    /// Terminals c11 adopted from c11h, and cmux's, export their own product's
    /// socket. Those are skipped, never refused or used: the next variable
    /// naming c11's socket is the one the CLI talks to.
    func testAnotherProductsSocketIsSkippedForC11s() throws {
        let c11hSocket = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)/Library/Application Support/c11h/c11h.sock").path
        for other in [c11hSocket, "/tmp/cmux-\(UUID().uuidString).sock"] {
            let socket = try CapturedCLISocket()
            guard let result = runCLI(["ping"], passSocketFlag: false, environmentOverrides: [
                "C11_SOCKET_PATH": other, "CMUX_SOCKET_PATH": socket.path,
            ]) else { return }
            XCTAssertEqual(result.status, 0, "\(other): \(result.stderr)")
            // The CLI has exited, so the fake server finishes at once; the bound
            // only absorbs a loaded host's thread scheduling.
            XCTAssertTrue(socket.waitUntilFinished(timeout: 10), other)
            XCTAssertEqual(socket.legacyCommands.filter { $0 == "ping" }.count, 1, "\(other): \(socket.legacyCommands)")
            XCTAssertFalse(result.stderr.contains("is not a c11 socket"), result.stderr)
        }
    }

    /// `--socket` is an explicit choice and takes any path, over a refused variable.
    func testSocketFlagTakesPrecedenceOverARefusedVariable() throws {
        let socket = try CapturedCLISocket()
        guard let result = runCLI(["ping"], socketPath: socket.path, environmentOverrides: [
            "C11_SOCKET_PATH": "/tmp/mine-\(UUID().uuidString).sock",
        ]) else { return }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(socket.waitUntilFinished(timeout: 10))
        XCTAssertEqual(socket.legacyCommands.filter { $0 == "ping" }.count, 1, "\(socket.legacyCommands)")
    }

    /// `c11 <dir>`, `c11 feedback` and bare `c11 shortcuts` connect with `try?` and
    /// launch c11 when that fails; `claude-teams` starts Claude with the path
    /// exported. A refused variable stops each of them first, by name. Launches
    /// go to a log through the CLI's test seam, and `claude` on PATH is a stub
    /// that only logs, so nothing is ever started. Every wait for an app
    /// (`waitForConnectableSocket`, 10 s) follows a launch, so an empty log
    /// proves none happened; no wall-clock bound, which a loaded host's process
    /// start alone could break (C11H-402).
    func testCommandsThatWouldLaunchRefuseFirstAndLaunchNothing() throws {
        let foreign = "/tmp/mine-\(UUID().uuidString).sock"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-socket-refusal-\(UUID().uuidString)", isDirectory: true)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let launchLog = dir.appendingPathComponent("launch.log").path
        let claudeStub = bin.appendingPathComponent("claude").path
        try "#!/bin/sh\necho claude >> \"$C11_CLI_TEST_LAUNCH_LOG\"\nexit 0\n"
            .write(toFile: claudeStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeStub)
        for args in [[dir.path], ["feedback"], ["shortcuts"], ["claude-teams"]] {
            guard let result = runCLI(args, passSocketFlag: false, environmentOverrides: [
                "C11_SOCKET_PATH": foreign,
                "C11_CLI_TEST_LAUNCH_LOG": launchLog,
                "PATH": bin.path + ":/usr/bin:/bin",
            ]) else { return }
            XCTAssertEqual(result.status, 1, "\(args): \(result.stdout) \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("C11_SOCKET_PATH=\(foreign) is not a c11 socket"), "\(args): \(result.stderr)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: launchLog),
                           "\(args) launched: \((try? String(contentsOfFile: launchLog, encoding: .utf8)) ?? "")")
            try? FileManager.default.removeItem(atPath: launchLog)
        }
    }

    /// The refusal is raised at connect: commands that never connect still run.
    func testARefusedVariableLeavesOfflineCommandsAlone() {
        guard let result = runCLI(["version"], passSocketFlag: false, environmentOverrides: [
            "C11_SOCKET_PATH": "/tmp/mine-\(UUID().uuidString).sock",
        ]) else { return }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stdout.isEmpty)
    }
}
