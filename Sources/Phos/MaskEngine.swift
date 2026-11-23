import Foundation
import CoreImage
import CoreGraphics
import Vision
import CoreML

/// 线程安全的 Core ML 天空分割可选模型管理器（`~/Library/Application Support/Phos/Models/SkySegmentation.mlmodelc`）。
final class CoreMLSkyEngine: @unchecked Sendable {
    static let shared = CoreMLSkyEngine()
    private let lock = NSLock()
    private var cachedModel: MLModel?
    private var loadAttempted = false

    var modelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos/Models/SkySegmentation.mlmodelc")
    }

    var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    func installModel(from sourceURL: URL) throws {
        let dir = modelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.lowercased()
        let staging = dir.appendingPathComponent(".sky-install-" + UUID().uuidString + ".mlmodelc")
        if FileManager.default.fileExists(atPath: staging.path) {
            try? FileManager.default.removeItem(at: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        if ext == "mlmodelc" {
            try FileManager.default.copyItem(at: sourceURL, to: staging)
        } else {
            let compiled = try MLModel.compileModel(at: sourceURL)
            try FileManager.default.moveItem(at: compiled, to: staging)
        }
        if FileManager.default.fileExists(atPath: modelURL.path) {
            _ = try FileManager.default.replaceItemAt(modelURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: modelURL)
        }
        resetCache()
    }

    func removeModel() throws {
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }
        resetCache()
    }

    func resetCache() {
        lock.lock()
        cachedModel = nil
        loadAttempted = false
        lock.unlock()
        MaskEngine.invalidateAllSkyCache()
    }

    func predict(cg: CGImage, targetExtent: CGRect) -> CIImage? {
        guard let model = loadModel() else { return nil }
        guard let vnModel = try? VNCoreMLModel(for: model) else { return nil }
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])

        if let obs = req.results?.first as? VNPixelBufferObservation {
            let mask = CIImage(cvPixelBuffer: obs.pixelBuffer)
            let sx = targetExtent.width / max(mask.extent.width, 1)
            let sy = targetExtent.height / max(mask.extent.height, 1)
            return mask.transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY)
                .scaledBy(x: sx, y: sy)).cropped(to: targetExtent)
        }

        if let fObs = req.results?.first as? VNCoreMLFeatureValueObservation,
           let arr = fObs.featureValue.multiArrayValue {
            let dims = arr.shape.map(\.intValue)
            let h: Int, w: Int, channels: Int
            let strides = arr.strides.map(\.intValue)
            var yStride = 1, xStride = 1, cStride = 1
            if dims.count == 4 {
                if dims[1] <= 4 {
                    channels = dims[1]; h = dims[2]; w = dims[3]
                    cStride = strides[1]; yStride = strides[2]; xStride = strides[3]
                } else {
                    h = dims[1]; w = dims[2]; channels = dims[3]
                    yStride = strides[1]; xStride = strides[2]; cStride = strides[3]
                }
            } else if dims.count == 3 {
                if dims[0] <= 4 {
                    channels = dims[0]; h = dims[1]; w = dims[2]
                    cStride = strides[0]; yStride = strides[1]; xStride = strides[2]
                } else {
                    h = dims[0]; w = dims[1]; channels = dims[2]
                    yStride = strides[0]; xStride = strides[1]; cStride = strides[2]
                }
            } else if dims.count == 2 {
                channels = 1; h = dims[0]; w = dims[1]
                yStride = strides[0]; xStride = strides[1]
            } else {
                return nil
            }
            guard w > 8, h > 8 else { return nil }
            let chIdx = channels > 1 ? 1 : 0
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let ptr = arr.dataPointer
            let isF16 = arr.dataType == .float16
            func readAt(_ off: Int) -> Float {
                if isF16 {
                    let bits = ptr.assumingMemoryBound(to: UInt16.self)[off]
                    return Float(Float16(bitPattern: bits))
                }
                return ptr.assumingMemoryBound(to: Float.self)[off]
            }
            for y in 0..<h {
                for x in 0..<w {
                    let off = chIdx * cStride + y * yStride + x * xStride
                    let v = max(0.0, min(1.0, readAt(off)))
                    let byte = UInt8((v * 255.0).rounded())
                    let idx = (y * w + x) * 4
                    rgba[idx] = byte; rgba[idx + 1] = byte; rgba[idx + 2] = byte; rgba[idx + 3] = 255
                }
            }
            let ci = CIImage(bitmapData: Data(rgba), bytesPerRow: w * 4, size: CGSize(width: w, height: h),
                             format: .RGBA8, colorSpace: Engine.srgb)
            let sx = targetExtent.width / CGFloat(w), sy = targetExtent.height / CGFloat(h)
            return ci.transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY)
                .scaledBy(x: sx, y: sy)).cropped(to: targetExtent)
        }
        return nil
    }

    private func loadModel() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedModel { return cachedModel }
        if loadAttempted && !isModelInstalled { return nil }
        loadAttempted = true
        guard isModelInstalled else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU
        guard let m = try? MLModel(contentsOf: modelURL, configuration: cfg) else { return nil }
        cachedModel = m
        return m
    }
}

/// 高级蒙版引擎：布尔组合（加/减/交）、天空与人脸五官语义分割、Guided Filter 全分辨率边缘精修。
enum MaskEngine {
    private static let maskCache = BoundedCache<String, CIImage>(capacity: 24)

    static func invalidateCache(for id: UUID) {
        maskCache.removeAll { $0.contains(id.uuidString) }
    }

    static func invalidateAllSkyCache() {
        maskCache.removeAll { $0.hasPrefix("sky-") }
    }

    static func resolve(_ m: Mask, extent: CGRect, analyzed: CIImage) -> CIImage? {
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        let refScale = max(extent.width, extent.height) / 2200.0
        guard var base = evaluateSingle(kind: m.kind, mask: m, extent: extent, analyzed: analyzed, refScale: refScale) else {
            return nil
        }
        if m.inverted {
            base = base.applyingFilter("CIColorInvert").cropped(to: extent)
        }

        for comp in m.components where comp.enabled {
            let subMask = comp.asMask()
            guard var sub = evaluateSingle(kind: comp.kind, mask: subMask, extent: extent, analyzed: analyzed, refScale: refScale) else {
                continue
            }
            if comp.inverted {
                sub = sub.applyingFilter("CIColorInvert").cropped(to: extent)
            }
            if MetalEngine.shared.isAvailable {
                base = MetalMaskBooleanKernel.combine(base: base, sub: sub, op: comp.op, extent: extent)
            } else {
                base = combineCPUFallback(base: base, sub: sub, op: comp.op, extent: extent)
            }
        }

        if !m.refinements.isEmpty, let paint = Engine.refinementImage(m.refinements, extent: extent, analyzed: analyzed) {
            base = paint.composited(over: base).cropped(to: extent)
        }

        let hasAI = m.kind.usesVision || m.components.contains(where: { $0.enabled && $0.kind.usesVision })
        if m.refineEdges && hasAI && MetalEngine.shared.isAvailable {
            let r = max(3, 7 * refScale)
            base = MetalMaskRefineKernel.refine(mask: base, guide: analyzed, radius: r, eps: 0.0018)
        }
        return base.cropped(to: extent)
    }

    private static func combineCPUFallback(base: CIImage, sub: CIImage, op: MaskBoolOp, extent: CGRect) -> CIImage {
        switch op {
        case .add:
            return base.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sub])
                .applyingFilter("CIColorClamp").cropped(to: extent)
        case .subtract:
            let inv = sub.applyingFilter("CIColorInvert")
            return base.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: inv])
                .applyingFilter("CIColorClamp").cropped(to: extent)
        case .intersect:
            return base.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: sub])
                .applyingFilter("CIColorClamp").cropped(to: extent)
        }
    }

    private static func evaluateSingle(kind: MaskKind, mask m: Mask, extent: CGRect, analyzed: CIImage, refScale: CGFloat) -> CIImage? {
        switch kind {
        case .linear, .radial, .brush, .depth, .colorRange, .luminanceRange, .subject, .person, .foreground:
            return Engine.baseMaskImage(for: m, extent: extent, analyzed: analyzed, refScale: refScale)
        case .background:
            var fgMask = m; fgMask.kind = .foreground
            guard let fg = Engine.aiMask(for: fgMask, extent: extent, analyzed: analyzed) else { return nil }
            return fg.applyingFilter("CIColorInvert").cropped(to: extent)
        case .sky:
            let key = "sky-\(m.id.uuidString)-\(Int(extent.width))x\(Int(extent.height))"
            if let hit = maskCache[key] { return hit }
            guard let out = skyMask(source: analyzed, extent: extent) else { return nil }
            maskCache[key] = out
            return out
        case .faceSkin, .bodySkin, .eyes, .eyebrows, .lips, .teeth, .hair, .clothes:
            let key = "\(kind.rawValue)-\(m.id.uuidString)-\(Int(extent.width))x\(Int(extent.height))"
            if let hit = maskCache[key] { return hit }
            guard let out = portraitPartMask(kind: kind, source: analyzed, extent: extent) else { return nil }
            maskCache[key] = out
            return out
        }
    }

    // MARK: - 天空分割（Core ML 可选加速 + 地平线倾角 + 多原型聚类 + 梯度阻断连通域混合算法）
    private static func skyMask(source: CIImage, extent: CGRect) -> CIImage? {
        let e = source.extent
        guard e.width > 8, e.height > 8 else { return nil }
        let side: CGFloat = 512
        let s = min(1, side / max(e.width, e.height))
        let small = s < 1 ? source.transformed(by: CGAffineTransform(scaleX: s, y: s)) : source
        guard let cg = Engine.ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: Engine.srgb) else { return nil }

        // 0) 如用户安装了 Core ML 天空分割模型则优先使用
        if let mlOut = runCoreMLSkyIfPresent(cg: cg, targetExtent: extent) {
            return mlOut
        }

        let w = cg.width, h = cg.height
        guard w > 4, h > 4 else { return nil }

        // 1) 前景掩膜与地平线倾角联合分析
        var fgBuffer = [UInt8](repeating: 0, count: w * h)
        let fgReq = VNGenerateForegroundInstanceMaskRequest()
        let horizonReq = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([fgReq, horizonReq])
        if let obs = fgReq.results?.first,
           let pb = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
            let fgCI = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(
                scaleX: CGFloat(w) / CGFloat(CVPixelBufferGetWidth(pb)),
                y: CGFloat(h) / CGFloat(CVPixelBufferGetHeight(pb))))
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            Engine.ctx.render(fgCI, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                              format: .RGBA8, colorSpace: Engine.srgb)
            for i in 0..<(w * h) { fgBuffer[i] = rgba[i * 4] }
        }

        // 2) 利用地平线倾角估算每列最大下界（Horizon 倾角倾斜时顺着斜率收紧）
        let horizonSlope = (horizonReq.results?.first).map { tan(Double(-$0.angle)) } ?? 0.0
        let baseMinSkyFromBottom = 0.22

        // 3) 读取小图像素并从顶部多列采样种子色，聚类为最多 3 个天空色原型（支持蓝天+白云渐变）
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = Engine.srgb
        if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        var seeds: [(r: Double, g: Double, b: Double)] = []
        let topRows = max(2, h / 16)
        for y in 0..<topRows {
            for x in stride(from: 0, to: w, by: max(1, w / 28)) {
                let idx = y * w + x
                if fgBuffer[idx] > 100 { continue }
                let o = idx * 4
                let r = Double(px[o]) / 255, g = Double(px[o + 1]) / 255, b = Double(px[o + 2]) / 255
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if luma > 0.12 { seeds.append((r, g, b)) }
            }
        }
        guard !seeds.isEmpty else {
            return CIImage(color: .black).cropped(to: extent)
        }

        var prototypes: [(r: Double, g: Double, b: Double)] = [seeds[0]]
        if let farthest = seeds.max(by: { a, b in
            let da = (a.r - seeds[0].r) * (a.r - seeds[0].r) + (a.g - seeds[0].g) * (a.g - seeds[0].g) + (a.b - seeds[0].b) * (a.b - seeds[0].b)
            let db = (b.r - seeds[0].r) * (b.r - seeds[0].r) + (b.g - seeds[0].g) * (b.g - seeds[0].g) + (b.b - seeds[0].b) * (b.b - seeds[0].b)
            return da < db
        }) {
            let d2 = (farthest.r - seeds[0].r) * (farthest.r - seeds[0].r) + (farthest.g - seeds[0].g) * (farthest.g - seeds[0].g) + (farthest.b - seeds[0].b) * (farthest.b - seeds[0].b)
            if d2 > 0.012 { prototypes.append(farthest) }
        }
        if seeds.count >= 6 {
            let meanSeed = (
                r: seeds.map(\.r).reduce(0, +) / Double(seeds.count),
                g: seeds.map(\.g).reduce(0, +) / Double(seeds.count),
                b: seeds.map(\.b).reduce(0, +) / Double(seeds.count)
            )
            prototypes.append(meanSeed)
        }
        for _ in 0..<4 {
            var sums = Array(repeating: (r: 0.0, g: 0.0, b: 0.0, c: 0), count: prototypes.count)
            for s in seeds {
                var bestI = 0, bestD = Double.infinity
                for (pi, p) in prototypes.enumerated() {
                    let d = (s.r - p.r) * (s.r - p.r) + (s.g - p.g) * (s.g - p.g) + (s.b - p.b) * (s.b - p.b)
                    if d < bestD { bestD = d; bestI = pi }
                }
                sums[bestI].r += s.r; sums[bestI].g += s.g; sums[bestI].b += s.b; sums[bestI].c += 1
            }
            for pi in prototypes.indices where sums[pi].c > 0 {
                let cnt = Double(sums[pi].c)
                prototypes[pi] = (sums[pi].r / cnt, sums[pi].g / cnt, sums[pi].b / cnt)
            }
        }

        // 4) 结合垂直渐变、地平线斜率与局部梯度阻断从顶部 BFS 连通域扩张
        var skyScore = [UInt8](repeating: 0, count: w * h)
        var visited = [Bool](repeating: false, count: w * h)
        var queue = [Int]()
        queue.reserveCapacity(w * h / 2)

        func pixelMatches(_ idx: Int, col: Int, row: Int) -> UInt8 {
            if fgBuffer[idx] > 135 { return 0 }
            let o = idx * 4
            let r = Double(px[o]) / 255, g = Double(px[o + 1]) / 255, b = Double(px[o + 2]) / 255
            var minDist = Double.infinity
            for p in prototypes {
                let dr = r - p.r, dg = g - p.g, db = b - p.b
                let dist = (dr * dr + dg * dg + db * db).squareRoot()
                if dist < minDist { minDist = dist }
            }
            let nx = Double(col) / Double(max(1, w)) - 0.5
            let rowFromTop = Double(row) / Double(h)
            let localHorizonClear = min(max(baseMinSkyFromBottom - horizonSlope * nx * 0.25, 0.12), 0.38)
            let tol = 0.34 + 0.12 * (1.0 - rowFromTop)
            let blueBoost = (b >= r * 0.92 && b >= g * 0.85) ? 0.08 : 0.0
            let soft = min(max(1.0 - (minDist - (tol * 0.45 + blueBoost)) / max(tol * 0.65, 0.05), 0.0), 1.0)
            let verticalFade = rowFromTop > (1.0 - localHorizonClear) ? max(0.0, (1.0 - rowFromTop) / localHorizonClear) : 1.0
            return UInt8(min(max(soft * verticalFade * 255.0, 0), 255))
        }

        for x in 0..<w {
            let idx = x
            let sc = pixelMatches(idx, col: x, row: 0)
            if sc > 45 {
                skyScore[idx] = sc
                visited[idx] = true
                queue.append(idx)
            }
        }
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            let cx = cur % w, cy = cur / w
            let co = cur * 4
            let cr = Double(px[co]) / 255, cgC = Double(px[co + 1]) / 255, cb = Double(px[co + 2]) / 255
            let neighbors = [
                cx > 0 ? cur - 1 : -1,
                cx + 1 < w ? cur + 1 : -1,
                cy > 0 ? cur - w : -1,
                cy + 1 < h ? cur + w : -1
            ]
            for nb in neighbors where nb >= 0 && !visited[nb] {
                visited[nb] = true
                let no = nb * 4
                let nr = Double(px[no]) / 255, ng = Double(px[no + 1]) / 255, nbb = Double(px[no + 2]) / 255
                let edgeDiff = abs(nr - cr) + abs(ng - cgC) + abs(nbb - cb)
                let sc = pixelMatches(nb, col: nb % w, row: nb / w)
                // 局部强边界且并非高亮白/蓝天空像素时阻止越过天际线渗漏
                if edgeDiff > 0.36 && sc < 150 { continue }
                if sc > 38 {
                    skyScore[nb] = sc
                    queue.append(nb)
                }
            }
        }

        var rgbaOut = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = skyScore[i]
            rgbaOut[i * 4] = v; rgbaOut[i * 4 + 1] = v; rgbaOut[i * 4 + 2] = v; rgbaOut[i * 4 + 3] = 255
        }
        let ci = CIImage(bitmapData: Data(rgbaOut), bytesPerRow: w * 4, size: CGSize(width: w, height: h),
                         format: .RGBA8, colorSpace: Engine.srgb)
        let sx = extent.width / CGFloat(w), sy = extent.height / CGFloat(h)
        return ci.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY).scaledBy(x: sx, y: sy))
            .cropped(to: extent)
    }

    private static func runCoreMLSkyIfPresent(cg: CGImage, targetExtent: CGRect) -> CIImage? {
        CoreMLSkyEngine.shared.predict(cg: cg, targetExtent: targetExtent)
    }

    // MARK: - 人物细粒度分部位分割 (faceSkin / bodySkin / eyes / eyebrows / lips / teeth / hair / clothes)
    private static func portraitPartMask(kind: MaskKind, source: CIImage, extent: CGRect) -> CIImage? {
        let e = source.extent
        guard e.width > 8, e.height > 8 else { return nil }
        let side: CGFloat = 1024
        let s = min(1, side / max(e.width, e.height))
        let small = s < 1 ? source.transformed(by: CGAffineTransform(scaleX: s, y: s)) : source
        guard let cg = Engine.ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: Engine.srgb) else { return nil }

        let w = cg.width, h = cg.height
        let landmarkReq = VNDetectFaceLandmarksRequest()
        var requests: [VNRequest] = [landmarkReq]
        let personReq = VNGeneratePersonSegmentationRequest()
        personReq.qualityLevel = .accurate
        personReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if kind == .hair || kind == .faceSkin || kind == .bodySkin || kind == .clothes {
            requests.append(personReq)
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform(requests)
        let faces = landmarkReq.results ?? []
        if faces.isEmpty && kind != .bodySkin && kind != .clothes {
            return CIImage(color: .black).cropped(to: extent)
        }
        if (kind == .bodySkin || kind == .clothes), personReq.results?.first?.pixelBuffer == nil {
            return CIImage(color: .black).cropped(to: extent)
        }

        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        func mappedPoints(_ region: VNFaceLandmarkRegion2D?, in box: CGRect) -> [CGPoint] {
            guard let region else { return [] }
            return region.normalizedPoints.map { pt in
                CGPoint(x: (box.minX + pt.x * box.width) * CGFloat(w),
                        y: (box.minY + pt.y * box.height) * CGFloat(h))
            }
        }
        func addPolygon(_ pts: [CGPoint]) {
            guard pts.count >= 3 else { return }
            ctx.move(to: pts[0])
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath()
        }

        if kind == .bodySkin || kind == .clothes {
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // 从身体/衣服候选区先剔除头部及人脸区域
            ctx.setFillColor(gray: 0, alpha: 1)
            for face in faces {
                let box = face.boundingBox
                let headRect = CGRect(
                    x: max(0, (box.minX - box.width * 0.25) * CGFloat(w)),
                    y: max(0, (box.minY - box.height * 0.05) * CGFloat(h)),
                    width: min(CGFloat(w), box.width * 1.50 * CGFloat(w)),
                    height: min(CGFloat(h), box.height * 1.65 * CGFloat(h))
                )
                ctx.fillEllipse(in: headRect)
            }
        } else {
            for face in faces {
                let box = face.boundingBox
                guard let lm = face.landmarks else { continue }
                switch kind {
                case .eyes:
                    ctx.setFillColor(gray: 1, alpha: 1)
                    addPolygon(mappedPoints(lm.leftEye, in: box)); ctx.fillPath()
                    addPolygon(mappedPoints(lm.rightEye, in: box)); ctx.fillPath()
                case .eyebrows:
                    let ptsL = mappedPoints(lm.leftEyebrow, in: box)
                    let ptsR = mappedPoints(lm.rightEyebrow, in: box)
                    let strokeW = max(3.0, box.height * CGFloat(h) * 0.045)
                    ctx.setFillColor(gray: 1, alpha: 1)
                    ctx.setStrokeColor(gray: 1, alpha: 1)
                    ctx.setLineWidth(strokeW)
                    ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    for pts in [ptsL, ptsR] where pts.count >= 2 {
                        addPolygon(pts); ctx.fillPath()
                        ctx.move(to: pts[0])
                        for p in pts.dropFirst() { ctx.addLine(to: p) }
                        ctx.strokePath()
                    }
                case .lips:
                    let outer = mappedPoints(lm.outerLips, in: box)
                    let inner = mappedPoints(lm.innerLips, in: box)
                    if outer.count >= 3 {
                        ctx.beginPath()
                        addPolygon(outer)
                        if inner.count >= 3 { addPolygon(inner) }
                        ctx.setFillColor(gray: 1, alpha: 1)
                        ctx.fillPath(using: .evenOdd)
                    }
                case .teeth:
                    ctx.setFillColor(gray: 1, alpha: 1)
                    addPolygon(mappedPoints(lm.innerLips, in: box)); ctx.fillPath()
                case .faceSkin:
                    var contour = mappedPoints(lm.faceContour, in: box)
                    if contour.count >= 5 {
                        let topL = contour.first!, topR = contour.last!
                        let foreheadY = min(CGFloat(h), box.maxY * CGFloat(h) + box.height * CGFloat(h) * 0.14)
                        contour.append(CGPoint(x: topR.x * 0.75 + topL.x * 0.25, y: foreheadY))
                        contour.append(CGPoint(x: (topL.x + topR.x) * 0.5, y: foreheadY + box.height * CGFloat(h) * 0.04))
                        contour.append(CGPoint(x: topL.x * 0.75 + topR.x * 0.25, y: foreheadY))
                        ctx.setFillColor(gray: 1, alpha: 1)
                        addPolygon(contour); ctx.fillPath()
                    } else {
                        ctx.setFillColor(gray: 1, alpha: 1)
                        ctx.fillEllipse(in: CGRect(x: box.minX * CGFloat(w), y: box.minY * CGFloat(h),
                                                   width: box.width * CGFloat(w), height: box.height * CGFloat(h)))
                    }
                    ctx.setFillColor(gray: 0, alpha: 1)
                    for reg in [lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow, lm.outerLips] {
                        addPolygon(mappedPoints(reg, in: box)); ctx.fillPath()
                    }
                case .hair:
                    let headRect = CGRect(
                        x: max(0, (box.minX - box.width * 0.35) * CGFloat(w)),
                        y: max(0, (box.minY - box.height * 0.20) * CGFloat(h)),
                        width: min(CGFloat(w), box.width * 1.70 * CGFloat(w)),
                        height: min(CGFloat(h), box.height * 1.85 * CGFloat(h))
                    )
                    ctx.setFillColor(gray: 1, alpha: 1)
                    ctx.fillEllipse(in: headRect)
                    ctx.setFillColor(gray: 0, alpha: 1)
                    var contour = mappedPoints(lm.faceContour, in: box)
                    if contour.count >= 5 {
                        let topL = contour.first!, topR = contour.last!
                        let fhY = min(CGFloat(h), (box.minY + box.height * 0.88) * CGFloat(h))
                        contour.append(CGPoint(x: (topL.x + topR.x) * 0.5, y: fhY))
                        addPolygon(contour); ctx.fillPath()
                    }
                default:
                    break
                }
            }
        }

        guard let maskCG = ctx.makeImage() else { return nil }
        var mask = CIImage(cgImage: maskCG)
        let blurRadius: Double = (kind == .eyes || kind == .eyebrows || kind == .lips || kind == .teeth) ? 1.8 : 4.2
        mask = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: NSNumber(value: blurRadius)])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))

        // 牙齿在口腔内筛选低饱和高亮区域
        if kind == .teeth {
            let smallOrig = CIImage(cgImage: cg)
            let toothSpec = smallOrig.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: NSNumber(value: 0.0),
                kCIInputContrastKey: NSNumber(value: 2.2),
                kCIInputBrightnessKey: NSNumber(value: -0.18)
            ]).applyingFilter("CIColorClamp")
            mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: toothSpec])
        }

        // 身体皮肤与衣服：利用 YCbCr 皮肤色度区间将人物轮廓划分为“裸露身体皮肤”和“衣物”
        if kind == .bodySkin || kind == .clothes {
            var px = [UInt8](repeating: 0, count: w * h * 4)
            if let rgbCtx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: Engine.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                rgbCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            var skinBytes = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                let o = i * 4
                let r = Double(px[o]), g = Double(px[o + 1]), b = Double(px[o + 2])
                let yv = 0.299 * r + 0.587 * g + 0.114 * b
                let cb = 128.0 - 0.168736 * r - 0.331264 * g + 0.5 * b
                let cr = 128.0 + 0.5 * r - 0.418688 * g - 0.081312 * b
                let inSkin = cb >= 75 && cb <= 130 && cr >= 131 && cr <= 176 && yv > 35 && r > g * 0.96 && r > b
                let score: Double
                if inSkin {
                    let dc = hypot((cb - 102) / 26, (cr - 152) / 22)
                    score = max(0, min(1, 1.15 - dc * 0.7))
                } else {
                    score = 0
                }
                let finalV = kind == .bodySkin ? score : (1.0 - score)
                let byte = UInt8((finalV * 255).rounded())
                skinBytes[o] = byte; skinBytes[o + 1] = byte; skinBytes[o + 2] = byte; skinBytes[o + 3] = 255
            }
            let skinCI = CIImage(bitmapData: Data(skinBytes), bytesPerRow: w * 4, size: CGSize(width: w, height: h),
                                 format: .RGBA8, colorSpace: Engine.srgb)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: NSNumber(value: 2.2)])
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skinCI])
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // 头发/身体皮肤/衣服与人物整体分割求交，确保边缘准确跟人物轮廓走
        if (kind == .hair || kind == .bodySkin || kind == .clothes), let pb = personReq.results?.first?.pixelBuffer {
            var pImg = CIImage(cvPixelBuffer: pb)
            let psx = CGFloat(w) / max(pImg.extent.width, 1), psy = CGFloat(h) / max(pImg.extent.height, 1)
            pImg = pImg.transformed(by: CGAffineTransform(scaleX: psx, y: psy))
            mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: pImg])
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }

        let sx = extent.width / CGFloat(w), sy = extent.height / CGFloat(h)
        return mask.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
            .scaledBy(x: sx, y: sy)).cropped(to: extent)
    }
}
