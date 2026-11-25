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

    /// 读取模型声明的输入图块边长（同时兼容 ImageType 与 MLMultiArray 模型，如 SCUNet 512 / RealESRGAN x2 256）。
    private func preferredTileSize(for model: MLModel) -> (w: Int, h: Int) {
        if let imgDesc = model.modelDescription.inputDescriptionsByName.values.first(where: { $0.imageConstraint != nil }),
           let c = imgDesc.imageConstraint, c.pixelsWide >= 64, c.pixelsHigh >= 64 {
            return (min(1024, c.pixelsWide), min(1024, c.pixelsHigh))
        }
        if let arrDesc = model.modelDescription.inputDescriptionsByName.values.first(where: { $0.multiArrayConstraint != nil }),
           let shape = arrDesc.multiArrayConstraint?.shape.map(\.intValue), shape.count == 4 {
            let h = shape[1] == 3 ? shape[2] : shape[1]
            let w = shape[1] == 3 ? shape[3] : shape[2]
            if w >= 64, h >= 64 { return (min(1024, w), min(1024, h)) }
        }
        return (512, 512)
    }

    /// 在图块上运行 Core ML 图像模型，大图使用重叠 Hann 窗融合消除拼缝。
    /// 同时兼容 Image 输入（VNCoreMLRequest）与 MLMultiArray NCHW/NHWC 输入（如 SCUNet / Real-ESRGAN x2plus）。
    func inferTiled(_ source: CIImage, scaleFactor: CGFloat = 1.0) -> CIImage? {
        guard let model = loadModel() else { return nil }
        let vnModel = model.modelDescription.inputDescriptionsByName.values.contains(where: { $0.imageConstraint != nil })
            ? (try? VNCoreMLModel(for: model))
            : nil
        let ext = source.extent
        let w = Int(ext.width.rounded())
        let h = Int(ext.height.rounded())
        guard w >= 8, h >= 8 else { return nil }

        let tileDims = preferredTileSize(for: model)
        let tileW = tileDims.w
        let tileH = tileDims.h
        let overlapX = max(24, tileW / 8)
        let overlapY = max(24, tileH / 8)
        let clampedSource = source.clampedToExtent()

        if w <= tileW && h <= tileH {
            let padRect = CGRect(x: ext.minX, y: ext.minY, width: CGFloat(tileW), height: CGFloat(tileH))
            guard let outTile = runSingleTile(clampedSource.cropped(to: padRect), extent: padRect, model: model, vnModel: vnModel) else {
                return nil
            }
            let cropW = CGFloat(w) * scaleFactor
            let cropH = CGFloat(h) * scaleFactor
            let sx = (CGFloat(tileW) * scaleFactor) / max(1, outTile.extent.width)
            let sy = (CGFloat(tileH) * scaleFactor) / max(1, outTile.extent.height)
            let scaled = outTile.transformed(by: CGAffineTransform(translationX: -outTile.extent.minX, y: -outTile.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            let cropped = scaled.cropped(to: CGRect(x: 0, y: 0, width: cropW, height: cropH))
            return cropped.transformed(by: CGAffineTransform(translationX: ext.minX * scaleFactor,
                                                             y: ext.minY * scaleFactor))
        }

        let stepX = max(32, tileW - overlapX)
        let stepY = max(32, tileH - overlapY)
        let outW = Int((Double(w) * Double(scaleFactor)).rounded())
        let outH = Int((Double(h) * Double(scaleFactor)).rounded())
        var accum = [Float](repeating: 0, count: outW * outH * 4)
        var weights = [Float](repeating: 0, count: outW * outH)

        var ys = [0]
        while ys.last! + tileH < h { ys.append(min(max(0, h - tileH), ys.last! + stepY)) }
        var xs = [0]
        while xs.last! + tileW < w { xs.append(min(max(0, w - tileW), xs.last! + stepX)) }

        for ty in ys {
            for tx in xs {
                let tw = min(tileW, w - tx)
                let th = min(tileH, h - ty)
                let padRect = CGRect(x: ext.minX + CGFloat(tx), y: ext.minY + CGFloat(ty),
                                     width: CGFloat(tileW), height: CGFloat(tileH))
                guard let tileOut = runSingleTile(clampedSource.cropped(to: padRect), extent: padRect, model: model, vnModel: vnModel) else {
                    return nil
                }
                let ow = max(1, Int((CGFloat(tw) * scaleFactor).rounded()))
                let oh = max(1, Int((CGFloat(th) * scaleFactor).rounded()))
                let fullOutW = CGFloat(tileW) * scaleFactor
                let fullOutH = CGFloat(tileH) * scaleFactor
                let resized = tileOut.transformed(by: CGAffineTransform(
                    translationX: -tileOut.extent.minX,
                    y: -tileOut.extent.minY
                )).transformed(by: CGAffineTransform(
                    scaleX: fullOutW / max(1, tileOut.extent.width),
                    y: fullOutH / max(1, tileOut.extent.height)
                )).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(ow), height: CGFloat(oh)))
                var tileBuf = [Float](repeating: 0, count: ow * oh * 4)
                Engine.ctx.render(resized, toBitmap: &tileBuf, rowBytes: ow * 16,
                                  bounds: CGRect(x: 0, y: 0, width: ow, height: oh),
                                  format: .RGBAf, colorSpace: Engine.workingColorSpace)
                let dstX0 = Int((CGFloat(tx) * scaleFactor).rounded())
                let dstY0 = Int((CGFloat(ty) * scaleFactor).rounded())
                for py in 0..<oh {
                    let wy = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(py + 1) / Double(oh + 1))
                    // tileBuf 与 CIImage(bitmapData:) 均为顶行优先（row 0 = 顶边），dstY0 为 CI 坐标（y 向上）。
                    let outRow = min(outH - 1, max(0, outH - dstY0 - oh + py))
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

    private func runSingleTile(_ tile: CIImage, extent: CGRect, model: MLModel, vnModel: VNCoreMLModel?) -> CIImage? {
        guard let cg = Engine.ctx.createCGImage(tile, from: extent, format: .RGBA8, colorSpace: Engine.srgb) else {
            return nil
        }
        if let vnModel {
            let req = VNCoreMLRequest(model: vnModel)
            req.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
            if let obs = req.results?.first as? VNPixelBufferObservation {
                return CIImage(cvPixelBuffer: obs.pixelBuffer)
            }
        }
        guard let inEntry = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.multiArrayConstraint != nil }),
              let constraint = inEntry.value.multiArrayConstraint else { return nil }
        let shape = constraint.shape.map(\.intValue)
        let isNCHW: Bool
        let inH: Int, inW: Int
        if shape.count == 4 && shape[1] == 3 {
            isNCHW = true; inH = shape[2]; inW = shape[3]
        } else if shape.count == 4 && shape[3] == 3 {
            isNCHW = false; inH = shape[1]; inW = shape[2]
        } else {
            return nil
        }
        var px = [UInt8](repeating: 0, count: inW * inH * 4)
        guard let gctx = CGContext(data: &px, width: inW, height: inH, bitsPerComponent: 8,
                                   bytesPerRow: inW * 4, space: Engine.srgb,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        gctx.interpolationQuality = .high
        gctx.draw(cg, in: CGRect(x: 0, y: 0, width: inW, height: inH))

        let dt: MLMultiArrayDataType = constraint.dataType == .float16 ? .float16 : .float32
        guard let inArr = try? MLMultiArray(shape: constraint.shape, dataType: dt) else { return nil }
        let st = inArr.strides.map(\.intValue)
        let inPtr = inArr.dataPointer
        let inF16 = dt == .float16
        for y in 0..<inH {
            for x in 0..<inW {
                let p = (y * inW + x) * 4
                for c in 0..<3 {
                    let v = Float(px[p + c]) / 255.0
                    let off = isNCHW ? (c * st[1] + y * st[2] + x * st[3]) : (y * st[1] + x * st[2] + c * st[3])
                    if inF16 {
                        inPtr.assumingMemoryBound(to: UInt16.self)[off] = Float16(v).bitPattern
                    } else {
                        inPtr.assumingMemoryBound(to: Float.self)[off] = v
                    }
                }
            }
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [inEntry.key: MLFeatureValue(multiArray: inArr)]),
              let pred = try? model.prediction(from: provider),
              let outName = model.modelDescription.outputDescriptionsByName.first(where: { $0.value.multiArrayConstraint != nil })?.key
                ?? model.modelDescription.outputDescriptionsByName.keys.first,
              let outArr = pred.featureValue(for: outName)?.multiArrayValue else { return nil }
        let oDims = outArr.shape.map(\.intValue)
        let oSt = outArr.strides.map(\.intValue)
        let oNCHW: Bool, oh: Int, ow: Int
        if oDims.count == 4 && oDims[1] == 3 {
            oNCHW = true; oh = oDims[2]; ow = oDims[3]
        } else if oDims.count == 4 && oDims[3] == 3 {
            oNCHW = false; oh = oDims[1]; ow = oDims[2]
        } else {
            return nil
        }
        let oPtr = outArr.dataPointer
        let oF16 = outArr.dataType == .float16
        @inline(__always) func readO(_ off: Int) -> Float {
            if oF16 { return Float(Float16(bitPattern: oPtr.assumingMemoryBound(to: UInt16.self)[off])) }
            return oPtr.assumingMemoryBound(to: Float.self)[off]
        }
        var maxSample: Float = 0
        for y in stride(from: 0, to: oh, by: max(1, oh / 16)) {
            for x in stride(from: 0, to: ow, by: max(1, ow / 16)) {
                let off = oNCHW ? (y * oSt[2] + x * oSt[3]) : (y * oSt[1] + x * oSt[2])
                let v = readO(off)
                if v.isFinite && v > maxSample { maxSample = v }
            }
        }
        let scale: Float = maxSample > 2.0 ? (1.0 / 255.0) : 1.0
        var outRGBA = [UInt8](repeating: 255, count: ow * oh * 4)
        for y in 0..<oh {
            for x in 0..<ow {
                let dst = (y * ow + x) * 4
                for c in 0..<3 {
                    let off = oNCHW ? (c * oSt[1] + y * oSt[2] + x * oSt[3]) : (y * oSt[1] + x * oSt[2] + c * oSt[3])
                    let raw = readO(off)
                    let v = raw.isFinite ? max(0.0, min(1.0, raw * scale)) : 0.0
                    outRGBA[dst + c] = UInt8((v * 255.0).rounded())
                }
            }
        }
        return CIImage(bitmapData: Data(outRGBA), bytesPerRow: ow * 4,
                       size: CGSize(width: ow, height: oh),
                       format: .RGBA8, colorSpace: Engine.srgb)
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
