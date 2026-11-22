import Foundation
import CoreImage
import CoreGraphics
import CoreML

/// 离线 Core ML 修复模型管理（支持用户导入 LaMa .mlpackage / .mlmodelc 图像修复模型）。
final class CoreMLInpaintingEngine: @unchecked Sendable {
    static let shared = CoreMLInpaintingEngine()
    private let lock = NSLock()
    private var cachedModel: MLModel?
    private var cachedInputSize: Int?
    private var cachedSummary: String?
    private var checkedPath = false
    private(set) var cacheToken: Int
    private(set) var lastUsedCoreML: Bool = false

    private init() {
        let hasModel = FileManager.default.fileExists(atPath: Self.compiledLaMaURL.path) ||
            Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc", subdirectory: "Models") != nil
        self.cacheToken = hasModel ? 1 : 0
    }

    static var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos/Models", isDirectory: true)
    }

    static var compiledLaMaURL: URL {
        modelsDirectory.appendingPathComponent("LaMa.mlmodelc", isDirectory: true)
    }

    private static func resolveModelURL() -> URL? {
        if FileManager.default.fileExists(atPath: compiledLaMaURL.path) {
            return compiledLaMaURL
        }
        return Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc", subdirectory: "Models")
    }

    var isModelInstalled: Bool {
        Self.resolveModelURL() != nil
    }

    var preferredInputSize: Int? {
        lock.lock()
        defer { lock.unlock() }
        return cachedInputSize
    }

    var modelSummary: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedSummary
    }

    func preloadInBackground(completion: (@Sendable (String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = self.loadModel()
            completion?(self.modelSummary)
        }
    }

    func installModel(from packageURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        let stageDir = Self.modelsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        let stagedURL = stageDir.appendingPathComponent("LaMa.mlmodelc", isDirectory: true)
        if packageURL.pathExtension.lowercased() == "mlmodelc" {
            try fm.copyItem(at: packageURL, to: stagedURL)
        } else {
            let compiled = try MLModel.compileModel(at: packageURL)
            try fm.moveItem(at: compiled, to: stagedURL)
        }

        let cfg = MLModelConfiguration()
        // Big-LaMa FFC 在 .all 下会触发数分钟 ANE 图编译且延迟更高，.cpuAndGPU 加载和推理都显著更快且精度一致
        cfg.computeUnits = .cpuAndGPU
        let validatedModel = try MLModel(contentsOf: stagedURL, configuration: cfg)
        guard Self.inspectInpaintSpec(from: validatedModel.modelDescription) != nil else {
            throw NSError(domain: "Phos.CoreMLInpaintingEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "模型输入输出不符合 LaMa 图像与掩膜规范"])
        }

        let dest = Self.compiledLaMaURL
        let backupURL = stageDir.appendingPathComponent("LaMa.old.mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.moveItem(at: dest, to: backupURL)
        }
        do {
            try fm.moveItem(at: stagedURL, to: dest)
        } catch {
            if fm.fileExists(atPath: backupURL.path) && !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: backupURL, to: dest)
            }
            throw error
        }

        lock.lock()
        cachedModel = nil
        cachedInputSize = nil
        cachedSummary = nil
        checkedPath = false
        cacheToken += 1
        lock.unlock()
        Engine.clearStageCache()
    }

    func removeModel() throws {
        let fm = FileManager.default
        let dest = Self.compiledLaMaURL
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        lock.lock()
        cachedModel = nil
        cachedInputSize = nil
        cachedSummary = nil
        checkedPath = false
        cacheToken += 1
        lock.unlock()
        Engine.clearStageCache()
    }

    private func loadModel() -> MLModel? {
        lock.lock()
        if checkedPath {
            let m = cachedModel
            lock.unlock()
            return m
        }
        lock.unlock()

        guard let url = Self.resolveModelURL() else {
            lock.lock()
            checkedPath = true
            cachedModel = nil
            cachedInputSize = nil
            cachedSummary = nil
            lock.unlock()
            return nil
        }

        let cfg = MLModelConfiguration()
        // 使用 .cpuAndGPU 避免 LaMa 快速傅里叶卷积触发 ANE 长耗时图编译
        cfg.computeUnits = .cpuAndGPU
        let loaded = try? MLModel(contentsOf: url, configuration: cfg)
        let spec = loaded.flatMap { Self.inspectInpaintSpec(from: $0.modelDescription) }
        let validModel = spec != nil ? loaded : nil

        lock.lock()
        checkedPath = true
        cachedModel = validModel
        cachedInputSize = spec?.preferredSize
        cachedSummary = spec.map { "LaMa \($0.inputWidth)×\($0.inputHeight)" }
        lock.unlock()
        return validModel
    }

    private enum TensorLayout {
        case nchw(cStride: Int, yStride: Int, xStride: Int, channels: Int, height: Int, width: Int)
        case nhwc(yStride: Int, xStride: Int, cStride: Int, height: Int, width: Int, channels: Int)
        case chw(cStride: Int, yStride: Int, xStride: Int, channels: Int, height: Int, width: Int)
        case hwc(yStride: Int, xStride: Int, cStride: Int, height: Int, width: Int, channels: Int)

        var width: Int {
            switch self {
            case let .nchw(_, _, _, _, _, w), let .nhwc(_, _, _, _, w, _),
                 let .chw(_, _, _, _, _, w), let .hwc(_, _, _, _, w, _): return w
            }
        }
        var height: Int {
            switch self {
            case let .nchw(_, _, _, _, h, _), let .nhwc(_, _, _, h, _, _),
                 let .chw(_, _, _, _, h, _), let .hwc(_, _, _, h, _, _): return h
            }
        }
        var channels: Int {
            switch self {
            case let .nchw(_, _, _, c, _, _), let .nhwc(_, _, _, _, _, c),
                 let .chw(_, _, _, c, _, _), let .hwc(_, _, _, _, _, c): return c
            }
        }

        func offset(c: Int, y: Int, x: Int) -> Int {
            switch self {
            case let .nchw(cs, ys, xs, _, _, _), let .chw(cs, ys, xs, _, _, _):
                return c * cs + y * ys + x * xs
            case let .nhwc(ys, xs, cs, _, _, _), let .hwc(ys, xs, cs, _, _, _):
                return y * ys + x * xs + c * cs
            }
        }
    }

    private enum InpaintSpec {
        case multiArray(imgKey: String, maskKey: String, imgShape: [NSNumber], imgDType: MLMultiArrayDataType,
                        maskShape: [NSNumber], maskDType: MLMultiArrayDataType, width: Int, height: Int)
        case imageBuffer(imgKey: String, maskKey: String, imgW: Int, imgH: Int, maskW: Int, maskH: Int)

        var inputWidth: Int {
            switch self {
            case let .multiArray(_, _, _, _, _, _, w, _): return w
            case let .imageBuffer(_, _, w, _, _, _): return w
            }
        }
        var inputHeight: Int {
            switch self {
            case let .multiArray(_, _, _, _, _, _, _, h): return h
            case let .imageBuffer(_, _, _, h, _, _): return h
            }
        }
        var preferredSize: Int { max(inputWidth, inputHeight) }
    }

    private static func parseTensorLayout(shape: [NSNumber], strides: [NSNumber]? = nil) -> TensorLayout? {
        let dims = shape.map { $0.intValue }
        let st: [Int]
        if let strides, strides.count == dims.count {
            st = strides.map { $0.intValue }
        } else {
            var computed = [Int](repeating: 1, count: dims.count)
            var acc = 1
            for i in stride(from: dims.count - 1, through: 0, by: -1) {
                computed[i] = acc
                acc *= max(1, dims[i])
            }
            st = computed
        }

        if dims.count == 4 {
            if (dims[1] == 3 || dims[1] == 1) && dims[2] >= 64 && dims[3] >= 64 {
                return .nchw(cStride: st[1], yStride: st[2], xStride: st[3], channels: dims[1], height: dims[2], width: dims[3])
            }
            if (dims[3] == 3 || dims[3] == 1) && dims[1] >= 64 && dims[2] >= 64 {
                return .nhwc(yStride: st[1], xStride: st[2], cStride: st[3], height: dims[1], width: dims[2], channels: dims[3])
            }
        } else if dims.count == 3 {
            if (dims[0] == 3 || dims[0] == 1) && dims[1] >= 64 && dims[2] >= 64 {
                return .chw(cStride: st[0], yStride: st[1], xStride: st[2], channels: dims[0], height: dims[1], width: dims[2])
            }
            if (dims[2] == 3 || dims[2] == 1) && dims[0] >= 64 && dims[1] >= 64 {
                return .hwc(yStride: st[0], xStride: st[1], cStride: st[2], height: dims[0], width: dims[1], channels: dims[2])
            }
        }
        return nil
    }

    private static func inspectInpaintSpec(from desc: MLModelDescription) -> InpaintSpec? {
        let inputs = desc.inputDescriptionsByName
        // Path A: MLMultiArray 输入（常见 Core ML 转换的 Big-LaMa 规范）
        let arrayInputs = inputs.compactMap { (key, fd) -> (String, MLMultiArrayConstraint, TensorLayout)? in
            guard fd.type == .multiArray, let mc = fd.multiArrayConstraint,
                  let layout = parseTensorLayout(shape: mc.shape) else { return nil }
            return (key, mc, layout)
        }
        if let imgEntry = arrayInputs.first(where: { $0.0.localizedCaseInsensitiveContains("image") && $0.2.channels == 3 })
            ?? arrayInputs.first(where: { $0.2.channels == 3 }),
           let maskEntry = arrayInputs.first(where: { $0.0.localizedCaseInsensitiveContains("mask") && $0.2.channels == 1 && $0.0 != imgEntry.0 })
            ?? arrayInputs.first(where: { $0.2.channels == 1 && $0.0 != imgEntry.0 }) {
            return .multiArray(
                imgKey: imgEntry.0, maskKey: maskEntry.0,
                imgShape: imgEntry.1.shape, imgDType: imgEntry.1.dataType,
                maskShape: maskEntry.1.shape, maskDType: maskEntry.1.dataType,
                width: imgEntry.2.width, height: imgEntry.2.height
            )
        }

        // Path B: CVPixelBuffer Image 输入
        if let imgKey = inputs.keys.first(where: { $0.localizedCaseInsensitiveContains("image") }),
           let maskKey = inputs.keys.first(where: { $0.localizedCaseInsensitiveContains("mask") }),
           let ic = inputs[imgKey]?.imageConstraint, let mc = inputs[maskKey]?.imageConstraint,
           ic.pixelsWide > 0, ic.pixelsHigh > 0, mc.pixelsWide > 0, mc.pixelsHigh > 0 {
            return .imageBuffer(imgKey: imgKey, maskKey: maskKey,
                                imgW: ic.pixelsWide, imgH: ic.pixelsHigh,
                                maskW: mc.pixelsWide, maskH: mc.pixelsHigh)
        }
        return nil
    }

    /// 尝试使用 Core ML 修复模型对 ROI 浮点缓冲修补（兼容 MLMultiArray 与 Image 双协议）。
    func inpaintIfAvailable(buf: inout [Float], mask: [Float], width w: Int, height h: Int) -> Bool {
        lock.lock()
        lastUsedCoreML = false
        lock.unlock()

        guard w > 0, h > 0, buf.count >= w * h * 4, mask.count >= w * h,
              let model = loadModel(),
              let spec = Self.inspectInpaintSpec(from: model.modelDescription) else {
            return false
        }

        let padSide = max(w, h)
        let padX = (padSide - w) / 2
        let padY = (padSide - h) / 2
        let dilateR = min(6, max(2, padSide / 160))
        let dilated = dilateBinaryMask(mask, w: w, h: h, threshold: 0.05, radius: dilateR)

        let reconstructedSRGB: [Float]
        let modelTw: Int
        let modelTh: Int

        switch spec {
        case let .multiArray(imgKey, maskKey, imgShape, imgDType, maskShape, maskDType, _, _):
            guard let imgArr = try? MLMultiArray(shape: imgShape, dataType: imgDType),
                  let maskArr = try? MLMultiArray(shape: maskShape, dataType: maskDType),
                  let imgLayout = Self.parseTensorLayout(shape: imgShape, strides: imgArr.strides),
                  let maskLayout = Self.parseTensorLayout(shape: maskShape, strides: maskArr.strides),
                  maskLayout.width > 0, maskLayout.height > 0 else { return false }

            fillMultiArrayInputs(
                imgArr: imgArr, imgLayout: imgLayout,
                maskArr: maskArr, maskLayout: maskLayout,
                buf: buf, dilated: dilated, srcW: w, srcH: h,
                padSide: padSide, padX: padX, padY: padY
            )
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                imgKey: MLFeatureValue(multiArray: imgArr),
                maskKey: MLFeatureValue(multiArray: maskArr)
            ]), let out = try? model.prediction(from: provider) else { return false }

            let outKey = out.featureNames.first(where: {
                let low = $0.lowercased()
                return low.contains("result") || low.contains("output") || low.contains("inpaint")
            }) ?? out.featureNames.first ?? "result"
            guard let outArr = out.featureValue(for: outKey)?.multiArrayValue,
                  let unpacked = unpackOutputMultiArray(outArr) else { return false }
            reconstructedSRGB = unpacked.srgb
            modelTw = unpacked.w
            modelTh = unpacked.h

        case let .imageBuffer(imgKey, maskKey, tw, th, mw, mh):
            guard let pbImg = makeSquareBilinearRGBABuffer(from: buf, dilated: dilated, srcW: w, srcH: h, dstW: tw, dstH: th, padSide: padSide, padX: padX, padY: padY),
                  let pbMask = makeSquareGrayBuffer(from: dilated, srcW: w, srcH: h, dstW: mw, dstH: mh, padSide: padSide, padX: padX, padY: padY),
                  let provider = try? MLDictionaryFeatureProvider(dictionary: [
                      imgKey: MLFeatureValue(pixelBuffer: pbImg),
                      maskKey: MLFeatureValue(pixelBuffer: pbMask)
                  ]), let out = try? model.prediction(from: provider) else { return false }

            let outKey = out.featureNames.first(where: {
                let low = $0.lowercased()
                return low.contains("result") || low.contains("output") || low.contains("inpaint")
            }) ?? out.featureNames.first ?? "output"
            guard let outPB = out.featureValue(for: outKey)?.imageBufferValue,
                  let unpacked = unpackOutputPixelBuffer(outPB) else { return false }
            reconstructedSRGB = unpacked.srgb
            modelTw = unpacked.w
            modelTh = unpacked.h
        }

        guard modelTw > 0, modelTh > 0 else { return false }
        resampleAndBlendOutput(
            srgbOut: reconstructedSRGB, outW: modelTw, outH: modelTh,
            into: &buf, mask: mask, dstW: w, dstH: h,
            padSide: padSide, padX: padX, padY: padY
        )

        lock.lock()
        lastUsedCoreML = true
        lock.unlock()
        return true
    }

    private func dilateBinaryMask(_ mask: [Float], w: Int, h: Int, threshold: Float, radius: Int) -> [Float] {
        var bin = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) where mask[i] > threshold { bin[i] = 1 }
        guard radius > 0 else { return bin.map { Float($0) } }

        // 分离式水平 + 垂直膨胀，复杂度 O(w*h*radius)
        var horiz = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let rowOff = y * w
            var run = 0
            let initMax = min(w - 1, radius)
            for x in 0...initMax { run += Int(bin[rowOff + x]) }
            for x in 0..<w {
                if run > 0 { horiz[rowOff + x] = 1 }
                let addX = x + radius + 1
                if addX < w { run += Int(bin[rowOff + addX]) }
                let remX = x - radius
                if remX >= 0 { run -= Int(bin[rowOff + remX]) }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for x in 0..<w {
            var run = 0
            let initMax = min(h - 1, radius)
            for y in 0...initMax { run += Int(horiz[y * w + x]) }
            for y in 0..<h {
                if run > 0 { out[y * w + x] = 1.0 }
                let addY = y + radius + 1
                if addY < h { run += Int(horiz[addY * w + x]) }
                let remY = y - radius
                if remY >= 0 { run -= Int(horiz[remY * w + x]) }
            }
        }
        return out
    }

    private func sampleMaskBoxOrBilinear(_ dilated: [Float], srcW: Int, srcH: Int, ux: Float, uy: Float, downsampleFactor: Float) -> Float {
        if downsampleFactor > 1.25 {
            let half = Int(ceil(downsampleFactor * 0.5))
            let cx = Int(ux.rounded()), cy = Int(uy.rounded())
            let x0 = max(0, cx - half), x1 = min(srcW - 1, cx + half)
            let y0 = max(0, cy - half), y1 = min(srcH - 1, cy + half)
            for sy in y0...y1 {
                for sx in x0...x1 where dilated[sy * srcW + sx] > 0.5 { return 1.0 }
            }
            return 0.0
        }
        let cx = min(max(ux, 0), Float(srcW - 1))
        let cy = min(max(uy, 0), Float(srcH - 1))
        let x0 = Int(floor(cx)), y0 = Int(floor(cy))
        let x1 = min(x0 + 1, srcW - 1), y1 = min(y0 + 1, srcH - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let v00 = dilated[y0 * srcW + x0], v10 = dilated[y0 * srcW + x1]
        let v01 = dilated[y1 * srcW + x0], v11 = dilated[y1 * srcW + x1]
        let v = (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy
        return v >= 0.35 ? 1.0 : 0.0
    }

    private func sampleBilinearSRGB(_ buf: [Float], srcW: Int, srcH: Int, ux: Float, uy: Float) -> (Float, Float, Float) {
        let cx = min(max(ux, 0), Float(srcW - 1))
        let cy = min(max(uy, 0), Float(srcH - 1))
        let x0 = Int(floor(cx)), y0 = Int(floor(cy))
        let x1 = min(x0 + 1, srcW - 1), y1 = min(y0 + 1, srcH - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
        let i00 = (y0 * srcW + x0) * 4, i10 = (y0 * srcW + x1) * 4
        let i01 = (y1 * srcW + x0) * 4, i11 = (y1 * srcW + x1) * 4
        let lr = buf[i00] * w00 + buf[i10] * w10 + buf[i01] * w01 + buf[i11] * w11
        let lg = buf[i00 + 1] * w00 + buf[i10 + 1] * w10 + buf[i01 + 1] * w01 + buf[i11 + 1] * w11
        let lb = buf[i00 + 2] * w00 + buf[i10 + 2] * w10 + buf[i01 + 2] * w01 + buf[i11 + 2] * w11
        return (toSRGB(min(max(lr, 0), 1)), toSRGB(min(max(lg, 0), 1)), toSRGB(min(max(lb, 0), 1)))
    }

    private func writeMultiArrayValue(_ arr: MLMultiArray, offset: Int, value: Float) {
        switch arr.dataType {
        case .float32:
            arr.dataPointer.assumingMemoryBound(to: Float.self)[offset] = value
        #if arch(arm64)
        case .float16:
            arr.dataPointer.assumingMemoryBound(to: Float16.self)[offset] = Float16(value)
        #endif
        case .double:
            arr.dataPointer.assumingMemoryBound(to: Double.self)[offset] = Double(value)
        default:
            break
        }
    }

    private func readMultiArrayValue(_ arr: MLMultiArray, offset: Int) -> Float {
        switch arr.dataType {
        case .float32:
            return arr.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        #if arch(arm64)
        case .float16:
            return Float(arr.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        #endif
        case .double:
            return Float(arr.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        default:
            return arr[offset].floatValue
        }
    }

    private func fillMultiArrayInputs(
        imgArr: MLMultiArray, imgLayout: TensorLayout,
        maskArr: MLMultiArray, maskLayout: TensorLayout,
        buf: [Float], dilated: [Float], srcW: Int, srcH: Int,
        padSide: Int, padX: Int, padY: Int
    ) {
        let tw = imgLayout.width, th = imgLayout.height
        let mw = maskLayout.width, mh = maskLayout.height
        let downFactorImg = Float(padSide) / Float(max(1, min(tw, th)))
        let downFactorMask = Float(padSide) / Float(max(1, min(mw, mh)))
        let pxOff = Float(padX), pyOff = Float(padY)

        if tw == mw && th == mh {
            for y in 0..<th {
                let fy = th > 1 ? Float(y) * Float(padSide - 1) / Float(th - 1) : 0
                let uy = fy - pyOff
                for x in 0..<tw {
                    let fx = tw > 1 ? Float(x) * Float(padSide - 1) / Float(tw - 1) : 0
                    let ux = fx - pxOff
                    let mVal = sampleMaskBoxOrBilinear(dilated, srcW: srcW, srcH: srcH, ux: ux, uy: uy, downsampleFactor: downFactorImg)
                    writeMultiArrayValue(maskArr, offset: maskLayout.offset(c: 0, y: y, x: x), value: mVal)
                    if mVal > 0.5 {
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 0, y: y, x: x), value: 0)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 1, y: y, x: x), value: 0)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 2, y: y, x: x), value: 0)
                    } else {
                        let (r, g, b) = sampleBilinearSRGB(buf, srcW: srcW, srcH: srcH, ux: ux, uy: uy)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 0, y: y, x: x), value: r)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 1, y: y, x: x), value: g)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 2, y: y, x: x), value: b)
                    }
                }
            }
        } else {
            for y in 0..<th {
                let fy = th > 1 ? Float(y) * Float(padSide - 1) / Float(th - 1) : 0
                let uy = fy - pyOff
                for x in 0..<tw {
                    let fx = tw > 1 ? Float(x) * Float(padSide - 1) / Float(tw - 1) : 0
                    let ux = fx - pxOff
                    let mVal = sampleMaskBoxOrBilinear(dilated, srcW: srcW, srcH: srcH, ux: ux, uy: uy, downsampleFactor: downFactorImg)
                    if mVal > 0.5 {
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 0, y: y, x: x), value: 0)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 1, y: y, x: x), value: 0)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 2, y: y, x: x), value: 0)
                    } else {
                        let (r, g, b) = sampleBilinearSRGB(buf, srcW: srcW, srcH: srcH, ux: ux, uy: uy)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 0, y: y, x: x), value: r)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 1, y: y, x: x), value: g)
                        writeMultiArrayValue(imgArr, offset: imgLayout.offset(c: 2, y: y, x: x), value: b)
                    }
                }
            }
            for y in 0..<mh {
                let fy = mh > 1 ? Float(y) * Float(padSide - 1) / Float(mh - 1) : 0
                let uy = fy - pyOff
                for x in 0..<mw {
                    let fx = mw > 1 ? Float(x) * Float(padSide - 1) / Float(mw - 1) : 0
                    let ux = fx - pxOff
                    let mVal = sampleMaskBoxOrBilinear(dilated, srcW: srcW, srcH: srcH, ux: ux, uy: uy, downsampleFactor: downFactorMask)
                    writeMultiArrayValue(maskArr, offset: maskLayout.offset(c: 0, y: y, x: x), value: mVal)
                }
            }
        }
    }

    private func unpackOutputMultiArray(_ arr: MLMultiArray) -> (srgb: [Float], w: Int, h: Int)? {
        guard let layout = Self.parseTensorLayout(shape: arr.shape, strides: arr.strides),
              layout.channels == 3 else { return nil }
        let w = layout.width, h = layout.height
        var maxSample: Float = 0
        for y in stride(from: 0, to: h, by: max(1, h / 16)) {
            for x in stride(from: 0, to: w, by: max(1, w / 16)) {
                for c in 0..<3 {
                    let v = readMultiArrayValue(arr, offset: layout.offset(c: c, y: y, x: x))
                    if v.isFinite && v > maxSample { maxSample = v }
                }
            }
        }
        let scale: Float = maxSample > 2.5 ? (1.0 / 255.0) : 1.0
        var srgb = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let dst = (y * w + x) * 3
                for c in 0..<3 {
                    let v = readMultiArrayValue(arr, offset: layout.offset(c: c, y: y, x: x)) * scale
                    srgb[dst + c] = v.isFinite ? min(max(v, 0), 1) : 0
                }
            }
        }
        return (srgb, w, h)
    }

    private func makeSquareBilinearRGBABuffer(
        from buf: [Float], dilated: [Float], srcW: Int, srcH: Int, dstW: Int, dstH: Int,
        padSide: Int, padX: Int, padY: Int
    ) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let downFactor = Float(padSide) / Float(max(1, min(dstW, dstH)))
        let pxOff = Float(padX), pyOff = Float(padY)
        for y in 0..<dstH {
            let fy = dstH > 1 ? Float(y) * Float(padSide - 1) / Float(dstH - 1) : 0
            let uy = fy - pyOff
            for x in 0..<dstW {
                let fx = dstW > 1 ? Float(x) * Float(padSide - 1) / Float(dstW - 1) : 0
                let ux = fx - pxOff
                let mVal = sampleMaskBoxOrBilinear(dilated, srcW: srcW, srcH: srcH, ux: ux, uy: uy, downsampleFactor: downFactor)
                let o = y * bpr + x * 4
                if mVal > 0.5 {
                    base[o] = 0; base[o + 1] = 0; base[o + 2] = 0; base[o + 3] = 255
                } else {
                    let (r, g, b) = sampleBilinearSRGB(buf, srcW: srcW, srcH: srcH, ux: ux, uy: uy)
                    base[o]     = UInt8(min(max(b * 255.0, 0), 255).rounded())
                    base[o + 1] = UInt8(min(max(g * 255.0, 0), 255).rounded())
                    base[o + 2] = UInt8(min(max(r * 255.0, 0), 255).rounded())
                    base[o + 3] = 255
                }
            }
        }
        return pixelBuffer
    }

    private func makeSquareGrayBuffer(
        from dilated: [Float], srcW: Int, srcH: Int, dstW: Int, dstH: Int,
        padSide: Int, padX: Int, padY: Int
    ) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, kCVPixelFormatType_OneComponent8, nil, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let downFactor = Float(padSide) / Float(max(1, min(dstW, dstH)))
        let pxOff = Float(padX), pyOff = Float(padY)
        for y in 0..<dstH {
            let fy = dstH > 1 ? Float(y) * Float(padSide - 1) / Float(dstH - 1) : 0
            let uy = fy - pyOff
            for x in 0..<dstW {
                let fx = dstW > 1 ? Float(x) * Float(padSide - 1) / Float(dstW - 1) : 0
                let ux = fx - pxOff
                let mVal = sampleMaskBoxOrBilinear(dilated, srcW: srcW, srcH: srcH, ux: ux, uy: uy, downsampleFactor: downFactor)
                base[y * bpr + x] = mVal > 0.5 ? 255 : 0
            }
        }
        return pixelBuffer
    }

    private func unpackOutputPixelBuffer(_ pb: CVPixelBuffer) -> (srgb: [Float], w: Int, h: Int)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var srgb = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bpr + x * 4
                let dst = (y * w + x) * 3
                srgb[dst]     = Float(base[o + 2]) / 255.0
                srgb[dst + 1] = Float(base[o + 1]) / 255.0
                srgb[dst + 2] = Float(base[o]) / 255.0
            }
        }
        return (srgb, w, h)
    }

    private func resampleAndBlendOutput(
        srgbOut: [Float], outW: Int, outH: Int,
        into buf: inout [Float], mask: [Float], dstW: Int, dstH: Int,
        padSide: Int, padX: Int, padY: Int
    ) {
        let sxScale = padSide > 1 ? Float(outW - 1) / Float(padSide - 1) : 0
        let syScale = padSide > 1 ? Float(outH - 1) / Float(padSide - 1) : 0

        var patchedSRGB = [Float](repeating: 0, count: dstW * dstH * 3)
        for y in 0..<dstH {
            let my = min(max(Float(y + padY) * syScale, 0), Float(outH - 1))
            let y0 = Int(floor(my)), y1 = min(y0 + 1, outH - 1)
            let fy = my - Float(y0)
            for x in 0..<dstW {
                let idx = y * dstW + x
                if mask[idx] <= 0.001 { continue }
                let mx = min(max(Float(x + padX) * sxScale, 0), Float(outW - 1))
                let x0 = Int(floor(mx)), x1 = min(x0 + 1, outW - 1)
                let fx = mx - Float(x0)
                let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                let i00 = (y0 * outW + x0) * 3, i10 = (y0 * outW + x1) * 3
                let i01 = (y1 * outW + x0) * 3, i11 = (y1 * outW + x1) * 3
                let dst = idx * 3
                patchedSRGB[dst]     = srgbOut[i00] * w00 + srgbOut[i10] * w10 + srgbOut[i01] * w01 + srgbOut[i11] * w11
                patchedSRGB[dst + 1] = srgbOut[i00 + 1] * w00 + srgbOut[i10 + 1] * w10 + srgbOut[i01 + 1] * w01 + srgbOut[i11 + 1] * w11
                patchedSRGB[dst + 2] = srgbOut[i00 + 2] * w00 + srgbOut[i10 + 2] * w10 + srgbOut[i01 + 2] * w01 + srgbOut[i11 + 2] * w11
            }
        }

        // 高像素 ROI 降采样上采样回写时，从洞外 16px 邻域环估算真实胶片/传感器微颗粒并补偿，避免修补块偏平
        var grainSigma: Float = 0
        if padSide > max(outW, outH), dstW >= 8, dstH >= 8 {
            var minMX = dstW, maxMX = -1, minMY = dstH, maxMY = -1
            for y in 0..<dstH {
                for x in 0..<dstW where mask[y * dstW + x] > 0.01 {
                    if x < minMX { minMX = x }; if x > maxMX { maxMX = x }
                    if y < minMY { minMY = y }; if y > maxMY { maxMY = y }
                }
            }
            if maxMX > minMX {
                let rx0 = max(1, minMX - 16), rx1 = min(dstW - 2, maxMX + 16)
                let ry0 = max(1, minMY - 16), ry1 = min(dstH - 2, maxMY + 16)
                func srcLuma(_ idx: Int) -> Float {
                    let i = idx * 4
                    return 0.2126 * toSRGB(buf[i]) + 0.7152 * toSRGB(buf[i + 1]) + 0.0722 * toSRGB(buf[i + 2])
                }
                func outLuma(_ idx: Int) -> Float {
                    let i = idx * 3
                    return 0.2126 * patchedSRGB[i] + 0.7152 * patchedSRGB[i + 1] + 0.0722 * patchedSRGB[i + 2]
                }
                var ringSumSq: Float = 0, ringCount = 0
                var patchSumSq: Float = 0, patchCount = 0
                for y in ry0...ry1 {
                    for x in rx0...rx1 {
                        let idx = y * dstW + x
                        let m = mask[idx]
                        if m <= 0.01 &&
                            mask[idx - 1] <= 0.01 && mask[idx + 1] <= 0.01 &&
                            mask[idx - dstW] <= 0.01 && mask[idx + dstW] <= 0.01 {
                            let res = srcLuma(idx) - 0.25 * (srcLuma(idx - 1) + srcLuma(idx + 1) + srcLuma(idx - dstW) + srcLuma(idx + dstW))
                            ringSumSq += res * res
                            ringCount += 1
                        } else if m > 0.8 &&
                                    mask[idx - 1] > 0.8 && mask[idx + 1] > 0.8 &&
                                    mask[idx - dstW] > 0.8 && mask[idx + dstW] > 0.8 {
                            let res = outLuma(idx) - 0.25 * (outLuma(idx - 1) + outLuma(idx + 1) + outLuma(idx - dstW) + outLuma(idx + dstW))
                            patchSumSq += res * res
                            patchCount += 1
                        }
                    }
                }
                if ringCount >= 32, patchCount >= 16 {
                    // 高通拉普拉斯残差与独立高斯噪声的标准差换算因子为 1 / sqrt(1.25)
                    let ringStd = sqrtf(ringSumSq / Float(ringCount) / 1.25)
                    let patchStd = sqrtf(patchSumSq / Float(patchCount) / 1.25)
                    if ringStd > patchStd * 1.15 && ringStd > 0.004 {
                        grainSigma = min(0.035, sqrtf(max(0, ringStd * ringStd - patchStd * patchStd)))
                    }
                }
            }
        }

        for y in 0..<dstH {
            for x in 0..<dstW {
                let idx = y * dstW + x
                let a = mask[idx]
                if a <= 0.001 { continue }
                let pi = idx * 3
                var sr = patchedSRGB[pi], sg = patchedSRGB[pi + 1], sb = patchedSRGB[pi + 2]
                if grainSigma > 0 {
                    let g0 = hashNormal(x: x, y: y, c: 0) * grainSigma
                    sr = min(max(sr + g0 + hashNormal(x: x, y: y, c: 1) * (grainSigma * 0.15), 0), 1)
                    sg = min(max(sg + g0 + hashNormal(x: x, y: y, c: 2) * (grainSigma * 0.15), 0), 1)
                    sb = min(max(sb + g0 + hashNormal(x: x, y: y, c: 3) * (grainSigma * 0.15), 0), 1)
                }
                let r = toLin(sr), g = toLin(sg), b = toLin(sb)
                let di = idx * 4
                buf[di]     = buf[di] * (1 - a) + r * a
                buf[di + 1] = buf[di + 1] * (1 - a) + g * a
                buf[di + 2] = buf[di + 2] * (1 - a) + b * a
            }
        }
    }

    private func hashNormal(x: Int, y: Int, c: Int) -> Float {
        func uniform(_ salt: UInt64) -> Float {
            var h = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15
            h ^= UInt64(bitPattern: Int64(y)) &* 0xBF58476D1CE4E5B9
            h ^= salt &* 0x94D049BB133111EB
            h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
            h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
            h ^= h >> 31
            return max(1e-6, Float(h & 0xFFFFFF) / Float(0x1000000))
        }
        let u1 = uniform(UInt64(c * 2 + 1))
        let u2 = uniform(UInt64(c * 2 + 2))
        return sqrtf(-2.0 * logf(u1)) * cosf(2.0 * Float.pi * u2)
    }

    private func toSRGB(_ v: Float) -> Float {
        let a = min(max(v, 0), 1)
        return a <= 0.0031308 ? a * 12.92 : 1.055 * powf(a, 1.0 / 2.4) - 0.055
    }
    private func toLin(_ v: Float) -> Float {
        let a = min(max(v, 0), 1)
        return a <= 0.04045 ? a / 12.92 : powf((a + 0.055) / 1.055, 2.4)
    }
}

/// 局部污点修复（Heal）、仿制克隆（Clone）与离线多尺度 PatchMatch 内容感知消除（Remove）。
enum RetouchEngine {
    static func apply(_ image: CIImage, spots: [RetouchSpot], workingSpace: CGColorSpace) -> CIImage {
        let active = spots.filter { $0.enabled && !$0.points.isEmpty && $0.opacity > 0.002 }
        guard !active.isEmpty else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width > 4, extent.height > 4 else { return image }

        var current = image
        for spot in active {
            current = applySingle(current, spot: spot, fullExtent: extent, workingSpace: workingSpace)
        }
        return current
    }

    private static func applySingle(_ image: CIImage, spot: RetouchSpot, fullExtent: CGRect, workingSpace: CGColorSpace) -> CIImage {
        let shortEdge = min(fullExtent.width, fullExtent.height)
        let rPx = max(3.0, spot.radius * Double(shortEdge))

        // 归一化坐标 (y 向上) -> 全图 CI 坐标 (y 向上)
        let ptsCI: [CGPoint] = spot.points.compactMap { pair in
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return nil }
            return CGPoint(
                x: fullExtent.minX + CGFloat(min(max(pair[0], 0), 1)) * fullExtent.width,
                y: fullExtent.minY + CGFloat(min(max(pair[1], 0), 1)) * fullExtent.height
            )
        }
        guard !ptsCI.isEmpty else { return image }

        var minX = ptsCI[0].x, maxX = ptsCI[0].x, minY = ptsCI[0].y, maxY = ptsCI[0].y
        for p in ptsCI {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }

        let targetPad = CGFloat(rPx) + 6
        let contextPad = max(CGFloat(rPx) * 4.2, 48)
        var roi = CGRect(
            x: minX - targetPad - contextPad,
            y: minY - targetPad - contextPad,
            width: (maxX - minX) + (targetPad + contextPad) * 2,
            height: (maxY - minY) + (targetPad + contextPad) * 2
        )
        // 如果手动指定了源点，则扩展 ROI 包住源区域（或至少留够源采样的空间）
        let srcAnchorCI: CGPoint? = spot.sourceX.flatMap { sx in
            spot.sourceY.map { sy in
                CGPoint(x: fullExtent.minX + CGFloat(min(max(sx, 0), 1)) * fullExtent.width,
                        y: fullExtent.minY + CGFloat(min(max(sy, 0), 1)) * fullExtent.height)
            }
        }
        if let srcPt = srcAnchorCI {
            let srcRect = CGRect(x: srcPt.x - targetPad - 12, y: srcPt.y - targetPad - 12,
                                 width: (maxX - minX) + (targetPad + 12) * 2,
                                 height: (maxY - minY) + (targetPad + 12) * 2)
            roi = roi.union(srcRect)
        }
        let lamaInstalled = (spot.mode == .remove) && CoreMLInpaintingEngine.shared.isModelInstalled
        if lamaInstalled {
            let side = max(roi.width, roi.height)
            let cx = roi.midX, cy = roi.midY
            roi = CGRect(x: cx - side * 0.5, y: cy - side * 0.5, width: side, height: side)
        }
        roi = roi.intersection(fullExtent).integral
        guard roi.width >= 4, roi.height >= 4 else { return image }

        let maxSide: CGFloat = lamaInstalled
            ? max(640, CGFloat(CoreMLInpaintingEngine.shared.preferredInputSize ?? 512))
            : 640
        let rawScale = min(1.0, maxSide / max(roi.width, roi.height))
        let workROI: CIImage
        let w: Int, h: Int
        let scaleX: CGFloat, scaleY: CGFloat
        if rawScale < 0.999 {
            w = max(4, Int((roi.width * rawScale).rounded()))
            h = max(4, Int((roi.height * rawScale).rounded()))
            scaleX = CGFloat(w) / roi.width
            scaleY = CGFloat(h) / roi.height
            workROI = image.cropped(to: roi)
                .transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY))
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        } else {
            w = Int(roi.width); h = Int(roi.height)
            scaleX = 1.0; scaleY = 1.0
            workROI = image.cropped(to: roi)
        }

        var buf = [Float](repeating: 0, count: w * h * 4)
        let renderBounds = rawScale < 0.999 ? CGRect(x: 0, y: 0, width: w, height: h) : roi
        Engine.ctx.render(workROI, toBitmap: &buf, rowBytes: w * 16, bounds: renderBounds,
                          format: .RGBAf, colorSpace: workingSpace)

        // 把 CI 点转成 top-down buf 本地像素坐标
        func toBufPt(_ ci: CGPoint) -> (x: Float, y: Float) {
            let lx = Float((ci.x - roi.minX) * scaleX)
            let ly = Float((roi.maxY - ci.y) * scaleY)
            return (lx, ly)
        }

        let bufPts = ptsCI.map(toBufPt)
        let rWork = Float(rPx * Double(min(scaleX, scaleY)))
        let feather = Float(min(max(spot.feather, 0.05), 1.0))
        let opacity = Float(min(max(spot.opacity, 0), 1))

        // 构建局部目标掩膜 [0..1]（以及核心二值损坏掩膜用于 PatchMatch/Poisson）
        var mask = [Float](repeating: 0, count: w * h)
        let hardR = rWork * (1.0 - feather * 0.45)
        let softSpan = max(rWork - hardR, 1.0)
        for y in 0..<h {
            for x in 0..<w {
                let d = minDistToPolyline(px: Float(x) + 0.5, py: Float(y) + 0.5, pts: bufPts)
                if d < rWork {
                    let a = d <= hardR ? 1.0 : max(0.0, min(1.0, (rWork - d) / softSpan))
                    // 平滑 Hermite 过渡
                    mask[y * w + x] = a * a * (3.0 - 2.0 * a)
                }
            }
        }

        let targetCenter = bufPts[0]
        var resultBuf = buf

        switch spot.mode {
        case .clone:
            let srcBufPt = srcAnchorCI.map(toBufPt) ?? findBestSourcePatch(buf: buf, mask: mask, w: w, h: h, center: targetCenter, radius: rWork)
            let dx = Int((srcBufPt.x - targetCenter.x).rounded())
            let dy = Int((srcBufPt.y - targetCenter.y).rounded())
            for y in 0..<h {
                for x in 0..<w {
                    let idx = y * w + x
                    let a = mask[idx] * opacity
                    if a <= 0.001 { continue }
                    let sx = min(max(x + dx, 0), w - 1)
                    let sy = min(max(y + dy, 0), h - 1)
                    let si = (sy * w + sx) * 4, di = idx * 4
                    for c in 0..<3 {
                        resultBuf[di + c] = buf[di + c] * (1 - a) + buf[si + c] * a
                    }
                }
            }

        case .heal:
            let srcBufPt = srcAnchorCI.map(toBufPt) ?? findBestSourcePatch(buf: buf, mask: mask, w: w, h: h, center: targetCenter, radius: rWork)
            let dx = Int((srcBufPt.x - targetCenter.x).rounded())
            let dy = Int((srcBufPt.y - targetCenter.y).rounded())
            poissonHeal(src: buf, dst: &resultBuf, mask: mask, w: w, h: h, dx: dx, dy: dy, opacity: opacity)

        case .remove:
            var core = buf
            if !CoreMLInpaintingEngine.shared.inpaintIfAvailable(buf: &core, mask: mask, width: w, height: h) {
                patchMatchInpaint(buf: &core, mask: mask, w: w, h: h)
            }
            for y in 0..<h {
                for x in 0..<w {
                    let idx = y * w + x
                    let a = mask[idx] * opacity
                    if a <= 0.001 { continue }
                    let di = idx * 4
                    for c in 0..<3 {
                        resultBuf[di + c] = buf[di + c] * (1 - a) + core[di + c] * a
                    }
                }
            }
        }

        let outData = resultBuf.withUnsafeBytes { Data($0) }
        var patched = CIImage(bitmapData: outData, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                              format: .RGBAf, colorSpace: workingSpace)
        if rawScale < 0.999 {
            patched = patched.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: 1.0 / scaleX, y: 1.0 / scaleY))
                .cropped(to: CGRect(x: 0, y: 0, width: roi.width, height: roi.height))
        }
        patched = patched.transformed(by: CGAffineTransform(translationX: roi.minX, y: roi.minY))
            .cropped(to: roi)
        return patched.composited(over: image).cropped(to: fullExtent)
    }

    private static func minDistToPolyline(px: Float, py: Float, pts: [(x: Float, y: Float)]) -> Float {
        if pts.count == 1 {
            return hypot(px - pts[0].x, py - pts[0].y)
        }
        var best = Float.greatestFiniteMagnitude
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let vx = b.x - a.x, vy = b.y - a.y
            let len2 = vx * vx + vy * vy
            let t = len2 > 1e-5 ? max(0.0, min(1.0, ((px - a.x) * vx + (py - a.y) * vy) / len2)) : 0.0
            let d = hypot(px - (a.x + t * vx), py - (a.y + t * vy))
            if d < best { best = d }
        }
        return best
    }

    /// 自动在周围 16 方向 × 2 倍率环上搜索边界色差与纹理梯度最匹配的干净源块
    private static func findBestSourcePatch(buf: [Float], mask: [Float], w: Int, h: Int,
                                            center: (x: Float, y: Float), radius: Float) -> (x: Float, y: Float) {
        let rInt = max(2, Int(radius.rounded()))
        var bestScore = Float.greatestFiniteMagnitude
        var bestPt = (x: min(Float(w - rInt - 2), center.x + radius * 2.5), y: center.y)

        // 取目标周界环采样对比
        var ringOffsets: [(Int, Int)] = []
        for aIdx in 0..<16 {
            let ang = Float(aIdx) * .pi * 2.0 / 16.0
            ringOffsets.append((Int(cos(ang) * Float(rInt + 2)), Int(sin(ang) * Float(rInt + 2))))
        }

        for mult: Float in [2.3, 3.2] {
            let dist = max(radius * mult, Float(rInt + 4))
            for dir in 0..<16 {
                let ang = Float(dir) * .pi * 2.0 / 16.0
                let cx = Int((center.x + cos(ang) * dist).rounded())
                let cy = Int((center.y + sin(ang) * dist).rounded())
                if cx - rInt - 2 < 0 || cx + rInt + 2 >= w || cy - rInt - 2 < 0 || cy + rInt + 2 >= h { continue }
                // 源区本身不能落在当前待修复遮罩内
                if mask[cy * w + cx] > 0.1 { continue }
                var valid = true
                var diffSum: Float = 0
                var varSum: Float = 0
                for (ox, oy) in ringOffsets {
                    let tx = Int(center.x) + ox, ty = Int(center.y) + oy
                    let sx = cx + ox, sy = cy + oy
                    if tx < 0 || tx >= w || ty < 0 || ty >= h || mask[sy * w + sx] > 0.1 {
                        valid = false; break
                    }
                    let ti = (ty * w + tx) * 4, si = (sy * w + sx) * 4
                    let dr = buf[ti] - buf[si], dg = buf[ti + 1] - buf[si + 1], db = buf[ti + 2] - buf[si + 2]
                    diffSum += dr * dr + dg * dg + db * db
                    // 源区内部平滑度奖励（倾向选干净纹理）
                    let ci = (cy * w + cx) * 4
                    let vr = buf[si] - buf[ci], vg = buf[si + 1] - buf[ci + 1], vb = buf[si + 2] - buf[ci + 2]
                    varSum += vr * vr + vg * vg + vb * vb
                }
                if !valid { continue }
                let score = diffSum + varSum * 0.25
                if score < bestScore {
                    bestScore = score
                    bestPt = (Float(cx), Float(cy))
                }
            }
        }
        return bestPt
    }

    /// 无缝泊松修补（Gauss-Seidel 求解 Δu = Δs，使源纹理梯度贴合目标四周光影颜色）
    private static func poissonHeal(src: [Float], dst: inout [Float], mask: [Float],
                                    w: Int, h: Int, dx: Int, dy: Int, opacity: Float) {
        var holeIndices: [Int] = []
        holeIndices.reserveCapacity(w * h / 3)
        var inside = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let idx = y * w + x
                if mask[idx] > 0.02 {
                    inside[idx] = true
                    holeIndices.append(idx)
                }
            }
        }
        guard !holeIndices.isEmpty else { return }

        // 先算引导拉普拉斯 b = 4*s - s_N - s_S - s_W - s_E 并初始化 u
        var u = src
        var rhs = [Float](repeating: 0, count: w * h * 3)
        for idx in holeIndices {
            let x = idx % w, y = idx / w
            let sx = min(max(x + dx, 1), w - 2)
            let sy = min(max(y + dy, 1), h - 2)
            let si = sy * w + sx
            for c in 0..<3 {
                let lap = 4 * src[si * 4 + c]
                    - src[(si - 1) * 4 + c] - src[(si + 1) * 4 + c]
                    - src[(si - w) * 4 + c] - src[(si + w) * 4 + c]
                rhs[idx * 3 + c] = lap
                u[idx * 4 + c] = src[si * 4 + c]
            }
        }

        // SOR 迭代（ω = 1.65）仅在洞内跑 28 轮即高度收敛
        let omega: Float = 1.65
        for _ in 0..<28 {
            for idx in holeIndices {
                for c in 0..<3 {
                    let sumN = u[(idx - 1) * 4 + c] + u[(idx + 1) * 4 + c]
                        + u[(idx - w) * 4 + c] + u[(idx + w) * 4 + c]
                    let target = (sumN + rhs[idx * 3 + c]) * 0.25
                    let old = u[idx * 4 + c]
                    u[idx * 4 + c] = max(0, old + omega * (target - old))
                }
            }
        }

        for idx in holeIndices {
            let a = mask[idx] * opacity
            let di = idx * 4
            for c in 0..<3 {
                dst[di + c] = src[di + c] * (1 - a) + u[di + c] * a
            }
        }
    }

    // MARK: - 4 层图像金字塔多尺度 PatchMatch 离线消除
    private static func patchMatchInpaint(buf: inout [Float], mask: [Float], w: Int, h: Int) {
        struct Level {
            var img: [Float]
            var msk: [UInt8] // 1=需要修复，0=已知干净区
            let w: Int
            let h: Int
        }

        // 1) 构建 4 层金字塔
        var levels: [Level] = []
        let m0: [UInt8] = mask.map { $0 > 0.12 ? 1 : 0 }
        levels.append(Level(img: buf, msk: m0, w: w, h: h))

        for _ in 0..<3 {
            let prev = levels.last!
            if prev.w < 16 || prev.h < 16 { break }
            let nw = max(8, prev.w / 2), nh = max(8, prev.h / 2)
            var nImg = [Float](repeating: 0, count: nw * nh * 4)
            var nMsk = [UInt8](repeating: 0, count: nw * nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0, validCnt: Float = 0
                    var anyUnknown = false
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let px = min(prev.w - 1, x * 2 + dx)
                            let py = min(prev.h - 1, y * 2 + dy)
                            let pi = py * prev.w + px
                            if prev.msk[pi] == 1 { anyUnknown = true }
                            else {
                                sr += prev.img[pi * 4]; sg += prev.img[pi * 4 + 1]; sb += prev.img[pi * 4 + 2]
                                validCnt += 1
                            }
                        }
                    }
                    let ni = y * nw + x
                    if validCnt > 0 {
                        nImg[ni * 4] = sr / validCnt; nImg[ni * 4 + 1] = sg / validCnt; nImg[ni * 4 + 2] = sb / validCnt
                        nMsk[ni] = 0
                    } else {
                        nMsk[ni] = anyUnknown ? 1 : 0
                    }
                    nImg[ni * 4 + 3] = 1
                }
            }
            levels.append(Level(img: nImg, msk: nMsk, w: nw, h: nh))
        }

        // 2) 最粗层做边界扩散初始化（Onion-peel 均值填充）
        var coarsest = levels[levels.count - 1]
        diffusionInit(img: &coarsest.img, msk: coarsest.msk, w: coarsest.w, h: coarsest.h, iterations: 16)
        levels[levels.count - 1] = coarsest

        // 3) 自粗向细逐层做 PatchMatch + EM 重建
        for li in stride(from: levels.count - 1, through: 0, by: -1) {
            var lv = levels[li]
            runPatchMatchLevel(img: &lv.img, msk: lv.msk, w: lv.w, h: lv.h, iterations: li == 0 ? 3 : 4)
            levels[li] = lv
            if li > 0 {
                // 上采样填补下一细层的未知区初值
                var finer = levels[li - 1]
                for y in 0..<finer.h {
                    let cy = min(lv.h - 1, y / 2)
                    for x in 0..<finer.w {
                        let fi = y * finer.w + x
                        if finer.msk[fi] == 1 {
                            let cx = min(lv.w - 1, x / 2)
                            let ci = cy * lv.w + cx
                            finer.img[fi * 4]     = lv.img[ci * 4]
                            finer.img[fi * 4 + 1] = lv.img[ci * 4 + 1]
                            finer.img[fi * 4 + 2] = lv.img[ci * 4 + 2]
                        }
                    }
                }
                levels[li - 1] = finer
            }
        }
        buf = levels[0].img
    }

    private static func diffusionInit(img: inout [Float], msk: [UInt8], w: Int, h: Int, iterations: Int) {
        var valid = msk.map { $0 == 0 }
        for _ in 0..<iterations {
            var nextImg = img
            var nextValid = valid
            var remaining = false
            for y in 0..<h {
                for x in 0..<w {
                    let idx = y * w + x
                    if valid[idx] { continue }
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0, cnt: Float = 0
                    for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, nx < w, ny >= 0, ny < h, valid[ny * w + nx] {
                            let ni = (ny * w + nx) * 4
                            sr += img[ni]; sg += img[ni + 1]; sb += img[ni + 2]; cnt += 1
                        }
                    }
                    if cnt > 0 {
                        nextImg[idx * 4] = sr / cnt; nextImg[idx * 4 + 1] = sg / cnt; nextImg[idx * 4 + 2] = sb / cnt
                        nextValid[idx] = true
                    } else {
                        remaining = true
                    }
                }
            }
            img = nextImg; valid = nextValid
            if !remaining { break }
        }
        // 多做 6 轮拉普拉斯平滑
        for _ in 0..<6 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let idx = y * w + x
                    if msk[idx] == 0 { continue }
                    for c in 0..<3 {
                        img[idx * 4 + c] = 0.25 * (img[(idx - 1) * 4 + c] + img[(idx + 1) * 4 + c]
                                                 + img[(idx - w) * 4 + c] + img[(idx + w) * 4 + c])
                    }
                }
            }
        }
    }

    private static func runPatchMatchLevel(img: inout [Float], msk: [UInt8], w: Int, h: Int, iterations: Int) {
        let pr = 2 // 5x5 patch
        guard w > pr * 2 + 2, h > pr * 2 + 2 else { return }

        // 只记录完全位于已知区的合法候选像素（保证 patch 5x5 不踩雷）
        var knownSources: [(x: Int, y: Int)] = []
        knownSources.reserveCapacity(w * h)
        for y in pr..<(h - pr) {
            for x in pr..<(w - pr) {
                var ok = true
                for dy in -pr...pr where ok {
                    for dx in -pr...pr {
                        if msk[(y + dy) * w + (x + dx)] == 1 { ok = false; break }
                    }
                }
                if ok { knownSources.append((x, y)) }
            }
        }
        guard !knownSources.isEmpty else { return }

        var holePixels: [Int] = []
        for y in pr..<(h - pr) {
            for x in pr..<(w - pr) {
                if msk[y * w + x] == 1 { holePixels.append(y * w + x) }
            }
        }
        guard !holePixels.isEmpty else { return }

        var nnfX = [Int](repeating: knownSources[0].x, count: w * h)
        var nnfY = [Int](repeating: knownSources[0].y, count: w * h)
        var nnfDist = [Float](repeating: Float.greatestFiniteMagnitude, count: w * h)

        var rng: UInt64 = 0x5DEECE66D
        func nextRand(_ bound: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(max(1, bound)))
        }

        func isValidPatchCenter(_ cx: Int, _ cy: Int) -> Bool {
            guard cx >= pr, cx < w - pr, cy >= pr, cy < h - pr else { return false }
            for dy in -pr...pr {
                for dx in -pr...pr {
                    if msk[(cy + dy) * w + (cx + dx)] == 1 { return false }
                }
            }
            return true
        }

        func patchDistance(tx: Int, ty: Int, sx: Int, sy: Int) -> Float {
            var sum: Float = 0
            for dy in -pr...pr {
                for dx in -pr...pr {
                    let ti = ((ty + dy) * w + (tx + dx)) * 4
                    let si = ((sy + dy) * w + (sx + dx)) * 4
                    let dr = img[ti] - img[si], dg = img[ti + 1] - img[si + 1], db = img[ti + 2] - img[si + 2]
                    let wgt: Float = msk[(ty + dy) * w + (tx + dx)] == 0 ? 1.5 : 0.85
                    sum += (dr * dr + dg * dg + db * db) * wgt
                }
            }
            return sum
        }

        // 随机初始化 NNF
        for idx in holePixels {
            let x = idx % w, y = idx / w
            let s = knownSources[nextRand(knownSources.count)]
            nnfX[idx] = s.x; nnfY[idx] = s.y
            nnfDist[idx] = patchDistance(tx: x, ty: y, sx: s.x, sy: s.y)
        }

        for iter in 0..<iterations {
            let reverse = iter % 2 == 1
            let scan = reverse ? Array(holePixels.reversed()) : holePixels
            let step = reverse ? 1 : -1

            for idx in scan {
                let x = idx % w, y = idx / w
                // 1) 空间传播
                for (nx, ny) in [(x + step, y), (x, y + step)] {
                    if nx >= pr, nx < w - pr, ny >= pr, ny < h - pr {
                        let nIdx = ny * w + nx
                        let cx = nnfX[nIdx] - step * (nx == x + step ? 1 : 0)
                        let cy = nnfY[nIdx] - step * (ny == y + step ? 1 : 0)
                        if isValidPatchCenter(cx, cy) {
                            let d = patchDistance(tx: x, ty: y, sx: cx, sy: cy)
                            if d < nnfDist[idx] { nnfX[idx] = cx; nnfY[idx] = cy; nnfDist[idx] = d }
                        }
                    }
                }
                // 2) 随机窗口搜索
                var radius = max(w, h) / 2
                while radius >= 2 {
                    let cx = min(max(nnfX[idx] + nextRand(radius * 2 + 1) - radius, pr), w - pr - 1)
                    let cy = min(max(nnfY[idx] + nextRand(radius * 2 + 1) - radius, pr), h - pr - 1)
                    if isValidPatchCenter(cx, cy) {
                        let d = patchDistance(tx: x, ty: y, sx: cx, sy: cy)
                        if d < nnfDist[idx] { nnfX[idx] = cx; nnfY[idx] = cy; nnfDist[idx] = d }
                    }
                    radius /= 2
                }
            }

            // 3) 多块加权像素重建（EM-like voting）
            var accR = [Float](repeating: 0, count: w * h)
            var accG = [Float](repeating: 0, count: w * h)
            var accB = [Float](repeating: 0, count: w * h)
            var accW = [Float](repeating: 0, count: w * h)

            for idx in holePixels {
                let tx = idx % w, ty = idx / w
                let sx = nnfX[idx], sy = nnfY[idx]
                let weight = 1.0 / (nnfDist[idx] + 0.01)
                for dy in -pr...pr {
                    for dx in -pr...pr {
                        let di = (ty + dy) * w + (tx + dx)
                        if msk[di] == 0 { continue }
                        let si = ((sy + dy) * w + (sx + dx)) * 4
                        accR[di] += img[si] * weight
                        accG[di] += img[si + 1] * weight
                        accB[di] += img[si + 2] * weight
                        accW[di] += weight
                    }
                }
            }
            for idx in holePixels where accW[idx] > 0 {
                img[idx * 4]     = accR[idx] / accW[idx]
                img[idx * 4 + 1] = accG[idx] / accW[idx]
                img[idx * 4 + 2] = accB[idx] / accW[idx]
            }
        }
    }
}
