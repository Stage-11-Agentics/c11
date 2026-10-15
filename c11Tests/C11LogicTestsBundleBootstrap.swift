import Foundation

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Initializes shared logic-test state before a fresh xctest worker runs its
/// first test. In particular, TerminalNotificationStore must capture the
/// hostless XCTest environment before workspace construction initializes
/// AppKit, or its lazy notification-center lookup can target Xcode's agent
/// bundle and abort the worker.
@MainActor
@objc(C11LogicTestsBundleBootstrap)
final class C11LogicTestsBundleBootstrap: NSObject {
    override init() {
        super.init()
        _ = TerminalNotificationStore.shared
    }
}
