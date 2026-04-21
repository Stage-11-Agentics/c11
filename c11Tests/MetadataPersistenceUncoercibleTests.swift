import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tier 1 Phase 2: values not representable as JSON must be dropped
/// silently (with a debug log) so the snapshot write never crashes.
/// The rest of the blob must survive.
final class MetadataPersistenceUncoercibleTests: XCTestCase {
    private final class CustomBox {
        let payload: Int
        init(_ p: Int) { self.payload = p }
    }

    func testCustomClassInstanceIsDroppedOtherValuesSurvive() {
        let blob: [String: Any] = [
            "good_string": "ok",
            "good_number": 42,
            "bad_custom": CustomBox(7)
        ]
        let encoded = PersistedMetadataBridge.encodeValues(blob)
        XCTAssertNil(encoded["bad_custom"])
        XCTAssertEqual(encoded["good_string"], .string("ok"))
        if case .number(let d)? = encoded["good_number"] {
            XCTAssertEqual(d, 42.0)
        } else {
            XCTFail("good_number should have survived as .number")
        }
    }

    func testNaNIsDroppedInfIsDroppedOthersSurvive() {
        let blob: [String: Any] = [
            "sane": 1.5,
            "nan": Double.nan,
            "pos_inf": Double.infinity,
            "neg_inf": -Double.infinity
        ]
        let encoded = PersistedMetadataBridge.encodeValues(blob)
        XCTAssertNil(encoded["nan"])
        XCTAssertNil(encoded["pos_inf"])
        XCTAssertNil(encoded["neg_inf"])
        if case .number(let d)? = encoded["sane"] {
            XCTAssertEqual(d, 1.5)
        } else {
            XCTFail("sane should have survived as .number")
        }
    }

    func testDateAndURLAreDropped() {
        let blob: [String: Any] = [
            "when": Date(timeIntervalSince1970: 0),
            "where": URL(string: "https://example.com")!,
            "survives": "hello"
        ]
        let encoded = PersistedMetadataBridge.encodeValues(blob)
        XCTAssertNil(encoded["when"])
        XCTAssertNil(encoded["where"])
        XCTAssertEqual(encoded["survives"], .string("hello"))
    }

    func testNestedArrayPreservesIndexStabilityOnDrop() {
        // Element-level drops should preserve positional semantics — a
        // dropped element becomes .null so indexing into the array stays
        // consistent for consumer code.
        let arr: [Any] = ["a", CustomBox(1), "c"]
        let blob: [String: Any] = ["tags": arr]
        let encoded = PersistedMetadataBridge.encodeValues(blob)
        guard case .array(let elements) = encoded["tags"] else {
            XCTFail("Expected .array")
            return
        }
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[0], .string("a"))
        XCTAssertEqual(elements[1], .null)
        XCTAssertEqual(elements[2], .string("c"))
    }

    func testNestedObjectDropsKeysIndividually() {
        let inner: [String: Any] = [
            "keep": "yes",
            "drop": Double.nan
        ]
        let blob: [String: Any] = ["obj": inner]
        let encoded = PersistedMetadataBridge.encodeValues(blob)
        guard case .object(let o) = encoded["obj"] else {
            XCTFail("Expected .object")
            return
        }
        XCTAssertEqual(o["keep"], .string("yes"))
        XCTAssertNil(o["drop"])
    }
}
