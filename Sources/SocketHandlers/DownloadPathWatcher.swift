import Foundation

/// C11-222. Watches a download destination path and reports when it becomes
/// *ready* — the file exists and has a non-zero size.
///
/// Why a directory watch alone is not enough: a directory's vnode changes when
/// a child is created, unlinked or renamed, but **not** when an existing
/// child's contents change. A file that is created empty and then written in
/// place therefore produces exactly one directory event (at create time, when
/// the size is still zero) and nothing afterwards, so a directory-only watch
/// runs to its full deadline even though the download landed. Atomic-rename
/// writes — what a real `WKDownload` does — happen to work, which is why this
/// went unnoticed. So whenever the target exists but is not yet ready, this
/// watcher also attaches a source to the file's *own* descriptor.
///
/// Lifetime invariants, inherited from C11-209 and not to be regressed:
///
///   * Every file descriptor is owned by its `DispatchSource` and closed from
///     that source's cancel handler only — never from a `defer`. The caller's
///     await can unwind on its own deadline while a source is still live, and
///     libdispatch traps on a descriptor closed out from under it.
///   * `terminate(delivering:)` is the single terminal path; the completion
///     runs at most once, and never after `teardown()`.
///   * Every mutation of watcher state happens on `queue`, so there is exactly
///     one writer: both event handlers, both cancel handlers, the deadline work
///     item and the synchronous `start` body all run there.
///   * `teardown()` is idempotent and cancels every live source, so the
///     deadline-unwind path always reclaims every descriptor.
///
/// Nothing here touches `DispatchQueue.main`. This runs underneath an
/// in-progress main-queue drain, where a main-queue block is structurally
/// undeliverable — see the comment on `v2AwaitCallbackPumpingMainRunLoop`.
final class DownloadPathWatcher {

    /// Ready means: the path resolves to something that exists and has bytes in
    /// it. A zero-byte file is a download that has been created but not yet
    /// written.
    static func isPathReady(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return info.st_size > 0
    }

    private let path: String
    private let directoryPath: String
    private let queue: DispatchQueue
    private let isReady: (String) -> Bool

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptorForFileSource: Int32 = -1
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: ((Bool) -> Void)?
    private var finished = false
    private var started = false
    private var rebindingFileSource = false

    /// Descriptors this watcher has opened and closed, in order. Test seam for
    /// the fd-lifetime invariant; read through `descriptorAccounting()`, which
    /// hops onto `queue` like every other reader of watcher state.
    private var openedDescriptors: [Int32] = []
    private var closedDescriptors: [Int32] = []

    /// - Parameters:
    ///   - path: the download destination being waited on.
    ///   - queue: a *serial* queue owned by the caller for the lifetime of the
    ///     wait. All watcher state is confined to it.
    ///   - isReady: readiness predicate, injectable for tests.
    init(
        path: String,
        queue: DispatchQueue,
        isReady: @escaping (String) -> Bool = DownloadPathWatcher.isPathReady
    ) {
        self.path = path
        self.directoryPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        self.queue = queue
        self.isReady = isReady
    }

    deinit {
        // Safety net only: `teardown()` is the documented exit. Cancelling is
        // thread-safe, and the cancel handlers close their descriptors without
        // needing `self`.
        timeoutWorkItem?.cancel()
        directorySource?.cancel()
        fileSource?.cancel()
    }

    /// Begins watching. `completion` is invoked at most once, on `queue`, with
    /// `true` when the path became ready and `false` when the deadline expired
    /// with the path still not ready. It may be invoked before `start` returns
    /// if the path is already ready.
    ///
    /// - Returns: `false` if the parent directory could not be opened, in which
    ///   case nothing was started and `completion` will never run.
    @discardableResult
    func start(timeout: TimeInterval, completion: @escaping (Bool) -> Void) -> Bool {
        var didStart = false
        queue.sync {
            guard !started else { return }
            started = true
            self.completion = completion

            let directoryDescriptor = open(directoryPath, O_EVTONLY)
            guard directoryDescriptor >= 0 else {
                self.completion = nil
                return
            }
            openedDescriptors.append(directoryDescriptor)

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directoryDescriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.evaluate()
            }
            source.setCancelHandler { [weak self] in
                close(directoryDescriptor)
                self?.noteDirectorySourceCancelled(directoryDescriptor)
            }
            directorySource = source
            source.resume()
            didStart = true

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.terminate(delivering: self.isReady(self.path))
            }
            timeoutWorkItem = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)

            // Closes the race between `open()` and `resume()` above — if the
            // file landed in that window no directory event will ever fire —
            // and covers "the file already exists and is empty right now", for
            // which the directory will never produce another event either.
            evaluate()
        }
        return didStart
    }

    /// Cancels every live source and the deadline item without delivering a
    /// result. Idempotent, safe from any thread, and safe to call after the
    /// completion has already run. This is what the caller invokes once its
    /// await has unwound, however it unwound.
    func teardown() {
        queue.sync {
            terminate(delivering: nil)
        }
    }

    /// Test seam: `(opened, closed)` descriptors, in order.
    func descriptorAccounting() -> (opened: [Int32], closed: [Int32]) {
        var snapshot: (opened: [Int32], closed: [Int32]) = ([], [])
        queue.sync {
            snapshot = (openedDescriptors, closedDescriptors)
        }
        return snapshot
    }

    // MARK: - Queue-confined internals

    private func evaluate() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }

        if isReady(path) {
            terminate(delivering: true)
            return
        }

        // The file exists but has no bytes yet. Further writes to it in place
        // do not disturb the parent directory, so watch the file itself.
        if attachFileSource() {
            // Re-check now that the source is live: the write may have landed
            // between the readiness check above and the attach, and nothing
            // would fire afterwards.
            if isReady(path) {
                terminate(delivering: true)
            }
        }
    }

    /// - Returns: `true` if a new file source was attached by this call.
    private func attachFileSource() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard fileSource == nil else { return false }

        let descriptor = open(path, O_EVTONLY)
        // Not there yet: the directory source will call back when it appears.
        guard descriptor >= 0 else { return false }
        openedDescriptors.append(descriptor)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        source.setCancelHandler { [weak self] in
            close(descriptor)
            self?.noteFileSourceCancelled(descriptor)
        }
        fileSource = source
        fileDescriptorForFileSource = descriptor
        source.resume()
        return true
    }

    private func handleFileEvent() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }

        let events = fileSource?.data ?? []
        if events.contains(.delete) || events.contains(.rename) {
            // The inode this descriptor tracks is no longer the path. Drop it
            // and rebind from the cancel handler, so a file replaced in place
            // (write to a temp, rename over the target) is still followed.
            rebindingFileSource = true
            fileSource?.cancel()
            return
        }
        evaluate()
    }

    private func noteDirectorySourceCancelled(_ descriptor: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        closedDescriptors.append(descriptor)
        directorySource = nil
    }

    private func noteFileSourceCancelled(_ descriptor: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        closedDescriptors.append(descriptor)
        if fileDescriptorForFileSource == descriptor {
            fileSource = nil
            fileDescriptorForFileSource = -1
        }
        guard rebindingFileSource else { return }
        rebindingFileSource = false
        evaluate()
    }

    /// The single terminal path. `nil` tears down without delivering.
    private func terminate(delivering value: Bool?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        finished = true

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        rebindingFileSource = false

        // Each source closes its own descriptor from its cancel handler.
        directorySource?.cancel()
        fileSource?.cancel()

        let pending = completion
        completion = nil
        if let value {
            pending?(value)
        }
    }
}
