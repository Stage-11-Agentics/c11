import Foundation

/// A distributed channel that real users run and that may report telemetry.
enum TelemetryChannel: String, Equatable {
    /// The production Release app (`com.stage11.c11`).
    case production
    /// The public nightly app (`com.stage11.c11.nightly`), built daily by
    /// `nightly.yml` and published with its own DMG and Sparkle feed.
    case nightly

    /// Sentry `environment` for this channel. Production keeps the value it
    /// has always sent.
    var sentryEnvironment: String {
        switch self {
        case .production: return "production"
        case .nightly: return "nightly"
        }
    }

    /// Extra PostHog super properties for this channel. Production registers
    /// none, so its events are unchanged.
    var postHogSuperProperties: [String: Any] {
        switch self {
        case .production: return [:]
        case .nightly: return ["$environment": "nightly"]
        }
    }
}

/// Whether this launch may start Sentry and PostHog, and why not when it may not.
struct TelemetryLaunchDecision: Equatable {
    enum OffReason: Equatable {
        case userOptedOut
        case missingBundleIdentifier
        case unreleasedIdentity(String)
    }

    let channel: TelemetryChannel?
    let offReason: OffReason?

    var isEnabled: Bool { channel != nil }

    static func on(_ channel: TelemetryChannel) -> TelemetryLaunchDecision {
        TelemetryLaunchDecision(channel: channel, offReason: nil)
    }

    static func off(_ reason: OffReason) -> TelemetryLaunchDecision {
        TelemetryLaunchDecision(channel: nil, offReason: reason)
    }

    /// The one startup log line for an off launch; nil when telemetry is on.
    var offLogLine: String? {
        guard let offReason else { return nil }
        switch offReason {
        case .userOptedOut:
            return "telemetry.off reason=user_opted_out"
        case .missingBundleIdentifier:
            return "telemetry.off reason=no_bundle_id"
        case .unreleasedIdentity(let bundleIdentifier):
            return "telemetry.off reason=unreleased_bundle_id bundle_id=\(bundleIdentifier)"
        }
    }
}

/// Telemetry may start only in the identities that real users run. Staging,
/// tagged Debug, sandbox-guest builds, c11h and any unknown bundle id start
/// no SDK and send nothing, whatever the user setting says.
enum TelemetryIdentityGate {
    static let productionBundleIdentifier = "com.stage11.c11"
    static let nightlyBundleIdentifier = "com.stage11.c11.nightly"

    static func decide(bundleIdentifier: String?, userEnabled: Bool) -> TelemetryLaunchDecision {
        guard userEnabled else { return .off(.userOptedOut) }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .off(.missingBundleIdentifier)
        }
        switch bundleIdentifier {
        case productionBundleIdentifier:
            return .on(.production)
        case nightlyBundleIdentifier:
            return .on(.nightly)
        default:
            return .off(.unreleasedIdentity(bundleIdentifier))
        }
    }
}

/// Startup seam for both SDKs. AppDelegate passes the real starters; tests
/// pass recording ones to prove an off launch starts neither.
struct TelemetryStartup {
    let decision: TelemetryLaunchDecision
    let isRunningUnderXCTest: Bool

    /// The channel to start, or nil when nothing may start.
    var channelToStart: TelemetryChannel? {
        guard !isRunningUnderXCTest else { return nil }
        return decision.channel
    }

    /// Logs the off line once at startup. XCTest hosts stay quiet.
    func logIfOff(_ log: (String) -> Void) {
        guard !isRunningUnderXCTest, let line = decision.offLogLine else { return }
        log(line)
    }

    func startSentryIfAllowed(_ start: (TelemetryChannel) -> Void) {
        guard let channel = channelToStart else { return }
        start(channel)
    }

    func startPostHogIfAllowed(_ start: (TelemetryChannel) -> Void) {
        guard let channel = channelToStart else { return }
        start(channel)
    }
}
