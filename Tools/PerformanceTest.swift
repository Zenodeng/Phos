import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct PerformanceTest {
    static func brandCompatibilityTests() throws {
        precondition(ExportSettings().watermarkText == "Phos")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phos-compatibility-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("photo.HIF")
        let legacyURL = photo.deletingPathExtension().appendingPathExtension("rawforge.json")
        let legacy = Data(#"{"version":1,"app":"RawForge","params":{"exposure":0.4},"rating":4,"picked":true}"#.utf8)
        try legacy.write(to: legacyURL)
        let decoded = try SidecarStore.read(for: photo)!
        precondition(decoded.app == "RawForge" && decoded.params.exposure == 0.4
                     && decoded.rating == 4 && decoded.picked)
        let renamed = Sidecar(params: decoded.params, rating: decoded.rating, picked: decoded.picked)
        try SidecarStore.write(renamed, for: photo)
        precondition(SidecarStore.url(for: photo).lastPathComponent == "photo.HIF.rawforge.json")
        let saved = try SidecarStore.read(for: photo)!
        precondition(saved.app == "Phos" && saved.params == decoded.params
                     && saved.rating == 4 && saved.picked)
        let untouched = try Data(contentsOf: legacyURL)
        precondition(untouched == legacy)
        let encoded = try JSONEncoder().encode(saved)
        let roundTrip = try JSONDecoder().decode(Sidecar.self, from: encoded)
        precondition(roundTrip.app == "Phos")
        print("PASS: Phos branding, RawForge sidecars, unchanged legacy files and edit metadata.")
    }

    @MainActor
    static func waitUntil(_ label: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            precondition(Date() < deadline, "Timeout: \(label)")
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    static func cacheTests() {
        let cache = BoundedCache<Int, Int>(capacity: 3)
        cache[1] = 1; cache[2] = 2; cache[3] = 3
        _ = cache[1]
        cache[4] = 4
        precondition(cache[2] == nil && cache[1] == 1 && cache.count == 3)
        cache.removeAll { $0 == 1 }
        precondition(cache[1] == nil && cache.count == 2)
        DispatchQueue.concurrentPerform(iterations: 10_000) { i in
            cache[i % 100] = i
            _ = cache[(i + 1) % 100]
            if i % 37 == 0 { cache.removeAll { $0 % 2 == 0 } }
        }
        precondition(cache.count <= 3)
        cache.removeAll()
        precondition(cache.count == 0)
        print("PASS: LRU eviction, invalidation and 10,000 concurrent cache operations.")
    }

    @MainActor
    static func queueTests() async {
        let gate = DispatchSemaphore(value: 0)
        let started = BoundedCache<Int, Bool>(capacity: 10)
        var completed: [Int] = []
        let queue = LatestWorkQueue<Int, Int>(operation: { input in
            started[input] = true
            if input == 0 || input == 2000 { gate.wait() }
            return input
        }, completion: { _, output in completed.append(output) })
        queue.submit(0)
        await waitUntil("worker start") { started[0] == true }
        for i in 1...1000 { queue.submit(i) }
        gate.signal()
        await waitUntil("coalescing") { !queue.isRunning }
        precondition(completed == [0, 1000], "Must render only the running and latest requests")

        queue.submit(2000)
        await waitUntil("old photo start") { started[2000] == true }
        queue.submit(2001)
        queue.invalidate()
        queue.submit(2002)
        gate.signal()
        await waitUntil("invalidation") { !queue.isRunning }
        precondition(completed == [0, 1000, 2002], "Old photo or pending work leaked")
        print("PASS: 1,001 queued updates become 2 operations; invalidated photos never publish.")
    }

    static func pixels(_ image: CIImage) -> Data {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        Engine.ctx.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: bounds,
                          format: .RGBA8, colorSpace: Engine.srgb)
        return Data(bytes)
    }

    @MainActor
    static func appTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawforge-tests-\(UUID())")
        let photos = root.appendingPathComponent("photos")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        var settings = ExportSettings()
        settings.format = "png"
        settings.maxLongEdge = 0
        for i in 0..<3 {
            let image = CIImage(color: CIColor(red: CGFloat(i + 1) * 0.2, green: 0.25, blue: 0.6))
                .cropped(to: CGRect(x: 0, y: 0, width: 2400, height: 1600))
            let url = photos.appendingPathComponent("\(i).png")
            try Engine.write(image, to: url, settings: settings)
            var params = EditParams()
            params.exposure = Double(i) * 0.1
            SidecarStore.save(Sidecar(params: params, rating: i, picked: i == 2), for: url)
        }

        let oriented = root.appendingPathComponent("oriented.jpg")
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let cg = Engine.ctx.createCGImage(image, from: image.extent)!
        let destination = CGImageDestinationCreateWithURL(oriented as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let thumb = AppState.thumb(for: oriented)!
        precondition(thumb.height > thumb.width && max(thumb.width, thumb.height) <= 260)
        print("PASS: thumbnail sizing and EXIF orientation.")

        let state = AppState()
        state.openFolder(photos)
        await waitUntil("initial preview") { state.current != nil && state.preview != nil && !state.previewing }
        precondition(state.items.count == 3 && state.items[2].rating == 2 && state.items[2].picked)
        await waitUntil("thumbnails") { state.items.allSatisfy { $0.thumb != nil } }
        for i in 0..<30 { state.select(i % 3) }
        await waitUntil("rapid selection") { state.preview != nil && !state.previewing }
        precondition(state.currentIndex == 2 && state.params.exposure == 0.2)
        precondition(state.preview!.width == 2200 && state.sourceSize.width == 2400)

        for i in 0..<100 { state.set(\.exposure, Double(i) / 100) }
        state.endEdit()
        await waitUntil("final parameter preview") { !state.previewing }
        let scale = 2200 / state.source!.extent.width
        let base = state.source!.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let expected = Engine.render(base, state.params)
        let expectedCG = Engine.ctx.createCGImage(expected, from: expected.extent, format: .RGBA8, colorSpace: Engine.srgb)!
        precondition(pixels(CIImage(cgImage: state.preview!)) == pixels(CIImage(cgImage: expectedCG)))
        precondition(SidecarStore.load(for: state.current!.url)!.params == state.params)
        state.undo()
        precondition(state.params.exposure == 0.2)
        state.redo()
        precondition(state.params.exposure == 0.99)
        await waitUntil("redo render") { !state.previewing }
        print("PASS: rapid selection, latest preview pixels, sidecar persistence and undo/redo.")

        state.addMask(.radial)
        let steps = state.history.stack.count
        var legacyMask = state.params.masks[0]
        legacyMask.adjust.exposure = 0.4
        let legacyJSON = try JSONEncoder().encode(legacyMask)
        let decodedLegacy = try JSONDecoder().decode(Mask.self, from: legacyJSON)
        precondition(decodedLegacy.gradientVersion == nil && decodedLegacy.radiusX == nil && decodedLegacy.adjust.exposure == 0.4)
        var ellipse = Mask(); ellipse.kind = .radial; ellipse.gradientVersion = 1
        ellipse.radiusX = 0.42; ellipse.radiusY = 0.18; ellipse.radialAngle = 30
        ellipse.adjust.highlights = -20; ellipse.adjust.shadows = 25
        let ellipseJSON = try JSONEncoder().encode(ellipse)
        let ellipseRoundTrip = try JSONDecoder().decode(Mask.self, from: ellipseJSON)
        precondition(ellipseRoundTrip.gradientVersion == 1 && ellipseRoundTrip.radiusX == 0.42
                     && ellipseRoundTrip.radiusY == 0.18 && ellipseRoundTrip.radialAngle == 30
                     && ellipseRoundTrip.adjust.highlights == -20)
        print("PASS: legacy mask decoding and ellipse mask round trip.")
        var mask = state.params.masks[0]
        for i in 0..<100 {
            mask.adjust.exposure = Double(i) / 100
            state.updateMaskLive(mask)
        }
        precondition(state.history.stack.count == steps)
        state.endEdit()
        precondition(state.history.stack.count == steps + 1)
        precondition(SidecarStore.load(for: state.current!.url)!.params == state.params)
        state.undo()
        precondition(state.params.masks[0].adjust.exposure == 0)
        state.redo()
        precondition(state.params.masks[0].adjust.exposure == 0.99)
        state.removeMask(mask.id)
        await waitUntil("mask drag") { !state.previewing }
        print("PASS: mask drags save once and remain a single undo/redo step.")

        state.fullResPreview = true
        await waitUntil("full resolution") { !state.previewing }
        precondition(state.preview!.width == 2400)
        state.fullResPreview = false
        state.oneToOne = true
        await waitUntil("one-to-one") { !state.previewing }
        precondition(state.preview!.width == 2400)
        state.oneToOne = false
        await waitUntil("proxy") { !state.previewing }
        precondition(state.preview!.width == 2200)
        state.showBefore = true
        await waitUntil("before") { state.beforeImage != nil }
        state.select(0)
        precondition(state.beforeImage == nil)
        await waitUntil("before after selection") { state.beforeImage != nil && !state.previewing }
        print("PASS: full-resolution, 1:1 and before-image refresh after switching photos.")

        let output = root.appendingPathComponent("export.png")
        state.exportSettings = settings
        let exportSource = state.source!, exportParams = state.params
        state.exportCurrent(to: output)
        precondition(state.exportRunning)
        state.select(1)
        await waitUntil("export") { !state.exportRunning }
        let exported = Engine.decode(output)!
        precondition(exported.extent.width == 2400)
        let expectedURL = root.appendingPathComponent("expected.png")
        try Engine.write(Engine.render(exportSource, exportParams), to: expectedURL, settings: settings)
        precondition(pixels(exported) == pixels(Engine.decode(expectedURL)!))
        print("PASS: asynchronous export retains the source and settings captured at submission.")

        await waitUntil("workflow preview") { state.source != nil && !state.previewing }
        state.filterRating = 2
        state.filterPicked = true
        precondition(state.visiblePhotoIndices == [2] && state.nextVisiblePhotoIndex == 2)
        state.select(state.nextVisiblePhotoIndex!)
        await waitUntil("filtered navigation") { state.source != nil && !state.previewing }
        precondition(state.currentIndex == 2 && state.visiblePhotoPosition == 1 && state.nextVisiblePhotoIndex == nil)
        state.filterRating = 0
        state.filterPicked = false
        print("PASS: filtered navigation selects only visible photos.")

        let savedParams = state.params
        state.createSnapshot(name: "Studio regression")
        let snapshot = state.snapshots.last!
        state.set(\.exposure, -0.7); state.endEdit()
        state.restoreSnapshot(snapshot.id)
        precondition(state.params == savedParams)
        state.undo()
        precondition(state.params.exposure == -0.7)
        state.redo()
        precondition(state.params == savedParams)
        state.renameSnapshot(snapshot.id, name: "Studio renamed")
        precondition(SidecarStore.load(for: state.current!.url)!.snapshots.last!.name == "Studio renamed")
        var syncParams = savedParams
        syncParams.exposure = 0.6
        let targetURL = state.items[1].url
        let targetBefore = SidecarStore.load(for: targetURL)!
        await state.synchronize(syncParams, to: [targetURL], groups: [.tone])
        let targetAfter = SidecarStore.load(for: targetURL)!
        precondition(targetAfter.params.exposure == 0.6 && targetAfter.rating == targetBefore.rating)
        precondition(targetAfter.params.cropW == targetBefore.params.cropW && targetAfter.params.masks == targetBefore.params.masks)
        precondition(targetAfter.snapshots.last?.params == targetBefore.params)
        print("PASS: snapshots restore, undo/redo and rename; sync preserves untouched groups and creates a recovery snapshot.")

        let batchDir = root.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        state.set(\.exposure, 0.45)
        await state.batchExport(to: batchDir, onlyPicked: true)
        precondition(!state.batchRunning && state.batchProgress == 1)
        let batchFiles = try FileManager.default.contentsOfDirectory(atPath: batchDir.path)
        precondition(batchFiles == ["2.png"])
        precondition(SidecarStore.load(for: state.current!.url)!.params.exposure == 0.45)
        let batchImage = Engine.decode(batchDir.appendingPathComponent("2.png"))!
        let batchExpected = root.appendingPathComponent("batch-expected.png")
        try Engine.write(Engine.render(state.source!, state.params), to: batchExpected, settings: settings)
        precondition(pixels(batchImage) == pixels(Engine.decode(batchExpected)!))
        print("PASS: batch export saves pending current edits and exports only marked photos with matching pixels.")

        state.openFolder(photos)
        state.openFolder(empty)
        await waitUntil("empty folder") { state.status == "文件夹里没有支持的图像" }
        state.setRating(4)
        state.togglePick()
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(state.items.isEmpty && state.current == nil && state.source == nil
                     && state.preview == nil && state.beforeImage == nil)
        print("PASS: changing folders rejects previous jobs and empty-folder actions are safe.")
        print("Fixtures: \(root.path)")
    }

    @MainActor
    static func main() async throws {
        try brandCompatibilityTests()
        cacheTests()
        await queueTests()
        try await appTests()
        print("All performance regression tests passed.")
    }
}
