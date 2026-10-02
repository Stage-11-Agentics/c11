import Foundation

/// Classifies create-time shell input without executing or unescaping it.
/// The create caller passes queued bytes through Ghostty's initial_input rail,
/// independently of the initial_command that replaces the shell.
enum CreateInitialInput {
    enum Decision: Equatable, Sendable {
        case absent
        case rejectLayout
        case rejectNonTerminal
        case queue(String)

        var queuedInput: String? {
            if case let .queue(input) = self { return input }
            return nil
        }

        func errorMessage(panelType: String? = nil) -> String? {
            switch self {
            case .rejectLayout:
                return String(localized: "cli.create.command.withLayout", defaultValue: "`--command` cannot be combined with `--layout`.")
            case .rejectNonTerminal:
                return String(
                    format: String(localized: "cli.create.command.nonTerminal", defaultValue: "`--command` is only for a terminal (%@)."),
                    CreateInitialInput.normalizedPanelType(panelType) ?? "terminal"
                )
            case .absent, .queue:
                return nil
            }
        }
    }

    static func decide(raw: String?, panelType: String?, hasLayout: Bool = false) -> Decision {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .absent
        }
        if hasLayout { return .rejectLayout }
        switch normalizedPanelType(panelType) {
        case "browser", "markdown":
            return .rejectNonTerminal
        default:
            // Preserve literal backslash escapes, Unicode and whitespace. Only
            // the submit byte is added, and an existing trailing CR is retained.
            return .queue(raw.hasSuffix("\r") ? raw : raw + "\r")
        }
    }

    static func normalizedPanelType(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }
}
