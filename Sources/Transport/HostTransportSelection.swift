import Foundation

// C11H-72: which `HostTransport` consumers are handed. The relay is the
// production transport. The bus carries test traffic only, and only when the
// launch asks for it: c11's real mail stays on the relay until sealing ships
// and a separate go switches it (bus D70, Cut 1).

enum HostTransportSelection {
    /// Per-launch flag, read once at launch and never persisted (like
    /// `C11_QA_LAUNCH`). Set only by c11's own guest launch scripts.
    static let environmentKey = "C11_HOST_TRANSPORT_BUS"

    enum Mode: Equatable, Sendable {
        /// Everything on the relay; nothing is built for the bus.
        case relay
        /// The reserved test recipients go to the bus; everything else stays on the relay.
        case busTestTraffic
    }

    static func mode(environment: [String: String]) -> Mode {
        environment[environmentKey] == "test" ? .busTestTraffic : .relay
    }

    /// The reserved test recipient (A6's `c11:` prefix, never a panel address).
    static let testRecipient = "c11:bus-test"

    static func isTestTraffic(_ envelope: HostEnvelope) -> Bool {
        guard let to = envelope.to else { return false }
        return to == testRecipient || to.hasPrefix(testRecipient + "/")
    }

    /// The transport consumers get. `bus` is built only in test-traffic mode.
    static func transport(relay: any HostTransport, mode: Mode,
                          bus: () -> any HostTransport) -> any HostTransport {
        switch mode {
        case .relay: return relay
        case .busTestTraffic: return HostTransportTestTrafficRouter(relay: relay, bus: bus())
        }
    }
}

/// Test traffic to the bus, everything else to the relay. Production mail,
/// layer records and transcript entries cannot reach the bus through it,
/// because only `c11:bus-test` recipients are routed there.
final class HostTransportTestTrafficRouter: HostTransport, @unchecked Sendable {
    let relay: any HostTransport
    let bus: any HostTransport

    init(relay: any HostTransport, bus: any HostTransport) {
        self.relay = relay
        self.bus = bus
    }

    var host: String { relay.host }

    func send(_ envelope: HostEnvelope, to host: String) async -> HostTransportResult {
        HostTransportSelection.isTestTraffic(envelope)
            ? await bus.send(envelope, to: host) : await relay.send(envelope, to: host)
    }

    func hold(_ envelope: HostEnvelope, for host: String) async -> HostTransportResult {
        HostTransportSelection.isTestTraffic(envelope)
            ? await bus.hold(envelope, for: host) : await relay.hold(envelope, for: host)
    }

    /// Production consumers read the relay only.
    func receive(from host: String) -> any HostTransportInbox { relay.receive(from: host) }

    /// The test traffic's own stream.
    func receiveTestTraffic(from host: String) -> any HostTransportInbox { bus.receive(from: host) }
}
