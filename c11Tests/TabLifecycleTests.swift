import XCTest
import WebKit
import Darwin

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Lock-protected counter used by the C11-25 fix DoD #5 sampler tests
/// to assert provider-invocation counts across the sampler's lock
/// boundary. Cheap; doesn't need an XCTestExpectation because the
/// refresh path is synchronous when driven through `testHook…`.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

/// Unit tests for the C11-25 lifecycle primitive — the transition
/// validator on `SurfaceLifecycleState`, the canonical metadata mirror
/// in `SurfaceMetadataStore`, and the controller's transition gating.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class TabLifecycleTests: XCTestCase {

    // MARK: - Transition validator

    func testActiveCanTransitionToThrottledAndHibernated() {
        XCTAssertTrue(TabLifecycleState.active.canTransition(to: .throttled))
        XCTAssertTrue(TabLifecycleState.active.canTransition(to: .hibernated))
    }

    func testThrottledCanTransitionToActiveAndHibernated() {
        XCTAssertTrue(TabLifecycleState.throttled.canTransition(to: .active))
        XCTAssertTrue(TabLifecycleState.throttled.canTransition(to: .hibernated))
    }

    func testHibernatedCanResumeToActive() {
        XCTAssertTrue(TabLifecycleState.hibernated.canTransition(to: .active))
    }

    func testHibernatedDoesNotAutoFlipToThrottled() {
        // Hibernated is operator-pinned. A workspace selection change
        // must not yank the surface back to throttled — the only legal
        // exit is to active (via "Resume Workspace").
        XCTAssertFalse(TabLifecycleState.hibernated.canTransition(to: .throttled))
    }

    func testSuspendedIsReservedInC11_25() {
        // Defined in the enum so the metadata key has an upgrade path,
        // but no transitions are valid in C11-25 — guards against a
        // stale snapshot or a typo flipping a surface into a state the
        // dispatcher has no handler for.
        for from in TabLifecycleState.allCases {
            if from == .suspended { continue }
            XCTAssertFalse(
                from.canTransition(to: .suspended),
                "expected \(from.rawValue) → suspended to be rejected"
            )
        }
        for to in TabLifecycleState.allCases {
            if to == .suspended { continue }
            XCTAssertFalse(
                TabLifecycleState.suspended.canTransition(to: to),
                "expected suspended → \(to.rawValue) to be rejected"
            )
        }
    }

    func testSelfTransitionsAreIdempotent() {
        for state in TabLifecycleState.allCases {
            XCTAssertTrue(state.canTransition(to: state))
        }
    }

    func testIsOperatorPinnedOnlyHibernated() {
        XCTAssertFalse(TabLifecycleState.active.isOperatorPinned)
        XCTAssertFalse(TabLifecycleState.throttled.isOperatorPinned)
        XCTAssertFalse(TabLifecycleState.suspended.isOperatorPinned)
        XCTAssertTrue(TabLifecycleState.hibernated.isOperatorPinned)
    }

    // MARK: - Canonical metadata mirror

    func testStoreAcceptsValidLifecycleState() throws {
        let workspace = UUID()
        let surface = UUID()
        let store = TabMetadataStore.shared
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        // C11-25 review fix I4: `.suspended` is reserved-only and rejected
        // at the validator. Walk only the runtime-acceptable set here.
        for state in TabLifecycleState.allCases where state != .suspended {
            let result = try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: [MetadataKey.lifecycleState: state.rawValue],
                mode: .merge,
                source: .explicit
            )
            XCTAssertEqual(
                result.applied[MetadataKey.lifecycleState],
                true,
                "expected \(state.rawValue) to be accepted"
            )
        }
    }

    func testStoreRejectsSuspendedAsReservedOnly() {
        let workspace = UUID()
        let surface = UUID()
        let store = TabMetadataStore.shared
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: [MetadataKey.lifecycleState: TabLifecycleState.suspended.rawValue],
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

    func testStoreRejectsUnknownLifecycleStateValue() {
        let workspace = UUID()
        let surface = UUID()
        let store = TabMetadataStore.shared
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: [MetadataKey.lifecycleState: "frozen"],
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

    func testStoreRejectsNonStringLifecycleState() {
        let workspace = UUID()
        let surface = UUID()
        let store = TabMetadataStore.shared
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: [MetadataKey.lifecycleState: 42],
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

    func testLifecycleStateIsCanonicalKey() {
        XCTAssertTrue(MetadataKey.canonical.contains(MetadataKey.lifecycleState))
        XCTAssertTrue(TabMetadataStore.reservedKeys.contains(MetadataKey.lifecycleState))
    }

    // MARK: - Controller

    @MainActor
    func testControllerStartsActiveByDefault() {
        let controller = TabLifecycleController(
            workspaceId: UUID(),
            surfaceId: UUID()
        ) { _, _ in }
        XCTAssertEqual(controller.state, .active)
    }

    @MainActor
    func testControllerTransitionMirrorsToMetadata() throws {
        let workspace = UUID()
        let surface = UUID()
        let store = TabMetadataStore.shared
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        let controller = TabLifecycleController(
            workspaceId: workspace,
            surfaceId: surface
        ) { _, _ in }

        XCTAssertTrue(controller.transition(to: .throttled))
        let snapshot = store.getMetadata(workspaceId: workspace, surfaceId: surface)
        XCTAssertEqual(
            snapshot.metadata[MetadataKey.lifecycleState] as? String,
            TabLifecycleState.throttled.rawValue
        )
    }

    @MainActor
    func testControllerRejectsInvalidTransition() {
        let controller = TabLifecycleController(
            workspaceId: UUID(),
            surfaceId: UUID(),
            initial: .active
        ) { _, _ in }
        // active → suspended is not a legal transition in C11-25.
        XCTAssertFalse(controller.transition(to: .suspended))
        XCTAssertEqual(controller.state, .active)
    }

    @MainActor
    func testControllerFiresHandlerOnRealTransitionOnly() {
        var calls: [(TabLifecycleState, TabLifecycleState)] = []
        let controller = TabLifecycleController(
            workspaceId: UUID(),
            surfaceId: UUID(),
            initial: .active
        ) { from, to in
            calls.append((from, to))
        }
        // Same-state transition is a no-op for the handler.
        XCTAssertTrue(controller.transition(to: .active))
        XCTAssertEqual(calls.count, 0)
        // Real transition fires the handler with (prior, target).
        XCTAssertTrue(controller.transition(to: .throttled))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, .active)
        XCTAssertEqual(calls[0].1, .throttled)
    }

    // MARK: - Native hibernated browser construction (S4 + E1)

    /// C11-25 fix S4+E1: a `BrowserPanel` constructed with
    /// `pendingHibernate: true` must come up natively in `.hibernated`,
    /// must NOT fire the initial `WKWebView.load(URLRequest:)` for
    /// `initialURL`, and must record the URL where resume can find it
    /// (so `Resume Workspace` lands on the right page). Closes the
    /// privacy/billing leak where a brief network hit attached cookies
    /// and a billable pageview against the persisted URL during the
    /// gap between construction and the legacy re-hibernate dispatch.
    @MainActor
    func testBrowserTabPendingHibernateSkipsInitialLoad() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/c11-25-pending-hibernate"))
        let surfaceId = UUID()
        BrowserSnapshotStore.shared.clear(forSurfaceId: surfaceId)
        defer { BrowserSnapshotStore.shared.clear(forSurfaceId: surfaceId) }

        let panel = BrowserTab(
            id: surfaceId,
            workspaceId: UUID(),
            initialURL: url,
            pendingHibernate: true
        )

        XCTAssertEqual(
            panel.lifecycleState,
            .hibernated,
            "panel constructed with pendingHibernate=true must publish hibernated"
        )
        XCTAssertEqual(
            panel.currentURL,
            url,
            "currentURL is preserved so the omnibar still presents the destination"
        )
        XCTAssertFalse(
            panel.shouldRenderWebView,
            "shouldRenderWebView must stay false; the placeholder owns the body"
        )
        XCTAssertNil(
            panel.webView.url,
            "WKWebView.url must remain nil — no request was dispatched for initialURL"
        )
        XCTAssertFalse(
            panel.webView.isLoading,
            "WKWebView must not be loading — no initial navigate fired"
        )
        let snapshot = try XCTUnwrap(
            BrowserSnapshotStore.shared.snapshot(forSurfaceId: surfaceId),
            "snapshot store must be primed with the initialURL so Resume can find it"
        )
        XCTAssertEqual(snapshot.url, url)
        XCTAssertNil(snapshot.image, "no live page rendered yet, so no captured image")
    }

    /// Sanity check the legacy path: without `pendingHibernate`, the
    /// panel still drives the initial navigate. Guards against an
    /// over-broad fix that suppresses the navigate for the normal case.
    @MainActor
    func testBrowserTabDefaultConstructionStillFiresInitialLoad() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/c11-25-default"))
        let panel = BrowserTab(
            workspaceId: UUID(),
            initialURL: url
        )

        XCTAssertEqual(panel.lifecycleState, .active)
        XCTAssertTrue(
            panel.shouldRenderWebView,
            "shouldRenderWebView flips to true for the default initialURL path"
        )
    }

    // MARK: - Terminal CPU/MEM resolver (DoD #5)

    /// C11-25 fix DoD #5: the resolver runs without crashing for a real
    /// tty path (e.g. `/dev/tty`). The exact pid returned depends on
    /// the test runner's environment — CI containers without a
    /// controlling tty get nil; macOS runners with one return a pid.
    /// Either is correct; the test asserts the contract: a returned
    /// pid is positive, no crashes on the syscall path.
    func testTerminalPIDResolverHandlesRealTTYPath() {
        let pid = TerminalPIDResolver.foregroundPID(forTTYName: "/dev/tty")
        if let pid {
            XCTAssertTrue(pid > 0, "expected a positive pid, got \(pid)")
        }
    }

    /// Resolver returns nil for a non-existent tty path.
    func testTerminalPIDResolverReturnsNilForUnknownTTY() {
        XCTAssertNil(
            TerminalPIDResolver.foregroundPID(forTTYName: "/dev/ttys999not-a-real-device")
        )
    }

    /// C11-224: the resolver asks the kernel for pids on one tty
    /// (`PROC_TTY_ONLY`) instead of scanning every process. Prove the
    /// filter is real by resolving this process's own controlling tty:
    /// the answer must be a live process whose controlling tty is that
    /// device, and since this process is itself on the tty and the
    /// resolver picks the highest pid, it cannot be lower than ours.
    /// Skips when the runner has no controlling tty (CI without a pty).
    func testTerminalPIDResolverResolvesOwnControllingTTY() throws {
        guard let cName = ttyname(STDIN_FILENO) else {
            throw XCTSkip("test runner has no controlling tty on stdin")
        }
        let ttyName = String(cString: cName)
        let dev = try XCTUnwrap(TerminalPIDResolver.ttyDevice(for: ttyName))

        let pid = try XCTUnwrap(
            TerminalPIDResolver.foregroundPID(forTTYName: ttyName),
            "a process (this one) is on \(ttyName), so the resolver must find it"
        )
        XCTAssertGreaterThanOrEqual(
            pid, getpid(),
            "highest-pid-wins over the tty's processes can't pick a pid below our own"
        )

        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
        XCTAssertEqual(rc, infoSize, "resolved pid \(pid) must be a live process")
        XCTAssertEqual(
            info.e_tdev, UInt32(truncatingIfNeeded: dev),
            "resolved pid \(pid) must have \(ttyName) as its controlling tty"
        )
    }

    /// C11-25 fix DoD #5: a registered pid-provider is invoked by the
    /// sampler's tick refresh path and its result is mirrored into
    /// `cachedPids`, so a subsequent `proc_pid_rusage` sample for that
    /// surface can attribute CPU/MEM. Drives the refresh path directly
    /// (rather than spinning the timer) so the test stays deterministic
    /// and CI-safe.
    func testSamplerInvokesPidProviderAndCachesResult() {
        let sampler = TabMetricsSampler.shared
        let surfaceId = UUID()
        let providerPID: pid_t = getpid()
        sampler.register(surfaceId: surfaceId)
        defer { sampler.unregister(surfaceId: surfaceId) }

        let counter = CallCounter()
        sampler.setPidProvider(surfaceId: surfaceId) {
            counter.increment()
            return providerPID
        }

        // First refresh fires the provider (no prior resolve recorded).
        sampler.testHookRefreshPidProviders()
        XCTAssertEqual(
            counter.value,
            1,
            "provider must run on the first refresh after registration"
        )
        XCTAssertEqual(
            sampler.testHookCachedPid(forSurfaceId: surfaceId),
            providerPID,
            "cached pid must match what the provider returned"
        )

        // A second refresh inside the throttle window must NOT re-run
        // the provider — proc_listpids is expensive enough that the
        // refresh window protects every tick from amortizing it.
        sampler.testHookRefreshPidProviders()
        XCTAssertEqual(
            counter.value,
            1,
            "provider must be throttled by pidProviderRefreshSeconds; "
            + "got \(counter.value) calls"
        )
    }

    /// C11-25 fix DoD #5: when the provider returns nil (e.g. the
    /// shell's foreground job has exited and no replacement exists),
    /// the sampler drops the cached pid so the sidebar can render `—`
    /// instead of a stale value.
    func testSamplerClearsCacheWhenProviderReturnsNil() {
        let sampler = TabMetricsSampler.shared
        let surfaceId = UUID()
        sampler.register(surfaceId: surfaceId, initialPid: getpid())
        defer { sampler.unregister(surfaceId: surfaceId) }

        sampler.setPidProvider(surfaceId: surfaceId) { nil }
        sampler.testHookRefreshPidProviders()

        XCTAssertNil(
            sampler.testHookCachedPid(forSurfaceId: surfaceId),
            "provider returning nil must drop the cached pid"
        )
    }

    @MainActor
    func testUpdateWorkspaceIdRedirectsMetadataWrites() throws {
        let originalWorkspace = UUID()
        let newWorkspace = UUID()
        let surface = UUID()
        let store = TabMetadataStore.shared
        defer {
            store.removeSurface(workspaceId: originalWorkspace, surfaceId: surface)
            store.removeSurface(workspaceId: newWorkspace, surfaceId: surface)
        }

        let controller = TabLifecycleController(
            workspaceId: originalWorkspace,
            surfaceId: surface
        ) { _, _ in }

        controller.updateWorkspaceId(newWorkspace)
        XCTAssertTrue(controller.transition(to: .throttled))

        let newSnap = store.getMetadata(workspaceId: newWorkspace, surfaceId: surface)
        XCTAssertEqual(
            newSnap.metadata[MetadataKey.lifecycleState] as? String,
            TabLifecycleState.throttled.rawValue
        )
        let oldSnap = store.getMetadata(workspaceId: originalWorkspace, surfaceId: surface)
        XCTAssertNil(oldSnap.metadata[MetadataKey.lifecycleState])
    }
}

/// C11-228: workspace selection drives terminal lifecycle from the model, so a
/// deselected workspace throttles even when its hidden SwiftUI subtree never
/// re-evaluates. No view hierarchy is mounted here, which is exactly that case.
@MainActor
final class WorkspaceSelectionLifecycleTests: XCTestCase {

    private func terminals(_ workspace: Workspace) -> [TerminalTab] {
        workspace.panels.values.compactMap { $0 as? TerminalTab }
    }

    func testDeselectingWorkspaceThrottlesItsTerminalsAndSelectingActivates() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.workspaces.first)
        let second = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let firstTerminal = try XCTUnwrap(terminals(first).first)
        let secondTerminal = try XCTUnwrap(terminals(second).first)

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedWorkspaceId, second.id)
        XCTAssertEqual(firstTerminal.lifecycle.state, .throttled)
        XCTAssertEqual(secondTerminal.lifecycle.state, .active)
        XCTAssertEqual(
            TabMetadataStore.shared
                .getMetadata(workspaceId: first.id, surfaceId: firstTerminal.id)
                .metadata[MetadataKey.lifecycleState] as? String,
            TabLifecycleState.throttled.rawValue
        )

        manager.selectWorkspace(first)
        XCTAssertEqual(firstTerminal.lifecycle.state, .active)
        XCTAssertEqual(secondTerminal.lifecycle.state, .throttled)
    }

    func testTabCreatedInsideHiddenWorkspaceStaysThrottled() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.workspaces.first)
        let second = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        manager.selectWorkspace(second)

        let created = try XCTUnwrap(first.newTerminalSurfaceInFocusedPane(focus: true))
        drainMainQueue()

        XCTAssertEqual(created.lifecycle.state, .throttled)
        for terminal in terminals(first) {
            XCTAssertEqual(
                terminal.lifecycle.state,
                .throttled,
                "every terminal in a hidden workspace must be throttled"
            )
        }
        for terminal in terminals(second) {
            XCTAssertEqual(terminal.lifecycle.state, .active)
        }
    }

    func testHibernatedTerminalIsNotReactivatedBySelection() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.workspaces.first)
        let second = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let firstTerminal = try XCTUnwrap(terminals(first).first)

        manager.selectWorkspace(second)
        XCTAssertTrue(firstTerminal.lifecycle.transition(to: .hibernated))
        manager.selectWorkspace(first)
        XCTAssertEqual(firstTerminal.lifecycle.state, .hibernated)
    }
}
