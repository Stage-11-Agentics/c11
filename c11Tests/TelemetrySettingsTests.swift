import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// c11 carries c11's Sentry and PostHog keys, so it must never start either.
final class TelemetrySettingsTests: XCTestCase {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "c11.tests.telemetry.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testTelemetryIsOffWhenTheKeyIsUnset() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(TelemetrySettings.isEnabled(defaults: defaults))
        XCTAssertFalse(TelemetrySettings.defaultSendAnonymousTelemetry)
    }

    func testTelemetryIsOffWhateverTheStoredPreferenceSays() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: TelemetrySettings.sendAnonymousTelemetryKey)
        XCTAssertFalse(TelemetrySettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: TelemetrySettings.sendAnonymousTelemetryKey)
        XCTAssertFalse(TelemetrySettings.isEnabled(defaults: defaults))
    }

    /// Both launch-time SDK starts (Sentry, PostHog) go through `TelemetryStartup`.
    /// c11's launch decision is off, and so is the gate for c11's bundle id
    /// whatever the stored preference says.
    func testLaunchStartupRefusesEveryTelemetrySDKOutsideXCTest() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        func startsNothing(_ decision: TelemetryLaunchDecision) {
            let startup = TelemetryStartup(decision: decision, isRunningUnderXCTest: false)
            var started: [TelemetryChannel] = []
            startup.startSentryIfAllowed { started.append($0) }
            startup.startPostHogIfAllowed { started.append($0) }
            XCTAssertNil(startup.channelToStart)
            XCTAssertEqual(started, [])
        }
        // The production path: ordinary app launch, the frozen launch decision.
        XCTAssertFalse(TelemetrySettings.launchDecision.isEnabled)
        XCTAssertFalse(TelemetrySettings.enabledForCurrentLaunch)
        // The log line names the identity, never a user choice the user did not make.
        let offLine = try XCTUnwrap(TelemetrySettings.launchDecision.offLogLine)
        XCTAssertTrue(offLine.contains("unreleased_bundle_id") || offLine.contains("no_bundle_id"), offLine)
        XCTAssertFalse(offLine.contains("user_opted_out"), offLine)
        startsNothing(TelemetrySettings.launchDecision)
        // Stored preference unset, true, false: still refused, under either id.
        for stored in [nil, true, false] as [Bool?] {
            if let stored { defaults.set(stored, forKey: TelemetrySettings.sendAnonymousTelemetryKey) }
            let userEnabled = TelemetrySettings.isEnabled(defaults: defaults)
            for bundleIdentifier in ["com.stage11.c11", "com.stage11.c11"] {
                startsNothing(TelemetryIdentityGate.decide(bundleIdentifier: bundleIdentifier, userEnabled: userEnabled))
            }
        }
    }

    /// The bundled CLI honors an inherited debugging DSN in c11; c11 must not.
    func testCLIIgnoresInheritedSentryDSN() {
        XCTAssertNil(CLITelemetryPolicy.configuredDSN([
            "C11_CLI_SENTRY_DSN": "https://key@o1.ingest.sentry.io/1",
        ]))
        XCTAssertNil(CLITelemetryPolicy.configuredDSN([
            "CMUX_CLI_SENTRY_DSN": "https://key@o1.ingest.sentry.io/1",
        ]))
        XCTAssertNil(CLITelemetryPolicy.configuredDSN([:]))
    }
}
