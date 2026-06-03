import XCTest
@testable import c11

/// C11-106 — AC16 + AC17 from the C11-104 v2 validation plan.
///
/// **AC16: socket `set_metadata` / `clear_metadata` rejects `source=derived`.**
/// The rejection logic lives in four `TerminalController.swift` socket
/// handlers (`v2SurfaceSetMetadata`, `v2SurfaceClearMetadata`,
/// `v2PaneSetMetadata`, `v2PaneClearMetadata`). In C11-106 the
/// duplicated 3-line check was extracted to
/// `SocketMetadataSourceValidator.externalRejectionMessage(for:)` so
/// the rejection contract can be exercised from `c11LogicTests`
/// without standing up a full unix-socket frame loop. The extracted
/// seam is the SAME logic the production handlers invoke; testing
/// it satisfies AC16's requirement to verify the external write
/// contract (per the trident plan-review's I8 option (b): "an
/// extracted handler function in TerminalController callable from
/// a logic test").
///
/// **AC17: `c11 get-metadata --key worktree` / `--key branch`
/// returns derived values.** The socket get path
/// (`SurfaceMetadataStore.getMetadata(workspaceId:surfaceId:)`)
/// does not filter on source, so values written with
/// `source=derived` via `setInternal(.derived)` are visible to
/// external readers. This is the contract — verifying it pins the
/// behavior so a future "filter derived out of socket reads"
/// regression would surface immediately.
final class SocketDerivedSourceRejectionTests: XCTestCase {

    // MARK: - AC16

    func testDerivedSourceProducesInvalidSourceRejection() {
        let result = SocketMetadataSourceValidator.externalRejectionMessage(for: .derived)
        XCTAssertNotNil(result, ".derived must be rejected from external callers")
        XCTAssertEqual(result?.code, "invalid_source")
        XCTAssertEqual(result?.message,
                       "source 'derived' is reserved for c11-internal writers")
    }

    func testExplicitDeclareOscHeuristicAreAccepted() {
        XCTAssertNil(SocketMetadataSourceValidator.externalRejectionMessage(for: .explicit),
                     ".explicit must be acceptable from external callers")
        XCTAssertNil(SocketMetadataSourceValidator.externalRejectionMessage(for: .declare),
                     ".declare must be acceptable from external callers")
        XCTAssertNil(SocketMetadataSourceValidator.externalRejectionMessage(for: .osc),
                     ".osc must be acceptable from external callers")
        XCTAssertNil(SocketMetadataSourceValidator.externalRejectionMessage(for: .heuristic),
                     ".heuristic must be acceptable from external callers")
    }

    func testRejectionMessageMatchesProductionConstants() {
        // The string constants in SocketMetadataSourceValidator must
        // match what TerminalController's pre-C11-106 inline check
        // returned, otherwise CLI consumers (lattice, agent-runtime)
        // would see a behavior change masquerading as a code-quality
        // refactor.
        XCTAssertEqual(SocketMetadataSourceValidator.invalidSourceCode, "invalid_source")
        XCTAssertTrue(
            SocketMetadataSourceValidator.invalidSourceMessage.contains("c11-internal"),
            "rejection message must explain why .derived is rejected"
        )
    }

    // MARK: - AC17

    func testGetMetadataReturnsDerivedWorktreeAndBranchValuesWithDerivedSource() {
        let store = SurfaceMetadataStore.shared
        let workspaceId = UUID()
        let surfaceId = UUID()
        // Fresh UUIDs per test → no contamination from sibling tests
        // sharing the singleton store; no defer cleanup needed.

        // Write the two derived keys through the internal write path
        // — same call sequence `TabManager.applyDerivedWorktreeBranchMetadata`
        // uses in production after the cache-wired probe completes.
        XCTAssertTrue(store.setInternal(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            key: MetadataKey.worktree,
            value: "c11-106-followups",
            source: .derived
        ))
        XCTAssertTrue(store.setInternal(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            key: MetadataKey.branch,
            value: "feat/c11-106-followups",
            source: .derived
        ))

        // Read through the same path the socket `get-metadata`
        // handler uses (`v2SurfaceGetMetadata` at TerminalController
        // calls `SurfaceMetadataStore.shared.getMetadata`).
        let (metadata, sources) = store.getMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )

        XCTAssertEqual(metadata[MetadataKey.worktree] as? String,
                       "c11-106-followups",
                       "derived worktree value must be visible to external readers")
        XCTAssertEqual(metadata[MetadataKey.branch] as? String,
                       "feat/c11-106-followups",
                       "derived branch value must be visible to external readers")

        // The socket get-metadata response includes per-key sources
        // when `include_sources=true`. Verify the source label is
        // `derived` so downstream consumers can distinguish derived
        // values from explicit user writes.
        let worktreeSource = sources[MetadataKey.worktree]?["source"] as? String
        let branchSource = sources[MetadataKey.branch]?["source"] as? String
        XCTAssertEqual(worktreeSource, MetadataSource.derived.rawValue,
                       "worktree's source must be 'derived' on the read path")
        XCTAssertEqual(branchSource, MetadataSource.derived.rawValue,
                       "branch's source must be 'derived' on the read path")
    }

    func testGetMetadataDoesNotFilterDerivedKeysFromUnfilteredRead() {
        // A future regression "filter derived keys out of socket
        // reads" would silently break Lattice / agent-runtime
        // readers that depend on the worktree+branch values. Pin
        // the behavior with an explicit "derived keys ARE returned
        // alongside explicit keys" check.
        let store = SurfaceMetadataStore.shared
        let workspaceId = UUID()
        let surfaceId = UUID()
        // Fresh UUIDs → no defer cleanup needed.

        // Write one .derived key + one .explicit key.
        XCTAssertTrue(store.setInternal(
            workspaceId: workspaceId, surfaceId: surfaceId,
            key: MetadataKey.worktree, value: "w", source: .derived
        ))
        XCTAssertTrue(store.setInternal(
            workspaceId: workspaceId, surfaceId: surfaceId,
            key: MetadataKey.role, value: "delegator", source: .explicit
        ))

        let (metadata, _) = store.getMetadata(workspaceId: workspaceId, surfaceId: surfaceId)
        XCTAssertEqual(metadata[MetadataKey.worktree] as? String, "w")
        XCTAssertEqual(metadata[MetadataKey.role] as? String, "delegator")
    }
}
