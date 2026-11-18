import Foundation

extension HCJSONValue {
    /// From a JSONSerialization value (NSNumber booleans stay booleans).
    init(foundation value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let string as String: self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if CFNumberIsFloatType(number) { self = .number(number.doubleValue) }
            else { self = .integer(number.int64Value) }
        case let array as [Any]: self = .array(array.map { HCJSONValue(foundation: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { HCJSONValue(foundation: $0) })
        default: self = .null
        }
    }

    /// As a JSONSerialization value.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return NSNumber(value: value)
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundation)
        case .object(let value): return value.mapValues(\.foundation)
        }
    }
}

/// The relay's hc calls on c11's own session (a remote machine's documents
/// are addressed with hc's `on`). Each call has a short deadline.
struct C11RelaySessionHost: C11RelayHost {
    let session: HCManagedSession
    static let callSeconds: TimeInterval = 3

    func relayDocGet(machine: String, name: String) async throws -> (value: Any?, version: UInt64) {
        let result = try await call("doc.get", ["name": .string(name), "on": .string(machine)])
        guard let version = result["version"].uint else { throw HCUnavailableReason.malformedResponse }
        let value = result["value"]
        return (value == .null ? nil : value.foundation, version)
    }

    func relayDocSet(machine: String, name: String, value: Any?, version: UInt64) async throws -> UInt64 {
        let result = try await call("doc.set", ["name": .string(name), "on": .string(machine),
                                                "value": HCJSONValue(foundation: value), "version": .integer(Int64(version))])
        guard let written = result["version"].uint else { throw HCUnavailableReason.malformedResponse }
        return written
    }

    func relayFileRead(machine: String, path: String) async throws -> String {
        let result = try await call("file.read", ["path": .string(path), "on": .string(machine)])
        guard let text = result["text"].string else { throw HCUnavailableReason.malformedResponse }
        return text
    }

    func relayMachines() async throws -> [String: (host: String, session: String?)] {
        let result = try await call("machine.list", [:])
        var machines: [String: (host: String, session: String?)] = [:]
        for machine in result["machines"].array ?? [] {
            guard let name = machine["name"].string else { continue }
            machines[name] = (machine["host"].string ?? name, machine["session"].string)
        }
        return machines
    }

    func snapshot() async -> HCInventorySnapshot { await session.snapshot() }

    /// C11H-228: one program on `machine` (argv, no shell), its exit code and stdout.
    func showExec(machine: String, argv: [String], timeout: TimeInterval) async throws -> ShowExecResult {
        let result = try await session.relayRequest("machine.exec", params: [
            "argv": .array(argv.map { .string($0) }), "on": .string(machine), "timeout": .number(timeout),
        ], seconds: timeout + 5)
        let code = result["code"].integer.flatMap { Int32(exactly: $0) }
        let stdout = result["stdout"].string.flatMap { Data(base64Encoded: $0) } ?? Data()
        return ShowExecResult(code: code, stdout: stdout, truncated: result["truncated"].bool ?? false)
    }

    /// C11H-228: writes `data` to `path` (relative paths start at that machine's home).
    func showWriteFile(machine: String, path: String, data: Data) async throws -> String {
        let result = try await session.relayRequest("file.write", params: [
            "path": .string(path), "on": .string(machine), "data": .string(data.base64EncodedString()),
        ], seconds: 15)
        return result["path"].string ?? path
    }

    func relayCurrentCreation(panel: UUID) async -> C11RelayCreationAnswer {
        await session.relayCurrentCreation(panelID: panel)
    }

    private func call(_ method: String, _ params: [String: HCJSONValue]) async throws -> HCJSONValue {
        do {
            return try await session.relayRequest(method, params: params, seconds: Self.callSeconds)
        } catch let failure as HCRPCFailure where failure.remoteCode == "conflict" {
            throw C11RelayStoreError.conflict
        }
    }
}

extension C11RelaySessionHost: ShowLinkHost {}

/// Runs an admitted relayed request through the same socket command
/// processor a local caller uses, on a worker thread (never main), with the
/// verified panel as the command's caller. The relay mail methods are served
/// here and nowhere else.
struct C11RelaySocketExecutor: C11RelayExecutor {
    /// The socket server instance; its command processor is nonisolated.
    nonisolated(unsafe) let controller: TerminalController

    func execute(_ admitted: C11RelayPolicy.Admitted, caller: C11RelayPolicy.VerifiedCaller,
                 originHost: String, machines: Set<String>, snapshot: HCInventorySnapshot) async -> String {
        let controller = self.controller
        let admitted = C11RelayPolicy.attributingJournalEvent(admitted,
            hcOwner: JournalCoordinator.shared.exactOwner(panelID: caller.panel))
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let response: String = autoreleasepool {
                    switch admitted {
                    case .v2(let method, let id, let params, _) where C11RelayMethods.all.contains(method):
                        return Self.mail(method: method, id: id, params: params, caller: caller,
                                         originHost: originHost, machines: machines)
                    case .v2(let method, let id, let params, _) where C11RelayPolicy.scopedReads.contains(method)
                        && Self.readRefusal(method: method, params: params, caller: caller, controller: controller) != nil:
                        // C11H-371: a read of anything outside the caller's workspace never runs.
                        return C11RelayPolicy.v2Reply(id: id, error: C11RelayPolicy.readScopeRefusal)
                    case .v2(_, _, _, let line), .v1(_, let line):
                        let context = SocketCommandContext(method: "connection", allowsFocus: false,
                                                           callerPanelId: caller.panel, hcInventory: snapshot)
                        context.relayMachine = caller.machine
                        context.relayLink = caller.link
                        context.relayReadScope = caller.readScope
                        return SocketCommandContext.withContext(context) {
                            controller.processCommandUsingSocketExecutionPolicy(line)
                        }
                    }
                }
                continuation.resume(returning: response)
            }
        }
    }

    /// C11H-371: why a scoped read may not run: the caller's workspace is
    /// unknown, or (for a gated read) a target it names lies outside it.
    static func readRefusal(method: String, params: [String: Any], caller: C11RelayPolicy.VerifiedCaller,
                            controller: TerminalController) -> C11RelayPolicy.Refusal? {
        guard let scope = caller.readScope else { return C11RelayPolicy.readScopeRefusal }
        guard C11RelayPolicy.gatedReads.contains(method) else { return nil }
        return controller.relayReadOutsideScope(params, scope: scope) ? C11RelayPolicy.readScopeRefusal : nil
    }

    static func mail(method: String, id: Any?, params: [String: Any], caller: C11RelayPolicy.VerifiedCaller,
                     originHost: String, machines: Set<String>) -> String {
        do {
            let mailbox = C11RelayMailbox(stateURL: try MailboxLayout.defaultStateURL())
            switch method {
            case C11RelayMethods.mailboxSend:
                let address = caller.workspace.flatMap { workspace in
                    PanelMetadataStore.shared.getMetadata(workspaceId: workspace, surfaceId: caller.panel).0["mailbox.address"] as? String
                }
                let sent = try mailbox.send(envelope: params["envelope"] as Any, targetWorkspace: params["workspace_id"],
                                            caller: caller, callerAddress: address, originHost: originHost, machines: machines)
                return C11RelayPolicy.v2Reply(id: id, result: ["id": sent.id, "from": sent.from])
            case C11RelayMethods.mailboxPeek:
                return C11RelayPolicy.v2Reply(id: id, result: ["messages": try mailbox.peek(caller: caller, panel: params["panel"])])
            default:
                let acked = try mailbox.ack(caller: caller, panel: params["panel"], ids: params["ids"])
                return C11RelayPolicy.v2Reply(id: id, result: ["acked": acked])
            }
        } catch let refusal as C11RelayPolicy.Refusal {
            return C11RelayPolicy.v2Reply(id: id, error: refusal)
        } catch {
            return C11RelayPolicy.v2Reply(id: id, error: .init(code: "mailbox_error", message: "\(error)"))
        }
    }
}

/// C11H-371: the read gate. A relayed read may name only what lies in the
/// caller's workspace: that workspace, its panels and areas, and the window
/// that holds it. Every key that names a target counts, in any spelling the
/// socket accepts, so no alias can name something the canonical key does not.
extension TerminalController {
    /// Whether `params` name any window, workspace, area or panel outside
    /// `scope`. A target that is not a string, or resolves to nothing live,
    /// counts as outside. A workspace or panel named by UUID is checked here,
    /// on the worker: the workspace by equality, the panel by its journal
    /// target (where the service finds the caller's own workspace). Short
    /// refs, areas and windows need c11's model: one main hop, bounded by
    /// `mainBound` like the handlers' own captures; a hop that does not
    /// answer in time counts as outside.
    nonisolated func relayReadOutsideScope(_ params: [String: Any], scope: C11RelayPolicy.ReadScope,
                                           mainBound: TimeInterval = SelectionRead.defaultOperationTimeout) -> Bool {
        var onMain: [(C11RelayPolicy.ReadTargetKind, String?)] = []
        for (key, value) in params where C11RelayPolicy.isReadTargetKey(key) {
            let kind = C11RelayPolicy.readTargetKind(key)
            guard let raw = value as? String else { return true }
            let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            switch (kind, id) {
            case (.workspace, let id?):
                if id != scope.workspace { return true }
            case (.panel, let id?):
                if JournalCoordinator.shared.target(panelID: id) != scope.workspace { return true }
            default:
                onMain.append((kind, raw))
            }
        }
        guard !onMain.isEmpty else { return false }
        let operation = SelectionReadOperation<Bool>(timeout: mainBound)
        let capture = {
            MainActor.assumeIsolated {
                guard operation.beginCapture() else { return }
                operation.complete(self.relayReadTargetsOutside(onMain, scope: scope))
            }
        }
        if Thread.isMainThread { capture() } else { DispatchQueue.main.async(execute: capture) }
        guard let outside = operation.wait(), operation.canPublish else { return true }
        return outside
    }

    private func relayReadTargetsOutside(_ targets: [(C11RelayPolicy.ReadTargetKind, String?)],
                                         scope: C11RelayPolicy.ReadScope) -> Bool {
        guard let app = AppDelegate.shared else { return true }
        for (kind, raw) in targets {
            guard let raw, let id = v2UUIDAny(raw) else { return true }
            switch kind {
            case .workspace:
                if id != scope.workspace { return true }
            case .panel:
                if app.locateSurface(surfaceId: id)?.workspaceId != scope.workspace { return true }
            case .area:
                if app.locatePane(paneId: id)?.workspace.id != scope.workspace { return true }
            case .window:
                guard let manager = app.workspaceManagerFor(windowId: id),
                      manager.workspaces.contains(where: { $0.id == scope.workspace }) else { return true }
            }
        }
        return false
    }

    /// C11H-371: the window that holds the relayed caller's workspace.
    func relayScopeWindowId(_ scope: C11RelayPolicy.ReadScope) -> UUID? {
        guard let app = AppDelegate.shared, let manager = app.workspaceManagerFor(workspaceId: scope.workspace) else { return nil }
        return app.windowId(for: manager)
    }
}

/// C11H-176: hands a terminal c11 is about to open on another machine its
/// relay credential. The credential, masked by a fresh pad, goes into a
/// one-time pickup document on that machine; only the pad goes into the
/// launch env (hc keeps launch env on disk). The terminal's launch line
/// claims the document once, before its login shell (`C11RelayAuth.pickUp`).
enum C11RelayPickupDelivery {
    /// The launch env value (`C11_RELAY_PICKUP`), or nil when anything fails:
    /// the terminal then opens without a credential and its relayed calls are
    /// refused with `relay_auth_missing`. Never throws, never blocks the open
    /// beyond its two document calls.
    static func deliver(host: any C11RelayHost, keyring: any C11RelayLinkSecrets, ledger: C11RelayPickupLedger,
                        session: String, machine: String, panel: UUID, creation: UUID,
                        lingerSeconds: TimeInterval = C11RelayAuth.pickupLingerSeconds) async -> String? {
        guard let link = keyring.secretCreatingIfNeeded(session: session, machine: machine),
              let pad = C11RelayAuth.randomBytes(32) else {
            C11RelayLog.event("pickup-failed machine=\(machine) panel=\(panel.uuidString.lowercased()) reason=no_secret")
            return nil
        }
        let credential = C11RelayAuth.terminalKey(link: link, session: session, machine: machine, panel: panel, creation: creation)
        let masked = C11RelayAuth.xor(credential, pad)
        let name = C11RelayAuth.pickupName(creation: creation)
        do {
            let (_, version) = try await host.relayDocGet(machine: machine, name: name)
            _ = try await host.relayDocSet(machine: machine, name: name,
                                           value: C11RelayAuth.pickupDocument(linkID: link.id, creation: creation, masked: masked),
                                           version: version)
        } catch {
            C11RelayLog.event("pickup-failed machine=\(machine) panel=\(panel.uuidString.lowercased()) reason=doc_write")
            return nil
        }
        // A document the terminal never claimed (its launch line did not
        // run, or failed) is removed and its credential refused; one it
        // claimed is already gone. The ledger keeps it until then, so a
        // document left when c11 quits is settled at the next link-up.
        let pending = C11RelayPickupLedger.Pending(machine: machine, name: name, creation: creation.uuidString.lowercased(),
                                                    masked: C11RelayAuth.hex(masked),
                                                    at: Int64(Date().timeIntervalSince1970 * 1000))
        ledger.add(pending)
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(max(0, lingerSeconds) * 1_000_000_000))
            await settle(pending, host: host, ledger: ledger)
        }
        return C11RelayAuth.Pickup(linkID: link.id, creation: creation, pad: pad).value
    }

    /// Settles one pickup. Gone means the terminal claimed it. c11's own
    /// document still there means nobody did: c11 deletes it, and only when
    /// that delete wins is the credential refused (a terminal that claims in
    /// the same moment wins instead). A different document under the name is
    /// someone else's, so c11's was claimed and nothing is revoked. An
    /// unanswered call leaves it pending for the next try.
    static func settle(_ pending: C11RelayPickupLedger.Pending, host: any C11RelayHost,
                       ledger: C11RelayPickupLedger) async {
        for _ in 0..<3 {
            guard let (value, version) = try? await host.relayDocGet(machine: pending.machine, name: pending.name) else { return }
            guard value != nil, C11RelayAuth.maskedValue(value) == pending.masked else { ledger.claimed(pending.name); return }
            do {
                _ = try await host.relayDocSet(machine: pending.machine, name: pending.name, value: nil, version: version)
            } catch C11RelayStoreError.conflict {
                continue   // the terminal (or someone) changed it meanwhile: look again
            } catch {
                return
            }
            ledger.unclaimed(pending.name, creation: pending.creation, at: Int64(Date().timeIntervalSince1970 * 1000))
            C11RelayLog.event("pickup-unclaimed machine=\(pending.machine) \(pending.name) creation=\(pending.creation)")
            return
        }
    }
}
