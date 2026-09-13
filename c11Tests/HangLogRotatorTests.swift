import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral tests for `HangLogRotator`, the size cap behind the local hang
/// log. Everything runs against a real temp directory: the rotator's whole job
/// is filesystem bookkeeping, so a fake filesystem would test nothing.
///
/// Payloads are runs of a single uppercase letter chosen to be absent from the
/// rotation header, which makes "which generation holds which episode" a
/// straight substring check.
final class HangLogRotatorTests: XCTestCase {

    private var directory: URL!
    private var logURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-hang-rotator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("hang.log")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private static let stampedHeaderPrefix = "=== c11 hang.rotated TS previous="

    private func makeRotator(
        cap: Int,
        generations: Int = 2,
        sizeProbe: @escaping HangLogRotator.SizeProbe = HangLogRotator.fileSize
    ) -> HangLogRotator {
        HangLogRotator(
            logURL: logURL,
            capBytes: cap,
            generations: generations,
            timestamp: { "TS" },
            sizeProbe: sizeProbe
        )
    }

    /// `count` bytes of a single ASCII letter, so byte length equals `count`.
    private func payload(_ marker: Character, _ count: Int) -> String {
        String(repeating: String(marker), count: count)
    }

    private func generation(_ index: Int) -> URL {
        URL(fileURLWithPath: logURL.path + ".\(index)")
    }

    private func text(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func byteCount(_ url: URL) -> Int {
        (try? Data(contentsOf: url))?.count ?? 0
    }

    private func directoryFileNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names)
    }

    private func totalFootprint() -> Int {
        directoryFileNames().reduce(0) { $0 + byteCount(directory.appendingPathComponent($1)) }
    }

    // MARK: Tests

    func testAppendsUnderTheCapNeverRotate() {
        var rotator = makeRotator(cap: 4096)
        rotator.append(payload("X", 100))
        rotator.append(payload("Y", 100))
        rotator.append(payload("Z", 100), episodeBoundary: true)

        XCTAssertEqual(byteCount(logURL), 300)
        XCTAssertEqual(directoryFileNames(), ["hang.log"])
        XCTAssertFalse(text(logURL).contains("hang.rotated"))
    }

    func testCrossingTheCapRotatesOnceAndHeadsTheNewFile() {
        var rotator = makeRotator(cap: 1000)
        rotator.append(payload("X", 600))
        rotator.append(payload("Y", 600))

        // The record that would have overflowed the cap opened a new file.
        XCTAssertEqual(text(generation(1)), payload("X", 600))
        XCTAssertFalse(exists(generation(2)))

        let live = text(logURL)
        XCTAssertTrue(
            live.hasPrefix(Self.stampedHeaderPrefix + "hang.log.1 capBytes=1000 ===\n"),
            "new file should open with the rotation header, got: \(live.prefix(120))"
        )
        XCTAssertTrue(live.contains(payload("Y", 600)))
        XCTAssertFalse(live.contains("X"))
    }

    func testGenerationsShiftDownAndTheOldestIsDeleted() {
        var rotator = makeRotator(cap: 1000, generations: 2)
        for marker in ["X", "Y", "Z", "W"] {
            rotator.append(payload(Character(marker), 600))
        }

        // Four 600-byte records against a 1000-byte cap means three rotations.
        XCTAssertTrue(text(logURL).contains(payload("W", 600)))
        XCTAssertTrue(text(generation(1)).contains(payload("Z", 600)))
        XCTAssertTrue(text(generation(2)).contains(payload("Y", 600)))
        XCTAssertFalse(exists(generation(3)))

        // X was the oldest and has been dropped off the end.
        for name in directoryFileNames() {
            XCTAssertFalse(
                text(directory.appendingPathComponent(name)).contains("X"),
                "\(name) still holds the evicted generation"
            )
        }
    }

    func testFootprintStaysBoundedAcrossManyRotations() {
        let cap = 4096
        var rotator = makeRotator(cap: cap, generations: 2)
        for index in 0..<200 {
            rotator.append(payload("X", 500), episodeBoundary: index % 5 == 4)
        }

        XCTAssertTrue(
            directoryFileNames().isSubset(of: ["hang.log", "hang.log.1", "hang.log.2"]),
            "unexpected files left behind: \(directoryFileNames())"
        )
        for name in directoryFileNames() {
            XCTAssertLessThanOrEqual(byteCount(directory.appendingPathComponent(name)), cap)
        }
        // 100 KB written, ~12 KB retained.
        XCTAssertLessThanOrEqual(totalFootprint(), 3 * cap)
    }

    func testRotationWaitsForTheEpisodeBoundaryPastTheSoftCap() {
        var rotator = makeRotator(cap: 1000)
        // 800 bytes is past the 750-byte soft cap but under the hard cap.
        rotator.append(payload("X", 800))
        XCTAssertFalse(exists(generation(1)), "mid-episode append must not rotate below the hard cap")
        XCTAssertEqual(byteCount(logURL), 800)

        rotator.append(payload("Y", 50), episodeBoundary: true)

        // The closing record joined its own episode before the file rotated.
        let archived = text(generation(1))
        XCTAssertEqual(archived, payload("X", 800) + payload("Y", 50))

        let live = text(logURL)
        XCTAssertTrue(live.hasPrefix(Self.stampedHeaderPrefix + "hang.log.1 capBytes=1000 ==="))
        XCTAssertFalse(live.contains("X"))
        XCTAssertFalse(live.contains("Y"))
    }

    func testASingleOversizedEpisodeStillRotatesMidEpisode() {
        let cap = 2000
        var rotator = makeRotator(cap: cap, generations: 2)
        // No boundary is ever reached: one unbroken episode of 40 KB.
        for _ in 0..<80 {
            rotator.append(payload("X", 500), episodeBoundary: false)
        }

        XCTAssertTrue(exists(generation(1)), "an episode that never ends must still rotate")
        for name in directoryFileNames() {
            XCTAssertLessThanOrEqual(byteCount(directory.appendingPathComponent(name)), cap)
        }
        XCTAssertLessThanOrEqual(totalFootprint(), 3 * cap)
    }

    func testFileSizeIsProbedExactlyOnceAcrossManyAppends() {
        var probes = 0
        var rotator = makeRotator(cap: 4096, sizeProbe: { url in
            probes += 1
            return HangLogRotator.fileSize(url)
        })
        for _ in 0..<25 {
            rotator.append(payload("X", 10))
        }

        XCTAssertEqual(probes, 1, "the rotator must stat the log once, not on every append")
        XCTAssertEqual(byteCount(logURL), 250)
    }

    func testAPreexistingOversizedLogIsDiscardedRatherThanArchived() throws {
        // Stands in for the uncapped log left by an older build.
        try Data(payload("X", 5000).utf8).write(to: logURL)

        let cap = 1000
        var rotator = makeRotator(cap: cap, generations: 2)
        rotator.append(payload("Y", 10))

        XCTAssertFalse(
            exists(generation(1)),
            "an already-oversized log must not be archived, or the footprint bound breaks"
        )
        let live = text(logURL)
        XCTAssertTrue(live.hasPrefix(Self.stampedHeaderPrefix + "discarded capBytes=1000 ==="))
        XCTAssertTrue(live.hasSuffix(payload("Y", 10)))
        XCTAssertLessThanOrEqual(totalFootprint(), 3 * cap)
    }

    func testCreatesTheLogDirectoryWhenItIsMissing() {
        logURL = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("hang.log")

        var rotator = makeRotator(cap: 4096)
        rotator.append(payload("X", 32))

        XCTAssertEqual(text(logURL), payload("X", 32))
    }

    func testANonPositiveCapDisablesRotationEntirely() {
        var rotator = makeRotator(cap: 0)
        for _ in 0..<20 {
            rotator.append(payload("X", 100), episodeBoundary: true)
        }

        XCTAssertEqual(byteCount(logURL), 2000)
        XCTAssertEqual(directoryFileNames(), ["hang.log"])
    }
}
