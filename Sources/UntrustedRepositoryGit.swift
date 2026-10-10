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
/// transport like `ext::<command>`. A content filter (`filter.<driver>.clean`
/// or `.process`, selected by `.gitattributes`) runs whenever `git status`
/// hashes a file whose stat data no longer matches the index, which is every
/// tracked file in a freshly extracted archive. Every git process c11 starts in
/// a document's or workspace's repository goes through
/// `run(in:arguments:input:timeout:discovery:readsFileContent:)`.
///
/// The `-c` overrides sit in the command-line scope, which outranks the
/// repository config and anything it includes. The environment variables
/// outrank config entirely. Together they switch off program launch,
/// transports and caches only; for an ordinary repository `ls-files` and
/// `check-ignore` print exactly what they print without them. `safe.directory`
/// is left alone, so git still refuses a repository owned by another account
/// and the caller falls back to its filesystem walk.
///
/// A command that hashes working-tree files (`status`, `diff-files`) passes
/// `readsFileContent: true`, which also switches off every filter driver defined
/// outside the operator's global config, in the repository and in each populated
/// submodule below it. git hands `-c` settings to the submodule `status`
/// children it starts, so one set of overrides covers them all.
///
/// Not covered here: keys that only take effect in commands that diff, sign, or
/// write the index (`diff.external`, `diff.<driver>.textconv`, `gpg.program`,
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

    /// How git finds the repository for `directory`.
    enum Discovery {
        /// `directory` is the work tree's top level. git never looks above it,
        /// and the work tree is pinned there whatever `core.worktree` says.
        case topLevel
        /// `directory` is anywhere inside a work tree, such as a terminal's
        /// working directory. git discovers the repository upward from it, as
        /// it does in a shell, and honors `core.worktree` (submodules set it).
        case enclosingRepository
    }

    /// Repositories visited when collecting submodule filter definitions.
    /// Past this the content-reading command is refused rather than run with
    /// filters left unchecked.
    static let maximumFilterScanRepositories = 64

    static func arguments(in directory: URL, _ command: [String], extraConfig: [String] = []) -> [String] {
        globalArguments + extraConfig.flatMap { ["-c", $0] } + ["-C", directory.path] + command
    }

    static func environment(
        in directory: URL,
        discovery: Discovery = .topLevel,
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
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Empty, so git consults neither core.askPass nor SSH_ASKPASS.
        environment["GIT_ASKPASS"] = ""
        environment["GIT_PAGER"] = "cat"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        if discovery == .topLevel {
            // The work tree is the directory c11 asked about, whatever
            // core.worktree says, so a listing cannot walk elsewhere.
            environment["GIT_WORK_TREE"] = directory.path
            // Discovery checks `directory` and never climbs above it.
            let parent = directory.deletingLastPathComponent().path
            if parent != directory.path {
                environment["GIT_CEILING_DIRECTORIES"] = parent
            }
        }
        return environment
    }

    /// A configured, unstarted git process. Stdin and stderr default to the
    /// null device.
    static func process(
        in directory: URL,
        arguments command: [String],
        discovery: Discovery = .topLevel,
        extraConfig: [String] = []
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments(in: directory, command, extraConfig: extraConfig)
        process.environment = environment(in: directory, discovery: discovery)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Runs git to completion and returns its exit status and stdout, or nil
    /// when it could not start or ran past `timeout`. With `readsFileContent`,
    /// also nil when the repository's filter definitions cannot be collected
    /// and switched off; `timeout` then bounds the scan and the command
    /// together. Blocks the calling thread; call it from a background queue.
    static func run(
        in directory: URL,
        arguments command: [String],
        input: Data? = nil,
        timeout: TimeInterval = defaultTimeout,
        discovery: Discovery = .topLevel,
        readsFileContent: Bool = false
    ) -> Result? {
        let deadline = DispatchTime.now() + timeout
        var extraConfig: [String] = []
        if readsFileContent {
            guard let overrides = contentFilterOverrides(in: directory, discovery: discovery, deadline: deadline) else {
                return nil
            }
            extraConfig = overrides
        }
        return execute(in: directory, arguments: command, input: input, deadline: deadline,
                       discovery: discovery, extraConfig: extraConfig)
    }

    /// `key=value` settings that switch off every filter driver key defined
    /// outside the operator's global config, in the repository enclosing
    /// `directory` and in each populated submodule below it. A key the operator
    /// also sets globally gets the global value back, so a filter installed
    /// globally (Git LFS) still runs its own command; any other key becomes
    /// empty, which leaves its driver with no command and not required. Nil
    /// when git cannot list the definitions before `deadline`, when there are
    /// more repositories than `maximumFilterScanRepositories`, or when a driver
    /// name contains `=`, which `-c` cannot express.
    static func contentFilterOverrides(
        in directory: URL,
        discovery: Discovery,
        deadline: DispatchTime
    ) -> [String]? {
        var globalValues: [String: String] = [:]
        var untrustedKeys: Set<String> = []
        // Each visit lists config and the index exactly as the command about
        // to run sees them: from the same directory with the same discovery,
        // so a hostile core.worktree cannot point the scan at another
        // repository. Submodules are visited from their work tree path with
        // upward discovery, the way git runs its own submodule status child.
        var pending: [(directory: URL, discovery: Discovery)] = [(directory, discovery)]
        var visited: Set<String> = []
        while let visit = pending.popLast() {
            guard let top = execute(in: visit.directory, arguments: ["rev-parse", "--show-toplevel"],
                                    deadline: deadline, discovery: visit.discovery),
                  top.status == 0 else { return nil }
            // Strip only the newline git appends: a directory name may itself
            // end in one, and a wrong top would hide its submodules.
            var topPath = String(decoding: top.output, as: UTF8.self)
            guard topPath.hasSuffix("\n") else { return nil }
            topPath.removeLast()
            guard topPath.hasPrefix("/") else { return nil }
            guard visited.insert(topPath).inserted else { continue }
            guard visited.count <= maximumFilterScanRepositories else { return nil }

            // Every scope git reads for this repository, including includes,
            // conditional includes and config.worktree.
            guard let config = execute(in: visit.directory, arguments: [
                "config", "-z", "--show-scope", "--get-regexp", "^filter\\."
            ], deadline: deadline, discovery: visit.discovery) else { return nil }
            switch config.status {
            case 0:
                let fields = config.output.split(separator: 0, omittingEmptySubsequences: false)
                    .map { String(decoding: $0, as: UTF8.self) }
                var index = 0
                while index + 1 < fields.count {
                    let scope = fields[index]
                    let entry = fields[index + 1]
                    index += 2
                    let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let key = String(parts[0])
                    if scope == "global" {
                        globalValues[key] = parts.count > 1 ? String(parts[1]) : ""
                    } else {
                        untrustedKeys.insert(key)
                    }
                }
            case 1:
                break // No filter keys at all.
            default:
                return nil
            }

            // A populated gitlink gets its own `git status` child, under its
            // own config.
            guard let index = execute(in: visit.directory, arguments: [
                "ls-files", "--stage", "--full-name", "-z", "--", ":/"
            ], deadline: deadline, discovery: visit.discovery),
                  index.status == 0 else { return nil }
            let topURL = URL(fileURLWithPath: topPath, isDirectory: true)
            for record in index.output.split(separator: 0) {
                let line = String(decoding: record, as: UTF8.self)
                guard line.hasPrefix("160000 "), let tab = line.firstIndex(of: "\t") else { continue }
                let path = String(line[line.index(after: tab)...])
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { continue }
                let submodule = topURL.appendingPathComponent(path, isDirectory: true)
                if FileManager.default.fileExists(atPath: submodule.appendingPathComponent(".git").path) {
                    pending.append((submodule, .enclosingRepository))
                }
            }
        }

        var overrides: [String] = []
        for key in untrustedKeys.sorted() {
            guard !key.contains("=") else { return nil }
            overrides.append("\(key)=\(globalValues[key] ?? "")")
        }
        return overrides
    }

    private static func execute(
        in directory: URL,
        arguments command: [String],
        input: Data? = nil,
        deadline: DispatchTime,
        discovery: Discovery = .topLevel,
        extraConfig: [String] = []
    ) -> Result? {
        guard DispatchTime.now() < deadline else { return nil }
        let process = process(in: directory, arguments: command, discovery: discovery, extraConfig: extraConfig)
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
