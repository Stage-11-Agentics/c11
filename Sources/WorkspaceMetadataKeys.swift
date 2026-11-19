import Foundation

/// c11's default named color palette (workspace, tab and group colors). Lives
/// here because this file compiles into both the app and the `c11` CLI, so
/// `list-palette` prints exactly the names the app resolves.
/// `WorkspaceColorSettings` layers the operator's per-name hex overrides and
/// custom colors on top.
public enum DefaultColorPalette {
    public static let entries: [(name: String, hex: String)] = [
        ("Red", "#C0392B"),
        ("Crimson", "#922B21"),
        ("Orange", "#A04000"),
        ("Amber", "#7D6608"),
        ("Olive", "#4A5C18"),
        ("Green", "#196F3D"),
        ("Teal", "#006B6B"),
        ("Aqua", "#0E6B8C"),
        ("Blue", "#1565C0"),
        ("Navy", "#1A5276"),
        ("Indigo", "#283593"),
        ("Purple", "#6A1B9A"),
        ("Magenta", "#AD1457"),
        ("Rose", "#880E4F"),
        ("Brown", "#7B3F00"),
        ("Charcoal", "#3E4B5E"),
    ]
}

/// Canonical operator-authored workspace metadata keys.
///
/// Workspace-scoped. Distinct from `MetadataKey` in `SurfaceMetadataStore.swift`
/// (surface-scoped). The same string literal (e.g. `"description"`) carries
/// different meaning in each namespace; do not cross them.
public enum WorkspaceMetadataKey {
    public static let description = "description"
    public static let icon = "icon"
    public static let captain = "captain"

    public static let canonical: Set<String> = [description, icon, captain]
}

/// Surface-scoped metadata keys used by the Phase 1 Snapshot + restart
/// registry paths. Kept here — beside `WorkspaceMetadataKey` — so the
/// spelling lives in one place and a future rename stays grep-tractable.
/// `SurfaceMetadataStore.reservedKeys` still owns the canonical-set
/// validation for keys like `"terminal_type"` / `"status"`; this enum
/// only names the keys the executor and capture walker reach for by
/// hand.
public enum PanelMetadataKeyName {
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

/// C11H-365 (N12): true when `text` holds a C0 control byte (0x00-0x1F) or
/// DEL (0x7F). A shell's line editor reads those as editing keys even
/// inside single quotes, so a resume line typed into a terminal never
/// carries one.
nonisolated public func containsTerminalControlByte(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

/// Project-dir grammar for `claude.session_project_dir`. Must be an
/// absolute POSIX path with no C0 control byte, DEL, or single quote
/// (C11H-365: every control byte, not only NUL, LF and CR). The single-quote
/// ban is what lets the registry's single-quote shell escape stay a no-op
/// even under defense-in-depth. Length cap is 4096 — well above Darwin's
/// 1024 PATH_MAX, with headroom for synthetic or encoded paths.
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
    if containsTerminalControlByte(candidate) { return false }
    return !candidate.unicodeScalars.contains { $0.value == 0x27 }  // '
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
/// Values for canonical keys have specific caps; unknown keys accept JSON and
/// the store caps the complete object at 64 KiB. All new keys match an ASCII
/// grammar to keep the socket wire shape stable and to avoid escape surprises
/// in logs and CLI output.
public enum WorkspaceMetadataValidator {
    public static let maxDescriptionLen = 2048
    public static let maxIconLen = 32
    public static let payloadCapBytes = 64 * 1024
    public static let maxCaptainBytes = 256
    public static let maxCustomKeyLen = 64

    /// Key grammar: non-empty ASCII letters/digits/underscore/dot/hyphen.
    /// Pattern: `^[A-Za-z0-9_.\-]+$`. No whitespace, no arbitrary UTF-8.
    public static let keyPattern = #"^[A-Za-z0-9_.\-]+$"#

    public enum ValidationError: Error, Equatable {
        case emptyKey
        case keyTooLong(limit: Int)
        case keyInvalidCharacters
        case valueTooLong(key: String, limit: Int)
        case invalidValue(key: String, reason: String)

        public var code: String {
            switch self {
            case .emptyKey: return "invalid_key"
            case .keyTooLong: return "invalid_key"
            case .keyInvalidCharacters: return "invalid_key"
            case .valueTooLong: return "value_too_long"
            case .invalidValue: return "invalid_value"
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
            case .invalidValue(let key, let reason):
                return String(format: String(localized: "workspace.metadata.invalidValue",
                    defaultValue: "Metadata value for '%@' %@"), key, reason)
            }
        }

        public var detail: [String: Any]? {
            switch self {
            case .valueTooLong(let key, let limit):
                return ["key": key, "limit": limit]
            case .invalidValue(let key, _):
                return ["key": key]
            case .keyTooLong(let limit):
                return ["limit": limit]
            default:
                return nil
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
        _ = try normalizedValue(key: key, value: value)
    }

    public static func validate(key: String, value: Any) throws {
        _ = try normalizedValue(key: key, value: value)
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

    /// Canonical values stay strings; custom keys accept every JSON value.
    public static func normalizedValue(key: String, value: Any) throws -> Any {
        try validateKey(key)
        if key == WorkspaceMetadataKey.captain { return try normalizedCaptain(value) }
        if key == WorkspaceMetadataKey.description || key == WorkspaceMetadataKey.icon {
            guard let string = value as? String else {
                throw ValidationError.invalidValue(key: key, reason: String(localized: "workspace.metadata.requiresString", defaultValue: "must be a string"))
            }
            let limit = valueLimit(for: key)
            if string.count > limit { throw ValidationError.valueTooLong(key: key, limit: limit) }
        }
        return value
    }

    public static func normalizedCaptain(_ value: Any) throws -> String {
        let key = WorkspaceMetadataKey.captain
        guard let raw = value as? String else {
            throw ValidationError.invalidValue(key: key, reason: String(localized: "workspace.metadata.requiresString", defaultValue: "must be a string"))
        }
        // Reject line breaks and controls before trimming so a trailing newline
        // cannot turn an invalid multiline identity into an accepted address.
        guard !raw.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) else {
            throw ValidationError.invalidValue(key: key, reason: String(localized: "workspace.metadata.captain.singleLine", defaultValue: "must be a single line without control characters"))
        }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw ValidationError.invalidValue(key: key, reason: String(localized: "workspace.metadata.captain.nonempty", defaultValue: "must be non-empty; clear the key to remove it"))
        }
        guard value.utf8.count <= maxCaptainBytes else {
            throw ValidationError.valueTooLong(key: key, limit: maxCaptainBytes)
        }
        return value
    }

    public static func valueLimit(for key: String) -> Int {
        switch key {
        case WorkspaceMetadataKey.description: return maxDescriptionLen
        case WorkspaceMetadataKey.icon: return maxIconLen
        case WorkspaceMetadataKey.captain: return maxCaptainBytes
        default: return Int.max // Custom values are bounded by the whole JSON object.
        }
    }
}
