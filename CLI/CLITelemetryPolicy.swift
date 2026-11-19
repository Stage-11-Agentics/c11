import Foundation

/// c11 sends no telemetry from the app or from the bundled CLI. The CLI's
/// Sentry reporting is opt-in through an inherited debugging DSN; a private fork
/// must not honor it, because it reports to the DSN's project and carries paths.
/// Compiled into both the CLI and the app so logic tests can exercise it.
enum CLITelemetryPolicy {
    /// The DSN the CLI may report to. Always nil in c11, whatever the
    /// environment says (`C11_CLI_SENTRY_DSN`, legacy `CMUX_CLI_SENTRY_DSN`).
    static func configuredDSN(_ processEnv: [String: String]) -> String? {
        nil
    }
}
