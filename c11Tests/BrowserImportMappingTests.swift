import SQLite3
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class BrowserImportMappingTests: XCTestCase {
    @MainActor
    func testDefaultExecutionPlanUsesSeparateModeForMultipleSourceProfiles() {
        let defaultProfile = BrowserProfileDefinition(
            id: UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!,
            displayName: "Default",
            createdAt: .distantPast,
            isBuiltInDefault: true
        )
        let sourceProfiles = [
            makeSourceProfile(displayName: "You", path: "/tmp/browser-import-you", isDefault: true),
            makeSourceProfile(displayName: "austin", path: "/tmp/browser-import-austin", isDefault: false),
        ]

        let plan = BrowserImportPlanResolver.defaultPlan(
            selectedSourceProfiles: sourceProfiles,
            destinationProfiles: [defaultProfile],
            preferredSingleDestinationProfileID: defaultProfile.id
        )

        XCTAssertEqual(plan.mode, .separateProfiles)
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(plan.entries.map { $0.sourceProfiles.map(\.displayName) }, [["You"], ["austin"]])
    }

    @MainActor
    func testDefaultExecutionPlanUsesSingleDestinationForSingleSourceProfile() {
        let defaultProfileID = UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!
        let sourceProfile = makeSourceProfile(
            displayName: "You",
            path: "/tmp/browser-import-single",
            isDefault: true
        )

        let plan = BrowserImportPlanResolver.defaultPlan(
            selectedSourceProfiles: [sourceProfile],
            destinationProfiles: [],
            preferredSingleDestinationProfileID: defaultProfileID
        )

        XCTAssertEqual(plan.mode, .singleDestination)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].sourceProfiles.map(\.displayName), ["You"])
    }

    @MainActor
    func testSeparatePlanReusesExistingSameNamedDestinationProfiles() {
        let workID = UUID()
        let destinationProfiles = [
            BrowserProfileDefinition(
                id: workID,
                displayName: "You",
                createdAt: .distantPast,
                isBuiltInDefault: false
            )
        ]
        let sourceProfiles = [
            makeSourceProfile(displayName: " you ", path: "/tmp/browser-import-match", isDefault: true)
        ]

        let plan = BrowserImportPlanResolver.separateProfilesPlan(
            selectedSourceProfiles: sourceProfiles,
            destinationProfiles: destinationProfiles
        )

        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].destination, .existing(workID))
    }

    @MainActor
    func testSeparatePlanUsesStableCreateNamesWhenTwoSourceProfilesShareDisplayName() {
        let sourceProfiles = [
            makeSourceProfile(displayName: "Work", path: "/tmp/browser-import-work-1", isDefault: true),
            makeSourceProfile(displayName: "Work", path: "/tmp/browser-import-work-2", isDefault: false),
        ]

        let plan = BrowserImportPlanResolver.separateProfilesPlan(
            selectedSourceProfiles: sourceProfiles,
            destinationProfiles: []
        )

        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(plan.entries[0].destination, .createNamed("Work"))
        XCTAssertEqual(plan.entries[1].destination, .createNamed("Work (2)"))
    }

    func testStep3PresentationShowsPerProfileRowsWhenPlanUsesSeparateMode() {
        let presentation = BrowserImportStep3Presentation(
            plan: BrowserImportExecutionPlan(
                mode: .separateProfiles,
                entries: [
                    BrowserImportExecutionEntry(
                        sourceProfiles: [
                            makeSourceProfile(
                                displayName: "You",
                                path: "/tmp/browser-import-presentation-separate",
                                isDefault: true
                            )
                        ],
                        destination: .createNamed("You")
                    )
                ]
            )
        )

        XCTAssertTrue(presentation.showsSeparateRows)
        XCTAssertFalse(presentation.showsSingleDestinationPicker)
    }

    func testStep3PresentationShowsSingleDestinationPickerWhenPlanUsesMergeMode() {
        let presentation = BrowserImportStep3Presentation(
            plan: BrowserImportExecutionPlan(
                mode: .mergeIntoOne,
                entries: []
            )
        )

        XCTAssertFalse(presentation.showsSeparateRows)
        XCTAssertTrue(presentation.showsSingleDestinationPicker)
    }

    func testSourceProfilesPresentationShrinksListForSmallProfileCounts() {
        let presentation = BrowserImportSourceProfilesPresentation(profileCount: 2)

        XCTAssertEqual(presentation.scrollHeight, 76)
        XCTAssertTrue(presentation.showsHelpText)
    }

    func testSourceProfilesPresentationCapsListHeightAndHidesHelpForSingleProfile() {
        let singleProfilePresentation = BrowserImportSourceProfilesPresentation(profileCount: 1)
        let manyProfilesPresentation = BrowserImportSourceProfilesPresentation(profileCount: 9)

        XCTAssertEqual(singleProfilePresentation.scrollHeight, 76)
        XCTAssertFalse(singleProfilePresentation.showsHelpText)
        XCTAssertEqual(manyProfilesPresentation.scrollHeight, 144)
        XCTAssertTrue(manyProfilesPresentation.showsHelpText)
    }

    func testBrowserImportHintSettingsDefaultToToolbarChip() throws {
        let suiteName = "BrowserImportHintDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presentation = BrowserImportHintSettings.presentation(defaults: defaults)

        XCTAssertEqual(presentation.blankPanelPlacement, .toolbarChip)
        XCTAssertEqual(presentation.settingsStatus, .visible)
    }

    func testBrowserImportHintPresentationHidesBlankTabHintWhenDismissed() {
        let presentation = BrowserImportHintPresentation(
            variant: .floatingCard,
            showOnBlankPanels: true,
            isDismissed: true
        )

        XCTAssertEqual(presentation.blankPanelPlacement, .hidden)
        XCTAssertEqual(presentation.settingsStatus, .hidden)
    }

    func testBrowserImportHintPresentationUsesToolbarChipWhenEnabled() {
        let presentation = BrowserImportHintPresentation(
            variant: .toolbarChip,
            showOnBlankPanels: true,
            isDismissed: false
        )

        XCTAssertEqual(presentation.blankPanelPlacement, .toolbarChip)
        XCTAssertEqual(presentation.settingsStatus, .visible)
    }

    func testBrowserImportHintPresentationSettingsOnlyVariantStaysInSettings() {
        let presentation = BrowserImportHintPresentation(
            variant: .settingsOnly,
            showOnBlankPanels: true,
            isDismissed: false
        )

        XCTAssertEqual(presentation.blankPanelPlacement, .hidden)
        XCTAssertEqual(presentation.settingsStatus, .settingsOnly)
    }

    /// C11-288: native Safari 26.6.2 keeps `title` on `history_visits`; `history_items` has no such column.
    func testSafariHistoryReadsLatestVisitTitleFromRealSchemaAndLeavesSourceUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-288-safari-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("History.db")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let statements = [
            """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE,
              domain_expansion TEXT, visit_count INTEGER NOT NULL, daily_visit_counts BLOB NOT NULL,
              weekly_visit_counts BLOB, autocomplete_triggers BLOB,
              should_recompute_derived_visit_counts INTEGER NOT NULL, visit_count_score INTEGER NOT NULL,
              status_code INTEGER NOT NULL DEFAULT 0)
            """,
            """
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT,
              history_item INTEGER NOT NULL REFERENCES history_items(id), visit_time REAL NOT NULL,
              title TEXT, load_successful BOOLEAN NOT NULL DEFAULT 1, http_non_get BOOLEAN NOT NULL DEFAULT 0,
              synthesized BOOLEAN NOT NULL DEFAULT 0, redirect_source INTEGER, redirect_destination INTEGER,
              origin INTEGER NOT NULL DEFAULT 0, generation INTEGER NOT NULL DEFAULT 0,
              attributes INTEGER NOT NULL DEFAULT 0, score INTEGER NOT NULL DEFAULT 0)
            """,
            "INSERT INTO history_items (id, url, visit_count, daily_visit_counts, should_recompute_derived_visit_counts, visit_count_score) VALUES (1, 'http://127.0.0.1:19288/c11-288', 2, x'', 0, 0)",
            "INSERT INTO history_items (id, url, visit_count, daily_visit_counts, should_recompute_derived_visit_counts, visit_count_score) VALUES (2, 'https://other.example.test/page', 1, x'', 0, 0)",
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (1, 100.0, 'Older title')",
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (1, 200.0, 'Latest title')",
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (2, 300.0, 'Filtered out')",
        ]
        for statement in statements {
            XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        sqlite3_close(database)
        let sourceBefore = try Data(contentsOf: databaseURL)

        let rows = try BrowserDataImporter.readWebKitHistoryRows(
            databaseURL: databaseURL,
            domainFilters: ["127.0.0.1"]
        )

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.url, "http://127.0.0.1:19288/c11-288")
        XCTAssertEqual(row.title, "Latest title")
        XCTAssertEqual(row.visitCount, 2)
        XCTAssertEqual(row.lastVisited, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(try Data(contentsOf: databaseURL), sourceBefore)
    }

    @MainActor
    func testRealizePlanCreatesMissingDestinationProfilesOnlyWhenRequested() throws {
        let suiteName = "BrowserImportMappingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserProfileStore(defaults: defaults)
        let plan = BrowserImportExecutionPlan(
            mode: .separateProfiles,
            entries: [
                BrowserImportExecutionEntry(
                    sourceProfiles: [
                        makeSourceProfile(
                            displayName: "You",
                            path: "/tmp/browser-import-realize-create",
                            isDefault: true
                        )
                    ],
                    destination: .createNamed("You")
                )
            ]
        )

        let realized = try BrowserImportPlanResolver.realize(plan: plan, profileStore: store)

        XCTAssertEqual(realized.createdProfiles.map(\.displayName), ["You"])
        XCTAssertEqual(store.profiles.map(\.displayName), ["Default", "You"])
    }

    @MainActor
    func testRealizePlanReusesExistingProfileInsteadOfCreatingDuplicate() throws {
        let suiteName = "BrowserImportMappingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserProfileStore(defaults: defaults)
        let existing = try XCTUnwrap(store.createProfile(named: "You"))
        let plan = BrowserImportExecutionPlan(
            mode: .separateProfiles,
            entries: [
                BrowserImportExecutionEntry(
                    sourceProfiles: [
                        makeSourceProfile(
                            displayName: "You",
                            path: "/tmp/browser-import-realize-existing",
                            isDefault: true
                        )
                    ],
                    destination: .existing(existing.id)
                )
            ]
        )

        let realized = try BrowserImportPlanResolver.realize(plan: plan, profileStore: store)

        XCTAssertTrue(realized.createdProfiles.isEmpty)
        XCTAssertEqual(realized.entries[0].destinationProfileID, existing.id)
    }

    func testAggregateOutcomeIncludesOneMappingLinePerDestination() {
        let outcome = BrowserImportOutcome(
            browserName: "Helium",
            scope: .cookiesAndHistory,
            domainFilters: [],
            createdDestinationProfileNames: ["You", "austin"],
            entries: [
                BrowserImportOutcomeEntry(
                    sourceProfileNames: ["You"],
                    destinationProfileName: "You",
                    importedCookies: 10,
                    skippedCookies: 0,
                    importedHistoryEntries: 20,
                    warnings: []
                ),
                BrowserImportOutcomeEntry(
                    sourceProfileNames: ["austin"],
                    destinationProfileName: "austin",
                    importedCookies: 5,
                    skippedCookies: 1,
                    importedHistoryEntries: 9,
                    warnings: []
                ),
            ],
            warnings: []
        )

        let lines = BrowserImportOutcomeFormatter.lines(for: outcome)

        XCTAssertTrue(lines.contains("You -> You"))
        XCTAssertTrue(lines.contains("austin -> austin"))
        XCTAssertTrue(lines.contains("Created c11 profiles: You, austin"))
    }

    @MainActor
    func testImportWizardCanBeConstructedForSettingsChoosePath() {
        let destinationProfiles = [
            BrowserProfileDefinition(
                id: UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!,
                displayName: "Default",
                createdAt: .distantPast,
                isBuiltInDefault: true
            )
        ]
        let browser = makeInstalledBrowserCandidate(
            descriptorID: "google-chrome",
            displayName: "Chrome",
            profiles: [
                makeSourceProfile(displayName: "Default", path: "/tmp/browser-import-chrome-default", isDefault: true),
                makeSourceProfile(displayName: "Profile 1", path: "/tmp/browser-import-chrome-profile-1", isDefault: false),
            ]
        )

        let window = BrowserDataImportCoordinator.shared.debugMakeImportWizardWindow(
            browsers: [browser],
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: destinationProfiles[0].id
        )
        defer {
            window.orderOut(nil)
            window.close()
        }

        XCTAssertEqual(window.title, "Import Browser Data")
        XCTAssertNotNil(window.contentView)
    }

    private func makeSourceProfile(displayName: String, path: String, isDefault: Bool) -> InstalledBrowserProfile {
        InstalledBrowserProfile(
            displayName: displayName,
            rootURL: URL(fileURLWithPath: path, isDirectory: true),
            isDefault: isDefault
        )
    }

    private func makeInstalledBrowserCandidate(
        descriptorID: String,
        displayName: String,
        profiles: [InstalledBrowserProfile]
    ) -> InstalledBrowserCandidate {
        let descriptor = try! XCTUnwrap(InstalledBrowserDetector.allBrowserDescriptors.first(where: { $0.id == descriptorID }))
        return InstalledBrowserCandidate(
            descriptor: BrowserImportBrowserDescriptor(
                id: descriptor.id,
                displayName: displayName,
                family: descriptor.family,
                tier: descriptor.tier,
                bundleIdentifiers: descriptor.bundleIdentifiers,
                appNames: descriptor.appNames,
                dataRootRelativePaths: descriptor.dataRootRelativePaths,
                dataArtifactRelativePaths: descriptor.dataArtifactRelativePaths,
                supportsDataOnlyDetection: descriptor.supportsDataOnlyDetection
            ),
            resolvedFamily: descriptor.family,
            homeDirectoryURL: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            appURL: nil,
            dataRootURL: URL(fileURLWithPath: "/tmp/browser-import-\(descriptorID)", isDirectory: true),
            profiles: profiles,
            detectionSignals: ["test"],
            detectionScore: 1
        )
    }
}
