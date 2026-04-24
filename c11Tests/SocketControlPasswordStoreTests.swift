import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class SocketControlPasswordStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SocketControlPasswordStore.resetLazyKeychainFallbackCacheForTests()
    }

    override func tearDown() {
        SocketControlPasswordStore.resetLazyKeychainFallbackCacheForTests()
        super.tearDown()
    }

    func testSaveLoadAndClearRoundTripUsesFileStorage() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)

        XCTAssertFalse(SocketControlPasswordStore.hasConfiguredPassword(environment: [:], fileURL: fileURL))

        try SocketControlPasswordStore.savePassword("hunter2", fileURL: fileURL)
        XCTAssertEqual(try SocketControlPasswordStore.loadPassword(fileURL: fileURL), "hunter2")
        XCTAssertTrue(SocketControlPasswordStore.hasConfiguredPassword(environment: [:], fileURL: fileURL))

        try SocketControlPasswordStore.clearPassword(fileURL: fileURL)
        XCTAssertNil(try SocketControlPasswordStore.loadPassword(fileURL: fileURL))
        XCTAssertFalse(SocketControlPasswordStore.hasConfiguredPassword(environment: [:], fileURL: fileURL))
    }

    func testConfiguredPasswordPrefersEnvironmentOverStoredFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)
        try SocketControlPasswordStore.savePassword("stored-secret", fileURL: fileURL)

        let environment = [SocketControlSettings.socketPasswordEnvKey: "env-secret"]
        let configured = SocketControlPasswordStore.configuredPassword(
            environment: environment,
            fileURL: fileURL
        )
        XCTAssertEqual(configured, "env-secret")
    }

    func testConfiguredPasswordLazyKeychainFallbackReadsOnlyOnceAndCaches() {
        var readCount = 0

        let withoutFallback = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: false,
            loadKeychainPassword: {
                readCount += 1
                return "legacy-secret"
            }
        )
        XCTAssertNil(withoutFallback)
        XCTAssertEqual(readCount, 0)

        let firstWithFallback = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return "legacy-secret"
            }
        )
        XCTAssertEqual(firstWithFallback, "legacy-secret")
        XCTAssertEqual(readCount, 1)

        let secondWithFallback = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return "new-secret"
            }
        )
        XCTAssertEqual(secondWithFallback, "legacy-secret")
        XCTAssertEqual(readCount, 1)
    }

    func testConfiguredPasswordLazyKeychainFallbackCachesMissingValue() {
        var readCount = 0

        let first = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return nil
            }
        )
        XCTAssertNil(first)
        XCTAssertEqual(readCount, 1)

        let second = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return "should-not-be-read"
            }
        )
        XCTAssertNil(second)
        XCTAssertEqual(readCount, 1)
    }

    func testConfiguredPasswordPrefersStoredFileOverLazyKeychainFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)
        try SocketControlPasswordStore.savePassword("stored-secret", fileURL: fileURL)

        var readCount = 0
        let configured = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: fileURL,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return "legacy-secret"
            }
        )

        XCTAssertEqual(configured, "stored-secret")
        XCTAssertEqual(readCount, 0)
    }

    func testHasConfiguredAndVerifyReuseSingleLazyKeychainRead() {
        var readCount = 0
        let loader = {
            readCount += 1
            return "legacy-secret"
        }

        XCTAssertTrue(
            SocketControlPasswordStore.hasConfiguredPassword(
                environment: [:],
                fileURL: nil,
                allowLazyKeychainFallback: true,
                loadKeychainPassword: loader
            )
        )
        XCTAssertEqual(readCount, 1)

        XCTAssertTrue(
            SocketControlPasswordStore.verify(
                password: "legacy-secret",
                environment: [:],
                fileURL: nil,
                allowLazyKeychainFallback: true,
                loadKeychainPassword: loader
            )
        )
        XCTAssertEqual(readCount, 1)
    }

    func testDefaultPasswordFileURLUsesCmuxAppSupportPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolved = SocketControlPasswordStore.defaultPasswordFileURL(appSupportDirectory: tempDir)
        XCTAssertEqual(
            resolved?.path,
            tempDir.appendingPathComponent("cmux", isDirectory: true)
                .appendingPathComponent("socket-control-password", isDirectory: false).path
        )
    }

    func testLegacyKeychainMigrationCopiesPasswordDeletesLegacyAndRunsOnlyOnce() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)
        let defaultsSuiteName = "cmux-socket-password-migration-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            XCTFail("Expected isolated UserDefaults suite for migration test")
            return
        }
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        var lookupCount = 0
        var deleteCount = 0

        SocketControlPasswordStore.migrateLegacyKeychainPasswordIfNeeded(
            defaults: defaults,
            fileURL: fileURL,
            loadLegacyPassword: {
                lookupCount += 1
                return "legacy-secret"
            },
            deleteLegacyPassword: {
                deleteCount += 1
                return true
            }
        )

        XCTAssertEqual(try SocketControlPasswordStore.loadPassword(fileURL: fileURL), "legacy-secret")
        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(deleteCount, 1)

        SocketControlPasswordStore.migrateLegacyKeychainPasswordIfNeeded(
            defaults: defaults,
            fileURL: fileURL,
            loadLegacyPassword: {
                lookupCount += 1
                return "new-value"
            },
            deleteLegacyPassword: {
                deleteCount += 1
                return true
            }
        )

        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(try SocketControlPasswordStore.loadPassword(fileURL: fileURL), "legacy-secret")
    }
}

final class CmuxCLIPathInstallerTests: XCTestCase {
    private func makeBundledCLI(in root: URL) throws -> URL {
        let fileManager = FileManager.default
        let url = root
            .appendingPathComponent("c11.app/Contents/Resources/bin/c11", isDirectory: false)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\necho c11\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeDestination(in root: URL) -> URL {
        let destinationURL = root.appendingPathComponent("usr/local/bin/c11", isDirectory: false)
        try? FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return destinationURL
    }

    func testInstallAndUninstallRoundTripWithoutAdministratorPrivileges() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)

        var privilegedInstallCallCount = 0
        var privilegedUninstallCallCount = 0
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { _, _ in privilegedInstallCallCount += 1 },
            privilegedUninstaller: { _ in privilegedUninstallCallCount += 1 }
        )

        let installOutcome = try installer.install()
        XCTAssertFalse(installOutcome.usedAdministratorPrivileges)
        XCTAssertEqual(privilegedInstallCallCount, 0)
        XCTAssertTrue(installer.isInstalled())
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: destinationURL.path),
            bundledCLIURL.path
        )

        let uninstallOutcome = try installer.uninstall()
        XCTAssertFalse(uninstallOutcome.usedAdministratorPrivileges)
        XCTAssertTrue(uninstallOutcome.removedExistingEntry)
        XCTAssertEqual(privilegedUninstallCallCount, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(installer.isInstalled())
    }

    func testInstallFallsBackToAdministratorFlowWhenDestinationIsNotWritable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)
        let destinationDir = destinationURL.deletingLastPathComponent()
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destinationDir.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationDir.path)
        }

        var privilegedInstallCallCount = 0
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { sourceURL, privilegedDestinationURL in
                privilegedInstallCallCount += 1
                XCTAssertEqual(sourceURL.standardizedFileURL, bundledCLIURL.standardizedFileURL)
                XCTAssertEqual(privilegedDestinationURL.standardizedFileURL, destinationURL.standardizedFileURL)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationDir.path)
                try fileManager.createSymbolicLink(at: privilegedDestinationURL, withDestinationURL: sourceURL)
            }
        )

        let installOutcome = try installer.install()
        XCTAssertTrue(installOutcome.usedAdministratorPrivileges)
        XCTAssertEqual(privilegedInstallCallCount, 1)
        XCTAssertTrue(installer.isInstalled())
    }

    func testInstallRefusesWhenDestinationIsUnrelatedSymlink() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)
        let unrelatedTarget = URL(fileURLWithPath: "/bin/ls")
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: unrelatedTarget)

        var privilegedInstallCallCount = 0
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { _, _ in privilegedInstallCallCount += 1 }
        )

        XCTAssertThrowsError(try installer.install()) { error in
            guard case CmuxCLIPathInstaller.InstallerError.destinationNotOwnedByC11 = error else {
                XCTFail("expected destinationNotOwnedByC11 error, got \(error)")
                return
            }
        }
        XCTAssertEqual(privilegedInstallCallCount, 0)
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: destinationURL.path),
            "/bin/ls",
            "destination must not be overwritten"
        )
    }

    func testInstallRefusesWhenDestinationIsRegularFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)
        try "user-owned script".write(to: destinationURL, atomically: true, encoding: .utf8)

        var privilegedInstallCallCount = 0
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { _, _ in privilegedInstallCallCount += 1 }
        )

        XCTAssertThrowsError(try installer.install()) { error in
            guard case CmuxCLIPathInstaller.InstallerError.destinationNotOwnedByC11 = error else {
                XCTFail("expected destinationNotOwnedByC11 error, got \(error)")
                return
            }
        }
        XCTAssertEqual(privilegedInstallCallCount, 0)
    }

    func testInstallReplacesExistingC11Symlink() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)
        // Pre-existing symlink pointing at the same bundled CLI — re-install should succeed.
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: bundledCLIURL)

        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { _, _ in XCTFail("should not escalate") }
        )

        let outcome = try installer.install()
        XCTAssertFalse(outcome.usedAdministratorPrivileges)
        XCTAssertTrue(installer.isInstalled())
    }

    func testInstallAcceptsDanglingC11SymlinkFromMovedBundle() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)
        // Simulate a prior c11.app at a different location that no longer exists.
        let staleTarget = root
            .appendingPathComponent("old-location/c11.app/Contents/Resources/bin/c11", isDirectory: false)
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: staleTarget)

        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { _, _ in XCTFail("should not escalate") }
        )

        let outcome = try installer.install()
        XCTAssertFalse(outcome.usedAdministratorPrivileges)
        XCTAssertTrue(installer.isInstalled())
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: destinationURL.path),
            bundledCLIURL.path
        )
    }

    func testUninstallRefusesWhenDestinationIsUnrelatedSymlink() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)
        let unrelatedTarget = URL(fileURLWithPath: "/bin/ls")
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: unrelatedTarget)

        var privilegedUninstallCallCount = 0
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { _, _ in },
            privilegedUninstaller: { _ in privilegedUninstallCallCount += 1 }
        )

        XCTAssertThrowsError(try installer.uninstall()) { error in
            guard case CmuxCLIPathInstaller.InstallerError.destinationNotOwnedByC11 = error else {
                XCTFail("expected destinationNotOwnedByC11 error, got \(error)")
                return
            }
        }
        XCTAssertEqual(privilegedUninstallCallCount, 0, "privileged path must also be guarded")
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: destinationURL.path),
            "/bin/ls",
            "destination must not be removed"
        )
    }

    func testUninstallRemovesDanglingC11SymlinkFromMovedBundle() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)
        let staleTarget = root
            .appendingPathComponent("old-location/c11.app/Contents/Resources/bin/c11", isDirectory: false)
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: staleTarget)

        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path
        )

        let outcome = try installer.uninstall()
        XCTAssertFalse(outcome.usedAdministratorPrivileges)
        XCTAssertTrue(outcome.removedExistingEntry)
        XCTAssertFalse(fileManager.fileExists(atPath: destinationURL.path))
    }

    func testPrivilegedInstallIsGuardedBySafetyCheck() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("c11-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = try makeBundledCLI(in: root)
        let destinationURL = makeDestination(in: root)
        let destinationDir = destinationURL.deletingLastPathComponent()
        // Put an unrelated symlink AND lock the parent so non-privileged install hits EACCES.
        let unrelatedTarget = URL(fileURLWithPath: "/bin/ls")
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: unrelatedTarget)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destinationDir.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationDir.path)
        }

        var privilegedInstallCallCount = 0
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { _, _ in privilegedInstallCallCount += 1 }
        )

        XCTAssertThrowsError(try installer.install()) { error in
            guard case CmuxCLIPathInstaller.InstallerError.destinationNotOwnedByC11 = error else {
                XCTFail("expected destinationNotOwnedByC11 before privileged handoff, got \(error)")
                return
            }
        }
        XCTAssertEqual(
            privilegedInstallCallCount,
            0,
            "safety check must fire before privileged handoff"
        )
    }
}

final class AgentSkillsOnboardingDefaultOptInTests: XCTestCase {
    func testDefaultsSelectEveryDetectedTarget() {
        let rows = SkillInstallerTarget.allCases.map { target in
            makeRow(target: target, detected: target != .kimi)
        }

        let defaults = AgentSkillsOnboarding.defaultOptIns(for: rows)

        XCTAssertEqual(defaults[.claude], true)
        XCTAssertEqual(defaults[.codex], true)
        XCTAssertEqual(defaults[.kimi], false)
        XCTAssertEqual(defaults[.opencode], true)
    }

    func testMissingTargetsDefaultToFalse() {
        let defaults = AgentSkillsOnboarding.defaultOptIns(for: [
            makeRow(target: .claude, detected: true),
        ])

        XCTAssertEqual(defaults[.claude], true)
        XCTAssertEqual(defaults[.codex], false)
        XCTAssertEqual(defaults[.kimi], false)
        XCTAssertEqual(defaults[.opencode], false)
    }

    func testOfferAppearsOnlyWhenDetectedTargetNeedsInstallOrUpdate() {
        let rows = [
            makeRow(target: .claude, detected: true, states: [.installedCurrent]),
            makeRow(target: .codex, detected: true, states: [.installedOutdated]),
            makeRow(target: .kimi, detected: false, states: [.notInstalled]),
        ]

        XCTAssertTrue(AgentSkillsOnboarding.shouldOffer(for: rows))
    }

    func testOfferIsSuppressedWhenDetectedTargetsAreCurrent() {
        let rows = [
            makeRow(target: .claude, detected: true, states: [.installedCurrent]),
            makeRow(target: .codex, detected: true, states: [.installedCurrent]),
            makeRow(target: .kimi, detected: false, states: [.notInstalled]),
        ]

        XCTAssertFalse(AgentSkillsOnboarding.shouldOffer(for: rows))
    }

    func testSharedDestinationRowsAreNotActionable() {
        let rows = [
            makeRow(target: .claude, detected: true, states: [.installedCurrent]),
            makeRow(target: .codex, detected: true, states: [.installedOutdated], sharedWith: .claude),
        ]

        XCTAssertFalse(AgentSkillsOnboarding.shouldOffer(for: rows))
    }

    private func makeRow(
        target: SkillInstallerTarget,
        detected: Bool,
        states: [SkillInstallerState] = [],
        sharedWith: SkillInstallerTarget? = nil
    ) -> AgentSkillsModel.TargetRow {
        AgentSkillsModel.TargetRow(
            id: target.rawValue,
            target: target,
            detected: detected,
            destinationDir: URL(fileURLWithPath: "/tmp/\(target.rawValue)", isDirectory: true),
            packages: states.map { makeStatus(target: target, state: $0) },
            statusError: nil,
            sharedWithTarget: sharedWith
        )
    }

    private func makeStatus(
        target: SkillInstallerTarget,
        state: SkillInstallerState
    ) -> SkillInstallerPackageStatus {
        let packageDir = URL(fileURLWithPath: "/tmp/source/c11", isDirectory: true)
        let destinationDir = URL(fileURLWithPath: "/tmp/\(target.rawValue)/skills/c11", isDirectory: true)
        return SkillInstallerPackageStatus(
            package: SkillInstallerPackage(name: "c11", version: "1", sourceDir: packageDir),
            target: target,
            destinationDir: destinationDir,
            state: state,
            record: nil,
            sourceContentHash: "sha256:test"
        )
    }
}

final class SkillInstallerPackageVersionTests: XCTestCase {
    func testDiscoverPackagesReadsSkillFrontmatterVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-skill-version-tests-\(UUID().uuidString)", isDirectory: true)
        let packageDir = root.appendingPathComponent("c11", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"installable":["c11"]}
        """.write(
            to: root.appendingPathComponent("MANIFEST.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: c11
        version: 7
        description: test
        ---
        """.write(
            to: packageDir.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let packages = try SkillInstaller.discoverPackages(sourceDir: root)

        XCTAssertEqual(packages.map(\.name), ["c11"])
        XCTAssertEqual(packages.first?.version, "7")
    }
}
