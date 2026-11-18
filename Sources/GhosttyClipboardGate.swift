import Foundation
import os

/// The clipboard decisions behind Ghostty's three clipboard callbacks
/// (`read_clipboard_cb`, `confirm_read_clipboard_cb`, `write_clipboard_cb`).
/// The callbacks pass the request's kind, the operator's `clipboard-read`
/// setting and a pasteboard reader or writer, and do what this returns. It
/// never touches a real pasteboard itself (C11H-372).
///
/// An OSC 52 read is answered only under `clipboard-read = allow`. c11 has no
/// clipboard prompt, so Ghostty's default `ask` resolves to a denial, and a
/// denied read never reads the pasteboard. An OSC 52 write that carries
/// Ghostty's confirm flag (`clipboard-write = ask`) is not written. A paste
/// keeps its behaviour: it is the operator's own act.
enum GhosttyClipboardGate {
    /// `ghostty_clipboard_request_e`.
    enum RequestKind: Equatable {
        case paste
        case osc52Read
        case osc52Write

        init?(_ raw: ghostty_clipboard_request_e) {
            switch raw {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE: self = .paste
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: self = .osc52Read
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE: self = .osc52Write
            default: return nil
            }
        }

        /// The kind of a live request handed to a clipboard callback, read
        /// before the request is completed; nil for a null request.
        init?(request: UnsafeRawPointer?) {
            var raw = GHOSTTY_CLIPBOARD_REQUEST_PASTE
            guard ghostty_clipboard_request_get_type(request, &raw) else { return nil }
            self.init(raw)
        }
    }

    /// Ghostty's `ClipboardAccess` (`clipboard-read`, `clipboard-write`).
    enum Access: Equatable {
        case allow
        case ask
        case deny

        /// The enum tag `ghostty_config_get` returns; nil for anything else.
        init?(configValue: String?) {
            switch configValue {
            case "allow": self = .allow
            case "ask": self = .ask
            case "deny": self = .deny
            default: return nil
            }
        }
    }

    /// One call to `ghostty_surface_complete_clipboard_request`.
    struct Completion: Equatable {
        let text: String
        let confirmed: Bool

        /// A refusal. Completing with `confirmed = false` is not final in
        /// Ghostty's embedded runtime: under `ask` it raises the confirmation
        /// again with the same request. Empty text, confirmed, is upstream
        /// Ghostty's own Cancel: the program gets an empty OSC 52 reply (no
        /// clipboard bytes), and Ghostty frees the request without asking
        /// again. An empty paste types nothing.
        static let refused = Completion(text: "", confirmed: true)
    }

    private static let logger = Logger(subsystem: "com.stage11.c11", category: "clipboard")

    /// `read_clipboard_cb`, decided before anything reads the pasteboard.
    /// `readPasteboard(allowImageFallback)` runs at most once, and never for a
    /// refused OSC 52 read: a read can raise the system's paste prompt or save
    /// a clipboard image to a temp file, and terminal output must cause
    /// neither. An answered read is completed unconfirmed, so Ghostty's own
    /// `clipboard-read = allow` path is what sends it. nil leaves the request
    /// alone: an OSC 52 write never starts a read, and completing one could
    /// clear the operator's clipboard.
    static func answerRead(kind: RequestKind?,
                           clipboardRead: Access?,
                           readPasteboard: (_ allowImageFallback: Bool) -> String) -> Completion? {
        switch kind {
        case .paste:
            return Completion(text: readPasteboard(true), confirmed: false)
        case .osc52Read where clipboardRead == .allow:
            return Completion(text: readPasteboard(false), confirmed: false)
        case .osc52Read:
            return .refused
        case .osc52Write, nil:
            return nil
        }
    }

    /// `confirm_read_clipboard_cb`: Ghostty asks after `UnsafePaste` or
    /// `UnauthorizedPaste`. An OSC 52 read's content is never confirmed. An
    /// unsafe paste is confirmed as before: a paste prompt would hold a
    /// socket-sent paste on an operator click, and a modal one wedges the app.
    /// nil leaves the request alone: an OSC 52 write never travels this route,
    /// and completing one could clear the operator's clipboard.
    static func answerConfirm(kind: RequestKind?, content: String) -> Completion? {
        switch kind {
        case .paste:
            return Completion(text: content, confirmed: true)
        case .osc52Read:
            return .refused
        case .osc52Write, nil:
            return nil
        }
    }

    /// `write_clipboard_cb`: the text to put on the pasteboard, or nil. With
    /// Ghostty's confirm flag set (`clipboard-write = ask`) and no prompt to
    /// ask, nothing is written. Otherwise the `text/plain` item wins, else the
    /// first item.
    static func textToWrite(items: [(mime: String?, data: String)], confirm: Bool) -> String? {
        guard !confirm else { return nil }
        if let plain = items.first(where: { $0.mime?.hasPrefix("text/plain") == true }) {
            return plain.data
        }
        return items.first?.data
    }

    /// One line per refusal: the kind, the panel and the setting, never the contents.
    static func logRefusal(_ event: String, panel: UUID?, setting: Access?) {
        let panelText = panel?.uuidString ?? "unknown"
        let settingText = setting.map { "\($0)" } ?? "unreadable"
        logger.info("event=\(event, privacy: .public) panel=\(panelText, privacy: .public) setting=\(settingText, privacy: .public)")
    }
}
