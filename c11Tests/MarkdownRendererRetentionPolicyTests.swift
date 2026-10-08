import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MarkdownRendererRetentionPolicyTests: XCTestCase {
    private let ids = (0..<8).map { _ in UUID() }

    func testDefaultCapacityRetainsFourHiddenRenderers() {
        var policy = MarkdownRendererRetentionPolicy()
        XCTAssertEqual(policy.hiddenCapacity, 4)
        ids.forEach { policy.insert($0) }
        XCTAssertEqual(policy.evictionCandidates, Array(ids.prefix(4)))
    }

    func testEveryVisibleRendererIsProtectedRegardlessOfCapacity() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 1)
        ids.forEach { policy.insert($0) }
        ids.prefix(6).forEach { policy.setVisible($0, true) }
        XCTAssertEqual(policy.evictionCandidates, [ids[6]])
        policy.setVisible(ids[7], true)
        XCTAssertTrue(policy.evictionCandidates.isEmpty)
    }

    func testHiddenCandidatesAreOldestFirstAndStayTrackedUntilRemoved() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 2)
        ids.prefix(5).forEach { policy.insert($0) }
        XCTAssertEqual(policy.evictionCandidates, Array(ids.prefix(3)))
        XCTAssertEqual(policy.evictionCandidates, Array(ids.prefix(3)))
        policy.remove(ids[0])
        XCTAssertEqual(policy.evictionCandidates, [ids[1], ids[2]])
    }

    func testTouchMovesAnExistingRendererToMostRecent() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 2)
        ids.prefix(4).forEach { policy.insert($0) }
        policy.touch(ids[0])
        XCTAssertEqual(policy.evictionCandidates, [ids[1], ids[2]])
        policy.touch(ids[1])
        XCTAssertEqual(policy.evictionCandidates, [ids[2], ids[3]])
    }

    func testHidingAVisibleRendererRecordsItsRecentUse() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 2)
        ids.prefix(4).forEach { policy.insert($0) }
        policy.setVisible(ids[0], true)
        policy.setVisible(ids[0], false)
        XCTAssertEqual(policy.evictionCandidates, [ids[1], ids[2]])
    }

    func testRepeatedVisibilityMarksDoNotChangeRecency() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 1)
        ids.prefix(3).forEach { policy.insert($0) }
        policy.setVisible(ids[0], false)
        XCTAssertEqual(policy.evictionCandidates, [ids[0], ids[1]])
        policy.setVisible(ids[0], true)
        policy.touch(ids[1])
        policy.setVisible(ids[0], true)
        policy.setVisible(ids[0], false)
        policy.touch(ids[2])
        policy.setVisible(ids[0], false)
        XCTAssertEqual(policy.evictionCandidates, [ids[1], ids[0]])
    }

    func testPinExcludesCandidateAndUnpinRestoresOriginalRecency() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 2)
        ids.prefix(4).forEach { policy.insert($0) }
        policy.setPinned(ids[0], true)
        XCTAssertEqual(policy.evictionCandidates, [ids[1], ids[2]])
        policy.setPinned(ids[0], false)
        XCTAssertEqual(policy.evictionCandidates, [ids[0], ids[1]])
    }

    func testPinnedHiddenRenderersCanExceedCapacityAndConsumeAllSlots() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 1)
        ids.prefix(4).forEach { policy.insert($0) }
        policy.setPinned(ids[0], true)
        policy.setPinned(ids[1], true)
        XCTAssertEqual(policy.evictionCandidates, [ids[2], ids[3]])
        policy.remove(ids[2])
        policy.remove(ids[3])
        XCTAssertTrue(policy.evictionCandidates.isEmpty)
        policy.setPinned(ids[0], false)
        XCTAssertEqual(policy.evictionCandidates, [ids[0]])
    }

    func testZeroAndNegativeCapacityEvictEveryEligibleHiddenRenderer() {
        for capacity in [0, -1] {
            var policy = MarkdownRendererRetentionPolicy(capacity: capacity)
            ids.prefix(4).forEach { policy.insert($0) }
            policy.setVisible(ids[0], true)
            policy.setPinned(ids[1], true)
            XCTAssertEqual(policy.hiddenCapacity, 0)
            XCTAssertEqual(policy.evictionCandidates, [ids[2], ids[3]])
        }
    }

    func testRemoveClearsProtectionAndLateCallbacksDoNotReinsert() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 0)
        policy.insert(ids[0])
        policy.setVisible(ids[0], true)
        policy.setPinned(ids[0], true)
        policy.remove(ids[0])
        policy.setVisible(ids[0], false)
        policy.setPinned(ids[0], false)
        XCTAssertTrue(policy.evictionCandidates.isEmpty)
        policy.insert(ids[0])
        XCTAssertEqual(policy.evictionCandidates, [ids[0]])
        policy.remove(ids[0])
        policy.remove(ids[0])
        XCTAssertTrue(policy.evictionCandidates.isEmpty)
    }

    func testDuplicateInsertionDoesNotChangeRecencyOrProtection() {
        var policy = MarkdownRendererRetentionPolicy(capacity: 1)
        ids.prefix(3).forEach { policy.insert($0) }
        policy.insert(ids[0])
        XCTAssertEqual(policy.evictionCandidates, [ids[0], ids[1]])
        policy.setPinned(ids[0], true)
        policy.insert(ids[0])
        XCTAssertEqual(policy.evictionCandidates, [ids[1], ids[2]])
    }
}
