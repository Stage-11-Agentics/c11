import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class CreateInitialInputTests: XCTestCase {
    func testNilAndBlankInputAreAbsentEvenForLayoutOrNonTerminal() {
        let blanks: [String?] = [nil, "", " \t\n\r", "\u{2003}\u{00A0}"]
        for raw in blanks {
            for panelType in [nil, "terminal", "browser", "markdown"] as [String?] {
                for hasLayout in [false, true] {
                    XCTAssertEqual(CreateInitialInput.decide(raw: raw, panelType: panelType, hasLayout: hasLayout), .absent)
                }
            }
        }
    }

    func testNonBlankLayoutInputIsRejectedBeforePanelType() {
        for panelType in [nil, "terminal", "browser", "markdown"] as [String?] {
            XCTAssertEqual(CreateInitialInput.decide(raw: "printf x", panelType: panelType, hasLayout: true), .rejectLayout)
        }
    }

    func testBrowserAndMarkdownCannotReceiveShellInput() {
        for panelType in ["browser", "markdown", " BROWSER ", "Markdown"] {
            XCTAssertEqual(CreateInitialInput.decide(raw: "echo no", panelType: panelType), .rejectNonTerminal)
        }
    }

    func testTerminalAndDefaultTypeQueueWithOneSubmitByte() throws {
        for panelType in [nil, "terminal", " TERMINAL "] as [String?] {
            let output = try queued(CreateInitialInput.decide(raw: "printf hi-from-create", panelType: panelType))
            XCTAssertEqual(Array(output.utf8), Array("printf hi-from-create\r".utf8))
        }
    }

    func testLiteralBackslashEscapesAndShellMetacharactersArePreserved() throws {
        let command = #"printf '%s' \n \r \t \x41 "$HOME" '$(touch sentinel)' `literal` ; && | > < \"quotes\""#
        let output = try queued(CreateInitialInput.decide(raw: command, panelType: nil))
        XCTAssertEqual(Array(output.utf8), Array(command.utf8) + [13])
    }

    func testRawUnicodeAndLeadingTrailingWhitespaceStayByteExact() throws {
        let command = " \tprintf '日本語 🪨 cafe\u{0301} café'\n  \t"
        let output = try queued(CreateInitialInput.decide(raw: command, panelType: "terminal"))
        XCTAssertEqual(Array(output.utf8), Array(command.utf8) + [13])
    }

    func testExistingTrailingCRIsNotDuplicated() throws {
        for command in ["echo once\r", "echo once\r\r", "echo once\n\r"] {
            let output = try queued(CreateInitialInput.decide(raw: command, panelType: nil))
            XCTAssertEqual(Array(output.utf8), Array(command.utf8))
        }
    }

    func testTrailingLFAndCRLFKeepExistingBytesAndGainCR() throws {
        for command in ["echo once\n", "echo once\r\n", "echo once\\r"] {
            let output = try queued(CreateInitialInput.decide(raw: command, panelType: nil))
            XCTAssertEqual(Array(output.utf8), Array(command.utf8) + [13])
        }
    }

    func testUnknownPanelTypeRemainsForCreateCallerToValidate() {
        // This helper only rejects the two known non-terminal types; existing
        // create validation remains responsible for unsupported panel types.
        XCTAssertEqual(CreateInitialInput.decide(raw: "echo x", panelType: "unsupported"), .queue("echo x\r"))
    }

    func testDecisionAccessorsSeparateQueuedInputFromRejection() throws {
        let command = " \techo x\n"
        let decision = CreateInitialInput.decide(raw: command, panelType: nil)
        XCTAssertEqual(decision.queuedInput.map { Array($0.utf8) }, Array(command.utf8) + [13])
        XCTAssertNil(decision.errorMessage())
        XCTAssertNil(CreateInitialInput.Decision.absent.queuedInput)
        XCTAssertNil(CreateInitialInput.Decision.absent.errorMessage())
        for rejection in [CreateInitialInput.Decision.rejectLayout, .rejectNonTerminal] {
            XCTAssertNil(rejection.queuedInput)
            XCTAssertNotNil(rejection.errorMessage())
        }
        let typeError = try XCTUnwrap(CreateInitialInput.Decision.rejectNonTerminal.errorMessage(panelType: "  BROWSER "))
        XCTAssertTrue(typeError.contains("browser"))
        XCTAssertTrue(try XCTUnwrap(CreateInitialInput.Decision.rejectNonTerminal.errorMessage()).contains("terminal"))
    }

    private func queued(_ decision: CreateInitialInput.Decision,
                        file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard case let .queue(input) = decision else {
            XCTFail("Expected queued create-time input", file: file, line: line)
            throw NSError(domain: "CreateInitialInputTests", code: 1)
        }
        return input
    }
}
