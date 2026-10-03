import Foundation

/// CLI-only parsing; callers supply stdin bytes after admission and targeting.
struct SendTextParse {
    enum Input: Equatable {
        case argument(String)
        case stdin
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    var workspace: String? = nil
    var tab: String? = nil
    var raw: Bool
    var submit = true
    var json = false
    var allowUnguarded = false
    var input: Input

    static func parse(_ arguments: [String], paste: Bool = false) throws -> Self {
        var parsed = Self(raw: paste, input: .stdin)
        var text: [String] = []
        var index = 0
        var literal = false
        while index < arguments.count {
            let argument = arguments[index]
            if !literal && argument == "--" {
                literal = true
            } else if !literal && ["--workspace", "--tab", "--surface", "--panel"].contains(argument) {
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--"),
                      !arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure(description: String(format: String(
                        localized: "cli.send.target_required",
                        defaultValue: "'%@' requires a non-empty id or ref."
                    ), argument))
                }
                index += 1
                if argument == "--workspace" {
                    parsed.workspace = arguments[index]
                } else {
                    parsed.tab = arguments[index]
                }
            } else if !literal && argument == "--raw" {
                parsed.raw = true
            } else if !literal && argument == "--no-submit" {
                parsed.submit = false
            } else if !literal && argument == "--json" {
                parsed.json = true
            } else if !literal && argument == "--allow-unguarded" {
                parsed.allowUnguarded = true
            } else if !literal && argument.hasPrefix("--") {
                throw Failure(description: String(format: String(
                    localized: "cli.send.unknown_flag", defaultValue: "Unknown flag '%@'."
                ), argument))
            } else {
                text.append(argument)
            }
            index += 1
        }
        if text.contains("-") {
            guard text == ["-"] else {
                throw Failure(description: String(
                    localized: "cli.send.stdin_conflict", defaultValue: "'-' reads stdin and takes no other text."
                ))
            }
            parsed.input = .stdin
        } else if text.isEmpty && paste {
            parsed.input = .stdin
        } else {
            let body = text.joined(separator: " ")
            guard !body.isEmpty else { throw missingText() }
            parsed.input = .argument(body)
        }
        return parsed
    }

    func text(stdin: Data = Data()) throws -> String {
        let text: String
        switch input {
        case .argument(let argument): text = argument
        case .stdin:
            guard let decoded = String(data: stdin, encoding: .utf8) else {
                throw Failure(description: String(
                    localized: "cli.send.stdin_utf8", defaultValue: "Send stdin must be UTF-8 text."
                ))
            }
            text = decoded
        }
        guard !text.isEmpty else { throw Self.missingText() }
        return raw ? text : Self.unescape(text)
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    private static func missingText() -> Failure {
        Failure(description: String(localized: "cli.send.text_required", defaultValue: "send requires text"))
    }
}

/// One newline/Return decision shared by attached and queued socket sends.
struct SendTextDelivery {
    let body: String
    let wantsReturn: Bool

    init(_ text: String, submit: Bool, preserveNewlines: Bool = false) {
        var body = text
        if !preserveNewlines {
            while let last = body.unicodeScalars.last, last.value == 0x0A || last.value == 0x0D {
                body.unicodeScalars.removeLast()
            }
        }
        self.body = body
        self.wantsReturn = submit || body != text
    }

    static func summary(queued: Bool, submitted: Bool) -> String {
        if queued {
            return String(localized: "cli.send.queued",
                          defaultValue: "queued, not delivered (tab not attached; the agent has not seen it)")
        }
        return submitted
            ? String(localized: "cli.send.delivered_submitted", defaultValue: "delivered, return scheduled")
            : String(localized: "cli.send.delivered", defaultValue: "delivered, not submitted")
    }
}
