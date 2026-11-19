import Foundation

/// Ticket 12: the `on` param of `panel.create`, `area.create` and
/// `agent.launch` (`--on <machine>` in the CLI).
struct V2MachineParam {
    /// How the new terminal picks its machine.
    let request: HCMachineRequest
    /// With an explicit machine, `cwd` is a path there: taken verbatim, never
    /// validated against this Mac's file system.
    let remoteCwd: String?

    var isRemote: Bool {
        if case .on = request { return true }
        return false
    }
}

extension TerminalController {
    /// Off-main. Without `on` the request is `absent`: `.inherit` for a split
    /// (a split of a remote terminal runs on that terminal's machine) and
    /// `.local` for a new panel, so everything else stays local exactly as
    /// before. `on: "local"` forces this
    /// Mac. A named machine is checked against the live inventory, bounded by
    /// one short main hop (to read the composed source) and a 2 s snapshot wait.
    nonisolated func v2ResolveMachineParam(_ params: [String: Any], panelType: PanelType,
                               absent: HCMachineRequest = .local) -> Result<V2MachineParam, V2CallResult> {
        guard params.keys.contains("on") else { return .success(V2MachineParam(request: absent, remoteCwd: nil)) }
        guard let raw = (params["on"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(.err(code: "invalid_params", message: "on must be a machine name", data: nil))
        }
        if HCMachineTarget.localWords.contains(raw.lowercased()) {
            return .success(V2MachineParam(request: .local, remoteCwd: nil))
        }
        guard panelType == .terminal else { return .failure(Self.v2MachineError(.notTerminal)) }
        let source = Self.v2ComposedInventory(seconds: HCLimits.connectSeconds)
        let snapshot = source.flatMap { Self.v2BoundedSnapshot($0, seconds: HCLimits.connectSeconds) }
        // C11H-391: routed per session, so a usable link of the name wins.
        // C11H-396: a name the starting links session lists is not ready yet.
        switch HCMachineTarget.resolve(requested: raw, snapshot: snapshot, linked: .shared) {
        case .failure(let error):
            return .failure(Self.v2MachineError(error))
        case .success(nil):
            return .success(V2MachineParam(request: .local, remoteCwd: nil))
        case .success(let machine?):
            var cwd: String?
            if let text = (params["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.lowercased() != "inherit" {
                cwd = text
            }
            return .success(V2MachineParam(request: .on(machine), remoteCwd: cwd))
        }
    }

    /// The composed inventory source, read on main by an async hop with a
    /// bounded wait: a busy main thread yields nil (hc_unavailable), never a hang.
    nonisolated static func v2ComposedInventory(seconds: TimeInterval) -> (any HCInventorySource)? {
        if Thread.isMainThread { return MainActor.assumeIsolated { HCBackendComposition.shared.inventory } }
        final class Box: @unchecked Sendable { var value: (any HCInventorySource)? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.value = MainActor.assumeIsolated { HCBackendComposition.shared.inventory }
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }

    nonisolated static func v2MachineError(_ error: HCMachineTargetError) -> V2CallResult {
        var data: [String: Any]?
        if case .unknown(_, let known) = error { data = ["machines": known] }
        return .err(code: error.code, message: error.message, data: data)
    }

    /// The canonical source answers from its reducer; a slow core yields nil
    /// (reported as hc_unavailable), never an indefinite wait on a socket thread.
    nonisolated static func v2BoundedSnapshot(_ source: any HCInventorySource, seconds: TimeInterval) -> HCInventorySnapshot? {
        final class Box: @unchecked Sendable { var value: HCInventorySnapshot? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await source.snapshot()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }
}
