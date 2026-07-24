import Foundation

/// Surface-targeting argument parser for destructive, surface-scoped CLI
/// commands.
///
/// Lives in `Sources/` (shared by the c11 app target and c11-cli target) so the
/// logic-test target can exercise it directly without linking the CLI
/// executable or dragging `CLIError` (CLI-local) into the app module. Callers
/// map `.reject` onto their own error type.
///
/// The rule this encodes: **the caller's own surface is a safe default only on
/// a genuinely bare command line.** The moment an argument names a target, the
/// environment must not be consulted. Resolving a named ref to some *other*
/// surface can never be what the caller meant, and when the command is
/// `close-surface` the difference is a destroyed session.
///
/// This is the client-side sibling of `SocketSurfaceRefValidator`, which
/// hardened *empty* refs into loud errors server-side. An *ignored* ref is as
/// dangerous as an empty one, and it cannot be caught server-side: by the time
/// the socket sees the request, the mis-targeted ref is already gone.
public enum CLISurfaceRefArguments {

    /// A resolved `close-surface` command line.
    public struct CloseSurfacePlan: Equatable {
        /// Value of `--workspace`, if the command line carried one.
        public let workspace: String?
        /// The surface the command line named, via `--surface`, `--panel`, or a
        /// positional handle. `nil` only when nothing named a surface.
        public let surface: String?

        public init(workspace: String?, surface: String?) {
            self.workspace = workspace
            self.surface = surface
        }

        /// True when the command line named a surface. Callers must not fall
        /// back to `$CMUX_SURFACE_ID` when this is true.
        public var namesSurface: Bool { surface != nil }
    }

    public enum ParseResult: Equatable {
        case plan(CloseSurfacePlan)
        /// The command line named something that cannot be honored. The message
        /// is operator-facing and names the fix.
        case reject(String)
    }

    /// Target flags consumed from a `tab-action` command line. `remaining`
    /// preserves action/title/url flags and positional rename text for the
    /// command runner to parse normally.
    public struct TabActionTargetPlan: Equatable {
        public let workspace: String?
        public let target: String?
        public let remaining: [String]

        public init(workspace: String?, target: String?, remaining: [String]) {
            self.workspace = workspace
            self.target = target
            self.remaining = remaining
        }
    }

    public enum TabActionTargetParseResult: Equatable {
        case plan(TabActionTargetPlan)
        case reject(String)
    }

    private static let knownValueFlags: Set<String> = ["--surface", "--panel", "--workspace"]

    private static let knownFlagsHelp =
        "--surface <id|ref|index>, --panel <id|ref|index>, --workspace <id|ref|index>"

    /// Parse `close-surface` arguments into an explicit plan, or refuse.
    ///
    /// Accepts `--flag value` and `--flag=value`, honors a well-formed
    /// positional surface handle (`c11 close-surface surface:101`), and refuses
    /// anything else rather than silently discarding it.
    public static func parseCloseSurface(_ args: [String]) -> ParseResult {
        var namedWorkspaces: [String] = []
        var namedSurfaces: [String] = []
        var index = 0

        while index < args.count {
            let raw = args[index]

            guard raw.hasPrefix("--") else {
                switch classifyPositional(raw) {
                case .surface(let ref):
                    namedSurfaces.append(ref)
                case .refuse(let message):
                    return .reject(message)
                }
                index += 1
                continue
            }

            let name: String
            var value: String?
            if let equals = raw.firstIndex(of: "=") {
                name = String(raw[..<equals])
                value = String(raw[raw.index(after: equals)...])
            } else {
                name = raw
            }

            guard knownValueFlags.contains(name) else {
                return .reject("close-surface: unknown flag '\(name)'. Known flags: \(knownFlagsHelp)")
            }

            if value == nil {
                guard index + 1 < args.count else {
                    return .reject("close-surface: flag '\(name)' requires a value")
                }
                let next = args[index + 1]
                if next.hasPrefix("--") {
                    return .reject("close-surface: flag '\(name)' requires a value, got another flag '\(next)'")
                }
                value = next
                index += 1
            }

            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .reject("close-surface: flag '\(name)' requires a non-empty value")
            }

            if name == "--workspace" {
                namedWorkspaces.append(value)
            } else {
                namedSurfaces.append(value)
            }
            index += 1
        }

        let distinctWorkspaces = distinctTrimmedValues(namedWorkspaces)
        if distinctWorkspaces.count > 1 {
            let listed = distinctWorkspaces.sorted().joined(separator: ", ")
            return .reject("close-surface: more than one workspace named (\(listed)). Name exactly one workspace.")
        }

        let distinct = Set(namedSurfaces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if distinct.count > 1 {
            let listed = distinct.sorted().joined(separator: ", ")
            return .reject("close-surface: more than one surface named (\(listed)). Name exactly one target.")
        }

        return .plan(CloseSurfacePlan(
            workspace: distinctWorkspaces.first,
            surface: distinct.first
        ))
    }

    /// Consume `--workspace`, `--tab`, and `--surface` from a `tab-action`
    /// command line without the generic option parser's last-value-wins
    /// behavior. Distinct repeated values — whether on one flag or split
    /// across the `--tab`/`--surface` aliases — are ambiguous destructive
    /// targets and reject before any socket resolution or dispatch. Repeating
    /// the same trimmed value is harmless and remains accepted.
    public static func parseTabActionTargets(_ args: [String]) -> TabActionTargetParseResult {
        let targetFlags: Set<String> = ["--workspace", "--tab", "--surface"]
        var namedWorkspaces: [String] = []
        var namedTargets: [String] = []
        var remaining: [String] = []
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let raw = args[index]
            if raw == "--" {
                pastTerminator = true
                remaining.append(raw)
                index += 1
                continue
            }
            guard !pastTerminator, targetFlags.contains(raw) else {
                remaining.append(raw)
                index += 1
                continue
            }

            guard index + 1 < args.count else {
                return .reject("tab-action: flag '\(raw)' requires a value")
            }
            let value = args[index + 1]
            guard !value.hasPrefix("--") else {
                return .reject("tab-action: flag '\(raw)' requires a value, got another flag '\(value)'")
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .reject("tab-action: flag '\(raw)' requires a non-empty value")
            }

            if raw == "--workspace" {
                namedWorkspaces.append(trimmed)
            } else {
                namedTargets.append(trimmed)
            }
            index += 2
        }

        let distinctWorkspaces = distinctTrimmedValues(namedWorkspaces)
        if distinctWorkspaces.count > 1 {
            let listed = distinctWorkspaces.sorted().joined(separator: ", ")
            return .reject("tab-action: more than one workspace named (\(listed)). Name exactly one workspace.")
        }

        let distinctTargets = distinctTrimmedValues(namedTargets)
        if distinctTargets.count > 1 {
            let listed = distinctTargets.sorted().joined(separator: ", ")
            return .reject("tab-action: more than one tab or surface named (\(listed)). Name exactly one target.")
        }

        return .plan(TabActionTargetPlan(
            workspace: distinctWorkspaces.first,
            target: distinctTargets.first,
            remaining: remaining
        ))
    }

    /// Refuse any positional token left after `tab-action` has consumed its
    /// action, except for `rename`, whose trailing positionals intentionally
    /// form the title.
    ///
    /// Other actions do not own a positional slot. Accepting even an
    /// innocent-looking value such as a bare index or a malformed handle would
    /// discard the caller's apparent target and let tab resolution fall back to
    /// caller focus. Keep this generic so every present and future non-rename
    /// action gets the same destructive-target safety rule.
    public static func tabActionPositionalRejection(action: String, positional: [String]) -> String? {
        let normalizedAction = action.lowercased().replacingOccurrences(of: "-", with: "_")
        guard normalizedAction != "rename", let stray = positional.first else {
            return nil
        }
        return "tab-action: action '\(normalizedAction)' does not take positional arguments; unexpected '\(stray)'. Pass the target with '--tab <id|ref|index>'."
    }

    private enum PositionalClass {
        case surface(String)
        case refuse(String)
    }

    private static func distinctTrimmedValues(_ values: [String]) -> Set<String> {
        Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private static func classifyPositional(_ raw: String) -> PositionalClass {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if UUID(uuidString: trimmed) != nil {
            return .surface(trimmed)
        }

        if let (kind, ordinal) = handleKindAndOrdinal(trimmed) {
            switch kind {
            case "surface":
                return .surface(trimmed)
            case "tab":
                return .refuse("close-surface: '\(trimmed)' is a tab handle, not a surface. Did you mean 'surface:\(ordinal)'?")
            case "pane":
                return .refuse("close-surface: '\(trimmed)' is a pane handle, not a surface. Did you mean 'c11 kill \(trimmed)'?")
            case "workspace":
                return .refuse("close-surface: '\(trimmed)' is a workspace handle. Did you mean 'c11 close-workspace --workspace \(trimmed)'?")
            case "window":
                return .refuse("close-surface: '\(trimmed)' is a window handle. Did you mean 'c11 close-window --window \(ordinal)'?")
            default:
                break
            }
        }

        if Int(trimmed) != nil {
            return .refuse("close-surface: bare index '\(trimmed)' is ambiguous. Pass '--surface \(trimmed)' to target surface index \(trimmed).")
        }

        return .refuse("close-surface: unexpected argument '\(trimmed)'. Did you mean '--surface \(trimmed)'?")
    }

    /// Split a `<kind>:<ordinal>` handle. Returns nil for anything else.
    private static func handleKindAndOrdinal(_ value: String) -> (kind: String, ordinal: String)? {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let ordinal = String(pieces[1])
        guard Int(ordinal) != nil else { return nil }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "pane", "surface", "tab"].contains(kind) else { return nil }
        return (kind, ordinal)
    }
}
