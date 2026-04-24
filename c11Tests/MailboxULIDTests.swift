import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MailboxULIDTests: XCTestCase {

    // MARK: - Shape

    func testLengthIs26() {
        XCTAssertEqual(MailboxULID.make().count, 26)
    }

    func testCharsetIsCrockfordBase32() {
        // Crockford base32 excludes I, L, O, U to avoid ambiguity.
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for _ in 0..<256 {
            let ulid = MailboxULID.make()
            XCTAssertNil(
                ulid.rangeOfCharacter(from: allowed.inverted),
                "ulid \(ulid) contained a disallowed character"
            )
        }
    }

    // MARK: - Sort + monotonicity

    /// 10k IDs generated in rapid succession must be in ascending lex order —
    /// that's the primary contract of a ULID and the reason the dispatch log
    /// tails are human-readable chronologically.
    func testSortStabilityOver10kGenerations() {
        var ulids: [String] = []
        ulids.reserveCapacity(10_000)
        for _ in 0..<10_000 {
            ulids.append(MailboxULID.make())
        }
        XCTAssertEqual(ulids, ulids.sorted(), "ULIDs must be generated in sort order")
    }

    func testUniquenessOver10kGenerations() {
        var ulids = Set<String>()
        for _ in 0..<10_000 {
            ulids.insert(MailboxULID.make())
        }
        XCTAssertEqual(ulids.count, 10_000, "every ULID must be unique")
    }

    // MARK: - Encoding

    func testTimestampEncodedAsBigEndian() {
        // Zero timestamp encodes as ten '0' chars.
        let zeros = MailboxULID.encode(
            timestampMs: 0,
            random: [UInt8](repeating: 0, count: MailboxULID.randomByteCount)
        )
        XCTAssertEqual(String(zeros.prefix(10)), "0000000000")
        XCTAssertEqual(zeros.count, 26)

        // Distinct timestamps produce distinct timestamp prefixes.
        let ts1 = MailboxULID.encode(
            timestampMs: 1,
            random: [UInt8](repeating: 0, count: MailboxULID.randomByteCount)
        )
        XCTAssertNotEqual(String(ts1.prefix(10)), "0000000000")
    }

    func testRandomFillEncodesAllOnesAsPattern() {
        // All-one random bytes (80 bits) should produce 16 'Z' chars (31 = Z).
        let allOnes = [UInt8](repeating: 0xFF, count: MailboxULID.randomByteCount)
        let ulid = MailboxULID.encode(timestampMs: 0, random: allOnes)
        XCTAssertEqual(String(ulid.suffix(16)), "ZZZZZZZZZZZZZZZZ")
    }

    func testIncrementIsMonotonic() {
        let zero = [UInt8](repeating: 0, count: MailboxULID.randomByteCount)
        let one = MailboxULID.increment(zero)
        XCTAssertEqual(one.last, 1)
        XCTAssertEqual(Array(one.dropLast()), [UInt8](repeating: 0, count: zero.count - 1))
    }

    func testIncrementCarries() {
        var bytes = [UInt8](repeating: 0, count: MailboxULID.randomByteCount)
        bytes[bytes.count - 1] = 0xFF
        let rolled = MailboxULID.increment(bytes)
        XCTAssertEqual(rolled.last, 0, "low byte wraps on carry")
        XCTAssertEqual(rolled[rolled.count - 2], 1, "carry propagates up one slot")
    }
}
