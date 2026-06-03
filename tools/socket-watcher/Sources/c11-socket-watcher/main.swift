// C11-105 socket-unlink diagnostic CLI.
// See ../../../../docs/c11-socket-unlink-diagnostic.md for the runbook.

import Foundation
import SocketWatcherKit

let version = "0.1.0"

func printUsage() {
    let usage = """
    c11-socket-watcher \(version) — C11-105 socket-unlink diagnostic

    USAGE
        c11-socket-watcher watch <path>     Watch <path> for delete/rename/revoke
                                            events; emit JSON Lines on stdout.
        c11-socket-watcher reset <path>     Unlink <path> (manual self-test).
        c11-socket-watcher --help           Show this message.
        c11-socket-watcher --version        Print version.

    NOTES
        Pipe output through `tee` or `jq -c .` to persist or pretty-print.
        See docs/c11-socket-unlink-diagnostic.md for reproduction scenarios.
    """
    print(usage)
}

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--help") || args.contains("-h") || args.isEmpty {
    printUsage()
    exit(args.isEmpty ? 2 : 0)
}

if args.contains("--version") {
    print(version)
    exit(0)
}

switch args[0] {
case "watch":
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("error: watch requires a path\n".utf8))
        printUsage()
        exit(2)
    }
    let path = (args[1] as NSString).expandingTildeInPath
    let stdout = FileHandle.standardOutput
    let emitter = JSONLinesEmitter { line in
        stdout.write(Data(line.utf8))
    }
    let watcher = SocketWatcher(path: path, emitter: emitter)
    signal(SIGINT) { _ in
        // Signal handlers can't safely call Swift methods; the watcher
        // loop checks for a stop flag, but on SIGINT we just exit. Any
        // partially-flushed JSON line is acceptable for a diagnostic.
        exit(0)
    }
    signal(SIGTERM) { _ in exit(0) }
    do {
        try watcher.run()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

case "reset":
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("error: reset requires a path\n".utf8))
        exit(2)
    }
    let path = (args[1] as NSString).expandingTildeInPath
    if unlink(path) != 0 {
        let code = errno
        FileHandle.standardError.write(Data("error: unlink(\(path)) failed: errno=\(code)\n".utf8))
        exit(1)
    }
    print("unlinked \(path)")

default:
    FileHandle.standardError.write(Data("error: unknown command '\(args[0])'\n".utf8))
    printUsage()
    exit(2)
}
