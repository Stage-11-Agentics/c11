import AVFoundation
import XCTest
import UserNotifications

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class SoundTestBox: @unchecked Sendable {
    var result: TerminalController.V2CallResult?
    var response: String?
}

/// C11H-319: three sound channels, per-kind flag sounds, and imported files
/// that outlive their originals. Every test uses a scratch defaults suite and
/// a scratch sound store; nothing touches the real Application Support or
/// `~/Library/Sounds`.
@MainActor
final class NotificationSoundTests: XCTestCase {
    private var root: URL!
    private var store: CustomNotificationSoundStore!
    private var settings: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-319-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = CustomNotificationSoundStore(
            storeDirectory: root.appendingPathComponent("store", isDirectory: true),
            playbackDirectory: root.appendingPathComponent("playback", isDirectory: true)
        )
        suiteName = "c11-319-\(UUID().uuidString)"
        settings = UserDefaults(suiteName: suiteName)
        // Anything that reaches for the shared store (socket workers, syncs)
        // stays in this scratch folder.
        CustomNotificationSoundStore.sharedOverrideForTesting = store
    }

    override func tearDown() {
        CustomNotificationSoundStore.sharedOverrideForTesting = nil
        TerminalNotificationStore.shared.configureNotificationSoundsForTesting(store: nil, registry: nil)
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Fixtures

    /// A short tone. `.aiff` is big-endian PCM; `.caf` and `.wav` little-endian.
    private func tone(_ name: String, seconds: Double = 0.2, sampleRate: Double = 8000) throws -> URL {
        let url = root.appendingPathComponent(name)
        let bigEndian = url.pathExtension.lowercased().hasPrefix("aif")
        try writeTone(to: url, seconds: seconds, sampleRate: sampleRate, bigEndian: bigEndian)
        return url
    }

    /// The file closes when this scope ends.
    private func writeTone(to url: URL, seconds: Double, sampleRate: Double, bigEndian: Bool) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: bigEndian,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = sin(Float(index) * 0.2) * 0.2 }
        try file.write(from: buffer)
    }

    private func importedID(_ url: URL) throws -> String {
        switch store.importSound(from: url) {
        case .success(let id): return id
        case .failure(let error): throw error
        }
    }

    // MARK: Values

    func testASoundArgumentThatNamesAFileBecomesAnAbsolutePath() {
        let cwd = "/work/project"
        let here: Set<String> = ["/work/project/bell.wav"]
        func resolve(_ value: String) -> String {
            NotificationSoundArgument.resolve(value, currentDirectory: cwd, home: "/home/op", fileExists: { here.contains($0) })
        }
        XCTAssertEqual(resolve("~/Sounds/gong.m4a"), "/home/op/Sounds/gong.m4a")
        XCTAssertEqual(resolve("sounds/a.wav"), "/work/project/sounds/a.wav")
        XCTAssertEqual(resolve("./a.wav"), "/work/project/a.wav")
        XCTAssertEqual(resolve("../a.wav"), "/work/a.wav")
        XCTAssertEqual(resolve("/abs/a.wav"), "/abs/a.wav")
        XCTAssertEqual(resolve("bell.wav"), "/work/project/bell.wav", "a bare name that exists here is a file")
        XCTAssertEqual(resolve("chime.wav"), "chime.wav", "one that does not exist stays a name, and is refused as one")
        for name in ["Hero", "none", "default", "flag", "file:0123456789abcdef.caf"] {
            XCTAssertEqual(resolve(name), name)
        }
    }

    func testSoundValuesParseAndPathsAreToldApart() {
        XCTAssertEqual(NotificationSoundChoice(rawValue: "hero"), .named("Hero"))
        XCTAssertEqual(NotificationSoundChoice(rawValue: "default"), .systemDefault)
        XCTAssertEqual(NotificationSoundChoice(rawValue: "None"), NotificationSoundChoice.none)
        XCTAssertEqual(NotificationSoundChoice(rawValue: "file:0123456789abcdef.caf"), .file("0123456789abcdef.caf"))
        XCTAssertNil(NotificationSoundChoice(rawValue: "file:../../etc/passwd"), "a file id is only a store name")
        XCTAssertNil(NotificationSoundChoice(rawValue: "Trumpet"))
        XCTAssertNil(NotificationSoundChoice(rawValue: "custom_file"), "the legacy value is migrated, not played")
        XCTAssertTrue(NotificationSoundChoice.looksLikePath("~/Sounds/a.m4a"))
        XCTAssertTrue(NotificationSoundChoice.looksLikePath("sounds/a.wav"))
        XCTAssertFalse(NotificationSoundChoice.looksLikePath("Glass"))
        XCTAssertEqual(NotificationSoundChannel(cliName: "needs-you"), .needsYou)
        XCTAssertEqual(NotificationSoundChannel(cliName: "turn_end"), .turnEnd)
    }

    func testEachChannelHasItsOwnSettingAndADistinctDefault() {
        let defaults = Set(NotificationSoundChannel.allCases.map(\.shippedDefault))
        XCTAssertEqual(defaults.count, 3, "turn end, needs you and flag sound different by default")
        XCTAssertEqual(Set(NotificationSoundChannel.allCases.map(\.defaultsKey)).count, 3)
        settings.set("Ping", forKey: NotificationSoundChannel.needsYou.defaultsKey)
        XCTAssertEqual(NotificationSoundChannel.needsYou.choice(defaults: settings), .named("Ping"))
        XCTAssertEqual(NotificationSoundChannel.turnEnd.choice(defaults: settings), .named("Bottle"))
        settings.set("none", forKey: NotificationSoundChannel.flag.defaultsKey)
        XCTAssertEqual(NotificationSoundChannel.flag.choice(defaults: settings), .named("Hero"), "a flag always sounds")
        guard case .failure(.noneNotAllowed) = NotificationSoundInput.choice(from: "none", allowsNone: false, store: store) else {
            return XCTFail("the flag sound must refuse none")
        }
    }

    // MARK: Imported files

    func testAnImportedFileOutlivesItsOriginal() throws {
        let original = try tone("chime.aiff")
        let id = try importedID(original)
        XCTAssertTrue(id.hasSuffix(".aiff"), "aiff is kept as it is")
        XCTAssertEqual(store.displayName(for: id), "chime.aiff")
        try FileManager.default.removeItem(at: original)

        settings.set(NotificationSoundChoice.file(id).rawValue, forKey: NotificationSoundChannel.turnEnd.defaultsKey)
        let resolved = NotificationSoundResolver.routine(channel: .turnEnd, defaults: settings, store: store)
        XCTAssertEqual(resolved.played, .file(id))
        XCTAssertEqual(resolved.source, .channel)
        XCTAssertNil(resolved.fallbackReason)
        XCTAssertEqual(resolved.systemSoundName, "c11-\(id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.playbackURL(for: id).path),
                      "macOS reads the playback copy")
        XCTAssertNotNil(resolved.notificationSound)
    }

    func testCompressedFormatsAreConvertedToCAF() throws {
        let source = try tone("source.caf", seconds: 0.3, sampleRate: 44_100)
        let m4a = root.appendingPathComponent("library.m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", source.path, m4a.path]
        try convert.run()
        convert.waitUntilExit()
        XCTAssertEqual(convert.terminationStatus, 0)

        let id = try importedID(m4a)
        XCTAssertTrue(id.hasSuffix(".caf"), "macOS notifications do not play m4a; c11 stores CAF")
        XCTAssertNotNil(CustomNotificationSoundStore.audioDuration(of: store.url(for: id)))
    }

    func testACodecNotificationsCannotPlayIsConvertedToPCM() throws {
        let source = try tone("source.caf", seconds: 0.3, sampleRate: 44_100)
        let aacInCAF = root.appendingPathComponent("compressed.caf")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "caff", "-d", "aac", source.path, aacInCAF.path]
        try convert.run()
        convert.waitUntilExit()
        XCTAssertEqual(convert.terminationStatus, 0)
        XCTAssertFalse(CustomNotificationSoundStore.hasNotificationCodec(aacInCAF), "AAC in a CAF container")

        let id = try importedID(aacInCAF)
        XCTAssertTrue(CustomNotificationSoundStore.hasNotificationCodec(store.url(for: id)),
                      "macOS would play its default sound for AAC; c11 stores PCM")
        XCTAssertTrue(CustomNotificationSoundStore.hasNotificationCodec(source), "PCM is kept as it is")
    }

    func testImportRefusesWhatCannotBeANotificationSound() throws {
        let text = root.appendingPathComponent("notes.wav")
        try Data("not audio".utf8).write(to: text)
        guard case .failure(.notAudio) = store.importSound(from: text) else { return XCTFail("text accepted") }

        let long = try tone("long.caf", seconds: 31)
        guard case .failure(.tooLong(_, let seconds)) = store.importSound(from: long) else {
            return XCTFail("a sound over 30 s accepted")
        }
        XCTAssertEqual(seconds, 31)

        guard case .failure(.missingFile) = store.importSound(from: root.appendingPathComponent("gone.aiff")) else {
            return XCTFail("a missing file accepted")
        }
        XCTAssertTrue(store.importedIDs().isEmpty)
    }

    func testTheSameFileImportedTwiceIsOneCopy() throws {
        let first = try tone("a.wav")
        let copy = root.appendingPathComponent("b.wav")
        try FileManager.default.copyItem(at: first, to: copy)
        XCTAssertEqual(try importedID(first), try importedID(copy))
        XCTAssertEqual(store.importedIDs().count, 1)
    }

    func testAMissingPlaybackCopyIsRecreatedFromTheStore() throws {
        let id = try importedID(try tone("ping.caf"))
        guard case .success = store.prepareForPlayback(id: id) else { return XCTFail("not playable") }
        try FileManager.default.removeItem(at: store.playbackURL(for: id))
        guard case .success(let name) = store.prepareForPlayback(id: id) else { return XCTFail("not recreated") }
        XCTAssertEqual(name, "c11-\(id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.playbackURL(for: id).path))
    }

    func testPlaybackCopiesExistOnlyForSoundsInUseAndNothingElseIsTouched() throws {
        let registry = PanelFlagKindRegistry(defaults: settings)
        let turn = try importedID(try tone("turn.wav"))
        let merge = try importedID(try tone("merge.aiff", seconds: 0.3))
        let spare = try importedID(try tone("spare.caf", seconds: 0.4))
        try FileManager.default.createDirectory(at: store.playbackDirectory, withIntermediateDirectories: true)
        let unrelated = ["Glass.aiff", "c11-notes.txt", "cmux-custom-notification-sound-0123.caf"]
        for name in unrelated {
            try Data("keep".utf8).write(to: store.playbackDirectory.appendingPathComponent(name))
        }
        func copies() -> Set<String> {
            Set([turn, merge, spare].filter { FileManager.default.fileExists(atPath: store.playbackURL(for: $0).path) })
        }

        settings.set(NotificationSoundChoice.file(turn).rawValue, forKey: NotificationSoundChannel.turnEnd.defaultsKey)
        try registry.setSound(id: "merge-issue", .file(merge))
        NotificationSoundPlayback.sync(defaults: settings, registry: registry, store: store)
        XCTAssertEqual(copies(), [turn, merge], "a copy for each sound in use, none for an unused import")

        settings.set("Ping", forKey: NotificationSoundChannel.turnEnd.defaultsKey)
        let changed = NotificationSoundPlayback.sync(defaults: settings, registry: registry, store: store)
        XCTAssertEqual(changed.removed, [turn])
        XCTAssertEqual(copies(), [merge])

        try registry.setSound(id: "merge-issue", nil)
        NotificationSoundPlayback.sync(defaults: settings, registry: registry, store: store)
        XCTAssertEqual(copies(), [])
        for name in unrelated {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.playbackDirectory.appendingPathComponent(name).path),
                          "\(name) is not c11's to remove")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: turn).path), "the store keeps imports for reuse")
    }

    // MARK: Fallback, never silence

    func testAMissingOrBrokenFileFallsBackAndSaysWhy() throws {
        let missing = NotificationSoundChoice.file("0123456789abcdef.caf")
        settings.set(missing.rawValue, forKey: NotificationSoundChannel.needsYou.defaultsKey)
        let routine = NotificationSoundResolver.routine(channel: .needsYou, defaults: settings, store: store)
        XCTAssertEqual(routine.played, .named("Glass"))
        XCTAssertEqual(routine.source, .fallback)
        XCTAssertEqual(routine.requested, missing)
        XCTAssertEqual(routine.fallbackReason, .missingFile)
        XCTAssertNotNil(routine.notificationSound, "a fallback still sounds")

        // A stored file that no longer opens as audio.
        let broken = NotificationSoundChoice.file("fedcba9876543210.aiff")
        try FileManager.default.createDirectory(at: store.storeDirectory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.url(for: "fedcba9876543210.aiff"))
        settings.set(broken.rawValue, forKey: NotificationSoundChannel.turnEnd.defaultsKey)
        let unplayable = NotificationSoundResolver.routine(channel: .turnEnd, defaults: settings, store: store)
        XCTAssertEqual(unplayable.played, .named("Bottle"))
        XCTAssertEqual(unplayable.fallbackReason, .unplayable)

        var payload: [String: Any] = [:]
        unplayable.addFields(to: &payload)
        XCTAssertEqual(payload["sound"] as? String, "Bottle")
        XCTAssertEqual(payload["sound_source"] as? String, "fallback")
        XCTAssertEqual(payload["sound_requested"] as? String, broken.rawValue)
        XCTAssertEqual(payload["sound_fallback"] as? String, "unplayable")
    }

    func testAKindsMissingFileFallsBackToTheFlagSound() {
        let missing = NotificationSoundChoice.file("0123456789abcdef.wav")
        settings.set("Submarine", forKey: NotificationSoundChannel.flag.defaultsKey)
        let resolved = NotificationSoundResolver.flag(kindSound: missing, defaults: settings, store: store)
        XCTAssertEqual(resolved.played, .named("Submarine"), "falls back to the flag sound, not silence")
        XCTAssertEqual(resolved.source, .flag)
        XCTAssertEqual(resolved.requested, missing)
        XCTAssertEqual(resolved.fallbackReason, .missingFile)

        // The flag sound itself a missing file: Hero.
        settings.set(missing.rawValue, forKey: NotificationSoundChannel.flag.defaultsKey)
        let last = NotificationSoundResolver.flag(kindSound: missing, defaults: settings, store: store)
        XCTAssertEqual(last.played, .named("Hero"))
        XCTAssertEqual(last.source, .fallback)
    }

    // MARK: Flag kinds

    func testAKindsSoundBeatsTheFlagSoundAndFlagClearsIt() throws {
        let registry = PanelFlagKindRegistry(defaults: settings)
        let kind = try XCTUnwrap(registry.kind(id: "merge-issue"))
        XCTAssertNil(registry.sound(id: kind.id), "no sound: the flag sound")
        XCTAssertEqual(NotificationSoundResolver.flag(kindSound: registry.sound(id: kind.id), defaults: settings, store: store).played,
                       .named("Hero"))

        try registry.setSound(id: kind.id, .named("Glass"))
        let own = NotificationSoundResolver.flag(kindSound: registry.sound(id: kind.id), defaults: settings, store: store)
        XCTAssertEqual(own.played, .named("Glass"))
        XCTAssertEqual(own.source, .kind)

        try registry.setSound(id: kind.id, NotificationSoundChoice.none)
        let quiet = NotificationSoundResolver.flag(kindSound: registry.sound(id: kind.id), defaults: settings, store: store)
        XCTAssertEqual(quiet.played, NotificationSoundChoice.none, "a kind may be soundless")
        XCTAssertNil(quiet.notificationSound)

        try registry.setSound(id: kind.id, nil)
        XCTAssertNil(registry.sound(id: kind.id))
        XCTAssertThrowsError(try registry.setSound(id: "not-a-kind", .named("Glass")))
    }

    func testAKindsSoundLivesBesideTheKindAndGoesWithIt() throws {
        let registry = PanelFlagKindRegistry(defaults: settings)
        let custom = PanelFlagKind(id: "command-consideration", name: "Command Consideration", color: .green, emoji: "🧭")
        try registry.set(custom)
        try registry.setSound(id: custom.id, .named("Purr"))

        // Editing the kind (as any build may) leaves its sound alone, and the
        // kind value copied onto flags carries no sound.
        try registry.set(PanelFlagKind(id: custom.id, name: "Consider", color: .teal, emoji: nil))
        XCTAssertEqual(registry.sound(id: custom.id), .named("Purr"))
        XCTAssertNil(registry.kind(id: custom.id)?.jsonObject["sound"])

        XCTAssertTrue(try registry.remove(id: custom.id))
        try registry.set(custom)
        XCTAssertNil(registry.sound(id: custom.id), "a removed kind's sound went with it")
    }

    func testAFlagOfAKindWithASoundRecordsItsSound() throws {
        let registry = PanelFlagKindRegistry(defaults: settings)
        try registry.setSound(id: "merge-issue", .named("Glass"))
        let spec = FlagNotificationSpec.make(
            workspaceId: UUID(), surfaceId: UUID(), flagRaisedAt: Date(), title: "Owner", reason: "conflict",
            kind: registry.kind(id: "merge-issue"), defaults: settings,
            kindSound: registry.sound(id: "merge-issue"), soundStore: store
        )
        XCTAssertNotNil(spec.request(appName: "c11", categoryIdentifier: "c").content.sound)
        let record = FlagNotificationRecord(action: .posted, cause: .raised, identifier: spec.identifier, attribution: spec.attribution)
        XCTAssertEqual(record.payload["sound"] as? String, "Glass")
        XCTAssertEqual(record.payload["sound_source"] as? String, "kind")
        XCTAssertEqual(record.payload["kind"] as? String, "merge-issue")
        XCTAssertNil(record.payload["sound_fallback"])
        XCTAssertTrue(record.logLine.contains("sound=Glass sound_source=kind"))
    }

    // MARK: Routine channels through the store

    func testTheOriginPicksTheRoutineSoundAndQuietPlaysNone() throws {
        XCTAssertEqual(NotificationSoundChannel.routine(for: .needsYou), .needsYou)
        XCTAssertEqual(NotificationSoundChannel.routine(for: .turnEnd), .turnEnd)
        XCTAssertEqual(NotificationSoundChannel.routine(for: .other), .turnEnd)

        let notifications = TerminalNotificationStore.makeForNotificationCommandTesting()
        var built: [UNNotificationRequest] = []
        var records: [RoutineNotificationRecord] = []
        notifications.configureRoutineNotificationDeliveryHooksForTesting(
            authorization: { $0(true) },
            add: { request, completion in built.append(request); completion(nil) }
        )
        notifications.configureNotificationCustomCommandDefaultsForTesting(settings)
        notifications.configureNotificationSettingsDefaultsForTesting(settings)
        notifications.configureNotificationSoundsForTesting(
            store: store, registry: nil, routineRecord: { records.append($0) }
        )
        settings.set("Ping", forKey: NotificationSoundChannel.needsYou.defaultsKey)
        settings.set("Tink", forKey: NotificationSoundChannel.turnEnd.defaultsKey)

        func routine(_ origin: TerminalNotificationOrigin, sound: Bool = true) -> TerminalNotification {
            TerminalNotification(id: UUID(), workspaceId: UUID(), surfaceId: UUID(), title: "t", subtitle: "", body: "",
                                 createdAt: Date(), isRead: false, deliversSound: sound, origin: origin)
        }
        notifications.scheduleUserNotificationForTesting(routine(.needsYou))
        notifications.scheduleUserNotificationForTesting(routine(.turnEnd))
        notifications.scheduleUserNotificationForTesting(routine(.other))
        notifications.scheduleUserNotificationForTesting(routine(.needsYou, sound: false))
        // The records hop to main; one later hop has them all. The timeout only
        // bounds a stuck run: main under the gate's parallel load took past 2 s.
        let drained = expectation(description: "records hop to main")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 15)

        XCTAssertEqual(built.count, 4)
        XCTAssertEqual(records.map(\.channel), [.needsYou, .turnEnd, .turnEnd, .needsYou])
        XCTAssertEqual(records.map(\.sound.played), [.named("Ping"), .named("Tink"), .named("Tink"), NotificationSoundChoice.none])
        XCTAssertEqual(records.last?.sound.source, .level)
        XCTAssertNil(built.last?.content.sound, "Quiet: a banner with no sound")
        XCTAssertNotNil(built.first?.content.sound)
        XCTAssertEqual(records.first?.payload["channel"] as? String, "needs_you")
        XCTAssertEqual(records.first?.payload["sound"] as? String, "Ping")
        XCTAssertNil(records.first?.payload["title"], "a record carries no text")
    }

    func testANeedsYouPlaysOncePerAsk() throws {
        AppFocusState.overrideIsFocused = false
        defer { AppFocusState.overrideIsFocused = nil }
        let notifications = TerminalNotificationStore.makeForNotificationCommandTesting()
        notifications.configureNotificationSettingsDefaultsForTesting(settings)
        var delivered: [TerminalNotification] = []
        notifications.configureNotificationDeliveryHandlerForTesting { _, notification in delivered.append(notification) }
        let workspace = UUID()
        // Each needs-you as Claude's hooks send it; no clear between asks
        // unless a step says the agent resumed.
        func post(_ panel: UUID, _ title: String, session: String? = "S", request: String? = nil) {
            notifications.addNotification(workspaceId: workspace, surfaceId: panel, title: title, subtitle: "", body: "",
                                          origin: .needsYou, ask: NeedsYouAsk(session: session, request: request))
        }
        func read(_ panel: UUID) { notifications.markRead(forWorkspaceId: workspace, surfaceId: panel) }
        func record(_ panel: UUID) -> TerminalNotification? {
            notifications.notifications.first { $0.workspaceId == workspace && $0.surfaceId == panel }
        }

        // Two request-less asks are two asks: a permission prompt, read, another.
        let a = UUID()
        post(a, "permission: Bash")
        read(a)
        post(a, "permission: Edit")
        XCTAssertEqual(delivered.count, 2, "a second permission prompt sounds")

        // A request after a request-less pending ask is a new ask.
        let b = UUID()
        post(b, "permission: Bash")
        post(b, "question", request: "toolu_b")
        XCTAssertEqual(delivered.count, 4)

        // The read-between case: the hook's accepted ask, read, then Claude's
        // own Notification for it: held, with its text, still read.
        let c = UUID()
        post(c, "accepted question", request: "toolu_c")
        read(c)
        post(c, "Claude needs your input")
        XCTAssertEqual(delivered.count, 5, "reading the notice is not answering: the same ask never sounds twice")
        XCTAssertEqual(record(c)?.title, "Claude needs your input", "the held-back repeat's text replaces the record")
        XCTAssertEqual(record(c)?.isRead, true, "and it does not raise attention again")
        post(c, "the same request again", request: "toolu_c")
        XCTAssertEqual(delivered.count, 5)
        post(c, "next question", request: "toolu_c2")
        XCTAssertEqual(delivered.count, 6, "a new request is a new ask")
        post(c, "other session", session: "S2")
        XCTAssertEqual(delivered.count, 7, "another session is a new ask")

        // Hook to store, no clear between asks: a permission prompt, read; an
        // ordinary post-tool-use and a default-mode AskUserQuestion pre-tool-use
        // send no needs-you; the question's own Notification sounds once.
        let d = UUID()
        post(d, "permission: Bash")
        read(d)
        post(d, "Claude needs your input")
        XCTAssertEqual(delivered.count, 9, "the question after the permission prompt sounds")
        // The same in bypass mode: the accepted managed ask sounds, its own
        // Notification does not.
        let e = UUID()
        post(e, "permission: Bash")
        read(e)
        post(e, "Waiting for input", request: "toolu_e")
        post(e, "Claude needs your input")
        XCTAssertEqual(delivered.count, 11, "exactly one more needs-you for the question")

        // Resuming ends the ask: the same request-less repeat then sounds.
        post(e, "next question", request: "toolu_e2")
        XCTAssertEqual(delivered.count, 12)
        notifications.clearNotifications(forWorkspaceId: workspace, surfaceId: e)  // the agent resumed
        post(e, "permission: Edit")
        XCTAssertEqual(delivered.count, 13, "after resuming, the next ask sounds")

        // A caller that names no ask: each needs-you is its own.
        let f = UUID()
        post(f, "approve migration?", session: nil)
        post(f, "approve deploy?", session: nil)
        XCTAssertEqual(delivered.suffix(2).map(\.title), ["approve migration?", "approve deploy?"])
        XCTAssertEqual(record(f)?.title, "approve deploy?")
    }

    func testTheAskTokenRoundTripsAndRefusesJunk() {
        let ask = NeedsYouAsk(session: "c0ffee-1", request: "toolu_01AbC")
        XCTAssertEqual(ask?.token, "ask=c0ffee-1/toolu_01AbC")
        XCTAssertEqual(NeedsYouAsk(token: "ask=c0ffee-1/toolu_01AbC"), ask)
        XCTAssertEqual(NeedsYouAsk(token: "ask=c0ffee-1/-")?.request, nil)
        XCTAssertEqual(NeedsYouAsk(session: "s", request: nil)?.token, "ask=s/-")
        XCTAssertNil(NeedsYouAsk(token: "ask=-"))
        XCTAssertNil(NeedsYouAsk(token: "ask=has space/r"))
        XCTAssertNil(NeedsYouAsk(session: String(repeating: "x", count: 129), request: nil))
        XCTAssertEqual(NeedsYouAsk(session: "s", request: "bad|pipe")?.request, nil, "a junk request is dropped, not trusted")
        let withRequest = NeedsYouAsk(session: "s", request: "r")!
        let without = NeedsYouAsk(session: "s", request: nil)!
        XCTAssertTrue(without.repeats(withRequest), "Claude's own Notification repeats the accepted ask")
        XCTAssertFalse(without.repeats(without), "two request-less asks are two asks")
        XCTAssertFalse(withRequest.repeats(without), "a request never repeats a request-less ask")
        XCTAssertTrue(withRequest.repeats(withRequest))
        XCTAssertFalse(NeedsYouAsk(session: "s", request: "r2")!.repeats(withRequest))
        XCTAssertFalse(NeedsYouAsk(session: "t", request: nil)!.repeats(withRequest))
    }

    // MARK: Socket and migration

    /// A socket request as an agent sends it, off main.
    private func socket(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let box = SoundTestBox()
        let done = expectation(description: "\(method) answered")
        DispatchQueue.global().async {
            box.response = TerminalController.shared.socketWorkerV2Response(
                TerminalController.V2SocketRequest(id: 319, method: method, params: params)
            )
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let data = try XCTUnwrap(box.response?.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    func testFlagKindSetChangesOnlyTheSoundAndRefusesBeforeImporting() throws {
        let registry = PanelFlagKindRegistry.shared
        let before = registry.kind(id: "merge-issue")
        defer { try? registry.setSound(id: "merge-issue", nil) }

        let set = try socket("flag.kind.set", ["id": "merge-issue", "sound": "Glass"])
        XCTAssertEqual(set["ok"] as? Bool, true, "\(set)")
        let kind = try XCTUnwrap((set["result"] as? [String: Any])?["kind"] as? [String: Any])
        XCTAssertEqual(kind["sound"] as? String, "Glass")
        XCTAssertEqual(registry.sound(id: "merge-issue"), .named("Glass"))
        XCTAssertEqual(registry.kind(id: "merge-issue"), before, "name, color and emoji untouched")

        let original = try tone("refused.wav")
        XCTAssertEqual(errorCode(try socket("flag.kind.set", ["id": "no-such-kind", "sound": "Glass"])), "not_found")
        XCTAssertEqual(errorCode(try socket("flag.kind.set", ["id": "no-such-kind", "sound": original.path])), "not_found")
        XCTAssertEqual(errorCode(try socket("flag.kind.set", ["id": "merge-issue", "sound": "Trumpet"])), "invalid_params")
        XCTAssertEqual(errorCode(try socket("flag.kind.set", [
            "id": "new-kind-\(UUID().uuidString.prefix(6).lowercased())", "name": "X", "color": "blue", "sound": original.path,
        ])), "invalid_params")
        XCTAssertTrue(store.importedIDs().isEmpty, "a refused call stores no file")

        let cleared = try socket("flag.kind.set", ["id": "merge-issue", "sound": "flag"])
        XCTAssertEqual(cleared["ok"] as? Bool, true)
        let clearedKind = try XCTUnwrap((cleared["result"] as? [String: Any])?["kind"] as? [String: Any])
        XCTAssertTrue(clearedKind["sound"] is NSNull, "back on the flag sound")
        XCTAssertNil(registry.sound(id: "merge-issue"))
    }

    /// C11H-330 with C11H-319: a kind carries a sound and evaporate seconds
    /// at once. The seconds belong to the kind, so a sound-only set keeps
    /// them, a set that names them needs a full kind, and every reply
    /// carries both.
    func testFlagKindSetCarriesASoundAndEvaporateSecondsTogether() throws {
        let registry = PanelFlagKindRegistry.shared
        let id = "evap-sound-\(UUID().uuidString.prefix(6).lowercased())"
        defer { try? registry.remove(id: id) }
        func kindReply(_ reply: [String: Any], _ why: String) throws -> [String: Any] {
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(why): \(reply)")
            return try XCTUnwrap((reply["result"] as? [String: Any])?["kind"] as? [String: Any], why)
        }

        let created = try kindReply(try socket("flag.kind.set", [
            "id": id, "name": "Evap Sound", "color": "orange", "sound": "Glass", "evaporate_seconds": 7,
        ]), "create with both")
        XCTAssertEqual(created["evaporate_seconds"] as? Int, 7)
        XCTAssertEqual(created["sound"] as? String, "Glass")
        XCTAssertEqual(created["effective_sound"] as? String, "Glass")
        XCTAssertEqual(registry.kind(id: id)?.evaporateSeconds, 7)
        XCTAssertEqual(registry.sound(id: id), .named("Glass"))

        let soundOnly = try kindReply(try socket("flag.kind.set", ["id": id, "sound": "Ping"]), "sound only")
        XCTAssertEqual(soundOnly["evaporate_seconds"] as? Int, 7, "the reply is the stored kind, seconds included")
        XCTAssertEqual(soundOnly["sound"] as? String, "Ping")
        XCTAssertEqual(registry.kind(id: id)?.evaporateSeconds, 7, "a sound-only set keeps the seconds")

        for (params, why) in [
            (["id": id, "sound": "Glass", "evaporate_seconds": 5] as [String: Any], "seconds with a sound but no kind"),
            (["id": id, "evaporate_seconds": 5] as [String: Any], "seconds alone"),
            (["id": id, "evaporate_seconds": NSNull()] as [String: Any], "a null clear without a kind"),
        ] {
            XCTAssertEqual(errorCode(try socket("flag.kind.set", params)), "invalid_params", why)
        }
        XCTAssertEqual(registry.kind(id: id)?.evaporateSeconds, 7, "a refused set stores nothing")
        XCTAssertEqual(registry.sound(id: id), .named("Ping"), "a refused set stores nothing")

        let redefined = try kindReply(try socket("flag.kind.set", [
            "id": id, "name": "Evap Sound", "color": "orange",
        ]), "kind set without seconds")
        XCTAssertTrue(redefined["evaporate_seconds"] is NSNull, "a kind set replaces the seconds")
        XCTAssertEqual(redefined["sound"] as? String, "Ping", "and leaves the sound")
        XCTAssertNil(registry.kind(id: id)?.evaporateSeconds)

        _ = try kindReply(try socket("flag.kind.set", [
            "id": id, "name": "Evap Sound", "color": "orange", "evaporate_seconds": 12,
        ]), "seconds back")
        let list = try XCTUnwrap((try socket("flag.kind.list", [:])["result"] as? [String: Any])?["kinds"] as? [[String: Any]])
        let listed = try XCTUnwrap(list.first { $0["id"] as? String == id })
        XCTAssertEqual(listed["evaporate_seconds"] as? Int, 12)
        XCTAssertEqual(listed["sound"] as? String, "Ping")
    }

    /// Off main, as the socket worker runs it: the set's write waits for main.
    private func soundSet(_ params: [String: Any]) -> TerminalController.V2CallResult? {
        let settings = self.settings!
        let store = self.store!
        let box = SoundTestBox()
        let done = expectation(description: "notification.sound.set answered")
        DispatchQueue.global().async {
            box.result = TerminalController.v2NotificationSound(
                method: "notification.sound.set", params: params, defaults: settings, store: store
            )
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return box.result
    }

    func testTheSoundSetImportsAPathAndRefusesANoneFlag() throws {
        let original = try tone("library.wav")
        guard case .ok(let payload)? = soundSet(["channel": "needs-you", "sound": original.path]) else {
            return XCTFail("set failed")
        }
        let channels = try XCTUnwrap((payload as? [String: Any])?["channels"] as? [[String: Any]])
        let needsYou = try XCTUnwrap(channels.first { $0["channel"] as? String == "needs-you" })
        let stored = try XCTUnwrap(needsYou["sound"] as? String)
        XCTAssertTrue(stored.hasPrefix("file:"))
        XCTAssertEqual(needsYou["label"] as? String, "library.wav")
        XCTAssertEqual(settings.string(forKey: NotificationSoundChannel.needsYou.defaultsKey), stored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.playbackURL(for: String(stored.dropFirst(5))).path),
                      "setting a file puts its playback copy in place")

        for (sound, why) in [("none", "a soundless flag"), ("Trumpet", "an unknown sound")] {
            guard case .err(let code, let message, _)? = soundSet(["channel": "flag", "sound": sound]) else {
                return XCTFail("\(why) must be refused")
            }
            XCTAssertEqual(code, "invalid_params", "\(why): \(message)")
        }
        XCTAssertEqual(NotificationSoundChannel.flag.choice(defaults: settings), .named("Hero"))
    }

    func testTheInheritedCustomFileBecomesAnImportedSound() throws {
        let original = try tone("old-custom.caf")
        settings.set(NotificationSoundLegacyMigration.legacyCustomFileValue, forKey: NotificationSoundChannel.turnEnd.defaultsKey)
        settings.set(original.path, forKey: NotificationSoundLegacyMigration.legacyCustomFilePathKey)
        let path = try XCTUnwrap(NotificationSoundLegacyMigration.pendingPath(defaults: settings))
        NotificationSoundLegacyMigration.apply(store.importSound(from: URL(fileURLWithPath: path)), path: path, defaults: settings)
        guard case .file(let id) = NotificationSoundChannel.turnEnd.choice(defaults: settings) else {
            return XCTFail("not migrated")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: id).path))
        XCTAssertNil(settings.string(forKey: NotificationSoundLegacyMigration.legacyCustomFilePathKey))
        XCTAssertNil(NotificationSoundLegacyMigration.pendingPath(defaults: settings), "runs once")

        // A path that is gone leaves the shipped default, not silence.
        settings.set(NotificationSoundLegacyMigration.legacyCustomFileValue, forKey: NotificationSoundChannel.turnEnd.defaultsKey)
        NotificationSoundLegacyMigration.apply(.failure(.missingFile(path: "/gone")), path: "/gone", defaults: settings)
        XCTAssertEqual(NotificationSoundChannel.turnEnd.choice(defaults: settings), .named("Bottle"))
    }
}
