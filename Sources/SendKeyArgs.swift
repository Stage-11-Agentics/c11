import Foundation

/// A send-key call dispatches one key, never a silently truncated sequence.
enum SendKeyArgs {
    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case missingKey
        case extraArgument(String)

        var description: String {
            switch self {
            case .missingKey:
                return "requires a key"
            case .extraArgument(let argument):
                return String(
                    format: String(
                        localized: "cli.send_key.extra",
                        defaultValue: "takes one key; extra argument '%@'. Send the next key in a second call."
                    ),
                    argument
                )
            }
        }

        var errorDescription: String? { description }
    }

    static func single(_ args: [String]) throws -> String {
        guard let key = args.first else { throw Failure.missingKey }
        guard args.count == 1 else { throw Failure.extraArgument(args[1]) }
        return key
    }
}

/// A release belongs only to the surface that received its press.
enum SendKeyRelease {
    static func target<ID: Equatable>(pressed: ID, current: ID?) -> ID? {
        guard let current, current == pressed else { return nil }
        return pressed
    }
}
