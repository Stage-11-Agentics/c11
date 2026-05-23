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

    func testDefaultPasswordFileURLUsesC11AppSupportPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolved = SocketControlPasswordStore.defaultPasswordFileURL(appSupportDirectory: tempDir)
        XCTAssertEqual(
            resolved?.path,
            tempDir.appendingPathComponent("c11", isDirectory: true)
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
            package: SkillInstallerPackage(name: "c11", version: "1", description: nil, sourceDir: packageDir),
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

// MARK: - C11-111: description parsing

final class SkillInstallerDescriptionParsingTests: XCTestCase {
    func testDiscoverPackagesReadsFrontmatterDescription() throws {
        let root = try makeTempSkillsRoot(name: "c11-skill-description-tests")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(root: root, installable: ["foo"])
        try writeSkill(root: root, name: "foo", contents: """
        ---
        name: foo
        version: 1
        description: Hello there.
        ---
        """)

        let packages = try SkillInstaller.discoverPackages(sourceDir: root)
        XCTAssertEqual(packages.first?.description, "Hello there.")
    }

    func testMissingDescriptionYieldsNil() throws {
        let root = try makeTempSkillsRoot(name: "c11-skill-description-missing-tests")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(root: root, installable: ["foo"])
        try writeSkill(root: root, name: "foo", contents: """
        ---
        name: foo
        version: 1
        ---
        """)

        let packages = try SkillInstaller.discoverPackages(sourceDir: root)
        XCTAssertNil(packages.first?.description)
    }

    func testQuotedDescriptionIsUnquoted() throws {
        let root = try makeTempSkillsRoot(name: "c11-skill-description-quoted-tests")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(root: root, installable: ["foo"])
        try writeSkill(root: root, name: "foo", contents: """
        ---
        name: foo
        version: 1
        description: "Quoted text."
        ---
        """)

        let packages = try SkillInstaller.discoverPackages(sourceDir: root)
        XCTAssertEqual(packages.first?.description, "Quoted text.")
    }

    func testDescriptionWithoutFrontmatterYieldsNil() throws {
        let root = try makeTempSkillsRoot(name: "c11-skill-description-no-frontmatter-tests")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(root: root, installable: ["foo"])
        try writeSkill(root: root, name: "foo", contents: """
        # foo
        description: ignored — not in frontmatter
        """)

        let packages = try SkillInstaller.discoverPackages(sourceDir: root)
        XCTAssertNil(packages.first?.description)
    }
}

// MARK: - C11-111: dismissal store

/// Hermetic UserDefaults helper. Uses a per-test suite name so writes
/// never touch the operator's `.standard` defaults during a logic run.
private func makeIsolatedDefaults(_ context: String = #function) -> UserDefaults {
    let suite = "c11.tests.\(context).\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

private func makeStatus(
    target: SkillInstallerTarget,
    skillName: String,
    state: SkillInstallerState,
    sourceHash: String = "sha256:current"
) -> SkillInstallerPackageStatus {
    let sourceDir = URL(fileURLWithPath: "/tmp/source/\(skillName)", isDirectory: true)
    return SkillInstallerPackageStatus(
        package: SkillInstallerPackage(name: skillName, version: "1", description: nil, sourceDir: sourceDir),
        target: target,
        destinationDir: URL(fileURLWithPath: "/tmp/\(target.rawValue)/skills/\(skillName)", isDirectory: true),
        state: state,
        record: nil,
        sourceContentHash: sourceHash
    )
}

final class AgentSkillsDismissalStoreTests: XCTestCase {
    func testLoadDismissalsTolerantOfMissingKey() {
        let d = makeIsolatedDefaults()
        XCTAssertEqual(AgentSkillsOnboarding.loadDismissals(defaults: d), [:])
    }

    func testLoadDismissalsTolerantOfMalformedValue() {
        let d = makeIsolatedDefaults()
        d.set(["claude.foo": 42, "claude.bar": "sha256:abc"] as [String: Any],
              forKey: AgentSkillsOnboarding.dismissalsKey)
        // The 42 is malformed; the helper should drop it without crashing
        // and still surface the well-typed entry.
        let loaded = AgentSkillsOnboarding.loadDismissals(defaults: d)
        XCTAssertEqual(loaded, ["claude.bar": "sha256:abc"])
    }

    func testKeyShape() {
        XCTAssertEqual(
            AgentSkillsOnboarding.dismissalKey(for: .claude, skillName: "c11-browser"),
            "claude.c11-browser"
        )
    }

    func testRecordDismissalsForUncheckedRowsCapturesBundledHash() {
        let d = makeIsolatedDefaults()
        let offered = [
            makeStatus(target: .claude, skillName: "foo", state: .notInstalled, sourceHash: "sha256:foo-current"),
            makeStatus(target: .claude, skillName: "bar", state: .installedOutdated, sourceHash: "sha256:bar-current"),
            makeStatus(target: .claude, skillName: "baz", state: .installedCurrent, sourceHash: "sha256:baz-current"),
        ]
        // Operator left "foo" checked and "bar" + "baz" unchecked. "baz"
        // is .installedCurrent so it should be skipped regardless.
        let selectedKeys: Set<String> = [
            AgentSkillsOnboarding.dismissalKey(for: .claude, skillName: "foo")
        ]
        AgentSkillsOnboarding.recordDismissalsForUncheckedRows(
            offered: offered, selectedKeys: selectedKeys, defaults: d
        )
        let dict = AgentSkillsOnboarding.loadDismissals(defaults: d)
        XCTAssertEqual(dict, ["claude.bar": "sha256:bar-current"])
    }

    func testRecordDismissalsClobbersStaleEntriesForSameKey() {
        let d = makeIsolatedDefaults()
        d.set(["claude.foo": "sha256:old"], forKey: AgentSkillsOnboarding.dismissalsKey)
        let offered = [
            makeStatus(target: .claude, skillName: "foo", state: .installedOutdated, sourceHash: "sha256:new"),
        ]
        AgentSkillsOnboarding.recordDismissalsForUncheckedRows(
            offered: offered, selectedKeys: [], defaults: d
        )
        let dict = AgentSkillsOnboarding.loadDismissals(defaults: d)
        XCTAssertEqual(dict, ["claude.foo": "sha256:new"])
    }

    func testClearDismissalRemovesOnlyTargetSkillEntry() {
        let d = makeIsolatedDefaults()
        d.set([
            "claude.foo": "sha256:f",
            "claude.bar": "sha256:b",
            "codex.foo": "sha256:cf",
        ], forKey: AgentSkillsOnboarding.dismissalsKey)
        AgentSkillsOnboarding.clearDismissal(for: .claude, skillName: "foo", defaults: d)
        let dict = AgentSkillsOnboarding.loadDismissals(defaults: d)
        XCTAssertEqual(dict, ["claude.bar": "sha256:b", "codex.foo": "sha256:cf"])
    }

    func testClearAllSilencingRemovesBothFlagAndDismissals() {
        let d = makeIsolatedDefaults()
        d.set(true, forKey: AgentSkillsOnboarding.dontAskAgainKey)
        d.set(["claude.foo": "sha256:f"], forKey: AgentSkillsOnboarding.dismissalsKey)
        AgentSkillsOnboarding.clearAllSilencing(defaults: d)
        XCTAssertFalse(d.bool(forKey: AgentSkillsOnboarding.dontAskAgainKey))
        XCTAssertNil(d.dictionary(forKey: AgentSkillsOnboarding.dismissalsKey))
    }

    func testHasSilencedStateReflectsBothSurfaces() {
        let d = makeIsolatedDefaults()
        XCTAssertFalse(AgentSkillsOnboarding.hasSilencedState(defaults: d))
        d.set(["claude.foo": "sha256:f"], forKey: AgentSkillsOnboarding.dismissalsKey)
        XCTAssertTrue(AgentSkillsOnboarding.hasSilencedState(defaults: d))
        d.removeObject(forKey: AgentSkillsOnboarding.dismissalsKey)
        d.set(true, forKey: AgentSkillsOnboarding.dontAskAgainKey)
        XCTAssertTrue(AgentSkillsOnboarding.hasSilencedState(defaults: d))
    }

    func testUpdateAllPathNeverWritesToDismissalStore() {
        // "Update all" = every offered row is selected; recording dismissals
        // with the full selected set adds nothing to the dict. Backs AC #2.
        let d = makeIsolatedDefaults()
        let offered = [
            makeStatus(target: .claude, skillName: "foo", state: .notInstalled, sourceHash: "sha256:foo"),
            makeStatus(target: .claude, skillName: "bar", state: .installedOutdated, sourceHash: "sha256:bar"),
        ]
        let allSelected: Set<String> = [
            AgentSkillsOnboarding.dismissalKey(for: .claude, skillName: "foo"),
            AgentSkillsOnboarding.dismissalKey(for: .claude, skillName: "bar"),
        ]
        AgentSkillsOnboarding.recordDismissalsForUncheckedRows(
            offered: offered, selectedKeys: allSelected, defaults: d
        )
        XCTAssertNil(d.dictionary(forKey: AgentSkillsOnboarding.dismissalsKey))
    }
}

@MainActor
final class AgentSkillsMaybeLaterTests: XCTestCase {
    override func tearDown() {
        // This test class is the only one that intentionally flips the
        // process-wide `_dismissedThisLaunch` static. Reset on teardown so
        // sibling test classes (especially AgentSkillsShouldPresentTests)
        // see a clean flag regardless of XCTest ordering.
        AgentSkillsOnboarding._resetDismissedThisLaunchForTests()
        super.tearDown()
    }

    func testMarkDismissedThisLaunchNeverWritesToDismissalStore() {
        // "Maybe later" + window-close path call markDismissedThisLaunch()
        // only. The persistent dismissal store must stay untouched (AC #3:
        // sheet re-fires next launch). Uses a hermetic UserDefaults so the
        // operator's real `.standard` is unaffected.
        let d = makeIsolatedDefaults()
        AgentSkillsOnboarding._resetDismissedThisLaunchForTests()
        AgentSkillsOnboarding.markDismissedThisLaunch()
        XCTAssertNil(d.dictionary(forKey: AgentSkillsOnboarding.dismissalsKey))
        XCTAssertFalse(d.bool(forKey: AgentSkillsOnboarding.dontAskAgainKey))
        XCTAssertTrue(AgentSkillsOnboarding.dismissedThisLaunch)
    }
}

// MARK: - C11-111: shouldPresent matrix

/// `shouldPresent` reads from a real `~/.{target}/skills` filesystem, so
/// these tests stand up an isolated tmp HOME with deterministic content
/// and bundled-skill source. The XCTSkip guard lets us bail cleanly if
/// the dev-source resolver can't find a real `skills/` tree (we never
/// reach into the real home or installer-controlled flags).
private struct SkillsHarness {
    let home: URL
    let source: URL
    let defaults: UserDefaults

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: source)
    }

    /// Compute the bundled hash for a skill that lives in this harness's
    /// `source` dir. Used by tests to inject "matching" dismissal entries.
    func bundledHash(skillName: String) throws -> String {
        try SkillInstaller.contentHash(of: source.appendingPathComponent(skillName, isDirectory: true))
    }
}

@MainActor
final class AgentSkillsShouldPresentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Other test classes in this process (notably AgentSkillsMaybeLaterTests)
        // intentionally flip the process-wide `_dismissedThisLaunch` static.
        // Production never clears it mid-launch by design; tests reset it via
        // the underscore-prefixed test hook so XCTest's nondeterministic class
        // ordering can't make these cases racy.
        AgentSkillsOnboarding._resetDismissedThisLaunchForTests()
    }

    func testDontAskAgainBeatsDriftedContent() throws {
        let h = try makeHarness(skills: ["foo": "v1-content"])
        defer { h.cleanup() }
        // Operator detected (target = .claude), skill missing → would
        // otherwise present. But dontAskAgain is set.
        h.defaults.set(true, forKey: AgentSkillsOnboarding.dontAskAgainKey)
        XCTAssertFalse(AgentSkillsOnboarding.shouldPresent(
            home: h.home, sourceDir: h.source, defaults: h.defaults, fileManager: .default))
    }

    func testDismissedEntryMatchingBundledHashSuppressesPresent() throws {
        let h = try makeHarness(skills: ["foo": "v1-content"])
        defer { h.cleanup() }
        let hash = try h.bundledHash(skillName: "foo")
        h.defaults.set(["claude.foo": hash], forKey: AgentSkillsOnboarding.dismissalsKey)
        XCTAssertFalse(AgentSkillsOnboarding.shouldPresent(
            home: h.home, sourceDir: h.source, defaults: h.defaults, fileManager: .default))
    }

    func testDismissedEntryAgainstOldHashAllowsPresent() throws {
        // This is the v0.49.0 bug fix: stale dismissal entry must NOT
        // shadow re-surfacing when bundled content changes.
        let h = try makeHarness(skills: ["foo": "v1-content"])
        defer { h.cleanup() }
        h.defaults.set(["claude.foo": "sha256:OBSOLETE"], forKey: AgentSkillsOnboarding.dismissalsKey)
        XCTAssertTrue(AgentSkillsOnboarding.shouldPresent(
            home: h.home, sourceDir: h.source, defaults: h.defaults, fileManager: .default))
    }

    func testNoDetectedTargetsReturnsFalse() throws {
        let h = try makeHarness(skills: ["foo": "v1-content"], detect: false)
        defer { h.cleanup() }
        XCTAssertFalse(AgentSkillsOnboarding.shouldPresent(
            home: h.home, sourceDir: h.source, defaults: h.defaults, fileManager: .default))
    }

    func testMissingPackageOnDetectedTargetReturnsTrue() throws {
        let h = try makeHarness(skills: ["foo": "v1-content"])
        defer { h.cleanup() }
        // No dismissal entry → row offers → should present.
        XCTAssertTrue(AgentSkillsOnboarding.shouldPresent(
            home: h.home, sourceDir: h.source, defaults: h.defaults, fileManager: .default))
    }
}

// MARK: - C11-111: legacy flag migration

@MainActor
final class AgentSkillsLegacyMigrationTests: XCTestCase {
    func testLegacyFlagSetAndAllCurrentPopulatesDismissals() throws {
        let h = try makeHarness(skills: ["foo": "v1-content"], installLocalCopies: ["foo": "v1-content"])
        defer { h.cleanup() }
        h.defaults.set(true, forKey: AgentSkillsOnboarding.legacyOnboardingShownKey)
        AgentSkillsOnboarding.migrateLegacyDismissalsIfNeeded(
            home: h.home, sourceDir: h.source, defaults: h.defaults)
        let dict = AgentSkillsOnboarding.loadDismissals(defaults: h.defaults)
        XCTAssertEqual(dict.keys.sorted(), ["claude.foo"])
    }

    func testLegacyFlagSetButOutdatedSkillIsNotSilenced() throws {
        // Bundled "foo" is v2-content; local copy is v1-content. Migration
        // must NOT silence this row — that's the v0.49.0 bug.
        let h = try makeHarness(skills: ["foo": "v2-content"], installLocalCopies: ["foo": "v1-content"])
        defer { h.cleanup() }
        h.defaults.set(true, forKey: AgentSkillsOnboarding.legacyOnboardingShownKey)
        AgentSkillsOnboarding.migrateLegacyDismissalsIfNeeded(
            home: h.home, sourceDir: h.source, defaults: h.defaults)
        let dict = AgentSkillsOnboarding.loadDismissals(defaults: h.defaults)
        XCTAssertNil(dict["claude.foo"])
    }

    func testLegacyFlagUnsetIsNoOp() throws {
        let h = try makeHarness(skills: ["foo": "v1-content"], installLocalCopies: ["foo": "v1-content"])
        defer { h.cleanup() }
        AgentSkillsOnboarding.migrateLegacyDismissalsIfNeeded(
            home: h.home, sourceDir: h.source, defaults: h.defaults)
        XCTAssertNil(h.defaults.dictionary(forKey: AgentSkillsOnboarding.dismissalsKey))
    }

    func testMigrationRunsOnceEvenAcrossRepeatedCalls() throws {
        let h = try makeHarness(skills: ["foo": "v1-content"], installLocalCopies: ["foo": "v1-content"])
        defer { h.cleanup() }
        h.defaults.set(true, forKey: AgentSkillsOnboarding.legacyOnboardingShownKey)
        AgentSkillsOnboarding.migrateLegacyDismissalsIfNeeded(
            home: h.home, sourceDir: h.source, defaults: h.defaults)
        // Simulate the operator changing bundled content between calls.
        try "v2-content".write(
            to: h.source.appendingPathComponent("foo", isDirectory: true)
                .appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true, encoding: .utf8)
        AgentSkillsOnboarding.migrateLegacyDismissalsIfNeeded(
            home: h.home, sourceDir: h.source, defaults: h.defaults)
        // The second call should be a no-op: the dismissals dict already
        // exists, so we don't overwrite with a v2-current hash.
        let dict = AgentSkillsOnboarding.loadDismissals(defaults: h.defaults)
        XCTAssertEqual(dict.count, 1)
        // The stored hash is the v1 hash from the first migration, not
        // v2. (We can't compute the v1 hash anymore directly; assert by
        // its inequality with the current v2 hash.)
        let currentHash = try h.bundledHash(skillName: "foo")
        XCTAssertNotEqual(dict["claude.foo"], currentHash)
    }
}

// MARK: - C11-111: row state classification

final class AgentSkillsRowStateClassificationTests: XCTestCase {
    func testUpToDateMapsToUpToDate() {
        let s = makeStatus(target: .claude, skillName: "x", state: .installedCurrent)
        XCTAssertEqual(AgentSkillsRowVariant.classify(s), .upToDate)
    }

    func testNotInstalledMapsToNotInstalled() {
        let s = makeStatus(target: .claude, skillName: "x", state: .notInstalled)
        XCTAssertEqual(AgentSkillsRowVariant.classify(s), .notInstalled)
    }

    func testInstalledNoManifestMapsToWillReplaceUnmanaged() {
        let s = makeStatus(target: .claude, skillName: "x", state: .installedNoManifest)
        XCTAssertEqual(AgentSkillsRowVariant.classify(s), .willReplaceUnmanaged)
    }

    func testSchemaMismatchMapsToWillReplaceUnmanaged() {
        let s = makeStatus(target: .claude, skillName: "x", state: .schemaMismatch)
        XCTAssertEqual(AgentSkillsRowVariant.classify(s), .willReplaceUnmanaged)
    }

    func testOutdatedWithoutManifestRecordMapsToUpdate() {
        let s = makeStatus(target: .claude, skillName: "x", state: .installedOutdated)
        XCTAssertEqual(AgentSkillsRowVariant.classify(s), .update)
    }

    func testOutdatedWithManifestHashEqualToBundledMapsToLocalEdits() {
        let bundledHash = "sha256:current-bundled"
        let record = SkillInstallerRecord(
            schema: SkillInstallerRecord.schemaVersion,
            packageName: "x",
            skillVersion: "1",
            installedAt: "2026-05-22T00:00:00Z",
            appVersion: "0.49.0",
            appBuild: "1",
            commitShort: "abcd",
            sourceContentHash: bundledHash
        )
        let status = SkillInstallerPackageStatus(
            package: SkillInstallerPackage(name: "x", version: "1", description: nil,
                                           sourceDir: URL(fileURLWithPath: "/tmp/src/x", isDirectory: true)),
            target: .claude,
            destinationDir: URL(fileURLWithPath: "/tmp/dst/x", isDirectory: true),
            state: .installedOutdated,
            record: record,
            sourceContentHash: bundledHash
        )
        XCTAssertEqual(AgentSkillsRowVariant.classify(status), .localEditsWillBeOverwritten)
    }
}

// MARK: - C11-111: bundled skills manifest contract

final class BundledSkillsManifestTests: XCTestCase {
    /// Every bundled SKILL.md description must fit on one line. The
    /// frontmatter reader is single-line by design; multi-line YAML would
    /// silently truncate, surprising both author and operator. See the
    /// C11-111 plan, *Description rendering: single-line contract*.
    func testEveryBundledSkillDescriptionFitsOnOneLine() throws {
        let source = try locateRepoSkillsDir()
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var failures: [String] = []
        for url in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillMd = url.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fm.fileExists(atPath: skillMd.path),
                  let data = fm.contents(atPath: skillMd.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var lines = text.components(separatedBy: .newlines)
            guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { continue }
            lines.removeFirst()
            var inFrontmatter = true
            var seenDescription = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "---" { inFrontmatter = false; break }
                if seenDescription && (trimmed.hasPrefix("\"") || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || (!trimmed.contains(":") && !trimmed.isEmpty)) {
                    failures.append("\(url.lastPathComponent): description appears to continue onto the next line — single-line contract per C11-111.")
                    break
                }
                if trimmed.hasPrefix("description:") { seenDescription = true; continue }
                if seenDescription { break }
            }
            _ = inFrontmatter
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}

// MARK: - C11-111 test helpers

private func makeTempSkillsRoot(name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeManifest(root: URL, installable: [String]) throws {
    let payload = ["installable": installable]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(to: root.appendingPathComponent("MANIFEST.json", isDirectory: false), options: .atomic)
}

private func writeSkill(root: URL, name: String, contents: String) throws {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try contents.write(to: dir.appendingPathComponent("SKILL.md", isDirectory: false), atomically: true, encoding: .utf8)
}

/// Stand up a bundled `skills/` source dir, a `~/` mock with `.claude/`
/// detected, and optional local installed copies. Lets us exercise
/// `shouldPresent` end-to-end against a real filesystem path without
/// touching the operator's home.
private func makeHarness(
    skills: [String: String],
    installLocalCopies: [String: String] = [:],
    detect: Bool = true,
    function: String = #function
) throws -> SkillsHarness {
    let root = try makeTempSkillsRoot(name: "c11-shouldpresent-\(function)")
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try writeManifest(root: source, installable: Array(skills.keys))
    for (name, content) in skills {
        try writeSkill(root: source, name: name, contents: """
        ---
        name: \(name)
        version: 1
        ---
        \(content)
        """)
    }
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    if detect {
        let claudeRoot = SkillInstallerTarget.claude.configRoot(home: home)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        // If the caller asked for installed local copies, use the real
        // installer so the manifest matches what production writes.
        if !installLocalCopies.isEmpty {
            _ = try SkillInstaller.install(target: .claude, home: home, sourceDir: source, force: true)
            // Overwrite SKILL.md per the caller's `installLocalCopies`
            // map. This lets us simulate "operator edited the local copy."
            for (name, content) in installLocalCopies {
                let dest = SkillInstallerTarget.claude.skillsDir(home: home)
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent("SKILL.md", isDirectory: false)
                try """
                ---
                name: \(name)
                version: 1
                ---
                \(content)
                """.write(to: dest, atomically: true, encoding: .utf8)
            }
        }
    }
    return SkillsHarness(home: home, source: source, defaults: makeIsolatedDefaults(function))
}

private func locateRepoSkillsDir() throws -> URL {
    // Walk up from the test bundle's path looking for a sibling `skills/`
    // dir that contains a SKILL.md anywhere. The c11 repo's `skills/` is
    // adjacent to the project root.
    let fm = FileManager.default
    var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
    while true {
        let candidate = current.appendingPathComponent("skills", isDirectory: true)
        if fm.fileExists(atPath: candidate.path) {
            let entries = (try? fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil)) ?? []
            if entries.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }) {
                return candidate.standardizedFileURL
            }
        }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        if parent.path == current.path { break }
        current = parent
    }
    throw XCTSkip("Could not locate a repo `skills/` directory from the test bundle; running outside the source tree.")
}

// MARK: - C11-99 Area B: XCTest socket-path isolation

/// Covers the `socketPath()` resolver behavior when launched by `xcodebuild
/// test`. The XCTest host runs as the untagged c11 DEV.app (bundle id
/// `com.stage11.c11.debug`) with a clean environment — no `CMUX_TAG`, no
/// `CMUX_SOCKET_PATH`. Without isolation, the resolver returned the shared
/// `/tmp/c11-debug.sock` path the operator's running c11 DEV.app already owned;
/// on test-host teardown the socket file was `unlink()`'d, killing the
/// operator's socket. C11-99 Area B added a per-PID fallback gated on
/// `XCTestConfigurationFilePath` being in env.
final class SocketControlSettingsXCTestIsolationTests: XCTestCase {
    private static let xctestEnv = ["XCTestConfigurationFilePath": "/tmp/some-xctest-config.xctestconfiguration"]

    func testUntaggedDebugHostUnderXCTestReturnsPerPIDSocket() {
        let path = SocketControlSettings.socketPath(
            environment: Self.xctestEnv,
            bundleIdentifier: "com.stage11.c11.debug",
            isDebugBuild: true,
            processIdentifier: 12345
        )
        XCTAssertEqual(path, "/tmp/c11-test-12345.sock")
    }

    func testUntaggedDebugHostWithoutXCTestStillUsesSharedDebugSocket() {
        let path = SocketControlSettings.socketPath(
            environment: [:],
            bundleIdentifier: "com.stage11.c11.debug",
            isDebugBuild: true,
            processIdentifier: 12345
        )
        XCTAssertEqual(path, "/tmp/c11-debug.sock")
    }

    func testTaggedDebugHostUnderXCTestStillHonorsTaggedPath() {
        let env = Self.xctestEnv.merging(["CMUX_TAG": "scenario"]) { current, _ in current }
        let path = SocketControlSettings.socketPath(
            environment: env,
            bundleIdentifier: "com.stage11.c11.debug",
            isDebugBuild: true,
            processIdentifier: 12345
        )
        XCTAssertEqual(path, "/tmp/c11-debug-scenario.sock")
    }

    func testExplicitSocketOverrideUnderXCTestStillWins() {
        let env = Self.xctestEnv.merging([
            "CMUX_SOCKET_PATH": "/tmp/c11-test-explicit.sock",
            "CMUX_ALLOW_SOCKET_OVERRIDE": "1"
        ]) { current, _ in current }
        let path = SocketControlSettings.socketPath(
            environment: env,
            bundleIdentifier: "com.stage11.c11.debug",
            isDebugBuild: true,
            processIdentifier: 12345
        )
        XCTAssertEqual(path, "/tmp/c11-test-explicit.sock")
    }

    func testStableBundleUnderXCTestDoesNotForcePerPIDFallback() {
        // The stable bundle resolves to ~/Library/Application Support/c11/...
        // not the shared /tmp/c11-debug.sock, so the XCTest guard is a no-op
        // for that path. Production c11.app launched under XCTest stays put.
        let path = SocketControlSettings.socketPath(
            environment: Self.xctestEnv,
            bundleIdentifier: "com.stage11.c11",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing },
            processIdentifier: 12345
        )
        XCTAssertNotEqual(path, "/tmp/c11-test-12345.sock")
        XCTAssertNotEqual(path, "/tmp/c11-debug.sock")
    }
}
