import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Covers `GhosttyClipboardGate`, the decisions behind Ghostty's clipboard
/// callbacks (C11H-372). A program's OSC 52 read must never receive this Mac's
/// pasteboard without the operator's `clipboard-read = allow`, and an OSC 52
/// write that carries Ghostty's confirm flag must not be written.
///
/// Every test uses a fake pasteboard holding a canary; nothing here reads or
/// writes a real pasteboard.
final class GhosttyClipboardGateTests: XCTestCase {
    private let canary = "C11H-372-CANARY-7f3a"

    /// A pasteboard stand-in: returns the canary and counts reads.
    private final class FakePasteboard {
        let contents: String
        private(set) var reads: [Bool] = []
        init(_ contents: String) { self.contents = contents }
        func read(allowImageFallback: Bool) -> String {
            reads.append(allowImageFallback)
            return contents
        }
    }

    /// The refusal as Ghostty's embedded runtime must receive it. Empty text
    /// carries no clipboard bytes. `confirmed` is what ends the request: an
    /// unconfirmed completion under `ask` raises the confirmation again with the
    /// same request, without end, and c11 would crash on its first OSC 52 read.
    private let refusal = GhosttyClipboardGate.Completion(text: "", confirmed: true)

    func testRefusalIsEmptyAndConfirmedSoGhosttyEndsTheRequest() {
        XCTAssertEqual(GhosttyClipboardGate.Completion.refused, refusal)
    }

    // MARK: OSC 52 read

    /// The finding: Ghostty's default `clipboard-read = ask` must not behave as
    /// allow. The read is refused before the pasteboard is touched, and the
    /// completion carries no clipboard bytes.
    func testOSC52ReadUnderAskIsRefusedWithoutReadingThePasteboard() {
        let pasteboard = FakePasteboard(canary)

        let answer = GhosttyClipboardGate.answerRead(kind: .osc52Read, clipboardRead: .ask,
                                                     readPasteboard: pasteboard.read)

        XCTAssertEqual(answer, refusal)
        XCTAssertFalse(answer?.text.contains(canary) ?? true)
        XCTAssertTrue(pasteboard.reads.isEmpty, "a refused OSC 52 read never reads the pasteboard")
    }

    /// The operator's explicit `clipboard-read = allow` is honoured: the read
    /// is answered from the pasteboard, unconfirmed, so Ghostty's own allow
    /// path sends it. No clipboard-image temp file is made for a program.
    func testOSC52ReadUnderAllowAnswersFromThePasteboard() {
        let pasteboard = FakePasteboard(canary)

        let answer = GhosttyClipboardGate.answerRead(kind: .osc52Read, clipboardRead: .allow,
                                                     readPasteboard: pasteboard.read)

        XCTAssertEqual(answer, GhosttyClipboardGate.Completion(text: canary, confirmed: false))
        XCTAssertEqual(pasteboard.reads, [false], "one text-only read, no image fallback")
    }

    /// Anything but an explicit allow is a refusal: Ghostty's `deny` (which
    /// normally never reaches c11) and a setting c11 could not read.
    func testOSC52ReadWithAnyOtherSettingIsRefused() {
        for setting: GhosttyClipboardGate.Access? in [.deny, nil] {
            let pasteboard = FakePasteboard(canary)
            let answer = GhosttyClipboardGate.answerRead(kind: .osc52Read, clipboardRead: setting,
                                                         readPasteboard: pasteboard.read)
            XCTAssertEqual(answer, refusal, "setting \(String(describing: setting))")
            XCTAssertTrue(pasteboard.reads.isEmpty)
        }
    }

    /// A write request, or one whose kind could not be read, is left alone and
    /// the pasteboard untouched. Completing a write request empty could clear
    /// the operator's clipboard.
    func testReadCallbackLeavesAWriteOrUnknownKindAlone() {
        for kind: GhosttyClipboardGate.RequestKind? in [nil, .osc52Write] {
            let pasteboard = FakePasteboard(canary)
            let answer = GhosttyClipboardGate.answerRead(kind: kind, clipboardRead: .allow,
                                                         readPasteboard: pasteboard.read)
            XCTAssertNil(answer, "kind \(String(describing: kind))")
            XCTAssertTrue(pasteboard.reads.isEmpty)
        }
    }

    /// Ghostty's confirmation for an OSC 52 read never confirms its content:
    /// the canary Ghostty hands back is replaced by an empty reply.
    func testConfirmCallbackNeverConfirmsOSC52ReadContent() {
        let answer = GhosttyClipboardGate.answerConfirm(kind: .osc52Read, content: canary)

        XCTAssertEqual(answer, refusal)
        XCTAssertFalse(answer?.text.contains(canary) ?? true)
    }

    /// A write request never travels the confirm route; it is left alone rather
    /// than completed, since completing one could clear the clipboard.
    func testConfirmCallbackLeavesAnUnexpectedKindAlone() {
        XCTAssertNil(GhosttyClipboardGate.answerConfirm(kind: .osc52Write, content: canary))
        XCTAssertNil(GhosttyClipboardGate.answerConfirm(kind: nil, content: canary))
    }

    /// The gate's kinds are Ghostty's request kinds, one to one.
    func testRequestKindMapsGhosttysEnum() {
        XCTAssertEqual(GhosttyClipboardGate.RequestKind(GHOSTTY_CLIPBOARD_REQUEST_PASTE), .paste)
        XCTAssertEqual(GhosttyClipboardGate.RequestKind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ), .osc52Read)
        XCTAssertEqual(GhosttyClipboardGate.RequestKind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE), .osc52Write)
        XCTAssertNil(GhosttyClipboardGate.RequestKind(request: nil))
    }

    /// The setting parses Ghostty's enum tags and nothing else.
    func testAccessParsesGhosttysTags() {
        XCTAssertEqual(GhosttyClipboardGate.Access(configValue: "allow"), .allow)
        XCTAssertEqual(GhosttyClipboardGate.Access(configValue: "ask"), .ask)
        XCTAssertEqual(GhosttyClipboardGate.Access(configValue: "deny"), .deny)
        XCTAssertNil(GhosttyClipboardGate.Access(configValue: "Allow"))
        XCTAssertNil(GhosttyClipboardGate.Access(configValue: nil))
    }

    // MARK: OSC 52 write

    /// Hardening note 5: under `clipboard-write = ask` Ghostty sets the confirm
    /// flag. With no prompt to ask, nothing is written.
    func testOSC52WriteWithConfirmFlagIsNotWritten() {
        let items: [(mime: String?, data: String)] = [(mime: "text/plain;charset=utf-8", data: canary)]

        XCTAssertNil(GhosttyClipboardGate.textToWrite(items: items, confirm: true))
    }

    /// Without the flag the existing choice stands: the `text/plain` item,
    /// else the first item.
    func testOSC52WriteWithoutConfirmFlagKeepsTheTextPlainChoice() {
        let mixed: [(mime: String?, data: String)] = [(mime: "text/html", data: "<b>x</b>"),
                                                      (mime: "text/plain", data: canary)]
        XCTAssertEqual(GhosttyClipboardGate.textToWrite(items: mixed, confirm: false), canary)

        let noPlain: [(mime: String?, data: String)] = [(mime: nil, data: canary), (mime: "text/html", data: "x")]
        XCTAssertEqual(GhosttyClipboardGate.textToWrite(items: noPlain, confirm: false), canary)

        XCTAssertNil(GhosttyClipboardGate.textToWrite(items: [], confirm: false))
    }

    // MARK: Paste (kept as today)

    /// The plan keeps today's paste behaviour: a paste reads the pasteboard
    /// with the image fallback and completes unconfirmed (Ghostty's own
    /// unsafe-paste check runs), and Ghostty's unsafe-paste confirmation is
    /// confirmed with the operator's own content.
    func testUnsafePasteKeepsTodaysBehaviour() {
        let multiLine = "\(canary)\necho second-line"
        let pasteboard = FakePasteboard(multiLine)

        let read = GhosttyClipboardGate.answerRead(kind: .paste, clipboardRead: .ask,
                                                   readPasteboard: pasteboard.read)
        XCTAssertEqual(read, GhosttyClipboardGate.Completion(text: multiLine, confirmed: false))
        XCTAssertEqual(pasteboard.reads, [true], "a paste keeps the clipboard-image fallback")

        let confirm = GhosttyClipboardGate.answerConfirm(kind: .paste, content: multiLine)
        XCTAssertEqual(confirm, GhosttyClipboardGate.Completion(text: multiLine, confirmed: true))
    }
}
