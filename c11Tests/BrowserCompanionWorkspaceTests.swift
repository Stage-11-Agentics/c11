import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Membership scaffold for ACB-01 host-level Workspace acceptance tests.
final class BrowserCompanionWorkspaceTests: XCTestCase {}
