import Foundation
#if canImport(Security)
import Security
#endif

/// Crockford base32 ULID generator. 128 bits total:
///   * 48 bits millisecond timestamp (Unix epoch) → 10 chars, big-endian.
///   * 80 bits randomness → 16 chars, big-endian bit stream.
/// Monotonic within the same millisecond: when the timestamp matches the
/// prior call's timestamp, the 80-bit randomness is incremented by one
/// instead of sampled fresh. Guarantees lexicographic sort order of IDs
/// minted from a single process. See `MailboxULIDTests` for the contract.
enum MailboxULID {

    /// Crockford base32 alphabet: no I, L, O, U to avoid ambiguity with 1, 0, V.
    static let alphabet: [UInt8] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    static let totalLength = 26
    static let timestampLength = 10
    static let randomLength = 16
    static let randomByteCount = 10 // 80 bits

    private static let lock = NSLock()
    private static var lastTimestampMs: UInt64 = 0
    private static var lastRandom: [UInt8] = [UInt8](repeating: 0, count: MailboxULID.randomByteCount)

    /// Returns a fresh ULID string.
    static func make(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000) & 0x0000_FFFF_FFFF_FFFF

        let random: [UInt8] = lock.withLock {
            let candidate: [UInt8]
            if ms == lastTimestampMs {
                candidate = increment(lastRandom)
            } else {
                candidate = freshRandomBytes(count: randomByteCount)
            }
            lastTimestampMs = ms
            lastRandom = candidate
            return candidate
        }

        return encode(timestampMs: ms, random: random)
    }

    // MARK: - Internal helpers (exposed for testing)

    static func encode(timestampMs: UInt64, random: [UInt8]) -> String {
        precondition(
            random.count == randomByteCount,
            "random must be \(randomByteCount) bytes"
        )

        var out = [UInt8](repeating: 0, count: totalLength)

        // Timestamp: 10 base32 chars from the low 48 bits, big-endian.
        var ts = timestampMs & 0x0000_FFFF_FFFF_FFFF
        for i in (0..<timestampLength).reversed() {
            out[i] = alphabet[Int(ts & 0x1F)]
            ts >>= 5
        }

        // Random: 80 bits → 16 base32 chars. Stream-encode 5 bits at a time.
        var bits: UInt64 = 0
        var bitsCount: Int = 0
        var outIndex = timestampLength
        for byte in random {
            bits = (bits << 8) | UInt64(byte)
            bitsCount += 8
            while bitsCount >= 5 {
                bitsCount -= 5
                let chunk = Int((bits >> UInt64(bitsCount)) & 0x1F)
                // Keep only the unused low bits so the accumulator can't overflow.
                bits &= bitsCount > 0 ? (UInt64(1) << UInt64(bitsCount)) - 1 : 0
                out[outIndex] = alphabet[chunk]
                outIndex += 1
            }
        }

        return String(bytes: out, encoding: .ascii)!
    }

    static func increment(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        for i in (0..<out.count).reversed() {
            if out[i] < UInt8.max {
                out[i] &+= 1
                return out
            }
            out[i] = 0
        }
        // 2^80 increments within a single millisecond is not physical. If it
        // ever happens, fall back to a fresh sample rather than wrap silently.
        return freshRandomBytes(count: out.count)
    }

    static func freshRandomBytes(count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        precondition(status == errSecSuccess, "ULID random source failed")
        #else
        for i in 0..<count {
            out[i] = UInt8.random(in: 0...UInt8.max)
        }
        #endif
        return out
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
