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

    /// Surface-scoped project directory the Claude session was created in
    /// (its current-working-directory at `SessionStart`). Written alongside
    /// `claude.session_id` by the same hook. The pair is atomic: claude's
    /// session JSONL files are stored under `~/.claude/projects/<encoded-cwd>/<id>.jsonl`
    /// and `claude --resume <id>` looks them up by the *current* shell's
    /// cwd, so a session captured in a worktree subdir cannot be resumed
    /// from its parent directory. The registry uses this value to `cd`
    /// into the recorded directory before issuing `claude --resume`.
    public static let claudeSessionProjectDir = "claude.session_project_dir"

    /// **Reserved namespace — not currently written by any production path.**
    /// Opencode capture rides the plugin push rail (`session.created` →
    /// `c11 conversation push`) and the SQLite scrape rail; both produce a
    /// `ConversationRef` directly, and neither writes this metadata key. The
    /// key + its `isValidOpencodeSessionId` grammar are kept reserved (and
    /// validated at the store boundary) so a future opencode hook that records
    /// the id has a safe, ready home — mirroring the live `claude.session_id`
    /// wrapper rail. Opencode session IDs are `ses_` + a 26-character
    /// **base62** body (`[0-9A-Za-z]`), NOT UUIDs — see
    /// `isValidOpencodeSessionId`. The `opencode.*` prefix does not collide
    /// with the C11-13 `mailbox.*` namespace.
    public static let opencodeSessionId = "opencode.session_id"

    /// **Reserved namespace — not currently written by any production path**
    /// (companion to `opencodeSessionId`; same rationale — capture rides the
    /// plugin/scrape rails, not metadata keys). Same project-dir grammar as
    /// the claude key, validated via `isValidOpencodeSessionProjectDir`, which
    /// delegates to the shared `isValidClaudeSessionProjectDir`.
    public static let opencodeSessionProjectDir = "opencode.session_project_dir"

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

/// Project-dir grammar for `claude.session_project_dir`. Must be an
/// absolute POSIX path with no NUL, newline, carriage return, or single
/// quote. The single-quote ban is what lets the registry's single-quote
/// shell escape stay a no-op even under defense-in-depth. Length cap is
/// 4096 — well above Darwin's 1024 PATH_MAX, with headroom for synthetic
/// or encoded paths.
///
/// File-scoped so both `SurfaceMetadataStore.validateReservedKey` (in the
/// app target) and the `c11 claude-hook session-start` handler (in the
/// CLI target) can share one definition. `WorkspaceMetadataKeys.swift` is
/// the only file linked into both targets that the schema layer naturally
/// reaches for.
public let claudeSessionProjectDirMaxLen = 4096
nonisolated public func isValidClaudeSessionProjectDir(_ candidate: String) -> Bool {
    guard candidate.first == "/" else { return false }
    if candidate.count > claudeSessionProjectDirMaxLen { return false }
    for scalar in candidate.unicodeScalars {
        switch scalar.value {
        case 0x00, 0x0A, 0x0D, 0x27: return false  // NUL, LF, CR, '
        default: continue
        }
    }
    return true
}

/// Grammar for `opencode.session_id`: `ses_` + a 26-character **base62**
/// body (`[0-9A-Za-z]`). Verified against a live opencode 1.17.5 store —
/// all 131 local `session` rows match this exactly, and 83 of them contain
/// `I`/`L`/`O`/`U` in the body. A Crockford-base32 alphabet (which excludes
/// those four letters) would wrongly reject those 83 ids, so base62 is the
/// load-bearing grammar, not a stylistic choice. Anchored so any
/// non-matching prefix/suffix — shell metacharacters, embedded newlines,
/// extra tokens — is rejected. Declared `nonisolated` + `public` so
/// `SurfaceMetadataStore.validateReservedKey` (off the main actor) and the
/// strategy/CLI validation share one compiled regex without cross-actor
/// traffic.
///
/// Defence in depth mirrors `isValidClaudeSessionId`: the store rejects
/// malformed writes at the boundary; the strategy re-validates at resume
/// time so a value that slipped past the store cannot become a shell
/// command.
let opencodeSessionIdPattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(
        pattern: "^ses_[0-9A-Za-z]{26}$",
        options: []
    )
}()

/// Returns true iff `candidate` matches `ses_` + 26-char base62 body
/// exactly. Trims nothing — callers normalise whitespace before calling.
nonisolated public func isValidOpencodeSessionId(_ candidate: String) -> Bool {
    let range = NSRange(location: 0, length: (candidate as NSString).length)
    return opencodeSessionIdPattern.firstMatch(in: candidate, options: [], range: range) != nil
}

/// Path grammar for `opencode.session_project_dir`. Identical to
/// `claude.session_project_dir` (absolute POSIX path, no NUL/newline/
/// carriage-return/single-quote, ≤4096). Delegates to the shared
/// `isValidClaudeSessionProjectDir` rather than duplicating the body — the
/// grammar is operator-path-shaped, not agent-specific.
nonisolated public func isValidOpencodeSessionProjectDir(_ candidate: String) -> Bool {
    return isValidClaudeSessionProjectDir(candidate)
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
