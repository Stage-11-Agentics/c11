import Foundation

/// What an agent hears when it types a verb this build does not have.
///
/// A newer c11 (or a c11 skill copied into `~/.claude/skills`) can name
/// commands c11 never shipped. The answer is the same for every unknown verb,
/// so it stays true as c11 grows: say it is not here, and point at the one
/// place that lists what is (`c11 guide`, offline, from this build's bundle).
enum CLIUnknownCommand {
    static func hint(command: String, version: String?, tool: String = "c11") -> String {
        "'\(command)' is not in c11 \(version ?? "(version unknown)"); run '\(tool) guide' for this build's commands."
    }
}

/// The name hints give this CLI. It is always `c11`: the retired line's alias
/// (`Legacy.invokedAsNames`, a script beside the CLI) still runs this build, and its
/// hints still say `c11`, so the old name never reaches help or an agent.
enum CLIInvokedName {
    static func name(from raw: String?) -> String { "c11" }

    /// Read once, at first use; `consumeEnvironment()` then clears it for children.
    static let current: String = name(from: ProcessInfo.processInfo.environment["C11_INVOKED_AS"])

    /// `Resources/bin/c11-core` (C11H-37): the standalone core utility, which
    /// never opens c11's app socket.
    static let isCoreUtility: Bool = isCoreUtilityName(ProcessInfo.processInfo.environment["C11_INVOKED_AS"])

    /// `c11-core`, or the retired line's core alias (`Legacy.invokedAsNames`).
    static func isCoreUtilityName(_ raw: String?) -> Bool {
        raw == "c11-core" || (raw.map { C11Identity.Legacy.invokedAsNames.contains($0) && $0.hasSuffix("-core") } ?? false)
    }

    static func consumeEnvironment() {
        _ = current
        _ = isCoreUtility
        unsetenv("C11_INVOKED_AS")
    }
}

/// The line at the top of `c11 guide`. An installed c11 skill can be newer than
/// this build; this page is the one that matches the binary in the agent's hand.
enum CLIGuideAuthority {
    static func line(version: String?) -> String {
        "This is c11 \(version ?? "(version unknown)"). If another c11 skill or doc names a command this guide lacks, that command does not exist here."
    }
}

/// The one launch instruction: the per-launch note (`Resources/bin/c11-agent-note.txt`).
/// The Claude wrapper passes it by `--append-system-prompt` and exports
/// `C11_AGENT_NOTE_SENT=1`; the SessionStart hook then adds nothing. When the wrapper
/// could not pass it (the operator's own flag won), the hook sends the same note, so a
/// session reads it once. `C11_AGENT_NOTE_DISABLED=1` turns both off.
enum C11LaunchNote {
    /// Whether the hook should send the note at all; checked before any file is read.
    static func hookShouldSend(environment: [String: String]) -> Bool {
        environment["C11_AGENT_NOTE_SENT"] != "1" && environment["C11_AGENT_NOTE_DISABLED"] != "1"
    }

    static func sessionStartContext(environment: [String: String], noteBody: String?, version: String?) -> String? {
        guard hookShouldSend(environment: environment) else { return nil }
        let body = noteBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else { return nil }
        let shown = version.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 } ?? "(version unknown)"
        return "c11 \(shown). \(body)"
    }
}

/// C11H-261: Claude's `Notification` hook fires `idle_prompt` ("Claude is
/// waiting for your input") about a minute after a turn ends with no reply.
/// It is that turn's end seen again, not a new ask, so the hook sends it as a
/// turn end for the waiting check. Permission and every other type stay plain.
enum ClaudeIdlePromptNotification {
    static let notificationType = "idle_prompt"
    static let idleMessage = "claude is waiting for your input"

    /// True for the hook's raw JSON input when `notification_type` is
    /// `idle_prompt`, or, from a Claude that omits the type, when the message
    /// is exactly the idle text.
    static func matches(rawInput: String) -> Bool {
        guard let data = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return false
        }
        if let type = object["notification_type"] as? String {
            return type == notificationType
        }
        let message = (object["message"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return message == idleMessage
    }
}
