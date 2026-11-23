import Foundation
import CoreImage
import CoreGraphics
import Vision
import CoreML

/// 线程安全的 Core ML 单目深度估计模型管理器（`~/Library/Application Support/Phos/Models/DepthAnythingV2.mlmodelc`）。
final class CoreMLDepthEngine: @unchecked Sendable {
    static let shared = CoreMLDepthEngine()
    private let lock = NSLock()
    private var cachedModel: MLModel?
    private var loadAttempted = false
    private var tokenCounter: UInt64 = 1

    var modelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos/Models/DepthAnythingV2.mlmodelc")
    }

    var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    var cacheToken: String {
        lock.lock()
        defer { lock.unlock() }
        return "\(isModelInstalled ? 1 : 0)-\(tokenCounter)"
    }

    var modelSizeDescription: String? {
        guard isModelInstalled,
              let en = FileManager.default.enumerator(at: modelURL, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in en {
            if let sz = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        let mb = Double(total) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", max(0.1, mb))
    }

    func installModel(from sourceURL: URL) throws {
        let dir = modelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.lowercased()
        let staging = dir.appendingPathComponent(".depth-install-" + UUID().uuidString + ".mlmodelc")
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
        tokenCounter &+= 1
        lock.unlock()
        DepthEngine.invalidateCache()
    }

    func predict(cg: CGImage, targetExtent: CGRect) -> CIImage? {
        guard let model = loadModel(),
              let vnModel = try? VNCoreMLModel(for: model) else { return nil }
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])

        if let obs = req.results?.first as? VNPixelBufferObservation {
            let raw = CIImage(cvPixelBuffer: obs.pixelBuffer)
            return normalizeCoreMLDepthImage(raw, targetExtent: targetExtent)
        }

        if let fObs = req.results?.first as? VNCoreMLFeatureValueObservation,
           let arr = fObs.featureValue.multiArrayValue {
            let dims = arr.shape.map(\.intValue)
            let strides = arr.strides.map(\.intValue)
            let h: Int, w: Int
            var yStride = 1, xStride = 1
            if dims.count == 4 {
                if dims[1] <= 4 {
                    h = dims[2]; w = dims[3]; yStride = strides[2]; xStride = strides[3]
                } else {
                    h = dims[1]; w = dims[2]; yStride = strides[1]; xStride = strides[2]
                }
            } else if dims.count == 3 {
                if dims[0] <= 4 {
                    h = dims[1]; w = dims[2]; yStride = strides[1]; xStride = strides[2]
                } else {
                    h = dims[0]; w = dims[1]; yStride = strides[0]; xStride = strides[1]
                }
            } else if dims.count == 2 {
                h = dims[0]; w = dims[1]; yStride = strides[0]; xStride = strides[1]
            } else {
                return nil
            }
            guard w > 8, h > 8 else { return nil }
            let ptr = arr.dataPointer
            let isF16 = arr.dataType == .float16
            func readAt(_ off: Int) -> Float {
                if isF16 {
                    let bits = ptr.assumingMemoryBound(to: UInt16.self)[off]
                    return Float(Float16(bitPattern: bits))
                }
                return ptr.assumingMemoryBound(to: Float.self)[off]
            }

            var vals = [Float](repeating: 0, count: w * h)
            var minV: Float = .greatestFiniteMagnitude
            var maxV: Float = -.greatestFiniteMagnitude
            for y in 0..<h {
                for x in 0..<w {
                    let v = readAt(y * yStride + x * xStride)
                    let fv = v.isFinite ? v : 0
                    vals[y * w + x] = fv
                    if fv < minV { minV = fv }
                    if fv > maxV { maxV = fv }
                }
            }
            let span = max(maxV - minV, 1e-5)
            // Depth Anything 模型输出逆深度（值越大越近），翻转为 0=近、1=远
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                let norm = max(0.0, min(1.0, 1.0 - (vals[i] - minV) / span))
                let byte = UInt8((norm * 255.0).rounded())
                let o = i * 4
                rgba[o] = byte; rgba[o + 1] = byte; rgba[o + 2] = byte; rgba[o + 3] = 255
            }
            let ci = CIImage(bitmapData: Data(rgba), bytesPerRow: w * 4, size: CGSize(width: w, height: h),
                             format: .RGBA8, colorSpace: Engine.srgb)
            let sx = targetExtent.width / CGFloat(w), sy = targetExtent.height / CGFloat(h)
            return ci.transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY)
                .scaledBy(x: sx, y: sy)).cropped(to: targetExtent)
        }
        return nil
    }

    private func normalizeCoreMLDepthImage(_ raw: CIImage, targetExtent: CGRect) -> CIImage? {
        let rw = Int(raw.extent.width.rounded())
        let rh = Int(raw.extent.height.rounded())
        guard rw > 8, rh > 8 else { return nil }
        var buf = [Float](repeating: 0, count: rw * rh * 4)
        Engine.ctx.render(raw, toBitmap: &buf, rowBytes: rw * 16, bounds: raw.extent,
                          format: .RGBAf, colorSpace: Engine.srgb)
        var minV: Float = .greatestFiniteMagnitude
        var maxV: Float = -.greatestFiniteMagnitude
        for i in 0..<(rw * rh) {
            let v = buf[i * 4]
            if v.isFinite {
                if v < minV { minV = v }
                if v > maxV { maxV = v }
            }
        }
        let span = max(maxV - minV, 1e-5)
        var rgba = [UInt8](repeating: 0, count: rw * rh * 4)
        for i in 0..<(rw * rh) {
            let v = buf[i * 4].isFinite ? buf[i * 4] : minV
            let norm = max(0.0, min(1.0, 1.0 - (v - minV) / span))
            let b = UInt8((norm * 255.0).rounded())
            let o = i * 4
            rgba[o] = b; rgba[o + 1] = b; rgba[o + 2] = b; rgba[o + 3] = 255
        }
        let ci = CIImage(bitmapData: Data(rgba), bytesPerRow: rw * 4, size: CGSize(width: rw, height: rh),
                         format: .RGBA8, colorSpace: Engine.srgb)
        let sx = targetExtent.width / CGFloat(rw), sy = targetExtent.height / CGFloat(rh)
        return ci.transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY)
            .scaledBy(x: sx, y: sy)).cropped(to: targetExtent)
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

/// P3 单目深度估计引擎：支持 Core ML DepthAnythingV2 推理，无模型时自动退回 Vision 显著性+人物+透视梯度混合深度 + Guided Filter 精修。
enum DepthEngine {
    private static let cache = BoundedCache<String, CIImage>(capacity: 8)

    static func invalidateCache() {
        cache.removeAll()
    }

    static func estimateDepth(for source: CIImage, extent: CGRect) -> CIImage? {
        guard !extent.isEmpty, !extent.isInfinite, extent.width > 4, extent.height > 4 else { return nil }
        let sig = imageSignature(source, extent: extent)
        let key = "\(Int(extent.width))x\(Int(extent.height))-\(sig)-\(CoreMLDepthEngine.shared.cacheToken)"
        if let hit = cache[key] { return hit }

        let maxDim: CGFloat = CoreMLDepthEngine.shared.isModelInstalled ? 518 : 224
        let scale = min(1.0, maxDim / max(extent.width, extent.height))
        let sw = max(16, Int((extent.width * scale).rounded()))
        let sh = max(16, Int((extent.height * scale).rounded()))
        let smallRect = CGRect(x: 0, y: 0, width: sw, height: sh)
        let small = source.cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(sw) / extent.width,
                                               y: CGFloat(sh) / extent.height))
        guard let cg = Engine.ctx.createCGImage(small, from: smallRect, format: .RGBA8, colorSpace: Engine.srgb) else {
            return nil
        }

        var depth: CIImage?
        if CoreMLDepthEngine.shared.isModelInstalled {
            depth = CoreMLDepthEngine.shared.predict(cg: cg, targetExtent: extent)
        }
        if depth == nil {
            depth = heuristicDepth(cg: cg, width: sw, height: sh, targetExtent: extent)
        }
        if var d = depth {
            if MetalEngine.shared.isAvailable {
                let refScale = max(extent.width, extent.height) / 2200.0
                let r = max(4.0, 9.0 * refScale)
                d = MetalMaskRefineKernel.refine(mask: d, guide: source.cropped(to: extent), radius: r, eps: 0.0022)
            }
            let cropped = d.cropped(to: extent)
            cache[key] = cropped
            return cropped
        }
        return nil
    }

    /// 画布「点击对焦」：采样归一化点位 (0...1, y 向上) 处的深度 [0, 1]。
    static func sampleDepth(at normPoint: CGPoint, in source: CIImage,
                            disparityMask: CIImage?, paintedDepth: CIImage?) -> Double? {
        let e = source.extent
        guard !e.isEmpty, !e.isInfinite else { return nil }
        let mask = paintedDepth ?? disparityMask ?? estimateDepth(for: source, extent: e)
        guard let depthImg = mask?.cropped(to: e) else { return nil }
        let nx = min(max(normPoint.x, 0), 0.9999)
        let ny = min(max(normPoint.y, 0), 0.9999)
        let px = (e.minX + nx * e.width).rounded(.down)
        let py = (e.minY + ny * e.height).rounded(.down)
        var buf = [Float](repeating: 0, count: 4)
        Engine.ctx.render(depthImg, toBitmap: &buf, rowBytes: 16,
                          bounds: CGRect(x: px, y: py, width: 1, height: 1),
                          format: .RGBAf, colorSpace: Engine.srgb)
        guard buf[0].isFinite else { return nil }
        return Double(min(max(buf[0], 0), 1))
    }

    private static func imageSignature(_ src: CIImage, extent: CGRect) -> UInt64 {
        let grid = 8
        let sRect = CGRect(x: 0, y: 0, width: grid, height: grid)
        let thumb = src.cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(grid) / extent.width,
                                               y: CGFloat(grid) / extent.height))
        var buf = [UInt8](repeating: 0, count: grid * grid * 4)
        Engine.ctx.render(thumb, toBitmap: &buf, rowBytes: grid * 4, bounds: sRect,
                          format: .RGBA8, colorSpace: Engine.srgb)
        var h: UInt64 = 1469598103934665603
        for b in buf {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return h
    }

    private static func heuristicDepth(cg: CGImage, width w: Int, height h: Int, targetExtent: CGRect) -> CIImage? {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = Engine.srgb
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4]) / 255.0
            let g = Float(rgba[i * 4 + 1]) / 255.0
            let b = Float(rgba[i * 4 + 2]) / 255.0
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        var fgWeights = [Float](repeating: 0, count: w * h)
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let salReq = VNGenerateAttentionBasedSaliencyImageRequest()
        let personReq = VNGeneratePersonSegmentationRequest()
        personReq.qualityLevel = .balanced
        personReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? handler.perform([salReq, personReq])

        if let salObs = salReq.results?.first as? VNSaliencyImageObservation {
            let mapCI = CIImage(cvPixelBuffer: salObs.pixelBuffer)
                .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / max(1, CGFloat(CVPixelBufferGetWidth(salObs.pixelBuffer))),
                                                   y: CGFloat(h) / max(1, CGFloat(CVPixelBufferGetHeight(salObs.pixelBuffer)))))
            var salBuf = [Float](repeating: 0, count: w * h * 4)
            Engine.ctx.render(mapCI, toBitmap: &salBuf, rowBytes: w * 16,
                              bounds: CGRect(x: 0, y: 0, width: w, height: h),
                              format: .RGBAf, colorSpace: cs)
            for i in 0..<(w * h) {
                fgWeights[i] = max(fgWeights[i], min(max(salBuf[i * 4], 0), 1) * 0.75)
            }
        }
        if let pObs = personReq.results?.first as? VNPixelBufferObservation {
            let mapCI = CIImage(cvPixelBuffer: pObs.pixelBuffer)
                .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / max(1, CGFloat(CVPixelBufferGetWidth(pObs.pixelBuffer))),
                                                   y: CGFloat(h) / max(1, CGFloat(CVPixelBufferGetHeight(pObs.pixelBuffer)))))
            var pBuf = [Float](repeating: 0, count: w * h * 4)
            Engine.ctx.render(mapCI, toBitmap: &pBuf, rowBytes: w * 16,
                              bounds: CGRect(x: 0, y: 0, width: w, height: h),
                              format: .RGBAf, colorSpace: cs)
            for i in 0..<(w * h) {
                fgWeights[i] = max(fgWeights[i], min(max(pBuf[i * 4], 0), 1))
            }
        }

        var outRGBA = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            // top (row 0) 远 ~0.90，bottom (row h-1) 近 ~0.25
            let yFrac = Float(y) / Float(max(1, h - 1))
            let planeDepth = 0.90 - yFrac * 0.65
            for x in 0..<w {
                let idx = y * w + x
                let xL = luma[y * w + max(0, x - 1)]
                let xR = luma[y * w + min(w - 1, x + 1)]
                let yU = luma[max(0, y - 1) * w + x]
                let yD = luma[min(h - 1, y + 1) * w + x]
                let grad = min(1.0, abs(xR - xL) + abs(yD - yU))

                let baseD = planeDepth * (1.0 - grad * 0.22)
                let fg = fgWeights[idx]
                let d = max(0.0, min(1.0, baseD * (1.0 - fg * 0.85) + 0.08 * fg))
                let byte = UInt8((d * 255.0).rounded())
                let o = idx * 4
                outRGBA[o] = byte; outRGBA[o + 1] = byte; outRGBA[o + 2] = byte; outRGBA[o + 3] = 255
            }
        }
        let dCI = CIImage(bitmapData: Data(outRGBA), bytesPerRow: w * 4,
                          size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: cs)
        let sx = targetExtent.width / CGFloat(w), sy = targetExtent.height / CGFloat(h)
        return dCI.transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY)
            .scaledBy(x: sx, y: sy)).cropped(to: targetExtent)
    }
}
