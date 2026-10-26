import Darwin
import Foundation

enum PrivateFileWriter {
    enum ReadError: LocalizedError, Equatable {
        case invalidSizeLimit
        case unsafeFile
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidSizeLimit:
                return String(localized: "browser.state.file.invalidSizeLimit", defaultValue: "State file size limit must be nonnegative")
            case .unsafeFile:
                return String(localized: "browser.state.file.unsafe", defaultValue: "State file must be a regular file owned by the current user and not writable by group or others")
            case .tooLarge:
                return String(localized: "browser.state.file.tooLarge", defaultValue: "State file exceeds the maximum allowed size")
            }
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw posixError() }

        var descriptorIsOpen = true
        var temporaryFileExists = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            if temporaryFileExists { unlink(temporaryURL.path) }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }

        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw posixError() }
        guard rename(temporaryURL.path, url.path) == 0 else { throw posixError() }
        temporaryFileExists = false
    }

    static func readPrivateFile(at url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else { throw ReadError.invalidSizeLimit }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            throw ReadError.unsafeFile
        }
        guard info.st_size >= 0 else { throw ReadError.unsafeFile }
        guard info.st_size <= off_t(maxBytes) else { throw ReadError.tooLarge }

        var data = Data()
        if info.st_size > 0 {
            data.reserveCapacity(Int(info.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = maxBytes - data.count
            let bytesToRead = remaining == Int.max ? buffer.count : min(buffer.count, remaining + 1)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytesToRead)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            guard count > 0 else { return data }
            guard count <= remaining else { throw ReadError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
