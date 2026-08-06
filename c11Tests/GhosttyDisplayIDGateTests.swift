import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Covers `GhosttyDisplayIDGate`, the admission control in front of
/// `ghostty_surface_set_display_id`.
///
/// C11-191: that call posts to the surface's renderer thread through a bounded
/// 64-slot blocking queue and blocks the caller — the main thread — until a slot
/// frees. `updateNSView` reaches it on every SwiftUI update, so the queue used to
/// take a message per surface per update; once a renderer thread stopped draining,
/// the main thread parked in `__ulock_wait2` inside `GhosttyNSView.attachSurface`
/// and stayed there (13h58m in the field log that opened the ticket).
///
/// These tests exercise the gate's decisions directly — a push admitted here is a
/// message that reaches the renderer mailbox, one refused is a slot not spent.
final class GhosttyDisplayIDGateTests: XCTestCase {

    /// The regression the ticket is about: a steady stream of SwiftUI updates over
    /// an unchanged screen must cost exactly one mailbox message, not one each.
    func testRepeatedUpdatesOnOneScreenPushOnce() {
        var gate = GhosttyDisplayIDGate()
        var pushes = 0

        for _ in 0..<500 {
            if gate.admit(1, force: false) { pushes += 1 }
        }

        XCTAssertEqual(pushes, 1)
    }

    /// A real screen change still has to reach the renderer, or the surface keeps
    /// vsyncing against the display it is no longer on.
    func testDisplayChangeIsAdmitted() {
        var gate = GhosttyDisplayIDGate()

        XCTAssertTrue(gate.admit(1, force: false))
        XCTAssertFalse(gate.admit(1, force: false))
        XCTAssertTrue(gate.admit(2, force: false))
        XCTAssertFalse(gate.admit(2, force: false))
        XCTAssertTrue(gate.admit(1, force: false))
    }

    /// `renderer.setMacOSDisplayID` restarts a stalled CVDisplayLink on every
    /// message it receives, so the sites that re-assert an unchanged id on purpose
    /// (surface creation, focus gain, topology churn, window/screen moves) must
    /// keep getting through. Suppressing those would trade a hang for a frozen
    /// terminal.
    func testForcedPushesAlwaysAdmittedEvenWhenUnchanged() {
        var gate = GhosttyDisplayIDGate()

        XCTAssertTrue(gate.admit(7, force: false))
        for _ in 0..<10 {
            XCTAssertTrue(gate.admit(7, force: true))
        }
        // The forced pushes must not disturb the memo the gated path relies on.
        XCTAssertFalse(gate.admit(7, force: false))
    }

    /// Zero is `NSScreen.displayID`'s "AppKit could not resolve this screen"
    /// value. Ghostty has nothing to do with it, and every call site used to
    /// filter it out by hand.
    func testZeroDisplayIDIsNeverAdmitted() {
        var gate = GhosttyDisplayIDGate()

        XCTAssertFalse(gate.admit(0, force: false))
        XCTAssertFalse(gate.admit(0, force: true))
        XCTAssertNil(gate.applied)

        // ...and a rejected zero must not become the memo, or the next real id
        // would be compared against it.
        XCTAssertTrue(gate.admit(3, force: false))
        XCTAssertEqual(gate.applied, 3)
    }

    /// A new `ghostty_surface_t` has its own renderer thread and knows nothing of
    /// what the old one was told, so the memo cannot survive the swap.
    func testInvalidateForcesTheNextPushThrough() {
        var gate = GhosttyDisplayIDGate()

        XCTAssertTrue(gate.admit(4, force: false))
        XCTAssertFalse(gate.admit(4, force: false))

        gate.invalidate()

        XCTAssertNil(gate.applied)
        XCTAssertTrue(gate.admit(4, force: false))
    }

    /// A surface that migrates between two displays and back — dragging a window
    /// across a monitor boundary — pushes once per crossing and nothing in between.
    func testAlternatingScreensPushOncePerCrossing() {
        var gate = GhosttyDisplayIDGate()
        var pushes = 0

        for crossing in 0..<6 {
            let displayID: UInt32 = crossing.isMultiple(of: 2) ? 1 : 2
            // Each crossing is followed by a burst of SwiftUI updates on the new
            // screen; only the crossing itself is worth a message.
            for _ in 0..<25 {
                if gate.admit(displayID, force: false) { pushes += 1 }
            }
        }

        XCTAssertEqual(pushes, 6)
    }
}
