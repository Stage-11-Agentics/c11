// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

extension String {
    func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last == " " {
            result.removeLast()
        }
        return result
    }

    func leftPadded(to length: Int, with pad: Character = " ") -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}

extension FileHandle {
    /// Broken-pipe-safe write.
    ///
    /// `FileHandle.write(_:)` is `-[NSConcreteFileHandle writeData:]`, which *raises*
    /// `NSFileHandleOperationException` when the far end of the pipe is gone. An ObjC
    /// exception cannot unwind through Swift frames — there is no landing pad, so the
    /// throw goes `__cxa_throw` -> `failed_throw` -> `std::terminate` -> `abort`, and
    /// `NSSetUncaughtExceptionHandler` never gets to convert it into a clean exit.
    /// Observed 2026-08-12: a CLI process SIGABRTed at Resources/bin/c11 when its
    /// stderr pipe closed as the app shut down (crash report c11-2026-08-12-185921).
    ///
    /// Writing through `write(2)` keeps the failure a return value. SIGPIPE is already
    /// `SIG_IGN` in `main()`, so a closed reader surfaces as `EPIPE` and is dropped —
    /// a CLI whose reader has gone away must exit quietly, not abort.
    func c11SafeWrite(_ data: Data) {
        let fd = fileDescriptor
        data.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, ptr, remaining)
                if written > 0 {
                    ptr = ptr.advanced(by: written)
                    remaining -= written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return // EPIPE / EBADF / anything else: drop it, never raise
                }
            }
        }
    }
}
