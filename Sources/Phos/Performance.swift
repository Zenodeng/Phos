import Foundation

/// Small, thread-safe LRU caches for expensive image resources.
final class BoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    subscript(key: Key) -> Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let value = values[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            order.removeAll { $0 == key }
            values[key] = newValue
            if newValue != nil { order.append(key) }
            while order.count > capacity {
                values.removeValue(forKey: order.removeFirst())
            }
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    func removeAll(where shouldRemove: (Key) -> Bool = { _ in true }) {
        lock.lock()
        defer { lock.unlock() }
        let keys = order.filter(shouldRemove)
        for key in keys { values.removeValue(forKey: key) }
        order.removeAll(where: shouldRemove)
    }
}

/// A running operation is never duplicated; incoming work replaces the pending job.
@MainActor
final class LatestWorkQueue<Input, Output> {
    private let priority: TaskPriority
    private let operation: @Sendable (Input) -> Output
    private let completion: (Input, Output) -> Void
    private var pending: Input?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(priority: TaskPriority = .userInitiated,
         operation: @escaping @Sendable (Input) -> Output,
         completion: @escaping (Input, Output) -> Void) {
        self.priority = priority
        self.operation = operation
        self.completion = completion
    }

    var isRunning: Bool { worker != nil }
    var hasPendingWork: Bool { pending != nil }

    func submit(_ input: Input) {
        pending = input
        guard worker == nil else { return }
        worker = Task {
            while let input = pending {
                pending = nil
                let epoch = generation
                let operation = operation
                let output = await Task.detached(priority: priority) {
                    autoreleasepool { operation(input) }
                }.value
                // Invalidation prevents a previous photo/folder from being published.
                if epoch == generation { completion(input, output) }
            }
            worker = nil
        }
    }

    func invalidate() {
        generation &+= 1
        pending = nil
    }
}
