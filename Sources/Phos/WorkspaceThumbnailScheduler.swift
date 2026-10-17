import AppKit

/// Two decoders at most, a bounded cache, and only the current visible/prefetch demand.
@MainActor
final class WorkspaceThumbnailScheduler {
    private let cache = BoundedCache<URL, CGImage>(capacity: 192)
    private let metrics: WorkspaceWorkMetrics
    private let publish: (URL, CGImage?) -> Void
    private var wanted: Set<URL> = []
    private var pending: [URL] = []
    private var active: [UUID: URL] = [:]
    private var orderedDemand: [URL] = []
    private var failed: Set<URL> = []
    private var generation = UUID()
    init(metrics: WorkspaceWorkMetrics, publish: @escaping (URL, CGImage?) -> Void) {
        self.metrics = metrics; self.publish = publish
    }
    var cachedCount: Int { cache.count }
    var activeCount: Int { active.count }
    func image(for url: URL) -> CGImage? { cache[url] }
    func request(_ urls: [URL]) {
        var seen = Set<URL>()
        let ordered = Array(urls.filter { seen.insert($0).inserted }.prefix(96))
        orderedDemand = ordered; wanted = Set(ordered)
        pending = ordered.filter { cache[$0] == nil && !failed.contains($0) && !active.values.contains($0) }
        startNext()
    }
    func reset() {
        generation = UUID(); wanted = []; orderedDemand = []; pending = []; failed = []; cache.removeAll()
    }
    private func startNext() {
        while active.count < 2, !pending.isEmpty {
            let url = pending.removeFirst(), ticket = generation, job = UUID()
            active[job] = url
            let metrics = metrics
            Task { [weak self] in
                let image = await Task.detached(priority: .utility) {
                    metrics.increment("thumbnail")
                    return autoreleasepool { AppState.thumb(for: url) }
                }.value
                guard let self else { return }
                active.removeValue(forKey: job)
                if ticket == generation {
                    if let image { cache[url] = image } else { failed.insert(url) }
                    if wanted.contains(url) { publish(url, image) }
                }
                // Running ImageIO work cannot be preempted. Keep its slot occupied even
                // across folder resets, then schedule only the latest visible demand.
                request(orderedDemand)
            }
        }
    }
}
