import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class CLIUnknownCommandTests: XCTestCase {
    func testUnknownVerbNamesTheVerbTheBuildAndTheGuide() {
        let text = CLIUnknownCommand.hint(command: "fleet", version: "1.6.0")
        XCTAssertEqual(text, "'fleet' is not in c11 1.6.0; run 'c11 guide' for this build's commands.")
    }

    func testUnknownVersionIsStatedNotOmitted() {
        let text = CLIUnknownCommand.hint(command: "fleet", version: nil)
        XCTAssertTrue(text.contains("c11 (version unknown)"), text)
        XCTAssertTrue(text.contains("run 'c11 guide'"), text)
    }

    /// The text must not depend on which verb it is: a list of "newer c11
    /// verbs" would go stale the day c11 adds one.
    func testHintIsTheSameShapeForAnyVerb() {
        for verb in ["fleet", "anything-new", "x"] {
            let text = CLIUnknownCommand.hint(command: verb, version: "1.6.0")
            XCTAssertEqual(text.replacingOccurrences(of: "'\(verb)'", with: "'<verb>'"),
                           "'<verb>' is not in c11 1.6.0; run 'c11 guide' for this build's commands.")
        }
    }

    func testGuideAuthorityNamesTheBuildAndSaysMissingCommandsDoNotExist() {
        let text = CLIGuideAuthority.line(version: "1.6.0")
        XCTAssertTrue(text.hasPrefix("This is c11 1.6.0."), text)
        XCTAssertTrue(text.contains("names a command this guide lacks, that command does not exist here"), text)
    }

    func testHintNamesTheToolTheAgentTyped() {
        XCTAssertEqual(CLIUnknownCommand.hint(command: "fleet", version: "1.6.0", tool: "c11"),
                       "'fleet' is not in c11 1.6.0; run 'c11 guide' for this build's commands.")
        XCTAssertTrue(CLIUnknownCommand.hint(command: "fleet", version: "1.6.0").contains("run 'c11 guide'"))
    }

    func testOnlyTheTwoKnownInvokedNamesAreAccepted() {
        XCTAssertEqual(CLIInvokedName.name(from: "c11"), "c11")
        XCTAssertEqual(CLIInvokedName.name(from: "c11"), "c11")
        for raw in [nil, "", "cmux", "c11; rm -rf /", "C11"] as [String?] {
            XCTAssertEqual(CLIInvokedName.name(from: raw), "c11", "\(String(describing: raw))")
        }
    }

    func testSessionStartHookSendsTheNoteOnlyWhenTheWrapperDidNot() {
        let note = "You are running inside c11, a fork of c11. Run `c11 guide` first."
        XCTAssertNil(C11LaunchNote.sessionStartContext(
            environment: ["C11_AGENT_NOTE_SENT": "1"], noteBody: note, version: "1.8.1-h13"))
        XCTAssertNil(C11LaunchNote.sessionStartContext(
            environment: ["C11_AGENT_NOTE_DISABLED": "1"], noteBody: note, version: "1.8.1-h13"))
        XCTAssertNil(C11LaunchNote.sessionStartContext(environment: [:], noteBody: " \n", version: "1.8.1-h13"))
        XCTAssertEqual(C11LaunchNote.sessionStartContext(environment: [:], noteBody: note + "\n", version: "1.8.1-h13"),
                       "c11 1.8.1-h13. " + note)
        XCTAssertEqual(C11LaunchNote.sessionStartContext(environment: [:], noteBody: note, version: "$(MARKETING_VERSION)-h7"),
                       "c11 (version unknown). " + note)
    }
}
