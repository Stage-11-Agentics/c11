// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

final class SocketClient {
    /// A validated global CLI scope. Propagate it to routing requests, including
    /// helper lookups, without changing the app's key window or caller identity.
    var scopedWindow: String?
    // Stable string used at both the throw site and the catch site in sendV2.
    // Extracting it prevents the catch clause from silently missing the timeout
    // if the throw-site message is ever edited.
    static let commandTimedOutMessage = "Command timed out"

    let path: String
    private var socketFD: Int32 = -1
    var usesSingleLineResponses = false

    // Default deadline: 10 s, tunable via env. Dual-read: C11_* primary, CMUX_* compat.
    // Legacy CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC (seconds) honoured for backward compat.
    private static let configuredDefaultDeadlineSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        for key in ["C11_DEFAULT_SOCKET_DEADLINE_MS", "CMUX_DEFAULT_SOCKET_DEADLINE_MS"] {
            if let raw = env[key], let ms = Double(raw), ms > 0 { return ms / 1000 }
        }
        if let raw = env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"], let s = Double(raw), s > 0 { return s }
        return 10.0
    }()

    // C11_TRACE=1 (or CMUX_TRACE=1) prints per-request start/end/timing lines to stderr.
    private static let traceEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["C11_TRACE"] == "1" || env["CMUX_TRACE"] == "1"
    }()

    private static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12

    init(path: String) {
        self.path = path
    }

    var socketPath: String {
        path
    }

    /// Transfers an authenticated connection to a bidirectional subscriber.
    /// The caller owns closing it; this client must make no further requests.
    func takeConnectedDescriptor() throws -> Int32 {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let descriptor = socketFD
        socketFD = -1
        return descriptor
    }

    func connect() throws {
        if socketFD >= 0 { return }
        try connectOnce()
    }

    func close() {
        serverVocabularyTier = nil
        serverMethods = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    // Backward-compat overload: uses the configured default deadline.
    func send(command: String) throws -> String {
        try send(command: command, responseTimeout: Self.configuredDefaultDeadlineSeconds)
    }

    // responseTimeout: nil = no SO_RCVTIMEO / SO_SNDTIMEO (unbounded); >0 = the
    // deadline in seconds for writing the request (a peer that stops reading
    // cannot hold the CLI) and for the initial read of the response.
    /// A wall-clock bound every request in this process must finish by, on top
    /// of its own deadline. A hook drain sets it to its claim cutoff, so a c11
    /// that stops reading or answering can never hold the hook past the point
    /// where it may still claim mail and finish before the harness's kill.
    static var processDeadline: Date?

    func send(command: String, responseTimeout: TimeInterval?) throws -> String {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        var responseTimeout = responseTimeout
        if let processDeadline = Self.processDeadline {
            let remaining = processDeadline.timeIntervalSinceNow
            guard remaining > 0.01 else { throw CLIError(message: SocketClient.commandTimedOutMessage) }
            responseTimeout = min(responseTimeout ?? remaining, remaining)
        }
        let payload = Array((command + "\n").utf8)
        try configureTimeout(SO_SNDTIMEO, responseTimeout)
        var offset = 0
        while offset < payload.count {
            let sent = payload[offset...].withUnsafeBytes { Darwin.write(socketFD, $0.baseAddress, $0.count) }
            if sent < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: SocketClient.commandTimedOutMessage)
                }
                throw CLIError(message: "Failed to write to socket")
            }
            offset += sent
        }

        var data = Data()
        var sawNewline = false

        while true {
            try configureReceiveTimeout(
                sawNewline ? Self.multilineResponseIdleTimeoutSeconds : responseTimeout
            )

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if sawNewline {
                        break
                    }
                    throw CLIError(message: SocketClient.commandTimedOutMessage)
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
            if data.contains(UInt8(0x0A)) {
                sawNewline = true
                if usesSingleLineResponses { break }
            }
        }

        guard var response = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }

    private func connectOnce() throws {
        // Verify socket is owned by the current user to prevent fake-socket attacks.
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket at \(path) is not owned by the current user — refusing to connect")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw CLIError(message: "Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let flags = fcntl(socketFD, F_GETFL)
        if Self.processDeadline != nil { _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            _ = fcntl(socketFD, F_SETFL, flags)
            return
        }
        if let deadline = Self.processDeadline, errno == EINPROGRESS {
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
            let wait = Int32(max(0, min(250, deadline.timeIntervalSinceNow * 1000)))
            if poll(&descriptor, 1, wait) > 0 {
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 {
                    _ = fcntl(socketFD, F_SETFL, flags)
                    return
                }
            }
        }

        let connectErrno = errno
        Darwin.close(socketFD)
        socketFD = -1
        throw CLIError(
            message: "Failed to connect to socket at \(path) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
        )
    }

    // timeout == nil clears SO_RCVTIMEO (no deadline). timeout > 0 sets the deadline.
    private func configureReceiveTimeout(_ timeout: TimeInterval?) throws {
        try configureTimeout(SO_RCVTIMEO, timeout)
    }

    private func configureTimeout(_ option: Int32, _ timeout: TimeInterval?) throws {
        var interval: timeval
        if let t = timeout, t > 0 {
            interval = timeval(
                tv_sec: Int(t.rounded(.down)),
                tv_usec: __darwin_suseconds_t((t - floor(t)) * 1_000_000)
            )
        } else {
            interval = timeval(tv_sec: 0, tv_usec: 0)
        }
        let result = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                option,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to configure socket timeout")
        }
    }

    static func waitForConnectableSocket(path: String, timeout: TimeInterval) throws -> SocketClient {
        let client = SocketClient(path: path)
        if (try? client.connect()) != nil {
            return client
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "c11 app did not start in time (socket not found at \(path))")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "c11 app did not start in time (socket not found at \(path))")
        }

        let queue = DispatchQueue(label: "com.stage11.c11.cli.socket-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var connected = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func attemptConnect() {
            guard !connected else { return }
            if (try? client.connect()) != nil {
                connected = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            attemptConnect()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            attemptConnect()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            client.close()
            throw CLIError(message: "c11 app did not start in time (socket not found at \(path))")
        }

        source.cancel()
        return client
    }

    static func waitForFilesystemPath(_ path: String, timeout: TimeInterval) throws {
        if FileManager.default.fileExists(atPath: path) {
            return
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        let queue = DispatchQueue(label: "com.stage11.c11.cli.path-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func checkPath() {
            guard !found else { return }
            if FileManager.default.fileExists(atPath: path) {
                found = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            checkPath()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            checkPath()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        source.cancel()
    }

    private static func existingWatchDirectory(forPath path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)

        while !candidate.path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }

    /// Version-skew tier of the app on this socket (see `CLIVersionSkew`). Probed once per
    /// connection via `system.capabilities` and cached; a failed probe means `.panel`.
    var serverVocabularyTier: CLIVersionSkew.Tier?
    /// The methods the same probe advertised; nil when it failed.
    private(set) var serverMethods: Set<String>?

    private func probeServerVocabularyTier(deadline: SocketDeadline) -> CLIVersionSkew.Tier {
        if let cached = serverVocabularyTier { return cached }
        let caps = try? sendV2Raw(method: "system.capabilities", params: [:], deadline: deadline)
        let tier = CLIVersionSkew.tier(fromCapabilities: caps)
        serverVocabularyTier = tier
        serverMethods = (caps?["methods"] as? [String]).map(Set.init)
        return tier
    }

    /// Whether the app on this socket advertises `method`, probing once.
    func advertisesMethod(_ method: String) -> Bool {
        _ = probeServerVocabularyTier(deadline: .default)
        return serverMethods?.contains(method) == true
    }

    func sendV2(method: String, params: [String: Any] = [:], deadline: SocketDeadline = .default) throws -> [String: Any] {
        var params = params
        // Attribution fallback belongs to selection routes. Unrelated protocols
        // (notably the closed journal envelope) must keep their exact parameters.
        if params["caller_panel_id"] == nil, params["caller_tab_id"] == nil,
           ["workspace.select", "workspace.next", "workspace.previous", "workspace.last",
            "workspace.close", "workspace.move_to_window", "workspace.group.focus",
            "browser.focus_webview", "history.back", "history.forward", "feed.open",
            "snapshot.restore", "snapshot.restore_set", "config.launch", "window.create",
            // A cache report describes the caller's own panel unless it names one.
            "agent.prompt_cache.report"].contains(method) {
            if let caller = CMUXCLI.callerPanelEnv(), UUID(uuidString: caller) != nil {
                params["caller_panel_id"] = caller
            }
        }
        if let scopedWindow, params["window_id"] == nil,
           method.hasPrefix("workspace.") || (method.hasPrefix("panel.") && method != "panel.move") || method.hasPrefix("area.")
            || method.hasPrefix("notification.") || method.hasPrefix("flag.") || method.hasPrefix("snapshot.")
            || ["system.identify", "system.tree", "agent.launch", "flag.delegate", "flag.undelegate", "config.launch", "sidebar.state", "snapshot.create"].contains(method) {
            params["window_id"] = scopedWindow
        }
        if let scopedWindow, ["panel.move", "panel.reorder", "area.swap", "area.join", "config.launch", "flag.raise", "flag.lower", "flag.delegate", "flag.undelegate"].contains(method) {
            // panel.move treats window_id as a destination, so its global scope
            // is source admission rather than a synthesized destination.
            if method == "panel.move", let destination = params["window_id"] as? String {
                var sourceParams: [String: Any] = [:]
                if let panel = params["panel_id"] { sourceParams["panel_id"] = panel }
                try validateScopedTargets(sourceParams, window: scopedWindow, deadline: deadline)
                var destinationParams = params
                destinationParams.removeValue(forKey: "panel_id")
                try validateScopedTargets(destinationParams, window: destination, deadline: deadline)
            } else {
                // These older handlers locate targets globally. Validate their
                // membership before allowing a window-scoped mutation.
                try validateScopedTargets(params, window: scopedWindow, deadline: deadline)
            }
        }
        if method == "system.capabilities" {
            return try sendV2Raw(method: method, params: params, deadline: deadline)
        }
        // Panel-vocabulary app: send canonical names, never retry. Older app: its method,
        // param keys and ref values for every request (unchanged-name methods included),
        // canonical result.
        let tier = probeServerVocabularyTier(deadline: deadline)
        if tier != .panel {
            let legacyResult = try sendV2Raw(
                method: CLIVersionSkew.legacyMethod(for: method, tier: tier) ?? method,
                params: CLIVersionSkew.legacyParams(params, method: method, tier: tier),
                deadline: deadline
            )
            return CLIVersionSkew.modernResult(legacyResult)
        }
        return try sendV2Raw(method: method, params: params, deadline: deadline)
    }

    /// Opens a single v2 request whose response is a sequence of newline-framed
    /// result envelopes. Used by markdown.visible --watch; closing this client
    /// socket cancels the server-side state subscription.
    func sendV2Stream(
        method: String,
        params: [String: Any],
        onPayload: ([String: Any]) throws -> Void
    ) throws {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let tier = probeServerVocabularyTier(deadline: .default)
        guard tier == .panel else {
            throw CLIError(message: "Markdown agent commands require a current c11 socket")
        }
        let streamReceiveTimeout: TimeInterval?
        if let deadline = Self.processDeadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.01 else { throw CLIError(message: SocketClient.commandTimedOutMessage) }
            streamReceiveTimeout = remaining
        } else {
            streamReceiveTimeout = nil
        }

        let requestID = UUID().uuidString
        let request: [String: Any] = ["id": requestID, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request, options: []),
              let line = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 stream request")
        }
        try configureTimeout(SO_SNDTIMEO, 10)
        let outgoing = Array((line + "\n").utf8)
        var offset = 0
        while offset < outgoing.count {
            let written = outgoing.withUnsafeBytes { bytes in
                Darwin.write(socketFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: SocketClient.commandTimedOutMessage)
                }
                throw CLIError(message: "Failed to write markdown watch request")
            }
            guard written > 0 else { throw CLIError(message: "Failed to write markdown watch request") }
            offset += written
        }
        try configureTimeout(SO_SNDTIMEO, nil)
        try configureReceiveTimeout(streamReceiveTimeout)

        var pending = Data()
        var receivedPayload = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: SocketClient.commandTimedOutMessage)
                }
                throw CLIError(message: "Markdown watch socket read failed")
            }
            if count == 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let frame = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: frame),
                      let envelope = object as? [String: Any] else {
                    throw CLIError(message: "Invalid markdown watch response")
                }
                guard (envelope["id"] as? String) == requestID else {
                    throw CLIError(message: "Markdown watch response id did not match request")
                }
                guard (envelope["ok"] as? Bool) == true else {
                    let error = envelope["error"] as? [String: Any] ?? [:]
                    let code = error["code"] as? String ?? "request_failed"
                    let message = error["message"] as? String ?? "Markdown watch failed"
                    throw CLIError(message: "\(code): \(message)")
                }
                guard let payload = envelope["result"] as? [String: Any] else {
                    throw CLIError(message: "Markdown watch returned an invalid result")
                }
                receivedPayload = true
                try onPayload(payload)
            }
        }
        guard receivedPayload else {
            throw CLIError(message: "Markdown watch ended before its initial state")
        }
    }

    private func validateScopedTargets(_ params: [String: Any], window: String, deadline: SocketDeadline) throws {
        let payload = try sendV2(method: "workspace.list", params: ["window_id": window], deadline: deadline)
        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
        // Refs compare by canonical prefix, so `tab:N` / `surface:N` / `pane:N` match `panel:N` / `area:N`.
        func matches(_ item: [String: Any], _ value: String) -> Bool {
            let wanted = CMUXCLI.canonicalHandle(value).lowercased()
            return [item["id"] as? String, item["ref"] as? String].compactMap { $0 }
                .contains { CMUXCLI.canonicalHandle($0).lowercased() == wanted }
        }
        if let value = (params["workspace_id"] ?? params["workspace"]) as? String, !workspaces.contains(where: { matches($0, value) }) {
            throw CLIError(message: "not_found: " + String(localized: "cli.window.scope.workspaceNotFound", defaultValue: "Workspace not found in scoped window"))
        }
        var panels: [[String: Any]] = []
        var areas: [[String: Any]] = []
        for workspace in workspaces {
            guard let id = workspace["id"] as? String else { continue }
            let route: [String: Any] = ["window_id": window, "workspace_id": id]
            let listed = try sendV2(method: "panel.list", params: route, deadline: deadline)
            panels += listed["panels"] as? [[String: Any]] ?? []
            if params["area_id"] != nil || params["target_area_id"] != nil || params["pane"] != nil {
                let listedAreas = try sendV2(method: "area.list", params: route, deadline: deadline)
                areas += listedAreas["areas"] as? [[String: Any]] ?? []
            }
        }
        for key in ["panel_id", "before_panel_id", "after_panel_id"] {
            if let value = params[key] as? String, !panels.contains(where: { matches($0, value) }) {
                throw CLIError(message: "not_found: " + String(localized: "cli.window.scope.tabNotFound", defaultValue: "Panel not found in scoped window"))
            }
        }
        for key in ["area_id", "target_area_id", "pane"] {
            if let value = params[key] as? String, !areas.contains(where: { matches($0, value) }) {
                throw CLIError(message: "not_found: " + String(localized: "cli.window.scope.areaNotFound", defaultValue: "Area not found in scoped window"))
            }
        }
    }

    private func sendV2Raw(
        method: String,
        params: [String: Any],
        deadline: SocketDeadline
    ) throws -> [String: Any] {
        let effectiveTimeout: TimeInterval?
        switch deadline {
        case .default: effectiveTimeout = Self.configuredDefaultDeadlineSeconds
        case .none: effectiveTimeout = nil
        case .custom(let t): effectiveTimeout = t > 0 ? t : nil
        }

        let startTime = Date()
        var traceStatus = "ok"

        if Self.traceEnabled {
            let refs = refTokens(from: params).joined(separator: " ")
            let refsStr = refs.isEmpty ? "" : "(\(refs)) "
            FileHandle.standardError.c11SafeWrite(
                Data("[c11-trace] -> \(method) \(refsStr)socket=\(path)\n".utf8)
            )
        }
        defer {
            if Self.traceEnabled {
                let ms = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
                FileHandle.standardError.c11SafeWrite(
                    Data("[c11-trace] <- \(method) elapsed=\(ms)ms status=\(traceStatus)\n".utf8)
                )
            }
        }

        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            traceStatus = "error"
            throw CLIError(message: "Failed to encode v2 request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            traceStatus = "error"
            throw CLIError(message: "Failed to encode v2 request")
        }

        let raw: String
        do {
            raw = try send(command: requestLine, responseTimeout: effectiveTimeout)
        } catch let err as CLIError where err.message == SocketClient.commandTimedOutMessage {
            traceStatus = "timeout"
            let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
            throw CLIError(message: timeoutMessage(method: method, params: params, elapsedMs: elapsedMs))
        } catch {
            traceStatus = "error"
            throw error
        }

        // The server may return plain-text errors (e.g., "ERROR: Access denied ...")
        // before the JSON protocol starts. Surface these directly instead of letting
        // JSONSerialization throw a confusing parse error.
        if raw.hasPrefix("ERROR:") {
            traceStatus = "error"
            throw CLIError(message: raw)
        }

        guard let responseData = raw.data(using: .utf8) else {
            traceStatus = "error"
            throw CLIError(message: "Invalid UTF-8 v2 response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            traceStatus = "error"
            throw CLIError(message: "Invalid v2 response: \(raw)")
        }

        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "error"
            let message = (error["message"] as? String) ?? "Unknown v2 error"
            // Normalize server-side main_thread_timeout to the same parseable c11: timeout:
            // envelope as a client-side SO_RCVTIMEO, so automation can parse both paths uniformly.
            // The 8 s server deadline is intentionally shorter than the 10 s CLI deadline, so this
            // is the expected production timeout path under a saturated main thread.
            if code == "main_thread_timeout" {
                traceStatus = "timeout"
                let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
                throw CLIError(message: timeoutMessage(method: method, params: params, elapsedMs: elapsedMs))
            }
            traceStatus = "error"
            // Structured `data` is otherwise dropped on the floor, so surface
            // the one field that tells the caller what to do next.
            let hint = (error["data"] as? [String: Any])?["hint"] as? String
            if code == "input_guard_refused" {
                let data = error["data"] as? [String: Any] ?? [:]
                let reason = data["reason"] as? String ?? "unknown"
                // A caller that follows a refused send with `send-key enter` would
                // submit the operator's draft or pick a dialog option, so say so.
                let guidance = message.contains("Nothing was sent") ? "" : String(
                    localized: "cli.send.guard_refused_guidance",
                    defaultValue: "\nNothing was sent; do not press Enter. If the operator is mid-draft, raise a flag (c11 raise-flag) instead of retrying."
                )
                throw CLIError(
                    message: String(format: String(
                        localized: "cli.send.guard_refused",
                        defaultValue: "%@\ninput_guard: refused (reason: %@)"
                    ), "\(code): \(message)", reason) + guidance,
                    structuredResponse: ["ok": false, "error": error]
                )
            }
            if let hint, !hint.isEmpty, !message.contains(hint) {
                throw CLIError(message: "\(code): \(message)\n\(hint)")
            }
            throw CLIError(message: "\(code): \(message)")
        }

        traceStatus = "error"
        throw CLIError(message: "v2 request failed")
    }

    // Shared builder for both trace output and timeout error messages.
    // Extracts workspace/surface/pane/panel refs from params into "key=value" tokens.
    private func refTokens(from params: [String: Any]) -> [String] {
        var parts: [String] = []
        if let ws = params["workspace_id"] as? String { parts.append("workspace=\(ws)") }
        if let surf = params["panel_id"] as? String { parts.append("panel=\(surf)") }
        if let pane = params["area_id"] as? String { parts.append("area=\(pane)") }
        return parts
    }

    func timeoutMessage(method: String, params: [String: Any], elapsedMs: Int) -> String {
        var parts = ["method=\(method)"] + refTokens(from: params)
        parts.append("socket=\(path)")
        parts.append("elapsed_ms=\(elapsedMs)")
        return "c11: timeout: \(parts.joined(separator: " "))"
    }
}
