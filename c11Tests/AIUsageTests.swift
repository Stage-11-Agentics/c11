import XCTest
import Security
import SwiftUI
@testable import c11

private func uniqueKeychainService() -> String {
    "com.stage11.c11.aiusage.tests.\(UUID().uuidString)"
}

private func uniqueIndexKey() -> String {
    "c11.aiusage.tests.\(UUID().uuidString)"
}

private func cleanupKeychain(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
    SecItemDelete(query as CFDictionary)
}

final class AIUsageAccountStoreRoundTripTests: XCTestCase {
    private let suiteName = "c11.aiusage.tests.\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var service: String!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        service = uniqueKeychainService()
        defaults.removePersistentDomain(forName: suiteName)
        cleanupKeychain(service: service)
    }

    override func tearDown() {
        cleanupKeychain(service: service)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor
    func testAddSecretUpdateRemoveRoundTrip() async throws {
        let indexKey = uniqueIndexKey()
        let store = AIUsageAccountStore(
            userDefaults: defaults,
            indexKey: indexKey,
            keychainServiceResolver: { _ in self.service }
        )
        XCTAssertTrue(store.accounts.isEmpty)

        let original = AIUsageSecret(fields: ["sessionKey": "secret-value", "orgId": "org-1"])
        try await store.add(providerId: "claude", displayName: "Personal", secret: original)
        XCTAssertEqual(store.accounts.count, 1)
        let id = store.accounts[0].id

        let loaded = try await store.secret(for: id)
        XCTAssertEqual(loaded.fields["sessionKey"], "secret-value")
        XCTAssertEqual(loaded.fields["orgId"], "org-1")

        let updated = AIUsageSecret(fields: ["sessionKey": "rotated", "orgId": "org-2"])
        try await store.update(id: id, displayName: "Work", secret: updated)
        XCTAssertEqual(store.accounts[0].displayName, "Work")
        let reloaded = try await store.secret(for: id)
        XCTAssertEqual(reloaded.fields["sessionKey"], "rotated")
        XCTAssertEqual(reloaded.fields["orgId"], "org-2")

        try await store.remove(id: id)
        XCTAssertTrue(store.accounts.isEmpty)
        do {
            _ = try await store.secret(for: id)
            XCTFail("expected notFound")
        } catch AIUsageStoreError.notFound {
            // expected
        }
    }

    @MainActor
    func testIndexPersistsAcrossInstances() async throws {
        let indexKey = uniqueIndexKey()
        let resolver: (String) -> String = { _ in self.service }
        let first = AIUsageAccountStore(
            userDefaults: defaults,
            indexKey: indexKey,
            keychainServiceResolver: resolver
        )
        let secret = AIUsageSecret(fields: ["sessionKey": "v"])
        try await first.add(providerId: "claude", displayName: "Personal", secret: secret)
        XCTAssertEqual(first.accounts.count, 1)

        let second = AIUsageAccountStore(
            userDefaults: defaults,
            indexKey: indexKey,
            keychainServiceResolver: resolver
        )
        XCTAssertEqual(second.accounts.count, 1)
        XCTAssertEqual(second.accounts[0].providerId, "claude")
        XCTAssertEqual(second.accounts[0].displayName, "Personal")

        try await second.remove(id: second.accounts[0].id)
        XCTAssertTrue(second.accounts.isEmpty)
    }
}

final class AIUsageSecretRedactionTests: XCTestCase {
    func testDescriptionElidesValues() {
        let secret = AIUsageSecret(fields: ["sessionKey": "topsecret", "orgId": "abcd-1234"])
        let description = secret.description
        XCTAssertTrue(description.contains("<redacted>"))
        XCTAssertFalse(description.contains("topsecret"))
        XCTAssertFalse(description.contains("abcd-1234"))
        XCTAssertEqual(secret.debugDescription, description)
    }

    func testDumpDoesNotLeakValues() {
        let secret = AIUsageSecret(fields: ["accessToken": "supersecret"])
        var sink = ""
        dump(secret, to: &sink)
        XCTAssertFalse(sink.contains("supersecret"))
    }

    func testStringInterpolationDoesNotLeakValues() {
        let secret = AIUsageSecret(fields: ["accessToken": "interp-secret"])
        let interpolated = "secret=\(secret)"
        XCTAssertFalse(interpolated.contains("interp-secret"))
        XCTAssertTrue(interpolated.contains("<redacted>"))
    }

    func testCodableRoundTripPreservesValues() throws {
        let secret = AIUsageSecret(fields: ["sessionKey": "codable-v"])
        let data = try JSONEncoder().encode(secret.fields)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(decoded["sessionKey"], "codable-v")
    }
}

final class AIUsageISO8601DateParserTests: XCTestCase {
    func testParsesStandardISO8601() {
        let date = AIUsageISO8601DateParser.parse("2026-04-26T12:34:56Z")
        XCTAssertNotNil(date)
    }

    func testParsesFractionalSeconds() {
        let date = AIUsageISO8601DateParser.parse("2026-04-26T12:34:56.789Z")
        XCTAssertNotNil(date)
    }

    func testNilAndEmptyAndGarbageReturnNil() {
        XCTAssertNil(AIUsageISO8601DateParser.parse(nil))
        XCTAssertNil(AIUsageISO8601DateParser.parse(""))
        XCTAssertNil(AIUsageISO8601DateParser.parse("not-a-date"))
    }
}

final class AIUsageHTTPSessionTests: XCTestCase {
    func testMakeSessionHonorsTimeout() {
        let session = AIUsageHTTP.makeSession(timeout: 7)
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 7)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 7)
    }

    func testMakeSessionIsEphemeral() {
        let session = AIUsageHTTP.makeSession(timeout: 10)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
    }

    func testSanitizeHeaderValueStripsControlAndSeparators() {
        XCTAssertEqual(AIUsageHTTP.sanitizeHeaderValue("a\r\nb"), "ab")
        XCTAssertEqual(AIUsageHTTP.sanitizeHeaderValue("a\rb"), "ab")
        XCTAssertEqual(AIUsageHTTP.sanitizeHeaderValue("a\nb"), "ab")
        XCTAssertEqual(AIUsageHTTP.sanitizeHeaderValue("Bearer abc;path=/"), "Bearer abcpath=/")
        XCTAssertEqual(AIUsageHTTP.sanitizeHeaderValue("a,b"), "ab")
        XCTAssertEqual(AIUsageHTTP.sanitizeHeaderValue("Bearer sk-ant-abc="), "Bearer sk-ant-abc=")
    }
}

final class AIUsageStatusPagePollerHostTests: XCTestCase {
    func testRejectsUnlistedHost() async {
        do {
            _ = try await AIUsageStatusPagePoller.fetch(host: "evil.example.com")
            XCTFail("expected invalidHost")
        } catch AIUsageStatusPageError.invalidHost(let host) {
            XCTAssertEqual(host, "evil.example.com")
        } catch {
            XCTFail("expected invalidHost, got \(error)")
        }
    }

    func testRejectsHostWithSlashOrColon() async {
        for bad in ["status.claude.com/path", "status.openai.com:443"] {
            do {
                _ = try await AIUsageStatusPagePoller.fetch(host: bad)
                XCTFail("expected invalidHost for \(bad)")
            } catch AIUsageStatusPageError.invalidHost {
                // expected
            } catch {
                XCTFail("expected invalidHost for \(bad), got \(error)")
            }
        }
    }

    func testAllowedHostsAreClaudeAndOpenAI() {
        XCTAssertTrue(AIUsageStatusPagePoller.allowedHosts.contains("status.claude.com"))
        XCTAssertTrue(AIUsageStatusPagePoller.allowedHosts.contains("status.openai.com"))
    }
}

final class ClaudeAIValidatorTests: XCTestCase {
    func testIsValidOrgIdAcceptsUUID() {
        XCTAssertTrue(ClaudeAIValidators.isValidOrgId("01970000-1111-7222-aaaa-bbbbcccc1234"))
    }

    func testIsValidOrgIdRejectsBadInputs() {
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId(""))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId(".."))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId("../etc/passwd"))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId("foo/bar"))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId("foo:bar"))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId("foo?bar"))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId("foo#bar"))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId(" "))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId("foo bar"))
        XCTAssertFalse(ClaudeAIValidators.isValidOrgId("foo\nbar"))
    }

    func testIsValidSessionKeyAcceptsTypicalToken() {
        XCTAssertTrue(ClaudeAIValidators.isValidSessionKey("sk-ant-sid01-abc123"))
    }

    func testIsValidSessionKeyRejectsSeparatorsAndControlChars() {
        XCTAssertFalse(ClaudeAIValidators.isValidSessionKey(""))
        XCTAssertFalse(ClaudeAIValidators.isValidSessionKey("a;b"))
        XCTAssertFalse(ClaudeAIValidators.isValidSessionKey("a,b"))
        XCTAssertFalse(ClaudeAIValidators.isValidSessionKey("a\nb"))
        XCTAssertFalse(ClaudeAIValidators.isValidSessionKey("a\rb"))
        XCTAssertFalse(ClaudeAIValidators.isValidSessionKey("a\tb"))
    }

    func testIsValidSessionKeyAcceptsPrefixedAssignment() {
        // Validator is permissive about the `=` character so
        // strippedSessionKey can recover the actual value.
        XCTAssertTrue(ClaudeAIValidators.isValidSessionKey("sessionKey=sk-ant-sid01-abc123"))
    }

    func testStrippedSessionKeyRemovesPrefix() {
        XCTAssertEqual(
            ClaudeAIValidators.strippedSessionKey("sessionKey=sk-ant-sid01-abc"),
            "sk-ant-sid01-abc"
        )
        XCTAssertEqual(
            ClaudeAIValidators.strippedSessionKey("sessionKey=sessionKey=value"),
            "value"
        )
        XCTAssertEqual(
            ClaudeAIValidators.strippedSessionKey("  sessionKey=value  "),
            "value"
        )
    }
}

final class AIUsageRegistryClaudeTests: XCTestCase {
    func testRegistryContainsClaude() {
        let claude = AIUsageRegistry.provider(id: "claude")
        XCTAssertNotNil(claude)
        XCTAssertEqual(claude?.displayName, "Claude")
        XCTAssertEqual(claude?.keychainService, "com.stage11.c11.aiusage.claude-accounts")
        XCTAssertFalse(claude?.credentialFields.isEmpty ?? true)
    }

    func testProviderUnknownReturnsNil() {
        XCTAssertNil(AIUsageRegistry.provider(id: "nope"))
    }
}

final class CodexAIValidatorTests: XCTestCase {
    private static let validJWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.dGVzdA"

    func testIsValidAccessTokenAcceptsThreeSegmentJWT() {
        XCTAssertTrue(CodexAIValidators.isValidAccessToken(Self.validJWT))
    }

    func testIsValidAccessTokenRejectsBadShapes() {
        XCTAssertFalse(CodexAIValidators.isValidAccessToken(""))
        XCTAssertFalse(CodexAIValidators.isValidAccessToken("eyJ.b"))
        XCTAssertFalse(CodexAIValidators.isValidAccessToken("eyJ.b.c.d"))
        XCTAssertFalse(CodexAIValidators.isValidAccessToken("notjwt.b.c"))
        XCTAssertFalse(CodexAIValidators.isValidAccessToken("   "))
        XCTAssertFalse(CodexAIValidators.isValidAccessToken("eyJ.a b.c"))
    }

    func testIsValidAccessTokenTrimsWhitespace() {
        XCTAssertTrue(CodexAIValidators.isValidAccessToken("\n  \(Self.validJWT)\n"))
    }

    func testIsValidAccountIdAcceptsEmptyAndOpaque() {
        XCTAssertTrue(CodexAIValidators.isValidAccountId(""))
        XCTAssertTrue(CodexAIValidators.isValidAccountId("abcd-1234-foo"))
    }

    func testIsValidAccountIdRejectsNullSentinelAndWhitespace() {
        XCTAssertFalse(CodexAIValidators.isValidAccountId("null"))
        XCTAssertFalse(CodexAIValidators.isValidAccountId("NULL"))
        XCTAssertFalse(CodexAIValidators.isValidAccountId("a b"))
        XCTAssertFalse(CodexAIValidators.isValidAccountId("a\nb"))
    }
}

final class AIUsageColorSettingsTests: XCTestCase {
    private let suiteName = "c11.aiusage.colors.tests.\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor
    func testDefaultsApplyWhenNothingStored() {
        let settings = AIUsageColorSettings(userDefaults: defaults)
        XCTAssertEqual(settings.lowColorHex, AIUsageColorSettings.defaultLowColorHex)
        XCTAssertEqual(settings.midColorHex, AIUsageColorSettings.defaultMidColorHex)
        XCTAssertEqual(settings.highColorHex, AIUsageColorSettings.defaultHighColorHex)
        XCTAssertEqual(settings.lowMidThreshold, AIUsageColorSettings.defaultLowMidThreshold)
        XCTAssertEqual(settings.midHighThreshold, AIUsageColorSettings.defaultMidHighThreshold)
        XCTAssertEqual(settings.interpolate, AIUsageColorSettings.defaultInterpolate)
    }

    @MainActor
    func testSetThresholdsEnforcesOrder() {
        let settings = AIUsageColorSettings(userDefaults: defaults)
        settings.setThresholds(low: 90, high: 50)
        XCTAssertLessThan(settings.lowMidThreshold, settings.midHighThreshold)
    }

    @MainActor
    func testSetThresholdsClampsToValidRange() {
        let settings = AIUsageColorSettings(userDefaults: defaults)
        settings.setThresholds(low: 0, high: 100)
        XCTAssertGreaterThanOrEqual(settings.lowMidThreshold, 1)
        XCTAssertLessThanOrEqual(settings.midHighThreshold, 99)
    }

    @MainActor
    func testResetToDefaults() {
        let settings = AIUsageColorSettings(userDefaults: defaults)
        settings.lowColorHex = "#000000"
        settings.midColorHex = "#000000"
        settings.highColorHex = "#000000"
        settings.setThresholds(low: 30, high: 60)
        settings.interpolate = false

        settings.resetToDefaults()
        XCTAssertEqual(settings.lowColorHex, AIUsageColorSettings.defaultLowColorHex)
        XCTAssertEqual(settings.lowMidThreshold, AIUsageColorSettings.defaultLowMidThreshold)
        XCTAssertEqual(settings.midHighThreshold, AIUsageColorSettings.defaultMidHighThreshold)
        XCTAssertEqual(settings.interpolate, AIUsageColorSettings.defaultInterpolate)
    }

    @MainActor
    func testColorForPercentBoundsAreClamped() {
        let settings = AIUsageColorSettings(userDefaults: defaults)
        settings.interpolate = false
        // Below 0 must clamp to the same color as 0.
        XCTAssertEqual(
            settings.color(for: -50).rgbComponents.red,
            settings.color(for: 0).rgbComponents.red,
            accuracy: 0.001,
            "negative percent must clamp to the 0% bucket"
        )
        // Above 100 must clamp to the same color as 100.
        XCTAssertEqual(
            settings.color(for: 1000).rgbComponents.red,
            settings.color(for: 100).rgbComponents.red,
            accuracy: 0.001,
            "very large percent must clamp to the 100% bucket"
        )
        // 0 sits in the low bucket; 100 sits in the high bucket: the two are not equal.
        let zero = settings.color(for: 0).rgbComponents
        let hundred = settings.color(for: 100).rgbComponents
        let same = abs(zero.red - hundred.red) < 0.001
            && abs(zero.green - hundred.green) < 0.001
            && abs(zero.blue - hundred.blue) < 0.001
        XCTAssertFalse(same, "0% and 100% must not produce the same color")
    }

    @MainActor
    func testInterpolationOffMatchesDiscreteBuckets() {
        let settings = AIUsageColorSettings(userDefaults: defaults)
        settings.interpolate = false
        let lowerBucket = settings.color(for: 10)
        let lowerBucket2 = settings.color(for: 20)
        XCTAssertEqual(lowerBucket.rgbComponents.red, lowerBucket2.rgbComponents.red, accuracy: 0.001)
    }
}

extension Color {
    fileprivate var testRGB: (Double, Double, Double) { rgbComponents }
}

final class AIUsageColorHexTests: XCTestCase {
    func testParsesHexWithAndWithoutHash() {
        XCTAssertNotNil(Color(usageHex: "#46B46E"))
        XCTAssertNotNil(Color(usageHex: "46B46E"))
        XCTAssertNil(Color(usageHex: "#GGG"))
        XCTAssertNil(Color(usageHex: "#1234"))
    }
}

final class AIUsageRegistryCodexTests: XCTestCase {
    func testRegistryContainsCodex() {
        let codex = AIUsageRegistry.provider(id: "codex")
        XCTAssertNotNil(codex)
        XCTAssertEqual(codex?.displayName, "Codex")
        XCTAssertEqual(codex?.keychainService, "com.stage11.c11.aiusage.codex-accounts")
        XCTAssertFalse(codex?.credentialFields.isEmpty ?? true)
    }

    func testProviderIdsAreUnique() {
        let ids = AIUsageRegistry.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testUIProvidersAllHaveCredentialFields() {
        for provider in AIUsageRegistry.ui {
            XCTAssertFalse(provider.credentialFields.isEmpty, "\(provider.id) has no fields")
        }
    }
}

final class AIUsagePollerLifecycleTests: XCTestCase {
    private let suiteName = "c11.aiusage.poller.tests.\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor
    func testStartIsIdempotent() async {
        let store = AIUsageAccountStore(
            userDefaults: defaults,
            indexKey: "c11.aiusage.poller.\(UUID().uuidString)"
        )
        let firstTickFired = expectation(description: "first start fires one tick")
        var ticks = 0
        let poller = AIUsagePoller(
            store: store,
            providersResolver: { [] },
            providerByIdResolver: { _ in nil },
            tickInterval: 60,
            visibilityProvider: { true },
            tickBody: { _ in
                ticks += 1
                if ticks == 1 { firstTickFired.fulfill() }
            }
        )
        poller.start()
        await fulfillment(of: [firstTickFired], timeout: 1.0)
        let baseline = ticks
        poller.start()
        // Allow any spurious second tick a chance to schedule onto the runloop.
        await Task.yield()
        XCTAssertEqual(ticks, baseline, "second start must not enqueue extra ticks")
        poller.stop()
    }

    @MainActor
    func testLoadWithMalformedBlobLeavesBytesIntact() {
        let key = "c11.aiusage.poller.malformed.\(UUID().uuidString)"
        let malformed = Data([0x42, 0x00, 0x99, 0xFE])
        defaults.set(malformed, forKey: key)

        let store = AIUsageAccountStore(
            userDefaults: defaults,
            indexKey: key
        )
        XCTAssertTrue(store.accounts.isEmpty,
                      "load() must end with no accounts on decode failure")
        let surviving = defaults.data(forKey: key)
        XCTAssertEqual(surviving, malformed,
                       "load() must not delete the underlying UserDefaults blob")
    }

    @MainActor
    func testRefreshNowAfterStopDoesNotRestartPolling() async {
        let store = AIUsageAccountStore(
            userDefaults: defaults,
            indexKey: "c11.aiusage.poller.\(UUID().uuidString)"
        )
        let firstTickFired = expectation(description: "start-time forced tick")
        var ticks = 0
        let poller = AIUsagePoller(
            store: store,
            providersResolver: { [] },
            providerByIdResolver: { _ in nil },
            tickInterval: 60,
            visibilityProvider: { true },
            tickBody: { _ in
                ticks += 1
                if ticks == 1 { firstTickFired.fulfill() }
            }
        )
        poller.start()
        await fulfillment(of: [firstTickFired], timeout: 1.0)
        poller.stop()
        let baseline = ticks
        poller.refreshNow()
        // Yield to let any erroneous tick schedule before we assert.
        await Task.yield()
        XCTAssertEqual(ticks, baseline, "refreshNow after stop must be inert")
    }
}

final class CodexAIUsageFetcherParseTests: XCTestCase {
    private func makeWindow(_ usedPercent: Any) -> [String: Any] {
        return [
            "used_percent": usedPercent,
            "limit_window_seconds": 18_000,
        ]
    }

    func testParseWindowRejectsMissingUsedPercent() {
        let raw: [String: Any] = ["limit_window_seconds": 18_000]
        XCTAssertThrowsError(try CodexAIUsageFetcher.parseWindow(raw)) { error in
            XCTAssertTrue(error is CodexAIUsageFetchError, "expected .decoding for missing used_percent")
        }
    }

    func testParseWindowRejectsNSNullUsedPercent() {
        XCTAssertThrowsError(try CodexAIUsageFetcher.parseWindow(makeWindow(NSNull()))) { error in
            XCTAssertTrue(error is CodexAIUsageFetchError, "expected .decoding for NSNull used_percent")
        }
    }

    func testParseWindowRejectsBoolUsedPercent() {
        XCTAssertThrowsError(try CodexAIUsageFetcher.parseWindow(makeWindow(true))) { error in
            XCTAssertTrue(error is CodexAIUsageFetchError, "expected .decoding for bool used_percent")
        }
    }

    func testParseWindowRejectsNonNumericStringUsedPercent() {
        XCTAssertThrowsError(try CodexAIUsageFetcher.parseWindow(makeWindow("oops"))) { error in
            XCTAssertTrue(error is CodexAIUsageFetchError, "expected .decoding for string used_percent")
        }
    }

    func testParseWindowAcceptsValidIntegerUsedPercent() throws {
        let window = try CodexAIUsageFetcher.parseWindow(makeWindow(42))
        XCTAssertEqual(window.utilization, 42)
    }

    func testParseWindowsAcceptsPayloadWithoutSecondaryWindow() throws {
        let payload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 25,
                    "limit_window_seconds": 18_000,
                ],
            ],
        ]
        let windows = try CodexAIUsageFetcher.parseWindows(payload: payload)
        XCTAssertEqual(windows.session.utilization, 25)
        XCTAssertEqual(windows.week.utilization, 0,
                       "missing secondary_window must degrade to a synthetic empty week window")
        XCTAssertNil(windows.week.resetsAt,
                     "missing secondary_window has no reset date")
        XCTAssertEqual(windows.week.windowSeconds, 604_800)
    }
}
