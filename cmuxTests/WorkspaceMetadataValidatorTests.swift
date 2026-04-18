import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceMetadataValidatorTests: XCTestCase {
    func testAcceptsCanonicalDescriptionAtMaxLen() throws {
        let value = String(repeating: "a", count: WorkspaceMetadataValidator.maxDescriptionLen)
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validate(
            key: WorkspaceMetadataKey.description,
            value: value
        ))
    }

    func testRejectsDescriptionOverMaxLen() {
        let value = String(repeating: "a", count: WorkspaceMetadataValidator.maxDescriptionLen + 1)
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validate(
            key: WorkspaceMetadataKey.description,
            value: value
        )) { error in
            guard let err = error as? WorkspaceMetadataValidator.ValidationError else {
                XCTFail("Expected ValidationError, got \(error)")
                return
            }
            XCTAssertEqual(
                err,
                .valueTooLong(
                    key: WorkspaceMetadataKey.description,
                    limit: WorkspaceMetadataValidator.maxDescriptionLen
                )
            )
        }
    }

    func testAcceptsIconAtMaxLen() throws {
        let value = String(repeating: "x", count: WorkspaceMetadataValidator.maxIconLen)
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validate(
            key: WorkspaceMetadataKey.icon,
            value: value
        ))
    }

    func testRejectsIconOverMaxLen() {
        let value = String(repeating: "x", count: WorkspaceMetadataValidator.maxIconLen + 1)
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validate(
            key: WorkspaceMetadataKey.icon,
            value: value
        ))
    }

    func testAcceptsEmojiValues() throws {
        // Emoji-with-modifier + ZWJ sequences commonly have count > 1 unit even
        // though they look like a single glyph. Confirm they pass within caps.
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validate(
            key: WorkspaceMetadataKey.icon,
            value: "🦊"
        ))
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validate(
            key: WorkspaceMetadataKey.icon,
            value: "👍🏽"
        ))
    }

    func testCustomKeyAcceptsValidGrammar() throws {
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validate(key: "project.id", value: "abc"))
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validate(key: "My-Key_1", value: "abc"))
    }

    func testRejectsEmptyKey() {
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validate(key: "", value: "ok")) { err in
            XCTAssertEqual(err as? WorkspaceMetadataValidator.ValidationError, .emptyKey)
        }
    }

    func testRejectsKeyWithWhitespace() {
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validate(key: "my key", value: "ok")) { err in
            XCTAssertEqual(err as? WorkspaceMetadataValidator.ValidationError, .keyInvalidCharacters)
        }
    }

    func testRejectsKeyWithNonASCII() {
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validate(key: "キー", value: "ok")) { err in
            XCTAssertEqual(err as? WorkspaceMetadataValidator.ValidationError, .keyInvalidCharacters)
        }
    }

    func testRejectsKeyOverMaxLen() {
        let key = String(repeating: "a", count: WorkspaceMetadataValidator.maxCustomKeyLen + 1)
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validate(key: key, value: "ok")) { err in
            XCTAssertEqual(
                err as? WorkspaceMetadataValidator.ValidationError,
                .keyTooLong(limit: WorkspaceMetadataValidator.maxCustomKeyLen)
            )
        }
    }

    func testRejectsCustomValueOverMaxLen() {
        let value = String(repeating: "a", count: WorkspaceMetadataValidator.maxCustomValueLen + 1)
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validate(key: "note", value: value)) { err in
            XCTAssertEqual(
                err as? WorkspaceMetadataValidator.ValidationError,
                .valueTooLong(key: "note", limit: WorkspaceMetadataValidator.maxCustomValueLen)
            )
        }
    }

    func testCapacityAcceptsCanonicalPlusCustomAtLimit() throws {
        var map: [String: String] = [
            WorkspaceMetadataKey.description: "desc",
            WorkspaceMetadataKey.icon: "🦊"
        ]
        for i in 0..<WorkspaceMetadataValidator.maxCustomKeys {
            map["custom_\(i)"] = "value"
        }
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validateCapacity(after: map))
    }

    func testCapacityRejectsOverCustomKeyLimit() {
        var map: [String: String] = [:]
        for i in 0..<(WorkspaceMetadataValidator.maxCustomKeys + 1) {
            map["custom_\(i)"] = "value"
        }
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validateCapacity(after: map)) { err in
            XCTAssertEqual(
                err as? WorkspaceMetadataValidator.CapacityError,
                .tooManyKeys(limit: WorkspaceMetadataValidator.maxCustomKeys)
            )
        }
    }
}
