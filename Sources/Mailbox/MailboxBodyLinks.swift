import Foundation
import SwiftUI
import AppKit

/// C11-524: the links inside a mail body, as the mailbox drawer shows them.
///
/// A body is untrusted text from another agent. It is never parsed as
/// Markdown: the only things recognized are `[Title](url)` and bare URLs, and
/// only for the `c11`, `http` and `https` schemes. Everything else, including
/// every other scheme, stays exactly the text that was sent, whitespace and
/// line breaks included. A `c11://` link is a link even when its target is
/// malformed, so a click gets the same "invalid" notice a Markdown panel
/// shows instead of silently doing nothing.
enum MailboxBodyLinks {
    struct Segment: Equatable {
        let text: String
        /// Nil for plain text.
        let url: URL?
    }

    /// Stands in for a `c11://` link that Foundation cannot represent as a
    /// URL; `PanelLinkTarget` rejects it, so a click reports it as invalid.
    static let invalidPanelLinkURL = URL(string: "c11://invalid")!

    private static let titleLimit = 512
    private static let hrefLimit = 2048
    private static let barePrefixes = ["c11://", "http://", "https://"]
    /// Characters that end a bare URL's run.
    private static let bareTerminators: Set<Character> = ["<", ">", "\"", "`"]
    /// Trailing characters left out of a bare URL: sentence punctuation and
    /// closing brackets around it.
    private static let bareTrailing: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\"", ")", "]", "}", ">"]

    /// The URL a recognized link opens, or nil when the text is not a link
    /// the drawer opens (then it stays plain text).
    static func linkURL(_ href: String) -> URL? {
        guard !href.isEmpty, href.utf8.count <= hrefLimit,
              href.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              href.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if PanelLinkTarget.isLink(href) {
            if let url = URL(string: href), PanelLinkTarget.usesScheme(url) { return url }
            return invalidPanelLinkURL
        }
        guard let url = URL(string: href),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// One left-to-right scan of the body.
    static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { result.append(Segment(text: plain, url: nil)); plain = "" }
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "[", let titled = titledLink(in: text, at: index) {
                flush()
                result.append(Segment(text: titled.title, url: titled.url))
                index = titled.end
                continue
            }
            if (character == "c" || character == "C" || character == "h" || character == "H"),
               startsBareLink(in: text, at: index),
               let bare = bareLink(in: text, at: index) {
                flush()
                result.append(Segment(text: bare.text, url: bare.url))
                index = bare.end
                continue
            }
            plain.append(character)
            index = text.index(after: index)
        }
        flush()
        return result
    }

    /// The body with each link's text carrying its URL; nothing else is styled.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for segment in segments(text) {
            var piece = AttributedString(segment.text)
            if let url = segment.url {
                piece.link = url
                piece.foregroundColor = Color(nsColor: .linkColor)
                piece.underlineStyle = .single
            }
            result.append(piece)
        }
        return result
    }

    // MARK: - Scanning

    private static func titledLink(in text: String, at start: String.Index) -> (title: String, url: URL, end: String.Index)? {
        var index = text.index(after: start)
        var title = ""
        var titleLength = 0
        while index < text.endIndex, text[index] != "]" {
            let character = text[index]
            titleLength += 1
            guard !character.isNewline, titleLength <= titleLimit else { return nil }
            title.append(character)
            index = text.index(after: index)
        }
        guard index < text.endIndex, !title.isEmpty else { return nil }
        index = text.index(after: index)
        guard index < text.endIndex, text[index] == "(" else { return nil }
        index = text.index(after: index)
        var href = ""
        var hrefLength = 0
        while index < text.endIndex, text[index] != ")" {
            let character = text[index]
            hrefLength += 1
            guard !character.isWhitespace, hrefLength <= hrefLimit else { return nil }
            href.append(character)
            index = text.index(after: index)
        }
        guard index < text.endIndex, let url = linkURL(href) else { return nil }
        return (title, url, text.index(after: index))
    }

    /// A bare URL starts at a word boundary, so `xhttp://` is not one.
    private static func startsBareLink(in text: String, at index: String.Index) -> Bool {
        if index > text.startIndex {
            let previous = text[text.index(before: index)]
            if previous.isLetter || previous.isNumber { return false }
        }
        let rest = text[index...]
        return barePrefixes.contains { prefix in
            rest.prefix(prefix.count).lowercased() == prefix
        }
    }

    private static func bareLink(in text: String, at start: String.Index) -> (text: String, url: URL, end: String.Index)? {
        var end = start
        var length = 0
        while end < text.endIndex {
            let character = text[end]
            if character.isWhitespace || bareTerminators.contains(character) { break }
            length += 1
            guard length <= hrefLimit else { return nil }
            end = text.index(after: end)
        }
        while end > start, bareTrailing.contains(text[text.index(before: end)]) {
            end = text.index(before: end)
        }
        let candidate = String(text[start..<end])
        guard let url = linkURL(candidate) else { return nil }
        return (candidate, url, end)
    }
}
