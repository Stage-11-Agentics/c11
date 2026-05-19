import Foundation

/// Pure path builders for the per-workspace mailbox tree. No I/O happens here —
/// the dispatcher owns directory creation at first send; this module only
/// computes the URLs and validates surface-name components.
///
/// Layout on disk:
///
///     <state>/workspaces/<workspace-uuid>/mailboxes/
///         _outbox/               (shared drop zone)
///         _processing/           (atomic-move target while dispatching)
///         _rejected/             (malformed envelopes + sibling .err files)
///         blobs/                 (body_ref payloads, v1.1 writers)
///         _dispatch.log          (append-only NDJSON, one line per event)
///         <surface-name>/        (per-recipient inbox)
///             01K3A2B7X8...msg   (pending message)
///
/// See `docs/c11-messaging-primitive-design.md` §3 and
/// `spec/mailbox-envelope.v1.schema.json` for the envelope format.
enum MailboxLayout {

    // MARK: - Names

    /// Directory name under `~/Library/Application Support/` where c11 keeps
    /// the socket, workspace snapshots, and the mailbox tree. Mirrors
    /// `SocketControlSettings.socketDirectoryName`; duplicated here so the
    /// CLI target (which compiles without SocketControlSettings.swift) can
    /// resolve the state root without a cross-target import.
    static let stateDirectoryName = "c11"

    static let workspacesDirectoryName = "workspaces"
    static let mailboxesDirectoryName = "mailboxes"
    static let outboxDirectoryName = "_outbox"
    static let processingDirectoryName = "_processing"
    static let rejectedDirectoryName = "_rejected"
    static let blobsDirectoryName = "blobs"
    static let dispatchLogFileName = "_dispatch.log"

    /// Extension for a fully-written envelope visible to the dispatcher.
    static let envelopeExtension = "msg"
    /// Extension for in-flight writes (hidden from the dispatcher by filename filter).
    static let tempExtension = "tmp"
    /// Sibling file next to a rejected envelope, explaining why it was quarantined.
    static let rejectedErrorExtension = "err"

    /// Max UTF-8 byte length for a surface name used as an inbox directory component.
    static let maxSurfaceNameBytes = 64

    // MARK: - Errors

    enum Error: Swift.Error, Equatable {
        case stateDirectoryUnavailable
        case invalidSurfaceName(name: String, reason: SurfaceNameRejection)
    }

    enum SurfaceNameRejection: String, Equatable {
        case empty
        case containsPathSeparator
        case containsNullByte
        case parentReference
        case leadingDot
        case tooLong
    }

    // MARK: - State root

    /// Resolves the c11 state root (default:
    /// `~/Library/Application Support/c11`). Tests that need isolation
    /// override HOME on the c11 process rather than overriding this function.
    static func defaultStateURL(fileManager: FileManager = .default) throws -> URL {
        StateDirectoryMigration.ensureMigrated(fileManager: fileManager)
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw Error.stateDirectoryUnavailable
        }
        return appSupport.appendingPathComponent(stateDirectoryName, isDirectory: true)
    }

    // MARK: - Path builders

    static func mailboxesRoot(state: URL, workspaceId: UUID) -> URL {
        state
            .appendingPathComponent(workspacesDirectoryName, isDirectory: true)
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
            .appendingPathComponent(mailboxesDirectoryName, isDirectory: true)
    }

    static func outboxURL(state: URL, workspaceId: UUID) -> URL {
        mailboxesRoot(state: state, workspaceId: workspaceId)
            .appendingPathComponent(outboxDirectoryName, isDirectory: true)
    }

    static func processingURL(state: URL, workspaceId: UUID) -> URL {
        mailboxesRoot(state: state, workspaceId: workspaceId)
            .appendingPathComponent(processingDirectoryName, isDirectory: true)
    }

    static func rejectedURL(state: URL, workspaceId: UUID) -> URL {
        mailboxesRoot(state: state, workspaceId: workspaceId)
            .appendingPathComponent(rejectedDirectoryName, isDirectory: true)
    }

    static func blobsURL(state: URL, workspaceId: UUID) -> URL {
        mailboxesRoot(state: state, workspaceId: workspaceId)
            .appendingPathComponent(blobsDirectoryName, isDirectory: true)
    }

    static func dispatchLogURL(state: URL, workspaceId: UUID) -> URL {
        mailboxesRoot(state: state, workspaceId: workspaceId)
            .appendingPathComponent(dispatchLogFileName, isDirectory: false)
    }

    /// Returns the inbox directory for a given surface name. Rejects names that
    /// would escape the mailbox tree or produce hidden/unsafe directory entries.
    static func inboxURL(state: URL, workspaceId: UUID, surfaceName: String) throws -> URL {
        try validateSurfaceName(surfaceName)
        return mailboxesRoot(state: state, workspaceId: workspaceId)
            .appendingPathComponent(surfaceName, isDirectory: true)
    }

    // MARK: - Filenames

    static func envelopeFilename(id: String) -> String {
        "\(id).\(envelopeExtension)"
    }

    static func tempFilename(id: String) -> String {
        ".\(id).\(tempExtension)"
    }

    static func rejectedErrorFilename(id: String) -> String {
        "\(id).\(rejectedErrorExtension)"
    }

    // MARK: - Surface-name validation

    /// Early bail-out used by the CLI and the dispatcher. The schema's
    /// `from` / `to` / `reply_to` fields are plain strings; the mailbox tree
    /// uses them as directory components, so the same name must also be safe
    /// on a POSIX filesystem.
    static func validateSurfaceName(_ name: String) throws {
        if name.isEmpty {
            throw Error.invalidSurfaceName(name: name, reason: .empty)
        }
        if name.utf8.count > maxSurfaceNameBytes {
            throw Error.invalidSurfaceName(name: name, reason: .tooLong)
        }
        if name.contains("/") {
            throw Error.invalidSurfaceName(name: name, reason: .containsPathSeparator)
        }
        if name.contains("\0") {
            throw Error.invalidSurfaceName(name: name, reason: .containsNullByte)
        }
        if name == "." || name == ".." {
            throw Error.invalidSurfaceName(name: name, reason: .parentReference)
        }
        if name.hasPrefix(".") {
            throw Error.invalidSurfaceName(name: name, reason: .leadingDot)
        }
    }
}

/// One-time-per-process migration of the c11 state directory from the legacy
/// `c11mux` name to the canonical `c11` name. Every state-root resolver
/// (`MailboxLayout.defaultStateURL`, `SocketControlSettings.stableSocketDirectoryURL`,
/// the password-store path builder, `SessionPersistence`, and the
/// remote-daemon cache root) calls `ensureMigrated` before constructing
/// its URL. Idempotent and thread-safe; cross-process safety is best-effort
/// via `moveItem`'s atomicity.
///
/// Migration shape: when legacy (`~/Library/Application Support/c11mux`) exists,
/// merge its entries into current (`~/Library/Application Support/c11`),
/// creating current first if necessary. Per-entry policy is `c11/` wins on
/// same-name collision; the `workspaces/` subdir is recursed one level so
/// per-workspace UUID directories present only in legacy still come over.
/// After the merge, if legacy is empty, replace it with a relative symlink
/// pointing at `c11` so downgraded older binaries continue to find their
/// state. The symlink can be dropped in a later release once the downgrade
/// window has closed; see `docs/c11-state-dir-rename-plan.md`.
///
/// The pre-C11-103 implementation rebuilt the dir with a single atomic rename
/// and bailed when both paths already existed. That left dogfooders who had
/// run tagged debug builds (which pre-create `c11/`) stranded on an empty
/// session after the prod rename release landed, because the migration was
/// a no-op and the prod build wrote a fresh empty snapshot. The per-entry
/// merge fixes that case at the cost of whole-dir atomicity, which the
/// `didRun` latch + per-entry `moveItem` atomicity make a non-issue.
enum StateDirectoryMigration {
    static let legacyName = "c11mux"
    static let currentName = "c11"

    private static let lock = NSLock()
    private static var didRun = false

    /// Performs the legacy → current merge once per process. The `appSupport`
    /// parameter is a testing seam (matches the convention used by
    /// `SessionPersistence.defaultSnapshotFileURL`); production callers leave
    /// it nil and accept the user-domain Application Support directory.
    static func ensureMigrated(
        fileManager: FileManager = .default,
        appSupport: URL? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if didRun { return }
        didRun = true

        let resolvedAppSupport: URL
        if let appSupport {
            resolvedAppSupport = appSupport
        } else {
            // Defensive: when no override is supplied AND the process is an
            // xctest host, bail without touching real Application Support.
            // `c11Tests` and `c11LogicTests` indirectly invoke this path via
            // `SessionPersistence.defaultSnapshotFileURL` and friends; without
            // this guard a passing test on a dogfooder's machine could merge
            // their actual session state. Tests that need to exercise the
            // migration must pass an explicit `appSupport:` temp-dir override.
            if isRunningUnderXCTest() { return }
            guard let discovered = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                return
            }
            resolvedAppSupport = discovered
        }

        let legacyURL = resolvedAppSupport.appendingPathComponent(legacyName, isDirectory: true)
        let currentURL = resolvedAppSupport.appendingPathComponent(currentName, isDirectory: true)

        // Fresh install (legacy never existed): nothing to do.
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }

        mergeLegacyIntoCurrent(
            legacyURL: legacyURL,
            currentURL: currentURL,
            fileManager: fileManager
        )

        // Drop the now-empty legacy dir and replace with a relative symlink so
        // downgraded older binaries still resolve their state. If collisions
        // kept entries in legacy, leave it alone — retiring the legacy path is
        // a future release.
        if isDirectoryEmpty(at: legacyURL, fileManager: fileManager) {
            do {
                try fileManager.removeItem(at: legacyURL)
                try fileManager.createSymbolicLink(
                    atPath: legacyURL.path,
                    withDestinationPath: currentName
                )
            } catch {
                logFailure(stage: "replace legacy with symlink", error: error)
            }
        }
    }

    /// Clears the `didRun` latch. Tests use this to run the migration
    /// multiple times against fresh temp-dir fixtures within a single process.
    static func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        didRun = false
    }

    private static func mergeLegacyIntoCurrent(
        legacyURL: URL,
        currentURL: URL,
        fileManager: FileManager
    ) {
        do {
            try fileManager.createDirectory(
                at: currentURL,
                withIntermediateDirectories: true
            )
        } catch {
            logFailure(stage: "create current dir", error: error)
            return
        }

        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: legacyURL.path)
        } catch {
            logFailure(stage: "list legacy entries", error: error)
            return
        }

        for entry in entries {
            let legacyEntryURL = legacyURL.appendingPathComponent(entry)
            let currentEntryURL = currentURL.appendingPathComponent(entry)

            if entry == MailboxLayout.workspacesDirectoryName,
               fileManager.fileExists(atPath: currentEntryURL.path) {
                mergeWorkspacesShallow(
                    legacyWorkspacesURL: legacyEntryURL,
                    currentWorkspacesURL: currentEntryURL,
                    fileManager: fileManager
                )
                continue
            }

            if fileManager.fileExists(atPath: currentEntryURL.path) {
                // Same-name collision: current wins. Leave legacy in place.
                continue
            }

            do {
                try fileManager.moveItem(at: legacyEntryURL, to: currentEntryURL)
            } catch {
                logFailure(stage: "move \(entry)", error: error)
            }
        }
    }

    private static func mergeWorkspacesShallow(
        legacyWorkspacesURL: URL,
        currentWorkspacesURL: URL,
        fileManager: FileManager
    ) {
        let workspaces: [String]
        do {
            workspaces = try fileManager.contentsOfDirectory(atPath: legacyWorkspacesURL.path)
        } catch {
            logFailure(stage: "list legacy workspaces", error: error)
            return
        }

        for workspace in workspaces {
            let legacyEntryURL = legacyWorkspacesURL.appendingPathComponent(workspace)
            let currentEntryURL = currentWorkspacesURL.appendingPathComponent(workspace)
            if fileManager.fileExists(atPath: currentEntryURL.path) {
                continue
            }
            do {
                try fileManager.moveItem(at: legacyEntryURL, to: currentEntryURL)
            } catch {
                logFailure(stage: "move workspaces/\(workspace)", error: error)
            }
        }
    }

    private static func isDirectoryEmpty(at url: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return entries.isEmpty
    }

    private static func logFailure(stage: String, error: Error) {
        FileHandle.standardError.write(Data(
            "c11: state-directory migration: \(stage) failed: \(error.localizedDescription)\n".utf8
        ))
    }

    /// Detects when this process is running as an XCTest host. Mirrors the
    /// signals used by `SessionRestorePolicy` and `AppDelegate` so behavior
    /// stays consistent across modules that need to skip side-effects in
    /// tests.
    private static func isRunningUnderXCTest() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCInjectBundle"] != nil { return true }
        if env["XCInjectBundleInto"] != nil { return true }
        if env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        return false
    }
}
