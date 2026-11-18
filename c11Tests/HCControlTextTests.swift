import XCTest
import Carbon.HIToolbox
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Control text sent to an hc terminal must arrive as the keys it names. Native
/// captures are faked with the real paste encoder's relevant behavior (control
/// bytes become spaces); no Ghostty surface is created.
final class HCControlTextTests: XCTestCase {
    private let panel = UUID()
    private let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t1")
    private let revision = HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 1)
    private let surface = UnsafeMutableRawPointer(bitPattern: 0x10)!

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paste = 0, keys = 0
        func notePaste() { lock.lock(); paste += 1; lock.unlock() }
        func noteKey() { lock.lock(); keys += 1; lock.unlock() }
        var pasteCalls: Int { lock.lock(); defer { lock.unlock() }; return paste }
        var keyCalls: Int { lock.lock(); defer { lock.unlock() }; return keys }
    }

    private final class Writer: HCFrameWriter, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var batches = 0
        var received: Data { lock.lock(); defer { lock.unlock() }; return bytes }
        var writes: Int { lock.lock(); defer { lock.unlock() }; return batches }
        func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
            .reserved(HCWriteReservation(id: UUID(), operationID: operationID, attachmentGeneration: attachmentGeneration,
                connectionGeneration: 1, encodedByteCount: encodedByteCount))
        }
        func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
            lock.lock(); defer { lock.unlock() }
            batches += 1
            var body = 0
            var returned = false
            for frame in batch.frames {
                switch frame {
                case .data(let data): bytes.append(data); body += data.count
                case .submitReturn(let data), .submitReturnAfter(let data, delayNanoseconds: _): bytes.append(data); returned = true
                default: break
                }
            }
            return .written(HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                bodyBytesWritten: body, returnWritten: returned))
        }
        func cancel(_ reservation: HCWriteReservation) {}
        func control(_ control: HCControl) async -> HCControlOutcome { .written }
    }

    private struct Screen: HCScreenProvider {
        func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
    }

    private func encoder(_ recorder: Recorder) -> HCNativePasteEncoder {
        HCNativePasteEncoder(surface: { [surface] in surface },
            pasteCapture: { _, payload, submit, _ in
                recorder.notePaste()
                // Ghostty's paste encoder replaces control bytes with spaces.
                let body = Data(payload.map { ($0 < 0x20 && $0 != 0x0A && $0 != 0x0D) || $0 == 0x7F ? 0x20 : $0 })
                return (body, submit ? Data([13]) : Data())
            },
            keyCapture: { _, spec, _ in
                recorder.noteKey()
                switch spec.keycode {
                case UInt32(kVK_Return): return Data([13])
                case UInt32(kVK_Tab): return Data([9])
                case UInt32(kVK_Escape): return Data([0x1B])
                case UInt32(kVK_Delete): return Data([0x7F])
                default: return Data((spec.text ?? "").utf8)
                }
            })
    }

    private func send(_ text: String, submit: Bool = false, source: HCInputSource = .socket,
                      recorder: Recorder = Recorder(), encoder custom: (any HCInputEncoder)? = nil) async
        -> (outcome: HCInputOutcome, writer: Writer, recorder: Recorder) {
        let writer = Writer()
        let revision = revision
        let coordinator = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: custom ?? (encoder(recorder) as any HCInputEncoder), screen: Screen(), displayRevision: { revision }, report: { _ in })
        let request = HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: 3,
            source: source, payload: Data(text.utf8), submitReturn: submit)
        let outcome = await coordinator.submit(request)
        return (outcome, writer, recorder)
    }

    func testControlTextReachesTheReceiverAsTheKeysItNames() async {
        let cases: [(String, [UInt8])] = [
            ("\u{3}", [3]),                       // Ctrl-C interrupts; paste would type a space
            ("\u{4}", [4]),                       // Ctrl-D
            ("\u{1b}[A", [0x1B, 0x5B, 0x41]),      // Escape sequence keeps its Escape
            ("a\tb", [0x61, 9, 0x62]),            // Tab
            ("\u{7f}", [0x7F]),                   // Delete
        ]
        for (text, expected) in cases {
            let result = await send(text)
            guard case .written = result.outcome else { return XCTFail("\(text.debugDescription) was not written") }
            XCTAssertEqual(result.writer.received, Data(expected), text.debugDescription)
            XCTAssertEqual(result.recorder.pasteCalls, 0, "control text must never go through the paste encoder")
        }
    }

    func testProseAndMultilineTextStayOnThePastePath() async {
        let result = await send("hello\nworld", submit: true)
        guard case .written = result.outcome else { return XCTFail("prose not written") }
        XCTAssertEqual(result.recorder.pasteCalls, 1)
        XCTAssertEqual(result.recorder.keyCalls, 0)
        XCTAssertEqual(result.writer.received, Data("hello\nworld".utf8) + Data([13]))
    }

    func testSubmitAfterControlTextIsAReturnKeyNotPasteSubmit() async {
        let result = await send("\u{3}", submit: true)
        guard case .written(let receipt) = result.outcome else { return XCTFail("not written") }
        XCTAssertTrue(receipt.returnWritten)
        XCTAssertEqual(result.writer.received, Data([3, 13]))
        XCTAssertEqual(result.recorder.pasteCalls, 0)
    }

    func testTextThatCannotBeSentFaithfullyIsRefusedBeforeAnyByte() async {
        let nul = await send("a\u{0}b")
        guard case .refused(.unavailable) = nul.outcome else { return XCTFail("NUL must be refused") }
        XCTAssertEqual(nul.writer.writes, 0)
        // One tab forces the key route, whose conservative bound is 16x the text.
        let large = await send(String(repeating: "x", count: 80_000) + "\t")
        guard case .refused(.tooLarge) = large.outcome else { return XCTFail("oversize key transaction admitted") }
        XCTAssertEqual(large.writer.writes, 0)
    }

    // MARK: C11H-362, operator pastes and drops

    /// Ghostty's paste encoder (`ghostty/src/input/paste.zig`, `encode`): xterm's strip set becomes spaces in every
    /// mode, a bracketed paste is fenced, and an unbracketed newline becomes CR. A Tab is kept.
    static func ghosttyPaste(_ payload: Data, bracketed: Bool) -> Data {
        let strip: Set<UInt8> = [0x00, 0x08, 0x05, 0x04, 0x1B, 0x7F, 0x03, 0x1C, 0x15, 0x1A, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0F]
        let body = Data(payload.map { strip.contains($0) ? 0x20 : (!bracketed && $0 == 0x0A ? 0x0D : $0) })
        return bracketed ? Data("\u{1b}[200~".utf8) + body + Data("\u{1b}[201~".utf8) : body
    }

    /// A native encoder whose paste capture is Ghostty's paste encoder in the given mode.
    static func ghosttyEncoder(bracketed: Bool, recorder: Recorder,
                               surface: UnsafeMutableRawPointer = UnsafeMutableRawPointer(bitPattern: 0x10)!) -> HCNativePasteEncoder {
        HCNativePasteEncoder(surface: { surface },
            pasteCapture: { _, payload, submit, _ in
                recorder.notePaste()
                return (ghosttyPaste(payload, bracketed: bracketed), submit ? Data([13]) : Data())
            },
            keyCapture: { _, spec, _ in
                recorder.noteKey()
                return spec.keycode == UInt32(kVK_Tab) ? Data([9]) : Data((spec.text ?? "").utf8)
            })
    }

    /// Two command lines joined by a Tab, an injected closing fence, a raw Ctrl-U and a Ctrl-C: the shape of a
    /// snippet copied from a web page.
    private let hostile = "echo first\techo x\n\u{1b}[201~echo second\u{15}\u{3}\n"

    func testOperatorPastesAndDropsAreFencedAndSanitizedNeverTyped() async {
        for source in [HCInputSource.filePaste, .drop] {
            let recorder = Recorder()
            let result = await send(hostile, source: source, recorder: recorder,
                                    encoder: Self.ghosttyEncoder(bracketed: true, recorder: recorder))
            guard case .written = result.outcome else { return XCTFail("\(source) was not written") }
            XCTAssertEqual(result.recorder.keyCalls, 0, "\(source): an operator paste is never typed as keys")
            XCTAssertEqual(result.recorder.pasteCalls, 1, "\(source)")
            XCTAssertEqual(result.writer.received,
                           Data("\u{1b}[200~echo first\techo x\n [201~echo second  \n\u{1b}[201~".utf8), "\(source)")
            XCTAssertFalse(result.writer.received.contains(13), "\(source): no carriage return, so nothing runs before Return")
        }
    }

    func testWithBracketedPasteOffAnOperatorPasteGetsGhosttysPasteBytes() async {
        for source in [HCInputSource.filePaste, .drop] {
            let recorder = Recorder()
            let result = await send(hostile, source: source, recorder: recorder,
                                    encoder: Self.ghosttyEncoder(bracketed: false, recorder: recorder))
            guard case .written = result.outcome else { return XCTFail("\(source) was not written") }
            XCTAssertEqual(result.recorder.keyCalls, 0, "\(source)")
            // No fence to hold it, so each newline is a CR, as in any terminal; the control bytes are spaces.
            XCTAssertEqual(result.writer.received, Data("echo first\techo x\r [201~echo second  \r".utf8), "\(source)")
        }
    }

    func testACleanMultilinePasteIsFencedUnchanged() async {
        let recorder = Recorder()
        let result = await send("ls -la\npwd", source: .filePaste, recorder: recorder,
                                encoder: Self.ghosttyEncoder(bracketed: true, recorder: recorder))
        guard case .written = result.outcome else { return XCTFail("not written") }
        XCTAssertEqual(result.writer.received, Data("\u{1b}[200~ls -la\npwd\u{1b}[201~".utf8))
        XCTAssertEqual(result.recorder.keyCalls, 0)
    }

    func testAnAgentSendOfTheSameTextStillTypesItsKeys() async {
        let recorder = Recorder()
        let result = await send("a\tb", source: .socket, recorder: recorder,
                                encoder: Self.ghosttyEncoder(bracketed: true, recorder: recorder))
        guard case .written = result.outcome else { return XCTFail("not written") }
        XCTAssertEqual(result.recorder.pasteCalls, 0, "c11 send keeps its content routing")
        XCTAssertEqual(result.writer.received, Data([0x61, 9, 0x62]))
    }

    /// A terminal with no screen cannot know whether its program enabled bracketed paste, so it refuses an
    /// operator paste before any byte rather than type it raw.
    func testAHeadlessTerminalRefusesAnOperatorPasteBeforeAnyByte() async {
        for source in [HCInputSource.filePaste, .drop] {
            let result = await send(hostile, source: source, encoder: HCHeadlessInputEncoder(returnDelayNanoseconds: { _ in 0 }))
            guard case .refused(.unavailable) = result.outcome else { return XCTFail("\(source): \(result.outcome)") }
            XCTAssertEqual(result.writer.writes, 0, "\(source)")
        }
        let agent = await send("ls", source: .socket, encoder: HCHeadlessInputEncoder(returnDelayNanoseconds: { _ in 0 }))
        guard case .written = agent.outcome else { return XCTFail("an agent send to a headless terminal still goes") }
        XCTAssertEqual(agent.writer.received, Data("ls".utf8))
    }
}
