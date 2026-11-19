import Foundation

/// Mail for a relayed caller (plan ticket 14). The mailbox folders live on
/// the machine c11 runs on, so the relayed CLI hands its envelope here and
/// reads its own inbox through here. Envelope format stays c11's v1.
struct C11RelayMailbox {
    let stateURL: URL
    var fileManager: FileManager = .default

    static let maxPeekMessages = 64
    static let maxPeekBytes = 512 * 1024

    struct Sent: Equatable {
        let id: String
        let from: String
    }

    /// Validates and stamps a relayed envelope and writes it into the target
    /// workspace's outbox, where the normal dispatcher delivers it.
    /// `callerAddress` is the caller panel's `mailbox.address`, read from
    /// c11's own metadata; nil or empty when it has none.
    func send(envelope object: Any, targetWorkspace rawWorkspace: Any?, caller: C11RelayPolicy.VerifiedCaller,
              callerAddress: String?, originHost: String, machines: Set<String>) throws -> Sent {
        guard let workspaceRaw = rawWorkspace as? String, let workspace = UUID(uuidString: workspaceRaw) else {
            throw C11RelayPolicy.Refusal(code: "invalid_params", message: "workspace_id must be a UUID")
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= 16 * 1024 else {
            throw C11RelayPolicy.Refusal(code: "invalid_params", message: "envelope must be a v1 envelope object")
        }
        let envelope: MailboxEnvelope
        do { envelope = try MailboxEnvelope.validate(data: data) }
        catch { throw C11RelayPolicy.Refusal(code: "invalid_envelope", message: "\(error)") }
        guard envelope.bodyRef == nil else {
            throw C11RelayPolicy.Refusal(code: "relay_unsupported",
                message: String(localized: "relay.error.bodyRef",
                    defaultValue: "body_ref names a file on the sending machine, which c11 cannot read."))
        }
        for address in [envelope.to, envelope.from, envelope.replyTo].compactMap({ $0 }) {
            if Self.carriesHost(address, names: machines.union([originHost])) {
                throw C11RelayPolicy.Refusal(code: "relay_host_prefix",
                    message: String(format: String(localized: "relay.error.hostPrefix",
                        defaultValue: "'%@' carries a machine name. A mail address is the panel's mailbox.address or id:<uuid>; the host is shown as a badge, never written into an address."),
                        address))
            }
        }
        // C11H-360: no relayed mail speaks as c11 itself or the operator.
        for address in [envelope.from, envelope.replyTo].compactMap({ $0 }) where C11RelayPolicy.isReservedIdentity(address) {
            throw C11RelayPolicy.identityReservedRefusal(address)
        }
        // C11H-176 part B: relayed mail is from the caller, as the CLI writes
        // it: its sender claim names the caller, and `from` is the caller's
        // mailbox.address, else id:<uuid>. No other sender is carried.
        guard let claim = envelope.senderClaim, claim.panel == caller.panel else {
            throw C11RelayPolicy.identityRefusal
        }
        guard Self.isOwnSender(envelope.from, caller: caller.panel, address: callerAddress),
              envelope.replyTo.map({ Self.isOwnSender($0, caller: caller.panel, address: callerAddress) }) ?? true else {
            throw C11RelayPolicy.Refusal(code: "relay_sender_refused",
                message: String(localized: "relay.error.sender",
                    defaultValue: "Through the machine relay, mail is from your own panel: its mailbox.address, else id:<its UUID>."))
        }
        // C11H-360: the id is minted on this Mac, so relayed mail never takes
        // an id a local inbox already holds.
        let stamped = envelope.relayed(originHost: originHost, machine: caller.machine, id: MailboxULID.make())
        let outbox = MailboxLayout.outboxURL(state: stateURL, workspaceId: workspace)
        try fileManager.createDirectory(at: outbox, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try MailboxIO.atomicWrite(data: stamped.encode(),
                                  to: outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: stamped.id)))
        return Sent(id: stamped.id, from: stamped.from)
    }

    static func isOwnSender(_ from: String, caller: UUID, address: String?) -> Bool {
        if from.lowercased() == "id:" + caller.uuidString.lowercased() { return true }
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return false }
        return from == address
    }

    /// `name/...` or `name:...` for a known machine or host name. `id:` and
    /// the matcher's own qualifiers are never machine names.
    static func carriesHost(_ address: String, names: Set<String>) -> Bool {
        let lowered = address.lowercased()
        return names.contains { name in
            let host = name.lowercased()
            guard !host.isEmpty, !["id", "panel", "role", "tab", "surface"].contains(host) else { return false }
            return lowered.hasPrefix(host + "/") || lowered.hasPrefix(host + ":")
        }
    }

    /// Unread envelopes of the caller's own inbox, oldest first, not claimed.
    func peek(caller: C11RelayPolicy.VerifiedCaller, panel requested: Any?) throws -> [[String: String]] {
        try requireOwnInbox(caller, requested)
        var messages: [[String: String]] = []
        var bytes = 0
        for entry in pending(caller) {
            guard messages.count < Self.maxPeekMessages else { break }
            // C11H-97 (T-24): an envelope that cannot be read is skipped and
            // logged, never a stop: one bad oldest entry must not hide every
            // later mail on every peek.
            guard let data = try? Data(contentsOf: entry) else {
                C11RelayLog.event("peek-skipped \(entry.lastPathComponent) reason=unreadable panel=\(caller.panel.uuidString)")
                continue
            }
            guard bytes + data.count <= Self.maxPeekBytes else {
                // The byte budget: later envelopes wait for the next peek. One
                // envelope alone over the budget would block forever, so skip it.
                if messages.isEmpty {
                    C11RelayLog.event("peek-skipped \(entry.lastPathComponent) reason=too_large bytes=\(data.count) panel=\(caller.panel.uuidString)")
                    continue
                }
                break
            }
            bytes += data.count
            messages.append(["id": entry.lastPathComponent, "envelope": String(decoding: data, as: UTF8.self)])
        }
        return messages
    }

    /// Claims the named envelopes from the caller's own inbox (moves them to
    /// `_read/`) and records their delivery. Unknown or already claimed ids
    /// are skipped. Returns how many were claimed.
    func ack(caller: C11RelayPolicy.VerifiedCaller, panel requested: Any?, ids raw: Any?) throws -> Int {
        try requireOwnInbox(caller, requested)
        guard let ids = raw as? [String], ids.count <= Self.maxPeekMessages else {
            throw C11RelayPolicy.Refusal(code: "invalid_params", message: "ids must be a list of envelope names")
        }
        let wanted = Set(ids)
        var claimed: [MailboxDrain.ClaimedMessage] = []
        for entry in pending(caller) where wanted.contains(entry.lastPathComponent) {
            let data = try? Data(contentsOf: entry)
            guard let moved = MailboxDrain.claim(entry, fileManager: fileManager) else { continue }
            let envelope = data.flatMap { try? MailboxEnvelope.validate(data: $0) }
            claimed.append(MailboxDrain.ClaimedMessage(
                id: envelope?.id ?? entry.deletingPathExtension().lastPathComponent,
                text: data.map { String(decoding: $0, as: UTF8.self) } ?? "",
                framing: .init(attributes: [], body: ""), readURL: moved, recipient: envelope?.to))
        }
        let byRoot = Dictionary(grouping: claimed) { $0.inbox.deletingLastPathComponent().path }
        for (root, messages) in byRoot {
            MailboxDeliveryReceipt(panelId: caller.panel,
                                   deliveries: messages.map { .init(id: $0.id, recipient: $0.recipient ?? "") })
                .writeAll(mailboxesRoot: URL(fileURLWithPath: root, isDirectory: true))
        }
        return claimed.count
    }

    private func requireOwnInbox(_ caller: C11RelayPolicy.VerifiedCaller, _ requested: Any?) throws {
        guard let requested, !(requested is NSNull) else { return }
        guard let value = requested as? String, UUID(uuidString: value) == caller.panel else {
            throw C11RelayPolicy.Refusal(code: "relay_not_allowed",
                message: String(localized: "relay.error.otherInbox",
                    defaultValue: "Through the machine relay a panel reads only its own inbox."))
        }
    }

    private func pending(_ caller: C11RelayPolicy.VerifiedCaller) -> [URL] {
        let root = stateURL.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
        let inboxes = MailboxDrain.panelInboxURLs(workspacesRoot: root, preferredWorkspaceId: caller.workspace,
                                                  scanWhenOwnerUnknown: true, panelId: caller.panel,
                                                  fileManager: fileManager)
        return inboxes.flatMap { MailboxDrain.pendingEntries(inbox: $0, fileManager: fileManager) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
