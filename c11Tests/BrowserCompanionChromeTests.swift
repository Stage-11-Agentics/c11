import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Membership scaffold for ACB-03 browser-chrome acceptance tests.
final class BrowserCompanionChromeTests: XCTestCase {}
