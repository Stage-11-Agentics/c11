import Darwin
import Foundation

/// The `<c11-msg>` framed block an agent reads, shared by the app and the CLI
/// (the hook drain runs in the CLI process). Byte-identical to
/// `StdinMailboxHandler.formatFramedBlock` for inline-body envelopes; a
/// `body_ref` envelope additionally carries `body_ref="<path>"`. Recv and the
/// hook drain inline that file, up to `bodyRefInlineCap` bytes, and name the
/// path when the rest does not fit. The envelope on disk stays unchanged.
///
///     \n
///     <c11-msg from="builder" id="01K..." ts="..." to="watcher">\n
///     escaped body bytes\n
///     </c11-msg>\n
///
/// Attribute values and the body are XML-escaped so a literal `</c11-msg>` in
/// a body cannot forge a closing tag.
enum MailboxFraming {

    static func framedBlock(envelope: MailboxEnvelope) -> String {
        var attrs: [(String, String)] = []
        attrs.append(("from", envelope.from))
        attrs.append(("id", envelope.id))
        attrs.append(("ts", envelope.ts))
        if let to = envelope.to { attrs.append(("to", to)) }
        if let topic = envelope.topic { attrs.append(("topic", topic)) }
        if let replyTo = envelope.replyTo { attrs.append(("reply_to", replyTo)) }
        if let inReplyTo = envelope.inReplyTo { attrs.append(("in_reply_to", inReplyTo)) }
        if envelope.urgent == true { attrs.append(("urgent", "true")) }
        if let ttl = envelope.ttlSeconds { attrs.append(("ttl_seconds", String(ttl))) }
        if let bodyRef = envelope.bodyRef { attrs.append(("body_ref", bodyRef)) }

        let attrString = attrs
            .map { "\($0.0)=\"\(xmlEscapeAttribute($0.1))\"" }
            .joined(separator: " ")
        return "\n<c11-msg \(attrString)>\n\(xmlEscapeBody(presentedBody(envelope: envelope)))\n</c11-msg>\n"
    }

    // MARK: What a pushed agent reads

    /// The block an agent reads when mail is pushed into its turn (Claude's
    /// inline turn, a Stop drain). The c11 skill already says what it is, so it
    /// carries only what the agent needs: who sent it, the topic and the body.
    /// `id` is the ULID's last six characters, enough to tell messages apart;
    /// `mailbox send --in-reply-to` expands it. `at` is local send time, with
    /// the date only when it is not today.
    ///
    ///     <c11-msg from="c11-lead" topic="review" id="J5ZEPW" at="18:01">
    ///     Rebased; re-run the gate.
    ///     </c11-msg>
    static func agentBlock(envelope: MailboxEnvelope, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var attrs: [(String, String)] = [("from", envelope.from)]
        if let replyTo = envelope.replyTo, replyTo != envelope.from { attrs.append(("reply_to", replyTo)) }
        if let topic = envelope.topic { attrs.append(("topic", topic)) }
        attrs.append(("id", shortId(envelope.id)))
        if let at = shortTime(envelope.ts, now: now, timeZone: timeZone) { attrs.append(("at", at)) }
        if envelope.urgent == true { attrs.append(("urgent", "true")) }
        if let bodyRef = envelope.bodyRef { attrs.append(("body_ref", bodyRef)) }
        let attrString = attrs.map { "\($0.0)=\"\(xmlEscapeAttribute($0.1))\"" }.joined(separator: " ")
        return "<c11-msg \(attrString)>\n\(escapeBlockTags(presentedBody(envelope: envelope)))\n</c11-msg>\n"
    }

    static let shortIdLength = 6

    static func shortId(_ id: String) -> String { String(id.suffix(shortIdLength)) }

    static func shortTime(_ ts: String, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }

    /// Only something a reader could take for an opening or closing block tag
    /// can forge a block, so only a `<` that leads to `c11` is escaped, across
    /// spaces, invisible format characters and a `/`; code stays readable.
    static func escapeBlockTags(_ body: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "<(?=[\\s\\p{Cf}]*/?[\\s\\p{Cf}]*c11)",
                                                     options: [.caseInsensitive]) else { return body }
        return pattern.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "&lt;")
    }

    /// UTF-8 bytes of a `body_ref` file copied into recv and hook output.
    /// Same cap as an inline `body`.
    static let bodyRefInlineCap = MailboxEnvelope.maxBodyBytes

    /// What `c11 mailbox recv` prints. An inline body stays the raw envelope
    /// JSON. A `body_ref` prints the framed block, with the file inlined.
    static func displayText(data: Data) -> String {
        guard let envelope = try? MailboxEnvelope.validate(data: data),
              envelope.bodyRef != nil else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return framedBlock(envelope: envelope)
    }

    /// Body text for a framed block. Inline envelopes pass through. A
    /// `body_ref` is read here; the stored envelope body stays empty.
    static func presentedBody(envelope: MailboxEnvelope) -> String {
        guard let path = envelope.bodyRef else { return envelope.body }
        let read = readBodyRef(path: path, cap: bodyRefInlineCap)
        if read.missing { return "[body unavailable; see \(path)]" }
        if read.notUTF8 { return "[body is not UTF-8; see \(path)]" }
        if read.truncated { return read.text + "\n[truncated; rest is at \(path)]" }
        return read.text
    }

    struct BodyRefRead: Equatable {
        var text: String
        var truncated: Bool
        var missing: Bool
        var notUTF8: Bool
    }

    /// Read at most `cap` bytes, plus one byte so a longer file is visible
    /// as truncated. Does not read the rest of a large file. A FIFO, a
    /// device, or anything else that is not a regular file is unavailable:
    /// the open is non-blocking, and the type is checked on the descriptor
    /// so `recv` and the Stop hook cannot stall on a pipe.
    static func readBodyRef(path: String, cap: Int) -> BodyRefRead {
        let unavailable = BodyRefRead(text: "", truncated: false, missing: true, notUTF8: false)
        guard path.hasPrefix("/"), cap >= 0 else { return unavailable }
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { return unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return unavailable
        }
        var buffer = [UInt8](repeating: 0, count: cap + 1)
        var got = 0
        while got < cap + 1 {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: got), cap + 1 - got)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return unavailable
            }
            got += count
        }
        let data = Data(buffer.prefix(got))
        let truncated = data.count > cap
        let end = utf8PrefixEnd(data, cap: cap)
        guard let text = String(data: data.prefix(end), encoding: .utf8) else {
            return BodyRefRead(text: "", truncated: truncated, missing: false, notUTF8: true)
        }
        return BodyRefRead(text: text, truncated: truncated, missing: false, notUTF8: false)
    }

    /// Index just past the last complete UTF-8 character that fits in `cap`.
    private static func utf8PrefixEnd(_ data: Data, cap: Int) -> Int {
        let limit = min(data.count, cap)
        guard data.count > cap else { return limit }
        var end = limit
        while end > 0, (data[end] & 0xC0) == 0x80 {
            end -= 1
        }
        return end
    }

    /// Covers `<`, `>`, `&`, and `"`.
    static func xmlEscapeAttribute(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            default: result.append(ch)
            }
        }
        return result
    }

    /// Covers `<`, `>`, `&`; quotes are fine in body text.
    static func xmlEscapeBody(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            default: result.append(ch)
            }
        }
        return result
    }
}

/// One turn's worth of waiting mail for a native route that can carry text:
/// the envelopes themselves as agent blocks, oldest first, with nothing else. Claude Code takes it
/// as a peer turn; any harness that can accept a message can take the same text.
/// Off-main only: it reads inbox and `body_ref` files. It never claims. The
/// claim follows the harness's confirmation (`claim`), so mail a harness did not
/// take stays in the inbox for the typed doorbell and `recv`.
struct MailboxInlineBatch: Equatable {
    struct Source: Equatable {
        let id: String
        let inbox: URL
    }

    /// Well under Claude's 1 MiB inbox line. The first message always goes, so
    /// one large message can never stall the inbox; mail past the budget waits
    /// for the next idle, oldest first, as a Stop drain would leave it.
    static let budget = 32 * 1024

    let text: String
    let ids: [String]

    /// Nil when none of the sources is still readable: another consumer took
    /// them, and the ring falls through to its ordinary invitation.
    static func compose(sources: [Source], budget: Int = MailboxInlineBatch.budget) -> MailboxInlineBatch? {
        var blocks: [String] = []
        var ids: [String] = []
        var used = 0
        for source in sources.sorted(by: { $0.id < $1.id }) {
            let entry = source.inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: source.id))
            guard let data = try? Data(contentsOf: entry) else { continue }
            let block = MailboxDrain.agentBlock(data: data, fallbackId: source.id)
            let size = block.utf8.count
            if !blocks.isEmpty, used + size > budget { break }
            blocks.append(block)
            ids.append(source.id)
            used += size
        }
        guard !ids.isEmpty else { return nil }
        return MailboxInlineBatch(text: blocks.joined(separator: "\n"), ids: ids)
    }

    /// Claims what the harness confirmed and records it as the recipient's own
    /// read, the same two records a Stop drain leaves. A rename that loses to
    /// another consumer records nothing: that consumer holds the claim, and the
    /// recipient saw the same id twice. Off-main only.
    @discardableResult
    static func claim(sources: [Source], panelId: UUID, recipient: (String) -> String,
                      fileManager: FileManager = .default) -> [String] {
        var claimed: [String] = []
        for (inbox, group) in Dictionary(grouping: sources, by: { $0.inbox.standardizedFileURL }) {
            let ids = group.compactMap { source -> String? in
                let entry = inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: source.id))
                return MailboxDrain.claim(entry, fileManager: fileManager) == nil ? nil : source.id
            }
            guard !ids.isEmpty else { continue }
            let root = inbox.deletingLastPathComponent()
            MailboxDeliveryReceipt(panelId: panelId, deliveries: ids.map { .init(id: $0, recipient: recipient($0)) })
                .writeAll(mailboxesRoot: root, fileManager: fileManager)
            MailboxClaimLog.append(ids: ids, recipientPanel: panelId, byPanel: panelId, via: "native", mailboxesRoot: root)
            claimed += ids
        }
        return claimed
    }
}
