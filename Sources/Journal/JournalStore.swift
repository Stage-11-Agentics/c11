import Foundation
import SQLite3
import CryptoKit
import Darwin

struct JournalAppendResult {
    let receipt: JournalReceipt
    let changedSnapshot: JournalSnapshot?
}

/// All disk work, folding and maintenance run on this utility queue. Receipts never wait for UI.
final class JournalStore {
    private let queue = DispatchQueue(label: "com.stage11.c11.journal", qos: .utility)
    private let admissionLock = NSLock()
    private var pendingCount = 0
    private var pendingBytes = 0
    private var db: OpaquePointer?
    let layout: JournalStorageLayout
    let budgets: JournalBudgets
    let instanceID: UUID
    private let clock: () -> Int64
    private var lastPrune: Int64 = 0
    private var sincePrune = 0
    private var healthCode: JournalError?

    init(layout: JournalStorageLayout, budgets: JournalBudgets = JournalBudgets(),
         instanceID: UUID = UUID(), clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        self.layout = layout
        self.budgets = budgets
        self.instanceID = instanceID
        self.clock = clock
        try queue.sync {
            do { try open() } catch {
                if let db { sqlite3_close(db); self.db = nil }
                throw error
            }
        }
    }
    deinit { if let db { sqlite3_close(db) } }

    private enum Bind { case text(String), data(Data), integer(Int64), null }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func statement(_ sql: String, _ values: [Bind] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        for (index, value) in values.enumerated() {
            let n = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(stmt, n, text, -1, transient)
            case .data(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(data.count), transient) }
            case .integer(let integer): result = sqlite3_bind_int64(stmt, n, integer)
            case .null: result = sqlite3_bind_null(stmt, n)
            }
            guard result == SQLITE_OK else { sqlite3_finalize(stmt); throw failure() }
        }
        return stmt
    }
    private func execute(_ sql: String, _ values: [Bind] = []) throws {
        let stmt = try statement(sql, values)
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func scalar(_ sql: String, _ values: [Bind] = []) throws -> Int64 {
        let stmt = try statement(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(stmt, 0)
    }
    private func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        guard let ptr = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, index)))
    }
    private func failure() -> JournalError {
        switch sqlite3_errcode(db) {
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        case SQLITE_FULL: return .full
        default: return .unavailable
        }
    }

    private func open() throws {
        try layout.prepare()
        // Create privately before SQLite can apply the process umask to a new database.
        let fd = Darwin.open(layout.database.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw JournalError.unavailable }
        close(fd)
        guard sqlite3_open_v2(layout.database.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 100)
        let version = try scalar("PRAGMA user_version")
        guard version == 0 || version == 1 else { throw JournalError.unsupportedVersion }
        if version == 0 { try execute("PRAGMA auto_vacuum=INCREMENTAL") }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA wal_autocheckpoint=1000")
        let pageSize = try scalar("PRAGMA page_size")
        let maxPages = max(1, (budgets.totalBytes - budgets.reserveBytes - budgets.walLimit - budgets.spoolBytes) / pageSize)
        try execute("PRAGMA max_page_count=\(maxPages)")
        if version == 0 {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("CREATE TABLE journal_events (sequence INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT NOT NULL UNIQUE,committed_at_ms INTEGER NOT NULL,tab_id TEXT,session_id TEXT,agent_kind TEXT NOT NULL,model_id TEXT,workspace_id TEXT,draft BLOB NOT NULL,event BLOB)")
                try execute("CREATE INDEX journal_owner_sequence ON journal_events(tab_id,session_id,sequence)")
                try execute("CREATE INDEX journal_dimensions ON journal_events(committed_at_ms,agent_kind,model_id,workspace_id)")
                try execute("CREATE TABLE journal_current (owner TEXT PRIMARY KEY,state BLOB NOT NULL,observed_at_ms INTEGER NOT NULL,protected INTEGER NOT NULL)")
                try execute("CREATE TABLE journal_meta (key TEXT PRIMARY KEY,value INTEGER NOT NULL)")
                try execute("INSERT INTO journal_meta VALUES('fold_version',1),('coverage_low_water',1),('last_writer_observation',0)")
                try execute("PRAGMA user_version=1")
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
        guard try scalar("SELECT value FROM journal_meta WHERE key='fold_version'") == 1 else { throw JournalError.unsupportedVersion }
        try layout.prepare()
        try pruneOnQueue(now: clock(), pressure: false)
    }

    func append(draft: JournalDraft, context: JournalContext) throws -> JournalAppendResult {
        try draft.validate()
        let canonical = try draft.canonicalData()
        admissionLock.lock()
        guard pendingCount < budgets.queueEntries, pendingBytes + canonical.count <= budgets.queueBytes else {
            admissionLock.unlock()
            throw JournalError.busy
        }
        pendingCount += 1; pendingBytes += canonical.count
        admissionLock.unlock()
        defer { admissionLock.lock(); pendingCount -= 1; pendingBytes -= canonical.count; admissionLock.unlock() }
        return try queue.sync {
            do {
                let result = try appendOnQueue(draft, canonical: canonical, context: context)
                healthCode = nil
                return result
            } catch {
                if let failure = error as? JournalError, [.busy, .full, .unavailable, .unsupportedVersion].contains(failure) { healthCode = failure }
                throw error
            }
        }
    }

    private func appendOnQueue(_ d: JournalDraft, canonical: Data, context: JournalContext) throws -> JournalAppendResult {
        let lookup = try statement("SELECT draft,event FROM journal_events WHERE event_id=?", [.text(d.eventID.uuidString)])
        let lookupResult = sqlite3_step(lookup)
        if lookupResult == SQLITE_ROW {
            let priorDraft = blob(lookup, 0), eventData = blob(lookup, 1)
            sqlite3_finalize(lookup)
            guard priorDraft == canonical else { throw JournalError.conflict }
            let e = try JSONDecoder().decode(JournalEvent.self, from: eventData)
            return JournalAppendResult(receipt: JournalReceipt(eventID: d.eventID, sequence: e.sequence,
                committedAtMs: e.committedAtMs, replayed: true, projectionEffect: e.effect), changedSnapshot: nil)
        }
        sqlite3_finalize(lookup)
        guard lookupResult == SQLITE_DONE else { throw failure() }
        let now = clock()
        guard d.emittedAtMs >= now - budgets.receiptMs, d.emittedAtMs <= now + 300_000 else { throw JournalError.expired }
        if sincePrune >= 1000 || now - lastPrune >= 60_000 { try pruneOnQueue(now: now, pressure: false) }
        try reserveSpace(now: now)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT INTO journal_events(event_id,committed_at_ms,tab_id,session_id,agent_kind,model_id,workspace_id,draft) VALUES(?,?,?,?,?,?,?,?)", [
                .text(d.eventID.uuidString), .integer(now), d.tabID.map { .text($0.uuidString) } ?? .null,
                d.sessionID.map(Bind.text) ?? .null, .text(d.agentKind), context.modelID.map(Bind.text) ?? .null,
                d.workspaceID.map { .text($0.uuidString) } ?? .null, .data(canonical)])
            let sequence = sqlite3_last_insert_rowid(db)
            let prior = try d.owner.flatMap { try currentOnQueue(owner: $0) }
            let tick = DispatchTime.now().uptimeNanoseconds
            let folded = JournalReducer.fold(previous: prior, draft: d, sequence: sequence, committedAtMs: now,
                tick: tick, instanceID: instanceID, context: context)
            let event = JournalEvent(sequence: sequence, committedAtMs: now, observedTickNs: tick,
                appInstanceID: instanceID, draft: d,
                draftHash: SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined(),
                attribution: context.eligible && d.owner != nil ? "exact" : "unattributed", confidenceRank: d.source.rank,
                capabilities: d.adapter.capabilities, modelID: context.modelID, foldVersion: 1,
                effect: folded.effect, effectReason: folded.reason, fromPhase: folded.fromPhase,
                toPhase: folded.fromPhase == nil ? nil : folded.snapshot?.phase, fromSinceMs: folded.fromSinceMs)
            try execute("UPDATE journal_events SET event=? WHERE sequence=?", [.data(try JSONEncoder().encode(event)), .integer(sequence)])
            if let next = folded.snapshot, next != prior {
                let data = try JSONEncoder().encode(next)
                let total = try scalar("SELECT COALESCE(SUM(length(state)),0) FROM journal_current WHERE owner<>?", [.text(next.owner.key)])
                guard data.count <= budgets.ownerBytes, total + Int64(data.count) <= Int64(budgets.currentBytes) else { throw JournalError.full }
                try execute("INSERT INTO journal_current(owner,state,observed_at_ms,protected) VALUES(?,?,?,?) ON CONFLICT(owner) DO UPDATE SET state=excluded.state,observed_at_ms=excluded.observed_at_ms,protected=excluded.protected", [
                    .text(next.owner.key), .data(data), .integer(now), .integer(next.paintsAttention ? 1 : 0)])
            }
            try execute("UPDATE journal_meta SET value=? WHERE key='last_writer_observation'", [.integer(now)])
            try execute("COMMIT")
            // No mutable in-memory baseline: an ambiguous COMMIT is resolved by reading SQLite next time.
            sincePrune += 1
            return JournalAppendResult(receipt: JournalReceipt(eventID: d.eventID, sequence: sequence,
                committedAtMs: now, replayed: false, projectionEffect: folded.effect),
                changedSnapshot: folded.snapshot == prior ? nil : folded.snapshot)
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func current(owner: JournalOwner) throws -> JournalSnapshot? { try queue.sync { try currentOnQueue(owner: owner) } }
    private func currentOnQueue(owner: JournalOwner) throws -> JournalSnapshot? {
        let stmt = try statement("SELECT state FROM journal_current WHERE owner=?", [.text(owner.key)])
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        return try JSONDecoder().decode(JournalSnapshot.self, from: blob(stmt, 0))
    }

    func baselines() throws -> [JournalSnapshot] {
        try queue.sync {
            let stmt = try statement("SELECT state FROM journal_current ORDER BY owner")
            defer { sqlite3_finalize(stmt) }
            var rows: [JournalSnapshot] = []
            var code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                rows.append(try JSONDecoder().decode(JournalSnapshot.self, from: blob(stmt, 0)))
                code = sqlite3_step(stmt)
            }
            guard code == SQLITE_DONE else { throw failure() }
            return rows
        }
    }

    func readPage(after: Int64, through: Int64 = Int64.max, limit: Int = 500) throws -> [JournalEvent] {
        try queue.sync {
            let stmt = try statement("SELECT event FROM journal_events WHERE sequence>? AND sequence<=? ORDER BY sequence LIMIT ?",
                                     [.integer(after), .integer(through), .integer(Int64(max(1, min(500, limit))))])
            defer { sqlite3_finalize(stmt) }
            var rows: [JournalEvent] = []
            var code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                rows.append(try JSONDecoder().decode(JournalEvent.self, from: blob(stmt, 0)))
                code = sqlite3_step(stmt)
            }
            guard code == SQLITE_DONE else { throw failure() }
            return rows
        }
    }

    func coverage() throws -> (first: Int64, highWater: Int64, lastObservation: Int64) {
        try queue.sync {
            (try scalar("SELECT value FROM journal_meta WHERE key='coverage_low_water'"),
             try scalar("SELECT COALESCE(MAX(seq),0) FROM sqlite_sequence WHERE name='journal_events'"),
             try scalar("SELECT value FROM journal_meta WHERE key='last_writer_observation'"))
        }
    }
    func health() -> JournalError? { queue.sync { healthCode } }
    func prune(now: Int64) throws { try queue.sync { try pruneOnQueue(now: now, pressure: false) } }

    private func pruneOnQueue(now: Int64, pressure: Bool) throws {
        try autoreleasepool {
            let cutoff = now - (pressure ? budgets.receiptMs : max(budgets.historyMs, budgets.receiptMs))
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM journal_current WHERE owner IN (SELECT owner FROM journal_current WHERE protected=0 AND observed_at_ms<? LIMIT 1000)", [.integer(now - budgets.historyMs)])
                try execute("DELETE FROM journal_events WHERE sequence IN (SELECT sequence FROM journal_events WHERE committed_at_ms<? ORDER BY sequence LIMIT 1000)", [.integer(cutoff)])
                try execute("UPDATE journal_meta SET value=COALESCE((SELECT MIN(sequence) FROM journal_events),(SELECT COALESCE(MAX(seq),0)+1 FROM sqlite_sequence WHERE name='journal_events')) WHERE key='coverage_low_water'")
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            try execute("PRAGMA incremental_vacuum(256)")
            lastPrune = now; sincePrune = 0
        }
    }

    private func reserveSpace(now: Int64) throws {
        var physical = layout.physicalBytes()
        if physical >= budgets.reclaimStart {
            // One bounded batch per append. If receipts prevent recovery, reject admission.
            try pruneOnQueue(now: now, pressure: true)
        }
        let wal = JournalStorageLayout.physicalBytes(layout.database.path + "-wal")
        if wal >= budgets.checkpointBytes || physical >= budgets.reclaimStart {
            let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            if rc != SQLITE_OK && wal >= budgets.walLimit { throw JournalError.full }
        }
        physical = layout.physicalBytes()
        guard physical + budgets.reserveBytes <= budgets.totalBytes,
              JournalStorageLayout.physicalBytes(layout.database.path + "-wal") < budgets.walLimit else { throw JournalError.full }
    }
}
