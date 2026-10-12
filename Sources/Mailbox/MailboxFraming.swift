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
    /// as truncated. Does not read the rest of a large file.
    static func readBodyRef(path: String, cap: Int) -> BodyRefRead {
        guard path.hasPrefix("/") else {
            return BodyRefRead(text: "", truncated: false, missing: true, notUTF8: false)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            return BodyRefRead(text: "", truncated: false, missing: true, notUTF8: false)
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: cap + 1) ?? Data()
        } catch {
            return BodyRefRead(text: "", truncated: false, missing: true, notUTF8: false)
        }
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
