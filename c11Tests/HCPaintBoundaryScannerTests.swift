import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Paint layout of hc 0.1.16 (`viewers.rs` `paint_state`, `ghostty-vt`
/// `Terminal::paint`), assembled from its parts so each case can vary one.
enum HCPaintFixture {
    static let esc = "\u{1b}"

    static func paint(
        history: [String] = [],
        altScreen: Bool = false,
        screen: [String] = ["\u{1b}[0m% ", "\u{1b}[1;32mready\u{1b}[0m"],
        title: String? = "zsh",
        win32: Bool = false,
        statuses: [String] = ["\u{1b}]7501;state=idle\u{1b}\\"],
        continuation: String? = nil
    ) -> Data {
        var out = Data(HCPaintBoundaryScanner.prelude)
        if !history.isEmpty, !altScreen {
            out += Data(history.joined(separator: "\r\n").utf8)
            out += Data("\(esc)[0m\r\n".utf8) + Data(String(repeating: "\n", count: 24).utf8)
            out += Data("\(esc)[H\(esc)[2J".utf8)
        }
        if altScreen { out += Data("\(esc)[?1049h".utf8) }
        // The formatter's own modes and cursor, as `Terminal::paint` keeps them.
        out += Data("\(esc)[?25h\(esc)[?7h".utf8)
        out += Data(screen.joined(separator: "\r\n").utf8)
        out += Data("\(esc)[3;5H".utf8)
        if let title { out += Data("\(esc)]2;\(title)\(esc)\\".utf8) }
        out += Data((win32 ? "\(esc)[?9001h" : "\(esc)[?9001l").utf8)
        for status in statuses { out += Data(status.utf8) }
        if let continuation { out += Data(continuation.utf8) }
        return out
    }

    /// Offset just past the paint's `CSI ? 9001 h|l`.
    static func markerEnd(in data: Data, from start: Int = 0) -> Int {
        let bytes = [UInt8](data)
        let marker = HCPaintBoundaryScanner.endMarker
        var i = start
        while i + marker.count < bytes.count {
            if Array(bytes[i..<(i + marker.count)]) == marker, bytes[i + marker.count] == 0x68 || bytes[i + marker.count] == 0x6c {
                return i + marker.count + 1
            }
            i += 1
        }
        return -1
    }
}

final class HCPaintBoundaryScannerTests: XCTestCase {
    private let pin = "0.1.16"

    private func scanned(_ chunks: [Data]) -> HCPaintBoundaryScanner {
        var scanner = HCPaintBoundaryScanner(pinVersion: pin)
        for chunk in chunks { scanner.scan(chunk) }
        return scanner
    }

    func testPaintEndsAtItsMarkerAtEverySplitPoint() {
        let paint = HCPaintFixture.paint(history: (1...40).map { "hist-\($0)" }, continuation: "\u{1b}[3")
        let live = Data("live \u{1b}[?9001h more".utf8)
        let stream = paint + live
        let end = HCPaintFixture.markerEnd(in: stream)
        XCTAssertGreaterThan(end, 0)
        for split in 0...stream.count {
            let scanner = scanned([stream.prefix(split), stream.dropFirst(split)].map { Data($0) })
            XCTAssertEqual(scanner.phase, .painted(watermark: UInt64(end)), "split at \(split)")
            XCTAssertEqual(scanner.completedPaints, 1, "split at \(split)")
        }
    }

    func testOneByteChunksStillFindTheBoundary() {
        let stream = HCPaintFixture.paint(altScreen: true, win32: true)
        var scanner = HCPaintBoundaryScanner(pinVersion: pin)
        let end = HCPaintFixture.markerEnd(in: stream)
        for (index, byte) in stream.enumerated() {
            scanner.scan(Data([byte]))
            if index + 1 < end {
                XCTAssertFalse(scanner.isPainted, "painted early at byte \(index)")
            }
        }
        XCTAssertEqual(scanner.phase, .painted(watermark: UInt64(end)))
    }

    func testNotPaintedUntilTheMarkerIsParsed() {
        let paint = HCPaintFixture.paint()
        let end = HCPaintFixture.markerEnd(in: paint)
        let scanner = scanned([Data(paint.prefix(end - 1))])
        XCTAssertEqual(scanner.phase, .inPaint)
    }

    func testAStreamThatDoesNotOpenWithAPaintIsUnprovable() {
        // Live bytes first (no prelude), even with a 9001 sequence in them.
        let scanner = scanned([Data("hello \u{1b}[?9001l world".utf8)])
        XCTAssertEqual(scanner.phase, .unprovable)
    }

    func testThePreludeWithoutCANIsNotAPaint() {
        let withoutCAN = Data(HCPaintFixture.paint().dropFirst())
        XCTAssertEqual(scanned([withoutCAN]).phase, .unprovable)
    }

    func testAMarkerBeforeAnyPreludeNeverProves() {
        // Unprovable from the start; a 9001 in live output must not flip it.
        var scanner = scanned([Data("x".utf8)])
        scanner.scan(Data("\u{1b}[?9001h\u{1b}[?9001l".utf8))
        XCTAssertEqual(scanner.phase, .unprovable)
    }

    func testALaterRepaintMakesAnUnprovableStreamProvable() {
        let lead = Data("stray output".utf8)
        let paint = HCPaintFixture.paint()
        let stream = lead + paint
        let scanner = scanned([stream])
        XCTAssertEqual(scanner.phase, .painted(watermark: UInt64(HCPaintFixture.markerEnd(in: stream))))
    }

    func testAMidStreamRepaintRevokesUntilItsOwnMarker() {
        let first = HCPaintFixture.paint()
        let live = Data("typed\r\n".utf8)
        let second = HCPaintFixture.paint(screen: ["repainted"])
        var scanner = scanned([first + live])
        XCTAssertTrue(scanner.isPainted)

        let secondEnd = HCPaintFixture.markerEnd(in: second)
        scanner.scan(Data(second.prefix(secondEnd - 2)))
        XCTAssertEqual(scanner.phase, .inPaint, "a repaint in progress must revoke the receipt")
        scanner.scan(Data(second.dropFirst(secondEnd - 2)))
        XCTAssertEqual(scanner.phase, .painted(watermark: UInt64(first.count + live.count + secondEnd)))
        XCTAssertEqual(scanner.completedPaints, 2)
    }

    func testARepaintThatCutsAnEarlierPaintShortRestarts() {
        // A dropped backlog: part of the first paint went out, then a new paint.
        let first = HCPaintFixture.paint(history: ["a", "b"])
        let cut = Data(first.prefix(HCPaintFixture.markerEnd(in: first) - 4))
        let second = HCPaintFixture.paint()
        let scanner = scanned([cut, second])
        XCTAssertEqual(scanner.phase, .painted(watermark: UInt64(cut.count + HCPaintFixture.markerEnd(in: second))))
        XCTAssertEqual(scanner.completedPaints, 1)
    }

    func testARepaintSplitAnywhereInItsPreludeRevokesAtOnce() {
        // hc replaces a dropped backlog with a new paint and chunks stream
        // bytes by credit, so a prelude can arrive cut at any byte.
        let first = HCPaintFixture.paint()
        let second = HCPaintFixture.paint(screen: ["repainted"])
        let secondEnd = HCPaintFixture.markerEnd(in: second)
        for split in 1..<HCPaintBoundaryScanner.prelude.count {
            var scanner = scanned([first])
            XCTAssertTrue(scanner.isPainted)
            scanner.scan(Data(second.prefix(split)))
            XCTAssertFalse(scanner.isPainted, "a half-parsed prelude (split at \(split)) still read as painted")
            scanner.scan(Data(second.dropFirst(split)))
            XCTAssertEqual(scanner.phase, .painted(watermark: UInt64(first.count + secondEnd)), "split at \(split)")
        }
    }

    func testACANThatStartsNoPaintRestoresTheEarlierReceipt() {
        let first = HCPaintFixture.paint()
        var scanner = scanned([first])
        scanner.scan(Data([0x18]))
        XCTAssertEqual(scanner.phase, .inPrelude)
        scanner.scan(Data("x\r\n".utf8))
        XCTAssertEqual(scanner.phase, .painted(watermark: UInt64(HCPaintFixture.markerEnd(in: first))))
    }

    func testAnUnreadPinIsNeverPainted() {
        var scanner = HCPaintBoundaryScanner(pinVersion: "0.1.17")
        scanner.scan(HCPaintFixture.paint())
        XCTAssertEqual(scanner.phase, .unprovable)
        XCTAssertEqual(scanner.scannedBytes, UInt64(HCPaintFixture.paint().count))
    }

    func testAnOversizedPaintBecomesUnprovable() {
        var scanner = HCPaintBoundaryScanner(pinVersion: pin)
        scanner.scan(Data(HCPaintBoundaryScanner.prelude))
        let block = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0...Int(HCPaintBoundaryScanner.maxPaintBytes / UInt64(block.count)) { scanner.scan(block) }
        scanner.scan(Data("\u{1b}[?9001l".utf8))
        XCTAssertEqual(scanner.phase, .unprovable)
    }
}

final class HCScreenTrackerTests: XCTestCase {
    private let pin = "0.1.16"
    private let grid = HCGridSize(columns: 80, rows: 24)

    private func chunk(_ data: Data, generation: UInt64 = 1, watermark: UInt64 = 0) -> HCOutputChunk {
        HCOutputChunk(attachmentGeneration: generation, watermark: watermark, bytes: data)
    }

    private func revision(_ display: UInt64, generation: UInt64 = 1) -> HCDisplayRevision {
        HCDisplayRevision(attachmentGeneration: generation, displayGeneration: display)
    }

    func testReceiptOnlyAfterTheWholePaintIsParsed() async {
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 5)
        tracker.noteDisplaySent(revision(1), grid: grid)
        tracker.noteSurfaceGrid(grid)
        let paint = HCPaintFixture.paint()
        let end = HCPaintFixture.markerEnd(in: paint)
        tracker.didParse(chunk(Data(paint.prefix(end - 1))))

        let waiter = Task { await tracker.screenCurrent(after: revision(1)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        tracker.didParse(chunk(Data(paint.dropFirst(end - 1))))
        let receipt = await waiter.value
        XCTAssertEqual(receipt?.columns, 80)
        XCTAssertEqual(receipt?.rows, 24)
        XCTAssertEqual(receipt?.revision, revision(1))
        XCTAssertEqual(receipt?.parsedOutputWatermark, UInt64(paint.count))
    }

    func testNoReceiptFromAPartialPaintWithinTheBound() async {
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 0.2)
        tracker.noteDisplaySent(revision(1), grid: grid)
        tracker.noteSurfaceGrid(grid)
        let paint = HCPaintFixture.paint()
        tracker.didParse(chunk(Data(paint.prefix(HCPaintFixture.markerEnd(in: paint) - 1))))
        let started = Date()
        let receipt = await tracker.screenCurrent(after: revision(1))
        XCTAssertNil(receipt)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the wait must be bounded")
    }

    func testEarlyBytesBeforeTheDisplayIsRecordedStillCount() async {
        // 2B may deliver the first paint before the channel registers; the
        // paint is parsed before the attach reply is processed on main.
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 2)
        tracker.didParse(chunk(HCPaintFixture.paint()))
        tracker.noteSurfaceGrid(grid)
        tracker.noteDisplaySent(revision(1), grid: grid)
        let receipt = await tracker.screenCurrent(after: revision(1))
        XCTAssertNotNil(receipt)
    }

    func testAGridMismatchHoldsTheReceiptUntilTheGridsAgree() async {
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 2)
        tracker.noteDisplaySent(revision(1), grid: grid)
        tracker.noteSurfaceGrid(HCGridSize(columns: 76, rows: 24))
        tracker.didParse(chunk(HCPaintFixture.paint()))
        let waiter = Task { await tracker.screenCurrent(after: revision(1)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        tracker.noteSurfaceGrid(grid)
        let receipt = await waiter.value
        XCTAssertEqual(receipt?.columns, 80)
    }

    func testAGridMismatchThatNeverClearsGivesNil() async {
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 0.2)
        tracker.noteDisplaySent(revision(1), grid: grid)
        tracker.noteSurfaceGrid(HCGridSize(columns: 76, rows: 24))
        tracker.didParse(chunk(HCPaintFixture.paint()))
        let receipt = await tracker.screenCurrent(after: revision(1))
        XCTAssertNil(receipt)
    }

    func testAnotherAttachmentGenerationIsRefusedAtOnce() async {
        let tracker = HCScreenTracker(attachmentGeneration: 2, pinVersion: pin, timeout: 5)
        tracker.noteDisplaySent(revision(1, generation: 2), grid: grid)
        tracker.noteSurfaceGrid(grid)
        tracker.didParse(chunk(HCPaintFixture.paint(), generation: 2))
        let started = Date()
        let receipt = await tracker.screenCurrent(after: revision(1, generation: 1))
        XCTAssertNil(receipt)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testBytesFromAnOldGenerationAreIgnored() async {
        let tracker = HCScreenTracker(attachmentGeneration: 2, pinVersion: pin, timeout: 0.2)
        tracker.noteDisplaySent(revision(1, generation: 2), grid: grid)
        tracker.noteSurfaceGrid(grid)
        tracker.didParse(chunk(HCPaintFixture.paint(), generation: 1))
        let receipt = await tracker.screenCurrent(after: revision(1, generation: 2))
        XCTAssertNil(receipt)
    }

    func testALaterDisplayRevisionWaitsForItsDisplayToBeSent() async {
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 2)
        tracker.noteDisplaySent(revision(1), grid: grid)
        tracker.noteSurfaceGrid(grid)
        tracker.didParse(chunk(HCPaintFixture.paint()))
        let waiter = Task { await tracker.screenCurrent(after: revision(3)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let bigger = HCGridSize(columns: 100, rows: 30)
        tracker.noteSurfaceGrid(bigger)
        tracker.noteDisplaySent(revision(3), grid: bigger)
        let receipt = await waiter.value
        XCTAssertEqual(receipt?.revision, revision(3))
        XCTAssertEqual(receipt?.columns, 100)
    }

    /// Never fires: only `invalidate()` can answer a pending request.
    private let held: HCScreenTracker.Scheduler = { _, _ in }

    func testInvalidateAnswersPendingWaitersWithNil() async {
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 30, schedule: held)
        let box = HCReceiptBox()
        let done = expectation(description: "pending request answered")
        Task {
            box.set(await tracker.screenCurrent(after: revision(1)))
            done.fulfill()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        tracker.invalidate()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(box.answered)
        XCTAssertNil(box.value)
    }

    func testAnInvalidatedTrackerNeverIssuesAReceiptEvenOnceReady() async {
        // In-flight work (a parse, a display send) may still reach a tracker
        // after its attachment was replaced or detached.
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 30, schedule: held)
        tracker.invalidate()
        tracker.didParse(chunk(HCPaintFixture.paint()))
        tracker.noteDisplaySent(revision(1), grid: grid)
        tracker.noteSurfaceGrid(grid)
        let box = HCReceiptBox()
        let done = expectation(description: "request answered")
        Task {
            box.set(await tracker.screenCurrent(after: revision(1)))
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(box.value)
    }

    func testAReceiptIsNotIssuedWhileARepaintPreludeIsHalfParsed() async {
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 0.2)
        tracker.noteDisplaySent(revision(1), grid: grid)
        tracker.noteSurfaceGrid(grid)
        tracker.didParse(chunk(HCPaintFixture.paint()))
        let before = await tracker.screenCurrent(after: revision(1))
        XCTAssertNotNil(before)
        // Split right after the prelude's CSI ? 1049 l: Ghostty has left the
        // alternate screen, the application's screen is not rebuilt yet.
        let second = HCPaintFixture.paint()
        let prelude = HCPaintBoundaryScanner.prelude
        let cut = [UInt8](Data("\u{1b}[?1049l".utf8))
        var split = 0
        for i in 0...(prelude.count - cut.count) where Array(prelude[i..<(i + cut.count)]) == cut { split = i + cut.count }
        XCTAssertGreaterThan(split, 0)
        tracker.didParse(chunk(Data(second.prefix(split))))
        let during = await tracker.screenCurrent(after: revision(1))
        XCTAssertNil(during, "the old screen is exposed mid-repaint; it is not current")
        tracker.didParse(chunk(Data(second.dropFirst(split))))
        let after = await tracker.screenCurrent(after: revision(1))
        XCTAssertNotNil(after)
    }

    func testAMidStreamRepaintRevokesTheReceipt() async {
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, timeout: 0.2)
        tracker.noteDisplaySent(revision(1), grid: grid)
        tracker.noteSurfaceGrid(grid)
        tracker.didParse(chunk(HCPaintFixture.paint()))
        let first = await tracker.screenCurrent(after: revision(1))
        XCTAssertNotNil(first)
        let second = HCPaintFixture.paint()
        tracker.didParse(chunk(Data(second.prefix(HCPaintFixture.markerEnd(in: second) - 1))))
        let during = await tracker.screenCurrent(after: revision(1))
        XCTAssertNil(during, "a half-parsed repaint is not a current screen")
    }

    func testOnPaintedFiresOncePerCompletedPaint() {
        let count = HCAtomicCounter()
        let tracker = HCScreenTracker(attachmentGeneration: 1, pinVersion: pin, onPainted: { _ in count.increment() })
        let paint = HCPaintFixture.paint()
        for byte in paint { tracker.didParse(chunk(Data([byte]))) }
        tracker.didParse(chunk(Data("live output".utf8)))
        XCTAssertEqual(count.value, 1)
        tracker.didParse(chunk(HCPaintFixture.paint()))
        XCTAssertEqual(count.value, 2)
    }
}

final class HCReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var receipt: HCScreenReceipt?
    private var done = false
    func set(_ value: HCScreenReceipt?) { lock.lock(); receipt = value; done = true; lock.unlock() }
    var value: HCScreenReceipt? { lock.lock(); defer { lock.unlock() }; return receipt }
    var answered: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

final class HCAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
