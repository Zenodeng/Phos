#if PHOS_QA
import AppKit
import QuartzCore
import Darwin

/// Opt-in measurement on the real QA workspace and copy-only fixtures. Never shipped.
@MainActor enum WorkspaceReviewBench {
    private(set) static var running = false
    static var launchBegin: Double?
    static var launchFirstPreviewMs: Double?
    static func recordFirstPreview() { if launchFirstPreviewMs == nil, let begin = launchBegin { launchFirstPreviewMs = (ProcessInfo.processInfo.systemUptime-begin)*1000 } }
    private static func ready(_ s:AppState) async throws {
        for _ in 0..<18000 {
            if s.workflowError != nil { throw NSError(domain:"R5",code:1,userInfo:[NSLocalizedDescriptionKey:s.workflowError!]) }
            if !s.previewing && s.previewFrame?.key.photoID == s.current?.id && s.preview != nil { return }
            try await Task.sleep(nanoseconds:5_000_000)
        }
        throw NSError(domain:"R5",code:2,userInfo:[NSLocalizedDescriptionKey:"Preview timeout"])
    }
    private static func rss() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return code == KERN_SUCCESS ? Double(info.resident_size)/1048576 : 0
    }
    private static func stats(_ a:[Double])->[String:Any] {
        let b = a.sorted(); return ["samplesMs":a,"count":a.count,"medianMs":b[b.count/2],"p95Ms":b[max(0,Int(ceil(Double(b.count)*0.95))-1)],"maxMs":b.last!]
    }
    static func run(root:WorkspaceRootView) async {
        guard !running,let window = root.window else { return }; running = true
        defer { running = false }
        let s = root.model.state, mode = root.model.session.mode
        let original = s.currentIndex
        var peak = rss()
        let memory = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { _ in MainActor.assumeIsolated { peak = max(peak,rss()) } }
        defer { memory.invalidate(); root.model.session.mode = mode; s.select(original) }
        let now = { ProcessInfo.processInfo.systemUptime }
        var results:[String:Any] = [:]
        do {
            let cold = AppState(); let begin = now(); cold.openFolder(QAWorkspace.fixtureFolder); try await ready(cold)
            results["launchFirstFolderPreviewMs"] = launchFirstPreviewMs
            results["firstFolderPreviewMs"] = (now()-begin)*1000
            // S0 measures warm selection before spawning its later cold-state tests.
            // Drain both thumbnail pipelines so the added first-folder probe cannot
            // contaminate warm render samples with concurrent RAW/HIF decoding.
            for _ in 0..<18000 {
                if cold.items.allSatisfy({ $0.thumb != nil || cold.thumbnailFailures.contains($0.id) }) && s.items.allSatisfy({ $0.thumb != nil || s.thumbnailFailures.contains($0.id) }) { break }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            cold.suspendPreviewWork()
            let names = ["00-landscape", "01-portrait", "02-raw"]
            let indices = names.compactMap { prefix in s.items.firstIndex { $0.url.lastPathComponent.hasPrefix(prefix) } }
            guard indices.count == 3 else { throw NSError(domain:"R5",code:3) }
            for _ in 0..<3 { for i in indices { s.select(i); try await ready(s) } }
            var warm:[Double] = []
            for i in 0..<20 { let t = now(); s.select(indices[i%3]); try await ready(s); warm.append((now()-t)*1000) }
            results["warmSelectionToPreview"] = stats(warm)
            s.select(indices[0]); try await ready(s)
            let before = s.workMetrics.snapshot
            var layout:[Double] = []
            for i in 0..<20 {
                let t = now(); root.model.session.mode = i%2 == 0 ? .immersive : .filmstrip
                root.refresh(); root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                layout.append((now()-t)*1000); try await Task.sleep(nanoseconds:40_000_000)
            }
            results["layoutSwitchSynchronousFlush"] = stats(layout)
            results["layoutCountersBefore"] = before; results["layoutCountersAfter"] = s.workMetrics.snapshot
            var fit:[Double] = []
            for _ in 0..<20 { let t = now(); s.render(); try await ready(s); fit.append((now()-t)*1000) }
            results["fitProxyPreview"] = stats(fit)
            results["peakResidentMiB"] = max(peak,rss()); results["finalResidentMiB"] = rss()
            results["windowContentBounds"] = NSStringFromRect(root.bounds)
            results["appearance"] = root.effectiveAppearance.name.rawValue
            results["backingScale"] = window.backingScaleFactor
            results["status"] = "passed"
            results["protocol"] = ["samples":20,"warmupCycles":3,"pollMs":5,"previewLongEdge":2200,"memorySamplingMs":20,"layoutTiming":"synchronous layout/display/CA flush, not FPS or scanout latency","firstFolderDefinition":"new AppState; OS file cache and global CIContext warm; same operation boundary as S0 firstProcessPreview","fixtures":"copied S0 fixed lake, historically named portrait (moon) and RAW set", "thumbnailIsolation":"both pipelines drained before warmup", "QARecorder":"paused during quantitative run"] as [String:Any]
            s.status = "R5性能检查完成"
        } catch { results["status"] = "failed"; results["error"] = error.localizedDescription; s.status = "R5性能检查失败" }
        let folder = QAWorkspace.root.appendingPathComponent("reports")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        if let data = try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:folder.appendingPathComponent("r5-performance.json"),options:.atomic) }
    }
}
#endif
