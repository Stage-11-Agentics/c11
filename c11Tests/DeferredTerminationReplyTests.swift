import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class DeferredTerminationReplyTests: XCTestCase {
    func testUpdateRestartRepliesOnceDespiteSheetDismissalReentry() async {
        await MainActor.run {
            var events: [String] = []
            let pending = DeferredTerminationReply { events.append("reply:\($0)") }
            XCTAssertTrue(pending.resolve(true) {
                events.append("dismiss")
                XCTAssertFalse(pending.resolve(false), "A sheet completion cannot cancel an accepted restart")
            })
            XCTAssertFalse(pending.resolve(true), "A second updater notification must not reply again")
            XCTAssertEqual(events, ["dismiss", "reply:true"])
        }
    }

    func testVanishedWindowCancelsOnceAndLateCallbackCannotQuit() async {
        await MainActor.run {
            var replies: [Bool] = []
            let pending = DeferredTerminationReply { replies.append($0) }
            XCTAssertTrue(pending.resolve(false))
            XCTAssertFalse(pending.resolve(true))
            XCTAssertEqual(replies, [false])
        }
    }

    func testOldSheetCompletionCannotConsumeNextQuitRequest() async {
        await MainActor.run {
            var replies: [Bool] = []
            let old = DeferredTerminationReply { replies.append($0) }
            old.resolve(false)
            let next = DeferredTerminationReply { replies.append($0) }
            XCTAssertFalse(old.resolve(true))
            XCTAssertTrue(next.resolve(true))
            XCTAssertEqual(replies, [false, true])
        }
    }
}
