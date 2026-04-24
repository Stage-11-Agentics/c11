import Foundation

/// Canonical operator-authored workspace metadata keys.
///
/// Workspace-scoped. Distinct from `MetadataKey` in `SurfaceMetadataStore.swift`
/// (surface-scoped). The same string literal (e.g. `"description"`) carries
/// different meaning in each namespace; do not cross them.
public enum WorkspaceMetadataKey {
    public static let description = "description"
    public static let icon = "icon"

    public static let canonical: Set<String> = [description, icon]
}

/// Surface-scoped metadata keys used by the Phase 1 Snapshot + restart
/// registry paths. Kept here — beside `WorkspaceMetadataKey` — so the
/// spelling lives in one place and a future rename stays grep-tractable.
/// `SurfaceMetadataStore.reservedKeys` still owns the canonical-set
/// validation for keys like `"terminal_type"` / `"status"`; this enum
/// only names the keys the executor and capture walker reach for by
/// hand.
public enum SurfaceMetadataKeyName {
    /// Surface-scoped session id written by the `c11 claude-hook
    /// session-start` handler when Claude Code emits `SessionStart`.
    /// Consumed by `AgentRestartRegistry` at restore time to synthesise
    /// `cc --resume <id>`. The `claude.*` prefix is reserved per
    /// `docs/c11-13-cmux-37-alignment.md:34` and does not collide with
    /// the C11-13 `mailbox.*` (pane-scoped) namespace.
    public static let claudeSessionId = "claude.session_id"

    /// Canonical `terminal_type` key (same literal as
    /// `SurfaceMetadataStore.reservedKeys`). Named here for executor
    /// readability; validation still flows through the store's reserved
    /// set.
    public static let terminalType = "terminal_type"

    /// Canonical `terminal_type` value for a Claude Code surface. Matches
    /// what `c11 set-agent --type claude-code` writes and what the
    /// Phase 1 restart registry keys against.
    public static let terminalTypeClaudeCode = "claude-code"
}

/// Validation for workspace metadata writes.
///
/// Values for canonical keys have specific caps; unknown keys are accepted up
/// to the generic caps below. All keys must match a conservative ASCII
/// grammar to keep the socket wire shape stable and to avoid escape surprises
/// in logs and CLI output.
public enum WorkspaceMetadataValidator {
    public static let maxDescriptionLen = 2048
    public static let maxIconLen = 32
    public static let maxCustomKeys = 32
    public static let maxCustomKeyLen = 64
    public static let maxCustomValueLen = 1024

    /// Key grammar: non-empty ASCII letters/digits/underscore/dot/hyphen.
    /// Pattern: `^[A-Za-z0-9_.\-]+$`. No whitespace, no arbitrary UTF-8.
    public static let keyPattern = #"^[A-Za-z0-9_.\-]+$"#

    public enum ValidationError: Error, Equatable {
        case emptyKey
        case keyTooLong(limit: Int)
        case keyInvalidCharacters
        case valueTooLong(key: String, limit: Int)

        public var code: String {
            switch self {
            case .emptyKey: return "invalid_key"
            case .keyTooLong: return "invalid_key"
            case .keyInvalidCharacters: return "invalid_key"
            case .valueTooLong: return "value_too_long"
            }
        }

        public var message: String {
            switch self {
            case .emptyKey:
                return "metadata key must be non-empty"
            case .keyTooLong(let limit):
                return "metadata key exceeds max length \(limit)"
            case .keyInvalidCharacters:
                return "metadata key must match [A-Za-z0-9_.-]+"
            case .valueTooLong(let key, let limit):
                return "metadata value for '\(key)' exceeds max length \(limit)"
            }
        }

        public var detail: [String: Any]? {
            switch self {
            case .valueTooLong(let key, let limit):
                return ["key": key, "limit": limit]
            case .keyTooLong(let limit):
                return ["limit": limit]
            default:
                return nil
            }
        }
    }

    public enum CapacityError: Error, Equatable {
        case tooManyKeys(limit: Int)

        public var code: String { "too_many_keys" }
        public var message: String {
            switch self {
            case .tooManyKeys(let limit):
                return "workspace metadata exceeds max \(limit) keys"
            }
        }
        public var detail: [String: Any]? {
            switch self {
            case .tooManyKeys(let limit):
                return ["limit": limit]
            }
        }
    }

    private static let keyRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: keyPattern, options: [])
    }()

    /// Validate a key/value pair for writing.
    public static func validate(key: String, value: String) throws {
        try validateKey(key)
        try validateValue(key: key, value: value)
    }

    /// Validate a key grammar only (used for deletion paths).
    public static func validateKey(_ key: String) throws {
        if key.isEmpty { throw ValidationError.emptyKey }
        if key.count > maxCustomKeyLen {
            throw ValidationError.keyTooLong(limit: maxCustomKeyLen)
        }
        let range = NSRange(location: 0, length: (key as NSString).length)
        if keyRegex.firstMatch(in: key, options: [], range: range) == nil {
            throw ValidationError.keyInvalidCharacters
        }
    }

    private static func validateValue(key: String, value: String) throws {
        let limit = valueLimit(for: key)
        if value.count > limit {
            throw ValidationError.valueTooLong(key: key, limit: limit)
        }
    }

    /// Cap (in characters) for a given key. Canonical keys have dedicated
    /// limits; anything else falls back to the generic custom-value cap.
    public static func valueLimit(for key: String) -> Int {
        switch key {
        case WorkspaceMetadataKey.description: return maxDescriptionLen
        case WorkspaceMetadataKey.icon: return maxIconLen
        default: return maxCustomValueLen
        }
    }

    /// Validate the post-write map does not exceed the custom-key count cap.
    /// Canonical keys do not count against the custom-key budget.
    public static func validateCapacity(after candidate: [String: String]) throws {
        let customCount = candidate.keys.filter { !WorkspaceMetadataKey.canonical.contains($0) }.count
        if customCount > maxCustomKeys {
            throw CapacityError.tooManyKeys(limit: maxCustomKeys)
        }
    }
}
