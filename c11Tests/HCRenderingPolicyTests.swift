import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class HCResizeCoordinatorTests: XCTestCase {
    private var pending: [@MainActor () -> Void] = []
    private var grid: HCGridSize? = HCGridSize(columns: 80, rows: 24)
    private var settled: [HCGridSize] = []

    private func makeCoordinator() -> HCResizeCoordinator {
        HCResizeCoordinator(
            schedule: { [unowned self] _, work in self.pending.append(work) },
            readGrid: { [unowned self] in self.grid },
            settled: { [unowned self] grid in self.settled.append(grid) }
        )
    }

    private func runPending() {
        let work = pending
        pending.removeAll()
        for item in work { item() }
    }

    func testABurstSettlesOnceWithTheLatestGrid() {
        let coordinator = makeCoordinator()
        grid = HCGridSize(columns: 70, rows: 24)
        coordinator.noteSizeChanged()
        grid = HCGridSize(columns: 60, rows: 20)
        coordinator.noteSizeChanged()
        grid = HCGridSize(columns: 57, rows: 42)
        coordinator.noteSizeChanged()
        runPending()
        XCTAssertEqual(settled, [HCGridSize(columns: 57, rows: 42)])
    }

    func testTheDebounceIsTheSpikes40Milliseconds() {
        var delays: [TimeInterval] = []
        let coordinator = HCResizeCoordinator(
            schedule: { delay, _ in delays.append(delay) },
            readGrid: { nil }, settled: { _ in }
        )
        coordinator.noteSizeChanged()
        XCTAssertEqual(delays, [0.040])
    }

    func testShrinkThenGrowSettlesEachGrid() {
        let coordinator = makeCoordinator()
        grid = HCGridSize(columns: 43, rows: 16)
        coordinator.noteSizeChanged(); runPending()
        grid = HCGridSize(columns: 80, rows: 24)
        coordinator.noteSizeChanged(); runPending()
        XCTAssertEqual(settled, [HCGridSize(columns: 43, rows: 16), HCGridSize(columns: 80, rows: 24)])
    }

    func testAttachmentReadySettlesTheCurrentGridAtOnce() {
        let coordinator = makeCoordinator()
        grid = HCGridSize(columns: 100, rows: 30)
        coordinator.attachmentReady()
        XCTAssertEqual(settled, [HCGridSize(columns: 100, rows: 30)])
        XCTAssertTrue(pending.isEmpty)
    }

    func testNoSurfaceGridMeansNoSettle() {
        let coordinator = makeCoordinator()
        grid = nil
        coordinator.noteSizeChanged(); runPending()
        XCTAssertTrue(settled.isEmpty)
    }
}

final class HCSentGridLedgerTests: XCTestCase {
    private let a = HCGridSize(columns: 80, rows: 24)
    private let b = HCGridSize(columns: 57, rows: 42)
    private let c = HCGridSize(columns: 100, rows: 30)

    func testTheAttachGridIsAlreadyAdmitted() {
        let ledger = HCSentGridLedger(initial: a)
        XCTAssertFalse(ledger.admitInBand(a))
        XCTAssertTrue(ledger.admitInBand(b))
        XCTAssertFalse(ledger.admitInBand(b))
        XCTAssertTrue(ledger.admitInBand(a), "returning to an earlier grid is a change")
        XCTAssertEqual(ledger.current, a)
    }

    func testAStaleObservationIsNotAdmittedAfterANewerOne() {
        let ledger = HCSentGridLedger(initial: a)
        let older = ledger.observe() // a display update read b, then waited behind another send
        XCTAssertTrue(ledger.admitInBand(c)) // the next reflow's report went out first
        XCTAssertFalse(ledger.admit(b, observedAt: older), "an older size must never overwrite a newer admitted one")
        XCTAssertEqual(ledger.current, c)
    }

    func testANewerObservationOfTheSameGridSendsNothing() {
        let ledger = HCSentGridLedger(initial: a)
        XCTAssertTrue(ledger.admitInBand(b))
        let later = ledger.observe()
        XCTAssertFalse(ledger.admit(b, observedAt: later))
        let latest = ledger.observe()
        XCTAssertTrue(ledger.admit(c, observedAt: latest))
        XCTAssertEqual(ledger.current, c)
    }

    func testConcurrentInBandAdmissionsOfOneGridSucceedOnce() {
        let ledger = HCSentGridLedger(initial: a)
        let wins = HCAtomicCounter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if ledger.admitInBand(c) { wins.increment() }
        }
        XCTAssertEqual(wins.value, 1)
    }
}

final class HCDisplayFactsTests: XCTestCase {
    func testSRGBColorsBecomeTheirBytes() {
        let color = NSColor(srgbRed: 0x09 / 255.0, green: 0x03 / 255.0, blue: 0x00, alpha: 1)
        XCTAssertEqual(HCDisplayFactsBuilder.rgb(color), HCRGBColor(red: 9, green: 3, blue: 0))
    }

    func testOtherColorSpacesAreConvertedToSRGB() {
        // Display P3 mid gray is not the same component values in sRGB.
        let p3 = NSColor(displayP3Red: 0.2, green: 0.6, blue: 0.4, alpha: 1)
        let srgb = p3.usingColorSpace(.sRGB)!
        let expected = HCRGBColor(
            red: UInt8((srgb.redComponent * 255).rounded()),
            green: UInt8((srgb.greenComponent * 255).rounded()),
            blue: UInt8((srgb.blueComponent * 255).rounded())
        )
        XCTAssertEqual(HCDisplayFactsBuilder.rgb(p3), expected)
        XCTAssertNotEqual(expected, HCRGBColor(red: 51, green: 153, blue: 102), "fixture must differ from raw P3 bytes")
    }

    func testOutOfGamutComponentsClampInsteadOfTrapping() {
        let p3Red = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        let rgb = HCDisplayFactsBuilder.rgb(p3Red)
        XCTAssertEqual(rgb?.red, 255)
        XCTAssertEqual(rgb?.green, 0)
    }

    func testCursorFallsBackToForeground() {
        let facts = HCDisplayFactsBuilder.facts(
            foreground: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            background: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            cursor: nil, cellWidthPixels: 16, cellHeightPixels: 32
        )
        XCTAssertEqual(facts.cursor, facts.foreground)
        XCTAssertEqual(facts.cellWidth, 16)
        XCTAssertEqual(facts.cellHeight, 32)
    }

    func testAMissingCellSizeOmitsBothDimensions() {
        let facts = HCDisplayFactsBuilder.facts(
            foreground: .white, background: .black, cursor: .red, cellWidthPixels: 0, cellHeightPixels: 32
        )
        XCTAssertNil(facts.cellWidth)
        XCTAssertNil(facts.cellHeight)
    }

    func testTheSameDisplayTwiceSendsOnce() {
        var tracker = HCDisplayStateTracker()
        let grid = HCGridSize(columns: 80, rows: 24)
        let facts = HCDisplayFacts(background: HCRGBColor(red: 9, green: 3, blue: 0))
        let first = tracker.next(attachmentGeneration: 1, grid: grid, facts: facts, focused: false)
        XCTAssertEqual(first?.revision.displayGeneration, 1)
        XCTAssertNil(tracker.next(attachmentGeneration: 1, grid: grid, facts: facts, focused: false))
        let changed = tracker.next(
            attachmentGeneration: 1, grid: grid,
            facts: HCDisplayFacts(background: HCRGBColor(red: 0x28, green: 0x2c, blue: 0x34)), focused: false
        )
        XCTAssertEqual(changed?.revision.displayGeneration, 2)
    }

    func testANewAttachmentAlwaysGetsAState() {
        var tracker = HCDisplayStateTracker()
        let grid = HCGridSize(columns: 80, rows: 24)
        _ = tracker.next(attachmentGeneration: 1, grid: grid, facts: HCDisplayFacts(), focused: false)
        let next = tracker.next(attachmentGeneration: 2, grid: grid, facts: HCDisplayFacts(), focused: false)
        XCTAssertEqual(next?.revision.attachmentGeneration, 2)
    }
}

final class HCLatencyProbeTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(UInt64, UInt64)] = []
        func add(_ s: UInt64, _ e: UInt64) { lock.lock(); items.append((s, e)); lock.unlock() }
        var all: [(UInt64, UInt64)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: UInt64 = 100
        func tick() -> UInt64 { lock.lock(); defer { lock.unlock() }; t += 10; return t }
    }

    private func key(_ probe: HCLatencyProbeState, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { probe.noteRawInput($0.baseAddress!, $0.count) }
    }

    func testOnePrintableKeyIsTimedToItsEcho() {
        let recorder = Recorder()
        let clock = Clock()
        let probe = HCLatencyProbeState(enabled: true, clock: { clock.tick() }, record: { recorder.add($0, $1) })
        key(probe, [0x61])
        probe.noteOutput(Data("zz".utf8))
        XCTAssertTrue(recorder.all.isEmpty)
        probe.noteOutput(Data("xa".utf8))
        XCTAssertEqual(recorder.all.count, 1)
        // Armed at the key (110); "zz" (120) misses; "xa" arrives at 130.
        XCTAssertEqual(recorder.all.first.map { $0.1 - $0.0 }, 20)
    }

    func testTheProbeDisarmsAfterOneSample() {
        let recorder = Recorder()
        let clock = Clock()
        let probe = HCLatencyProbeState(enabled: true, clock: { clock.tick() }, record: { recorder.add($0, $1) })
        key(probe, [0x61])
        probe.noteOutput(Data("a".utf8))
        probe.noteOutput(Data("a".utf8))
        XCTAssertEqual(recorder.all.count, 1)
    }

    func testOnlySinglePrintableBytesArm() {
        let recorder = Recorder()
        let clock = Clock()
        let probe = HCLatencyProbeState(enabled: true, clock: { clock.tick() }, record: { recorder.add($0, $1) })
        key(probe, [0x0d])
        probe.noteOutput(Data([0x0d]))
        key(probe, [0x20])
        probe.noteOutput(Data([0x20]))
        key(probe, [0x61, 0x62])
        probe.noteOutput(Data("ab".utf8))
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testOffRecordsNothing() {
        let recorder = Recorder()
        let probe = HCLatencyProbeState(enabled: false, clock: { 1 }, record: { recorder.add($0, $1) })
        key(probe, [0x61])
        probe.noteOutput(Data("a".utf8))
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testTheSinkWritesTheSpikesLineFormat() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-latency-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sink = HCLatencySink(path: path)
        sink.record(microseconds: 215.04)
        sink.record(microseconds: 9.96)
        sink.flush()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text, "mode=hc us=215.0\nmode=hc us=10.0\n")
    }

    func testLongRunsKeepEverySample() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-latency-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sink = HCLatencySink(path: path)
        for i in 0..<2_150 { sink.record(microseconds: Double(i)) }
        sink.flush()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2_150)
        XCTAssertEqual(lines.last, "mode=hc us=2149.0")
    }

    func testAPartialBatchReachesTheFileWithoutAnExplicitFlush() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-latency-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sink = HCLatencySink(path: path, flushDelay: 0.2)
        for _ in 0..<7 { sink.record(microseconds: 1) }
        let deadline = Date().addingTimeInterval(3)
        var count = 0
        while Date() < deadline {
            count = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").count
            if count == 7 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(count, 7)
    }
}
