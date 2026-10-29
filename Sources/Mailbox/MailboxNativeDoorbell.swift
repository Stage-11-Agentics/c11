import Foundation
import Darwin

/// One event-driven stream per interactive harness. No inbox contents travel
/// over it. Socket IO and deadlines run on workers; Workspace owns ring policy.
final class MailboxNativeDoorbell {
    static let shared = MailboxNativeDoorbell()
    enum Route: String {
        case typed, piExtension = "pi_extension", ompExtension = "omp_extension"
        case codexQueue = "codex_queue", claudeInbox = "claude_inbox", opencodePlugin = "opencode_plugin"
    }
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
            case .ompExtension: return kind == "omp"
            case .codexQueue: return kind == "codex"
            case .claudeInbox: return kind == "claude-code" || kind == "claude"
            case .opencodePlugin: return kind == "opencode"
            case .typed: return false
            }
        }
    }
    enum Result: Equatable { case accepted(late: Bool), alreadyAdmitted, failed(String) }

    struct Attempt: Equatable {
        let id: UUID
        let process: MailboxStdinBuffer.AgentProcess
        let ids: Set<String>
    }

    /// Reuse only the exact unread snapshot for the same live TUI process.
    /// New mail stays outside an ambiguous earlier attempt and receives its
    /// own attempt after the original result is confirmed.
    static func reusableAttempt(_ attempt: Attempt?, process: MailboxStdinBuffer.AgentProcess,
                                unreadIDs: Set<String>) -> Attempt? {
        guard let attempt, attempt.process == process,
              !attempt.ids.isDisjoint(with: unreadIDs) else { return nil }
        return attempt
    }

    /// Keep accepted coverage across OpenCode /new route registrations from
    /// the same TUI process. A different process must be allowed to retry the
    /// still-unread invitation after a crash or restart.
    static func shouldResetCoverage(previousProcess: MailboxStdinBuffer.AgentProcess?,
                                    currentProcess: MailboxStdinBuffer.AgentProcess?) -> Bool {
        guard let currentProcess else { return false }
        return previousProcess != currentProcess
    }

    struct Fallback {
        let registration: Registration
        let ids: Set<String>
        let reason: String

        /// A hard failure holds the same uncovered mail off native delivery.
        /// omp has no typed reader, so a genuinely new uncovered envelope may
        /// start another native attempt. That attempt records its own IDs if
        /// it fails, preventing rechecks of the same mail from spinning.
        func blocksNative(registrationID: UUID, unreadIDs: Set<String>, coveredIDs: Set<String>,
                          arrivingID: String? = nil) -> Bool {
            guard registration.id == registrationID else { return false }
            var unread = unreadIDs
            // Admission reads its gate before it enqueues the new envelope.
            if let arrivingID { unread.insert(arrivingID) }
            let uncovered = unread.subtracting(coveredIDs)
            guard !ids.isDisjoint(with: uncovered) else { return false }
            if registration.route == .ompExtension, !uncovered.isSubset(of: ids) { return false }
            return true
        }

        /// OpenCode has no safe typed fallback while an invitation may already
        /// have been admitted by a prompt whose native acknowledgement was
        /// lost. The next native registration replays the same attempt ID.
        func blocksTyped(unreadIDs: Set<String>, coveredIDs: Set<String>) -> Bool {
            guard registration.route == .opencodePlugin else { return false }
            return !ids.isDisjoint(with: unreadIDs.subtracting(coveredIDs))
        }
    }

    /// Whether a failed native attempt hands its envelopes to the typed gate
    /// until a new session registers (or new mail arrives for omp). A busy
    /// rejection on omp happens before any side effect and omp has no typed
    /// composer reader, so sticking would
    /// strand the mail for the whole session: the next ring tries native again,
    /// bounded by the rate cap. Every other failure, and every other route,
    /// sticks (a timeout may follow a turn that already started).
    static func failureSticksToTypedGate(route: Route, reason: String) -> Bool {
        !(route == .ompExtension && reason == "native_rejected")
    }

    /// OpenCode v2 TUI routes cannot use typed delivery while their exact
    /// displayed root is still reserved or explicitly conflicted. This state
    /// lives in ConversationStore so the hold survives a refused/missing
    /// native stream registration.
    static func blocksTypedForUnboundOpenCodeTUI(conversation: ConversationRef?) -> Bool {
        guard let conversation, conversation.kind == "opencode",
              case .number(let rawPID)? = conversation.payload?[ConversationLifecyclePayloadKey.openCodeTuiPID],
              rawPID.isFinite, rawPID > 0 else { return false }
        return conversation.placeholder ||
            (conversation.diagnosticReason?.hasPrefix("OpenCode displayed route ") == true)
    }

    /// Typed delivery requires a fresh wrapper claim and a root capture from
    /// the current route generation. This includes the interval after a
    /// verified route-change request arrives but before the actor write ends.
    static func blocksTypedForOpenCodeTUI(snapshot: ConversationStorePanelRefSnapshot?) -> Bool {
        guard let snapshot else { return false }
        if snapshot.authenticatedOpenCodeTuiPID != nil && snapshot.routePending { return true }
        guard let conversation = snapshot.active, conversation.kind == "opencode",
              conversation.payload?[ConversationLifecyclePayloadKey.openCodeTuiPID] != nil else {
            return snapshot.authenticatedOpenCodeTuiPID != nil
        }
        guard case .number(let rawPID)? = conversation.payload?[ConversationLifecyclePayloadKey.openCodeTuiPID],
              rawPID.isFinite, rawPID > 0, rawPID <= Double(Int32.max),
              rawPID.rounded(.towardZero) == rawPID else { return true }
        guard let authenticatedPID = snapshot.authenticatedOpenCodeTuiPID,
              authenticatedPID == Int32(rawPID), !snapshot.routePending,
              snapshot.boundRouteID == conversation.id else { return true }
        return conversation.placeholder ||
            conversation.diagnosticReason?.hasPrefix("OpenCode displayed route ") == true
    }

    static func openCodePluginPeerMatches(peerPID: pid_t?, agentPID: pid_t) -> Bool {
        peerPID == agentPID && agentPID > 1
    }

    /// Apply an observed acceptance on the main hop. The return value says
    /// whether the listener is still current and may trigger further work.
    static func recordAcceptance(_ ids: Set<String>, registrationID: UUID, currentRegistrationID: UUID?,
                                 nativeCovered: inout Set<String>, ledger: inout MailboxDoorbell.Ledger) -> Bool {
        // Acceptance is an observed delivery even if the listener closed
        // before this hop. Route-change handling must see these original IDs.
        nativeCovered.formUnion(ids)
        ledger.coveredIds.formUnion(ids)
        ledger.draftWatch = nil
        return currentRegistrationID == registrationID
    }

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

    /// Authenticate the TUI PID recorded by an OpenCode wrapper claim. The
    /// claim arrives from a short-lived c11 CLI child, so the socket peer must
    /// be a same-terminal descendant of the foreground process-group leader.
    /// Requiring the claimed PID to lead that group prevents a child from
    /// claiming itself and then reporting a displayed root from its own PID.
    static func verifiedOpenCodeTUIClaim(
        peerPID: pid_t?,
        claimedTuiPID: pid_t,
        peerTTYDevice: UInt32?,
        panelTTYDevice: UInt32?,
        readProcess: (pid_t) -> MailboxAgentForeground.ProcessTerminalInfo? = MailboxAgentForeground.processTerminalInfo
    ) -> Bool {
        guard let peerPID, peerPID > 1, claimedTuiPID > 1, peerPID != claimedTuiPID,
              let peerTTYDevice, let panelTTYDevice,
              let tui = readProcess(claimedTuiPID), tui.startTime > 0,
              tui.processGroup == claimedTuiPID,
              tui.processGroup == tui.terminalForegroundGroup,
              tui.terminalDevice != -1,
              UInt32(tui.terminalDevice) == peerTTYDevice,
              UInt32(tui.terminalDevice) == panelTTYDevice,
              let peer = readProcess(peerPID), peer.startTime > 0,
              peer.terminalDevice == tui.terminalDevice,
              peer.processGroup == tui.processGroup,
              peer.terminalForegroundGroup == tui.terminalForegroundGroup,
              verifiedAgent(
                peer: .init(pid: peerPID, startTime: peer.startTime),
                agentPID: claimedTuiPID,
                readProcess: readProcess
              ) == tui,
              readProcess(peerPID) == peer,
              readProcess(claimedTuiPID) == tui else { return false }
        return true
    }

    private struct Pending {
        let reply: (Result, @escaping () -> Void) -> Void
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
            // Serialize with deliveries so the frame cannot interleave with
            // another write. The displaced consumer retires instead of
            // reconnecting and repeatedly evicting the newer session.
            io.async {
                _ = old.write(["type": "replaced"])
                old.close()
            }
            for request in old.pending.values where !request.failed { request.reply(.failed("native_replaced"), {}) }
        }
    }

    func disconnect(_ registration: Registration) {
        lock.lock()
        guard listeners[registration.panelID]?.registration.id == registration.id else { lock.unlock(); return }
        let old = listeners.removeValue(forKey: registration.panelID)
        lock.unlock()
        for request in old?.pending.values ?? Dictionary<UUID, Pending>().values where !request.failed {
            request.reply(.failed("native_disconnected"), {})
        }
    }

    /// Deadline failure retains the request briefly for a late acknowledgement.
    /// Coverage belongs to Workspace and always names the dispatch-time IDs.
    @discardableResult
    func deliver(_ registration: Registration, timeout: TimeInterval = 2, reply: @escaping (Result) -> Void) -> UUID {
        deliver(registration, timeout: timeout) { result, _ in reply(result) }
    }

    /// `settled` runs after Workspace applies an observed acceptance on main.
    /// OpenCode keeps its old stream until that frame arrives, so route-change
    /// registration cannot race ahead of accepted-ID coverage.
    @discardableResult
    func deliver(_ registration: Registration, timeout: TimeInterval = 2, attemptID: UUID? = nil,
                 reply: @escaping (Result, @escaping () -> Void) -> Void) -> UUID {
        let requestID = UUID()
        lock.lock()
        guard var listener = listeners[registration.panelID], listener.registration.id == registration.id else {
            lock.unlock(); reply(.failed("native_unavailable"), {}); return requestID
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
            var frame: [String: Any] = ["type": "deliver", "delivery_id": requestID.uuidString, "text": MailboxDoorbell.text]
            if let attemptID { frame["attempt_id"] = attemptID.uuidString }
            if !listener.write(frame) {
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
        case .alreadyAdmitted:
            resolved = .alreadyAdmitted
            listener.pending.removeValue(forKey: requestID)
        case .failed(let reason):
            guard !pending.failed else { lock.unlock(); return }
            pending.failed = true
            listener.pending[requestID] = pending
            resolved = .failed(reason)
        }
        listeners[registration.panelID] = listener
        lock.unlock()
        let settled: () -> Void
        let confirmsCoverage: Bool
        switch resolved {
        case .accepted, .alreadyAdmitted: confirmsCoverage = true
        case .failed: confirmsCoverage = false
        }
        if confirmsCoverage {
            settled = { [weak self] in
                guard let self else { return }
                self.io.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let listener = self.listeners[registration.panelID]
                    let write = listener?.registration.id == registration.id ? listener?.write : nil
                    self.lock.unlock()
                    _ = write?(["type": "settled", "delivery_id": requestID.uuidString])
                }
            }
        } else {
            settled = {}
        }
        pending.reply(resolved, settled)
    }

    /// Reasons a consumer may give that the log names on their own. Any other
    /// rejection, including one with no reason (Pi), stays `native_rejected`,
    /// so a consumer cannot write arbitrary text into `_dispatch.log`.
    static let namedRejections: Set<String> = [
        "transcript_unavailable", "inbox_unavailable", "inbox_write_failed", "unconfirmed", "unsupported_invitation",
        "session_conflict", "not_ready",
    ]

    /// One consumer frame from the stream: an acceptance or a rejection.
    func consume(_ line: Data, registration: Registration) {
        guard let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let rawID = frame["delivery_id"] as? String, let requestID = UUID(uuidString: rawID) else { return }
        switch frame["type"] as? String {
        case "accepted":
            if registration.route == .opencodePlugin,
               frame["disposition"] as? String == "already_admitted" {
                resolve(registration, requestID: requestID, result: .alreadyAdmitted)
            } else {
                resolve(registration, requestID: requestID, result: .accepted(late: false))
            }
        case "rejected":
            let reason = (frame["reason"] as? String).flatMap { Self.namedRejections.contains($0) ? "native_\($0)" : nil }
            resolve(registration, requestID: requestID, result: .failed(reason ?? "native_rejected"))
        default: break
        }
    }
}

extension TerminalController {
    /// Persistent worker-only transport. Existing socket authentication runs
    /// before this function. A registration is usable only while Workspace's
    /// live process/start-time/foreground checks match it.
    nonisolated func v2StreamNativeMailbox(id: Any?, params: [String: Any], socket: Int32,
                                          peer: MailboxStdinBuffer.AgentProcess?, shouldContinue: () -> Bool) {
        let isOpenCodePluginPeer = params["route"] as? String == MailboxNativeDoorbell.Route.opencodePlugin.rawValue
        guard let rawPanel = params["panel_id"] as? String, let panelID = UUID(uuidString: rawPanel),
              let pidNumber = params["agent_pid"] as? NSNumber,
              pidNumber.doubleValue.rounded() == pidNumber.doubleValue,
              pidNumber.int64Value > 1, pidNumber.int64Value <= Int64(Int32.max),
              let sessionID = params["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 256,
              let rawRoute = params["route"] as? String, let route = MailboxNativeDoorbell.Route(rawValue: rawRoute), route != .typed,
              !isOpenCodePluginPeer || MailboxNativeDoorbell.openCodePluginPeerMatches(
                peerPID: peer?.pid, agentPID: pidNumber.int32Value
              ),
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
                    MailboxNativeDoorbell.shared.consume(Data(line), registration: registration)
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
