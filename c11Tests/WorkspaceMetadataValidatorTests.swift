import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
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

    func testCustomValuesUseObjectCapRatherThanLegacyStringCap() throws {
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validate(key: "note", value: String(repeating: "a", count: 4096)))
        XCTAssertNoThrow(try WorkspaceMetadataValidator.validate(key: "custom", value: ["nested": [true, false]]))
        XCTAssertThrowsError(try WorkspaceMetadataValidator.validate(key: "icon", value: 7))
    }

    func testCaptainNormalizesOnlySurroundingSpacesAndKeepsAddressOpaque() throws {
        XCTAssertEqual(try WorkspaceMetadataValidator.normalizedCaptain("  agent:Captain@Case/1  "), "agent:Captain@Case/1")
        XCTAssertNoThrow(try WorkspaceMetadataValidator.normalizedCaptain(String(repeating: "é", count: 128)))
        for invalid: Any in ["", "  ", "agent\n", "agent\tname", String(repeating: "é", count: 129), 42, NSNull()] {
            XCTAssertThrowsError(try WorkspaceMetadataValidator.normalizedCaptain(invalid))
        }
    }
}
