import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Every delayed-Return call site must refuse a stale input generation. Each test
/// drives the production caller, replaces the surface (bumping the generation)
/// before the delayed Return, and asserts that no Return reaches the replacement;
/// the paired control proves the harness would have seen the Return. A fake
/// native handle and sinks replace Ghostty; nothing is launched.
@MainActor
final class HCDelayedReturnTests: XCTestCase {
    private final class Sinks {
        var returns = 0
        var texts: [Data] = []
    }

    private func makeSurface() -> (TerminalSurface, Sinks) {
        let surface = TerminalSurface(workspaceId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                                      configTemplate: nil, workingDirectory: nil)
        let sinks = Sinks()
        surface.installFakeNativeSurfaceForTesting(UnsafeMutableRawPointer(bitPattern: 0x10))
        surface.returnKeySinkForTesting = { sinks.returns += 1 }
        surface.textSinkForTesting = { sinks.texts.append($0) }
        return (surface, sinks)
    }

    private func releaseSurface(_ surface: TerminalSurface) {
        surface.returnKeySinkForTesting = nil
        surface.textSinkForTesting = nil
        surface.installFakeNativeSurfaceForTesting(nil)
    }

    // MARK: scheduleSubmitReturnAfterPasteDelay (text box, socket send, feed)

    func testPasteDelayReturnIsDeliveredToTheSameSurface() {
        let (surface, sinks) = makeSurface()
        defer { releaseSurface(surface) }
        let done = expectation(description: "Return result")
        var dispatched: Bool?
        surface.performInputTransaction { finish in
            surface.scheduleSubmitReturnAfterPasteDelay(then: finish, onReturnDispatched: { dispatched = $0; done.fulfill() })
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(dispatched, true)
        XCTAssertEqual(sinks.returns, 1, "control: the harness must observe a current Return")
    }

    func testPasteDelayReturnIsWithheldWhenTheSurfaceIsReplacedDuringTheDelay() {
        let (surface, sinks) = makeSurface()
        defer { releaseSurface(surface) }
        let done = expectation(description: "Return result")
        var dispatched: Bool?
        surface.performInputTransaction { finish in
            surface.scheduleSubmitReturnAfterPasteDelay(then: finish, onReturnDispatched: { dispatched = $0; done.fulfill() })
        }
        surface.replaceNativeSurfaceForTesting()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(dispatched, false)
        XCTAssertEqual(sinks.returns, 0, "a stale Return reached the replacement terminal")
    }

    // MARK: mailbox / launch-prompt push

    func testMailboxPushReturnFollowsTheGenerationItWasPastedUnder() {
        for replace in [false, true] {
            let (surface, sinks) = makeSurface()
            defer { releaseSurface(surface) }
            let done = expectation(description: "completion \(replace)")
            var dispatched: Bool?
            surface.sendSubmitFormText("<c11-msg>hi</c11-msg>", shouldSubmit: { true }) { dispatched = $0; done.fulfill() }
            if replace { surface.replaceNativeSurfaceForTesting() }
            wait(for: [done], timeout: 3)
            XCTAssertEqual(sinks.texts.count, 1, "the body is pasted before the delay")
            XCTAssertEqual(dispatched, !replace)
            XCTAssertEqual(sinks.returns, replace ? 0 : 1)
        }
    }

    // MARK: socket send (queued behind another writer)

    func testSocketSendQueuedBehindAnotherWriterIsRefusedWhenTheSurfaceChangesFirst() {
        for replace in [false, true] {
            let (surface, sinks) = makeSurface()
            defer { releaseSurface(surface) }
            var unblock: (() -> Void)?
            surface.performInputTransaction { finish in unblock = finish }
            let done = expectation(description: "socket send result \(replace)")
            var dispatched: Bool?
            TerminalController.shared.deliverSocketSendText("echo hi", submit: true, terminalSurface: surface,
                surface: UnsafeMutableRawPointer(bitPattern: 0x10)!, onReturnDispatched: { dispatched = $0; done.fulfill() })
            XCTAssertTrue(sinks.texts.isEmpty, "the body must wait for the other writer")
            if replace { surface.replaceNativeSurfaceForTesting() }
            unblock?()
            wait(for: [done], timeout: 3)
            XCTAssertEqual(dispatched, !replace)
            XCTAssertEqual(sinks.texts.count, replace ? 0 : 1, "a stale body was written into the replacement")
            XCTAssertEqual(sinks.returns, replace ? 0 : 1)
        }
    }

    // MARK: post-boot launch binding (TerminalPanel.submitLaunchPlan)

    func testLaunchBindingRefusesAStaleGenerationForBothPromptAndReturn() {
        let binding = LaunchGenerationBinding<Int>()
        XCTAssertFalse(binding.admitsSubmit(isLive: true, isCurrent: { _ in true }), "unbound launch must not submit")
        XCTAssertTrue(binding.isCurrent { _ in false }, "nothing to be stale against before the launcher")
        binding.bindIfNeeded { 7 }
        binding.bindIfNeeded { 8 }
        var seen: [Int] = []
        XCTAssertTrue(binding.admitsSubmit(isLive: true, isCurrent: { seen.append($0); return $0 == 7 }))
        XCTAssertEqual(seen, [7], "the first generation stays bound")
        XCTAssertFalse(binding.admitsSubmit(isLive: true, isCurrent: { $0 == 8 }), "stale generation admitted the prompt")
        XCTAssertFalse(binding.admitsSubmit(isLive: false, isCurrent: { _ in true }))
        XCTAssertFalse(binding.isCurrent { $0 == 8 }, "stale generation kept the post-boot delay alive")
    }
}
