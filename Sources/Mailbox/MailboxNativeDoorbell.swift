import Foundation
import Darwin

/// One event-driven stream per interactive harness. No inbox contents travel
/// over it. Socket IO and deadlines run on workers; Workspace owns ring policy.
final class MailboxNativeDoorbell {
    static let shared = MailboxNativeDoorbell()
    enum Route: String { case typed, piExtension = "pi_extension", codexQueue = "codex_queue", claudeInbox = "claude_inbox" }
    struct Registration: Equatable {
        let id: UUID
        let panelID: UUID
        let agentPID: pid_t
        let processStart: UInt64
        let sessionID: String
        let route: Route
        let canQueue: Bool

        func matches(process: MailboxStdinBuffer.AgentProcess?, kind: String) -> Bool {
            guard let process, process.pid == agentPID, process.startTime == processStart else { return false }
            switch route {
            case .piExtension: return kind == "pi"
            case .codexQueue: return kind == "codex"
            case .claudeInbox: return kind == "claude-code" || kind == "claude"
            case .typed: return false
            }
        }
    }
    enum Result: Equatable { case accepted(late: Bool), failed(String) }

    /// The peer identity is captured from the accepted socket, never JSON.
    /// A hook may have detached from the terminal while remaining a descendant
    /// of the interactive harness. Only the harness must own that terminal.
    static func verifiedAgent(
        peer: MailboxStdinBuffer.AgentProcess?,
        agentPID: pid_t,
        readProcess: (pid_t) -> MailboxAgentForeground.ProcessTerminalInfo? = MailboxAgentForeground.processTerminalInfo
    ) -> MailboxAgentForeground.ProcessTerminalInfo? {
        guard let peer, let peerStart = peer.startTime, peerStart > 0,
              let agent = readProcess(agentPID), agent.startTime > 0,
              !agent.isZombie, agent.terminalDevice != -1,
              agent.processGroup > 0, agent.processGroup == agent.terminalForegroundGroup,
              let first = readProcess(peer.pid), first.startTime == peerStart else { return nil }
        var chain: [(pid_t, MailboxAgentForeground.ProcessTerminalInfo)] = []
        var seen: Set<pid_t> = []
        var pid = peer.pid
        var process = first
        for _ in 0..<128 {
            guard pid > 1, !process.isZombie, process.startTime > 0,
                  seen.insert(pid).inserted else { return nil }
            chain.append((pid, process))
            if pid == agentPID {
                guard process == agent else { return nil }
                // Re-read every edge: an exit, reparent or PID replacement
                // during the walk must not authenticate a different process.
                guard chain.allSatisfy({ readProcess($0.0) == $0.1 }) else { return nil }
                return agent
            }
            guard let parent = readProcess(process.parentPID),
                  parent.startTime <= process.startTime else { return nil }
            pid = process.parentPID
            process = parent
        }
        return nil
    }

    private struct Pending {
        let reply: (Result) -> Void
        var failed = false
        let at: Date
    }
    private struct Listener {
        let registration: Registration
        let write: ([String: Any]) -> Bool
        let close: () -> Void
        var pending: [UUID: Pending] = [:]
    }
    private let lock = NSLock()
    private var listeners: [UUID: Listener] = [:]
    private let io = DispatchQueue(label: "com.stage11.c11.mailbox.native", qos: .utility)

    func registration(panelID: UUID) -> Registration? {
        lock.lock(); defer { lock.unlock() }
        return listeners[panelID]?.registration
    }

    func register(_ registration: Registration, write: @escaping ([String: Any]) -> Bool, close: @escaping () -> Void) {
        lock.lock()
        let old = listeners.updateValue(Listener(registration: registration, write: write, close: close), forKey: registration.panelID)
        lock.unlock()
        // Never call consumer closures or write a socket while holding the lock.
        if let old {
            old.close()
            for request in old.pending.values where !request.failed { request.reply(.failed("native_replaced")) }
        }
    }

    func disconnect(_ registration: Registration) {
        lock.lock()
        guard listeners[registration.panelID]?.registration.id == registration.id else { lock.unlock(); return }
        let old = listeners.removeValue(forKey: registration.panelID)
        lock.unlock()
        for request in old?.pending.values ?? Dictionary<UUID, Pending>().values where !request.failed {
            request.reply(.failed("native_disconnected"))
        }
    }

    /// Deadline failure retains the request briefly for a late acknowledgement.
    /// Coverage belongs to Workspace and always names the dispatch-time IDs.
    @discardableResult
    func deliver(_ registration: Registration, timeout: TimeInterval = 2, reply: @escaping (Result) -> Void) -> UUID {
        let requestID = UUID()
        lock.lock()
        guard var listener = listeners[registration.panelID], listener.registration.id == registration.id else {
            lock.unlock(); reply(.failed("native_unavailable")); return requestID
        }
        listener.pending = listener.pending.filter { Date().timeIntervalSince($0.value.at) < MailboxDoorbell.rateWindow }
        listener.pending[requestID] = Pending(reply: reply, at: Date())
        listeners[registration.panelID] = listener
        lock.unlock()
        // A stalled peer must not postpone another panel's two-second bound.
        // The timer is independent of the serial writer and starts at dispatch.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
            resolve(registration, requestID: requestID, result: .failed("native_timeout"))
        }
        io.async { [self] in
            lock.lock()
            let current = listeners[registration.panelID]
            let shouldSend = current?.registration.id == registration.id
                && current?.pending[requestID]?.failed == false
            lock.unlock()
            guard shouldSend else { return }
            if !listener.write(["type": "deliver", "delivery_id": requestID.uuidString, "text": MailboxDoorbell.text]) {
                resolve(registration, requestID: requestID, result: .failed("native_write_failed"))
            }
        }
        return requestID
    }

    func resolve(_ registration: Registration, requestID: UUID, result: Result) {
        lock.lock()
        guard var listener = listeners[registration.panelID], listener.registration.id == registration.id,
              var pending = listener.pending[requestID] else { lock.unlock(); return }
        let resolved: Result
        switch result {
        case .accepted:
            resolved = .accepted(late: pending.failed)
            listener.pending.removeValue(forKey: requestID)
        case .failed(let reason):
            guard !pending.failed else { lock.unlock(); return }
            pending.failed = true
            listener.pending[requestID] = pending
            resolved = .failed(reason)
        }
        listeners[registration.panelID] = listener
        lock.unlock()
        pending.reply(resolved)
    }
}

extension TerminalController {
    /// Persistent worker-only transport. Existing socket authentication runs
    /// before this function. A registration is usable only while Workspace's
    /// live process/start-time/foreground checks match it.
    nonisolated func v2StreamNativeMailbox(id: Any?, params: [String: Any], socket: Int32,
                                          peer: MailboxStdinBuffer.AgentProcess?, shouldContinue: () -> Bool) {
        guard let rawPanel = params["panel_id"] as? String, let panelID = UUID(uuidString: rawPanel),
              let pidNumber = params["agent_pid"] as? NSNumber,
              pidNumber.doubleValue.rounded() == pidNumber.doubleValue,
              pidNumber.int64Value > 1, pidNumber.int64Value <= Int64(Int32.max),
              let sessionID = params["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 256,
              let rawRoute = params["route"] as? String, let route = MailboxNativeDoorbell.Route(rawValue: rawRoute), route != .typed,
              let process = MailboxNativeDoorbell.verifiedAgent(peer: peer, agentPID: pidNumber.int32Value) else {
            _ = Self.writeSocketResponse(v2Error(id: id, code: "invalid_params", message: String(localized: "mailbox.native.error.liveProcess", defaultValue: "Native mailbox requires the live agent process and its terminal.")), to: socket)
            return
        }
        let registration = MailboxNativeDoorbell.Registration(id: UUID(), panelID: panelID, agentPID: pidNumber.int32Value,
            processStart: process.startTime, sessionID: sessionID, route: route, canQueue: params["can_queue"] as? Bool ?? false)
        // A slow/dead peer cannot occupy the shared writer indefinitely.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let writer = MailboxNativeSocketWriter(socket)
        let write: ([String: Any]) -> Bool = { payload in
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let line = String(data: data, encoding: .utf8) else { return false }
            return writer.write(line)
        }
        guard Self.writeSocketResponse(v2Ok(id: id, result: ["subscription_id": registration.id.uuidString]), to: socket) else { return }
        MailboxNativeDoorbell.shared.register(registration, write: write, close: { writer.shutdown() })
        Self.nativeMailboxChanged(panelID)
        defer {
            MailboxNativeDoorbell.shared.disconnect(registration)
            Self.nativeMailboxChanged(panelID)
        }
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while shouldContinue() {
            let keep = autoreleasepool { () -> Bool in
                let count = read(socket, &bytes, bytes.count)
                if count < 0 && errno == EINTR { return true }
                guard count > 0 else { return false }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 65536 else { return false }
                while let end = pending.firstIndex(of: 10) {
                    let line = pending[..<end]
                    pending.removeSubrange(...end)
                    guard let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let rawID = frame["delivery_id"] as? String, let requestID = UUID(uuidString: rawID) else { continue }
                    switch frame["type"] as? String {
                    case "accepted": MailboxNativeDoorbell.shared.resolve(registration, requestID: requestID, result: .accepted(late: false))
                    case "rejected": MailboxNativeDoorbell.shared.resolve(registration, requestID: requestID, result: .failed("native_rejected"))
                    default: break
                    }
                }
                return true
            }
            if !keep { break }
        }
    }

    private nonisolated static func nativeMailboxChanged(_ panelID: UUID) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for workspace in AppDelegate.shared?.allMainWindowWorkspaces() ?? [] where workspace.panels[panelID] != nil {
                    workspace.nativeMailboxRouteChanged(surfaceId: panelID)
                }
            }
        }
    }
}

/// Own a duplicate descriptor so a queued write cannot hit a reused client fd.
private final class MailboxNativeSocketWriter {
    private let fd: Int32
    init(_ socket: Int32) { fd = dup(socket) }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func write(_ line: String) -> Bool {
        guard fd >= 0 else { return false }
        // Do not toggle O_NONBLOCK: dup shares file status with the reader.
        // SO_SNDTIMEO bounds a blocked send without changing read semantics.
        let data = Data((line + "\n").utf8)
        let deadline = Date().addingTimeInterval(2)
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count && Date() < deadline {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { return false }
            }
            return offset == bytes.count
        }
    }
    func shutdown() { if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) } }
}
