import Foundation
import Darwin

/// Best-effort offline delivery in c11's namespace. Files contain canonical drafts only.
struct JournalSpool {
    let layout: JournalStorageLayout
    var budgets = JournalBudgets()

    struct DrainCounts {
        var committed = 0
        var invalid = 0
        var expired = 0
        var conflicts = 0
        var partial = 0
        var remaining = false
    }

    @discardableResult
    func write(_ draft: JournalDraft) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 25_000_000
        do {
            try draft.validate()
            let data = try draft.canonicalData() + Data([10])
            try layout.prepare()
            let lock = Darwin.open(layout.spool.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { return false }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return false }
            defer { flock(lock, LOCK_UN) }
            let entries = try FileManager.default.contentsOfDirectory(atPath: layout.spool.path).filter { !$0.hasPrefix(".") }
            guard entries.count < budgets.spoolFiles else { return false }
            var bytes: Int64 = 0
            for entry in entries {
                var st = stat()
                if lstat(layout.spool.appendingPathComponent(entry).path, &st) == 0 { bytes += Int64(st.st_size) }
                if DispatchTime.now().uptimeNanoseconds > deadline { return false }
            }
            guard bytes + Int64(data.count) <= budgets.spoolBytes,
                  layout.physicalBytes() + Int64(data.count) + budgets.reserveBytes <= budgets.totalBytes,
                  DispatchTime.now().uptimeNanoseconds <= deadline else { return false }
            let stem = "\(getpid()).\(UUID().uuidString)"
            let pending = layout.spool.appendingPathComponent(stem + ".open")
            let ready = layout.spool.appendingPathComponent(stem + ".ready")
            let fd = Darwin.open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return false }
            let written = data.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
            let closed = close(fd)
            guard written == data.count, closed == 0 else { unlink(pending.path); return false }
            guard rename(pending.path, ready.path) == 0 else { unlink(pending.path); return false }
            return true
        } catch { return false }
    }

    /// Call on a utility queue. The caller yields between bounded batches; no transaction
    /// holds the spool lock, and a crash before unlink is recovered by event-ID dedupe.
    func drain(limit: Int = 1000, durationMs: UInt64 = 2000, now: Int64,
               append: (JournalDraft) throws -> Void) -> DrainCounts {
        var counts = DrainCounts()
        let deadline = DispatchTime.now().uptimeNanoseconds + durationMs * 1_000_000
        guard (try? JournalStorageLayout.privateDirectory(layout.spool)) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: layout.spool.path) else { return counts }
        for name in names.sorted() where !name.hasPrefix(".") {
            if counts.committed + counts.invalid + counts.expired + counts.conflicts >= limit || DispatchTime.now().uptimeNanoseconds >= deadline {
                counts.remaining = true
                break
            }
            autoreleasepool {
                let url = layout.spool.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG else { return }
                guard info.st_size <= budgets.spoolFileBytes else { counts.invalid += 1; unlink(url.path); return }
                let modified = Int64(info.st_mtimespec.tv_sec) * 1000
                if modified < now - budgets.receiptMs { counts.expired += 1; unlink(url.path); return }
                let parts = name.split(separator: ".")
                guard parts.count == 3, let producer = pid_t(parts[0]), UUID(uuidString: String(parts[1])) != nil else { return }
                let suffix = String(parts[2])
                if suffix == "open" {
                    // PID reuse is ambiguous: leave a live PID's abandoned file alone.
                    guard kill(producer, 0) != 0, errno == ESRCH else { return }
                } else if suffix.hasPrefix("claim-") {
                    guard let claimant = pid_t(suffix.dropFirst(6)), kill(claimant, 0) != 0, errno == ESRCH else { return }
                } else if suffix != "ready" { return }
                let claimed = layout.spool.appendingPathComponent("\(parts[0]).\(parts[1]).claim-\(getpid())")
                guard rename(url.path, claimed.path) == 0 else { return }
                let fd = Darwin.open(claimed.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { return }
                var actual = stat()
                guard fstat(fd, &actual) == 0, actual.st_uid == getuid(), (actual.st_mode & S_IFMT) == S_IFREG,
                      actual.st_size <= budgets.spoolFileBytes else { close(fd); counts.invalid += 1; unlink(claimed.path); return }
                var bytes = [UInt8](repeating: 0, count: budgets.spoolFileBytes + 1)
                let size = read(fd, &bytes, bytes.count)
                close(fd)
                guard size >= 0, size <= budgets.spoolFileBytes else { counts.invalid += 1; unlink(claimed.path); return }
                let data = Data(bytes.prefix(size))
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                var retry = false
                for (index, line) in lines.enumerated() {
                    if index == lines.count - 1 {
                        if !line.isEmpty { counts.partial += 1 }
                        break
                    }
                    if counts.committed + counts.invalid + counts.expired + counts.conflicts >= limit || DispatchTime.now().uptimeNanoseconds >= deadline {
                        retry = true; break
                    }
                    do {
                        let draft = try JournalDraft.decode(Data(line))
                        try append(draft)
                        counts.committed += 1
                    } catch JournalError.expired { counts.expired += 1
                    } catch JournalError.conflict { counts.conflicts += 1
                    } catch JournalError.invalidEvent { counts.invalid += 1
                    } catch JournalError.unsupportedVersion { counts.invalid += 1
                    } catch { retry = true; break }
                }
                if retry {
                    let ready = layout.spool.appendingPathComponent("\(parts[0]).\(parts[1]).ready")
                    _ = rename(claimed.path, ready.path)
                    counts.remaining = true
                } else { unlink(claimed.path) }
            }
        }
        return counts
    }
}
