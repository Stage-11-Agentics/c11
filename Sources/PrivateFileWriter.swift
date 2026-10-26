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
                return String(localized: "browser.state.file.unsafeWithACL", defaultValue: "State file must be a regular file (not a symlink) owned by the current user, not writable by group or others, and without allow ACLs")
            case .tooLarge:
                return String(localized: "browser.state.file.tooLarge", defaultValue: "State file exceeds the maximum allowed size")
            }
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".c11-state.\(UUID().uuidString).tmp")
        let descriptor = try openPrivateTemporaryFile(at: temporaryURL)

        var descriptorIsOpen = true
        var temporaryFileExists = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            if temporaryFileExists { unlink(temporaryURL.path) }
        }

        guard let emptyACL = acl_init(0) else { throw posixError() }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        if acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) != 0,
           !isACLUnsupported(errno) {
            throw posixError()
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

    static func openPrivateTemporaryFile(at url: URL) throws -> Int32 {
        guard let emptyACL = acl_init(0) else { throw posixError() }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }

        var flagset: acl_flagset_t?
        guard acl_get_flagset_np(UnsafeMutableRawPointer(emptyACL), &flagset) == 0,
              let flagset else {
            throw posixError()
        }
        guard acl_add_flag_np(flagset, ACL_FLAG_NO_INHERIT) == 0 else { throw posixError() }

        guard let fileSecurity = filesec_init() else { throw posixError() }
        defer { filesec_free(fileSecurity) }

        var aclValue: acl_t? = emptyACL
        guard filesec_set_property(fileSecurity, FILESEC_ACL, &aclValue) == 0 else { throw posixError() }
        var mode = mode_t(0o600)
        guard filesec_set_property(fileSecurity, FILESEC_MODE, &mode) == 0 else { throw posixError() }

        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = openx_np(url.path, flags, fileSecurity)
        guard descriptor < 0 else { return descriptor }
        if errno == EINVAL || isACLUnsupported(errno) {
            let fallbackDescriptor = open(url.path, flags, mode_t(0o600))
            guard fallbackDescriptor >= 0 else { throw posixError() }
            return fallbackDescriptor
        }
        throw posixError()
    }

    static func readPrivateFile(at url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else { throw ReadError.invalidSizeLimit }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ReadError.unsafeFile }
            throw posixError()
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            throw ReadError.unsafeFile
        }
        if try hasExtendedAllowACL(descriptor) { throw ReadError.unsafeFile }
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

    private static func isACLUnsupported(_ error: Int32) -> Bool {
        error == ENOTSUP || error == EOPNOTSUPP
    }

    private static func hasExtendedAllowACL(_ descriptor: Int32) throws -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || isACLUnsupported(errno) { return false }
            throw posixError()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var entry: acl_entry_t?
        var result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        if result < 0 {
            if errno == EINVAL { return false }
            throw posixError()
        }

        while result == 0 {
            guard let currentEntry = entry else { throw POSIXError(.EIO) }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(currentEntry, &tag) == 0 else { throw posixError() }
            if tag == ACL_EXTENDED_ALLOW { return true }

            result = acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &entry)
            if result < 0 {
                if errno == EINVAL { return false }
                throw posixError()
            }
        }
        return false
    }
}
