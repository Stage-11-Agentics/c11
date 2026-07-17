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

    private static let knownValueFlags: Set<String> = ["--surface", "--panel", "--workspace"]

    private static let knownFlagsHelp =
        "--surface <id|ref|index>, --panel <id|ref|index>, --workspace <id|ref|index>"

    /// Parse `close-surface` arguments into an explicit plan, or refuse.
    ///
    /// Accepts `--flag value` and `--flag=value`, honors a well-formed
    /// positional surface handle (`c11 close-surface surface:101`), and refuses
    /// anything else rather than silently discarding it.
    public static func parseCloseSurface(_ args: [String]) -> ParseResult {
        var workspace: String?
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

            if name == "--workspace" {
                workspace = value
            } else {
                namedSurfaces.append(value ?? "")
            }
            index += 1
        }

        let distinct = Set(namedSurfaces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if distinct.count > 1 {
            let listed = distinct.sorted().joined(separator: ", ")
            return .reject("close-surface: more than one surface named (\(listed)). Name exactly one target.")
        }

        return .plan(CloseSurfacePlan(workspace: workspace, surface: namedSurfaces.first))
    }

    /// True when a token is plainly one of c11's `<kind>:<ordinal>` handles or a
    /// UUID, i.e. the caller meant it as a target, not as free text. Bare
    /// integers are deliberately excluded: `3` is as likely to be a title as an
    /// index.
    public static func looksLikeHandle(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil { return true }
        return handleKindAndOrdinal(trimmed) != nil
    }

    private enum PositionalClass {
        case surface(String)
        case refuse(String)
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
