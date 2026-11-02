import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-575: telemetry starts only in the identities real users run.
final class TelemetryIdentityGateTests: XCTestCase {
    private let offIdentities = [
        "com.stage11.c11.staging",
        "com.stage11.c11.staging.rel.v1.7.9",
        "com.stage11.c11.debug",
        "com.stage11.c11.debug.c11.575",
        "com.stage11.c11h",
        "com.example.unknown",
        "com.stage11.c11.nightly.extra",
        "COM.STAGE11.C11",
    ]

    func testProductionIdentityIsOnWithProductionEnvironment() {
        let decision = TelemetryIdentityGate.decide(bundleIdentifier: "com.stage11.c11", userEnabled: true)
        XCTAssertEqual(decision, .on(.production))
        XCTAssertTrue(decision.isEnabled)
        XCTAssertNil(decision.offLogLine)
        XCTAssertEqual(decision.channel?.sentryEnvironment, "production")
        XCTAssertTrue(decision.channel?.postHogSuperProperties.isEmpty ?? false)
    }

    func testNightlyIdentityIsOnWithItsOwnEnvironment() {
        let decision = TelemetryIdentityGate.decide(bundleIdentifier: "com.stage11.c11.nightly", userEnabled: true)
        XCTAssertEqual(decision, .on(.nightly))
        XCTAssertTrue(decision.isEnabled)
        XCTAssertEqual(decision.channel?.sentryEnvironment, "nightly")
        XCTAssertEqual(decision.channel?.postHogSuperProperties["$environment"] as? String, "nightly")
    }

    func testStagingTaggedDebugC11hAndUnknownIdentitiesAreOff() {
        for identity in offIdentities {
            let decision = TelemetryIdentityGate.decide(bundleIdentifier: identity, userEnabled: true)
            XCTAssertFalse(decision.isEnabled, identity)
            XCTAssertNil(decision.channel, identity)
            XCTAssertEqual(decision.offReason, .unreleasedIdentity(identity), identity)
            XCTAssertEqual(
                decision.offLogLine,
                "telemetry.off reason=unreleased_bundle_id bundle_id=\(identity)",
                identity
            )
        }
    }

    func testMissingBundleIdentifierIsOff() {
        for identity in [nil, ""] as [String?] {
            let decision = TelemetryIdentityGate.decide(bundleIdentifier: identity, userEnabled: true)
            XCTAssertFalse(decision.isEnabled)
            XCTAssertEqual(decision.offLogLine, "telemetry.off reason=no_bundle_id")
        }
    }

    func testUserOptOutIsOffInEveryIdentity() {
        for identity in ["com.stage11.c11", "com.stage11.c11.nightly"] + offIdentities {
            let decision = TelemetryIdentityGate.decide(bundleIdentifier: identity, userEnabled: false)
            XCTAssertFalse(decision.isEnabled, identity)
            XCTAssertEqual(decision.offReason, .userOptedOut, identity)
            XCTAssertEqual(decision.offLogLine, "telemetry.off reason=user_opted_out", identity)
        }
    }

    func testTestHostResolvesOff() {
        // The logic-test runner is not a released identity, so the frozen
        // launch value every Sentry and PostHog path reads is off here.
        XCTAssertFalse(TelemetrySettings.enabledForCurrentLaunch)
        XCTAssertFalse(TelemetrySettings.launchDecision.isEnabled)
    }
}

/// C11-575: the startup seam AppDelegate drives with the real SDK starters.
final class TelemetryStartupTests: XCTestCase {
    private func run(_ startup: TelemetryStartup) -> (sentry: [TelemetryChannel], postHog: [TelemetryChannel], log: [String]) {
        var sentry: [TelemetryChannel] = []
        var postHog: [TelemetryChannel] = []
        var log: [String] = []
        startup.logIfOff { log.append($0) }
        startup.startSentryIfAllowed { sentry.append($0) }
        startup.startPostHogIfAllowed { postHog.append($0) }
        return (sentry, postHog, log)
    }

    func testOffIdentityStartsNeitherSDKAndLogsOneLine() {
        for identity in ["com.stage11.c11.staging", "com.stage11.c11.debug.c11.575", "com.stage11.c11h", "com.example.unknown"] {
            let decision = TelemetryIdentityGate.decide(bundleIdentifier: identity, userEnabled: true)
            let result = run(TelemetryStartup(decision: decision, isRunningUnderXCTest: false))
            XCTAssertEqual(result.sentry, [], identity)
            XCTAssertEqual(result.postHog, [], identity)
            XCTAssertEqual(result.log, ["telemetry.off reason=unreleased_bundle_id bundle_id=\(identity)"], identity)
        }
    }

    func testOptOutStartsNeitherSDK() {
        let decision = TelemetryIdentityGate.decide(bundleIdentifier: "com.stage11.c11", userEnabled: false)
        let result = run(TelemetryStartup(decision: decision, isRunningUnderXCTest: false))
        XCTAssertEqual(result.sentry, [])
        XCTAssertEqual(result.postHog, [])
        XCTAssertEqual(result.log, ["telemetry.off reason=user_opted_out"])
    }

    func testReleasedIdentitiesStartBothSDKsOnTheirChannel() {
        for (identity, channel) in [("com.stage11.c11", TelemetryChannel.production), ("com.stage11.c11.nightly", .nightly)] {
            let decision = TelemetryIdentityGate.decide(bundleIdentifier: identity, userEnabled: true)
            let result = run(TelemetryStartup(decision: decision, isRunningUnderXCTest: false))
            XCTAssertEqual(result.sentry, [channel], identity)
            XCTAssertEqual(result.postHog, [channel], identity)
            XCTAssertEqual(result.log, [], identity)
        }
    }

    func testXCTestHostStartsNothingEvenInProduction() {
        let result = run(TelemetryStartup(decision: .on(.production), isRunningUnderXCTest: true))
        XCTAssertEqual(result.sentry, [])
        XCTAssertEqual(result.postHog, [])
        XCTAssertEqual(result.log, [])
    }
}

/// C11-575: PostHogAnalytics never sets up the SDK (so no client, queue or
/// send) when the launch decision is off, through every public entry point.
final class PostHogAnalyticsGateTests: XCTestCase {
    private let productionKey = "phc_DfsnweKfe5uHUDK2scRVddAjpX8xGkq5NZWANmZaKo97"
    // Debug builds additionally require this; set it so only the gate decides.
    private let debugEnable = ["C11_POSTHOG_ENABLE": "1"]

    private final class Recorder {
        var requests: [PostHogSetupRequest] = []
    }

    func testOffDecisionNeverSetsUpTheSDK() {
        let offDecisions: [TelemetryLaunchDecision] = [
            TelemetryIdentityGate.decide(bundleIdentifier: "com.stage11.c11.staging", userEnabled: true),
            TelemetryIdentityGate.decide(bundleIdentifier: "com.stage11.c11.debug.c11.575", userEnabled: true),
            TelemetryIdentityGate.decide(bundleIdentifier: "com.stage11.c11h", userEnabled: true),
            TelemetryIdentityGate.decide(bundleIdentifier: "com.stage11.c11", userEnabled: false),
        ]
        for decision in offDecisions {
            let recorder = Recorder()
            let analytics = PostHogAnalytics(decision: decision, environment: debugEnable) { recorder.requests.append($0) }
            analytics.startIfNeeded()
            analytics.captureMainThreadHang(stalledMs: 9000, recapture: false, topFrame: "frame", cause: "test")
            analytics.flush()
            XCTAssertEqual(recorder.requests.count, 0, "\(decision)")
            XCTAssertFalse(analytics.hasStarted, "\(decision)")
        }
    }

    func testProductionDecisionSetsUpWithTheProductionKeyAndNoEnvironmentTag() {
        let recorder = Recorder()
        let analytics = PostHogAnalytics(decision: .on(.production), environment: debugEnable) { recorder.requests.append($0) }
        analytics.startIfNeeded()
        analytics.startIfNeeded()
        XCTAssertTrue(analytics.hasStarted)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.apiKey, productionKey)
        XCTAssertEqual(recorder.requests.first?.host, "https://us.i.posthog.com")
        XCTAssertEqual(recorder.requests.first?.superProperties["platform"] as? String, "c11")
        XCTAssertNil(recorder.requests.first?.superProperties["$environment"])
    }

    func testNightlyDecisionTagsItsEnvironment() {
        let recorder = Recorder()
        let analytics = PostHogAnalytics(decision: .on(.nightly), environment: debugEnable) { recorder.requests.append($0) }
        analytics.startIfNeeded()
        XCTAssertTrue(analytics.hasStarted)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.apiKey, productionKey)
        XCTAssertEqual(recorder.requests.first?.superProperties["$environment"] as? String, "nightly")
    }
}
