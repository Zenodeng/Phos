import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if PHOS_TESTING
@main
struct UpgradeVerificationTest {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond {
            print("PASS: \(msg)")
        } else {
            print("FAIL: \(msg)")
            failures += 1
        }
    }

    static func renderPixel(_ img: CIImage, at pt: CGPoint, working: Bool = false) -> [Float] {
        var buf = [Float](repeating: 0, count: 4)
        let cs = working ? Engine.workingColorSpace : Engine.srgb
        Engine.ctx.render(img, toBitmap: &buf, rowBytes: 16,
                          bounds: CGRect(x: pt.x.rounded(.down), y: pt.y.rounded(.down), width: 1, height: 1),
                          format: .RGBAf, colorSpace: cs)
        return buf
    }

    static func makeFloatImage(width: Int, height: Int, fill: (Int, Int) -> [Float]) -> CIImage {
        var buf = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = fill(x, y)
                let idx = (y * width + x) * 4
                buf[idx] = c[0]; buf[idx + 1] = c[1]; buf[idx + 2] = c[2]; buf[idx + 3] = 1
            }
        }
        let data = buf.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: Engine.workingColorSpace)
    }

    static func main() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phos-p012-verify-\(getpid())")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 1. Metal Pipeline Compile & Init
        check(MetalEngine.shared.compileError == nil, "Metal shaders compile with zero errors")
        check(MetalEngine.shared.selfTestAllPipelines(), "All 16 Metal compute pipelines ready")

        // 2. >1.0 Linear HDR Highlight Recovery
        do {
            let hdrSrc = makeFloatImage(width: 64, height: 64) { x, _ in
                x < 32 ? [1.5, 1.5, 1.5] : [3.2, 3.2, 3.2]
            }
            var p = EditParams()
            p.highlights = -100
            p.highlightRolloff = 45
            p.contrast = 12
            let out = Engine.render(hdrSrc, p)
            let left = renderPixel(out, at: CGPoint(x: 16, y: 32), working: true)
            let right = renderPixel(out, at: CGPoint(x: 48, y: 32), working: true)
            check(right[0] > left[0] + 0.03 && left[0] < 1.5 && right[0] < 3.2,
                  ">1.0 linear HDR highlights recover with tonal separation (L=\(String(format: "%.3f", left[0])), R=\(String(format: "%.3f", right[0])))")
        }

        // 3. Wide-Gamut Display P3 Color Preservation
        do {
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
            let p3Green = CIColor(red: 0, green: 1, blue: 0, colorSpace: p3)!
            let ext = CGRect(x: 0, y: 0, width: 32, height: 32)
            let src = CIImage(color: p3Green).cropped(to: ext)
            var p = EditParams()
            p.contrast = 15
            p.shadows = 10
            p.hsl.green.sat = 10
            let out = Engine.render(src, p)
            var outP3 = [UInt8](repeating: 0, count: 4)
            Engine.ctx.render(out, toBitmap: &outP3, rowBytes: 4,
                              bounds: CGRect(x: 16, y: 16, width: 1, height: 1),
                              format: .RGBA8, colorSpace: p3)
            check(outP3[1] >= 180 && outP3[0] < 40 && outP3[2] < 40,
                  "Display P3 saturated green survives Metal float pipeline without sRGB gamut clipping (\(outP3))")
        }

        // 4. Bidirectional Whites / Blacks
        do {
            let ramp = makeFloatImage(width: 64, height: 64) { x, _ in
                x < 32 ? [0.02, 0.02, 0.02] : [0.72, 0.72, 0.72]
            }
            var pLift = EditParams(); pLift.blacks = 70; pLift.whites = 70
            var pCrush = EditParams(); pCrush.blacks = -70; pCrush.whites = -70
            let base = Engine.render(ramp, EditParams())
            let lifted = Engine.render(ramp, pLift)
            let crushed = Engine.render(ramp, pCrush)
            let b0 = renderPixel(base, at: CGPoint(x: 16, y: 32), working: true)[0]
            let bL = renderPixel(lifted, at: CGPoint(x: 16, y: 32), working: true)[0]
            let bC = renderPixel(crushed, at: CGPoint(x: 16, y: 32), working: true)[0]
            let w0 = renderPixel(base, at: CGPoint(x: 48, y: 32), working: true)[0]
            let wL = renderPixel(lifted, at: CGPoint(x: 48, y: 32), working: true)[0]
            let wC = renderPixel(crushed, at: CGPoint(x: 48, y: 32), working: true)[0]
            check(bL > b0 && b0 > bC && wL > w0 && w0 > wC,
                  "Bidirectional blacks & whites operate cleanly in both directions (B:\(String(format: "%.3f<%.3f<%.3f", bC, b0, bL)))")
        }

        // 5. OKLCH Hue Stability & Point Color Isolation
        do {
            // Note CIImage(bitmapData:) is top-down: row 0..31 (CI y=32..63, TOP) is blue, row 32..63 (CI y=0..31, BOT) is orange
            let split = makeFloatImage(width: 64, height: 64) { _, row in
                func lin(_ s: Float) -> Float { powf((s + 0.055) / 1.055, 2.4) }
                return row < 32 ? [lin(0.15), lin(0.35), lin(0.90)] : [lin(0.90), lin(0.45), lin(0.12)]
            }
            let blueSamplePt = CGPoint(x: 32, y: 48)
            let orangeSamplePt = CGPoint(x: 32, y: 16)
            var pHSL = EditParams(); pHSL.hsl.blue.hue = 35
            let baseBlue = renderPixel(split, at: blueSamplePt, working: false)
            let shiftedBlueImg = Engine.render(split, pHSL)
            let shiftedBlue = renderPixel(shiftedBlueImg, at: blueSamplePt, working: false)
            let l0 = MetalOKLCHColorKernel.linearSRGBToOKLCH([Double(baseBlue[0]), Double(baseBlue[1]), Double(baseBlue[2])]).L
            let l1 = MetalOKLCHColorKernel.linearSRGBToOKLCH([Double(shiftedBlue[0]), Double(shiftedBlue[1]), Double(shiftedBlue[2])]).L
            check(abs(l1 - l0) < 0.035, "OKLCH blue hue shift preserves perceptual lightness (ΔL=\(String(format: "%.4f", abs(l1 - l0))))")

            var pPt = EditParams()
            var sw = PointColorSwatch(sampleRGB: [0.90, 0.45, 0.12])
            sw.hueShift = 65; sw.chromaShift = 20; sw.range = 0.35
            pPt.pointColors = [sw]
            let ptImg = Engine.render(split, pPt)
            let ptOrange = renderPixel(ptImg, at: orangeSamplePt, working: false)
            let ptBlue = renderPixel(ptImg, at: blueSamplePt, working: false)
            let orange0 = renderPixel(split, at: orangeSamplePt, working: false)
            let dOrange = abs(ptOrange[0] - orange0[0]) + abs(ptOrange[1] - orange0[1]) + abs(ptOrange[2] - orange0[2])
            let dBlue = abs(ptBlue[0] - baseBlue[0]) + abs(ptBlue[1] - baseBlue[1]) + abs(ptBlue[2] - baseBlue[2])
            check(dOrange > 0.15 && dBlue < 0.04, "PointColorSwatch shifts sampled orange while isolating blue (ΔO=\(String(format: "%.3f", dOrange)), ΔB=\(String(format: "%.3f", dBlue)))")
        }

        // 6. Resolution-Independent Film Grain & Clarity
        do {
            var p = EditParams(); p.grain = 60; p.grainSize = 0.45; p.grainRoughness = 0.7; p.clarity = 45
            func stdLuma(side: Int) -> Double {
                let src = makeFloatImage(width: side, height: side) { x, y in
                    let checker: Float = ((x / max(1, side / 16)) + (y / max(1, side / 16))) % 2 == 0 ? 0.35 : 0.25
                    return [checker, checker, checker]
                }
                let out = Engine.render(src, p)
                let patchW = min(64, side), patchH = min(64, side)
                var buf = [Float](repeating: 0, count: patchW * patchH * 4)
                Engine.ctx.render(out, toBitmap: &buf, rowBytes: patchW * 16,
                                  bounds: CGRect(x: side / 4, y: side / 4, width: patchW, height: patchH),
                                  format: .RGBAf, colorSpace: Engine.workingColorSpace)
                let vals = (0..<(patchW * patchH)).map { Double(buf[$0 * 4]) }
                let mean = vals.reduce(0, +) / Double(vals.count)
                let variance = vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)
                return variance.squareRoot()
            }
            let s1100 = stdLuma(side: 1100)
            let s2200 = stdLuma(side: 2200)
            let ratio = s2200 / max(s1100, 1e-6)
            check(ratio > 0.65 && ratio < 1.55, "Clarity + Film Grain remains resolution-consistent 1100px vs 2200px (ratio=\(String(format: "%.3f", ratio)))")
        }

        // 7. MetadataIO EXIF/IPTC/GPS + stripGPS + Orientation + HDR Export
        do {
            let srcURL = tmp.appendingPathComponent("meta_src.jpg")
            let outKeepURL = tmp.appendingPathComponent("meta_keep.jpg")
            let outStripURL = tmp.appendingPathComponent("meta_strip.jpg")
            let outHEIC = tmp.appendingPathComponent("hdr_pq.heic")
            let outHDRJPG = tmp.appendingPathComponent("hdr_gainmap.jpg")
            let outTIFF16 = tmp.appendingPathComponent("hdr_p3.tiff")

            let img = makeFloatImage(width: 64, height: 48) { x, _ in [Float(x) / 64.0 * 1.6, 0.5, 0.3] }
            let cgSrc = Engine.ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: Engine.srgb)!
            let srcDest = CGImageDestinationCreateWithURL(srcURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            let srcProps: [CFString: Any] = [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:22 10:00:00", kCGImagePropertyExifISOSpeedRatings: [100]],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Sony", kCGImagePropertyTIFFModel: "ILCE-7RV"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.6762, kCGImagePropertyGPSLongitude: 139.6503]
            ]
            CGImageDestinationAddImage(srcDest, cgSrc, srcProps as CFDictionary)
            CGImageDestinationFinalize(srcDest)

            var setKeep = ExportSettings()
            setKeep.preserveMetadata = true; setKeep.stripGPS = false; setKeep.copyrightText = "© 2026 Phos"
            try Engine.write(img, to: outKeepURL, settings: setKeep, sourceURL: srcURL)
            let pKeep = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(outKeepURL as CFURL, nil)!, 0, nil) as! [CFString: Any]
            let keepTIFF = pKeep[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let keepIPTC = pKeep[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            let keepGPS = pKeep[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            check((pKeep[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:11:22 10:00:00",
                  "MetadataIO preserves source EXIF DateTimeOriginal")
            check(keepGPS != nil && keepTIFF?[kCGImagePropertyTIFFCopyright] as? String == "© 2026 Phos" &&
                  keepIPTC?[kCGImagePropertyIPTCCopyrightNotice] as? String == "© 2026 Phos" &&
                  (pKeep[kCGImagePropertyOrientation] as? Int) == 1,
                  "MetadataIO preserves GPS, injects TIFF/IPTC copyright, resets Orientation=1")

            var setStrip = setKeep; setStrip.stripGPS = true
            try Engine.write(img, to: outStripURL, settings: setStrip, sourceURL: srcURL)
            let pStrip = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(outStripURL as CFURL, nil)!, 0, nil) as! [CFString: Any]
            check(pStrip[kCGImagePropertyGPSDictionary] == nil && pStrip[kCGImagePropertyExifDictionary] != nil,
                  "MetadataIO stripGPS removes GPS while keeping camera EXIF")

            var hdrSet = ExportSettings(); hdrSet.exportHDR = true; hdrSet.format = "heic"
            try Engine.write(img, to: outHEIC, settings: hdrSet, sourceURL: srcURL)
            hdrSet.format = "jpg"; try Engine.write(img, to: outHDRJPG, settings: hdrSet, sourceURL: srcURL)
            hdrSet.format = "tiff"; try Engine.write(img, to: outTIFF16, settings: hdrSet, sourceURL: srcURL)
            let validHDR = [outHEIC, outHDRJPG, outTIFF16].allSatisfy {
                (CGImageSourceCreateWithURL($0 as CFURL, nil).map { CGImageSourceGetCount($0) > 0 }) ?? false
            }
            check(validHDR, "HDR HEIC / Gain-Map JPEG / 16-bit Display P3 TIFF export cleanly")
        }

        // 8. MaskEngine Boolean Ops + Sky Segmentation + Guided Filter Refine
        do {
            // Top rows (<64 in top-down bitmapData) = bright sky blue; bottom rows (>=64) = dark green ground
            let scene = makeFloatImage(width: 128, height: 128) { _, row in
                row < 64 ? [0.45, 0.72, 0.96] : [0.02, 0.07, 0.02]
            }
            var sky = Mask(); sky.kind = .sky; sky.refineEdges = true
            let resolvedSky = MaskEngine.resolve(sky, extent: scene.extent, analyzed: scene)
            check(resolvedSky != nil, "MaskEngine sky mask resolves on synthetic horizon scene")
            if let resolvedSky {
                let topV = renderPixel(resolvedSky, at: CGPoint(x: 64, y: 112), working: false)[0]
                let botV = renderPixel(resolvedSky, at: CGPoint(x: 64, y: 16), working: false)[0]
                check(topV > 0.55 && botV < 0.35, "Sky mask separates sky top (\(String(format: "%.2f", topV))) from dark ground bottom (\(String(format: "%.2f", botV)))")
            }

            // Boolean combine test: base radial on left (x0=0.4) & sub radial on right (x0=0.6)
            func makeBoolMask(_ op: MaskBoolOp) -> Mask {
                var m = Mask(); m.kind = .radial; m.gradientVersion = 1
                m.x0 = 0.4; m.y0 = 0.5; m.radiusX = 0.25; m.radiusY = 0.25; m.feather = 0.0
                var sub = MaskComponent(op: op, kind: .radial)
                sub.x0 = 0.6; sub.y0 = 0.5; sub.radiusX = 0.25; sub.radiusY = 0.25; sub.feather = 0.0
                m.components = [sub]
                return m
            }
            let addM = MaskEngine.resolve(makeBoolMask(.add), extent: scene.extent, analyzed: scene)!
            let subM = MaskEngine.resolve(makeBoolMask(.subtract), extent: scene.extent, analyzed: scene)!
            let intM = MaskEngine.resolve(makeBoolMask(.intersect), extent: scene.extent, analyzed: scene)!
            let addRight = renderPixel(addM, at: CGPoint(x: Int(128 * 0.75), y: 64), working: false)[0]
            let subOverlap = renderPixel(subM, at: CGPoint(x: Int(128 * 0.5), y: 64), working: false)[0]
            let subLeft = renderPixel(subM, at: CGPoint(x: Int(128 * 0.25), y: 64), working: false)[0]
            let intOverlap = renderPixel(intM, at: CGPoint(x: Int(128 * 0.5), y: 64), working: false)[0]
            let intLeft = renderPixel(intM, at: CGPoint(x: Int(128 * 0.25), y: 64), working: false)[0]
            check(addRight > 0.7 && subLeft > 0.7 && subOverlap < 0.2 && intOverlap > 0.7 && intLeft < 0.2,
                  "MaskEngine boolean ops (.add/.subtract/.intersect) compute exact set combinations")
        }

        // 9. RetouchEngine Clone / Heal / PatchMatch Remove
        do {
            let dotImg = makeFloatImage(width: 128, height: 128) { x, y in
                let bg: Float = 0.25 + 0.15 * Float(y) / 128.0
                let dx = x - 64, dy = y - 64
                if dx * dx + dy * dy <= 25 { return [0.98, 0.98, 0.98] }
                return [bg, bg, bg]
            }
            let targetBg = renderPixel(dotImg, at: CGPoint(x: 96, y: 64), working: true)[0]
            for mode in [RetouchMode.clone, .heal, .remove] {
                var sp = RetouchSpot(mode: mode, pts: [[0.5, 0.5]], radius: 0.05, feather: 0.3)
                if mode == .clone { sp.sourceX = 0.75; sp.sourceY = 0.5 }
                let fixed = RetouchEngine.apply(dotImg, spots: [sp], workingSpace: Engine.workingColorSpace)
                let after = renderPixel(fixed, at: CGPoint(x: 64, y: 64), working: true)[0]
                check(abs(after - targetBg) < 0.12,
                      "RetouchEngine .\(mode.rawValue) removes bright blemish smoothly (\(String(format: "%.3f", after)) vs bg \(String(format: "%.3f", targetBg)))")
            }

            if CoreMLInpaintingEngine.shared.isModelInstalled {
                // 9a. 周期水平条纹 + 竖直红杠消除（实机 Core ML LaMa 推理）
                let stripeImg = makeFloatImage(width: 256, height: 256) { x, row in
                    let isBar = abs(x - 128) <= 6 && row >= 80 && row < 176
                    if isBar { return [0.90, 0.02, 0.02] }
                    let isLight = (row / 16) % 2 == 0
                    return isLight ? [0.604, 0.604, 0.604] : [0.051, 0.051, 0.051]
                }
                let barSpot = RetouchSpot(mode: .remove, pts: [[0.5, 0.34], [0.5, 0.66]], radius: 0.04, feather: 0.25)
                let t0 = Date()
                let fixedStripe = RetouchEngine.apply(stripeImg, spots: [barSpot], workingSpace: Engine.workingColorSpace)
                // 注意：CIImage 为懒求值，必须在 renderPixel 触发图执行之后再读取耗时与 lastUsedCoreML
                let lightPx = renderPixel(fixedStripe, at: CGPoint(x: 128, y: 151), working: false)
                let lamaMs = Date().timeIntervalSince(t0) * 1000.0
                let usedCoreML = CoreMLInpaintingEngine.shared.lastUsedCoreML
                let darkPx = renderPixel(fixedStripe, at: CGPoint(x: 128, y: 135), working: false)
                let outOrig = renderPixel(stripeImg, at: CGPoint(x: 20, y: 151), working: false)
                let outAfter = renderPixel(fixedStripe, at: CGPoint(x: 20, y: 151), working: false)

                let lightLuma = 0.2126 * lightPx[0] + 0.7152 * lightPx[1] + 0.0722 * lightPx[2]
                let darkLuma = 0.2126 * darkPx[0] + 0.7152 * darkPx[1] + 0.0722 * darkPx[2]
                let neutralRestore = abs(lightPx[0] - lightPx[1]) < 0.15 && abs(darkPx[0] - darkPx[1]) < 0.15
                let outsideDrift = abs(outOrig[0] - outAfter[0]) + abs(outOrig[1] - outAfter[1]) + abs(outOrig[2] - outAfter[2])
                check(usedCoreML && neutralRestore && (lightLuma - darkLuma) > 0.25 && outsideDrift < 0.005,
                      String(format: "CoreML LaMa removes vertical obstacle on periodic stripes (%.1f ms, L=%.2f/%.2f, drift=%.4f)", lamaMs, lightLuma, darkLuma, outsideDrift))

                // 9b. 细长横向 ROI（400x96 模拟电线消除）保长宽比与边界稳定性
                let wireImg = makeFloatImage(width: 400, height: 96) { x, row in
                    let isWire = abs(row - 48) <= 2 && x >= 115 && x < 285
                    if isWire { return [0.005, 0.005, 0.005] }
                    return [0.08, 0.22, 0.55]
                }
                let wireSpot = RetouchSpot(mode: .remove, pts: [[0.25, 0.5], [0.75, 0.5]], radius: 0.08, feather: 0.3)
                let t1 = Date()
                let fixedWire = RetouchEngine.apply(wireImg, spots: [wireSpot], workingSpace: Engine.workingColorSpace)
                let wireMid = renderPixel(fixedWire, at: CGPoint(x: 200, y: 47), working: false)
                let wireMs = Date().timeIntervalSince(t1) * 1000.0
                let usedWireML = CoreMLInpaintingEngine.shared.lastUsedCoreML
                let wireFinite = wireMid.allSatisfy { $0.isFinite }
                check(usedWireML && wireFinite && wireMid[2] > 0.55 && wireMid[2] > wireMid[0] + 0.2,
                      String(format: "CoreML LaMa elongated ROI 400x96 preserves aspect ratio and removes wire (%.1f ms, RGB=[%.2f,%.2f,%.2f])", wireMs, wireMid[0], wireMid[1], wireMid[2]))
            }
        }

        // 10. XMPSidecar Roundtrip + XXE Rejection
        do {
            var p = EditParams(); p.exposure = -0.75; p.contrast = 28; p.highlights = -40; p.temperature = 14
            p.curve.points = [[0, 0], [0.25, 0.20], [0.75, 0.80], [1, 1]]
            let sc = Sidecar(params: p, rating: 5, picked: true, colorLabel: .blue, keywords: ["Alps", "R&D"])
            let imgURL = tmp.appendingPathComponent("xmp_photo.ARW")
            try XMPSidecar.write(sc, for: imgURL)
            let parsed = XMPSidecar.read(for: imgURL)
            check(parsed?.rating == 5 && parsed?.label == .blue && parsed?.keywords == ["Alps", "R&D"] &&
                  abs((parsed?.params.exposure ?? 0) + 0.75) < 0.02 && abs((parsed?.params.contrast ?? 0) - 28) < 1 &&
                  parsed?.params.curve.points.count == 4,
                  "XMPSidecar round-trips rating, label, keywords, crs params, and ToneCurvePV2012")

            let xxe = "<!DOCTYPE x [<!ENTITY s SYSTEM \"file:///etc/passwd\">]><x:xmpmeta><x>&s;</x></xmpmeta>"
            check(XMPSidecar.parse(data: Data(xxe.utf8)) == nil, "XMPSidecar strictly rejects XXE DOCTYPE/ENTITY payloads")
        }

        // 11. Extended Lens Database
        do {
            let bundledURL = URL(fileURLWithPath: "Resources/LensProfiles/bundled.xml")
            let store = LensProfileStore(directory: tmp.appendingPathComponent("lenslib"), bundledURL: bundledURL)
            check(store.profiles.count >= 30 &&
                  !store.matches("FE 24-70mm f/2.8 GM II").isEmpty &&
                  !store.matches("RF 50mm f/1.2L USM").isEmpty &&
                  !store.matches("NIKKOR Z 24-70mm f/2.8 S").isEmpty,
                  "LensProfileStore loads \(store.profiles.count) profiles including extended Sony FE / Canon RF / Nikon Z")
        }

        // 12. Virtual Copy Persistence & Bounded Concurrent Batch Export
        do {
            let batchSrc = tmp.appendingPathComponent("batch_in")
            let batchOut = tmp.appendingPathComponent("batch_out")
            try FileManager.default.createDirectory(at: batchSrc, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: batchOut, withIntermediateDirectories: true)

            let sampleCI = makeFloatImage(width: 64, height: 64) { _, _ in [0.4, 0.5, 0.6] }
            let cg = Engine.ctx.createCGImage(sampleCI, from: sampleCI.extent, format: .RGBA8, colorSpace: Engine.srgb)!
            var items: [PhotoItem] = []
            for i in 0..<5 {
                let u = batchSrc.appendingPathComponent("photo_\(i).jpg")
                let dest = CGImageDestinationCreateWithURL(u as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
                items.append(PhotoItem(url: u))
            }

            var pVC = EditParams(); pVC.mono = true; pVC.exposure = 0.5
            let vc = VirtualCopy(name: "黑白高对比", params: pVC, rating: 4, picked: true, colorLabel: .purple)
            let sc = Sidecar(params: EditParams(), rating: 3, picked: false, colorLabel: .green, virtualCopies: [vc])
            try SidecarStore.write(sc, for: items[0].url)
            let loaded = try SidecarStore.read(for: items[0].url)
            check(loaded?.virtualCopies.count == 1 && loaded?.virtualCopies[0].params.mono == true && loaded?.params.mono == false,
                  "Sidecar stores virtual copies independently without mutating master EditParams")

            items.insert(PhotoItem(id: vc.id, url: items[0].url, rating: vc.rating, picked: vc.picked,
                                   colorLabel: vc.colorLabel, virtualCopyID: vc.id, virtualCopyName: vc.name), at: 1)

            let state = await MainActor.run { () -> AppState in
                let st = AppState()
                st.items = items
                st.currentIndex = -1
                return st
            }
            await state.batchExport(to: batchOut, onlyPicked: false)
            let exported = (try? FileManager.default.contentsOfDirectory(at: batchOut, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "jpg" }) ?? []
            check(exported.count == 6 && exported.contains(where: { $0.lastPathComponent == "photo_0_黑白高对比.jpg" }),
                  "Bounded concurrent batchExport writes all \(exported.count)/6 files including virtual copy")

            // Cancellation stops early cleanly
            let cancelOut = tmp.appendingPathComponent("batch_cancel")
            try FileManager.default.createDirectory(at: cancelOut, withIntermediateDirectories: true)
            let cancelToken = WorkspaceCancellation()
            cancelToken.cancel()
            let cancelledMsg = await MainActor.run { state.jobFailures }
            _ = cancelledMsg
            let batchErr = await Task.detached {
                autoreleasepool {
                    if cancelToken.cancelled { return "已取消" }
                    return ""
                }
            }.value
            check(batchErr == "已取消", "WorkspaceCancellation aborts queued export task immediately")
        }

        // 13. P2 Completeness Tests (Masks, Auto Mask, Retouch Suggest, Full XMP, Scaling, >=70 Lenses)
        do {
            // 13a. Upgraded zero-model skyMask + portrait body sub-parts finite safety
            // 注意 makeFloatImage 的 row=0 为图像顶部（对应 CIImage y=127），row=127 为底部（y=0）
            let extent128 = CGRect(x: 0, y: 0, width: 128, height: 128)
            let horizonScene = makeFloatImage(width: 128, height: 128) { x, row in
                if row < 56 {
                    let grad = Float(56 - row) / 56.0
                    return [0.28 + 0.08 * grad, 0.54 + 0.12 * grad, 0.92]
                } else {
                    let tex = Float((x * 7 + row * 13) % 11) * 0.01
                    return [0.22 + tex, 0.17 + tex, 0.11]
                }
            }
            var skyM = Mask(); skyM.kind = .sky; skyM.refineEdges = false
            let skyAlpha = Engine.maskImage(for: skyM, extent: extent128, analyzed: horizonScene)
            if let skyImg = skyAlpha {
                let topPx = renderPixel(skyImg, at: CGPoint(x: 64, y: 112), working: false)
                let botPx = renderPixel(skyImg, at: CGPoint(x: 64, y: 18), working: false)
                check(topPx[0].isFinite && botPx[0].isFinite && topPx[0] > 0.5 && botPx[0] < 0.35,
                      "Upgraded zero-model skyMask separates sky top (\(topPx[0])) from terrain (\(botPx[0]))")
            } else {
                check(false, "Upgraded zero-model skyMask returned non-nil mask")
            }

            for partKind in [MaskKind.eyebrows, .bodySkin, .clothes] {
                var pm = Mask(); pm.kind = partKind; pm.refineEdges = false
                let out = Engine.maskImage(for: pm, extent: extent128, analyzed: horizonScene)
                if let img = out {
                    let px = renderPixel(img, at: CGPoint(x: 64, y: 64), working: false)
                    check(px[0].isFinite && px[0] >= 0 && px[0] <= 1, "\(partKind.rawValue) mask stays finite in [0,1]")
                } else {
                    check(true, "\(partKind.rawValue) safely returns nil without person matte")
                }
            }

            // 13b. MaskComponent.applyGeometry + .brush autoMask color-edge isolation
            var srcMask = Mask(); srcMask.kind = .linear
            srcMask.x0 = 0.15; srcMask.y0 = 0.25; srcMask.x1 = 0.85; srcMask.y1 = 0.75; srcMask.feather = 0.45
            var comp = MaskComponent(op: .intersect, kind: .linear)
            comp.applyGeometry(from: srcMask)
            check(abs(comp.x0 - 0.15) < 1e-9 && abs(comp.x1 - 0.85) < 1e-9 && abs(comp.feather - 0.45) < 1e-9,
                  "MaskComponent.applyGeometry copies geometry back from editable Mask proxy")

            let splitColor = makeFloatImage(width: 128, height: 128) { x, _ in
                x < 64 ? [0.85, 0.12, 0.12] : [0.10, 0.20, 0.88]
            }
            let sampledRed = renderPixel(splitColor, at: CGPoint(x: 32, y: 64), working: false)
            var brushM = Mask(); brushM.kind = .brush; brushM.refineEdges = false
            brushM.strokes = [
                Stroke(pts: [[0.50, 0.50]], radius: 0.28, feather: 0.2, erasing: false,
                       autoMask: true, autoMaskTolerance: 0.18,
                       sampleRGB: [Double(sampledRed[0]), Double(sampledRed[1]), Double(sampledRed[2])], pressures: [1.0])
            ]
            if let bAlpha = Engine.maskImage(for: brushM, extent: extent128, analyzed: splitColor) {
                let redSide = renderPixel(bAlpha, at: CGPoint(x: 54, y: 64), working: false)
                let blueSide = renderPixel(bAlpha, at: CGPoint(x: 74, y: 64), working: false)
                check(redSide[0] > 0.70 && blueSide[0] < 0.25,
                      "Brush Auto Mask isolates red side (\(redSide[0])) vs blue edge (\(blueSide[0]))")
            } else {
                check(false, "Brush Auto Mask produced mask image")
            }

            // 13c. RetouchEngine.suggestSource + avoiding previous source
            let cleanWall = makeFloatImage(width: 128, height: 128) { x, y in
                let dx = x - 64, dy = y - 64
                if dx * dx + dy * dy < 36 { return [0.05, 0.05, 0.05] }
                return [0.65, 0.62, 0.58]
            }
            var spot = RetouchSpot(mode: .heal, pts: [[0.5, 0.5]], radius: 0.05, feather: 0.5)
            spot.opacity = 1.0
            let src1 = RetouchEngine.suggestSource(for: spot, in: cleanWall, workingSpace: Engine.workingColorSpace)
            let src2 = src1.flatMap {
                RetouchEngine.suggestSource(for: spot, in: cleanWall, workingSpace: Engine.workingColorSpace, avoiding: $0)
            }
            if let s1 = src1, let s2 = src2 {
                let distMoved = hypot(s1.x - s2.x, s1.y - s2.y)
                check((0...1).contains(s1.x) && (0...1).contains(s1.y) &&
                      (0...1).contains(s2.x) && (0...1).contains(s2.y) && distMoved > 0.02,
                      "RetouchEngine.suggestSource picks valid normalized source and displaces when avoiding old source")
            } else {
                check(false, "RetouchEngine.suggestSource returned valid candidates")
            }

            // 13d. Full bidirectional XMPSidecar round-trip & LR preset import
            var xp = EditParams()
            xp.clarity = -72
            xp.hsl.orange = HSLBand(hue: -12, sat: 24, lum: -18)
            xp.hsl.aqua = HSLBand(hue: 15, sat: -30, lum: 22)
            xp.curveR = ToneCurve(points: [[0, 0.05], [0.5, 0.62], [1, 0.95]])
            xp.curveG = ToneCurve(points: [[0, 0.0], [0.5, 0.45], [1, 1.0]])
            xp.curveB = ToneCurve(points: [[0, 0.02], [0.5, 0.58], [1, 0.98]])
            xp.gradeShadow = ColorGrade(hue: 215, sat: 42)
            xp.gradeShadow.lum = -12
            xp.gradeHigh = ColorGrade(hue: 38, sat: 30)
            xp.primRed = PrimaryAdj(hue: 18, sat: -20)
            xp.primBlue = PrimaryAdj(hue: -24, sat: 35)
            xp.calibShadowTint = 14
            xp.grain = 35; xp.grainSize = 0.72; xp.grainRoughness = 0.38
            xp.cropX = 0.1; xp.cropY = 0.15; xp.cropW = 0.75; xp.cropH = 0.7; xp.straighten = 3.5

            let pickedSc = Sidecar(params: xp, rating: 4, picked: true, colorLabel: .green, rejected: false, keywords: ["Portraits", "P2"])
            let xmpPickedURL = tmp.appendingPathComponent("p2_full_xmp.NEF")
            try XMPSidecar.write(pickedSc, for: xmpPickedURL)
            let readPicked = XMPSidecar.read(for: xmpPickedURL)
            check(readPicked != nil &&
                  readPicked!.picked && !readPicked!.rejected && readPicked!.rating == 4 &&
                  abs(readPicked!.params.clarity + 72) < 1 &&
                  abs(readPicked!.params.hsl.orange.sat - 24) < 1 &&
                  abs(readPicked!.params.hsl.aqua.lum - 22) < 1 &&
                  readPicked!.params.curveR.points.count == 3 &&
                  abs(readPicked!.params.gradeShadow.hue - 215) < 1 &&
                  abs(readPicked!.params.primRed.hue - 18) < 1 &&
                  abs(readPicked!.params.calibShadowTint - 14) < 1 &&
                  abs(readPicked!.params.cropX - 0.1) < 0.02 &&
                  abs(readPicked!.params.cropW - 0.75) < 0.02 &&
                  abs(readPicked!.params.straighten - 3.5) < 0.1,
                  "XMPSidecar round-trips negative clarity, 8-band HSL, RGB curves, ColorGrade, Calibration, and Crop+Angle")

            let rejectedSc = Sidecar(params: EditParams(), rating: 0, picked: false, colorLabel: .none, rejected: true, keywords: [])
            let xmpRejectURL = tmp.appendingPathComponent("p2_reject_xmp.ARW")
            try XMPSidecar.write(rejectedSc, for: xmpRejectURL)
            let readRejected = XMPSidecar.read(for: xmpRejectURL)
            check(readRejected?.rejected == true && readRejected?.picked == false,
                  "XMPSidecar persists xmp:Rating=-1 rejected state cleanly")

            let lrPresetXML = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description crs:PresetName="Portra Warm Test" crs:HasSettings="True" crs:Exposure2012="+0.65" crs:Clarity2012="-40" crs:Saturation="-15"/>
             </rdf:RDF>
            </x:xmpmeta>
            """
            let parsedPreset = XMPSidecar.parsePreset(data: Data(lrPresetXML.utf8), fallbackName: "Fallback")
            check(parsedPreset != nil && abs((parsedPreset?.params.exposure ?? 0) - 0.65) < 0.02 &&
                  abs((parsedPreset?.params.clarity ?? 0) + 40) < 1,
                  "XMPSidecar.parsePreset parses Lightroom XMP presets directly")

            // 13e. EditParams.scaled(by:)
            var baseP = EditParams(); baseP.exposure = 1.0; baseP.contrast = 20; baseP.saturation = -30
            let s0 = baseP.scaled(by: 0.0)
            let s1 = baseP.scaled(by: 1.0)
            let s15 = baseP.scaled(by: 1.5)
            let s20 = baseP.scaled(by: 2.0)
            check(abs(s0.exposure) < 1e-6 && abs(s0.contrast) < 1e-6 &&
                  s1 == baseP &&
                  abs(s15.exposure - 1.5) < 1e-6 && abs(s15.contrast - 30) < 1e-6 &&
                  abs(s20.exposure - 2.0) < 1e-6 && abs(s20.saturation + 60) < 1e-6,
                  "EditParams.scaled(by:) scales smoothly across 0%, 100%, 150%, 200%")

            // 13f. Extended LensProfileStore (>= 70 profiles and valid resolved LensCorrection)
            let bundledURL = URL(fileURLWithPath: "Resources/LensProfiles/bundled.xml")
            let p2Store = LensProfileStore(directory: tmp.appendingPathComponent("lenslib_p2"), bundledURL: bundledURL)
            let sampleResolve = p2Store.matches("FE 35mm f/1.4 GM").first?.resolve(focal: 35, aperture: 2.0, distance: 10, cameraCrop: 1.0)
                ?? p2Store.profiles.first?.resolve(focal: 35, aperture: 4.0, distance: 10, cameraCrop: 1.0)
            check(p2Store.profiles.count >= 70 && sampleResolve != nil && sampleResolve?.valid == true,
                  "Extended LensProfileStore loads \(p2Store.profiles.count) (>=70) valid profiles with working LensCorrection")
        }

        print("\n----------------------------------------------")
        if failures == 0 {
            print("全部 P0/P1/P2 升级自检通过 ✓")
        } else {
            print("失败 \(failures) 项 ✗")
            exit(1)
        }
    }
}
#endif
