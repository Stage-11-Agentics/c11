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
///         <tab-uuid>/            (per-recipient inbox, lowercased tab UUID)
///             01K3A2B7X8...msg   (pending message)
///             _read/             (consumed by push or drain; history only)
///
/// Inboxes are keyed on the recipient tab's UUID, never its title: a title
/// can carry `/`, run past a filename's length, or change under a rename.
/// Titles and `mailbox.address` stay lookups that resolve to tab UUIDs.
/// Inboxes from older builds were keyed on the raw title; `recvInboxURLs`
/// still reads such a directory so its unread mail is not stranded.
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
    static let stateDirectoryName = C11Identity.stateDirectoryName

    static let workspacesDirectoryName = "workspaces"
    static let mailboxesDirectoryName = "mailboxes"
    static let outboxDirectoryName = "_outbox"
    static let processingDirectoryName = "_processing"
    static let rejectedDirectoryName = "_rejected"
    static let blobsDirectoryName = "blobs"
    static let dispatchLogFileName = "_dispatch.log"
    /// Inside an inbox: envelopes a consumer (stdin push or `recv --drain`)
    /// has claimed. Renaming into it is the claim; whoever renames first owns
    /// the message.
    static let readDirectoryName = "_read"

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
        case invalidSurfaceName(name: String, reason: PanelNameRejection)
    }

    enum PanelNameRejection: String, Equatable {
        case empty
        case containsPathSeparator
        case containsNullByte
        case parentReference
        case leadingDot
        case tooLong
    }

    // MARK: - State root

    /// Resolves this process's mailbox state root (`MailboxStateRoot`): the
    /// release app's `~/Library/Application Support/c11`, a debug or tagged
    /// build's own folder, or a test process's temporary folder.
    static func defaultStateURL(fileManager: FileManager = .default) throws -> URL {
        StateDirectoryMigration.ensureMigrated(fileManager: fileManager)
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw Error.stateDirectoryUnavailable
        }
        let root = MailboxStateRoot.forProcess(
            main: Bundle.main.bundleIdentifier,
            executablePath: Bundle.main.executableURL?.path,
            environment: ProcessInfo.processInfo.environment,
            appSupport: appSupport,
            hostsXCTest: NSClassFromString("XCTestCase") != nil,
            temporaryDirectory: fileManager.temporaryDirectory,
            processIdentifier: getpid()
        )
        if case .test = root.kind { MailboxStateRoot.removeAtExit(root.url) }
        return root.url
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

    /// The recipient tab's inbox: `<mailboxes>/<tab-uuid-lowercased>/`.
    static func inboxURL(state: URL, workspaceId: UUID, panelId: UUID) -> URL {
        mailboxesRoot(state: state, workspaceId: workspaceId)
            .appendingPathComponent(inboxDirectoryName(panelId: panelId), isDirectory: true)
    }

    static func inboxDirectoryName(panelId: UUID) -> String {
        panelId.uuidString.lowercased()
    }

    /// The title-keyed inbox older builds wrote. `nil` when the title could
    /// never have been a directory (it fails `validateSurfaceName`) or names
    /// one of the tree's own directories (`_outbox`, `blobs`, ...), which
    /// `recv --drain` must never read as an inbox.
    static func legacyInboxURL(state: URL, workspaceId: UUID, panelName: String) -> URL? {
        guard (try? validateSurfaceName(panelName)) != nil,
              !panelName.hasPrefix("_"),
              panelName != blobsDirectoryName else { return nil }
        return mailboxesRoot(state: state, workspaceId: workspaceId)
            .appendingPathComponent(panelName, isDirectory: true)
    }

    /// Inboxes `recv` reads, in order: the canonical UUID inbox (when the
    /// tab id is known), then the legacy title-keyed inbox when it exists on
    /// disk and is a different directory.
    static func recvInboxURLs(
        state: URL,
        workspaceId: UUID,
        panelId: UUID?,
        panelName: String?,
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []
        if let panelId {
            urls.append(inboxURL(state: state, workspaceId: workspaceId, panelId: panelId))
        }
        if let panelName,
           let legacy = legacyInboxURL(state: state, workspaceId: workspaceId, panelName: panelName),
           !urls.contains(where: { $0.standardizedFileURL == legacy.standardizedFileURL }) {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue {
                urls.append(legacy)
            }
        }
        return urls
    }

    /// `<inbox>/_read/`: where a consumed envelope lives after its claim.
    static func readURL(inbox: URL) -> URL {
        inbox.appendingPathComponent(readDirectoryName, isDirectory: true)
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

    /// Whether a name is safe as a single POSIX directory component. Inboxes
    /// are UUID-keyed now, so this only decides whether a title could have
    /// been a legacy inbox directory.
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

/// Plain words for a doorbell hold. `c11 mailbox trace` and `mailbox tail`
/// print the JSON line, then this sentence. The log file stays JSON.
/// A question, an unreadable prompt, and a stranded doorbell line are named
/// as themselves. Only `draft` is called a draft.
enum MailboxHoldNotice {

    /// Queued ids whose invitation has not succeeded. Covered ids stay unread
    /// until recv, and they are not held behind the draft.
    static func uncoveredCount(queuedIds: [String], coveredIds: Set<String>) -> Int {
        queuedIds.reduce(0) { $0 + (coveredIds.contains($1) ? 0 : 1) }
    }

    /// Queued messages to show as held behind a draft. Nil when this look is
    /// not a held-composer look, so a quiet-window defer leaves the indicator.
    /// Any other named look clears it. A count with no ids treats every queued
    /// message as uncovered.
    static func draftHoldCount(relook: String?, queued: Int) -> Int? {
        guard let relook else { return nil }
        guard relook == "draft" else { return 0 }
        return max(0, queued)
    }

    static func draftHoldCount(relook: String?, queuedIds: [String], coveredIds: Set<String>) -> Int? {
        guard let relook else { return nil }
        guard relook == "draft" else { return 0 }
        return uncoveredCount(queuedIds: queuedIds, coveredIds: coveredIds)
    }

    /// The reason written on a skip row. The decision can be `draft` while the
    /// composer still holds the doorbell line; the row says `stranded`.
    static func loggedSkipReason(decisionReason: String, relook: String?) -> String {
        if decisionReason == "draft", relook == "stranded" { return "stranded" }
        return decisionReason
    }

    /// The agent is working. That is not a draft holding mail.
    static func holdAfterClosedGate() -> Int { 0 }

    /// Claiming the last unread message clears a hold. A receipt that leaves
    /// mail does not guess which ids remain.
    static func holdAfterReceipt(unread: Int) -> Int? {
        unread <= 0 ? 0 : nil
    }

    /// Human trace prints the JSON line and then the sentence. `--json` prints
    /// the log records only, one object per line.
    static func traceText(lines: [String], jsonOutput: Bool) -> String {
        var out = ""
        for line in lines {
            let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
            out += body + "\n"
            if !jsonOutput, let sentence = sentence(forLogLine: body) {
                out += sentence + "\n"
            }
        }
        return out
    }

    static func sentence(outcome: String, reason: String) -> String? {
        let held = outcome == "doorbell_recheck" || outcome == "doorbell_skipped"
        guard held else { return nil }
        switch reason {
        case "draft":
            return String(
                localized: "mailbox.hold.trace.draft",
                defaultValue: "held: recipient has a draft"
            )
        case "dialog":
            return String(
                localized: "mailbox.hold.trace.dialog",
                defaultValue: "held: recipient is answering a question"
            )
        case "unknown_prompt":
            return String(
                localized: "mailbox.hold.trace.unknown",
                defaultValue: "held: recipient prompt is unreadable"
            )
        case "stranded":
            return String(
                localized: "mailbox.hold.trace.stranded",
                defaultValue: "held: doorbell line still in the composer"
            )
        case "headless_status":  // C11H-304, `MailboxHeadlessHold.notIdle`
            return String(
                localized: "mailbox.hold.trace.headless",
                defaultValue: "held: the panel has no screen and hc does not report its agent idle"
            )
        case "composer_unread":  // C11H-306, `MailboxHeadlessHold.unread`
            return String(
                localized: "mailbox.hold.trace.composerUnread",
                defaultValue: "held: the panel has no screen and c11 could not read its composer; it reads it again shortly"
            )
        default:
            return nil
        }
    }

    /// The plain sentence for one dispatch-log line, or nil when it is not a hold.
    static func sentence(forLogLine line: String) -> String? {
        guard line.contains("doorbell_") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcome = obj["outcome"] as? String,
              let reason = obj["reason"] as? String else { return nil }
        return sentence(outcome: outcome, reason: reason)
    }

    /// The JSON line plus the plain sentence, each ending in a newline.
    static func annotated(_ line: String) -> String {
        let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
        guard let sentence = sentence(forLogLine: body) else {
            return line.hasSuffix("\n") ? line : line + "\n"
        }
        return body + "\n" + sentence + "\n"
    }

    /// Tail reads arrive in chunks that may split a line. Completed lines are
    /// annotated. The returned pending is the trailing partial, so a caller
    /// can keep it without passing a captured variable as `inout`.
    static func annotateChunk(
        _ chunk: String,
        pending: String,
        jsonOutput: Bool = false
    ) -> (shown: String, pending: String) {
        var rest = pending + chunk
        var out = ""
        while let newline = rest.firstIndex(of: "\n") {
            let line = String(rest[..<newline])
            rest = String(rest[rest.index(after: newline)...])
            if jsonOutput {
                out += line + "\n"
            } else {
                out += annotated(line)
            }
        }
        return (out, rest)
    }

    /// What the mailbox cell and drawer say while a draft holds delivery.
    /// Nil when nothing is held, including a question or an unreadable prompt.
    static func panelLine(count: Int) -> String? {
        switch count {
        case ..<1:
            return nil
        case 1:
            return String(
                localized: "mailbox.hold.panel.one",
                defaultValue: "1 message held behind your draft"
            )
        default:
            return String(
                localized: "mailbox.hold.panel.many",
                defaultValue: "\(count) messages held behind your draft"
            )
        }
    }
}

/// The words the mailbox cell and the drawer show for a draft hold.
/// Both surfaces call this, so a test fails when the sentence is removed.
enum MailboxHoldCopy {
    static func cellAccessibility(unread: Int, received: Int, heldBehindDraft: Int) -> String {
        var text = String(
            localized: "mailbox.cell.accessibility",
            defaultValue: "Mailbox, \(unread) unread, \(received) received"
        )
        if let held = MailboxHoldNotice.panelLine(count: heldBehindDraft) {
            text += ". " + held
        }
        return text
    }

    /// The hold sentence is inserted after the count lines and before "Click to read".
    static func cellHelp(linesBeforeHold: [String], heldBehindDraft: Int) -> [String] {
        var lines = linesBeforeHold
        if let held = MailboxHoldNotice.panelLine(count: heldBehindDraft) {
            lines.append(held)
        }
        return lines
    }

    static func drawerBanner(heldBehindDraft: Int) -> String? {
        MailboxHoldNotice.panelLine(count: heldBehindDraft)
    }
}

/// Which mailbox tree a process uses (C11H-439). Only the release app keeps
/// its mail in `~/Library/Application Support/c11`, with the untagged staging
/// and nightly channels, whose users keep their mail across an update. A
/// debug or tagged build uses its own `~/Library/Application Support/c11-dev/<bundle id>/`,
/// and a test process a temporary folder removed when it exits, so neither
/// leaves workspace folders in the release app's. A migration QA launch
/// (`C11Identity.isMigrationQALaunch`) stands in for the release app and keeps
/// its folder, which is where the migration puts the mail; a CLI given the
/// same two variables does too.
///
/// The app decides from its own bundle id and stamps the folder on every
/// terminal (`C11_MAILBOX_STATE_DIR`). The CLI follows that stamp; without
/// one (a terminal an older build made, a bare shell) it follows the
/// migration variables, then the terminal's `CMUX_BUNDLE_ID`, then the app it
/// ships inside. A test that
/// relocates the home with `CFFIXED_USER_HOME` (the CLI tests do, for the c11
/// they run) already has a disposable Application Support and resolves there.
enum MailboxStateRoot {
    enum Kind: Equatable {
        case release
        case build(String)
        case test
        /// The folder the app stamped on the terminal this CLI runs in.
        case stamped
    }

    struct Resolved: Equatable {
        let kind: Kind
        let url: URL
    }

    static let buildsDirectoryName = "c11-dev"
    static let stampEnvironmentKey = "C11_MAILBOX_STATE_DIR"
    static let testDirectoryPrefix = "c11-test-mailboxes-"

    /// The bundle ids that share the release folder.
    static let sharedBundleIdentifiers: Set<String> = [
        C11Identity.releaseBundleIdentifier,
        C11Identity.stagingBundleIdentifier,
        C11Identity.nightlyBundleIdentifier,
    ]

    /// The root for a process described by its facts: `defaultStateURL` passes
    /// this process's own, and tests pass a CLI's or an app's.
    static func forProcess(
        main: String?,
        executablePath: String?,
        environment: [String: String],
        appSupport: URL,
        hostsXCTest: Bool,
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> Resolved {
        resolve(
            appSupport: appSupport,
            environment: environment,
            bundleIdentifier: bundleIdentifier(main: main, environment: environment, executablePath: executablePath),
            isApp: main.map(C11Identity.isFamilyBundleIdentifier) ?? false,
            hostsXCTest: hostsXCTest,
            temporaryDirectory: temporaryDirectory,
            processIdentifier: processIdentifier
        )
    }

    static func resolve(
        appSupport: URL,
        environment: [String: String],
        bundleIdentifier: String?,
        isApp: Bool,
        hostsXCTest: Bool = false,
        temporaryDirectory: URL,
        processIdentifier: Int32,
        isDirectory: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    ) -> Resolved {
        // Only the CLI follows a stamp: an app opened from another build's
        // terminal decides for itself, and a test runner started from a c11
        // terminal (XCTest loaded in this process, not inherited variables,
        // which a test's child CLI carries too) keeps to its own folder.
        if !isApp, !hostsXCTest, let stamp = environment[stampEnvironmentKey], stamp.hasPrefix("/"), isDirectory(stamp) {
            return Resolved(kind: .stamped, url: URL(fileURLWithPath: stamp, isDirectory: true))
        }
        if hostsXCTest || isRunningUnderXCTest(environment), environment["CFFIXED_USER_HOME"] == nil {
            return Resolved(
                kind: .test,
                url: temporaryDirectory.appendingPathComponent(
                    "\(testDirectoryPrefix)\(processIdentifier)", isDirectory: true)
            )
        }
        let migrationQA = C11Identity.isMigrationQALaunch(environment: environment)
        if !migrationQA, let id = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           C11Identity.isFamilyBundleIdentifier(id),
           !sharedBundleIdentifiers.contains(id) {
            return Resolved(kind: .build(id), url: buildFolder(appSupport: appSupport, bundleIdentifier: id))
        }
        return Resolved(
            kind: .release,
            url: appSupport.appendingPathComponent(C11Identity.stateDirectoryName, isDirectory: true)
        )
    }

    static func buildFolder(appSupport: URL, bundleIdentifier id: String) -> URL {
        let component = id.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
        return appSupport
            .appendingPathComponent(buildsDirectoryName, isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
    }

    /// The app's own id. For the CLI (no bundle of its own) or a test runner:
    /// the id of the app whose terminal it runs in, else the app it ships inside.
    static func bundleIdentifier(main: String?, environment: [String: String], executablePath: String?) -> String? {
        if let main, C11Identity.isFamilyBundleIdentifier(main) { return main }
        if let terminal = environment["CMUX_BUNDLE_ID"], !terminal.isEmpty { return terminal }
        return enclosingAppBundleIdentifier(executablePath: executablePath)
    }

    static func enclosingAppBundleIdentifier(executablePath: String?) -> String? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        var url = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func isRunningUnderXCTest(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCInjectBundle"] != nil
            || environment["XCInjectBundleInto"] != nil
            || environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true
    }

    private static let exitLock = NSLock()
    private static var exitRemovalPath: String?

    /// A test process's folder goes when the process exits normally.
    static func removeAtExit(_ url: URL) {
        exitLock.lock()
        defer { exitLock.unlock() }
        guard exitRemovalPath == nil, url.lastPathComponent.hasPrefix(testDirectoryPrefix) else { return }
        exitRemovalPath = url.path
        atexit { MailboxStateRoot.removeTestFolder() }
    }

    private static func removeTestFolder() {
        exitLock.lock()
        let path = exitRemovalPath
        exitLock.unlock()
        guard let path, URL(fileURLWithPath: path).lastPathComponent.hasPrefix(testDirectoryPrefix) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A closed workspace's folder under `<state>/workspaces/` (C11H-439). The
/// dispatcher makes the folder when the workspace opens; when the workspace
/// closes holding no file at all (no unread, read or rejected envelope, no
/// dispatch log or receipt), the folder goes with it. Only empty directories
/// are removed (`rmdir`), so a file that lands meanwhile keeps its folder,
/// and a folder whose workspace is open again is left alone.
enum MailboxWorkspaceFolder {
    enum Outcome: Equatable {
        case removed
        /// Some file is in it; nothing was removed.
        case kept
        /// A dispatcher for the workspace is running again.
        case live
        case absent
    }

    private static let lock = NSLock()
    private static var liveCounts: [String: Int] = [:]

    private static func key(state: URL, workspaceId: UUID) -> String {
        MailboxLayout.mailboxesRoot(state: state, workspaceId: workspaceId).standardizedFileURL.path
    }

    /// A dispatcher for the workspace starts. Called before it makes the tree.
    static func noteStarted(state: URL, workspaceId: UUID) {
        lock.withLock { liveCounts[key(state: state, workspaceId: workspaceId), default: 0] += 1 }
    }

    static func noteStopped(state: URL, workspaceId: UUID) {
        lock.withLock {
            let key = key(state: state, workspaceId: workspaceId)
            let count = (liveCounts[key] ?? 0) - 1
            liveCounts[key] = count > 0 ? count : nil
        }
    }

    static func folderURL(state: URL, workspaceId: UUID) -> URL {
        state
            .appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
    }

    /// Removes the workspace's folder when no file is anywhere in it.
    @discardableResult
    static func removeIfEmpty(state: URL, workspaceId: UUID, fileManager: FileManager = .default) -> Outcome {
        let key = key(state: state, workspaceId: workspaceId)
        if lock.withLock({ liveCounts[key] != nil }) { return .live }
        let folder = folderURL(state: state, workspaceId: workspaceId)
        guard isPlainDirectory(folder.path) else { return .absent }
        // The walk runs unlocked; a dispatcher that starts meanwhile is seen below.
        var directories = [folder.path]
        guard let enumerator = fileManager.enumerator(atPath: folder.path) else { return .kept }
        while let relative = enumerator.nextObject() as? String {
            let path = folder.appendingPathComponent(relative).path
            guard isPlainDirectory(path) else { return .kept }
            directories.append(path)
        }
        lock.lock()
        defer { lock.unlock() }
        guard liveCounts[key] == nil else { return .live }
        // Deepest first; a directory that is no longer empty stops the removal.
        for path in directories.sorted(by: { $0.count > $1.count }) {
            guard rmdir(path) == 0 else { return .kept }
        }
        return .removed
    }

    private static func isPlainDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}

/// c11 does not import `c11`, `c11mux`, or `cmux` state. The call stays so
/// every resolver still has one seam, and it returns without reading or writing.
enum StateDirectoryMigration {
    static let legacyName = "c11mux"
    static let currentName = C11Identity.stateDirectoryName

    static func ensureMigrated(
        fileManager: FileManager = .default,
        appSupport: URL? = nil
    ) {
        _ = fileManager
        _ = appSupport
    }

    static func resetForTests() {}
}
