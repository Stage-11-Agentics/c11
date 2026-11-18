import Foundation
import Carbon.HIToolbox

/// One key event for the pinned synchronous key encoder.
struct HCKeyEventSpec: Equatable, Sendable {
    let keycode: UInt32
    let text: String?
    let releaseAfterPress: Bool
}

/// Keystroke-shaped text (an interrupt, escape codes, Tab) must reach the
/// terminal as the keys it names. Ghostty's paste encoder replaces those bytes
/// with spaces, so a payload carrying any C0 byte other than a newline is
/// encoded as key events instead, with the same chunking and key mapping the
/// non-hc `send` path uses (`socketTextChunks`). Prose and multi-line text keep
/// the paste encoder.
enum HCControlText {
    static func usesKeyEncoding(_ text: String) -> Bool {
        !TerminalController.socketTextIsPasteDeliverable(text)
    }

    /// Nil when the text cannot be sent byte-for-byte: NUL cannot cross the
    /// C-string boundary of a key event, and the legacy path dropped it too.
    static func bodyEvents(for text: String) -> [HCKeyEventSpec]? {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        var events: [HCKeyEventSpec] = []
        for chunk in TerminalController.socketTextChunks(text) {
            switch chunk {
            case .text(let value):
                events.append(HCKeyEventSpec(keycode: 0, text: value, releaseAfterPress: false))
            case .control(let scalar):
                guard let keycode = TerminalController.socketControlKeycode(scalar) else { return nil }
                events.append(HCKeyEventSpec(keycode: keycode, text: nil, releaseAfterPress: false))
            }
        }
        return events
    }

    /// A real submit is a Return key press and release.
    static let returnEvent = HCKeyEventSpec(keycode: UInt32(kVK_Return), text: nil, releaseAfterPress: true)

    /// The byte limit the native encoder requires for one event.
    static func byteLimit(for event: HCKeyEventSpec) -> Int {
        16 * (event.text?.utf8.count ?? 0) + 512
    }
}

extension HCInitialInput {
    /// The non-hc path types `raw + "\r"` as raw bytes. Over hc the body is a
    /// paste (bracketed when the program asked for it), so a trailing CR inside
    /// it would sit in the line editor unexecuted. Split one trailing CR into
    /// the separate Return frame, which is sent outside the brackets.
    static func creation(from raw: String, operationID: UUID = UUID()) -> HCInitialInput {
        guard raw.hasSuffix("\r") else {
            return HCInitialInput(operationID: operationID, payload: Data(raw.utf8), submitReturn: false)
        }
        return HCInitialInput(operationID: operationID, payload: Data(raw.dropLast().utf8), submitReturn: true)
    }
}
