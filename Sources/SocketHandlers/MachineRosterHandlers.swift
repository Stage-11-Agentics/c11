import Foundation

extension TerminalController {
    /// C11H-126: the machine roster (`c11 machine list|set|rm`). Pure store
    /// reads and writes; runs on the socket worker, never on main. Open chips
    /// repaint from the roster's own change signal.
    nonisolated static func v2MachineRoster(method: String, params: [String: Any]) -> V2CallResult {
        let roster = MachineRoster.shared
        switch method {
        case "machine.list":
            let linked = HCLinkedMachines.shared.snapshot()
            let rows = MachineRosterRow.rows(
                roster: roster.all(),
                linked: linked,
                localHostName: LocalSessionPlacementFeed.localHostName
            )
            // C11H-391: each session that links a row's name (after the switch
            // to c11 2.0, c11h's old link and c11's own can share a name).
            let sessions = HCLinkedMachines.shared.sessionMachines().sorted { $0.shard < $1.shard }
            let unusable = HCLinkedMachines.shared.unusableSessions()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let objects = rows.map { row -> [String: Any] in
                var object = row.jsonObject
                let links = sessions.compactMap { entry -> [String: Any]? in
                    entry.machines[row.id].map {
                        ["session": entry.session, "connected": $0 == .connected,
                         "usable": !(unusable[entry.session]?.contains(row.id) ?? false),
                         "c11h_link": MachineRemoval.isC11hLink(viaPath: nil, session: entry.session, home: home)]
                    }
                }
                if !links.isEmpty { object["links"] = links }
                return object
            }
            return .ok([
                "machines": objects,
                "count": rows.count,
                "hc_inventory": linked == nil ? "pending" : "ready",
            ])
        case "machine.set":
            guard let id = params["id"] as? String else {
                return .err(code: "invalid_params", message: "id is required", data: nil)
            }
            guard params["name"] != nil || params["color"] != nil else {
                return .err(code: "invalid_params", message: "set needs a name or a color to change", data: nil)
            }
            let name: MachineRosterFieldChange
            let color: MachineRosterFieldChange
            switch fieldChange(params["name"]) {
            case .success(let change): name = change
            case .failure:
                return .err(code: "invalid_params", message: "name must be a string or null", data: nil)
            }
            switch fieldChange(params["color"]) {
            case .success(let change): color = change
            case .failure:
                return .err(code: "invalid_params", message: "color must be a string or null", data: nil)
            }
            do {
                let entry = try roster.set(id: id, name: name, color: color)
                let normalized = MachineRoster.normalizedID(id) ?? id
                return .ok([
                    "id": normalized,
                    "machine": entry?.jsonObject ?? ["id": normalized, "name": NSNull(), "color": NSNull()],
                ])
            } catch let error as MachineRosterError {
                return .err(code: "invalid_params", message: error.message, data: nil)
            } catch {
                return .err(code: "internal_error", message: "failed to save the machine roster", data: nil)
            }
        case "machine.rm":
            guard let id = params["id"] as? String else {
                return .err(code: "invalid_params", message: "id is required", data: nil)
            }
            do {
                let removed = try roster.remove(id: id)
                return .ok(["id": MachineRoster.normalizedID(id) ?? id, "removed": removed])
            } catch let error as MachineRosterError {
                return .err(code: "invalid_params", message: error.message, data: nil)
            } catch {
                return .err(code: "internal_error", message: "failed to save the machine roster", data: nil)
            }
        default:
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
    }

    /// C11H-126 part 2: remove a linked machine. Lists c11's terminals on it;
    /// unless `dry_run`, ends them (closing a panel ends its session), then
    /// unlinks (`MachineRemoval.unlink`). An operator action (`c11 machine
    /// unlink`), never an agent's own call.
    nonisolated func v2MachineUnlink(params: [String: Any]) -> V2CallResult {
        guard let raw = params["id"] as? String else {
            return .err(code: "invalid_params", message: "id is required", data: nil)
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let dryRun = params["dry_run"] as? Bool ?? false
        // C11H-391: whose link, when c11 and c11h both link the name.
        let requestedSession = ((params["session"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        enum Found { case machine(String, session: String?), missing, ambiguous(String, [String]), noSession(String, [String]) }
        // Main, through the socket's own hop (focus policy carried): the panel
        // list and closes are workspace state. The unlink runs here, off main.
        let context = SocketCommandContext.current
        let onMain: () -> (HCLaunchConfiguration?, Found, [MachineRemoval.Terminal], Int) = {
            SocketCommandContext.withContext(context) {
            MainActor.assumeIsolated {
                guard let machine = MachinePicker.liveMachines().keys.first(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
                    return (nil, .missing, [], 0)
                }
                let (sole, sessions) = MachineRemoval.soleLinkSession(of: machine)
                let session: String?
                if let requestedSession {
                    guard sessions.contains(requestedSession) else { return (nil, .noSession(machine, sessions), [], 0) }
                    session = requestedSession
                } else if sessions.count > 1 {
                    return (nil, .ambiguous(machine, sessions), [], 0)
                } else {
                    session = sole
                }
                let configuration = session.map { MachineRemoval.configuration(forSession: $0) }
                    ?? HCBackendComposition.shared.configuration
                let listed = MachineRemoval.terminals(on: machine, session: session)
                let ended = dryRun ? 0 : MachineRemoval.endTerminals(on: machine, session: session)
                return (configuration, .machine(machine, session: session), listed, ended)
            }
            }
        }
        // As `v2MainSync` does: the request's context crosses the hop.
        let snapshot = Thread.isMainThread ? onMain() : DispatchQueue.main.sync(execute: onMain)
        let (configuration, found, listed, ended) = snapshot
        let machine: String
        let session: String?
        switch found {
        case .missing:
            return .err(code: "not_found", message: "no machine called \(id) is linked", data: nil)
        case .ambiguous(let name, let sessions):
            return .err(code: "machine_link_ambiguous", message: String(format: String(localized: "machineRemove.ambiguous",
                defaultValue: "%1$@ is linked by more than one session (%2$@). Say which link to remove with --session."),
                name, sessions.joined(separator: ", ")), data: ["machine": name, "sessions": sessions])
        case .noSession(let name, let sessions):
            return .err(code: "not_found", message: String(format: String(localized: "machineRemove.noSuchLink",
                defaultValue: "%1$@ has no link in session %2$@; its links are in %3$@."),
                name, requestedSession ?? "", sessions.joined(separator: ", ")), data: ["machine": name, "sessions": sessions])
        case .machine(let name, let linkSession):
            machine = name
            session = linkSession
        }
        let terminals: [[String: Any]] = listed.map {
            ["panel_id": $0.panelId.uuidString, "workspace_id": $0.workspaceId.uuidString,
             "title": $0.title, "workspace_title": $0.workspaceTitle]
        }
        if dryRun {
            return .ok(["machine": machine, "terminals": terminals, "dry_run": true, "session": session.map { $0 as Any } ?? NSNull()])
        }
        guard let configuration else {
            return .err(code: "core_unavailable", message: HCMachineSetupFailure.coreUnavailable("no hc session").message, data: nil)
        }
        switch MachineRemoval.unlink(machine: machine, configuration: configuration, origin: "socket") {
        case .success(let outcome):
            return .ok(["machine": machine, "terminals": terminals, "ended": ended, "removed": true,
                        "left_running": outcome.leftRunning, "stop_refused": outcome.stopRefused,
                        "c11h_link": outcome.c11hLink, "link_was_up": outcome.linkWasUp,
                        "session": configuration.session])
        case .failure(let failure):
            return .err(code: failure.code, message: failure.message, data: ["ended": ended])
        }
    }

    /// C11H-391: `c11 machine link` (after its consent) asks the app for the
    /// session a new link lands in, and to start that session's core: while
    /// this app has adopted c11h's sessions, the links session, whose core
    /// starts only when Add Machine asks. Starts nothing else, links nothing.
    nonisolated static func v2MachineLinkSession() -> V2CallResult {
        final class Box: @unchecked Sendable { var session: String?; var serving = false }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let composition = HCBackendComposition.shared
            box.session = composition.linkConfiguration?.session
            box.serving = await composition.startLinkSession()
            done.signal()
        }
        guard done.wait(timeout: .now() + HCLimits.runSeconds + HCLimits.connectSeconds) == .success else {
            return .err(code: "hc_unavailable", message: String(localized: "machineSetup.linkSession.timeout",
                defaultValue: "c11's hc core for new links did not start in time. Try again, or use Settings > Herder Topography > Add Machine."), data: nil)
        }
        guard let session = box.session else {
            return .err(code: "core_unavailable", message: HCMachineSetupFailure.coreUnavailable("no hc session").message, data: nil)
        }
        return .ok(["session": session, "serving": box.serving])
    }

    private struct FieldTypeError: Error {}

    /// Absent keeps the field, null or "" clears it, a string sets it.
    nonisolated private static func fieldChange(_ value: Any?) -> Result<MachineRosterFieldChange, FieldTypeError> {
        guard let value else { return .success(.keep) }
        if value is NSNull { return .success(.clear) }
        guard let string = value as? String else { return .failure(FieldTypeError()) }
        return .success(.set(string))
    }
}
