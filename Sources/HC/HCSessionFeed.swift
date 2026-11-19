import Foundation

/// Stable subscriptions survive replacement of the underlying inventory source.
/// Each observer holds one pending value, so a suspended consumer cannot create
/// an unbounded queue of snapshots. The reducer never runs consumer code.
final class HCSessionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current = HCInventorySnapshot(readiness: .pending(.backendNotInstalled),
                                               revision: HCRevision(connectionGeneration: 0, sequence: 0))
    private var subscribers: [UUID: Subscriber] = [:]

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        let id = UUID()
        let subscriber = Subscriber(queue: queue, handler: handler)
        lock.lock()
        subscribers[id] = subscriber
        subscriber.offer(current)
        lock.unlock()
        return HCObservation { [weak self] in
            subscriber.cancel()
            self?.remove(id)
        }
    }

    func publish(_ snapshot: HCInventorySnapshot) {
        lock.lock()
        current = snapshot
        let targets = Array(subscribers.values)
        lock.unlock()
        for target in targets { target.offer(snapshot) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }

    private final class Subscriber: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: @Sendable (HCInventorySnapshot) -> Void
        let lock = NSLock()
        var active = true
        var scheduled = false
        var first: HCInventorySnapshot?
        var latest: HCInventorySnapshot?

        init(queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) {
            self.queue = queue
            self.handler = handler
        }

        func offer(_ snapshot: HCInventorySnapshot) {
            lock.lock()
            guard active else { lock.unlock(); return }
            if !scheduled {
                first = snapshot
                scheduled = true
                queue.async { self.drain() }
            } else { latest = snapshot }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            active = false
            first = nil
            latest = nil
            lock.unlock()
        }

        func drain() {
            lock.lock()
            guard active, let value = first else { scheduled = false; lock.unlock(); return }
            first = nil
            lock.unlock()
            handler(value)
            lock.lock()
            if active, let next = latest {
                first = next
                latest = nil
                queue.async { self.drain() }
            } else { scheduled = false }
            lock.unlock()
        }
    }
}
