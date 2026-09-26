import Foundation
import CoreImage
import ImageIO
import CryptoKit

@main
struct WorkflowTest {
    static let output = URL(fileURLWithPath: "/tmp/rawforge-next-check")
    static func check(_ passed: @autoclosure () -> Bool, _ message: String) {
        guard passed() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }
    @MainActor
    static func wait(_ label: String, _ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(90)
        while !done() {
            precondition(Date() < deadline, label + " timeout")
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    static func rendered(_ image: CIImage) -> CGImage {
        guard let cg = Engine.ctx.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Engine.srgb) else {
            fatalError("No graphics service")
        }
        return cg
    }
    static func pixel(_ image: CIImage, at point: CGPoint) -> [Float] {
        let e = image.extent
        let bounds = CGRect(x: floor(e.minX + point.x * (e.width - 1)),
                            y: floor(e.minY + point.y * (e.height - 1)), width: 1, height: 1)
        var rgba = [Float](repeating: 0, count: 4)
        Engine.ctx.render(image, toBitmap: &rgba, rowBytes: 16, bounds: bounds,
                          format: .RGBAf, colorSpace: Engine.srgb)
        return rgba
    }
    static func write(_ image: CIImage, _ name: String) throws {
        var settings = ExportSettings()
        settings.format = "png"
        settings.maxLongEdge = 1200
        try Engine.write(image, to: output.appendingPathComponent(name + ".png"), settings: settings)
    }
    static func digest(_ image: CGImage) -> String {
        SHA256.hash(data: image.dataProvider!.data! as Data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func main() async throws {
        let inputs = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        check(inputs.count >= 2, "two real photo inputs")
        let originals = try inputs.map { try Data(contentsOf: $0) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photos = output.appendingPathComponent("photos-\(UUID())")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var copies: [URL] = []
        for (i, source) in inputs.enumerated() {
            let copy = photos.appendingPathComponent("\(i)-\(source.lastPathComponent)")
            try FileManager.default.copyItem(at: source, to: copy)
            copies.append(copy)
        }
        let image = Engine.decode(copies[0])!
        check(image.extent.width > 1000, "real photo decoding")
        let proxy = image.transformed(by: CGAffineTransform(scaleX: 1200 / image.extent.height,
                                                           y: 1200 / image.extent.height))
        try write(proxy, "01-original")

        // The paper photo supplies a photographed neutral patch, with a known warm cast applied.
        let paper = Engine.decode(copies[1])!
        let cast = paper.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.15, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0)
        ])
        let point = CGPoint(x: 0.86, y: 0.83)
        let gains = Engine.sampledWhiteBalance(cast, params: EditParams(), point: point)!
        var wb = EditParams(); wb.whiteBalanceGains = gains; wb.sharpen = 0
        let corrected = Engine.render(cast, wb)
        let before = pixel(cast, at: point), after = pixel(corrected, at: point)
        check(after.prefix(3).max()! - after.prefix(3).min()! < 0.025, "WB neutralizes a photographed paper patch")
        check(before.prefix(3).max()! - before.prefix(3).min()! > 0.1, "WB test starts with measurable color cast")
        try write(cast, "02-white-balance-before")
        try write(corrected, "03-white-balance-after")
        var transformed = EditParams()
        transformed.rotation = 90; transformed.cropX = 0.1; transformed.cropY = 0.15
        transformed.cropW = 0.7; transformed.cropH = 0.6
        let g1 = Engine.sampledWhiteBalance(cast, params: transformed, point: point)!
        let g2 = Engine.sampledWhiteBalance(Engine.geometry(cast, transformed), params: EditParams(), point: point)!
        check(zip(g1, g2).allSatisfy { abs($0 - $1) < 1e-8 }, "WB coordinate mapping honors crop and rotation")
        check(Engine.sampledWhiteBalance(CIImage(color: .white).cropped(to: paper.extent),
                                        params: EditParams(), point: point) == nil, "clipped white sample rejected")

        var mask = Mask(); mask.kind = .radial; mask.x0 = 0.5; mask.y0 = 0.65; mask.radius = 0.3
        mask.feather = 0.2; mask.adjust.exposure = 1.5
        var p = EditParams(); p.masks = [mask]
        var displayedMask: CIImage?
        let adjusted = Engine.render(proxy, p, selectedMask: mask.id) { displayedMask = $0 }
        let beforeMask = displayedMask!
        let center = CGPoint(x: 0.5, y: 0.65)
        check(pixel(beforeMask, at: center)[0] > 0.95, "selected mask exposes actual rendered selection")
        mask.refinements = [Stroke(pts: [[0.5, 0.65]], radius: 0.07, feather: 0.2, erasing: true)]
        p.masks = [mask]
        let erased = Engine.render(proxy, p, selectedMask: mask.id) { displayedMask = $0 }
        check(pixel(displayedMask!, at: center)[0] < 0.02, "eraser removes selected region")
        let basePixel = pixel(Engine.render(proxy, EditParams()), at: center)
        let erasePixel = pixel(erased, at: center)
        check(zip(basePixel, erasePixel).allSatisfy { abs($0 - $1) < 0.01 }, "erasing restores real photo pixels")
        mask.refinements.append(Stroke(pts: [[0.5, 0.65]], radius: 0.035, feather: 0.1))
        p.masks = [mask]
        _ = Engine.render(proxy, p, selectedMask: mask.id) { displayedMask = $0 }
        check(pixel(displayedMask!, at: center)[0] > 0.95, "painting restores an erased region")
        p.masks[0].refinements.removeLast()
        var overlayMask: CIImage?
        _ = Engine.render(proxy, p, selectedMask: mask.id) { overlayMask = $0 }
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.45)).cropped(to: erased.extent)
        let preview = red.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: erased, kCIInputMaskImageKey: overlayMask!
        ])
        try write(adjusted, "04-mask-adjustment")
        try write(erased, "05-mask-erased")
        try write(preview, "06-mask-overlay")
        let decoded = try JSONDecoder().decode(EditParams.self, from: JSONEncoder().encode(p))
        check(decoded == p, "erase strokes survive sidecar encoding")

        for space in ExportColorSpace.allCases {
            for depth in [8, 16] {
                var settings = ExportSettings()
                settings.format = "tiff"; settings.tiffBitDepth = depth; settings.colorSpace = space
                settings.maxLongEdge = 900
                let dest = output.appendingPathComponent("export-\(space.rawValue)-\(depth).tiff")
                try Engine.write(Engine.render(image, p), to: dest, settings: settings)
                let src = CGImageSourceCreateWithURL(dest as CFURL, nil)!
                let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                check(cg.bitsPerComponent == depth, "\(space.label) TIFF is truly \(depth)-bit")
                check(max(cg.width, cg.height) == 900, "TIFF output size")
                check(cg.colorSpace?.name == space.cgColorSpace.name, "TIFF embeds \(space.label) profile")
                if depth == 16 {
                    let data = cg.dataProvider!.data! as Data
                    let levels = data.withUnsafeBytes { raw -> Set<UInt16> in
                        Set(raw.bindMemory(to: UInt16.self).prefix(900 * 100))
                    }
                    check(levels.count > 256, "16-bit TIFF contains more than 256 sample levels")
                }
            }
        }
        var alphaSettings = ExportSettings(); alphaSettings.format = "tiff"
        let alpha = proxy.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)])
        let alphaURL = output.appendingPathComponent("export-alpha16.tiff")
        try Engine.write(alpha, to: alphaURL, settings: alphaSettings)
        check(abs(pixel(Engine.decode(alphaURL)!, at: center)[3] - 0.5) < 0.02, "16-bit TIFF preserves transparency")

        let state = AppState()
        state.openFolder(photos)
        await wait("photo ready") { state.source != nil && !state.previewing }
        state.commit(p)
        state.createSnapshot(name: "实图 · 局部提亮")
        let snap = state.snapshots[0]
        state.set(\.exposure, 1.25); state.endEdit()
        state.restoreSnapshot(snap.id)
        check(state.params == p, "named snapshot restores exact settings")
        state.undo()
        check(state.params.exposure == 1.25, "snapshot restore is undoable")
        state.redo()
        check(state.params == p, "snapshot restore is redoable")
        state.renameSnapshot(snap.id, name: "保留版本")
        state.select(1); state.select(0)
        await wait("reload") { state.source != nil && !state.previewing }
        check(state.snapshots.first?.name == "保留版本", "snapshot survives photo switch and disk reload")

        var target = EditParams(); target.cropX = 0.1; target.cropW = 0.75
        target.exposure = -0.3; target.masks = [Mask()]
        let targetSnapshot = EditSnapshot(name: "目标原版", params: target)
        try SidecarStore.write(Sidecar(params: target, rating: 4, picked: true, snapshots: [targetSnapshot]), for: copies[1])
        var source = p; source.exposure = 0.8; source.whiteBalanceGains = gains
        await state.synchronize(source, to: [copies[1]], groups: EditGroup.defaults)
        let saved = try SidecarStore.read(for: copies[1])!
        check(saved.params.exposure == 0.8 && saved.params.whiteBalanceGains == gains, "batch sync applies selected groups")
        check(saved.params.cropX == target.cropX && saved.params.masks == target.masks, "default batch sync preserves geometry and masks")
        check(saved.rating == 4 && saved.picked && saved.snapshots.count == 2, "batch sync preserves rating, pick and snapshots")
        check(saved.snapshots.last!.params == target, "batch sync creates recoverable pre-sync snapshot")
        let all = EditGroup.applying(source, to: target, groups: Set(EditGroup.allCases))
        check(all.masks[0].id != source.masks[0].id, "copied masks have new IDs for independent AI caches")
        let selective = EditGroup.applying(source, to: target, groups: [.whiteBalance])
        check(selective.exposure == target.exposure, "unchecked groups stay untouched")

        let legacyPhoto = output.appendingPathComponent("legacy-\(UUID()).jpg")
        let legacyPath = legacyPhoto.deletingPathExtension().appendingPathExtension("rawforge.json")
        let legacy = #"{"version":1,"app":"RawForge","params":{"exposure":0.4,"masks":[{"kind":"brush","strokes":[{"pts":[[0.5,0.5]],"radius":0.1,"feather":0.3}]}]}}"#.data(using: .utf8)!
        try legacy.write(to: legacyPath, options: .atomic)
        let legacySidecar = try SidecarStore.read(for: legacyPhoto)!
        check(legacySidecar.snapshots.isEmpty && legacySidecar.params.whiteBalanceGains == [1,1,1], "legacy sidecars decode with new defaults")
        check(!legacySidecar.params.masks[0].strokes[0].erasing, "legacy brush strokes remain additive")
        let sameName = legacyPhoto.deletingPathExtension().appendingPathExtension("HIF")
        try SidecarStore.write(Sidecar(params: source), for: legacyPhoto)
        try SidecarStore.write(Sidecar(params: target), for: sameName)
        check(SidecarStore.load(for: legacyPhoto)!.params != SidecarStore.load(for: sameName)!.params, "same-name JPEG/HIF get independent sidecars")
        let legacyAfter = try Data(contentsOf: legacyPath)
        check(legacyAfter == legacy, "legacy edit file remains untouched")

        let broken = output.appendingPathComponent("broken.jpg")
        let bad = Data("not JSON".utf8)
        try bad.write(to: SidecarStore.url(for: broken))
        let result = BatchEditor.apply(source, to: [broken], groups: [.tone])
        check(result.failures.count == 1 && result.succeeded.isEmpty, "corrupt batch target reports failure")
        let brokenAfter = try Data(contentsOf: SidecarStore.url(for: broken))
        check(brokenAfter == bad, "corrupt edit file is not overwritten")
        for (i, original) in inputs.enumerated() {
            let unchanged = try Data(contentsOf: original)
            check(unchanged == originals[i], "original photo \(i + 1) unchanged")
        }
        print("REAL PHOTO FIXTURES: \(photos.path)")
        print("ARTIFACTS: \(output.path)")
        print("All next-version tests passed.")
    }
}
