import Foundation

/// C11-257 Lane C: consuming an inbox at an agent's turn boundary.
///
/// Every consumer (`c11 mailbox recv --drain`, a harness hook drain, the stdin
/// push) claims an envelope by renaming `<inbox>/<ULID>.msg` into
/// `<inbox>/_read/<ULID>.msg` *before* it prints or types the message. The
/// rename is the lock: when two consumers race, exactly one rename succeeds
/// and the other finds the file gone and skips it. `_read/` is history for the
/// messages page, never a source for re-delivery; `recv` reads only the inbox
/// root.
///
/// Pure file I/O plus pure formatting, shared by the app and the CLI so the
/// claim semantics and the hook wire shapes are covered by `c11LogicTests`.
enum MailboxDrain {

    static let readDirectoryName = "_read"

    static func readURL(inbox: URL) -> URL {
        inbox.appendingPathComponent(readDirectoryName, isDirectory: true)
    }

    /// Envelope files waiting in the inbox root, oldest first (ULID order).
    static func pendingEntries(
        inbox: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .filter { $0.pathExtension == MailboxLayout.envelopeExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The pinned C5 inbox of one tab: `<mailboxes>/<tab-uuid-lowercased>/`.
    /// The hook drain computes it from `C11_TAB_ID` alone, so a turn boundary
    /// never waits on the socket to learn which inbox is its own.
    static func tabInboxURL(mailboxesRoot: URL, tabId: UUID) -> URL {
        mailboxesRoot.appendingPathComponent(tabId.uuidString.lowercased(), isDirectory: true)
    }

    /// Every existing inbox of one tab, from the filesystem alone.
    ///
    /// The process's `C11_WORKSPACE_ID` goes stale when the tab is moved to
    /// another workspace, while the dispatcher keeps delivering into the tab's
    /// *current* workspace. Tab UUIDs are unique, so any
    /// `workspaces/*/mailboxes/<tab-uuid>/` is this tab's. The preferred
    /// (environment) workspace comes first; the others come from a scan of
    /// every workspace directory. A machine can hold thousands of those (11k
    /// measured: ~40 ms warm, ~450 ms cold), so with a `scanCache` file the
    /// scan runs at most once per `scanInterval` and its result is reused in
    /// between. A moved tab's turn-boundary drain therefore finds its new
    /// inbox within one interval; the stdin push reaches it meanwhile, since
    /// the app knows where the tab lives.
    static func tabInboxURLs(
        workspacesRoot: URL,
        preferredWorkspaceId: UUID?,
        tabId: UUID,
        scanCache: URL?,
        scanInterval: TimeInterval = 300,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        func inbox(workspace: String) -> URL {
            workspacesRoot
                .appendingPathComponent(workspace, isDirectory: true)
                .appendingPathComponent(MailboxLayout.mailboxesDirectoryName, isDirectory: true)
                .appendingPathComponent(tabId.uuidString.lowercased(), isDirectory: true)
        }

        var result: [URL] = []
        if let preferredWorkspaceId {
            let preferred = inbox(workspace: preferredWorkspaceId.uuidString)
            if isDirectory(preferred) { result.append(preferred) }
        }

        var found: [URL]
        if let scanCache,
           let modified = (try? fileManager.attributesOfItem(atPath: scanCache.path))?[.modificationDate] as? Date,
           now.timeIntervalSince(modified) < scanInterval,
           let text = try? String(contentsOf: scanCache, encoding: .utf8) {
            found = text.split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        } else {
            let workspaces = (try? fileManager.contentsOfDirectory(atPath: workspacesRoot.path)) ?? []
            found = workspaces.map { inbox(workspace: $0) }.filter(isDirectory)
            if let scanCache {
                try? fileManager.createDirectory(
                    at: scanCache.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try? found.map(\.path).joined(separator: "\n")
                    .write(to: scanCache, atomically: true, encoding: .utf8)
            }
        }
        for url in found where isDirectory(url) && !result.contains(where: { $0.path == url.path }) {
            result.append(url)
        }
        return result
    }

    /// The workspace UUID an inbox directory lives under
    /// (`workspaces/<uuid>/mailboxes/<inbox>/`).
    static func workspaceId(ofInbox inbox: URL) -> UUID? {
        UUID(uuidString: inbox.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)
    }

    /// Claims one inbox entry by renaming it into `_read/`. Returns the claimed
    /// file's new URL, or nil when another consumer already took it (or it
    /// could not be moved). `rename(2)` is atomic within the inbox's volume,
    /// so at most one caller ever gets a non-nil result for a given entry.
    static func claim(
        _ entry: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let readDir = readURL(inbox: entry.deletingLastPathComponent())
        try? fileManager.createDirectory(
            at: readDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = readDir.appendingPathComponent(entry.lastPathComponent)
        guard rename(entry.path, target.path) == 0 else { return nil }
        return target
    }

    /// Returns a claimed entry to the inbox root, for a consumer whose
    /// injection failed after the claim (C3-order).
    @discardableResult
    static func unclaim(_ claimed: URL) -> Bool {
        let inbox = claimed.deletingLastPathComponent().deletingLastPathComponent()
        let target = inbox.appendingPathComponent(claimed.lastPathComponent)
        return rename(claimed.path, target.path) == 0
    }

    struct ClaimedMessage {
        let id: String
        let text: String
        let framed: String
        let readURL: URL
        /// The inbox the envelope was claimed from.
        var inbox: URL { readURL.deletingLastPathComponent().deletingLastPathComponent() }
        /// The envelope's `to`: the address the sender used, which the
        /// dispatcher resolved to this inbox. Nil for a malformed file.
        let recipient: String?
    }

    /// Claims pending entries strictly oldest first (ULID order), handing each
    /// one to `accept` right after its claim.
    ///
    /// - Budget: stops at the first entry whose framed text would push the
    ///   total past `budget` characters, so newer mail never overtakes older
    ///   mail. The first message is always taken, so one large message can
    ///   never stall an inbox.
    /// - `accept` returning false (the caller could not hand the message over)
    ///   un-claims that entry and stops; nothing after it was claimed (C3).
    /// - An entry another consumer took first is skipped.
    ///
    /// Returns what was claimed and accepted, and how many entries were left in
    /// the inbox root untouched.
    static func claimPending(
        inbox: URL,
        budget: Int = Int.max,
        fileManager: FileManager = .default,
        accept: (ClaimedMessage) -> Bool = { _ in true }
    ) -> (claimed: [ClaimedMessage], remaining: Int) {
        claimPending(inboxes: [inbox], budget: budget, fileManager: fileManager, accept: accept)
    }

    /// `claimPending` across several inboxes of the same tab, merged into one
    /// ULID order.
    static func claimPending(
        inboxes: [URL],
        budget: Int = Int.max,
        fileManager: FileManager = .default,
        accept: (ClaimedMessage) -> Bool = { _ in true }
    ) -> (claimed: [ClaimedMessage], remaining: Int) {
        let entries = inboxes
            .flatMap { pendingEntries(inbox: $0, fileManager: fileManager) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var claimed: [ClaimedMessage] = []
        var used = 0
        for (index, entry) in entries.enumerated() {
            // Peek before claiming so an over-budget message stays in the inbox
            // rather than being claimed and then handed back. Unreadable means
            // another consumer renamed it away.
            guard let peeked = try? Data(contentsOf: entry) else { continue }
            let preview = framedBlock(data: peeked, fallbackId: idFromFilename(entry))
            if !claimed.isEmpty, used + preview.count > budget {
                return (claimed, entries.count - index)
            }
            guard let readURL = claim(entry, fileManager: fileManager) else { continue }
            let data = (try? Data(contentsOf: readURL)) ?? peeked
            let message = ClaimedMessage(
                id: idFromFilename(entry),
                text: String(data: data, encoding: .utf8) ?? "",
                framed: framedBlock(data: data, fallbackId: idFromFilename(entry)),
                readURL: readURL,
                recipient: (try? MailboxEnvelope.validate(data: data))?.to
            )
            guard accept(message) else {
                unclaim(readURL)
                return (claimed, entries.count - index)
            }
            claimed.append(message)
            used += message.framed.count
        }
        return (claimed, 0)
    }

    static func idFromFilename(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Frames an inbox file as a `<c11-msg>` block. A file that fails envelope
    /// validation is still delivered: its raw text becomes the escaped body so
    /// the agent sees it instead of it vanishing.
    static func framedBlock(data: Data, fallbackId: String) -> String {
        if let envelope = try? MailboxEnvelope.validate(data: data) {
            return MailboxFraming.framedBlock(envelope: envelope)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return "\n<c11-msg id=\"\(MailboxFraming.xmlEscapeAttribute(fallbackId))\" malformed=\"true\">\n"
            + MailboxFraming.xmlEscapeBody(raw)
            + "\n</c11-msg>\n"
    }
}

// MARK: - Hook output

/// The harnesses whose hook JSON `c11 mailbox recv --hook-format` speaks.
enum MailboxHookFormat: String, CaseIterable {
    case claude
    case codex
    case grok
}

enum MailboxHookEvent: String {
    case promptSubmit = "prompt-submit"
    case stop

    /// Accepts the CLI spelling (`prompt-submit`, `stop`) and every harness's
    /// event name: Claude/Codex `UserPromptSubmit`/`Stop` in `hook_event_name`,
    /// Grok's snake `user_prompt_submit`/`stop` in `hookEventName`.
    init?(name: String) {
        switch name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "promptsubmit", "userpromptsubmit": self = .promptSubmit
        case "stop": self = .stop
        default: return nil
        }
    }
}

/// What the drain needs from a hook's stdin JSON.
struct MailboxHookInput: Equatable {
    var event: MailboxHookEvent?
    /// Claude/Codex `stop_hook_active`, Grok `stopHookActive`: this stop is
    /// already a continuation forced by a Stop hook.
    var stopHookActive: Bool
    /// Grok's Stop `reason`; only exactly `end_turn` is a real turn end (a
    /// second Stop fires at session teardown).
    var stopReason: String?

    init(event: MailboxHookEvent? = nil, stopHookActive: Bool = false, stopReason: String? = nil) {
        self.event = event
        self.stopHookActive = stopHookActive
        self.stopReason = stopReason
    }

    static func parse(_ data: Data) -> MailboxHookInput {
        guard !data.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return MailboxHookInput()
        }
        var input = MailboxHookInput()
        for key in ["hook_event_name", "hookEventName"] {
            if let name = object[key] as? String, let event = MailboxHookEvent(name: name) {
                input.event = event
                break
            }
        }
        for key in ["stop_hook_active", "stopHookActive"] {
            if let active = object[key] as? Bool, active {
                input.stopHookActive = true
            }
        }
        input.stopReason = object["reason"] as? String
        return input
    }
}

enum MailboxHookOutput {

    /// Upper bound on the framed text one hook invocation delivers. Claude,
    /// Codex and Grok each clip or spill hook context near 10,000 characters;
    /// staying under that keeps every delivered message whole. Anything left
    /// over waits for the next boundary and is announced in the header.
    static let contextBudget = 8_000

    /// No claim starts after this many seconds of the hook process's life.
    /// Claude and Codex kill a hook at 10 s and then discard its stdout; mail
    /// claimed that late could land in `_read/` without reaching the agent.
    /// What follows a claim is one stdout write and one receipt file: no
    /// socket I/O, so it cannot run into the kill.
    static let claimDeadlineSeconds: TimeInterval = 6

    static func mayClaim(processElapsedSeconds: TimeInterval?) -> Bool {
        (processElapsedSeconds ?? 0) < claimDeadlineSeconds
    }

    /// Whether this hook invocation may consume mail at all.
    ///
    /// - Stop drains only on a genuine turn end that is not already a Stop-hook
    ///   continuation, so a turn that delivered mail always ends at its next
    ///   Stop: the agent can never be trapped in a loop by the mailbox.
    /// - Grok discards an allowing UserPromptSubmit hook's output, so Grok
    ///   drains at Stop only; its prompt-submit leaves the mail in the inbox.
    static func shouldDrain(format: MailboxHookFormat, input: MailboxHookInput) -> Bool {
        switch input.event {
        case .promptSubmit:
            return format != .grok
        case .stop:
            if input.stopHookActive { return false }
            // Grok also fires Stop at session teardown; only `end_turn` is a
            // real turn end, and a missing or unknown reason is not one.
            if format == .grok { return input.stopReason == "end_turn" }
            return true
        case nil:
            return false
        }
    }

    /// The text the agent reads: a one-line header, then the framed messages.
    static func context(framedBlocks: [String], remaining: Int) -> String {
        let count = framedBlocks.count
        var header = count == 1
            ? "c11 mailbox: 1 new message for this tab, delivered at a turn boundary."
            : "c11 mailbox: \(count) new messages for this tab, delivered at a turn boundary."
        if remaining > 0 {
            header += " \(remaining) more waiting: run `c11 mailbox recv` to read them."
        }
        header += " Reply with `c11 mailbox send --to <from> --body ...` when a reply is wanted."
        return header + "\n" + framedBlocks.joined()
    }

    /// Hook stdout JSON for one harness and event. Prompt-submit adds the
    /// messages as context to the turn that is starting; Stop blocks the stop
    /// with the messages as the reason, so the agent takes one more turn.
    /// Claude, Codex and Grok share these two shapes.
    static func payload(event: MailboxHookEvent, context: String) -> [String: Any] {
        switch event {
        case .promptSubmit:
            return [
                "hookSpecificOutput": [
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": context
                ]
            ]
        case .stop:
            return ["decision": "block", "reason": context]
        }
    }

    static func render(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Delivery receipts

/// A drain's record of what it delivered, handed to the app through the
/// filesystem: `<mailboxes>/_receipts/<ULID>.receipt`. The CLI writes one per
/// drained batch right after the claim (temp file + rename, no socket), and
/// the app turns each delivery into a `mailbox.delivered` event with
/// `via: "drain"` and deletes the receipt (`MailboxReceiptRecorder`). No
/// connection means nothing to authorize or authenticate, and a paused, quit
/// or crashed app records the delivery when it next runs.
///
/// Same trust level as `_outbox/`: any local process of the user can write
/// one, so content is validated and size-limited, and anything malformed is
/// moved to `_receipts/_rejected/`.
struct MailboxDeliveryReceipt: Equatable {

    struct Delivery: Equatable {
        let id: String
        let recipient: String
    }

    static let version = 1
    static let directoryName = "_receipts"
    static let rejectedDirectoryName = "_rejected"
    static let fileExtension = "receipt"
    static let maxBytes = 64 * 1024
    static let maxDeliveries = 512
    static let allowedKeys: Set<String> = ["version", "via", "tab_id", "deliveries", "ts"]

    /// The recipient tab, when the drain knows it (a hook always does; `recv
    /// --tab <name>` may not). Never the caller's tab by default.
    let tabId: UUID?
    let deliveries: [Delivery]
    let via: String
    let ts: String

    init(tabId: UUID?, deliveries: [Delivery], via: String = "drain", ts: String = MailboxEnvelope.currentRFC3339()) {
        self.tabId = tabId
        self.deliveries = deliveries
        self.via = via
        self.ts = ts
    }

    static func spoolURL(mailboxesRoot: URL) -> URL {
        mailboxesRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    func encode() -> Data? {
        var object: [String: Any] = [
            "version": Self.version,
            "via": via,
            "ts": ts,
            "deliveries": deliveries.map { ["id": $0.id, "recipient": $0.recipient] }
        ]
        if let tabId { object["tab_id"] = tabId.uuidString }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Strict parse: known keys only, version 1, `via` "drain", 1...512
    /// deliveries with ULID ids and non-empty recipients of at most 256 bytes.
    static func decode(_ data: Data) -> MailboxDeliveryReceipt? {
        guard data.count <= maxBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: allowedKeys),
              (object["version"] as? NSNumber)?.intValue == version,
              let via = object["via"] as? String, via == "drain",
              let ts = object["ts"] as? String, !ts.isEmpty, ts.utf8.count <= 64,
              let rawDeliveries = object["deliveries"] as? [Any],
              (1...maxDeliveries).contains(rawDeliveries.count) else { return nil }
        var tabId: UUID?
        if let rawTab = object["tab_id"] {
            guard let string = rawTab as? String, let uuid = UUID(uuidString: string) else { return nil }
            tabId = uuid
        }
        var deliveries: [Delivery] = []
        for raw in rawDeliveries {
            guard let entry = raw as? [String: Any],
                  Set(entry.keys).isSubset(of: ["id", "recipient"]),
                  let id = entry["id"] as? String,
                  id.range(of: MailboxEnvelope.ulidPattern, options: .regularExpression) != nil,
                  let recipient = entry["recipient"] as? String,
                  !recipient.isEmpty, recipient.utf8.count <= MailboxEnvelope.maxStringFieldBytes else { return nil }
            deliveries.append(Delivery(id: id, recipient: recipient))
        }
        return MailboxDeliveryReceipt(tabId: tabId, deliveries: deliveries, via: via, ts: ts)
    }

    /// Writes the receipt atomically into the workspace's spool and returns
    /// its URL, or nil on failure (the mail was already delivered; only the
    /// event is lost).
    @discardableResult
    func write(mailboxesRoot: URL, fileManager: FileManager = .default) -> URL? {
        guard !deliveries.isEmpty, let data = encode() else { return nil }
        let spool = Self.spoolURL(mailboxesRoot: mailboxesRoot)
        try? fileManager.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = MailboxULID.make()
        let temp = spool.appendingPathComponent(".\(name).tmp")
        let target = spool.appendingPathComponent("\(name).\(Self.fileExtension)")
        guard (try? data.write(to: temp)) != nil else { return nil }
        guard rename(temp.path, target.path) == 0 else {
            try? fileManager.removeItem(at: temp)
            return nil
        }
        return target
    }
}
