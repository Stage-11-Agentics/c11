import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// C11H-176: the relay's authentication (protocol 2). Shared by the CLI on the
/// other machine and the app.
///
/// c11 keeps one random secret per (hc session, linked machine) on the Mac
/// (`C11RelayKeyring`). Each terminal it opens there gets its own credential,
/// derived from that secret, the panel and the terminal's creation id. The
/// credential reaches the terminal through a one-time pickup document holding
/// it masked by a pad, with only the pad in the launch environment: hc saves a
/// terminal's launch env in plaintext (`restart_env`), so the credential itself
/// is never put there. Every request carries an HMAC under the credential and
/// a nonce c11 issued in its heartbeat; every `done` reply carries an HMAC
/// back. A same-user process on that machine that reads a live c11
/// terminal's environment, or types into one through hc, can still act as
/// that terminal: stock hc gives that user every terminal there (docs/c11-relay.md).
enum C11RelayAuth {
    /// The terminal's credential, exported by the pickup. Its name avoids
    /// KEY, SECRET and TOKEN: Codex drops variables whose names hold them
    /// from the tools' environment, and the relay `c11` runs as a tool.
    static let credentialVariable = "C11_RELAY_AUTH"
    /// `<link id>:<creation>:<pad>` in the launch env; unset by the pickup.
    static let pickupVariable = "C11_RELAY_PICKUP"
    /// The relay kit's protocol, from its manifest. c11 delivers a credential
    /// only to a kit that speaks protocol 2.
    static let protocolVariable = "C11_RELAY_PROTOCOL"
    static let pickupPrefix = "c11h.relay.k."

    /// hc names a document with at most 32 of a-z, 0-9, `-`, `_` and `.`, so
    /// the name carries the creation id's first 16 hex digits; the document
    /// itself names the whole creation id, which the pickup checks.
    static func pickupName(creation: UUID) -> String {
        pickupPrefix + String(creation.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
    }

    /// A live request must carry a nonce c11 issued this recently.
    static let nonceLifetimeMilliseconds: Int64 = 64_000
    /// Request ids are remembered at least this long, so a copy is refused
    /// for as long as its nonce could still be accepted.
    static let replayWindowMilliseconds: Int64 = 2 * nonceLifetimeMilliseconds
    /// A spooled record older than this (by c11's clock) is dropped.
    static let spoolMaxAgeMilliseconds: Int64 = 24 * 60 * 60 * 1000
    /// c11 deletes a pickup document the terminal never claimed after this long.
    static let pickupLingerSeconds: TimeInterval = 60

    // MARK: Refusal codes

    static let authMissingCode = "relay_auth_missing"
    static let authRefusedCode = "relay_auth_refused"
    static let staleCode = "relay_stale"
    static let replayCode = "relay_replay"
    static let kitOutdatedCode = "relay_kit_outdated"

    // MARK: Secrets

    /// One machine's link secret: a public id and 32 random bytes.
    struct LinkSecret: Equatable, Sendable {
        let id: String
        let key: Data

        init?(id: String, key: Data) {
            guard C11RelayAuth.isLinkID(id), key.count == 32 else { return nil }
            self.id = id
            self.key = key
        }

        static func make() -> LinkSecret? {
            guard let id = C11RelayAuth.randomBytes(8), let key = C11RelayAuth.randomBytes(32) else { return nil }
            return LinkSecret(id: C11RelayAuth.hex(id), key: key)
        }
    }

    static func isLinkID(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { isLowerHex($0) }
    }

    /// Bytes from the system CSPRNG, or nil if it fails (nothing is made from a failed read).
    static func randomBytes(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
        #else
        // Linux (the relay CLI): Swift's system generator is the kernel CSPRNG (getrandom).
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = generator.next() }
        #endif
        return Data(bytes)
    }

    /// The credential of one terminal: the panel and its creation, under the
    /// session's link to that machine. Derived on demand, never stored.
    static func terminalKey(link: LinkSecret, session: String, machine: String, panel: UUID, creation: UUID) -> Data {
        code(key: link.key, label: "c11h-relay-2 term",
             fields: [session, machine, panel.uuidString.lowercased(), creation.uuidString.lowercased()])
    }

    // MARK: MACs

    /// Fields joined by a 4-byte big-endian length each, so no field can run
    /// into the next and no JSON canonical form is needed.
    static func encode(_ fields: [String]) -> Data {
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }

    static func code(key: Data, label: String, fields: [String]) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: encode([label] + fields), using: SymmetricKey(data: key)))
    }

    static func mac(key: Data, label: String, fields: [String]) -> String {
        hex(code(key: key, label: label, fields: fields))
    }

    /// Constant time (CryptoKit's comparison).
    static func isValid(mac: String, key: Data, label: String, fields: [String]) -> Bool {
        guard let given = data(hex: mac), given.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: encode([label] + fields),
                                                      using: SymmetricKey(data: key))
    }

    static let requestLabel = "c11h-relay-2 request"
    static let replyLabel = "c11h-relay-2 reply"
    static let refusalLabel = "c11h-relay-2 refusal"

    static func refusalMAC(requestID: String, code: String, message: String, key: Data) -> String {
        mac(key: key, label: refusalLabel, fields: [requestID, code, message])
    }

    static func isValidRefusal(_ mac: String, requestID: String, code: String, message: String, key: Data) -> Bool {
        isValid(mac: mac, key: key, label: refusalLabel, fields: [requestID, code, message])
    }

    // MARK: Refusal texts

    /// What the CLI shows for a refusal c11 did not sign. Only c11's
    /// refusals before it knows the caller (identity, credential, an older
    /// kit, a pending inventory) come unsigned, and for those the CLI shows
    /// its own text, never the slot's: anyone who can write the slot could
    /// otherwise put words in front of the agent. Any other unsigned refusal
    /// is reported as `relay_refused` with the generic text.
    static func unsignedRefusal(code: String) -> (code: String, message: String) {
        if let text = refusalText(code) { return (code, text) }
        return ("relay_refused", String(localized: "relay.error.unsignedRefusal",
            defaultValue: "c11 refused this call, but the refusal was not signed by c11, so its text is not shown. Nothing ran."))
    }

    static func refusalText(_ code: String) -> String? {
        switch code {
        case "relay_identity_refused":
            return String(localized: "relay.error.identity",
                defaultValue: "This terminal's C11_PANEL_ID and HC_TERMINAL_ID do not name a c11 panel on this machine.")
        case authMissingCode:
            return String(localized: "relay.error.authMissing",
                defaultValue: "This terminal has no relay credential: it was opened before this version of c11, or its credential pickup failed. Open a new terminal on this machine.")
        case authRefusedCode:
            return String(localized: "relay.error.authRefused",
                defaultValue: "This terminal's relay credential does not check out: it belongs to an earlier terminal or an earlier link to this machine, or the request was changed. Open a new terminal on this machine.")
        case kitOutdatedCode:
            return String(localized: "relay.error.kitOutdated",
                defaultValue: "The relay on this machine is from an older c11. The operator reinstalls it from the current c11 (c11 machine link --update, or the relay install script), then opens a new terminal here.")
        case "relay_inventory_pending":
            return String(localized: "relay.error.inventoryPending",
                defaultValue: "c11's terminal inventory is not ready. Retry.")
        default:
            return nil
        }
    }

    static func requestFields(_ request: C11Relay.Request) -> [String] {
        [String(C11Relay.protocolVersion), request.id, String(request.at), request.nonce, request.panel,
         request.workspace ?? "", request.term, request.creation, request.linkID, request.framing.rawValue,
         String(request.timeoutMilliseconds), request.line, request.mode.rawValue]
    }

    static func sign(_ request: C11Relay.Request, key: Data) -> String {
        mac(key: key, label: requestLabel, fields: requestFields(request))
    }

    static func isSigned(_ request: C11Relay.Request, key: Data) -> Bool {
        isValid(mac: request.mac, key: key, label: requestLabel, fields: requestFields(request))
    }

    static func replyMAC(requestID: String, response: String, key: Data) -> String {
        mac(key: key, label: replyLabel, fields: [requestID, response])
    }

    static func isValidReply(_ mac: String, requestID: String, response: String, key: Data) -> Bool {
        isValid(mac: mac, key: key, label: replyLabel, fields: [requestID, response])
    }

    // MARK: The terminal's credential

    /// `2:<link id>:<creation>:<credential hex>`, as the pickup exports it.
    struct Credential: Equatable, Sendable {
        let linkID: String
        let creation: UUID
        let key: Data

        init(linkID: String, creation: UUID, key: Data) {
            self.linkID = linkID; self.creation = creation; self.key = key
        }

        init?(_ raw: String?) {
            guard let raw else { return nil }
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "2", C11RelayAuth.isLinkID(String(parts[1])),
                  let creation = UUID(uuidString: String(parts[2])),
                  let key = C11RelayAuth.data(hex: String(parts[3])), key.count == 32 else { return nil }
            self.init(linkID: String(parts[1]), creation: creation, key: key)
        }

        var value: String { "2:\(linkID):\(creation.uuidString.lowercased()):\(C11RelayAuth.hex(key))" }
    }

    // MARK: Pickup

    /// `<link id>:<creation>:<pad hex>`, the launch env's half of a pickup.
    struct Pickup: Equatable, Sendable {
        let linkID: String
        let creation: UUID
        let pad: Data

        init(linkID: String, creation: UUID, pad: Data) {
            self.linkID = linkID; self.creation = creation; self.pad = pad
        }

        init?(_ raw: String?) {
            guard let raw else { return nil }
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, C11RelayAuth.isLinkID(String(parts[0])),
                  let creation = UUID(uuidString: String(parts[1])),
                  let pad = C11RelayAuth.data(hex: String(parts[2])), pad.count == 32 else { return nil }
            self.init(linkID: String(parts[0]), creation: creation, pad: pad)
        }

        var value: String { "\(linkID):\(creation.uuidString.lowercased()):\(C11RelayAuth.hex(pad))" }
    }

    static func xor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    /// The pickup document: the credential masked by the pad.
    static func pickupDocument(linkID: String, creation: UUID, masked: Data) -> [String: Any] {
        ["p": C11Relay.protocolVersion, "lk": linkID, "creation": creation.uuidString.lowercased(), "m": hex(masked)]
    }

    static func maskedValue(_ document: Any?) -> String? {
        (document as? [String: Any])?["m"] as? String
    }

    /// The credential from a pickup document and the env's pad, when both
    /// name the same link and creation.
    static func credential(document: Any?, pickup: Pickup) -> Credential? {
        guard let object = document as? [String: Any], (object["p"] as? NSNumber)?.intValue == C11Relay.protocolVersion,
              object["lk"] as? String == pickup.linkID,
              (object["creation"] as? String).flatMap(UUID.init(uuidString:)) == pickup.creation,
              let masked = (object["m"] as? String).flatMap(data(hex:)), masked.count == 32 else { return nil }
        return Credential(linkID: pickup.linkID, creation: pickup.creation, key: xor(masked, pickup.pad))
    }

    /// The CLI's `relay-pickup`, run once by the remote terminal's launch line
    /// before the login shell: reads the pickup document, deletes it by
    /// compare-and-set, and returns the shell line that exports the
    /// credential. Nil on any failure (no pickup, no document, a conflict, a
    /// core that does not answer): the terminal then opens without one.
    static func pickUp(environment: [String: String], store: C11RelayDocStore) -> String? {
        guard let pickup = Pickup(environment[pickupVariable]) else { return nil }
        let name = pickupName(creation: pickup.creation)
        /// One retry of a call the core did not answer (a loaded machine); a
        /// conflict or a missing document is an answer and is not retried.
        func twice<T>(_ call: () throws -> T) -> T? {
            for attempt in 0..<2 {
                do { return try call() }
                catch C11RelayStoreError.unavailable where attempt == 0 { continue }
                catch { return nil }
            }
            return nil
        }
        guard let (document, version) = twice({ try store.get(name) }),
              let credential = credential(document: document, pickup: pickup) else { return nil }
        // The delete, once more if the core did not answer. A conflict after
        // an unanswered try may be that try having landed: the document gone
        // means it did.
        var deleted = false
        for attempt in 0..<2 where !deleted {
            do {
                _ = try store.set(name, value: nil, version: version)
                deleted = true
            } catch C11RelayStoreError.unavailable where attempt == 0 {
                continue
            } catch C11RelayStoreError.conflict where attempt == 1 {
                deleted = (try? store.get(name))?.value == nil
                break
            } catch {
                break
            }
        }
        guard deleted else { return nil }
        return "export \(credentialVariable)='\(credential.value)'"
    }

    // MARK: Hex

    static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data { out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func data(hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0, bytes.allSatisfy({ isLowerHex($0) }) else { return nil }
        var out = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            out.append(nibble(bytes[index]) << 4 | nibble(bytes[index + 1]))
            index += 2
        }
        return out
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }

    private static func nibble(_ byte: UInt8) -> UInt8 {
        byte <= 0x39 ? byte - 0x30 : byte - 0x61 + 10
    }
}
