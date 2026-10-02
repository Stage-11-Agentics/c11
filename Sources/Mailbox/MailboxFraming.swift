import Foundation

/// The `<c11-msg>` framed block an agent reads, shared by the app and the CLI
/// (the hook drain runs in the CLI process). Byte-identical to
/// `StdinMailboxHandler.formatFramedBlock` for inline-body envelopes; a
/// `body_ref` envelope additionally carries `body_ref="<path>"` so a drained
/// agent can open the external body.
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
        return "\n<c11-msg \(attrString)>\n\(xmlEscapeBody(envelope.body))\n</c11-msg>\n"
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
