import Foundation

/// Decay stage for an age-classified sidebar status/progress value.
///
/// C11-162 (Telemetry truth): sidebar status pills and progress
/// indicators visually decay by age so operators can tell a live
/// agent-reported value from one that has gone silent.
public enum SidebarDecayStage: Equatable {
    /// Recently written — render at full emphasis.
    case fresh
    /// Older than the stale threshold — render dimmed with a small age hint.
    case stale
    /// Older than the expiry threshold — render grayed-out; the writer is
    /// presumed silent and (where available) a derived pill takes over.
    case expired
}

/// Operator-tunable thresholds + the pure age→stage classifier for the
/// sidebar decay system. Values are read from `UserDefaults` (bound to the
/// two `@AppStorage` settings rows) and clamped into a sane range. Both
/// resolvers honor an environment override so tests and debugging can pin
/// the thresholds without touching user prefs.
public enum SidebarStalenessSettings {
    static let staleThresholdKey = "sidebarStaleThresholdSeconds"
    static let expiryThresholdKey = "sidebarExpiryThresholdSeconds"

    static let defaultStaleSeconds: Double = 300
    static let defaultExpirySeconds: Double = 900

    static let minSeconds: Double = 5
    static let maxSeconds: Double = 3600

    static let staleEnvKey = "C11_SIDEBAR_STALE_SECONDS"
    static let expiryEnvKey = "C11_SIDEBAR_EXPIRE_SECONDS"

    /// Clamp any candidate threshold into `[minSeconds, maxSeconds]`.
    static func clamp(_ value: Double) -> Double {
        min(max(value, minSeconds), maxSeconds)
    }

    /// Resolved stale threshold in seconds. Env override wins, then the
    /// stored setting, then the default. Always clamped.
    static func staleSeconds(defaults: UserDefaults = .standard) -> Double {
        staleSeconds(defaults: defaults, environment: ProcessInfo.processInfo.environment)
    }

    /// Resolved expiry threshold in seconds. Env override wins, then the
    /// stored setting, then the default. Always clamped.
    static func expirySeconds(defaults: UserDefaults = .standard) -> Double {
        expirySeconds(defaults: defaults, environment: ProcessInfo.processInfo.environment)
    }

    /// Testable seam: resolve with an explicit environment dictionary.
    static func staleSeconds(defaults: UserDefaults, environment: [String: String]) -> Double {
        if let raw = environment[staleEnvKey], let value = Double(raw) {
            return clamp(value)
        }
        let stored = (defaults.object(forKey: staleThresholdKey) as? Double) ?? defaultStaleSeconds
        return clamp(stored)
    }

    /// Testable seam: resolve with an explicit environment dictionary.
    static func expirySeconds(defaults: UserDefaults, environment: [String: String]) -> Double {
        if let raw = environment[expiryEnvKey], let value = Double(raw) {
            return clamp(value)
        }
        let stored = (defaults.object(forKey: expiryThresholdKey) as? Double) ?? defaultExpirySeconds
        return clamp(stored)
    }

    /// Pure classifier: map an age (seconds) to a decay stage. Boundaries
    /// are inclusive on the upper side — `age == staleSeconds` is `.stale`,
    /// `age == expirySeconds` is `.expired`. A negative age (clock skew)
    /// is treated as fresh.
    static func stage(ageSeconds: Double, staleSeconds: Double, expirySeconds: Double) -> SidebarDecayStage {
        if ageSeconds < staleSeconds { return .fresh }
        if ageSeconds < expirySeconds { return .stale }
        return .expired
    }
}
