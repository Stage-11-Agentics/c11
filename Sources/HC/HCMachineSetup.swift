import Foundation

/// C11H-126 part 2: Add Machine. Links another Mac to c11 over SSH in one
/// flow, the steps `docs/c11-install-guide.md` (remote machine section) did by hand:
/// reach it, install or verify c11's pinned hc there, install the relay so
/// agents there can talk back, render a via script, `hc machine add`, verify.
///
/// Foundation only: the app's Settings sheet and `c11 machine link` share it.
/// Every external command goes through `HCMachineSetupRunner`, so tests use a
/// fake. It writes nothing outside `~/.local/share/c11` here and there, and
/// adding a machine stays an operator action (the skill says so).
///
/// C11H-332: the hc there must hash to this build's pin before it is linked
/// (`secure`), the via checks that hash again at every dial, hc's folders
/// there are made private (0700), and every outcome is a line in c11's audit
/// log (`C11AuditLog`).
enum HCMachineSetupStep: String, CaseIterable, Sendable {
    case reach, install, secure, relay, link, verify

    var title: String {
        switch self {
        case .reach: return String(localized: "machineSetup.step.reach", defaultValue: "Reach the machine over SSH")
        case .install: return String(localized: "machineSetup.step.install", defaultValue: "Install c11's hc there")
        case .secure: return String(localized: "machineSetup.step.secure", defaultValue: "Check c11's hc and its folders")
        case .relay: return String(localized: "machineSetup.step.relay", defaultValue: "Install the relay for agents there")
        case .link: return String(localized: "machineSetup.step.link", defaultValue: "Link it to c11")
        case .verify: return String(localized: "machineSetup.step.verify", defaultValue: "Check the link")
        }
    }
}

enum HCMachineSetupState: String, Equatable, Sendable {
    case running, done, skipped, failed
}

struct HCMachineSetupProgress: Equatable, Sendable {
    let step: HCMachineSetupStep
    let state: HCMachineSetupState
    let detail: String?
}

/// Every way Add Machine stops, each with a sentence saying what to fix.
enum HCMachineSetupFailure: Error, Equatable, Sendable {
    case invalidHost(String)
    case invalidName(String)
    case nameTaken(String)
    case hostKeyUnknown(String)
    case authRefused(String)
    case unknownHost(String)
    case unreachable(String, String)
    case unsupported(host: String, system: String)
    case needsCommandLineTools(String)
    /// C11H-392: what a Linux machine needs for c11's link.
    case needsLinger(host: String, user: String)
    case needsNoFile(host: String, limit: Int)
    case needsPython(String)
    case needsSHA256(String)
    /// C11H-398: the relay step unpacks its kit with the far machine's tar.
    case needsTar(String)
    case needsUserManager(String)
    /// C11H-392: this build names no Linux files, or one could not be got or checked.
    case linuxFilesMissing(String)
    case linuxFileFailed(name: String, reason: String)
    case linuxFileMismatch(name: String, found: String, expected: String)
    case linuxFileNotInFolder(name: String, folder: String)
    case sshFailed(String, String)
    case installRefusedInUse(String)
    case hcHashMismatch(host: String, found: String, expected: String)
    case hcServingMismatch(host: String, pid: Int, found: String)
    case folderRefused(host: String, path: String, reason: String)
    case updateTargetChanged(name: String, linked: String, requested: String)
    case updateTargetUnknown(String)
    case updateNeedsNoTerminals(String, Int)
    case removeIncomplete(String, String)
    case updateLeftUnlinked(String, String)
    case installFailed(String, String)
    case relayFailed(String, String)
    case missingResource(String)
    case coreUnavailable(String)
    case addFailed(String, String)
    case removeFailed(String, String)
    case notConnected(String, String)

    var code: String {
        switch self {
        case .invalidHost: return "invalid_host"
        case .invalidName: return "invalid_name"
        case .nameTaken: return "name_taken"
        case .hostKeyUnknown: return "host_key_unknown"
        case .authRefused: return "auth_refused"
        case .unknownHost: return "unknown_host"
        case .unreachable: return "unreachable"
        case .unsupported: return "unsupported_machine"
        case .needsCommandLineTools: return "needs_command_line_tools"
        case .needsLinger: return "needs_linger"
        case .needsNoFile: return "needs_nofile"
        case .needsPython: return "needs_python"
        case .needsSHA256: return "needs_sha256"
        case .needsTar: return "needs_tar"
        case .needsUserManager: return "needs_user_manager"
        case .linuxFilesMissing: return "remote_artifacts_missing"
        case .linuxFileFailed: return "remote_artifact_failed"
        case .linuxFileMismatch: return "remote_artifact_hash_mismatch"
        case .linuxFileNotInFolder: return "remote_artifact_not_in_folder"
        case .sshFailed: return "ssh_failed"
        case .installRefusedInUse: return "hc_in_use"
        case .hcHashMismatch: return "hc_hash_mismatch"
        case .hcServingMismatch: return "hc_serving_mismatch"
        case .folderRefused: return "dir_refused"
        case .updateTargetChanged: return "update_target_changed"
        case .updateTargetUnknown: return "update_target_unknown"
        case .updateNeedsNoTerminals: return "update_needs_no_terminals"
        case .removeIncomplete: return "remove_incomplete"
        case .updateLeftUnlinked: return "update_left_unlinked"
        case .installFailed: return "install_failed"
        case .relayFailed: return "relay_failed"
        case .missingResource: return "missing_resource"
        case .coreUnavailable: return "core_unavailable"
        case .addFailed: return "add_failed"
        case .removeFailed: return "remove_failed"
        case .notConnected: return "not_connected"
        }
    }

    var message: String {
        switch self {
        case .invalidHost(let host):
            return String(format: String(localized: "machineSetup.error.invalidHost",
                defaultValue: "“%@” isn't an SSH host c11 can use. Give a name from your SSH config, a host name, or user@host."), host)
        case .invalidName(let name):
            return String(format: String(localized: "machineSetup.error.invalidName",
                defaultValue: "“%@” can't be a machine name. Use lower-case letters, digits, dots, dashes or underscores; “local” and “here” mean this Mac."), name)
        case .nameTaken(let name):
            return String(format: String(localized: "machineSetup.error.nameTaken",
                defaultValue: "A machine called %@ is already linked. Pick another name, or remove that one first."), name)
        case .hostKeyUnknown(let host):
            return String(format: String(localized: "machineSetup.error.hostKey",
                defaultValue: "This Mac doesn't know %1$@'s host key yet. Run “ssh %1$@” once in a terminal, check the fingerprint and accept it, then try again."), host)
        case .authRefused(let host):
            return String(format: String(localized: "machineSetup.error.auth",
                defaultValue: "%1$@ didn't accept your SSH key. c11 signs in with your keys and never asks for a password: run “ssh-copy-id %1$@”, then try again."), host)
        case .unknownHost(let host):
            return String(format: String(localized: "machineSetup.error.unknownHost",
                defaultValue: "No machine called %@ could be found. Check the name, or use its address."), host)
        case .unreachable(let host, let why):
            return String(format: String(localized: "machineSetup.error.unreachable",
                defaultValue: "Couldn't reach %1$@ over SSH (%2$@). Check that it's on, on your network, and has Remote Login turned on."), host, why)
        case .unsupported(let host, let system):
            return String(format: String(localized: "machineSetup.error.unsupported",
                defaultValue: "%1$@ runs %2$@. c11 can add Macs with Apple silicon and x86-64 Linux machines; other machines are not supported yet."), host, system)
        case .needsCommandLineTools(let host):
            return String(format: String(localized: "machineSetup.error.clt",
                defaultValue: "%@ needs Apple's Command Line Tools for c11's link. Run “xcode-select --install” on it, then try again."), host)
        case .needsLinger(let host, let user):
            return String(format: String(localized: "machineSetup.error.linger",
                defaultValue: "%1$@ stops %2$@'s programs when their last login ends, and c11's terminals there would end with them. Run “sudo loginctl enable-linger %2$@” on it, then try again."), host, user)
        case .needsNoFile(let host, let limit):
            return String(format: String(localized: "machineSetup.error.nofile",
                defaultValue: "%1$@ lets your services there open only %2$lld files, which c11's terminals outgrow. On it, put “DefaultLimitNOFILE=524288” under [Manager] in /etc/systemd/user.conf.d/50-c11-nofile.conf, run “systemctl --user daemon-reexec”, then try again."), host, limit)
        case .needsPython(let host):
            return String(format: String(localized: "machineSetup.error.python",
                defaultValue: "%@ needs Python 3 at /usr/bin/python3 for c11's link. Install it there (on Debian or Ubuntu, “sudo apt install python3”), then try again."), host)
        case .needsSHA256(let host):
            return String(format: String(localized: "machineSetup.error.sha256",
                defaultValue: "%@ has neither sha256sum nor shasum, which c11 uses to check its hc there. Install coreutils there, then try again."), host)
        case .needsTar(let host):
            return String(format: String(localized: "machineSetup.error.tar",
                defaultValue: "%@ has no tar, which c11 uses to unpack its relay kit there. Install tar there (on Debian or Ubuntu, “sudo apt install tar”), then try again."), host)
        case .needsUserManager(let host):
            return String(format: String(localized: "machineSetup.error.userManager",
                defaultValue: "%@ runs no systemd user manager for you, which c11's terminals there need to outlive your logins. c11 can add Linux machines that run systemd."), host)
        case .linuxFilesMissing(let host):
            return String(format: String(localized: "machineSetup.error.linuxFilesMissing",
                defaultValue: "This c11 build doesn't name c11's files for Linux, so it can't add %@. A released c11 can."), host)
        case .linuxFileFailed(let name, let why):
            return String(format: String(localized: "machineSetup.error.linuxFileFailed",
                defaultValue: "c11 couldn't get its Linux %1$@ (%2$@). Check this Mac's network, or run “c11 machine link --artifacts <folder>” with a folder holding it, then try again."), name, why)
        case .linuxFileMismatch(let name, let found, let expected):
            return String(format: String(localized: "machineSetup.error.linuxFileMismatch",
                defaultValue: "The Linux %1$@ c11 got isn't the one this build names (it hashes %2$@, this build expects %3$@), so c11 didn't use it."),
                name, String(found.prefix(12)), String(expected.prefix(12)))
        case .linuxFileNotInFolder(let name, let folder):
            return String(format: String(localized: "machineSetup.error.linuxFileNotInFolder",
                defaultValue: "No file in %2$@ is this build's Linux %1$@ (c11 matches it by its hash), so c11 didn't download it instead. Put the file in that folder, or leave out “--artifacts” to download it."),
                name, folder)
        case .sshFailed(let host, let why):
            return String(format: String(localized: "machineSetup.error.ssh",
                defaultValue: "SSH to %1$@ failed: %2$@"), host, why)
        case .installRefusedInUse(let host):
            return String(format: String(localized: "machineSetup.error.inUse",
                defaultValue: "c11's hc file on %@ differs from this build's and is running, so it wasn't replaced. Remove the machine (which ends its c11 terminals), then add it again."), host)
        case .hcHashMismatch(let host, let found, let expected):
            return String(format: String(localized: "machineSetup.error.hashMismatch",
                defaultValue: "The hc on %1$@ isn't the one this c11 ships (it hashes %2$@, this build expects %3$@), so c11 didn't link it."),
                host, String(found.prefix(12)), String(expected.prefix(12)))
        case .hcServingMismatch(let host, let pid, let found):
            return String(format: String(localized: "machineSetup.error.servingMismatch",
                defaultValue: "An hc that isn't this build's is already serving c11 on %1$@ (process %2$lld, %3$@), so c11 didn't use it or stop it. End that process there, then try again."),
                host, pid, String(found.prefix(12)))
        case .updateTargetChanged(let name, let linked, let requested):
            return String(format: String(localized: "machineSetup.error.updateTarget",
                defaultValue: "%1$@ is linked through %2$@, not %3$@. To link it through another host, remove it and add it again."),
                name, linked, requested)
        case .updateTargetUnknown(let name):
            return String(format: String(localized: "machineSetup.error.updateTargetUnknown",
                defaultValue: "c11 can't read how %@ is linked, so it won't update it in place. Remove it and add it again."), name)
        case .folderRefused(let host, let path, let reason):
            return String(format: String(localized: "machineSetup.error.folderRefused",
                defaultValue: "c11 couldn't make hc's folder %2$@ on %1$@ private (%3$@), so it didn't link it. Fix or remove that folder there, then try again."),
                host, path, reason)
        case .updateNeedsNoTerminals(let name, let count):
            return String(format: String(localized: "machineSetup.error.updateBusy",
                defaultValue: "%1$@ still has %2$lld c11 terminals open. Updating restarts its hc, which would end them: close them, or Remove the machine and add it again."), name, count)
        case .updateLeftUnlinked(let name, let why):
            return String(format: String(localized: "machineSetup.error.updateUnlinked",
                defaultValue: "%1$@ was unlinked to update it, but linking it again failed: %2$@ Add it again with Add Machine."), name, why)
        case .removeIncomplete(let name, let why):
            return String(format: String(localized: "machineSetup.error.removeIncomplete",
                defaultValue: "Couldn't end everything c11 runs on %1$@ (%2$@), so it was not removed. Try again."), name, why)
        case .installFailed(let host, let why):
            return String(format: String(localized: "machineSetup.error.install",
                defaultValue: "Couldn't install c11's hc on %1$@: %2$@"), host, why)
        case .relayFailed(let host, let why):
            return String(format: String(localized: "machineSetup.error.relay",
                defaultValue: "Couldn't install the relay on %1$@: %2$@"), host, why)
        case .missingResource(let what):
            return String(format: String(localized: "machineSetup.error.resource",
                defaultValue: "This c11 build is missing %@. Reinstall c11."), what)
        case .coreUnavailable(let why):
            return String(format: String(localized: "machineSetup.error.core",
                defaultValue: "c11's hc on this Mac isn't answering (%@). Open c11 and try again."), why)
        case .addFailed(let name, let why):
            return String(format: String(localized: "machineSetup.error.add",
                defaultValue: "hc couldn't link %1$@: %2$@"), name, why)
        case .removeFailed(let name, let why):
            return String(format: String(localized: "machineSetup.error.remove",
                defaultValue: "hc couldn't remove %1$@: %2$@"), name, why)
        case .notConnected(let name, let state):
            return String(format: String(localized: "machineSetup.error.notConnected",
                defaultValue: "%1$@ was added but its link is %2$@. It will keep retrying; check it in Settings > Herder Topography."), name, state)
        }
    }
}

struct HCMachineSetupRequest: Equatable, Sendable {
    /// How ssh reaches it: a Host from ~/.ssh/config, a host name, or user@host.
    let host: String
    /// hc's machine name; derived from the host when nil.
    let name: String?
    /// An already linked machine whose hc is older than this app's: install
    /// and relay again, keep the link.
    var update: Bool = false
}

struct HCMachineSetupResult: Equatable, Sendable {
    let name: String
    let host: String
    let viaScript: String
    let installedHC: Bool
    let version: String
}

/// What one external command returned.
struct HCMachineSetupOutput: Equatable, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// The seam every command goes through.
protocol HCMachineSetupRunner: Sendable {
    /// Run `argv` with `stdin` (a file, or nothing) and an exact environment.
    func run(_ argv: [String], stdin: URL?, environment: [String: String], timeout: TimeInterval) -> HCMachineSetupOutput
}

/// The files the build carries for this flow.
struct HCMachineSetupResources: Equatable, Sendable {
    let linkScript: URL
    let relayScript: URL
    let cli: URL
    /// C11H-392: the app's `Contents` folder, whose Info.plist, Claude wrapper
    /// with its agent note, and bundled c11 skill go into the relay kit there.
    var kitContents: URL? = nil

    /// From a c11 .app bundle: `Contents/Resources/bin/…`.
    static func inBundle(_ bundle: URL) -> HCMachineSetupResources {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let bin = contents.appendingPathComponent("Resources/bin", isDirectory: true)
        return HCMachineSetupResources(
            linkScript: bin.appendingPathComponent("c11-atlas-link.sh"),
            relayScript: bin.appendingPathComponent("c11-atlas-relay.sh"),
            cli: bin.appendingPathComponent("c11"),
            kitContents: contents
        )
    }
}

/// What the probe learned about the far machine.
struct HCMachineSetupProbe: Equatable, Sendable {
    let system: String
    let arch: String
    let home: String
    let user: String
    let hasCommandLineTools: Bool
    /// SHA-256 of `~/.local/share/c11/hc/<pin>/herdr-core` there, nil when absent.
    let pinSHA256: String?
    /// C11H-392: what a Linux machine needs. The launcher is Python, the
    /// installer hashes with sha256sum or shasum, and hc runs the core as a
    /// systemd user service: it needs this user's manager, linger (or it
    /// stops at the last logout) and enough files (the manager's default
    /// NOFILE soft limit; Int.max for infinity, nil when unread).
    var hasPython3 = false
    var hasSHA256 = false
    /// C11H-398: the relay step runs `tar -xf` there, on either platform.
    var hasTar = false
    var userManager = false
    var linger = false
    var serviceNoFile: Int? = nil

    enum Platform: String, Equatable, Sendable {
        case macArm64 = "mac"
        case linuxX86_64 = "linux"

        /// The remote artifacts' platform name.
        var artifactPlatform: String { "linux-x86_64" }
    }

    var platform: Platform? {
        switch (system, arch) {
        case ("Darwin", "arm64"): return .macArm64
        case ("Linux", "x86_64"): return .linuxX86_64
        default: return nil
        }
    }

    var isAppleSiliconMac: Bool { platform == .macArm64 }

    static func parse(_ text: String) -> HCMachineSetupProbe? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        // C11H-332: home and user reach a remote command line and the audit, so
        // only plain paths and names are accepted.
        guard let system = values["os"], let arch = values["arch"], let home = values["home"],
              let user = values["user"],
              home.range(of: #"^/[A-Za-z0-9._/-]{1,255}$"#, options: .regularExpression) != nil, !home.contains(".."),
              user.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { return nil }
        let pin = values["pin"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
        var probe = HCMachineSetupProbe(system: system, arch: arch, home: home, user: user,
                                        hasCommandLineTools: values["clt"] == "yes", pinSHA256: pin)
        probe.hasPython3 = values["python3"] == "yes"
        probe.hasSHA256 = values["sha"] == "yes"
        probe.hasTar = values["tar"] == "yes"
        probe.userManager = values["manager"] == "yes"
        probe.linger = values["linger"] == "yes"
        if let raw = values["nofile"] {
            probe.serviceNoFile = raw == "infinity" ? Int.max : Int(raw)
        }
        return probe
    }

    /// C11H-392: the first thing this machine lacks for c11's link, or nil.
    func missing(host: String) -> HCMachineSetupFailure? {
        switch platform {
        case nil:
            return .unsupported(host: host, system: "\(system) \(arch)")
        case .macArm64?:
            if !hasCommandLineTools { return .needsCommandLineTools(host) }
            return hasTar ? nil : .needsTar(host)
        case .linuxX86_64?:
            if !hasPython3 { return .needsPython(host) }
            if !hasSHA256 { return .needsSHA256(host) }
            if !hasTar { return .needsTar(host) }
            if !userManager { return .needsUserManager(host) }
            if !linger { return .needsLinger(host: host, user: user) }
            if let limit = serviceNoFile, limit >= 8192 { return nil }
            return .needsNoFile(host: host, limit: serviceNoFile ?? 0)
        }
    }
}

enum HCMachineSetup {
    static let sshPath = "/usr/bin/ssh"
    static let sshTimeout: TimeInterval = 30
    static let transferTimeout: TimeInterval = 180
    /// Remote staging folder, one per run (two runs never clean up each
    /// other's files), removed when the run ends.
    static func remoteSetupDir(run: String) -> String { "$HOME/.local/share/c11/setup-\(run)" }

    // MARK: Names

    /// An ssh destination: no option-like or shell-special text.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 255, !host.hasPrefix("-") else { return false }
        // The same rule the via renderer applies (`safe_token`).
        return host.range(of: #"^[A-Za-z0-9][A-Za-z0-9._@-]*$"#, options: .regularExpression) != nil
    }

    /// An hc machine name: lower case, short, not one of this Mac's words.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 32, !["local", "here"].contains(name) else { return false }
        return name.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// `me@studio.lan` reads `studio`.
    static func defaultName(forHost host: String) -> String {
        let afterUser = host.split(separator: "@").last.map(String.init) ?? host
        if afterUser.allSatisfy({ $0.isNumber || $0 == "." }), afterUser.contains(".") {
            return String(afterUser.replacingOccurrences(of: ".", with: "-").prefix(32))
        }
        let first = afterUser.split(separator: ".").first.map(String.init) ?? afterUser
        let cleaned = first.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(cleaned.prefix(32))
    }

    /// Where the via script for `name` lives on this Mac.
    static func viaURL(home: URL, name: String) -> URL {
        home.appendingPathComponent(".local/share/c11/vias", isDirectory: true)
            .appendingPathComponent("\(name)-via.sh")
    }

    // MARK: ssh

    /// C11H-361: every ssh c11 opens for a link turns forwarding off,
    /// whatever `~/.ssh/config` says: no agent, no X11, no local, remote or
    /// dynamic forward, no LocalCommand, no GSSAPI credential delegation.
    /// The via `c11-atlas-link.sh` renders carries the same list
    /// (`LINK_SSH_NO_FORWARDING`), in the same order, before `--`.
    static let sshForwardingOff = ["-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
                                   "-o", "PermitLocalCommand=no", "-k"]

    static func sshArgv(host: String, remoteCommand: String) -> [String] {
        [sshPath, "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=no",
         "-o", "ControlPath=none", "-o", "ServerAliveInterval=15"] + sshForwardingOff + ["--", host, remoteCommand]
    }

    /// Read ssh's own error for the cases an operator can fix.
    static func classifySSH(status: Int32, stderr: String, host: String) -> HCMachineSetupFailure? {
        guard status == 255 else { return nil }
        let text = stderr.lowercased()
        if text.contains("host key verification failed") || text.contains("no matching host key")
            || text.contains("remote host identification has changed") {
            return .hostKeyUnknown(host)
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            return .authRefused(host)
        }
        if text.contains("could not resolve hostname") || text.contains("nodename nor servname") {
            return .unknownHost(host)
        }
        if text.contains("timed out") {
            return .unreachable(host, String(localized: "machineSetup.reason.timedOut", defaultValue: "it timed out"))
        }
        if text.contains("connection refused") {
            return .unreachable(host, String(localized: "machineSetup.reason.refused", defaultValue: "the connection was refused"))
        }
        if text.contains("no route to host") {
            return .unreachable(host, String(localized: "machineSetup.reason.noRoute", defaultValue: "no route to it"))
        }
        if text.contains("connection closed") || text.contains("connection reset") {
            return .unreachable(host, String(localized: "machineSetup.reason.closed",
                                             defaultValue: "the connection was closed; Remote Login may not allow this user"))
        }
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit 255"
        return .sshFailed(host, line)
    }

    /// The probe, sent on stdin to `/bin/sh -s` there, so no quoting reaches
    /// the far machine's login shell.
    ///
    /// C11H-392: tools are found on PATH (a Linux machine keeps them in other
    /// places than a Mac), and a Linux machine also reports Python, a SHA-256
    /// tool, its systemd user manager, linger and that manager's default NOFILE
    /// soft limit.
    static func probeScript(pinVersion: String) -> String {
        """
        os=$(uname -s)
        printf 'os=%s\\n' "$os"
        printf 'arch=%s\\n' "$(uname -m)"
        printf 'home=%s\\n' "$HOME"
        printf 'user=%s\\n' "$(id -un)"
        if [ "$os" = Darwin ]; then if /usr/bin/xcode-select -p >/dev/null 2>&1; then echo clt=yes; else echo clt=no; fi; fi
        if [ -x /usr/bin/python3 ]; then echo python3=yes; fi
        if command -v shasum >/dev/null 2>&1; then s='shasum -a 256'; elif command -v sha256sum >/dev/null 2>&1; then s=sha256sum; else s=; fi
        if [ -n "$s" ]; then echo sha=yes; fi
        if command -v tar >/dev/null 2>&1; then echo tar=yes; fi
        p="$HOME/.local/share/c11/hc/\(pinVersion)/herdr-core"
        if [ -f "$p" ] && [ -n "$s" ]; then printf 'pin=%s\\n' "$($s "$p" | awk '{print $1}')"; fi
        if [ "$os" = Linux ]; then
          r="/run/user/$(id -u)"
          if [ -S "$r/systemd/private" ]; then echo manager=yes; fi
          if [ -e "/var/lib/systemd/linger/$(id -un)" ]; then echo linger=yes; fi
          printf 'nofile=%s\\n' "$(XDG_RUNTIME_DIR="$r" systemctl --user show -p DefaultLimitNOFILESoft --value 2>/dev/null)"
        fi
        """
    }

    /// C11H-332: Add Machine's check after install, run on the far machine by
    /// the staged link script: the same launcher code every dial runs, in
    /// report mode. It prints the pinned hc's hash (`sha=`), each folder it
    /// created, repaired or refused (stopping at the first refusal), and
    /// whether a core already serves the session's socket and is this pin
    /// (`serving=`). It never starts or signals hc.
    static func secureCommand(session: String, socket: String, hc: String, sha256: String, dir: String) -> String {
        "/bin/sh \"\(dir)/c11-atlas-link.sh\" secure --session \(session) --socket \(socket) --hc \(hc) --sha \(sha256.lowercased())"
    }

    /// C11H-332: Remove's and Update's stop, run by the staged link script:
    /// `server stop` runs only when `hc` hashes to `sha256` and the process
    /// serving `socket` is identified from the kernel as an hc in `allow`.
    /// Exit 7: the client isn't the pin; exit 8: the serving core is foreign
    /// or unknown, left running and never signalled; exit 0: stopped, or
    /// nothing was serving.
    static func stopCoreCommand(session: String, socket: String, hc: String, sha256: String, allow: [String], dir: String) -> String {
        let allowed = Array(Set(([sha256] + allow).map { $0.lowercased() })).sorted().joined(separator: ",")
        return "/bin/sh \"\(dir)/c11-atlas-link.sh\" stop --session \(session) --socket \(socket) --hc \(hc) --sha \(sha256.lowercased()) --allow \(allowed)"
    }

    struct SecureReport: Equatable, Sendable {
        enum Serving: Equatable, Sendable {
            /// No core answers on the session's socket.
            case absent
            case ok(pid: Int)
            /// A core serves the session's socket and is not this pin (or its
            /// identity could not be read): `found` is its hash or a reason.
            case mismatch(pid: Int, found: String)
        }

        /// The pinned hc's hash there; nil when it is missing.
        var sha256: String?
        var created: [String] = []
        var repaired: [(path: String, mode: String)] = []
        var refused: [(path: String, reason: String)] = []
        /// Nil when the report named no serving line (treated as unverified).
        var serving: Serving?

        static func == (a: SecureReport, b: SecureReport) -> Bool {
            a.sha256 == b.sha256 && a.created == b.created && a.serving == b.serving
                && a.repaired.map { "\($0.path) \($0.mode)" } == b.repaired.map { "\($0.path) \($0.mode)" }
                && a.refused.map { "\($0.path) \($0.reason)" } == b.refused.map { "\($0.path) \($0.reason)" }
        }

        /// The most lines a valid report can hold, with room for noise: one
        /// sha, one serving, one refusal and one line per walked folder.
        static let maximumLines = 64

        /// C11H-365 (L11): `folders` are the folders the walk makes private,
        /// computed here (`securedFolders`). A valid report has one `sha`, at
        /// most one `serving`, at most one `created` or `repaired` line for each
        /// of those folders and at most one `refused` line. Anything else (a
        /// folder c11 did not walk, a repeated line, an over-long report) is
        /// invalid: nil, and the caller records that once, never line by line.
        static func parse(_ text: String, folders: [String]) -> SecureReport? {
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.count <= maximumLines else { return nil }
            let walked = Set(folders)
            var report = SecureReport()
            var sawHash = false, sawServing = false
            var reported: Set<String> = []
            for line in lines {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
                func split() -> (String, String) {
                    guard let space = value.lastIndex(of: " ") else { return (value, "") }
                    return (String(value[..<space]), String(value[value.index(after: space)...]))
                }
                switch key {
                case "sha":
                    guard !sawHash else { return nil }
                    sawHash = true
                    let hash = value.lowercased()
                    report.sha256 = hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil ? hash : nil
                case "created":
                    guard walked.contains(value), reported.insert(value).inserted else { return nil }
                    report.created.append(Self.checkedPath(value))
                case "repaired":
                    let (path, mode) = split()
                    guard walked.contains(path), reported.insert(path).inserted else { return nil }
                    report.repaired.append((Self.checkedPath(path), mode.range(of: "^[0-7]{3,4}$", options: .regularExpression) != nil ? mode : "?"))
                case "refused":
                    guard report.refused.isEmpty else { return nil }
                    let (path, reason) = split()
                    report.refused.append((Self.checkedPath(path), C11AuditRecord.checked(reason, #"^[a-z0-9_]{1,40}$"#) ?? "invalid"))
                case "serving":
                    guard !sawServing else { return nil }
                    sawServing = true
                    let words = value.split(separator: " ").map(String.init)
                    let pid = words.count > 1 ? Int(words[1]) ?? 0 : 0
                    switch words.first {
                    case "none": report.serving = .absent
                    case "ok": report.serving = .ok(pid: pid)
                    default:
                        let found = words.count > 2 ? words[2] : "unknown"
                        report.serving = .mismatch(pid: pid, found: C11AuditRecord.checked(found, #"^[a-z0-9_]{1,64}$"#) ?? "unknown")
                    }
                default: continue
                }
            }
            return sawHash ? report : nil
        }

        /// A path the far machine printed: plain characters only, else `invalid`.
        static func checkedPath(_ value: String) -> String {
            C11AuditRecord.checked(value, C11AuditRecord.pathPattern) ?? "invalid"
        }
    }

    /// C11H-365 (L11): the folders the far launcher's walk makes private, as
    /// its `secure_folders` names them: the socket's folder, hc's state
    /// folder, and the session's folder inside it.
    static func securedFolders(home: String, session: String, socket: String) -> [String] {
        let state = home + "/.local/state/herdr-core"
        return [(socket as NSString).deletingLastPathComponent, state, state + "/" + session]
    }

    static func writeRemoteFileCommand(_ name: String, dir: String) -> String {
        "umask 077; mkdir -p \"\(dir)\" && cat > \"\(dir)/\(name)\" && chmod 700 \"\(dir)/\(name)\""
    }

    static func installCommand(pinVersion: String, sha256: String, dir: String) -> String {
        "/bin/sh \"\(dir)/c11-atlas-link.sh\" install --pin \(pinVersion) --sha \(sha256.lowercased())"
    }

    /// C11H-392: the relay kit's payload goes over as one archive, unpacked in
    /// the staging folder, and the installer reads it around `--cli`.
    static let kitArchiveName = "c11-kit.tar"
    static let kitCLIPath = "kit/Contents/Resources/bin/c11"
    /// The Claude wrapper and its note, which the installer takes only as a set
    /// (scripts/c11-atlas-relay.sh `has_claude`).
    static let kitWrapperFiles = ["claude", "c11-agent-note.sh", "c11-agent-note.txt"]

    static func relayCommand(session: String, dir: String) -> String {
        "umask 077; cd \"\(dir)\" && tar -xf \(kitArchiveName) && /bin/sh \"\(dir)/c11-atlas-relay.sh\" install --session \(session) --cli \"\(dir)/\(kitCLIPath)\""
    }

    /// C11H-392 (Astra 1 on #384): the relay kit's payload, laid out under
    /// `root` as the app the installer reads around `--cli` (`kit_plan`): the
    /// CLI for that machine, and from this app its Info.plist, its Claude
    /// wrapper with the agent note, and the bundled c11 skill. With the CLI
    /// alone a fresh kit has no `bin/claude`, so Claude there runs without
    /// c11's wrapper, its Stop mail drain and its launch note. A part this app
    /// lacks is left out, as before. Returns the payload's CLI.
    static func layOutKit(contents: URL?, cli: URL, at root: URL) throws -> URL {
        let files = FileManager.default
        let kit = root.appendingPathComponent("kit/Contents", isDirectory: true)
        let bin = kit.appendingPathComponent("Resources/bin", isDirectory: true)
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let kitCLI = bin.appendingPathComponent("c11")
        try files.copyItem(at: cli, to: kitCLI)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kitCLI.path)
        guard let contents else { return kitCLI }
        let plist = contents.appendingPathComponent("Info.plist")
        if files.fileExists(atPath: plist.path) { try files.copyItem(at: plist, to: kit.appendingPathComponent("Info.plist")) }
        let appBin = contents.appendingPathComponent("Resources/bin", isDirectory: true)
        if kitWrapperFiles.allSatisfy({ files.fileExists(atPath: appBin.appendingPathComponent($0).path) }) {
            for name in kitWrapperFiles {
                try files.copyItem(at: appBin.appendingPathComponent(name), to: bin.appendingPathComponent(name))
            }
        }
        let skill = contents.appendingPathComponent("Resources/skills/c11", isDirectory: true)
        if files.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path) {
            let skills = kit.appendingPathComponent("Resources/skills", isDirectory: true)
            try files.createDirectory(at: skills, withIntermediateDirectories: true)
            try files.copyItem(at: skill, to: skills.appendingPathComponent("c11", isDirectory: true))
        }
        return kitCLI
    }

    static func cleanupCommand(dir: String) -> String { "rm -rf \"\(dir)\"" }

    /// c11's own hc config there (what `install --from` writes): the via
    /// points the far core's XDG_CONFIG_HOME at it. Written only when absent;
    /// an existing file is left as it is.
    static let ensureConfigCommand =
        "d=\"$HOME/.local/share/c11/config/herdr-core\"; umask 077; mkdir -p \"$d\" && "
        + "if [ ! -e \"$d/config.toml\" ]; then printf 'headless = \"200x120\"\\n' > \"$d/config.toml.$$\" && mv -f \"$d/config.toml.$$\" \"$d/config.toml\"; fi"

    /// What a rendered ssh via script runs on the far machine: its ssh
    /// target, and the hc binary, session and socket it starts there. Every
    /// value is held to the renderer's own token and path rules.
    struct ViaInfo: Equatable, Sendable {
        let target: String
        let hc: String
        let session: String
        let socket: String
        /// C11H-332: the pin the via checks at every dial; nil for a via
        /// rendered before the pin was required (it needs Update).
        var sha256: String? = nil

        /// A c11h-era via is accepted only while this app has adopted c11h's sessions (C11H-266).  c11-2.0:legacy
        static func parse(_ script: String, adopted: Bool = HCLaunchPolicy.processNamespace != nil) -> ViaInfo? {
            func match(_ pattern: String) -> String? {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let found = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                      found.numberOfRanges > 1, let range = Range(found.range(at: 1), in: script) else { return nil }
                return String(script[range])
            }
            let path = #"(/[A-Za-z0-9._/-]+)"#
            guard let target = match(#"-- ([A-Za-z0-9][A-Za-z0-9._@-]*) '"#), isValidHost(target),
                  let hc = match(path + #"/herdr-core connect --session"#).map({ $0 + "/herdr-core" }),
                  let session = match(#"connect --session (c11h?(?:-[A-Za-z0-9][A-Za-z0-9._-]*)?)"#),  // c11-2.0:legacy
                  let socket = match(#"HC_SOCKET="# + path),
                  !hc.contains(".."), !socket.contains(".."),
                  hc.contains("/.local/share/c11/hc/") || (adopted && hc.contains("/.local/share/c11h/hc/")),  // c11-2.0:legacy
                  adopted || !session.hasPrefix("c11h") else { return nil }  // c11-2.0:legacy
            let sha = match(#"sha256=([0-9a-f]{64}) "#)
            return ViaInfo(target: target, hc: hc, session: session, socket: socket, sha256: sha)
        }

        /// The hashes a core this via started may have: its own pin, or this
        /// build's when the via predates the pin.
        func allowedServing(pin: String) -> [String] {
            Array(Set([pin.lowercased()] + (sha256.map { [$0] } ?? [])))
        }
    }

    /// The via a listed machine uses, when it is one of c11's own files here.
    static func viaScript(for machine: ListedMachine, home: URL) -> String? {
        // A c11h-era link adopted by 2.0 (C11H-266) keeps its via under c11h's folder.  // c11-2.0:legacy
        let adopted = HCLaunchPolicy.processNamespace != nil
        guard let path = machine.target, !path.contains(".."),
              path.hasPrefix(home.path + "/.local/share/c11/")
                || (adopted && path.hasPrefix(home.path + "/.local/share/c11h/")) else { return nil }  // c11-2.0:legacy
        return try? String(contentsOfFile: path, encoding: .utf8)
    }



    // MARK: hc machine ls

    struct ListedMachine: Equatable, Sendable {
        let name: String
        let state: String
        let version: String?
        let host: String?
        /// The via script hc dials it through.
        var target: String? = nil
    }

    static func parseMachineList(_ json: String) -> [ListedMachine]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let machines = object["machines"] as? [[String: Any]] else { return nil }
        return machines.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return ListedMachine(name: name, state: entry["state"] as? String ?? "unknown",
                                 version: entry["version"] as? String, host: entry["host"] as? String,
                                 target: entry["target"] as? String)
        }
    }

    /// Live terminals on `machine` in `hc ls --json` (addresses `machine/tN`).
    static func liveTerminals(on machine: String, lsJSON: String) -> [String] {
        guard let data = lsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terminals = object["terminals"] as? [[String: Any]] else { return [] }
        return terminals.compactMap { entry in
            guard let address = entry["address"] as? String, address.hasPrefix("\(machine)/"),
                  (entry["state"] as? String ?? "live") != "finished" else { return nil }
            return address
        }
    }

    /// Proves, read-only, that the socket is this user's c11 core serving
    /// this build's pin (the `c11-core` checks). Nil when verified.
    static func verifyOwnCore(configuration: HCLaunchConfiguration, host: HCCoreHost) -> String? {
        switch HCCoreUtility.open(configuration, host: host) {
        case .verified(let connection):
            connection.link.close()
            return nil
        case .refused(_, _, let detail):
            return detail
        }
    }

    /// The far machine's hc is older than this app's, or (C11H-332) its via
    /// doesn't check this build's pin at every dial: its row offers an update.
    /// C11H-392: `otherPins` are this build's pins for other platforms (a
    /// Linux machine's via checks the Linux hc's hash, not this Mac's).
    static func needsUpdate(_ machine: ListedMachine, pinVersion: String, pinSHA256: String? = nil,
                            viaScript: String? = nil, otherPins: Set<String> = []) -> Bool {
        if machine.state == "needs_update" { return true }
        if let pinSHA256, let viaScript {
            let current = Set([pinSHA256.lowercased()]).union(otherPins.map { $0.lowercased() })
            guard let via = ViaInfo.parse(viaScript)?.sha256, current.contains(via) else { return true }
        }
        guard let version = machine.version, !version.isEmpty else { return false }
        return version != pinVersion
    }
}

/// C11H-392: where a Linux machine's hc and relay CLI come from: the files
/// this build's signed manifest names (`HCRemoteArtifacts`), from c11's cache,
/// an operator's folder or the release, each checked against its hash.
struct HCMachineSetupLinuxFiles: Sendable {
    let manifest: HCRemoteArtifactManifest?
    let store: HCRemoteArtifactStore
    var importDirectory: URL? = nil

    static func forBundle(_ bundle: URL, home: URL, importDirectory: URL? = nil) -> HCMachineSetupLinuxFiles {
        HCMachineSetupLinuxFiles(manifest: HCRemoteArtifactManifest.load(bundle: bundle),
                                 store: HCRemoteArtifactStore(cacheRoot: HCRemoteArtifactStore.cacheRoot(home: home)),
                                 importDirectory: importDirectory)
    }

    /// The pinned hc's SHA-256 a Linux link checks, when this build names one.
    var hcSHA256: String? { manifest?.artifact(platform: "linux-x86_64", name: "herdr-core")?.sha256 }

    /// The hc and CLI files for `platform`, each already checked against its hash.
    func resolve(platform: String, pinVersion: String, host: String)
        -> Result<(hc: URL, sha256: String, cli: URL), HCMachineSetupFailure> {
        guard let hc = manifest?.artifact(platform: platform, name: "herdr-core"), hc.version == pinVersion,
              let cli = manifest?.artifact(platform: platform, name: "c11") else { return .failure(.linuxFilesMissing(host)) }
        func get(_ artifact: HCRemoteArtifact) -> Result<URL, HCMachineSetupFailure> {
            switch store.resolve(artifact, importDirectory: importDirectory) {
            case .success(let url): return .success(url)
            case .failure(.hashMismatch(let name, let found, let expected)):
                return .failure(.linuxFileMismatch(name: name, found: found, expected: expected))
            case .failure(.downloadFailed(let name, let reason)), .failure(.cacheFailed(let name, let reason)):
                return .failure(.linuxFileFailed(name: name, reason: reason))
            case .failure(.notInFolder(let name, let folder)):
                return .failure(.linuxFileNotInFolder(name: name, folder: folder))
            case .failure(.noManifest), .failure(.notInManifest):
                return .failure(.linuxFilesMissing(host))
            }
        }
        return get(hc).flatMap { hcURL in get(cli).map { (hc: hcURL, sha256: hc.sha256, cli: $0) } }
    }
}

/// Runs the steps. Synchronous; callers keep it off the main thread.
struct HCMachineSetupFlow: Sendable {
    let configuration: HCLaunchConfiguration
    let resources: HCMachineSetupResources
    let runner: any HCMachineSetupRunner
    let localHome: URL
    /// Proves the socket is c11's own pinned core before any hc command;
    /// nil means verified, else why not.
    let verifyCore: @Sendable () -> String?
    let verifyAttempts: Int
    let verifyInterval: TimeInterval
    let sleep: @Sendable (TimeInterval) -> Void
    /// C11H-332: where each outcome is recorded, and who asked (`settings`, `cli`).
    let audit: C11AuditLog
    let origin: String
    /// C11H-392: a Linux machine's files; nil refuses every Linux machine.
    let linuxFiles: HCMachineSetupLinuxFiles?

    init(configuration: HCLaunchConfiguration, resources: HCMachineSetupResources,
         runner: any HCMachineSetupRunner, localHome: URL,
         verifyCore: @escaping @Sendable () -> String?,
         verifyAttempts: Int = 20, verifyInterval: TimeInterval = 1,
         sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         audit: C11AuditLog = .shared, origin: String = "app", linuxFiles: HCMachineSetupLinuxFiles? = nil) {
        self.configuration = configuration
        self.resources = resources
        self.runner = runner
        self.localHome = localHome
        self.verifyCore = verifyCore
        self.verifyAttempts = verifyAttempts
        self.verifyInterval = verifyInterval
        self.sleep = sleep
        self.audit = audit
        self.origin = origin
        self.linuxFiles = linuxFiles
    }

    private var sshEnvironment: [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": localHome.path]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["SSH_AUTH_SOCK", "USER", "LOGNAME"] {
            if let value = inherited[key], !value.isEmpty { environment[key] = value }
        }
        return environment
    }

    var hcEnvironment: [String: String] {
        var environment = configuration.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !agent.isEmpty {
            environment["SSH_AUTH_SOCK"] = agent
        }
        return environment
    }

    private func ssh(_ host: String, _ command: String, stdin: URL? = nil,
                     timeout: TimeInterval = HCMachineSetup.sshTimeout) -> HCMachineSetupOutput {
        runner.run(HCMachineSetup.sshArgv(host: host, remoteCommand: command), stdin: stdin,
                   environment: sshEnvironment, timeout: timeout)
    }

    private func hc(_ arguments: [String], timeout: TimeInterval) -> HCMachineSetupOutput {
        runner.run([configuration.executableURL.path] + arguments, stdin: nil, environment: hcEnvironment, timeout: timeout)
    }

    private func reason(_ output: HCMachineSetupOutput) -> String {
        let text = (output.stderr.isEmpty ? output.stdout : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return last.isEmpty ? "exit \(output.status)" : String(last.prefix(300))
    }

    /// hc's own list of linked machines: the authoritative name check.
    private func listMachines() -> [HCMachineSetup.ListedMachine]? {
        let listed = hc(["machine", "ls", "--json"], timeout: 10)
        return listed.status == 0 ? HCMachineSetup.parseMachineList(listed.stdout) : nil
    }

    func run(_ request: HCMachineSetupRequest,
             progress: (HCMachineSetupProgress) -> Void) -> Result<HCMachineSetupResult, HCMachineSetupFailure> {
        let outcome = perform(request, progress: progress)
        // C11H-332: codes and checked identifiers only; a rejected host or
        // name, and any message carrying another program's output, stay out.
        let rawHost = request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = HCMachineSetup.isValidHost(rawHost) ? rawHost : "invalid"
        let kind: C11AuditKind = request.update ? .update : .link
        switch outcome {
        case .success(let result):
            audit.record(C11AuditRecord(kind: kind, via: origin, outcome: "ok", machine: result.name, host: host,
                                        session: configuration.session, path: result.viaScript,
                                        detail: "hc \(result.version)\(result.installedHC ? ", installed" : "")"))
        case .failure(let failure):
            let requested = request.name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap { $0.isEmpty ? nil : $0 } ?? HCMachineSetup.defaultName(forHost: rawHost)
            let name = HCMachineSetup.isValidName(requested) ? requested : "invalid"
            audit.record(C11AuditRecord(kind: kind, via: origin, outcome: "failed", machine: name, host: host,
                                        session: configuration.session, code: failure.code))
        }
        return outcome
    }

    private func perform(_ request: HCMachineSetupRequest,
                         progress: (HCMachineSetupProgress) -> Void) -> Result<HCMachineSetupResult, HCMachineSetupFailure> {
        let host = request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HCMachineSetup.isValidHost(host) else { return .failure(.invalidHost(host)) }
        let name = request.name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 } ?? HCMachineSetup.defaultName(forHost: host)
        guard HCMachineSetup.isValidName(name) else { return .failure(.invalidName(name)) }
        for resource in [resources.linkScript, resources.relayScript, resources.cli, configuration.executableURL]
            where !FileManager.default.isReadableFile(atPath: resource.path) {
            return .failure(.missingResource(resource.lastPathComponent))
        }
        if let why = verifyCore() { return .failure(.coreUnavailable(why)) }
        guard let linked = listMachines() else { return .failure(.coreUnavailable("hc machine ls failed")) }
        let existing = linked.first { $0.name == name }
        var oldVia: HCMachineSetup.ViaInfo?
        if request.update {
            guard let existing else { return .failure(.notConnected(name, "not linked")) }
            // C11H-332: an update reinstalls on the machine already linked,
            // through the host it was linked through; any other host is a new
            // link, which asks for consent first. Checked before any SSH.
            guard let via = HCMachineSetup.viaScript(for: existing, home: localHome).flatMap({ HCMachineSetup.ViaInfo.parse($0) }) else {
                return .failure(.updateTargetUnknown(name))
            }
            guard via.target == host else {
                return .failure(.updateTargetChanged(name: name, linked: via.target, requested: host))
            }
            oldVia = via
            let lsOutput = hc(["ls", "--json"], timeout: 10)
            guard lsOutput.status == 0 else { return .failure(.coreUnavailable("hc ls failed")) }
            let live = HCMachineSetup.liveTerminals(on: name, lsJSON: lsOutput.stdout)
            guard live.isEmpty else { return .failure(.updateNeedsNoTerminals(name, live.count)) }
        } else if existing != nil {
            return .failure(.nameTaken(name))
        }
        let pin = configuration.pin
        let session = configuration.session
        let stagingDir = HCMachineSetup.remoteSetupDir(run: String(UUID().uuidString.prefix(8)).lowercased())

        func fail(_ step: HCMachineSetupStep, _ failure: HCMachineSetupFailure) -> Result<HCMachineSetupResult, HCMachineSetupFailure> {
            progress(HCMachineSetupProgress(step: step, state: .failed, detail: failure.message))
            return .failure(failure)
        }

        // 1. Reach it and learn what it is.
        progress(HCMachineSetupProgress(step: .reach, state: .running, detail: host))
        let probeFile = FileManager.default.temporaryDirectory.appendingPathComponent("c11-probe-\(UUID().uuidString).sh")
        do { try HCMachineSetup.probeScript(pinVersion: pin.version).write(to: probeFile, atomically: true, encoding: .utf8) }
        catch { return fail(.reach, .sshFailed(host, "could not write the probe")) }
        defer { try? FileManager.default.removeItem(at: probeFile) }
        let probed = ssh(host, "/bin/sh -s", stdin: probeFile)
        if let failure = HCMachineSetup.classifySSH(status: probed.status, stderr: probed.stderr, host: host) {
            return fail(.reach, failure)
        }
        guard probed.status == 0, let probe = HCMachineSetupProbe.parse(probed.stdout) else {
            return fail(.reach, .sshFailed(host, reason(probed)))
        }
        if let missing = probe.missing(host: host) { return fail(.reach, missing) }
        guard let platform = probe.platform else { return fail(.reach, .unsupported(host: host, system: "\(probe.system) \(probe.arch)")) }
        let who = host.contains("@") ? host : "\(probe.user)@\(host)"
        progress(HCMachineSetupProgress(step: .reach, state: .done, detail: "\(who), \(probe.system) \(probe.arch)"))

        // C11H-392: the hc and relay CLI this machine runs, each checked against
        // the hash this build names: a Mac's are this app's own; a Linux
        // machine's come from c11's cache, an operator's folder or the release,
        // and are got before anything is written there.
        let hcFile: URL, expected: String, cliFile: URL
        switch platform {
        case .macArm64:
            (hcFile, expected, cliFile) = (configuration.executableURL, pin.executableSHA256.lowercased(), resources.cli)
        case .linuxX86_64:
            progress(HCMachineSetupProgress(step: .install, state: .running, detail: String(localized: "machineSetup.install.linuxFiles",
                                                                                        defaultValue: "c11's Linux files")))
            guard let linuxFiles else { return fail(.install, .linuxFilesMissing(host)) }
            switch linuxFiles.resolve(platform: platform.artifactPlatform, pinVersion: pin.version, host: host) {
            case .failure(let failure): return fail(.install, failure)
            case .success(let files): (hcFile, expected, cliFile) = (files.hc, files.sha256.lowercased(), files.cli)
            }
        }

        // 2. Stage the link script, then install or keep the pinned hc.
        func stage(_ file: URL, as remoteName: String) -> HCMachineSetupOutput {
            ssh(host, HCMachineSetup.writeRemoteFileCommand(remoteName, dir: stagingDir), stdin: file,
                timeout: HCMachineSetup.transferTimeout)
        }
        defer { _ = ssh(host, HCMachineSetup.cleanupCommand(dir: stagingDir)) }
        progress(HCMachineSetupProgress(step: .install, state: .running, detail: "hc \(pin.version)"))
        let remoteHC = "\(probe.home)/.local/share/c11/hc/\(pin.version)/herdr-core"
        let remoteRun = "\(probe.home)/.local/share/c11/run/\(session).sock"
        func record(_ kind: C11AuditKind, _ outcome: String, path: String? = remoteHC, code: String? = nil, detail: String? = nil) {
            audit.record(C11AuditRecord(kind: kind, via: origin, outcome: outcome, machine: name, host: host,
                                        session: session, path: path, code: code, detail: detail))
        }
        let staged = stage(resources.linkScript, as: "c11-atlas-link.sh")
        guard staged.status == 0 else { return fail(.install, .installFailed(host, reason(staged))) }
        let installed: Bool
        if probe.pinSHA256 == expected {
            // This build's own hc is already there (C11H-332: by hash, not by
            // its version's path): kept, never rewritten.
            installed = false
            progress(HCMachineSetupProgress(step: .install, state: .skipped, detail: "hc \(pin.version)"))
        } else {
            // Missing, or a different file at this version's path. The
            // installer replaces a different file only while nothing runs it,
            // and only with bytes that hash to this build's pin.
            let result = ssh(host, HCMachineSetup.installCommand(pinVersion: pin.version, sha256: expected, dir: stagingDir),
                             stdin: hcFile, timeout: HCMachineSetup.transferTimeout)
            if let found = probe.pinSHA256 {
                record(.hcHashMismatch, result.status == 0 ? "replaced" : "refused", code: result.status == 3 ? "hc_in_use" : nil,
                       detail: "found \(found.prefix(12)), expected \(expected.prefix(12))")
            }
            if result.status == 3 { return fail(.install, .installRefusedInUse(host)) }
            guard result.status == 0 else { return fail(.install, .installFailed(host, reason(result))) }
            installed = true
            progress(HCMachineSetupProgress(step: .install, state: .done, detail: probe.pinSHA256 == nil
                ? "hc \(pin.version)"
                : String(format: String(localized: "machineSetup.install.replaced",
                                        defaultValue: "hc %@, replaced a different file"), pin.version)))
        }
        let config = ssh(host, HCMachineSetup.ensureConfigCommand)
        guard config.status == 0 else { return fail(.install, .installFailed(host, reason(config))) }

        var unlinkedForUpdate = false
        func failLinked(_ step: HCMachineSetupStep, _ failure: HCMachineSetupFailure) -> Result<HCMachineSetupResult, HCMachineSetupFailure> {
            guard unlinkedForUpdate else { return fail(step, failure) }
            return fail(step, .updateLeftUnlinked(name, failure.message))
        }
        // The cores an update may stop: this pin, or the one the old link was made with.
        let priorServing = oldVia?.allowedServing(pin: expected) ?? [expected]

        // 2b. C11H-332: what is there now must be this build's hc, hc's
        // folders there must be this user's alone, and a core already serving
        // c11's session there must be this build's hc (for an update, the
        // old link's own pinned core, which the update then stops). Checked
        // before an update unlinks anything.
        progress(HCMachineSetupProgress(step: .secure, state: .running, detail: nil))
        let secured = ssh(host, HCMachineSetup.secureCommand(session: session, socket: remoteRun, hc: remoteHC,
                                                            sha256: expected, dir: stagingDir))
        if let failure = HCMachineSetup.classifySSH(status: secured.status, stderr: secured.stderr, host: host) {
            return failLinked(.secure, failure)
        }
        guard secured.status == 0 else { return failLinked(.secure, .sshFailed(host, reason(secured))) }
        let walked = HCMachineSetup.securedFolders(home: probe.home, session: session, socket: remoteRun)
        guard let report = HCMachineSetup.SecureReport.parse(secured.stdout, folders: walked) else {
            // C11H-365 (L11): one record for the whole report, whatever it held.
            record(.dirRefused, "refused", path: nil, code: "secure_report_invalid",
                   detail: "the far end's folder report was not one line per folder c11 walks")
            return failLinked(.secure, .sshFailed(host, String(localized: "machineSetup.secure.invalidReport",
                                                               defaultValue: "the machine's folder report was not valid")))
        }
        for (path, mode) in report.repaired { record(.dirRepaired, "ok", path: path, detail: "mode \(mode) to 700") }
        for (path, why) in report.refused { record(.dirRefused, "refused", path: path, code: why) }
        guard report.sha256 == expected else {
            let found = report.sha256 ?? "missing"
            record(.hcHashMismatch, "refused", detail: "found \(found.prefix(12)), expected \(expected.prefix(12))")
            return failLinked(.secure, .hcHashMismatch(host: host, found: found, expected: expected))
        }
        record(.hcVerified, "ok", detail: "hc \(pin.version) \(expected.prefix(12))")
        if let first = report.refused.first {
            return failLinked(.secure, .folderRefused(host: host, path: first.path, reason: first.reason))
        }
        switch report.serving {
        case .absent?:
            break
        case .ok(let pid)?:
            record(.hcVerified, "ok", code: "serving", detail: "serving core pid \(pid) is hc \(pin.version) \(expected.prefix(12))")
        case .mismatch(let pid, let found)? where request.update && priorServing.contains(found):
            record(.hcVerified, "ok", code: "serving_prior", detail: "serving core pid \(pid) is the link's own hc \(found.prefix(12))")
        case .mismatch(let pid, let found)?:
            record(.hcServingMismatch, "refused", code: "hc_serving_mismatch", detail: "pid \(pid), found \(found.prefix(12))")
            return failLinked(.secure, .hcServingMismatch(host: host, pid: pid, found: found))
        case nil:
            record(.hcServingMismatch, "refused", code: "hc_serving_unverified")
            return failLinked(.secure, .hcServingMismatch(host: host, pid: 0, found: "unknown"))
        }
        let fixed = report.repaired.count + report.created.count
        progress(HCMachineSetupProgress(step: .secure, state: .done, detail: fixed == 0
            ? "hc \(pin.version)"
            : fixed == 1
                ? String(format: String(localized: "machineSetup.secure.oneFolder",
                                        defaultValue: "hc %@, 1 folder made private"), pin.version)
                : String(format: String(localized: "machineSetup.secure.folders",
                                        defaultValue: "hc %1$@, %2$lld folders made private"), pin.version, fixed)))

        // 2c. Update: drop the old link, so hc can't dial the old core back
        // up, then stop that core through the checked stop: it runs `server
        // stop` only for a core identified from the kernel as the old link's
        // own pinned hc. A foreign or unknown core is left running.
        if request.update, let oldVia {
            let removed = hc(["machine", "rm", name, "--json"], timeout: 20)
            guard removed.status == 0 else { return fail(.secure, .removeFailed(name, reason(removed))) }
            unlinkedForUpdate = true
            let stopped = ssh(host, HCMachineSetup.stopCoreCommand(session: oldVia.session, socket: oldVia.socket, hc: remoteHC,
                                                                  sha256: expected, allow: priorServing, dir: stagingDir), timeout: 30)
            if stopped.status == 7 || stopped.status == 8 {
                record(.hcServingMismatch, "refused", code: stopped.status == 7 ? "hc_hash_mismatch" : "hc_serving_mismatch",
                       detail: "the old core was not stopped")
                return failLinked(.secure, .hcServingMismatch(host: host, pid: 0, found: "unknown"))
            }
        }

        // 3. The relay: the c11 CLI there, in relay mode for this session, with
        // this app's Claude wrapper, agent note, Info.plist and c11 skill
        // around it, sent as one archive.
        progress(HCMachineSetupProgress(step: .relay, state: .running, detail: nil))
        let stagedRelay = stage(resources.relayScript, as: "c11-atlas-relay.sh")
        guard stagedRelay.status == 0 else { return failLinked(.relay, .relayFailed(host, reason(stagedRelay))) }
        let kitRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-kit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: kitRoot) }
        do { _ = try HCMachineSetup.layOutKit(contents: resources.kitContents, cli: cliFile, at: kitRoot) } catch {
            return failLinked(.relay, .relayFailed(host, error.localizedDescription))
        }
        let archive = kitRoot.appendingPathComponent(HCMachineSetup.kitArchiveName)
        let packed = runner.run(["/usr/bin/tar", "--format", "ustar", "-cf", archive.path, "-C", kitRoot.path, "kit"], stdin: nil,
                                environment: ["PATH": "/usr/bin:/bin", "COPYFILE_DISABLE": "1"], timeout: 60)
        guard packed.status == 0 else { return failLinked(.relay, .relayFailed(host, reason(packed))) }
        let stagedKit = stage(archive, as: HCMachineSetup.kitArchiveName)
        guard stagedKit.status == 0 else { return failLinked(.relay, .relayFailed(host, reason(stagedKit))) }
        let relay = ssh(host, HCMachineSetup.relayCommand(session: session, dir: stagingDir), timeout: HCMachineSetup.transferTimeout)
        guard relay.status == 0 else { return failLinked(.relay, .relayFailed(host, reason(relay))) }
        progress(HCMachineSetupProgress(step: .relay, state: .done, detail: nil))

        // 4. Link, with a via that checks this pin at every dial.
        progress(HCMachineSetupProgress(step: .link, state: .running, detail: name))
        let via = HCMachineSetup.viaURL(home: localHome, name: name)
        let rendered = runner.run(
            ["/bin/sh", resources.linkScript.path, "render", "--mode", "ssh", "--session", session,
             "--socket", remoteRun, "--hc", remoteHC, "--sha", expected, "--machine", name, "--target", host, "--home", probe.home,
             "--user", probe.user, "--out", via.path] + (platform == .linuxX86_64 ? ["--platform", "linux"] : []),
            stdin: nil, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": localHome.path], timeout: 30)
        guard rendered.status == 0 else { return failLinked(.link, .addFailed(name, reason(rendered))) }
        let added = hc(["machine", "add", "--name", name, "--session", session, "--via", via.path, "--json"], timeout: 90)
        guard added.status == 0 else {
            // No link uses this via: leave nothing behind.
            try? FileManager.default.removeItem(at: via)
            return failLinked(.link, .addFailed(name, reason(added)))
        }
        progress(HCMachineSetupProgress(step: .link, state: .done, detail: name))

        // 5. Wait for the link to report connected at this build's version.
        progress(HCMachineSetupProgress(step: .verify, state: .running, detail: nil))
        var lastState = "unknown"
        for attempt in 0..<max(1, verifyAttempts) {
            if let machine = listMachines()?.first(where: { $0.name == name }) {
                lastState = machine.version.map { "\(machine.state), hc \($0)" } ?? machine.state
                if machine.state == "connected", machine.version == pin.version {
                    progress(HCMachineSetupProgress(step: .verify, state: .done, detail: machine.version))
                    return .success(HCMachineSetupResult(name: name, host: host, viaScript: via.path,
                                                         installedHC: installed, version: machine.version ?? pin.version))
                }
            }
            if attempt + 1 < verifyAttempts { sleep(verifyInterval) }
        }
        return fail(.verify, .notConnected(name, lastState))
    }
}

/// The real runner: `Process`, an exact environment, stdin from a file, a hard timeout.
struct HCMachineSetupProcessRunner: HCMachineSetupRunner {
    func run(_ argv: [String], stdin: URL?, environment: [String: String], timeout: TimeInterval) -> HCMachineSetupOutput {
        guard let first = argv.first else { return HCMachineSetupOutput(status: -1, stdout: "", stderr: "empty command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input: FileHandle?
        if let stdin {
            guard let handle = try? FileHandle(forReadingFrom: stdin) else {
                return HCMachineSetupOutput(status: -1, stdout: "", stderr: "could not read \(stdin.lastPathComponent)")
            }
            input = handle
            process.standardInput = handle
        } else {
            input = nil
            process.standardInput = FileHandle.nullDevice
        }
        defer { try? input?.close() }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return HCMachineSetupOutput(status: -1, stdout: "", stderr: "could not run \(first): \(error.localizedDescription)")
        }
        let box = Box()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.set(data, isOut: isOut)
                group.leave()
            }
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            _ = group.wait(timeout: .now() + 5)
            return HCMachineSetupOutput(status: -1, stdout: box.text(isOut: true),
                                        stderr: "timed out after \(Int(timeout)) s")
        }
        _ = group.wait(timeout: .now() + 5)
        return HCMachineSetupOutput(status: process.terminationStatus, stdout: box.text(isOut: true), stderr: box.text(isOut: false))
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func set(_ data: Data, isOut: Bool) { lock.lock(); if isOut { out = data } else { err = data }; lock.unlock() }
        func text(isOut: Bool) -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: isOut ? out : err, as: UTF8.self)
        }
    }
}

/// C11H-332: a link c11 keeps must check an hc pin every time it starts hc
/// there, and (C11H-361) its ssh must forward nothing. A stored link made by
/// an older c11 (its via has no `sha256=` pin, or forwards) is migrated
/// before c11 uses it: `c11-atlas-link.sh migrate` re-renders the
/// via exactly as Update would, from its own target, session, socket, hc,
/// home and user, with the switches that turn forwarding off and a pin (its
/// own when it has one, this build's when it has none), keeping a pairing
/// manifest that owns it consistent. That grants no new trust (the operator consented when the
/// link was made). Where migration can't happen (a read-only shard, a via
/// outside c11's own folder, a write or render failure) the link is
/// `unusable`: c11 opens nothing on that machine and relays nothing from it,
/// records why, retries at the next review, and says plainly that hc may
/// still redial it until the operator updates or removes it.
enum HCStoredLinks {
    enum Verdict: Equatable, Sendable {
        case pinned
        case migrated
        /// `read_only_shard`, `via_outside`, `migrate_failed` or `pairing_unowned`.
        case unusable(String)

        var isUsable: Bool { if case .unusable = self { return false } else { return true } }
    }

    /// The via's text when `path` is one of c11's own via files (a regular
    /// file this user owns, read without following a symlink), else nil.
    static func ownedVia(_ path: String?, home: URL, adopted: Bool = HCLaunchPolicy.processNamespace != nil) -> String? {
        guard let path, !path.contains(".."),
              path.hasPrefix(home.path + "/.local/share/c11/")
                || (adopted && path.hasPrefix(home.path + "/.local/share/c11h/")) else { return nil }  // c11-2.0:legacy
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              let data = try? handle.read(upToCount: 512 * 1024) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isPinned(_ script: String) -> Bool {
        script.range(of: #"sha256=[0-9a-f]{64} "#, options: .regularExpression) != nil
    }

    /// C11H-361: the via's ssh turns every forwarding off, before `--`.
    static func forwardsNothing(_ script: String) -> Bool {
        script.contains(" " + HCMachineSetup.sshForwardingOff.joined(separator: " ") + " -- ")
    }

    /// Current: checks a pin and forwards nothing.
    static func isCurrent(_ script: String) -> Bool { isPinned(script) && forwardsNothing(script) }

    /// One stored link: pinned, migrated now, or unusable with a reason.
    /// A migration is audited once, as `link migrated`.
    static func review(machine: String, viaPath: String?, home: URL, pinSHA256: String, mayWrite: Bool,
                       linkScript: URL?, runner: any HCMachineSetupRunner = HCMachineSetupProcessRunner(),
                       adopted: Bool = HCLaunchPolicy.processNamespace != nil,
                       audit: C11AuditLog = .shared) -> Verdict {
        guard let path = viaPath, let script = ownedVia(path, home: home, adopted: adopted) else { return .unusable("via_outside") }
        if isCurrent(script) { return .pinned }
        // C11H-361: a pinned via that still forwards keeps its own pin (the
        // link script reads it from the via); only a pinless one takes this build's.
        let forwardingOnly = isPinned(script)
        guard mayWrite else { return .unusable("read_only_shard") }
        guard let linkScript, FileManager.default.isReadableFile(atPath: linkScript.path) else { return .unusable("migrate_failed") }
        let name = HCCoreUtility.isLinkMachineName(machine) ? machine : ""
        let output = runner.run(["/bin/sh", linkScript.path, "migrate", "--via", path, "--sha", pinSHA256.lowercased()]
                                    + (name.isEmpty ? [] : ["--machine", name]),
                                stdin: nil, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 20)
        switch output.status {
        case 0:
            guard let after = ownedVia(path, home: home, adopted: adopted), isCurrent(after) else { return .unusable("migrate_failed") }
            if output.stdout.hasPrefix("migrated") {
                // Written before returning, not queued: a quit right after a
                // migration must not lose its only record.
                _ = audit.append(C11AuditRecord(kind: .link, via: "app", outcome: "migrated", machine: name.isEmpty ? "invalid" : name,
                                                path: path, code: forwardingOnly ? "forwarding_off" : "pinned_now",
                                                detail: forwardingOnly
                                                    ? "an older c11's link turns agent, X11 and port forwarding off from its next dial"
                                                    : "an older c11's link now checks this build's hc at every start and forwards nothing"))
                return .migrated
            }
            return .pinned
        case 3: return .unusable("via_outside")
        case 5: return .unusable("pairing_unowned")
        default: return .unusable("migrate_failed")
        }
    }
}
