import Foundation

enum HCManagedVerb: String, Codable, Sendable {
    case status, restart, list, get, run, machineList = "machine_list"

    var isReadOnly: Bool {
        switch self {
        case .status, .list, .get, .machineList: return true
        case .run, .restart: return false
        }
    }
}


struct HCManagedCommand: Codable, Sendable {
    let session: String
    let socket: String
    let verb: HCManagedVerb
    var terminal: String?
    var argv: [String] = []
    var cwd: String?
    var environment: [String: String] = [:]
    var labels: [String: String] = [:]
}

enum HCManagedCommandError: String, Error, Sendable {
    case hcSessionRequired = "hc_session_required"
    case hcManagedRuntime = "hc_managed_runtime"
    case hcCommandUnsupported = "hc_command_unsupported"
    case hcInvalidArguments = "hc_invalid_arguments"
}

/// Pure CLI parsing shared with tests. Only these explicit verbs reach hc;
/// unsupported CLI flags cannot silently change a core's lifetime or routing.
enum HCManagedCommandParser {
    static func parse(_ arguments: [String], environment: [String: String], cwd: String) throws -> HCManagedCommand {
        guard let session = environment["HC_SESSION"], !session.isEmpty,
              let socket = environment["HC_SOCKET"], !socket.isEmpty else { throw HCManagedCommandError.hcSessionRequired }
        var args = arguments
        guard let verb = args.first else { throw HCManagedCommandError.hcInvalidArguments }
        args.removeFirst()
        var request: HCManagedCommand
        switch verb {
        case "server":
            guard let action = args.first else { throw HCManagedCommandError.hcInvalidArguments }
            args.removeFirst()
            if action == "start" || action == "stop" { throw HCManagedCommandError.hcManagedRuntime }
            guard action == "status" || action == "restart" else { throw HCManagedCommandError.hcCommandUnsupported }
            request = HCManagedCommand(session: session, socket: socket, verb: action == "status" ? .status : .restart)
        case "update": throw HCManagedCommandError.hcManagedRuntime
        case "machine":
            // Read-only: the core's machine inventory with each line's state. Adding
            // or removing a machine changes the topology this app composes, so link
            // setup stays with `scripts/c11-atlas-link.sh`, not this adapter.
            guard let action = args.first else { throw HCManagedCommandError.hcInvalidArguments }
            args.removeFirst()
            guard action == "ls" || action == "list" else { throw HCManagedCommandError.hcCommandUnsupported }
            request = HCManagedCommand(session: session, socket: socket, verb: .machineList)
        case "ls": request = HCManagedCommand(session: session, socket: socket, verb: .list)
        case "get":
            guard let terminal = args.first, !terminal.hasPrefix("-") else { throw HCManagedCommandError.hcInvalidArguments }
            args.removeFirst()
            request = HCManagedCommand(session: session, socket: socket, verb: .get, terminal: terminal)
        case "run":
            request = HCManagedCommand(session: session, socket: socket, verb: .run, cwd: cwd)
            // Selected shell/display values only, never a bulk caller env copy.
            let inherited = Set(["PATH", "TERM", "TERMINFO", "TERMINFO_DIRS", "COLORTERM", "GHOSTTY_RESOURCES_DIR",
                                 "C11_SOCKET_PATH", "C11_HC_SESSION", "C11_HC_SOCKET"])
            request.environment = environment.filter { inherited.contains($0.key) || $0.key.hasPrefix("XDG_") }
            while !args.isEmpty {
                let arg = args.removeFirst()
                if arg == "--" { request.argv = args; args = []; break }
                if !arg.hasPrefix("-") { request.argv = [arg] + args; args = []; break }
                if ["--bg", "--no-parent", "--no-notify", "--json"].contains(arg) { continue }
                guard ["--cwd", "--env", "--label"].contains(arg), !args.isEmpty else { throw HCManagedCommandError.hcCommandUnsupported }
                let value = args.removeFirst()
                if arg == "--cwd" { request.cwd = value; continue }
                guard let equals = value.firstIndex(of: "="), equals != value.startIndex else { throw HCManagedCommandError.hcInvalidArguments }
                let key = String(value[..<equals]), body = String(value[value.index(after: equals)...])
                if arg == "--env" {
                    guard !key.hasPrefix("HC_") else { throw HCManagedCommandError.hcManagedRuntime }
                    request.environment[key] = body
                } else { request.labels[key] = body }
            }
            // No argv selects the caller's shell explicitly, not shared hc config.
            if request.argv.isEmpty { request.argv = [environment["SHELL"] ?? "/bin/zsh"] }
        default: throw HCManagedCommandError.hcCommandUnsupported
        }
        guard args.allSatisfy({ $0 == "--json" }) else { throw HCManagedCommandError.hcCommandUnsupported }
        return request
    }
}
