import Foundation

/// Marker protocol for errors whose `errorDescription` is owned by c11
/// and safe to surface to the UI as-is. Errors that do not conform fall
/// back to a generic catalog string so raw OS wording (URLError's
/// localized descriptions, framework strings) never leaks into user-
/// visible text.
///
/// Conform any user-facing error type whose localized description is
/// authored by c11 (typically via `String(localized:)` against the
/// xcstrings catalog).
protocol C11AppOwnedError {
    var isAppOwned: Bool { get }
}
