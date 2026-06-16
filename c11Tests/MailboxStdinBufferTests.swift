import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for the pure gating/buffer/flush logic behind C11-144's
/// prompt-gated stdin delivery. No PTY, no Workspace instance — the clock is
/// injected, so every decision is deterministic.
final class MailboxStdinBufferTests: XCTestCase {

    private func entry(
        id: String = "01K3A2B7X8PQRTVWYZ0123456J",
        recipient: String = "watcher",
        block: String = "<c11-msg/>",
        at: Date = Date(timeIntervalSince1970: 1_000)
    ) -> MailboxStdinBuffer.Entry {
        MailboxStdinBuffer.Entry(
            id: id, recipientName: recipient, block: block, bufferedAt: at
        )
    }

    // MARK: - decide()

    func testDecideInjectsWhenPromptIdle() {
        XCTAssertEqual(MailboxStdinBuffer.decide(state: .promptIdle), .injectNow)
    }

    func testDecideBuffersWhenCommandRunning() {
        XCTAssertEqual(MailboxStdinBuffer.decide(state: .commandRunning), .buffer)
    }

    func testDecideBuffersWhenUnknown() {
        XCTAssertEqual(MailboxStdinBuffer.decide(state: .unknown), .buffer)
    }

    // MARK: - enqueue / drain FIFO

    func testBufferedEntriesFlushInFifoOrder() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<3 {
            buffer.enqueue(
                surfaceId: surface,
                entry: entry(id: "id-\(i)", block: "block-\(i)", at: base)
            )
        }
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 3)

        let result = buffer.drainForFlush(surfaceId: surface, now: base.addingTimeInterval(1))
        XCTAssertEqual(result.fresh.map(\.id), ["id-0", "id-1", "id-2"])
        XCTAssertTrue(result.expired.isEmpty)
        // Drained — queue is now empty.
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 0)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainOfEmptySurfaceIsNoOp() {
        var buffer = MailboxStdinBuffer()
        let result = buffer.drainForFlush(surfaceId: UUID(), now: Date())
        XCTAssertTrue(result.fresh.isEmpty)
        XCTAssertTrue(result.expired.isEmpty)
    }

    func testQueuesAreIsolatedPerSurface() {
        var buffer = MailboxStdinBuffer()
        let a = UUID()
        let b = UUID()
        buffer.enqueue(surfaceId: a, entry: entry(id: "a0"))
        buffer.enqueue(surfaceId: b, entry: entry(id: "b0"))
        let drainA = buffer.drainForFlush(surfaceId: a, now: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(drainA.fresh.map(\.id), ["a0"])
        // b untouched.
        XCTAssertEqual(buffer.pendingCount(surfaceId: b), 1)
    }

    // MARK: - freshness window

    func testStaleEntriesExpireRatherThanFlush() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let bufferedAt = Date(timeIntervalSince1970: 1_000)
        buffer.enqueue(surfaceId: surface, entry: entry(id: "stale", at: bufferedAt))
        buffer.enqueue(
            surfaceId: surface,
            entry: entry(id: "fresh", at: bufferedAt.addingTimeInterval(
                MailboxStdinBuffer.freshnessWindow
            ))
        )

        // Flush far enough out that the first entry is past the window but the
        // second is exactly on the boundary (<= window → fresh).
        let now = bufferedAt
            .addingTimeInterval(MailboxStdinBuffer.freshnessWindow)
            .addingTimeInterval(1)
        let result = buffer.drainForFlush(surfaceId: surface, now: now)
        XCTAssertEqual(result.expired.map(\.id), ["stale"])
        XCTAssertEqual(result.fresh.map(\.id), ["fresh"])
    }

    func testEntryExactlyAtWindowBoundaryIsFresh() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let bufferedAt = Date(timeIntervalSince1970: 1_000)
        buffer.enqueue(surfaceId: surface, entry: entry(id: "edge", at: bufferedAt))
        let now = bufferedAt.addingTimeInterval(MailboxStdinBuffer.freshnessWindow)
        let result = buffer.drainForFlush(surfaceId: surface, now: now)
        XCTAssertEqual(result.fresh.map(\.id), ["edge"])
        XCTAssertTrue(result.expired.isEmpty)
    }

    // MARK: - per-surface cap eviction

    func testCapEvictsOldestAndReportsIt() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        var evictions: [String] = []
        for i in 0...MailboxStdinBuffer.perSurfaceCap {
            if let evicted = buffer.enqueue(
                surfaceId: surface,
                entry: entry(id: "id-\(i)", at: base)
            ) {
                evictions.append(evicted.id)
            }
        }
        // One over the cap → exactly one eviction, the oldest.
        XCTAssertEqual(evictions, ["id-0"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), MailboxStdinBuffer.perSurfaceCap)

        let result = buffer.drainForFlush(surfaceId: surface, now: base.addingTimeInterval(1))
        XCTAssertEqual(result.fresh.first?.id, "id-1")
        XCTAssertEqual(result.fresh.count, MailboxStdinBuffer.perSurfaceCap)
    }

    func testEnqueueUnderCapDoesNotEvict() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let evicted = buffer.enqueue(surfaceId: surface, entry: entry())
        XCTAssertNil(evicted)
    }

    // MARK: - removeSurface / retainOnly

    func testRemoveSurfaceReturnsPendingAndClears() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        buffer.enqueue(surfaceId: surface, entry: entry(id: "x0"))
        buffer.enqueue(surfaceId: surface, entry: entry(id: "x1"))
        let dropped = buffer.removeSurface(surface)
        XCTAssertEqual(dropped.map(\.id), ["x0", "x1"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 0)
    }

    func testRetainOnlyPrunesAbsentSurfaces() {
        var buffer = MailboxStdinBuffer()
        let keep = UUID()
        let drop = UUID()
        buffer.enqueue(surfaceId: keep, entry: entry(id: "k"))
        buffer.enqueue(surfaceId: drop, entry: entry(id: "d"))
        buffer.retainOnly(surfaceIds: [keep])
        XCTAssertEqual(buffer.pendingCount(surfaceId: keep), 1)
        XCTAssertEqual(buffer.pendingCount(surfaceId: drop), 0)
    }
}
