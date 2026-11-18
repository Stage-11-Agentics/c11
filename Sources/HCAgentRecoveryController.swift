import Foundation

/// App projection of the same inventory used by socket admission. This owns
/// no terminal lifecycle or input: it only restarts the existing tty observers.
final class HCAgentRecoveryController: @unchecked Sendable {
    static let shared = HCAgentRecoveryController()
    private let queue = DispatchQueue(label: "com.stage11.c11.agent-recovery-projection", qos: .utility)
    private var recovery: HCAgentRecovery?
    private var claims: [UUID: HCTerminalKey] = [:]

    /// What one panel's observers were last armed with. Re-arming happens only
    /// when this changes, so it carries the key's own shard generation: another
    /// shard starting or reconnecting never re-arms this panel (C11H-77).
    struct Applied: Equatable, Sendable {
        let workspaceID: UUID
        let key: HCTerminalKey
        let process: HCProcessIdentity
        let tty: String
        let generation: UInt64

        init(workspaceID: UUID, observation: HCAgentRecoveryObservation) {
            self.workspaceID = workspaceID
            key = observation.key
            process = observation.rootProcessIdentity
            tty = observation.ttyName
            generation = observation.connectionGeneration
        }
    }
    @MainActor private var applied: [UUID: Applied] = [:]

    func install(inventory: any HCInventorySource) {
        queue.async { [self] in
            recovery?.stop()
            let observer = HCAgentRecovery(inventory: inventory) { [weak self] observations in
                self?.receive(observations)
            }
            recovery = observer
            observer.setClaims(claims)
            observer.start()
        }
    }

    func setPanelIdentity(_ identity: HCPanelIdentity?, panelID: UUID) {
        queue.async { [self] in
            claims[panelID] = identity?.persistence == .persistent ? identity?.key : nil
            recovery?.setClaims(claims)
            if identity == nil || identity?.persistence == .nonpersistent {
                Task { @MainActor [weak self] in self?.applied.removeValue(forKey: panelID) }
            }
        }
    }

    private func receive(_ observations: [HCAgentRecoveryObservation]) {
        queue.async { [weak self] in
            guard let self, let observer = self.recovery else { return }
            DispatchQueue.main.async { [weak self, weak observer] in
                MainActor.assumeIsolated {
                    guard let self, let observer else { return }
                    for observation in observations where observer.isCurrent(observation) {
                        self.apply(observation)
                    }
                }
            }
        }
    }

    @MainActor private func apply(_ observation: HCAgentRecoveryObservation) {
        guard let identity = HCProcessAdmission.shared.panelIdentity(observation.panelID),
              identity.persistence == .persistent, identity.key == observation.key,
              let located = AppDelegate.shared?.workspaceContainingPanel(panelId: observation.panelID),
              located.workspace.panels[observation.panelID] is TerminalPanel else { return }
        let workspace = located.workspace
        let facts = Applied(workspaceID: workspace.id, observation: observation)
        guard applied[observation.panelID] != facts else { return }
        applied[observation.panelID] = facts
        workspace.panelTTYNames[observation.panelID] = facts.tty
        PortScanner.shared.registerTTY(workspaceId: workspace.id, panelId: observation.panelID, ttyName: facts.tty)
        PortScanner.shared.kick(workspaceId: workspace.id, panelId: observation.panelID)
        AgentDetector.shared.registerTTY(workspaceId: workspace.id, panelId: observation.panelID,
            ttyName: facts.tty, recoverAgent: true, rootProcess: facts.process)
        PanelMetricsSampler.shared.setPidProvider(surfaceId: observation.panelID) {
            guard HCAgentRecoveryKernel.readProcess(facts.process.pid)?.identity == facts.process else { return nil }
            return TerminalPIDResolver.foregroundPID(forTTYName: facts.tty)
        }
        // C11H-184: hc's inventory names no tty, so the doorbell could not
        // relearn the surviving agent until now. Mail held since the relaunch
        // rings once the kernel agrees.
        if let panel = workspace.panels[observation.panelID] as? TerminalPanel {
            workspace.noteHCLocalMailbox(panel)
        }
    }
}
