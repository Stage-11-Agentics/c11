import Darwin
import Foundation

/// Runs read-only git in a repository whose `.git` c11 did not create.
///
/// A checkout's `.git/config` travels with it: an extracted archive or a copied
/// folder can carry one written by anyone, and git reads it on every command.
/// Some of its keys start programs even for read-only listing. `core.fsmonitor`
/// runs its hook whenever the index is read. A promisor remote
/// (`extensions.partialClone`) turns a missing object, such as the blob of a
/// skip-worktree `.gitignore` or a sparse-index tree, into a lazy fetch over a
/// transport like `ext::<command>`. Every git process c11 starts in a
/// document's repository goes through `run(in:arguments:input:timeout:)`.
///
/// The `-c` overrides sit in the command-line scope, which outranks the
/// repository config and anything it includes. The environment variables
/// outrank config entirely. Together they switch off program launch,
/// transports and caches only; for an ordinary repository `ls-files` and
/// `check-ignore` print exactly what they print without them. `safe.directory`
/// is left alone, so git still refuses a repository owned by another account
/// and the caller falls back to its filesystem walk.
///
/// Not covered here: keys that only take effect in commands that diff, convert
/// content, sign, or write the index (`diff.external`, `filter.*`, `gpg.program`,
/// hooks). Before routing such a command through this helper, check those keys
/// against it.
enum UntrustedRepositoryGit {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    /// A hostile repository can also make git block, for example on a FIFO
    /// named `.gitignore`. Past this, git is terminated and the call fails.
    static let defaultTimeout: TimeInterval = 10

    /// Global options placed before every subcommand.
    static let globalArguments: [String] = [
        "--no-pager",
        // Runs its hook, or starts the builtin daemon, on every index read.
        "-c", "core.fsmonitor=false",
        // No hook can run, even from a command that writes the index.
        "-c", "core.hooksPath=/dev/null",
        // Ignore an untracked-cache extension carried in the index.
        "-c", "core.untrackedCache=false",
        // Repository config can still allow one protocol by name
        // (protocol.<name>.allow outranks this), so GIT_ALLOW_PROTOCOL below
        // is the binding control; this is a second layer.
        "-c", "protocol.allow=never",
        // Never adopt a bare-repository-shaped directory found by discovery.
        "-c", "safe.bareRepository=explicit",
    ]

    struct Result {
        let status: Int32
        let output: Data
    }

    static func arguments(in directory: URL, _ command: [String]) -> [String] {
        globalArguments + ["-C", directory.path] + command
    }

    static func environment(
        in directory: URL,
        inheriting inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // An inherited GIT_DIR, GIT_WORK_TREE or GIT_INDEX_FILE would point git
        // at a different repository. Keep only the operator's global config
        // location, which supplies core.excludesFile.
        var environment = inherited.filter { key, _ in
            !key.hasPrefix("GIT_") || key == "GIT_CONFIG_GLOBAL"
        }
        // Set, even empty, this list replaces every protocol.* setting: no
        // transport (ext::, ssh with core.sshCommand, file with uploadpack,
        // http) is allowed, so a lazy fetch or credential prompt cannot start
        // anything. Honored by every git since 2.6.
        environment["GIT_ALLOW_PROTOCOL"] = ""
        // Never fetch a missing object from a promisor remote. Honored from
        // 2.39.4, 2.40.2, 2.41.1, 2.42.2, 2.43.4, 2.44.1 and 2.45.1; older git
        // starts a `git fetch` child that GIT_ALLOW_PROTOCOL then stops.
        environment["GIT_NO_LAZY_FETCH"] = "1"
        // The work tree is the directory c11 asked about, whatever
        // core.worktree says, so the listing cannot walk elsewhere.
        environment["GIT_WORK_TREE"] = directory.path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Empty, so git consults neither core.askPass nor SSH_ASKPASS.
        environment["GIT_ASKPASS"] = ""
        environment["GIT_PAGER"] = "cat"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Discovery checks `directory` and never climbs above it.
        let parent = directory.deletingLastPathComponent().path
        if parent != directory.path {
            environment["GIT_CEILING_DIRECTORIES"] = parent
        }
        return environment
    }

    /// A configured, unstarted git process. Stdin and stderr default to the
    /// null device.
    static func process(in directory: URL, arguments command: [String]) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments(in: directory, command)
        process.environment = environment(in: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Runs git to completion and returns its exit status and stdout, or nil
    /// when it could not start or ran past `timeout`. Blocks the calling
    /// thread; call it from a background queue.
    static func run(
        in directory: URL,
        arguments command: [String],
        input: Data? = nil,
        timeout: TimeInterval = defaultTimeout
    ) -> Result? {
        let process = process(in: directory, arguments: command)
        let output = Pipe()
        process.standardOutput = output
        let inputPipe = input == nil ? nil : Pipe()
        if let inputPipe { process.standardInput = inputPipe }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        if let inputPipe, let input {
            DispatchQueue.global(qos: .utility).async {
                // git can exit without reading stdin (outside a repository, or
                // killed at the timeout). With SIGPIPE off for this fd the
                // throwing write reports EPIPE; write(_:) would raise an
                // exception that ends the app.
                let writer = inputPipe.fileHandleForWriting
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }

        // Drain stdout concurrently so a large listing cannot fill the pipe
        // and stall git into a false timeout.
        let collected = OutputBox()
        let readFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected.data = output.fileHandleForReading.readDataToEndOfFile()
            readFinished.signal()
        }

        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            // The reader and writer finish once git's pipe ends close; nothing
            // here waits on them.
            return nil
        }
        // git has exited, so its stdout is closed unless a child it started
        // still holds it.
        guard readFinished.wait(timeout: .now() + 1) == .success else { return nil }
        return Result(status: process.terminationStatus, output: collected.data)
    }

    private final class OutputBox: @unchecked Sendable {
        // Written once by the reader before readFinished signals; read after.
        var data = Data()
    }
}
