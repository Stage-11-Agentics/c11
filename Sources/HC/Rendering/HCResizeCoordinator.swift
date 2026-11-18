import Foundation
import os

/// The grid admitted to hc's ordered writer for one attachment, shared by
/// the two paths that send RESIZE (contract L6 ordering; SPIKE-0B row 3):
///
/// - 2C's raw input lane, which sends RESIZE immediately ahead of each
///   mode-2048 in-band size report Ghostty emits inside its reflow;
/// - ticket 5's display updates (debounced reflow, theme, focus), which carry
///   the grid read on main.
///
/// Decisions happen only where a RESIZE enters the ordered writer, never when
/// a send is merely scheduled, so a report is never left without its RESIZE
/// ahead of it (Astra, PR #12 finding 2). Each grid carries the sequence of
/// the moment it was *observed*; a RESIZE observed before one already admitted
/// is stale and is dropped, so a queued older display size can never land
/// after a newer in-band one. A grid hc already has is not sent twice.
///
/// One unfair lock, no allocation: `admitInBand` runs on Ghostty's IO thread.
final class HCSentGridLedger: @unchecked Sendable {
    private struct State {
        var admitted: HCGridSize?
        var admittedObservation: UInt64 = 0
        var nextObservation: UInt64 = 0
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// - Parameter initial: the grid the attach request carried (hc has it).
    init(initial: HCGridSize? = nil) {
        if let initial {
            lock.withLock { state in
                state.nextObservation &+= 1
                state.admitted = initial
                state.admittedObservation = state.nextObservation
            }
        }
    }

    /// Marks the moment a grid was read from Ghostty (main, display path).
    func observe() -> UInt64 {
        lock.withLock { state in
            state.nextObservation &+= 1
            return state.nextObservation
        }
    }

    /// At the ordered writer's admission point, for a grid observed at
    /// `observation`. True: enqueue RESIZE(grid) now, ahead of anything that
    /// depends on it. False: hc already has this grid, or a newer observation
    /// was already admitted (this one is stale).
    func admit(_ grid: HCGridSize, observedAt observation: UInt64) -> Bool {
        lock.withLock { state in
            Self.admitLocked(&state, grid, observation)
        }
    }

    /// 2C's in-band path: observed and admitted in one step, inside the
    /// reflow, immediately before its RESIZE+report batch is written.
    @inline(__always)
    func admitInBand(_ grid: HCGridSize) -> Bool {
        lock.withLock { state in
            state.nextObservation &+= 1
            return Self.admitLocked(&state, grid, state.nextObservation)
        }
    }

    /// The grid hc has (the last one admitted).
    var current: HCGridSize? { lock.withLock { $0.admitted } }

    private static func admitLocked(_ state: inout State, _ grid: HCGridSize, _ observation: UInt64) -> Bool {
        guard observation > state.admittedObservation else { return false }
        state.admittedObservation = observation
        guard state.admitted != grid else { return false }
        state.admitted = grid
        return true
    }
}

/// Ticket 5's debounced reflow path. Manual-IO Ghostty has no resize hook, so
/// after every `ghostty_surface_set_size` (or cell-size change) the host reads
/// the grid itself, once Ghostty's reflow has settled: a trailing debounce,
/// kept at the spike's 40 ms (debounce 0 rendered once, but Step 0's stale
/// frame race is timing-dependent).
///
/// Main thread. Scheduling and grid reads are injected so the policy is
/// testable without a surface.
@MainActor
final class HCResizeCoordinator {
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    static let debounceSeconds: TimeInterval = 0.040

    private let debounce: TimeInterval
    private let schedule: Scheduler
    private let readGrid: () -> HCGridSize?
    private let settled: (_ grid: HCGridSize) -> Void
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - readGrid: Ghostty's current grid, nil without a sized surface.
    ///   - settled: called once per settled burst with the grid. Whether hc
    ///     needs a RESIZE for it is decided at the writer's admission point
    ///     (`HCSentGridLedger.admit`), not here.
    init(
        debounce: TimeInterval = HCResizeCoordinator.debounceSeconds,
        schedule: @escaping Scheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        },
        readGrid: @escaping () -> HCGridSize?,
        settled: @escaping (_ grid: HCGridSize) -> Void
    ) {
        self.debounce = debounce
        self.schedule = schedule
        self.readGrid = readGrid
        self.settled = settled
    }

    /// After every pixel-size or cell-size change Ghostty was given.
    func noteSizeChanged() {
        generation &+= 1
        let mine = generation
        schedule(debounce) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.apply()
        }
    }

    /// The attachment just became usable: forward any resize that happened
    /// while the attach was in flight.
    func attachmentReady() {
        apply()
    }

    private func apply() {
        guard let grid = readGrid(), grid.columns > 0, grid.rows > 0 else { return }
        settled(grid)
    }
}
