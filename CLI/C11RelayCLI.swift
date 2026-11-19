import Foundation

/// The CLI side of c11's prototype relay (plan ticket 14). Active only when
/// the relay shim on another machine set `C11_RELAY_HC_SOCKET` and
/// `C11_RELAY_SESSION`; every other `c11` run is unchanged.
///
/// In relay mode each socket request line travels through that machine's
/// c11 hc core to c11 (`C11RelayClient`). Socket discovery, password
/// lookup and the local mailbox and journal directories are never used:
/// they belong to the machine c11 runs on, not this one.
enum C11RelayCLI {
    struct Configuration: Equatable {
        let hcSocket: String
        let session: String
        let caller: C11RelayClient.Caller?
        let claimMilliseconds: Int

        init?(environment: [String: String]) {
            guard let socket = environment["C11_RELAY_HC_SOCKET"], !socket.isEmpty,
                  let session = environment["C11_RELAY_SESSION"], !session.isEmpty else { return nil }
            hcSocket = socket
            self.session = session
            claimMilliseconds = C11Relay.claimMilliseconds(environment: environment)
            let panel = CMUXCLI.callerPanelEnv(environment).flatMap { UUID(uuidString: $0)?.uuidString }
            let workspace = (environment["C11_WORKSPACE_ID"] ?? environment["CMUX_WORKSPACE_ID"])
                .flatMap { UUID(uuidString: $0)?.uuidString }
            let term = environment["HC_TERMINAL_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let panel, let term, !term.isEmpty {
                // C11H-176: the credential the launch line's pickup exported.
                caller = C11RelayClient.Caller(panel: panel, workspace: workspace, term: term,
                                                credential: C11RelayAuth.Credential(environment[C11RelayAuth.credentialVariable]))
            } else {
                caller = nil
            }
        }

        /// The shim bakes these in; anything else is not our relay.
        var isValid: Bool {
            guard session.range(of: #"^c11(-[A-Za-z0-9][A-Za-z0-9._-]*)?$"#, options: .regularExpression) != nil else {
                return false
            }
            return hcSocket.hasPrefix("/") && !hcSocket.contains("..")
                && hcSocket.hasSuffix("/.local/share/c11/run/\(session).sock")
        }
    }

    static let current: Configuration? = Configuration(environment: ProcessInfo.processInfo.environment)

    static var isActive: Bool { current != nil }

    /// One per process: a reconnect makes a new client but keeps what the
    /// first unreachable call learned.
    static let downLatch = C11RelayDownLatch()

    static func makeClient() throws -> C11RelayClient {
        guard let current else { throw CLIError(message: "relay_unavailable: not a c11 relay terminal") }
        guard current.isValid else {
            throw CLIError(message: "relay_unavailable: C11_RELAY_HC_SOCKET / C11_RELAY_SESSION do not name a c11 session")
        }
        guard let caller = current.caller else {
            throw CLIError(message: String(localized: "relay.cli.error.noIdentity",
                defaultValue: "relay_identity_missing: run c11 inside a c11 terminal (C11_PANEL_ID and HC_TERMINAL_ID are not set)"))
        }
        // C11H-97: each claim timeout leaves one line in this session's relay
        // folder, so "never reached c11" can be told from "served empty".
        let session = current.session
        let log = ProcessInfo.processInfo.environment["HOME"].map { C11RelayTrace.logURL(home: $0, session: session) }
        return C11RelayClient(store: C11RelayHCStore(socketPath: current.hcSocket), caller: caller,
                               claimMilliseconds: current.claimMilliseconds, latch: downLatch,
                               onClaimTimeout: { request, slot, waited, error in
                                   guard let log else { return }
                                   C11RelayTrace.append(C11RelayTrace.timeoutLine(at: Date(), session: session, slot: slot,
                                       request: request, waitedMilliseconds: waited, error: error), to: log)
                               })
    }

    /// C11H-176: `c11 relay-pickup`, run once by a remote terminal's launch
    /// line before its login shell. Prints the shell line that exports the
    /// terminal's credential, or nothing. Bounded by short hc calls, so a
    /// slow or missing core never holds the shell back noticeably.
    static func pickup(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let current = Configuration(environment: environment), current.isValid else { return nil }
        let store = C11RelayHCStore(socketPath: current.hcSocket, timeout: pickupCallSeconds)
        defer { store.close() }
        return C11RelayAuth.pickUp(environment: environment, store: store)
    }

    /// Each hc call's bound; with one retry per call the pickup gives up
    /// within about 2 s on a core that does not answer, and at once when
    /// there is no core.
    static let pickupCallSeconds: TimeInterval = 0.5

    /// A relayed error as the CLI reports it.
    /// `mailbox recv --ack` printed envelopes, then the ack failed.
    static func unacknowledgedMessage(printed: Int, error: Error) -> String {
        C11Relay.unacknowledgedMessage(printed: printed, reason: (error as? CLIError)?.message ?? "\(error)")
    }

    static func cliError(_ error: Error) -> CLIError {
        if let relay = error as? C11RelayCallError { return CLIError(message: relay.cliMessage) }
        return CLIError(message: "relay_unavailable: \(error)")
    }

    /// Mailbox commands that read or write the mailbox directories directly.
    /// Those directories live on the machine c11 runs on.
    static func refuseFileMailboxCommand(_ subcommand: String) throws {
        throw CLIError(message: String(format: String(localized: "relay.cli.error.mailboxFiles",
            defaultValue: "relay_unsupported: c11 mailbox %@ reads c11's mailbox folders, which are not on this machine. Use mailbox send and mailbox recv."),
            subcommand))
    }
}
