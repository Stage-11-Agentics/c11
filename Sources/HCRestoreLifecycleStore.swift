import Foundation
import Combine

/// Observes the existing per-panel runtime; it never creates or attaches a
/// terminal. A binding belongs to an object, not merely a reusable panel UUID.
@MainActor
final class HCRestoreLifecycleStore {
    static let shared = HCRestoreLifecycleStore()

    @MainActor private final class Binding {
        weak var session: HCPanelSession?
        var projection: HCRestoreLifecycleProjection
        var observation: AnyCancellable?

        init(_ session: HCPanelSession) {
            self.session = session
            projection = HCRestoreLifecycleProjection(identity: session.identity)
            // A converged replacement may have reached its fresh shell before
            // c11 quit, while its resume was still pending. Reconstruct the
            // attempted replacement from the saved identity/proof. A live
            // inventory must still match this panel and creation before input.
            if let entry = HCPanelRestoreState.shared.entry(for: session.identity.panelID),
               entry.migrationEnd != nil, let creation = entry.creation,
               creation.creationID == session.identity.creationID,
               let proof = creation.replaces {
                projection.receive(.ended(proof))
                projection.willCreate(creation.creationID)
            }
        }
    }
    private var bindings: [UUID: Binding] = [:]

    func observe(_ session: HCPanelSession) {
        if bindings[session.identity.panelID]?.session === session { return }
        let binding = Binding(session)
        bindings[session.identity.panelID] = binding
        binding.observation = session.$lifecycle.sink { [weak binding] lifecycle in
            binding?.projection.receive(lifecycle)
        }
        session.onWillCreate = { [weak self, weak session] creationID, proof in
            guard let session else { return }
            self?.willCreate(creationID, replacing: proof, in: session)
        }
        session.onCreationOutcome = { [weak self, weak session] creationID, result in
            guard let session else { return }
            self?.didCreate(result, creationID: creationID, in: session)
        }
        session.onCreationAdopted = { [weak self, weak session] attempt, made in
            guard let self, let session, let binding = self.bindings[session.identity.panelID],
                  binding.session === session else { return }
            binding.projection.adopt(made, for: attempt)
        }
    }

    func permitsResume(_ session: HCPanelSession) -> Bool {
        observe(session)
        guard case .live(let record) = session.lifecycle,
              let binding = bindings[session.identity.panelID],
              binding.projection.identity.key == record.key else { return false }
        return binding.projection.permitsConversationResume
    }

    func forget(_ session: HCPanelSession) {
        guard bindings[session.identity.panelID]?.session === session else { return }
        bindings.removeValue(forKey: session.identity.panelID)
    }

    /// The composition callbacks call these with the original runtime object,
    /// so a late completion cannot grant resume on a replacement UI graph.
    func willCreate(_ creationID: UUID, replacing proof: HCEndEvidence? = nil, in session: HCPanelSession) {
        guard let binding = bindings[session.identity.panelID], binding.session === session else { return }
        // 2C publishes creationPending before this callback. Its explicit
        // proof carries the pre-create resolved end across that publication.
        if let proof { binding.projection.receive(.ended(proof)) }
        binding.projection.willCreate(creationID)
    }

    func didCreate(_ result: HCCreateResult, creationID: UUID, in session: HCPanelSession) {
        guard let binding = bindings[session.identity.panelID], binding.session === session else { return }
        binding.projection.didCreate(result, creationID: creationID)
    }
}
