import Foundation

/// C11H-319: a `--sound` value that names a file is made absolute against the
/// caller's directory, since the app imports it from its own. A value with a
/// slash or a leading `~` or `.` is a path; a bare name with an extension that
/// exists in the caller's directory (`bell.wav`) is a path too. Sound names
/// (`Hero`, `none`, `flag`, `file:<id>`) pass through. Compiled into the CLI
/// and the app.
enum NotificationSoundArgument {
    static func resolve(
        _ value: String,
        currentDirectory: String,
        home: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("file:") else { return trimmed }
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        let pathLike = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")
            || trimmed.contains("/")
        if !pathLike {
            guard trimmed.contains("."), fileExists(base.appendingPathComponent(trimmed).path) else {
                return trimmed
            }
        }
        let expanded: String
        if trimmed == "~" {
            expanded = home
        } else if trimmed.hasPrefix("~/") {
            expanded = home + trimmed.dropFirst()
        } else {
            expanded = (trimmed as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
    }
}

/// C11H-319: which ask a needs-you is for: the agent's session and, when it
/// has one, the request (Claude's `tool_use_id`). Built by the CLI's hooks
/// and read by the app, as the `ask=` token of `notify_needs_you`.
struct NeedsYouAsk: Equatable, Sendable {
    let session: String
    let request: String?

    static let tokenPrefix = "ask="

    init?(session: String?, request: String?) {
        guard let session = Self.clean(session) else { return nil }
        self.session = session
        self.request = Self.clean(request)
    }

    /// Whether this needs-you repeats the panel's pending ask:
    /// - with a request, only that same request repeats it;
    /// - without one (Claude's own Notification names none), it repeats a
    ///   pending ask that has a request (the accepted question or plan ask it
    ///   follows), never another request-less one: two permission prompts
    ///   are two asks.
    func repeats(_ pending: NeedsYouAsk) -> Bool {
        guard session == pending.session, let pendingRequest = pending.request else { return false }
        return request == nil || request == pendingRequest
    }

    /// `ask=<session>/<request>`, or `ask=<session>/-` without a request.
    var token: String { "\(Self.tokenPrefix)\(session)/\(request ?? "-")" }

    /// Reads a token; nil for `ask=-` or anything malformed.
    init?(token: String) {
        guard token.hasPrefix(Self.tokenPrefix) else { return nil }
        let parts = token.dropFirst(Self.tokenPrefix.count).split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return nil }
        self.init(session: first, request: parts.count > 1 ? parts[1] : nil)
    }

    /// Opaque ids only: letters, digits, `.`, `_`, `:`, `-`; at most 128.
    private static func clean(_ value: String?) -> String? {
        guard let value, value != "-", !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._:-".unicodeScalars.contains($0) })
        else { return nil }
        return value
    }
}
