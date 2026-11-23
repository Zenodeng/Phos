import Foundation
import CoreImage
import CoreGraphics
import Vision
import CoreML

/// 通用线程安全 Core ML 图像到图像分块引擎（支持 512×512 重叠 Hann 窗无缝推理）。
final class CoreMLImageModelManager: @unchecked Sendable {
    let modelFileName: String
    private let lock = NSLock()
    private var cachedModel: MLModel?
    private var loadAttempted = false

    init(modelFileName: String) {
        self.modelFileName = modelFileName
    }

    var modelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos/Models")
            .appendingPathComponent(modelFileName)
    }

    var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
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
        let staging = dir.appendingPathComponent(".\(UUID().uuidString).mlmodelc")
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
    }

    func loadModel() -> MLModel? {
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

    /// 在图块上运行 Core ML 图像模型，大图使用 512×512 重叠 Hann 窗融合消除拼缝。
    func inferTiled(_ source: CIImage, scaleFactor: CGFloat = 1.0) -> CIImage? {
        guard let model = loadModel(),
              let vnModel = try? VNCoreMLModel(for: model) else { return nil }
        let ext = source.extent
        let w = Int(ext.width.rounded())
        let h = Int(ext.height.rounded())
        guard w >= 8, h >= 8 else { return nil }

        let tileSide = 512
        let overlap = 64
        if w <= tileSide && h <= tileSide {
            guard let outTile = runSingleTile(source, extent: ext, vnModel: vnModel) else { return nil }
            let targetRect = CGRect(x: ext.minX * scaleFactor, y: ext.minY * scaleFactor,
                                    width: ext.width * scaleFactor, height: ext.height * scaleFactor)
            let sx = targetRect.width / max(1, outTile.extent.width)
            let sy = targetRect.height / max(1, outTile.extent.height)
            return outTile.transformed(by: CGAffineTransform(translationX: targetRect.minX - outTile.extent.minX * sx,
                                                             y: targetRect.minY - outTile.extent.minY * sy)
                .scaledBy(x: sx, y: sy)).cropped(to: targetRect)
        }

        let step = tileSide - overlap
        let outW = Int((Double(w) * Double(scaleFactor)).rounded())
        let outH = Int((Double(h) * Double(scaleFactor)).rounded())
        var accum = [Float](repeating: 0, count: outW * outH * 4)
        var weights = [Float](repeating: 0, count: outW * outH)

        var ys = [0]
        while ys.last! + tileSide < h { ys.append(min(h - tileSide, ys.last! + step)) }
        var xs = [0]
        while xs.last! + tileSide < w { xs.append(min(w - tileSide, xs.last! + step)) }

        for ty in ys {
            for tx in xs {
                let tw = min(tileSide, w - tx)
                let th = min(tileSide, h - ty)
                let tileRect = CGRect(x: ext.minX + CGFloat(tx), y: ext.minY + CGFloat(ty),
                                      width: CGFloat(tw), height: CGFloat(th))
                guard let tileOut = runSingleTile(source.cropped(to: tileRect), extent: tileRect, vnModel: vnModel) else {
                    return nil
                }
                let ow = max(1, Int((CGFloat(tw) * scaleFactor).rounded()))
                let oh = max(1, Int((CGFloat(th) * scaleFactor).rounded()))
                let resized = tileOut.transformed(by: CGAffineTransform(
                    translationX: -tileOut.extent.minX,
                    y: -tileOut.extent.minY
                )).transformed(by: CGAffineTransform(
                    scaleX: CGFloat(ow) / max(1, tileOut.extent.width),
                    y: CGFloat(oh) / max(1, tileOut.extent.height)
                ))
                var tileBuf = [Float](repeating: 0, count: ow * oh * 4)
                Engine.ctx.render(resized, toBitmap: &tileBuf, rowBytes: ow * 16,
                                  bounds: CGRect(x: 0, y: 0, width: ow, height: oh),
                                  format: .RGBAf, colorSpace: Engine.workingColorSpace)
                let dstX0 = Int((CGFloat(tx) * scaleFactor).rounded())
                let dstY0 = Int((CGFloat(ty) * scaleFactor).rounded())
                for py in 0..<oh {
                    let wy = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(py + 1) / Double(oh + 1))
                    let outRow = min(outH - 1, max(0, outH - 1 - (dstY0 + (oh - 1 - py))))
                    for px in 0..<ow {
                        let wx = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(px + 1) / Double(ow + 1))
                        let win = Float(max(0.05, wx * wy))
                        let ox = min(outW - 1, dstX0 + px)
                        let sIdx = (py * ow + px) * 4
                        let dIdx = (outRow * outW + ox)
                        accum[dIdx * 4] += tileBuf[sIdx] * win
                        accum[dIdx * 4 + 1] += tileBuf[sIdx + 1] * win
                        accum[dIdx * 4 + 2] += tileBuf[sIdx + 2] * win
                        accum[dIdx * 4 + 3] += win
                        weights[dIdx] += win
                    }
                }
            }
        }
        for i in 0..<(outW * outH) {
            let wSum = max(weights[i], 1e-5)
            accum[i * 4] /= wSum
            accum[i * 4 + 1] /= wSum
            accum[i * 4 + 2] /= wSum
            accum[i * 4 + 3] = 1.0
        }
        let data = accum.withUnsafeBytes { Data($0) }
        let merged = CIImage(bitmapData: data, bytesPerRow: outW * 16,
                             size: CGSize(width: outW, height: outH),
                             format: .RGBAf, colorSpace: Engine.workingColorSpace)
        return merged.transformed(by: CGAffineTransform(translationX: ext.minX * scaleFactor,
                                                        y: ext.minY * scaleFactor))
    }

    private func runSingleTile(_ tile: CIImage, extent: CGRect, vnModel: VNCoreMLModel) -> CIImage? {
        guard let cg = Engine.ctx.createCGImage(tile, from: extent, format: .RGBA8, colorSpace: Engine.srgb) else {
            return nil
        }
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        if let obs = req.results?.first as? VNPixelBufferObservation {
            return CIImage(cvPixelBuffer: obs.pixelBuffer)
        }
        return nil
    }
}

enum CoreMLDenoiseEngine {
    static let shared = CoreMLImageModelManager(modelFileName: "Denoise.mlmodelc")
}

enum CoreMLSuperResEngine {
    static let shared = CoreMLImageModelManager(modelFileName: "SuperRes.mlmodelc")
}

/// P3 非破坏性 RAW 域降噪与 2x 超分引擎（支持 Core ML 模型，未安装时自动走 Metal 线性 RAW 算子）。
enum NeuralDenoiseEngine {
    static func applyDenoise(_ image: CIImage, amount: Double, detail: Double, refScale: CGFloat) -> CIImage {
        let e = image.extent
        guard !e.isEmpty, !e.isInfinite, amount > 0 else { return image }
        let strength = min(max(amount / 100.0, 0), 1)
        let det = min(max(detail / 100.0, 0), 1)

        if CoreMLDenoiseEngine.shared.isModelInstalled,
           let neural = CoreMLDenoiseEngine.shared.inferTiled(image, scaleFactor: 1.0) {
            let blendAmt = strength * (1.0 - det * 0.25)
            let maskColor = CIImage(color: CIColor(red: blendAmt, green: blendAmt, blue: blendAmt, alpha: 1))
                .cropped(to: e)
            return neural.cropped(to: e).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: maskColor
            ]).cropped(to: e)
        }

        if MetalEngine.shared.isAvailable {
            return MetalRawDenoiseKernel.apply(image, amount: amount, detail: detail, chromaOnly: false, refScale: refScale)
        }

        return image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": NSNumber(value: strength * 0.08),
            "inputSharpness": NSNumber(value: 0.35 + det * 0.45)
        ]).cropped(to: e)
    }

    static func applySuperResolution(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard !e.isEmpty, !e.isInfinite, e.width >= 2, e.height >= 2 else { return image }

        if CoreMLSuperResEngine.shared.isModelInstalled,
           let neural2x = CoreMLSuperResEngine.shared.inferTiled(image, scaleFactor: 2.0) {
            return neural2x
        }

        let zeroed = e.minX != 0 || e.minY != 0
            ? image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            : image
        var up = zeroed.applyingFilter("CILanczosScaleTransform", parameters: [
            "inputScale": NSNumber(value: 2.0),
            "inputAspectRatio": NSNumber(value: 1.0)
        ])
        let targetRect = CGRect(x: 0, y: 0,
                                width: (e.width * 2.0).rounded(),
                                height: (e.height * 2.0).rounded())
        up = up.cropped(to: targetRect)
        if MetalEngine.shared.isAvailable {
            up = MetalSuperResKernel.apply(up, sharpen: 0.58, edgePreserve: 0.85)
        } else {
            up = up.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: NSNumber(value: 1.0),
                kCIInputIntensityKey: NSNumber(value: 0.45)
            ]).cropped(to: targetRect)
        }
        return e.minX != 0 || e.minY != 0
            ? up.transformed(by: CGAffineTransform(translationX: e.minX * 2.0, y: e.minY * 2.0))
            : up
    }
}
