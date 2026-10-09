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
    static func panelInboxURL(mailboxesRoot: URL, panelId: UUID) -> URL {
        mailboxesRoot.appendingPathComponent(panelId.uuidString.lowercased(), isDirectory: true)
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
    static func panelInboxURLs(
        workspacesRoot: URL,
        preferredWorkspaceId: UUID?,
        panelId: UUID,
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
                .appendingPathComponent(panelId.uuidString.lowercased(), isDirectory: true)
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
        let target = readDir.appendingPathComponent(claimedName(for: entry))
        guard rename(entry.path, target.path) == 0 else { return nil }
        return target
    }

    /// The name an entry gets under `_read/`. Envelopes the dispatcher wrote
    /// are named by their ULID and keep it. A file dropped into an inbox by
    /// hand (`0note.msg`) gets a freshly minted ULID, so every delivered
    /// message has a globally unique id: the id it is recorded under, and the
    /// name its body keeps under `_read/`.
    static func claimedName(for entry: URL) -> String {
        let stem = idFromFilename(entry)
        if isULID(stem) { return entry.lastPathComponent }
        return MailboxLayout.envelopeFilename(id: MailboxULID.make())
    }

    static func isULID(_ value: String) -> Bool {
        value.range(of: MailboxEnvelope.ulidPattern, options: .regularExpression) != nil
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
            let id = idFromFilename(readURL)
            let message = ClaimedMessage(
                id: id,
                text: String(data: data, encoding: .utf8) ?? "",
                framed: framedBlock(data: data, fallbackId: id),
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

// MARK: - CLI seam (C11-364, C11-369)
//
// `c11 mailbox send` / `recv` call these before any outbox write or inbox
// claim. c11LogicTests call the same functions, so a guard that lets a
// message vanish fails here.

/// Parsed `c11 mailbox send` arguments. One trailing positional is the body
/// when `--body` is absent, the same shape as `c11 send`.
enum MailboxSendArguments {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownFlag(String)
        case flagNeedsValue(String)
        case flagTakesNoValue(String)
        case duplicateFlag(String)
        case bodyConflict
        case extraArgument
        case emptyBody

        var description: String {
            switch self {
            case .unknownFlag(let name):
                return String(
                    localized: "mailbox.cli.error.unknown-flag",
                    defaultValue: "Unknown flag '%@'."
                ).replacingOccurrences(of: "%@", with: name)
            case .flagNeedsValue(let name):
                return String(
                    localized: "mailbox.cli.error.flag-needs-value",
                    defaultValue: "Flag '%@' requires a value."
                ).replacingOccurrences(of: "%@", with: name)
            case .flagTakesNoValue(let name):
                return String(
                    localized: "mailbox.cli.error.flag-no-value",
                    defaultValue: "Flag '%@' does not take a value."
                ).replacingOccurrences(of: "%@", with: name)
            case .duplicateFlag(let name):
                return String(
                    localized: "mailbox.cli.error.duplicate-flag",
                    defaultValue: "Flag '%@' was passed more than once."
                ).replacingOccurrences(of: "%@", with: name)
            case .bodyConflict:
                return String(
                    localized: "mailbox.cli.error.body-conflict",
                    defaultValue: "Pass the message as --body or as one trailing argument, not both."
                )
            case .extraArgument:
                return String(
                    localized: "mailbox.cli.error.extra-argument",
                    defaultValue: "mailbox send takes one message. Quote it, or pass --body."
                )
            case .emptyBody:
                return String(
                    localized: "mailbox.cli.error.empty-body",
                    defaultValue: "Refusing to send an empty mailbox message. Pass the text, or pass --body-ref for a file."
                )
            }
        }
    }

    struct Parsed: Equatable {
        var to: String?
        var toWorkspace: String?
        var topic: String?
        var body: String
        var bodyRef: String?
        var replyTo: String?
        var inReplyTo: String?
        var urgent: Bool
        var ttlSeconds: String?
        var from: String?
        var id: String?
        var ts: String?
        var contentType: String?
        var json: Bool
    }

    private static let valueFlags: Set<String> = [
        "--to", "--to-workspace", "--topic", "--body", "--body-ref",
        "--reply-to", "--in-reply-to", "--ttl-seconds", "--from",
        "--id", "--ts", "--content-type",
    ]
    private static let boolFlags: Set<String> = ["--urgent", "--json"]

    static func parse(_ args: [String]) throws -> Parsed {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var positionals: [String] = []
        var literal = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            if !literal, argument == "--" {
                literal = true
                index += 1
                continue
            }
            if !literal, argument.hasPrefix("--") {
                let name: String
                let inline: String?
                if let eq = argument.firstIndex(of: "=") {
                    name = String(argument[..<eq])
                    inline = String(argument[argument.index(after: eq)...])
                } else {
                    name = argument
                    inline = nil
                }
                if boolFlags.contains(name) {
                    if inline != nil { throw Failure.flagTakesNoValue(name) }
                    guard flags.insert(name).inserted else { throw Failure.duplicateFlag(name) }
                } else if valueFlags.contains(name) {
                    let value: String
                    if let inline {
                        value = inline
                    } else {
                        guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                            throw Failure.flagNeedsValue(name)
                        }
                        value = args[index + 1]
                        index += 1
                    }
                    guard values[name] == nil else { throw Failure.duplicateFlag(name) }
                    values[name] = value
                } else {
                    throw Failure.unknownFlag(name)
                }
                index += 1
                continue
            }
            positionals.append(argument)
            index += 1
        }

        if values["--body"] != nil, !positionals.isEmpty {
            throw Failure.bodyConflict
        }
        if positionals.count > 1 {
            throw Failure.extraArgument
        }
        let body = values["--body"] ?? positionals.first ?? ""
        let bodyRef = values["--body-ref"].flatMap { $0.isEmpty ? nil : $0 }
        if body.isEmpty, bodyRef == nil {
            throw Failure.emptyBody
        }
        return Parsed(
            to: values["--to"],
            toWorkspace: values["--to-workspace"],
            topic: values["--topic"],
            body: body,
            bodyRef: bodyRef,
            replyTo: values["--reply-to"],
            inReplyTo: values["--in-reply-to"],
            urgent: flags.contains("--urgent"),
            ttlSeconds: values["--ttl-seconds"],
            from: values["--from"],
            id: values["--id"],
            ts: values["--ts"],
            contentType: values["--content-type"],
            json: flags.contains("--json")
        )
    }
}

/// Parsed `c11 mailbox recv` arguments. Unknown flags are refused so a typo
/// cannot drain the inbox.
enum MailboxRecvArguments {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownFlag(String)
        case flagNeedsValue(String)
        case flagTakesNoValue(String)
        case duplicateFlag(String)
        case unexpectedArgument(String)
        case conflictingPanel

        var description: String {
            switch self {
            case .unknownFlag(let name):
                return MailboxSendArguments.Failure.unknownFlag(name).description
            case .flagNeedsValue(let name):
                return MailboxSendArguments.Failure.flagNeedsValue(name).description
            case .flagTakesNoValue(let name):
                return MailboxSendArguments.Failure.flagTakesNoValue(name).description
            case .duplicateFlag(let name):
                return MailboxSendArguments.Failure.duplicateFlag(name).description
            case .unexpectedArgument:
                return String(
                    localized: "mailbox.cli.error.recv-unexpected",
                    defaultValue: "mailbox recv does not take a trailing argument."
                )
            case .conflictingPanel:
                return String(
                    localized: "mailbox.cli.error.recv-one-panel",
                    defaultValue: "Pass only one of --panel, --tab, or --surface."
                )
            }
        }
    }

    struct Parsed: Equatable {
        var peek: Bool
        var ack: Bool
        var hookFormat: String?
        var event: String?
        var panel: String?
        /// Explicit `--drain`, or the default when `--peek` is absent.
        var drains: Bool
    }

    private static let panelFlags: Set<String> = ["--panel", "--tab", "--surface"]
    private static let valueFlags: Set<String> = ["--hook-format", "--event", "--panel", "--tab", "--surface"]
    private static let boolFlags: Set<String> = ["--drain", "--peek", "--ack"]

    static func parse(_ args: [String]) throws -> Parsed {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                throw Failure.unexpectedArgument(argument)
            }
            guard argument.hasPrefix("--") else {
                throw Failure.unexpectedArgument(argument)
            }
            let name: String
            let inline: String?
            if let eq = argument.firstIndex(of: "=") {
                name = String(argument[..<eq])
                inline = String(argument[argument.index(after: eq)...])
            } else {
                name = argument
                inline = nil
            }
            if boolFlags.contains(name) {
                if inline != nil { throw Failure.flagTakesNoValue(name) }
                guard flags.insert(name).inserted else { throw Failure.duplicateFlag(name) }
            } else if valueFlags.contains(name) {
                let value: String
                if let inline {
                    value = inline
                } else {
                    guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                        throw Failure.flagNeedsValue(name)
                    }
                    value = args[index + 1]
                    index += 1
                }
                guard values[name] == nil else { throw Failure.duplicateFlag(name) }
                values[name] = value
            } else {
                throw Failure.unknownFlag(name)
            }
            index += 1
        }
        let panelHits = panelFlags.filter { values[$0] != nil }
        if panelHits.count > 1 { throw Failure.conflictingPanel }
        let peek = flags.contains("--peek")
        return Parsed(
            peek: peek,
            ack: flags.contains("--ack"),
            hookFormat: values["--hook-format"],
            event: values["--event"],
            panel: panelFlags.compactMap { values[$0] }.first,
            drains: flags.contains("--drain") || !peek
        )
    }
}

/// Whether a drain may claim envelopes. A drain whose stdout nobody can read
/// throws and leaves the inbox untouched.
enum MailboxRecvAdmission {
    struct Refusal: Error, Equatable, CustomStringConvertible {
        var description: String {
            String(
                localized: "mailbox.cli.error.drain-unreadable",
                defaultValue: "Refusing to mark mailbox messages read because stdout is not a terminal. Run c11 mailbox recv --drain --ack"
            )
        }
    }

    static func allowsMarkRead(stdoutIsTTY: Bool, acknowledged: Bool) -> Bool {
        stdoutIsTTY || acknowledged
    }

    static func consume(
        inboxes: [URL],
        stdoutIsTTY: Bool,
        acknowledged: Bool,
        budget: Int = Int.max,
        fileManager: FileManager = .default,
        accept: (MailboxDrain.ClaimedMessage) -> Bool = { _ in true }
    ) throws -> (claimed: [MailboxDrain.ClaimedMessage], remaining: Int) {
        guard allowsMarkRead(stdoutIsTTY: stdoutIsTTY, acknowledged: acknowledged) else {
            throw Refusal()
        }
        return MailboxDrain.claimPending(
            inboxes: inboxes,
            budget: budget,
            fileManager: fileManager,
            accept: accept
        )
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
    /// - Prompt-submit never drains, for any harness: mail added to a turn the
    ///   operator started is treated as non-operator input and not acted on
    ///   (and Grok discards that output outright). It waits for the Stop.
    static func shouldDrain(format: MailboxHookFormat, input: MailboxHookInput) -> Bool {
        switch input.event {
        case .promptSubmit:
            // Never: an agent reads mail injected as prompt-submit context as
            // non-operator input and declines to act on it. Mail waits for the
            // turn's Stop, where it becomes the agent's own next turn.
            return false
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
            ? "c11 mailbox: 1 new message for this panel, delivered at a turn boundary."
            : "c11 mailbox: \(count) new messages for this panel, delivered at a turn boundary."
        if remaining > 0 {
            header += " \(remaining) more waiting: run `c11 mailbox recv` to read them."
        }
        header += " Reply with `c11 mailbox send --to <from> --body ...` when a reply is wanted."
        return header + "\n" + framedBlocks.joined()
    }

    /// Hook stdout JSON: the Stop is blocked with the messages as the reason,
    /// so the agent takes one more turn of its own. Claude, Codex and Grok
    /// share this shape. (Drains happen only at Stop; see `shouldDrain`.)
    static func payload(context: String) -> [String: Any] {
        ["decision": "block", "reason": context]
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
/// filesystem: `<mailboxes>/_receipts/<ULID>.receipt`. The CLI writes them
/// right after the claim (temp file + rename, no socket), and the app turns
/// each delivery into a `mailbox.delivered` event with `via: "drain"` and
/// deletes the receipt (`MailboxReceiptRecorder`). No connection means nothing
/// to authorize or authenticate, and a paused, quit or crashed app records the
/// delivery when it next runs.
///
/// **Ids.** A delivery's id is always a ULID, globally unique: the
/// envelope's for anything the dispatcher wrote, and for a file someone
/// dropped into an inbox by hand (`0note.msg`) the ULID it was claimed under
/// (`MailboxDrain.claimedName`), which is also its name under `_read/`. A
/// non-ULID name would only be unique within one inbox, and the recorder's
/// exactly-once checks key on the id.
///
/// **Limits.** A receipt holds at most `maxDeliveries` entries and
/// `maxBytes` bytes; `writeAll` splits a batch into as many receipts as that
/// takes, so no drain is ever too big to record.
///
/// **Validation.** Same trust level as `_outbox/`: any local process of the
/// user can write one. A file that is not a receipt at all (unreadable, over
/// `maxBytes`, not JSON, wrong version or `via`) is moved to
/// `_receipts/_rejected/`. Inside a valid receipt each delivery is checked on
/// its own: valid ones are recorded and invalid ones are dropped and listed in
/// `_rejected/<receipt>.dropped`, so one bad entry never loses the batch.
struct MailboxDeliveryReceipt: Equatable {

    struct Delivery: Equatable {
        let id: String
        let recipient: String
    }

    static let version = 1
    static let directoryName = "_receipts"
    static let rejectedDirectoryName = "_rejected"
    static let fileExtension = "receipt"
    static let droppedExtension = "dropped"
    static let maxBytes = 64 * 1024
    static let maxDeliveries = 512
    static let maxRecipientBytes = MailboxEnvelope.maxStringFieldBytes

    /// The recipient tab, when the drain knows it (a hook always does; `recv
    /// --tab <name>` may not). Never the caller's tab by default.
    let panelId: UUID?
    let deliveries: [Delivery]
    let via: String
    let ts: String

    init(panelId: UUID?, deliveries: [Delivery], via: String = "drain", ts: String = MailboxEnvelope.currentRFC3339()) {
        self.panelId = panelId
        self.deliveries = deliveries
        self.via = via
        self.ts = ts
    }

    static func spoolURL(mailboxesRoot: URL) -> URL {
        mailboxesRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func isValidId(_ id: String) -> Bool {
        MailboxDrain.isULID(id)
    }

    static func isValidRecipient(_ recipient: String) -> Bool {
        !recipient.isEmpty && recipient.utf8.count <= maxRecipientBytes
    }

    /// A recipient cut to `maxRecipientBytes` on a character boundary, so a
    /// long tab title still records.
    static func clampedRecipient(_ recipient: String) -> String {
        guard recipient.utf8.count > maxRecipientBytes else { return recipient }
        var result = ""
        for character in recipient {
            if result.utf8.count + String(character).utf8.count > maxRecipientBytes { break }
            result.append(character)
        }
        return result
    }

    func encode() -> Data? {
        try? JSONSerialization.data(withJSONObject: jsonObject(deliveries), options: [.sortedKeys])
    }

    private func jsonObject(_ deliveries: [Delivery]) -> [String: Any] {
        var object: [String: Any] = [
            "version": Self.version,
            "via": via,
            "ts": ts,
            "deliveries": deliveries.map { ["id": $0.id, "recipient": $0.recipient] }
        ]
        if let panelId {
            object["panel_id"] = panelId.uuidString
        }
        return object
    }

    // MARK: Decode

    /// A parsed receipt plus the raw entries it had to drop.
    struct Decoded {
        let receipt: MailboxDeliveryReceipt
        let dropped: [Any]
    }

    /// Nil only when the file is not a receipt at all; otherwise every valid
    /// delivery is kept and every invalid one returned in `dropped`. Unknown
    /// keys are ignored. The panel is read from `panel_id`, falling back to
    /// the legacy `tab_id`. An invalid value leaves the deliveries without a
    /// panel (and is listed in `dropped`) rather than losing them.
    static func decode(_ data: Data) -> Decoded? {
        guard data.count <= maxBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == version,
              let via = object["via"] as? String, via == "drain",
              let rawDeliveries = object["deliveries"] as? [Any] else { return nil }
        var dropped: [Any] = []
        var panelId: UUID?
        // C11-337: `tab_id` is the legacy spelling, accepted forever.
        let panelKey = object["panel_id"] != nil ? "panel_id" : "tab_id"
        if let rawPanel = object[panelKey] {
            if let string = rawPanel as? String, let uuid = UUID(uuidString: string) {
                panelId = uuid
            } else {
                dropped.append([panelKey: rawPanel])
            }
        }
        var deliveries: [Delivery] = []
        for raw in rawDeliveries {
            guard let entry = raw as? [String: Any],
                  let id = entry["id"] as? String, isValidId(id),
                  let recipient = entry["recipient"] as? String, isValidRecipient(recipient) else {
                dropped.append(raw)
                continue
            }
            deliveries.append(Delivery(id: id, recipient: recipient))
        }
        let ts = (object["ts"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 64 ? nil : $0 }
            ?? MailboxEnvelope.currentRFC3339()
        return Decoded(receipt: MailboxDeliveryReceipt(panelId: panelId, deliveries: deliveries, via: via, ts: ts), dropped: dropped)
    }

    // MARK: Write

    /// Splits this receipt's deliveries into receipts that each fit
    /// `maxDeliveries` and `maxBytes`, recipients clamped to
    /// `maxRecipientBytes`. Nothing is filtered here: an entry the recorder
    /// cannot accept is dropped there and listed in the `.dropped` sidecar,
    /// where it can be seen.
    func chunked() -> [MailboxDeliveryReceipt] {
        let entries = deliveries
            .map { Delivery(id: $0.id, recipient: Self.clampedRecipient($0.recipient)) }
        guard !entries.isEmpty,
              let empty = try? JSONSerialization.data(withJSONObject: jsonObject([]), options: [.sortedKeys]) else { return [] }
        // Exact sizes: an entry's encoded form is the same inside the array.
        let overhead = empty.count
        var chunks: [[Delivery]] = [[]]
        var bytes = overhead
        for entry in entries {
            let size = (try? JSONSerialization.data(
                withJSONObject: ["id": entry.id, "recipient": entry.recipient],
                options: [.sortedKeys]
            ).count) ?? Self.maxBytes
            let separator = chunks[chunks.count - 1].isEmpty ? 0 : 1
            if chunks[chunks.count - 1].count >= Self.maxDeliveries || bytes + separator + size > Self.maxBytes {
                chunks.append([])
                bytes = overhead
            }
            bytes += (chunks[chunks.count - 1].isEmpty ? 0 : 1) + size
            chunks[chunks.count - 1].append(entry)
        }
        return chunks.filter { !$0.isEmpty }.map { MailboxDeliveryReceipt(panelId: panelId, deliveries: $0, via: via, ts: ts) }
    }

    /// Writes the deliveries as one or more receipts (see `chunked`) and
    /// returns their URLs. A failed write only loses that receipt's events;
    /// the mail was already delivered.
    @discardableResult
    func writeAll(mailboxesRoot: URL, fileManager: FileManager = .default) -> [URL] {
        chunked().compactMap { $0.writeOne(mailboxesRoot: mailboxesRoot, fileManager: fileManager) }
    }

    /// Writes this receipt as one file, atomically. Callers go through
    /// `writeAll`, which guarantees it fits.
    private func writeOne(mailboxesRoot: URL, fileManager: FileManager) -> URL? {
        guard !deliveries.isEmpty, let data = encode(), data.count <= Self.maxBytes else { return nil }
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
