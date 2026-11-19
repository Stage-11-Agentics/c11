import CryptoKit
import Darwin
import Foundation
import OSLog

/// All file hashing and kernel inspection runs on this actor, never a native
/// callback or main. A changed file identity invalidates the cached digest.
actor HCBuildVerifier {
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.identity")
    private var hashes: [String: (HCFileIdentity, String)] = [:]
    private let executablePath: @Sendable (Int32) -> String?

    /// `executablePath` is the kernel's answer (`proc_pidpath`); tests give a
    /// path so they never have to run ad hoc code to stand in for a core.
    init(executablePath: @escaping @Sendable (Int32) -> String? = { HCBuildVerifier.kernelExecutablePath($0) }) {
        self.executablePath = executablePath
    }

    static func kernelExecutablePath(_ pid: Int32) -> String? {
        #if !os(macOS)
        return LinuxProc.executablePath(pid)
        #else
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
        #endif
    }

    func validateOwnedState(_ configuration: HCLaunchConfiguration, coreID: String) throws {
        try Self.verifyStateEndpoint(configuration, expectedCoreID: coreID)
    }

    func verifyPin(_ configuration: HCLaunchConfiguration) throws -> HCFileIdentity {
        let (identity, hash) = try fingerprint(configuration.executableURL)
        guard hash == configuration.pin.executableSHA256 else { throw HCUnavailableReason.pinMismatch }
        return identity
    }

    func verify(_ peer: HCPeerEvidence, configuration: HCLaunchConfiguration) throws -> HCVerifiedPeer {
        guard peer.uid == getuid(), peer.pid > 0, peer.pid == peer.statusPID else { throw HCUnavailableReason.foreignSession }
        guard peer.protocolGeneration == configuration.pin.protocolGeneration,
              peer.features.contains("framed"),
              Set(["server.restart", "terminal.run", "terminal.attach", "events.subscribe"]).isSubset(of: peer.methods) else {
            throw HCUnavailableReason.incompatibleProtocol
        }
        try Self.verifyStateEndpoint(configuration, expectedCoreID: peer.coreID)
        var socketInfo = stat()
        guard lstat(configuration.socketURL.path, &socketInfo) == 0,
              socketInfo.st_uid == getuid(), socketInfo.st_mode & S_IFMT == S_IFSOCK else {
            throw HCUnavailableReason.foreignSession
        }
        let before = try Self.processIdentity(peer.pid)
        guard let path = executablePath(peer.pid) else { throw HCUnavailableReason.connectionLost }
        let executable = URL(fileURLWithPath: path)
        _ = try verifyPin(configuration)
        let (file, hash) = try fingerprint(executable)
        guard try Self.processIdentity(peer.pid) == before else { throw HCUnavailableReason.connectionLost }
        // L2: the serving binary is the launch binary, or one the tuple accepts
        // as already serving (C11H-66's transition from M1's external pin).
        let accepted = configuration.servingBinaries.first { serving in
            executable.standardizedFileURL == serving.executableURL.standardizedFileURL
                && hash == serving.pin.executableSHA256 && peer.version == serving.pin.version
        }
        let pinned = accepted != nil
        if !pinned {
            Self.logger.error("hc_serving_build_refused expected_version=\(configuration.pin.version, privacy: .public) expected_sha256=\(configuration.pin.executableSHA256, privacy: .public) served_version=\(peer.version, privacy: .public) served_sha256=\(hash, privacy: .public) pid=\(peer.pid) start_us=\(before.startTimeMicroseconds)")
        }
        let observedPin = accepted?.pin ?? HCPin(version: peer.version, archiveSHA256: "",
            executableSHA256: hash, protocolGeneration: peer.protocolGeneration)
        return HCVerifiedPeer(identity: HCBuildIdentity(pin: observedPin, executablePath: executable.path,
            fileIdentity: file, process: before, coreID: peer.coreID, protocolGeneration: peer.protocolGeneration),
            isPinnedBuild: pinned)
    }

    static func processIdentity(_ pid: Int32) throws -> HCProcessIdentity {
        #if !os(macOS)
        guard pid > 0, let stat = LinuxProc.stat(pid), stat.state != "Z", LinuxProc.uid(pid) == getuid() else {
            throw HCUnavailableReason.connectionLost
        }
        return HCProcessIdentity(pid: pid, startTimeMicroseconds: LinuxProc.epochMicroseconds(stat))
        #else
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { throw HCUnavailableReason.connectionLost }
        return HCProcessIdentity(pid: pid,
            startTimeMicroseconds: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
        #endif
    }

    /// Exact incarnation only. A recycled pid means the original process exited.
    static func isRunning(_ process: HCProcessIdentity) -> Bool {
        (try? processIdentity(process.pid)) == process
    }

    static func verifyStateEndpoint(_ configuration: HCLaunchConfiguration, expectedCoreID: String? = nil) throws {
        let lock = configuration.stateDirectory.appendingPathComponent("core.lock")
        do {
            let data = try PrivateFileWriter.readPrivateFile(at: lock, maxBytes: 4096)
            guard data == Data(configuration.socketURL.path.utf8) else { throw HCUnavailableReason.foreignSession }
        } catch let error as POSIXError where error.code == .ENOENT {
            guard expectedCoreID == nil else { throw HCUnavailableReason.foreignSession }
        }
        if let expectedCoreID {
            struct Identity: Decodable { let id: String }
            let data = try PrivateFileWriter.readPrivateFile(at: configuration.stateDirectory.appendingPathComponent("core.json"), maxBytes: 65536)
            guard !expectedCoreID.isEmpty, try JSONDecoder().decode(Identity.self, from: data).id == expectedCoreID else {
                throw HCUnavailableReason.foreignSession
            }
        }
    }

    private func fingerprint(_ url: URL) throws -> (HCFileIdentity, String) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw HCUnavailableReason.coreUnreachable }
            throw HCUnavailableReason.pinMismatch
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_uid == getuid() || info.st_uid == 0,
              info.st_size >= 0 else { throw HCUnavailableReason.pinMismatch }
        let identity = Self.fileIdentity(info)
        if let cached = hashes[url.path], cached.0 == identity { return cached }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw HCUnavailableReason.pinMismatch }
            if count == 0 { break }
            digest.update(data: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Self.fileIdentity(after) == identity else { throw HCUnavailableReason.pinMismatch }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        hashes[url.path] = (identity, hash)
        return (identity, hash)
    }

    private static func fileIdentity(_ info: stat) -> HCFileIdentity {
        HCFileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), size: UInt64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}
