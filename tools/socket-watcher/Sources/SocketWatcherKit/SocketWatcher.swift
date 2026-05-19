// C11-105 socket-unlink diagnostic.
//
// SocketWatcher uses kqueue + EVFILT_VNODE to watch a file path for
// delete/rename/revoke events. When the file disappears, the watcher
// pivots to watching the parent directory for NOTE_WRITE events and
// re-arms the file watch as soon as the path reappears. Each event is
// emitted as a single JSON Lines record on the provided output stream.
//
// This is a diagnostic harness for the bug described in Lattice C11-105:
// the prod c11.app's socket file at
// ~/Library/Application Support/c11/c11.sock is being unlinked while
// the prod process is still alive and bound to that path in the kernel.
// The watcher's job is to name the unlinker so a follow-up fix ticket
// can target the responsible code path.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum SocketWatcherEventKind: String, Codable, Sendable {
    case delete
    case rename
    case revoke
    case rebound
}

public struct SocketWatcherEvent: Codable, Sendable {
    public let timestamp: String
    public let event: SocketWatcherEventKind
    public let path: String
    public let lsof: String
    public let ps: String

    public init(
        timestamp: String,
        event: SocketWatcherEventKind,
        path: String,
        lsof: String,
        ps: String
    ) {
        self.timestamp = timestamp
        self.event = event
        self.path = path
        self.lsof = lsof
        self.ps = ps
    }

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case event
        case path
        case lsof
        case ps
    }
}

public protocol SnapshotCapturing: Sendable {
    func captureLsof(path: String) -> String
    func capturePs() -> String
}

public struct ShellSnapshotCapturer: SnapshotCapturing {
    public init() {}

    public func captureLsof(path: String) -> String {
        // -U restricts to UNIX-domain sockets; the watcher's target paths
        // are always sockets when they're bound (which is the interesting
        // case). lsof returns success even when no rows match, so this
        // is safe to run even after the file is gone.
        runShell("/usr/sbin/lsof", arguments: ["-U"])
    }

    public func capturePs() -> String {
        // Filter to lines mentioning c11/cmux to keep the snapshot
        // compact. Operators correlate by PID against the lsof snapshot.
        let raw = runShell("/bin/ps", arguments: ["-axww", "-o", "pid,etime,command"])
        let filtered = raw.split(whereSeparator: \.isNewline).filter { line in
            let lower = line.lowercased()
            return lower.contains("c11") || lower.contains("cmux")
        }
        return filtered.joined(separator: "\n")
    }

    private func runShell(_ launchPath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "<failed to launch \(launchPath): \(error)>"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public protocol EventEmitting: Sendable {
    func emit(_ event: SocketWatcherEvent)
}

public final class JSONLinesEmitter: EventEmitting {
    private let writer: @Sendable (String) -> Void

    public init(writer: @escaping @Sendable (String) -> Void) {
        self.writer = writer
    }

    public func emit(_ event: SocketWatcherEvent) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        writer(line + "\n")
    }
}

public final class SocketWatcher {
    public let path: String
    private let snapshotter: SnapshotCapturing
    private let emitter: EventEmitting
    private let clock: @Sendable () -> Date
    private let pollInterval: TimeInterval
    private var stopFlag = false
    private let lock = NSLock()

    public init(
        path: String,
        snapshotter: SnapshotCapturing = ShellSnapshotCapturer(),
        emitter: EventEmitting,
        clock: @escaping @Sendable () -> Date = { Date() },
        pollInterval: TimeInterval = 0.05
    ) {
        self.path = path
        self.snapshotter = snapshotter
        self.emitter = emitter
        self.clock = clock
        self.pollInterval = pollInterval
    }

    public func stop() {
        lock.lock()
        stopFlag = true
        lock.unlock()
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopFlag
    }

    // The kqueue lifecycle is per-vnode: a watched file's kqueue
    // registration dies the instant the file is unlinked. The loop
    // below opens a fresh kqueue + file descriptor on each pass, waits
    // for one event, emits, closes everything, and (after a delete /
    // rename / revoke) polls the parent directory until the file
    // reappears, at which point it re-arms and emits a `rebound`
    // event.
    public func run(maxEvents: Int? = nil) throws {
        var emitted = 0
        while !shouldStop {
            if let max = maxEvents, emitted >= max { return }

            guard waitForFileToExist() else { return }

            let kq = kqueue()
            if kq < 0 {
                throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
            }
            defer { close(kq) }

            let fd = open(path, O_EVTONLY)
            if fd < 0 {
                // File raced away between exists-check and open. Loop.
                continue
            }

            var changeEvent = makeFileEvent(fd: Int32(fd))
            let registered = withUnsafePointer(to: &changeEvent) { ptr -> Int32 in
                kevent(kq, ptr, 1, nil, 0, nil)
            }
            if registered < 0 {
                close(fd)
                throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
            }

            var outEvent = kevent()
            var timeout = timespec(tv_sec: 0, tv_nsec: Int(pollInterval * 1_000_000_000))
            var observed = false
            while !shouldStop {
                let n = withUnsafePointer(to: &timeout) { tsPtr in
                    kevent(kq, nil, 0, &outEvent, 1, tsPtr)
                }
                if n > 0 {
                    observed = true
                    break
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                // n == 0 -> timed out; check stop flag and loop.
            }
            close(fd)

            guard observed else { continue }

            let kind = decodeEventKind(outEvent.fflags)
            emitEvent(kind)
            emitted += 1

            if let max = maxEvents, emitted >= max { return }

            // Wait for the path to reappear, then emit a "rebound"
            // event so the operator can see that the file came back
            // (e.g. via the Restart CLI Listener command).
            if waitForFileToExist() {
                if shouldStop { return }
                emitEvent(.rebound)
                emitted += 1
            }
        }
    }

    private func makeFileEvent(fd: Int32) -> kevent {
        let flags = UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)
        return kevent(
            ident: UInt(UInt32(bitPattern: fd)),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: flags,
            data: 0,
            udata: nil
        )
    }

    private func decodeEventKind(_ fflags: UInt32) -> SocketWatcherEventKind {
        if fflags & UInt32(NOTE_DELETE) != 0 { return .delete }
        if fflags & UInt32(NOTE_RENAME) != 0 { return .rename }
        if fflags & UInt32(NOTE_REVOKE) != 0 { return .revoke }
        return .delete
    }

    private func emitEvent(_ kind: SocketWatcherEventKind) {
        let event = SocketWatcherEvent(
            timestamp: Self.isoFormatter.string(from: clock()),
            event: kind,
            path: path,
            lsof: snapshotter.captureLsof(path: path),
            ps: snapshotter.capturePs()
        )
        emitter.emit(event)
    }

    private func waitForFileToExist() -> Bool {
        while !shouldStop {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            usleep(useconds_t(pollInterval * 1_000_000))
        }
        return false
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
