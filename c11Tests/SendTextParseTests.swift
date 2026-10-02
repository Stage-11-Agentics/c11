import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class SendTextParseTests: XCTestCase {
    func testBuiltCLISendProtocolFixtures() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = products.appendingPathComponent("c11 DEV.app/Contents/Resources/bin/c11")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tests_v2/test_send_raw_and_flags.py")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--offline"]
        var environment = ProcessInfo.processInfo.environment
        environment["C11_CLI"] = cli.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }

    func testRawKeepsEscapesAndDefaultKeepsLegacyDecoding() throws {
        let argument = #"printf %s \n\r\t"#
        XCTAssertEqual(try SendTextParse.parse(["--raw", argument]).text(), argument)
        XCTAssertEqual(try SendTextParse.parse([argument]).text(), "printf %s \r\r\t")
        XCTAssertEqual(try SendTextParse.parse([argument], paste: true).text(), argument)
    }

    func testFlagsAndTargetAliasesAreConsumedBeforeTerminator() throws {
        for flag in ["--tab", "--surface", "--panel"] {
            let parsed = try SendTextParse.parse(["--workspace", "workspace:2", flag, "tab:3",
                                                  "--json", "--no-submit", "--raw", "body"])
            XCTAssertEqual(parsed.workspace, "workspace:2")
            XCTAssertEqual(parsed.tab, "tab:3")
            XCTAssertTrue(parsed.raw)
            XCTAssertTrue(parsed.json)
            XCTAssertFalse(parsed.submit)
            XCTAssertEqual(try parsed.text(), "body")
        }
        let literal = try SendTextParse.parse(["--", "--bogus", "--raw", "--tab", "tab:9"])
        XCTAssertNil(literal.tab)
        XCTAssertFalse(literal.raw)
        XCTAssertEqual(try literal.text(), "--bogus --raw --tab tab:9")
    }

    func testUnknownFlagsAndMissingTargetsAreErrorsRatherThanText() {
        for arguments in [["--bogus", "hello"], ["hello", "--text", "hi"],
                          ["--tab"], ["--tab", ""], ["--workspace", "--raw", "hello"]] {
            XCTAssertThrowsError(try SendTextParse.parse(arguments)) { error in
                XCTAssertTrue(String(describing: error).contains(arguments.first(where: { $0.hasPrefix("--") })!))
            }
        }
        XCTAssertThrowsError(try SendTextParse.parse([]))
        XCTAssertThrowsError(try SendTextParse.parse(["-", "extra"]))
    }

    func testStdinIsExplicitForSendAndDefaultForPaste() throws {
        let bytes = Data("\nline1\nline2\r\n".utf8)
        for arguments in [["--raw", "-"], ["--no-submit", "-"]] {
            let parsed = try SendTextParse.parse(arguments)
            XCTAssertEqual(parsed.input, .stdin)
            XCTAssertEqual(try parsed.text(stdin: bytes), String(decoding: bytes, as: UTF8.self))
        }
        let paste = try SendTextParse.parse(["--no-submit"], paste: true)
        XCTAssertEqual(paste.input, .stdin)
        XCTAssertTrue(paste.raw)
        XCTAssertFalse(paste.submit)
        XCTAssertEqual(try paste.text(stdin: bytes), "\nline1\nline2\r\n")
        XCTAssertThrowsError(try paste.text(stdin: Data()))
        XCTAssertThrowsError(try paste.text(stdin: Data([0xff])))
    }

    func testNewlinePolicyForAttachedAndQueuedDelivery() {
        for text in ["\nline1\nline2\r\n", "\n", "\r\n", "literal\\n", "body"] {
            let raw = SendTextDelivery(text, submit: false, preserveNewlines: true)
            XCTAssertEqual(raw.body, text)
            XCTAssertFalse(raw.wantsReturn)
            XCTAssertTrue(SendTextDelivery(text, submit: true, preserveNewlines: true).wantsReturn)
        }
        let legacy = SendTextDelivery("\nline1\nline2\r\n", submit: false)
        XCTAssertEqual(legacy.body, "\nline1\nline2")
        XCTAssertTrue(legacy.wantsReturn)
        XCTAssertFalse(SendTextDelivery("line1\nline2", submit: false).wantsReturn)
        XCTAssertEqual(SendTextDelivery("\r\n", submit: false).body, "")
        XCTAssertTrue(SendTextDelivery("\r\n", submit: false).wantsReturn)
    }

    func testDeliverySummaryDescribesTransportAndScheduledReturn() {
        XCTAssertEqual(SendTextDelivery.summary(queued: false, submitted: true), "delivered, return scheduled")
        XCTAssertEqual(SendTextDelivery.summary(queued: false, submitted: false), "delivered, not submitted")
        for submitted in [true, false] {
            let summary = SendTextDelivery.summary(queued: true, submitted: submitted)
            XCTAssertTrue(summary.hasPrefix("queued, not delivered"))
            XCTAssertTrue(summary.contains("has not seen it"))
        }
    }
}
