import AppKit
import SwiftUI
import CoreImage
import ImageIO
import QuartzCore
import Darwin

// Test-only window: a larger baseline surface can extend beyond the laptop screen.
// The production StudioMainWindow content view is rehosted without rebuilding it.
final class BaselineCaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// This file is explicitly linked only by build_ui_baseline.sh with PHOS_BASELINE.
// It drives the production AppState and StudioMainWindow in a native test window.
// No AX/CGEvent automation; test inputs and window sizes are owned by this build.
@MainActor
enum UIBaselineRunner {
    private static var started = false
    private static var peakRSS: UInt64 = 0
    private static var memoryTimer: Timer?
    private static var frameTimer: Timer?
    private static var frameIntervals: [Double] = []
    private static var previousTick = 0.0
    private static var captureWindow: NSWindow?
    private static var originalWindowInfo: [String:Any] = [:]

    struct Options {
        let command: String
        let folder: URL
        let output: URL
        let photo: String?
        let appearance: String
        let width: CGFloat
        let height: CGFloat
        let samples: Int
        let captureBackend: String
        init() throws {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first, ["capture", "benchmark"].contains(command) else {
                throw error("Expected capture or benchmark.")
            }
            var values: [String: String] = [:]
            var i = 1
            while i < args.count {
                guard args[i].hasPrefix("--"), i + 1 < args.count, values[args[i]] == nil else {
                    throw error("Invalid or duplicate option.")
                }
                values[args[i]] = args[i + 1]; i += 2
            }
            let known: Set<String> = ["--folder","--output","--photo","--appearance","--size","--samples","--capture-backend"]
            guard Set(values.keys).isSubset(of: known), let folder = values["--folder"],
                  let output = values["--output"] else { throw error("Missing folder/output or unknown option.") }
            let dimensions = (values["--size"] ?? "1440x900").split(separator: "x")
            guard dimensions.count == 2, let w = Double(dimensions[0]), let h = Double(dimensions[1]),
                  w >= 1100, h >= 700, w <= 4096, h <= 2160 else { throw error("Invalid content size.") }
            let appearance = values["--appearance"] ?? "light"
            guard ["light","dark"].contains(appearance) else { throw error("Appearance must be light or dark.") }
            let samples = Int(values["--samples"] ?? "20") ?? 0
            guard (1...100).contains(samples) else { throw error("Samples must be 1...100.") }
            guard Bundle.main.bundleIdentifier == "com.zeno.phos.baseline" else {
                throw error("Baseline must run from its isolated app bundle.")
            }
            self.command = command; self.folder = URL(fileURLWithPath: folder)
            let fixtureFolder = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
            guard fixtureFolder.lastPathComponent == "work",
                  fixtureFolder.deletingLastPathComponent().lastPathComponent == "fixtures",
                  FileManager.default.fileExists(atPath: fixtureFolder.deletingLastPathComponent().appendingPathComponent("catalog.json").path) else {
                throw error("Only a catalogued fixtures/work folder may be edited.")
            }
            self.output = URL(fileURLWithPath: output); self.photo = values["--photo"]
            self.appearance = appearance; self.width = w; self.height = h; self.samples = samples
            self.captureBackend = values["--capture-backend"] ?? "windowshot"
            guard ["windowshot","external"].contains(captureBackend) else { throw error("Invalid capture backend.") }
        }
    }
    nonisolated static func error(_ text: String) -> NSError {
        NSError(domain: "PhosBaseline", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func start(_ state: AppState) {
        guard !started else { return }; started = true
        Task { @MainActor in
            do {
                let options = try Options()
                try FileManager.default.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let original = try await windowReady()
                originalWindowInfo = ["framePt":rect(original.frame),"contentPt":rect(original.contentView!.bounds),
                    "class":NSStringFromClass(type(of:original)),
                    "screenVisiblePt":rect(original.screen?.visibleFrame ?? .zero)]
                print("Initial native test window: " + String(describing:originalWindowInfo)); fflush(stdout)
                let content = original.contentView!
                let window = BaselineCaptureWindow(contentRect:CGRect(x:24,y:24,width:options.width,height:options.height),
                    styleMask:original.styleMask,backing:.buffered,defer:false)
                window.title = original.title
                window.isReleasedWhenClosed = false
                original.contentView = nil
                original.orderOut(nil)
                window.contentView = content
                captureWindow = window
                UserDefaults.standard.set(options.appearance, forKey: "rf.appearance")
                window.appearance = NSAppearance(named: options.appearance == "dark" ? .darkAqua : .aqua)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await resize(window, to:CGSize(width:options.width,height:options.height))
                try checkSize(window, options)
                startMemorySampling()
                let begin = ProcessInfo.processInfo.systemUptime
                state.openFolder(options.folder)
                try await ready(state)
                let initial = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                if options.command == "capture" {
                    if let name = options.photo {
                        guard let index = state.items.firstIndex(where: { $0.url.lastPathComponent == name }) else { throw error("Photo not found: " + name) }
                        if state.currentIndex != index { state.select(index); try await ready(state) }
                    }
                    try await wait("thumbnails") { state.items.allSatisfy { $0.thumb != nil } }
                    try await pause(0.4)
                    flush(window)
                    try await capture(window, options: options, state: state, initialMs: initial)
                } else {
                    try await benchmark(window, options: options, state: state, initialMs: initial)
                }
                memoryTimer?.invalidate(); frameTimer?.invalidate()
                print("PASS: " + options.command); fflush(stdout)
                NSApplication.shared.terminate(nil)
            } catch {
                memoryTimer?.invalidate(); frameTimer?.invalidate()
                fputs("FAIL: " + error.localizedDescription + "\n", stderr)
                exit(1)
            }
        }
    }
    static func windowReady() async throws -> NSWindow {
        try await wait("native test window") { NSApplication.shared.windows.contains { $0.isVisible && $0.contentView != nil } }
        return NSApplication.shared.windows.first { $0.isVisible && $0.contentView != nil }!
    }
    static func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    static func wait(_ label: String, timeout: Double = 90, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline { throw error("Timed out: " + label) }
            try await pause(0.005)
        }
    }
    static func ready(_ s: AppState) async throws {
        try await wait("correct preview") {
            s.workflowError != nil || (s.current != nil && s.source != nil && s.preview != nil && !s.previewing)
        }
        if let message = s.workflowError { throw error(message) }
    }
    static func rect(_ r: CGRect) -> [String: Double] {
        ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height]
    }
    static func checkSize(_ w: NSWindow, _ o: Options) throws {
        let size = w.contentLayoutRect.size
        guard abs(size.width - o.width) < 0.5,
              abs(size.height - o.height) < 0.5 else {
            throw error("Actual content size differs from requested size: " + String(describing: w.contentView?.bounds))
        }
    }
    static func resize(_ w: NSWindow, to target: CGSize) async throws {
        w.setContentSize(target)
        try await pause(0.08)
        for _ in 0..<6 {
            let actual = w.contentLayoutRect.size
            let dx = target.width - actual.width, dy = target.height - actual.height
            if abs(dx) < 0.5 && abs(dy) < 0.5 { return }
            var frame = w.frame
            frame.size.width += dx; frame.size.height += dy
            w.setFrame(frame,display:true)
            try await pause(0.08)
        }
        throw error("Cannot obtain exact content dimensions: " + String(describing:w.contentView?.bounds))
    }
    static func flush(_ w: NSWindow) {
        w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded(); CATransaction.flush()
    }
    static func rss() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    static func startMemorySampling() {
        peakRSS = rss()
        memoryTimer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { peakRSS = max(peakRSS, rss()) }
        }
        RunLoop.main.add(memoryTimer!, forMode: .common)
    }
    static func summary(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        let median = sorted.count % 2 == 0 ? (sorted[sorted.count/2 - 1] + sorted[sorted.count/2]) / 2 : sorted[sorted.count/2]
        return ["samplesMs":values,"count":values.count,"medianMs":median,
                "p95Ms":sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))],
                "minMs":sorted.first!,"maxMs":sorted.last!]
    }
    static func metadata(_ w: NSWindow, _ o: Options, _ s: AppState) -> [String: Any] {
        var m: [String: Any] = [
            "processID":ProcessInfo.processInfo.processIdentifier, "appPath":Bundle.main.bundleURL.path,
            "executablePath":Bundle.main.executableURL?.path ?? "", "bundleID":Bundle.main.bundleIdentifier ?? "",
            "version":Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "windowID":w.windowNumber,"windowFramePt":rect(w.frame),
            "contentBoundsPt":rect(w.contentLayoutRect),"contentViewBoundsPt":rect(w.contentView!.bounds),
            "contentLayoutRectPt":rect(w.contentLayoutRect),
            "requestedContentDefinition":"NSWindow.contentLayoutRect excluding title chrome",
            "requestedContentPt":["width":o.width,"height":o.height],"backingScale":w.backingScaleFactor,
            "appearance":o.appearance,"photo":s.current?.url.lastPathComponent ?? "",
            "photoID":s.current?.id.uuidString ?? "", "folder":o.folder.path,
            "previewPixels":["width":s.preview?.width ?? 0,"height":s.preview?.height ?? 0],
            "sourcePixels":["width":s.sourceSize.width,"height":s.sourceSize.height],
            "previewScale":s.lastPreviewScale,"fullResolution":s.fullResPreview,"oneToOne":s.oneToOne,
            "materialCapability":"legacy-opaque-baseline",
            "sourceWindow":"production StudioMainWindow in native test-only NSWindow",
            "baselineOnlyInstrumentation":true
        ]
        m["windowIsKey"] = w.isKeyWindow
        m["windowIsMain"] = w.isMainWindow
        m["applicationIsActive"] = NSApplication.shared.isActive
        m["initialNativeWindow"] = originalWindowInfo
        m["offscreenSurfaceAllowedForLargeSizes"] = true
        if let screen = w.screen {
            m["screenFramePt"] = rect(screen.frame); m["visibleScreenFramePt"] = rect(screen.visibleFrame)
            m["screenRefreshHz"] = screen.maximumFramesPerSecond
        }
        return m
    }
    static func json(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: url)
    }
    static func capture(_ w: NSWindow, options o: Options, state s: AppState, initialMs: Double) async throws {
        try checkSize(w, o)
        if o.captureBackend == "external" {
            let expectedPhotoID = s.current?.id
            let expectedParams = s.params
            w.ignoresMouseEvents = true
            var info = metadata(w,o,s)
            info["firstPreviewMs"] = initialMs
            try json(info,to:o.output.appendingPathExtension("ready.json"))
            print("READY for native capture: " + o.output.path); fflush(stdout)
            try await wait("external screenshot",timeout:300) { FileManager.default.fileExists(atPath:o.output.path) }
            try await pause(0.1)
            guard s.current?.id == expectedPhotoID, s.params == expectedParams else {
                throw error("Photo or adjustments changed while capturing the baseline.")
            }
            guard let source = CGImageSourceCreateWithURL(o.output as CFURL,nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
                  let width = props[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = props[kCGImagePropertyPixelHeight as String] as? Int,
                  Double(width) >= o.width*w.backingScaleFactor-2,
                  Double(height) >= o.height*w.backingScaleFactor-2 else {
                throw error("External native screenshot does not cover the verified content size.")
            }
            info["screenshotPath"] = o.output.path
            info["screenshotPixels"] = ["width":width,"height":height]
            info["screenshotFormat"] = CGImageSourceGetType(source) as String? ?? "unknown"
            info["captureBackend"] = "cua native app window screenshot"
            info["peakResidentMiB"] = Double(peakRSS)/1_048_576
            try json(info,to:o.output.appendingPathExtension("json"))
            return
        }
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/windowshot")
        process.arguments = ["shot",String(w.windowNumber),o.output.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, let image = NSImage(contentsOf: o.output) else { throw error("Window screen capture failed.") }
        var info = metadata(w,o,s)
        info["screenshotPath"] = o.output.path
        info["screenshotLogicalSize"] = ["width":image.size.width,"height":image.size.height]
        let captureData = try Data(contentsOf:o.output.appendingPathExtension("window.json"))
        let capture = try JSONSerialization.jsonObject(with:captureData) as! [String:Any]
        guard (capture["processID"] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier,
              let pixels = capture["screenshotPixels"] as? [String:Int],
              Double(pixels["width"] ?? 0) >= o.width * w.backingScaleFactor - 2,
              Double(pixels["height"] ?? 0) >= o.height * w.backingScaleFactor - 2 else {
            throw error("Capture belongs to another process or does not cover the requested content.")
        }
        info["windowCapture"] = capture
        info["firstPreviewMs"] = initialMs
        info["peakResidentMiB"] = Double(peakRSS) / 1_048_576
        try json(info, to: o.output.appendingPathExtension("json"))
        print("Captured actual content " + String(Int(o.width)) + "x" + String(Int(o.height)) + ": " + o.output.path)
    }
    static func scrollViews(_ root: NSView) -> [NSScrollView] {
        (root as? NSScrollView).map { [$0] } ?? root.subviews.flatMap(scrollViews)
    }
    static func benchmark(_ w: NSWindow, options o: Options, state s: AppState, initialMs: Double) async throws {
        var results: [String: Any] = [:]
        let landscape = s.items.firstIndex { $0.url.lastPathComponent.hasPrefix("00-") }!
        let portrait = s.items.firstIndex { $0.url.lastPathComponent.hasPrefix("01-") }!
        let raw = s.items.firstIndex { $0.url.pathExtension.lowercased() == "arw" }!
        let warmIndices = [landscape,portrait,raw]
        for index in warmIndices { s.select(index); try await ready(s) }
        for _ in 0..<3 { for index in warmIndices { s.select(index); try await ready(s) } }
        var switches: [Double] = []
        for i in 0..<o.samples {
            let index = warmIndices[i % warmIndices.count]
            let t = ProcessInfo.processInfo.systemUptime
            s.select(index); try await ready(s)
            guard s.currentIndex == index else { throw error("Wrong photo published.") }
            switches.append((ProcessInfo.processInfo.systemUptime - t) * 1000)
        }
        results["warmSelectionToPreview"] = summary(switches)
        print("Measured warm selection"); fflush(stdout)

        for (name, index) in [("newStateLandscapePreview",landscape),("newStateRAWPreview",raw)] {
            var samples: [Double] = []
            for _ in 0..<o.samples {
                let cold = AppState(); cold.currentIndex = -1
                cold.items = [PhotoItem(url:s.items[index].url)]
                let t = ProcessInfo.processInfo.systemUptime
                cold.select(0); try await ready(cold)
                samples.append((ProcessInfo.processInfo.systemUptime - t) * 1000)
            }
            results[name] = summary(samples)
            print("Measured " + name); fflush(stdout)
        }
        s.select(landscape); try await ready(s)
        // Measure the default light inspector before mask selection changes its private category.
        frameIntervals.removeAll(); previousTick = 0
        frameTimer = Timer(timeInterval:1.0/60,repeats:true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                if previousTick > 0 { frameIntervals.append((now-previousTick)*1000) }
                previousTick = now
            }
        }
        RunLoop.main.add(frameTimer!,forMode:.common)
        var resizes: [Double] = []
        var resizeGeometry: [[String:Double]] = []
        for i in 0..<o.samples {
            let target = CGSize(width:i % 2 == 0 ? 1100 : 1440,height:i % 2 == 0 ? 700 : 900)
            let t = ProcessInfo.processInfo.systemUptime
            let current = w.contentLayoutRect.size
            var frame = w.frame
            frame.size.width += target.width - current.width
            frame.size.height += target.height - current.height
            w.setFrame(frame,display:true)
            flush(w)
            resizes.append((ProcessInfo.processInfo.systemUptime-t)*1000)
            let actual = w.contentLayoutRect.size
            guard abs(actual.width-target.width) < 0.5, abs(actual.height-target.height) < 0.5 else {
                throw error("Benchmark resize did not produce the requested content size.")
            }
            resizeGeometry.append(["width":actual.width,"height":actual.height])
            try await pause(0.04)
        }
        results["windowResizeLayoutDisplayFlush"] = summary(resizes)
        results["windowResizeContentSizesPt"] = resizeGeometry
        // The default inspector fits at 900 pt; use the smaller baseline to measure actual scrolling.
        try await resize(w,to:CGSize(width:1100,height:700)); flush(w)
        let scrolls = scrollViews(w.contentView!)
        let diagnostics = scrolls.map { view -> [String:Any] in
            ["class":NSStringFromClass(type(of:view)),"windowRectPt":rect(view.convert(view.bounds,to:w.contentView)),
             "clipPt":rect(view.contentView.bounds),"documentPt":rect(view.documentView?.bounds ?? .zero),
             "documentFramePt":rect(view.documentView?.frame ?? .zero)]
        }
        let inspectorCandidates = scrolls.filter { view in
            let frame = view.convert(view.bounds,to:w.contentView)
            return frame.minX > w.contentLayoutRect.width*0.55 && frame.height > 200 &&
                (view.documentView?.bounds.height ?? 0) > view.contentView.bounds.height
        }
        guard let inspector = inspectorCandidates.max(by: {
            $0.convert($0.bounds,to:w.contentView).minX < $1.convert($1.bounds,to:w.contentView).minX
        }), let document = inspector.documentView else {
            try json(diagnostics,to:o.output.appendingPathExtension("scroll-diagnostic.json"))
            throw error("Scrollable right-hand inspector unavailable; geometry diagnostic saved.")
        }
        let maxY = max(0,document.bounds.height-inspector.contentView.bounds.height)
        guard maxY > 0 else { throw error("Inspector content not scrollable.") }
        var scrolling: [Double] = []
        for i in 0..<o.samples {
            let t = ProcessInfo.processInfo.systemUptime
            inspector.contentView.scroll(to:CGPoint(x:0,y:maxY*CGFloat(i%10)/9))
            inspector.reflectScrolledClipView(inspector.contentView); flush(w)
            scrolling.append((ProcessInfo.processInfo.systemUptime-t)*1000)
            try await pause(0.02)
        }
        results["inspectorScrollLayoutDisplayFlush"] = summary(scrolling)
        results["inspectorScrollRangePt"] = maxY
        results["inspectorScrollViewRectPt"] = rect(inspector.convert(inspector.bounds,to:w.contentView))
        results["inspectorScrollContentSizePt"] = ["width":1100,"height":700]
        frameTimer?.invalidate()
        if !frameIntervals.isEmpty { results["mainRunLoopTimerIntervals"] = summary(frameIntervals) }
        try await resize(w,to:CGSize(width:o.width,height:o.height)); flush(w)
        var sliders: [Double] = []
        var maskSamples: [Double] = []
        for i in 0..<o.samples {
            let historyCount = s.history.stack.count
            for event in 0..<60 { s.set(\.exposure, Double(event) / 100 + Double(i % 2) / 10) }
            let t = ProcessInfo.processInfo.systemUptime
            s.set(\.exposure, 0.2 + Double(i + 1) / 30); s.endEdit(); try await ready(s)
            guard s.history.stack.count == historyCount + 1 else { throw error("Slider history changed more than once.") }
            sliders.append((ProcessInfo.processInfo.systemUptime - t) * 1000)
        }
        results["sliderLastInputToPreview"] = summary(sliders)
        s.addMask(.radial); try await ready(s)
        for i in 0..<o.samples {
            let base = s.params.masks[0]
            let start = CGPoint(x:400,y:300)
            let session = MaskDragSession(start:start,base:base)
            let historyCount = s.history.stack.count
            let t = ProcessInfo.processInfo.systemUptime
            for event in 1...61 {
                let delta = CGFloat(event) * (i % 2 == 0 ? 1 : -1)
                var next = session.updated(.move,to:CGPoint(x:start.x+delta,y:start.y),size:CGSize(width:800,height:600))
                next.adjust.exposure = 0.2
                s.updateMaskLive(next)
            }
            s.endEdit(); try await ready(s)
            guard s.history.stack.count == historyCount + 1 else { throw error("Mask history changed more than once.") }
            maskSamples.append((ProcessInfo.processInfo.systemUptime - t) * 1000)
        }
        results["mask61ModelEventsToPreview"] = summary(maskSamples)
        s.removeMask(s.params.masks[0].id); try await ready(s)
        print("Measured slider and mask sessions"); fflush(stdout)

        s.select(portrait); try await ready(s)
        for _ in 0..<3 {
            s.oneToOne = true; try await ready(s)
            s.oneToOne = false; try await ready(s)
        }
        var fullPixels: [Double] = [], fitPixels: [Double] = []
        for _ in 0..<o.samples {
            var t = ProcessInfo.processInfo.systemUptime
            s.oneToOne = true; try await ready(s)
            guard s.lastPreviewScale == 1 else { throw error("1:1 mode did not publish full-resolution pixels.") }
            fullPixels.append((ProcessInfo.processInfo.systemUptime-t)*1000)
            t = ProcessInfo.processInfo.systemUptime
            s.oneToOne = false; s.canvasResetID = UUID(); try await ready(s)
            guard s.lastPreviewScale < 1 else { throw error("Fit mode did not restore the proxy preview.") }
            fitPixels.append((ProcessInfo.processInfo.systemUptime-t)*1000)
        }
        results["oneToOneFullResolutionPreview"] = summary(fullPixels)
        results["fitProxyPreview"] = summary(fitPixels)
        results["zoomPhoto"] = s.current!.url.lastPathComponent
        results["zoomSourcePixels"] = ["width":s.sourceSize.width,"height":s.sourceSize.height]
        s.select(landscape); try await ready(s)
        print("Measured 1:1 and fit previews"); fflush(stdout)

        var info = metadata(w,o,s)
        info["firstProcessPreviewMs"] = initialMs
        info["metrics"] = results
        info["peakResidentMiB"] = Double(max(peakRSS,rss())) / 1_048_576
        info["finalResidentMiB"] = Double(rss()) / 1_048_576
        info["protocol"] = [
            "samples":o.samples,"warmupCycles":3,"previewLongEdge":2200,
            "coldDefinition":"new AppState source cache; OS file cache and global CIContext are warm",
            "uiCostDefinition":"synchronous layout/display flush, not measured display presentation latency",
            "maskDefinition":"61 production MaskDragSession/model updates; not synthesized mouse events",
            "memorySamplingMs":20,"originalAppRunningDuringTest":true
        ]
        try json(info,to:o.output)
    }
}

@main
struct PhosBaselineApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = AppState()
        let window = BaselineCaptureWindow(contentRect:CGRect(x:24,y:55,width:1440,height:900),
            styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.title = "PhosBaseline"
        let host = NSHostingView(rootView:StudioMainWindow().environmentObject(state).frame(minWidth:1100,minHeight:700))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps:true)
        UIBaselineRunner.start(state)
        app.run()
    }
}
