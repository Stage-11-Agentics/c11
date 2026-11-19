import Foundation
import Darwin
import os

/// Remote-machine link policy for ticket 11. Pin identity is `HCPin.current` only.
/// This type does not start a core, dial ssh, or write a binary.
enum HCAtlasLinkMode: String, Equatable, Sendable {
    case ssh
    case bridge
}

enum HCAtlasPinInstall: Equatable, Sendable {
    case leave
    case write
    case stopBecauseServing
}

struct HCAtlasFileLimit: Equatable, Sendable {
    let kernelCap: UInt64
    let beforeSoft: UInt64
    let beforeHard: UInt64
    let afterSoft: UInt64
    let afterHard: UInt64
}

struct HCAtlasLink: Equatable, Sendable {
    static let releaseSession = "c11"
    static let remotePath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let maximumSocketPathBytes = 103
    static let shellFileDescriptorToken = "hc_fd_limit"

    let mode: HCAtlasLinkMode
    let session: String
    let sshTarget: String
    let configuration: HCLaunchConfiguration
    /// Absolute pin, then `connect --session <S>`. Never hc's default remote line.
    let remoteArgv: [String]
    /// Guest bridge body. Nil in ssh mode. Does not exec a PATH `herdr-core`.
    let bridgeCommand: String?

    static func sessionName(debugTag: String?) -> String? {
        guard let tag = debugTag, !tag.isEmpty else { return releaseSession }
        guard token(tag) else { return nil }
        let session = "\(releaseSession)-\(tag)"
        guard session != "default", token(session) else { return nil }
        return session
    }

    static func availability(machineState: String?, localCore: Bool = false) -> HCMachineAvailability {
        if localCore { return .local }
        switch machineState {
        case "connected":
            return .connected
        case nil, "":
            return .unknown
        case "connecting", "unreachable", "needs_login", "needs_update":
            return .disconnected
        default:
            return .disconnected
        }
    }

    static func tellsOrchestrator(machineState: String?) -> Bool {
        machineState == "needs_login"
    }

    /// Link loss stays unresolved as connectionLost and keeps the given identity.
    /// Connected and local decisions use the caller's snapshot and stored intent.
    /// A missing record is not turned into a ready empty inventory.
    static func resolve(
        identity: HCPanelIdentity,
        availability: HCMachineAvailability,
        snapshot: HCInventorySnapshot,
        intent: HCStoredCreation? = nil,
        placement: HCPanelPlacement = .local
    ) -> HCLifecycle {
        switch availability {
        case .disconnected, .unknown:
            return .unresolved(identity, .connectionLost)
        case .local, .connected:
            if let key = identity.key,
               snapshot.records.values.contains(where: { record in
                   record.key != key
                       && record.labels["c11.panel"]?.lowercased() == identity.panelID.uuidString.lowercased()
               }) {
                return .unresolved(identity, .ambiguousIdentity)
            }
            return HCLifecycleResolver.resolve(
                identity,
                snapshot: snapshot,
                intent: intent,
                placement: placement
            )
        }
    }

    /// Soft NOFILE decision. Nil means `HCUnavailableReason.fileDescriptorLimit`
    /// and the shell token `hc_fd_limit`. Hard is never changed. A soft limit
    /// already above the kernel cap is left in place.
    static func fileLimit(
        beforeSoft: UInt64,
        beforeHard: UInt64,
        hardInfinite: Bool,
        softInfinite: Bool,
        kernelCap: UInt64
    ) -> HCAtlasFileLimit? {
        guard kernelCap >= 1 else { return nil }
        let finiteHard = hardInfinite ? kernelCap : beforeHard
        let target = min(finiteHard, kernelCap)
        let afterSoft: UInt64
        if softInfinite || beforeSoft > kernelCap {
            afterSoft = beforeSoft
        } else {
            afterSoft = target
        }
        let afterHard = beforeHard
        let effective: UInt64
        if softInfinite || afterSoft > kernelCap {
            effective = kernelCap
        } else {
            effective = afterSoft
        }
        guard effective >= HCLimits.minimumFileDescriptors else { return nil }
        return HCAtlasFileLimit(
            kernelCap: kernelCap,
            beforeSoft: beforeSoft,
            beforeHard: beforeHard,
            afterSoft: afterSoft,
            afterHard: afterHard
        )
    }

    /// Match reads `HCPin.current.executableSHA256`. A mismatch under our
    /// serving session does not write and does not imply a kill.
    static func pinInstall(remoteExecutableSHA256: String?, ourSessionServing: Bool) -> HCAtlasPinInstall {
        if let remote = remoteExecutableSHA256,
           remote.caseInsensitiveCompare(HCPin.current.executableSHA256) == .orderedSame {
            return .leave
        }
        if ourSessionServing { return .stopBecauseServing }
        return .write
    }

    /// `sshTarget` is the linked machine's name, as the pairing file
    /// (`HCAtlasPairing.machine`) names it.
    static func make(
        mode: HCAtlasLinkMode,
        sshTarget: String,
        remoteHome: URL,
        localHome: URL,
        user: String,
        debugTag: String?,
        bridgeSocket: String? = nil
    ) -> Result<HCAtlasLink, HCUnavailableReason> {
        guard let session = sessionName(debugTag: debugTag), session != "default" else {
            return .failure(.invalidLaunchTuple)
        }
        guard token(user), token(sshTarget), absolutePath(remoteHome), absolutePath(localHome) else {
            return .failure(.invalidLaunchTuple)
        }
        let executable = pinExecutable(home: remoteHome)
        let socket = socketURL(home: remoteHome, session: session)
        let holder = holderURL(home: remoteHome, session: session)
        guard !isLocalBinHerdr(executable), !isLocalBinHerdr(socket) else {
            return .failure(.invalidLaunchTuple)
        }
        guard socket.path.utf8.count <= maximumSocketPathBytes,
              holder.path.utf8.count <= maximumSocketPathBytes else {
            return .failure(.invalidLaunchTuple)
        }
        let environment = remoteEnvironment(
            home: remoteHome.path,
            user: user,
            session: session,
            socket: socket.path
        )
        guard sanitized(environment, session: session, socket: socket.path) else {
            return .failure(.invalidLaunchTuple)
        }
        let bridgeCommand: String?
        switch mode {
        case .ssh:
            bridgeCommand = nil
        case .bridge:
            guard let bridgeSocket, absoluteSocket(bridgeSocket) else {
                return .failure(.invalidLaunchTuple)
            }
            bridgeCommand = "exec /usr/bin/nc -U \(bridgeSocket)"
        }
        let configuration = HCLaunchConfiguration(
            executableURL: executable,
            session: session,
            socketURL: socket,
            stateDirectory: stateDirectory(home: remoteHome, session: session),
            intentDirectory: intentDirectory(home: localHome, session: session),
            environment: environment,
            pin: HCPin.current
        )
        let link = HCAtlasLink(
            mode: mode,
            session: session,
            sshTarget: sshTarget,
            configuration: configuration,
            remoteArgv: [executable.path, "connect", "--session", session],
            bridgeCommand: bridgeCommand
        )
        return .success(link)
    }

    static func pinExecutable(home: URL, pin: HCPin = .current) -> URL {
        home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("c11", isDirectory: true)
            .appendingPathComponent("hc", isDirectory: true)
            .appendingPathComponent("\(pin.version)-\(pin.executableSHA256.prefix(12))", isDirectory: true)
            .appendingPathComponent("herdr-core")
    }

    private static func socketURL(home: URL, session: String) -> URL {
        runDirectory(home: home).appendingPathComponent("\(session).sock")
    }

    private static func holderURL(home: URL, session: String) -> URL {
        runDirectory(home: home).appendingPathComponent("\(session).holder.ffffffff.sock")
    }

    private static func runDirectory(home: URL) -> URL {
        home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("c11", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
    }

    private static func stateDirectory(home: URL, session: String) -> URL {
        home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("herdr-core", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
    }

    private static func intentDirectory(home: URL, session: String) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("c11", isDirectory: true)
            .appendingPathComponent("HC", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
    }

    private static func remoteEnvironment(home: String, user: String, session: String, socket: String) -> [String: String] {
        [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
            "PATH": remotePath,
            "HC_SESSION": session,
            "HC_SOCKET": socket,
            "HC_SPAWN_MS": String(HCLimits.spawnMilliseconds),
            "XDG_CONFIG_HOME": "\(home)/.local/share/c11/config",
        ]
    }

    static func sanitized(_ environment: [String: String], session: String, socket: String) -> Bool {
        let allowed = Set(["HOME", "USER", "LOGNAME", "SHELL", "LANG", "PATH", "HC_SESSION", "HC_SOCKET", "HC_SPAWN_MS", "XDG_CONFIG_HOME"])
        guard Set(environment.keys) == allowed else { return false }
        guard environment["PATH"] == remotePath else { return false }
        guard environment["HC_SESSION"] == session, environment["HC_SOCKET"] == socket else { return false }
        guard environment["HC_SPAWN_MS"] == String(HCLimits.spawnMilliseconds) else { return false }
        guard environment["SHELL"] == "/bin/zsh" else { return false }
        guard let home = environment["HOME"], home.hasPrefix("/") else { return false }
        return environment["XDG_CONFIG_HOME"] == "\(home)/.local/share/c11/config"
    }

    private static func isLocalBinHerdr(_ url: URL) -> Bool {
        url.path.contains("/.local/bin/herdr-core") || url.path.hasSuffix("/.local/bin/herdr-core")
    }

    private static func token(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._@-]*$"#, options: .regularExpression) != nil
    }

    private static func absolutePath(_ url: URL) -> Bool {
        let path = url.path
        return path.hasPrefix("/") && !path.contains("..")
    }

    private static func absoluteSocket(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("..") && !path.contains("\n") && !path.contains("'")
    }
}
/// C11H-78 (SH4, option B): a local shard `c11-sN` links to the session of
/// the same name on another machine, one to one. The app adds that machine to
/// a shard's core only when the operator's pairing file names the shard; with
/// no file it never adds a machine. `scripts/c11-atlas-link.sh pair` writes
/// the file and renders one via script per shard, so the app writes no
/// executable and the remote session can only be the shard's own.
///
/// `~/.local/share/c11/atlas-pair.json`:
///     {"pairing": 1, "machine": "studio", "acknowledged": 1,
///      "vias": {"c11-s1": "<home>/.local/share/c11/atlas-via-c11-s1.sh", ...}}
struct HCAtlasPairing: Hashable, Sendable {
    static let version = 1
    let machine: String
    /// Shard session -> its via script.
    let vias: [String: String]
    /// C11H-365: `pair` writes `"acknowledged": 1` only after the operator
    /// answered its question on a terminal, or passed `--yes` outside a c11
    /// terminal. The registrar adds no machine for a manifest without it; a
    /// machine already in a shard's list stays paired.
    let acknowledged: Bool

    static func fileURL(home: URL) -> URL {
        directory(home: home).appendingPathComponent("atlas-pair.json")
    }

    /// The only path a shard's via may have: its name carries the session.
    static func viaPath(home: URL, session: String) -> String {
        directory(home: home).appendingPathComponent("atlas-via-\(session).sh").path
    }

    /// A shard session: `c11-s<N>` or `c11-<tag>-s<N>`, N from 1 to 8.
    /// The legacy `c11` session (shard 0) is never paired by this file.
    static func isShardSession(_ session: String) -> Bool {
        session.range(of: #"^c11(-[A-Za-z0-9][A-Za-z0-9._-]*)?-s[1-8]$"#, options: .regularExpression) != nil
    }

    /// Nil for anything that is not exactly a pairing file of this version.
    /// Entries that break a rule make the whole file invalid rather than
    /// pairing some shards and silently dropping others.
    init?(data: Data, home: URL) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["pairing"] as? NSNumber)?.intValue == Self.version,
              let machine = object["machine"] as? String, HCCoreUtility.isLinkMachineName(machine),
              let raw = object["vias"] as? [String: Any], !raw.isEmpty else { return nil }
        var vias: [String: String] = [:]
        for (session, value) in raw {
            guard Self.isShardSession(session), let path = value as? String,
                  path == Self.viaPath(home: home, session: session) else { return nil }
            vias[session] = path
        }
        self.machine = machine
        self.vias = vias
        self.acknowledged = (object["acknowledged"] as? NSNumber)?.intValue == 1
    }

    struct Registration: Hashable, Sendable {
        let machine: String
        let via: String
        let session: String

        /// hc 0.1.16 `machine.add`: the remote session is the shard's own.
        var params: [String: HCJSONValue] {
            ["name": .string(machine), "via": .string(via), "session": .string(session)]
        }
    }

    /// Nil when the file does not pair this shard.
    func registration(for session: String) -> Registration? {
        guard let via = vias[session] else { return nil }
        return Registration(machine: machine, via: via, session: session)
    }

    enum Decision: Equatable, Sendable {
        case add
        case paired
        /// The machine is there, linked to another session. Left alone: the
        /// operator's registration wins and the log says so.
        case mismatch(String?)
    }

    static func decide(_ registration: Registration, machineList: HCJSONValue) -> Decision? {
        guard let list = machineList["machines"].array else { return nil }
        guard let entry = list.first(where: { $0["name"].string == registration.machine }) else { return .add }
        let session = entry["session"].string
        return session == registration.session ? .paired : .mismatch(session)
    }

    /// The via must be a regular file this user owns, not writable by group
    /// or others, and executable: the core runs it.
    /// C11H-332: with `pinSHA256`, the via must also check that pin at every
    /// dial (`sha256=<pin> ` before the hc it runs); one rendered without it
    /// is never added.
    static func viaIsSafe(_ path: String, pinSHA256: String? = nil) -> Bool {
        guard isSafeFile(path) else { return false }
        guard let pinSHA256 else { return true }
        return text(path).map { checks($0, pin: pinSHA256) } ?? false
    }

    /// C11H-397: this build's hc pins, one per platform a paired via may dial.
    struct Pins: Equatable, Sendable {
        let mac: String?
        let linux: String?
    }

    enum ViaCheck: Equatable, Sendable {
        case safe
        /// Not a private executable regular file of this user.
        case unsafeFile
        /// Checks no pin of this build (an older via, or another build's).
        case noPin
        /// Checks this build's pin for the other platform, so every dial
        /// there would refuse the hc it finds (C11H-397).
        case otherPlatformPin
    }

    /// C11H-397: a paired via is added only when it checks, at every dial, this
    /// build's pin for the platform it was rendered for, as Add Machine renders
    /// it: a Linux via (`render --platform linux`, which bakes bash) the Linux
    /// hc's pin, any other via this Mac's.
    static func checkVia(_ path: String, pins: Pins) -> ViaCheck {
        guard isSafeFile(path) else { return .unsafeFile }
        guard let text = text(path) else { return .unsafeFile }
        let linux = text.range(of: #"\bSHELL=/bin/bash\b"#, options: .regularExpression) != nil
        let (own, other) = linux ? (pins.linux, pins.mac) : (pins.mac, pins.linux)
        if let own, checks(text, pin: own) { return .safe }
        if let other, checks(text, pin: other) { return .otherPlatformPin }
        return .noPin
    }

    private static func isSafeFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
            && (info.st_mode & 0o022) == 0 && (info.st_mode & 0o100) != 0
    }

    private static func text(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func checks(_ text: String, pin: String) -> Bool { text.contains("sha256=\(pin.lowercased()) ") }

    private static func directory(home: URL) -> URL {
        home.appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("c11", isDirectory: true)
    }
}

/// Adds the paired machine to a shard's core when that core connects, and
/// retries while the far end cannot be reached (hc dials when it adds, so an
/// add fails while the linked machine is down). One loop per shard; a reconnect while one
/// runs does not start another. Never removes a machine.
actor HCAtlasPairingRegistrar {
    typealias Request = @Sendable (_ method: String, _ params: [String: HCJSONValue]) async throws -> HCJSONValue
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias Load = @Sendable () -> HCAtlasPairing?

    static let retryDelays: [TimeInterval] = [2, 5, 15, 30]

    enum Outcome: Equatable, Sendable {
        case unpaired, added, paired, inProgress, mismatch(String?), unsafeVia, unacknowledged, gaveUp
    }

    private let load: Load
    private let checkVia: @Sendable (String) -> HCAtlasPairing.ViaCheck
    private let sleep: Sleep
    private let maxAttempts: Int
    private let audit: C11AuditLog
    private var running: Set<String> = []
    private var attempts: [HCAtlasPairing.Registration: Task<Outcome, Never>] = [:]
    /// Unacknowledged manifests already audited: one record per manifest.
    private var auditedUnacknowledged: Set<HCAtlasPairing> = []

    init(load: @escaping Load,
         checkVia: @escaping @Sendable (String) -> HCAtlasPairing.ViaCheck = { HCAtlasPairing.viaIsSafe($0) ? .safe : .unsafeFile },
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         maxAttempts: Int = 20,
         audit: C11AuditLog = .shared) {
        self.load = load
        self.audit = audit
        self.checkVia = checkVia
        self.sleep = sleep
        self.maxAttempts = maxAttempts
    }

    /// The production registrar: reads the operator's file on every connect,
    /// so adding or editing it takes effect at the shard's next connect.
    /// C11H-397: `pins` are this build's, so a Linux machine's via checks the
    /// Linux hc's pin and a Mac's this Mac's.
    static func live(home: URL, pins: @escaping @Sendable () -> HCAtlasPairing.Pins) -> HCAtlasPairingRegistrar {
        HCAtlasPairingRegistrar(load: { pairing(home: home) },
                                checkVia: { HCAtlasPairing.checkVia($0, pins: pins()) })
    }

    /// The operator's pairing file, re-read only when its modification time
    /// changes: a terminal's creation asks this on the main thread.
    static func pairing(home: URL) -> HCAtlasPairing? { HCAtlasPairingCache.shared.pairing(home: home) }
}

final class HCAtlasPairingCache: @unchecked Sendable {
    static let shared = HCAtlasPairingCache()
    private let lock = NSLock()
    private var stamp: (path: String, modified: Date?)?
    private var value: HCAtlasPairing?

    func pairing(home: URL) -> HCAtlasPairing? {
        let url = HCAtlasPairing.fileURL(home: home)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        lock.lock(); defer { lock.unlock() }
        if let stamp, stamp.path == url.path, stamp.modified == modified { return value }
        value = modified == nil ? nil : (try? Data(contentsOf: url)).flatMap { HCAtlasPairing(data: $0, home: home) }
        stamp = (url.path, modified)
        return value
    }
}

extension HCAtlasPairingRegistrar {
    /// One short attempt shared by the connect hook and a cold remote create.
    /// Joining this task never waits through the background retry sleeps.
    private func attempt(_ registration: HCAtlasPairing.Registration, of pairing: HCAtlasPairing,
                         request: @escaping Request) async -> Outcome {
        if let task = attempts[registration] { return await task.value }
        let task = Task { await self.performAttempt(registration, of: pairing, request: request) }
        attempts[registration] = task
        let result = await task.value
        attempts.removeValue(forKey: registration)
        return result
    }

    /// C11H-365: a manifest the operator never acknowledged adds no machine.
    /// The pairing log names each refusal; the audit records one per manifest.
    private func refuseUnacknowledged(_ registration: HCAtlasPairing.Registration, of pairing: HCAtlasPairing) -> Outcome {
        HCAtlasPairingLog.event("session=\(registration.session) machine=\(registration.machine) unacknowledged reason=no_operator_answer")
        if auditedUnacknowledged.insert(pairing).inserted {
            audit.record(C11AuditRecord(kind: .link, via: "pairing", outcome: "refused",
                                        machine: registration.machine, session: registration.session,
                                        path: registration.via, code: "pairing_unacknowledged"))
        }
        return .unacknowledged
    }

    private func performAttempt(_ registration: HCAtlasPairing.Registration, of pairing: HCAtlasPairing,
                                request: @escaping Request) async -> Outcome {
        let check = checkVia(registration.via)
        guard check == .safe else {
            // C11H-332: a pairing link is audited like Add Machine, and the
            // pairing log says why (a via from before the pin needs `pair --sha`).
            // C11H-397: a via that checks the other platform's pin needs `pair`
            // again with the machine's own `--platform` and `--sha`.
            let (reason, code): (String, String)
            switch check {
            case .noPin: (reason, code) = ("no_pin", "via_unchecked")
            case .otherPlatformPin: (reason, code) = ("other_platform_pin", "via_other_platform")
            case .unsafeFile, .safe: (reason, code) = ("unsafe_file", "via_unsafe")
            }
            HCAtlasPairingLog.event("session=\(registration.session) machine=\(registration.machine) unsafe_via reason=\(reason)")
            audit.record(C11AuditRecord(kind: .link, via: "pairing", outcome: "refused",
                                        machine: registration.machine, session: registration.session,
                                        path: registration.via, code: code))
            return .unsafeVia
        }
        guard let list = try? await request("machine.list", [:]),
              let decision = HCAtlasPairing.decide(registration, machineList: list) else { return .gaveUp }
        switch decision {
        case .paired: return .paired
        case .mismatch(let other):
            HCAtlasPairingLog.event("session=\(registration.session) machine=\(registration.machine) left=other_session remote_session=\(other ?? "none")")
            return .mismatch(other)
        case .add:
            // Only adding needs the acknowledgement: a machine already listed stays `.paired`.
            guard pairing.acknowledged else { return refuseUnacknowledged(registration, of: pairing) }
            do {
                _ = try await request("machine.add", registration.params)
                HCAtlasPairingLog.event("session=\(registration.session) machine=\(registration.machine) added remote_session=\(registration.session)")
                audit.record(C11AuditRecord(kind: .link, via: "pairing", outcome: "ok",
                                                         machine: registration.machine, session: registration.session,
                                                         path: registration.via))
                return .added
            } catch {
                HCAtlasPairingLog.event("session=\(registration.session) machine=\(registration.machine) add_failed error=\(error)")
                audit.record(C11AuditRecord(kind: .link, via: "pairing", outcome: "failed",
                                                         machine: registration.machine, session: registration.session,
                                                         path: registration.via, code: "add_failed"))
                return .gaveUp
            }
        }
    }

    /// Prepare the one remote creation; never creates the terminal itself.
    /// No matching operator intent means no registration, including shard 0.
    func prepare(session: String, machine: String, request: @escaping Request) async throws -> Bool {
        guard HCAtlasPairing.isShardSession(session), let pairing = load(),
              let registration = pairing.registration(for: session), registration.machine == machine else { return false }
        switch await attempt(registration, of: pairing, request: request) {
        case .added, .paired: return true
        case .mismatch: throw HCUnavailableReason.foreignSession
        case .unsafeVia, .unacknowledged: throw HCUnavailableReason.invalidLaunchTuple
        default: throw HCUnavailableReason.connectionLost
        }
    }

    /// Background retry remains bounded; creation joins only the current attempt.
    @discardableResult
    func connected(session: String, request: @escaping Request) async -> Outcome {
        guard HCAtlasPairing.isShardSession(session), load()?.registration(for: session) != nil else { return .unpaired }
        guard !running.contains(session) else { return .inProgress }
        running.insert(session)
        defer { running.remove(session) }
        for number in 0..<maxAttempts {
            if number > 0 {
                let delay = Self.retryDelays[min(number - 1, Self.retryDelays.count - 1)]
                do { try await sleep(delay) } catch { return .gaveUp }
            }
            guard let pairing = load(), let registration = pairing.registration(for: session) else { return .unpaired }
            let outcome = await attempt(registration, of: pairing, request: request)
            if outcome != .gaveUp { return outcome }
        }
        HCAtlasPairingLog.event("session=\(session) gave_up attempts=\(maxAttempts)")
        return .gaveUp
    }
}

enum HCAtlasPairingLog {
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.pair")

    static func event(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        C11RelayLog.append("hc.pair " + line)
    }
}
