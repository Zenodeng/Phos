import Foundation
import Metal
import CoreImage
import CoreGraphics
import simd

/// 管理全局共享 MTLDevice、MTLCommandQueue、编译后的 MSL 管线和 GPU 算子。
final class MetalEngine: @unchecked Sendable {
    static let shared = MetalEngine()

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let library: MTLLibrary?
    let compileError: String?
    let ciContext: CIContext

    private let lock = NSLock()
    private var pipelines: [String: MTLComputePipelineState] = [:]

    private init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        if let dev {
            do {
                self.library = try dev.makeLibrary(source: MetalShaders.source, options: nil)
                self.compileError = nil
            } catch {
                self.library = nil
                self.compileError = "\(error)"
                fputs("[Phos Metal] Shader compile failed: \(error)\n", stderr)
            }
        } else {
            self.library = nil
            self.compileError = "No Metal device"
        }

        let workingSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        if let q = commandQueue {
            self.ciContext = CIContext(mtlCommandQueue: q, options: [
                .workingColorSpace: workingSRGB,
                .workingFormat: CIFormat.RGBAh,
                .cacheIntermediates: false,
                .allowLowPower: false
            ])
        } else if let dev {
            self.ciContext = CIContext(mtlDevice: dev, options: [
                .workingColorSpace: workingSRGB,
                .workingFormat: CIFormat.RGBAh,
                .cacheIntermediates: false,
                .allowLowPower: false
            ])
        } else {
            self.ciContext = CIContext(options: [
                .workingColorSpace: workingSRGB,
                .workingFormat: CIFormat.RGBAh,
                .cacheIntermediates: false,
                .allowLowPower: false
            ])
        }
    }

    var isAvailable: Bool { device != nil && library != nil }

    func pipeline(_ name: String) -> MTLComputePipelineState? {
        lock.lock()
        defer { lock.unlock() }
        if let p = pipelines[name] { return p }
        guard let dev = device, let fn = library?.makeFunction(name: name),
              let p = try? dev.makeComputePipelineState(function: fn) else { return nil }
        pipelines[name] = p
        return p
    }

    static func allKernelNames() -> [String] {
        ["contrast_agx", "gf_pack", "gf_pack_logluma", "gf_pack_darkchannel",
         "gf_box_h", "gf_box_v", "gf_coeff", "gf_apply_mask",
         "local_tone_apply", "dehaze_apply", "edge_detail_apply",
         "curves_grading_apply", "oklch_color_apply", "film_grain_apply",
         "mask_boolean_combine", "clipping_overlay",
         "bokeh_optical_apply", "depth_visualize_overlay", "raw_denoise_apply", "super_res_enhance"]
    }

    func selfTestAllPipelines() -> Bool {
        guard isAvailable else { return false }
        return Self.allKernelNames().allSatisfy { pipeline($0) != nil }
    }

    func makePrivateTexture(width: Int, height: Int, format: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
        guard let dev = device, width > 0, height > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        return dev.makeTexture(descriptor: desc)
    }

    static func dispatch2D(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let tw = max(1, min(16, pipeline.threadExecutionWidth))
        let th = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tw))
        let groupSize = MTLSize(width: tw, height: th, depth: 1)
        let gridSize = MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1)
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: groupSize)
    }

    static func textureOffset(inputRegion: CGRect, outputRegion: CGRect) -> (Int32, Int32) {
        let ox = Int32((outputRegion.minX - inputRegion.minX).rounded())
        let oy = Int32((inputRegion.maxY - outputRegion.maxY).rounded())
        return (ox, oy)
    }

    static func extentArgs(_ e: CGRect) -> [Double] {
        [Double(e.minX), Double(e.minY), Double(e.width), Double(e.height)]
    }

    static func expandedROI(outputRect: CGRect, arguments: [String: Any]?, radiusKeys: [String]) -> CGRect {
        let maxR = radiusKeys.compactMap { (arguments?[$0] as? NSNumber)?.doubleValue }.max() ?? 0
        let pad = CGFloat(ceil(max(0, maxR) * 2.0))
        let grown = pad > 0 ? outputRect.insetBy(dx: -pad, dy: -pad) : outputRect
        if let arr = arguments?["extent"] as? [Double], arr.count == 4 {
            let ext = CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
            let clamped = grown.intersection(ext)
            return clamped.isNull ? outputRect : clamped
        }
        return grown
    }
}

// MARK: - 1. 对数对比度 + AgX 高光滚降
final class MetalContrastAgXKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pso = MetalEngine.shared.pipeline("contrast_agx"),
              let encoder = cmd.makeComputeCommandEncoder() else { return }

        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        var u = MetalShaders.ContrastAgXUniforms(
            contrast: (arguments?["contrast"] as? NSNumber)?.floatValue ?? 0,
            pivotOffset: (arguments?["pivot"] as? NSNumber)?.floatValue ?? 0,
            rolloff: (arguments?["rolloff"] as? NSNumber)?.floatValue ?? 0,
            offsetX: ox, offsetY: oy
        )
        encoder.setComputePipelineState(pso)
        encoder.setTexture(inTex, index: 0)
        encoder.setTexture(outTex, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<MetalShaders.ContrastAgXUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(encoder, pipeline: pso, width: outTex.width, height: outTex.height)
        encoder.endEncoding()
    }

    static func apply(_ image: CIImage, contrast: Double, pivot: Double, rolloff: Double) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite,
              abs(contrast) > 0.01 || rolloff > 0.01 else { return image }
        let args: [String: Any] = [
            "contrast": NSNumber(value: Float(contrast / 100.0)),
            "pivot": NSNumber(value: Float(pivot / 50.0)),
            "rolloff": NSNumber(value: Float(min(max(rolloff / 100.0, 0), 1)))
        ]
        return (try? apply(withExtent: e, inputs: [image], arguments: args)) ?? image
    }
}

// MARK: - 2. 内部 Fast Guided Filter 编码器
private enum GuidedFilterPass {
    /// 对单通道目标（或基于引导图的暗通道/对数亮度）运行 Fast Guided Filter，返回低频线性系数 (a, b) 纹理。
    static func encodeCoefficients(
        cmd: MTLCommandBuffer,
        guideTex: MTLTexture,
        targetTex: MTLTexture?,
        packKernel: String,
        fullWidth: Int,
        fullHeight: Int,
        radius: CGFloat,
        eps: Float,
        selfGuided: Bool
    ) -> MTLTexture? {
        let engine = MetalEngine.shared
        // Fast Guided Filter 降采样因子（半径越大降采样越多，保持计算在常数级别内）
        let sub: Int
        if radius > 28 { sub = 4 }
        else if radius > 10 { sub = 2 }
        else { sub = 1 }

        let sw = max(4, (fullWidth + sub - 1) / sub)
        let sh = max(4, (fullHeight + sub - 1) / sub)
        let subRadius = max(1, Int((radius / CGFloat(sub)).rounded()))

        guard let texA = engine.makePrivateTexture(width: sw, height: sh, format: .rgba32Float),
              let texB = engine.makePrivateTexture(width: sw, height: sh, format: .rgba32Float),
              let texMean = engine.makePrivateTexture(width: sw, height: sh, format: .rgba32Float),
              let texCoeff = engine.makePrivateTexture(width: sw, height: sh, format: .rgba32Float),
              let texCoeffMean = engine.makePrivateTexture(width: sw, height: sh, format: .rgba32Float),
              let pPack = engine.pipeline(packKernel),
              let pBoxH = engine.pipeline("gf_box_h"),
              let pBoxV = engine.pipeline("gf_box_v"),
              let pCoeff = engine.pipeline("gf_coeff"),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }

        // 1) Pack (I, p, I*I, I*p) at sub-resolution
        enc.setComputePipelineState(pPack)
        enc.setTexture(guideTex, index: 0)
        if packKernel == "gf_pack" {
            enc.setTexture(targetTex ?? guideTex, index: 1)
            enc.setTexture(texA, index: 2)
            var pu = MetalShaders.GuidedFilterPackUniforms(scaleX: 1, scaleY: 1, inOriginX: 0, inOriginY: 0, selfGuided: selfGuided ? 1 : 0)
            enc.setBytes(&pu, length: MemoryLayout<MetalShaders.GuidedFilterPackUniforms>.stride, index: 0)
        } else {
            enc.setTexture(texA, index: 1)
        }
        MetalEngine.dispatch2D(enc, pipeline: pPack, width: sw, height: sh)

        var bu = MetalShaders.BoxPassUniforms(radius: Int32(subRadius))
        // 2) Mean of (I, p, II, Ip)
        enc.setComputePipelineState(pBoxH)
        enc.setTexture(texA, index: 0); enc.setTexture(texB, index: 1)
        enc.setBytes(&bu, length: MemoryLayout<MetalShaders.BoxPassUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pBoxH, width: sw, height: sh)

        enc.setComputePipelineState(pBoxV)
        enc.setTexture(texB, index: 0); enc.setTexture(texMean, index: 1)
        enc.setBytes(&bu, length: MemoryLayout<MetalShaders.BoxPassUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pBoxV, width: sw, height: sh)

        // 3) Compute (a, b)
        var cu = MetalShaders.GuidedCoeffUniforms(eps: eps)
        enc.setComputePipelineState(pCoeff)
        enc.setTexture(texMean, index: 0); enc.setTexture(texCoeff, index: 1)
        enc.setBytes(&cu, length: MemoryLayout<MetalShaders.GuidedCoeffUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pCoeff, width: sw, height: sh)

        // 4) Mean of (a, b)
        enc.setComputePipelineState(pBoxH)
        enc.setTexture(texCoeff, index: 0); enc.setTexture(texB, index: 1)
        enc.setBytes(&bu, length: MemoryLayout<MetalShaders.BoxPassUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pBoxH, width: sw, height: sh)

        enc.setComputePipelineState(pBoxV)
        enc.setTexture(texB, index: 0); enc.setTexture(texCoeffMean, index: 1)
        enc.setBytes(&bu, length: MemoryLayout<MetalShaders.BoxPassUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pBoxV, width: sw, height: sh)

        enc.endEncoding()
        return texCoeffMean
    }
}

// MARK: - 3. 保边局部影调 (Highlights / Shadows + 双向 Whites / Blacks)
final class MetalLocalToneKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        MetalEngine.expandedROI(outputRect: outputRect, arguments: arguments, radiusKeys: ["radius"])
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("local_tone_apply") else { return }

        let hi = (arguments?["highlights"] as? NSNumber)?.floatValue ?? 0
        let sh = (arguments?["shadows"] as? NSNumber)?.floatValue ?? 0
        let wh = (arguments?["whites"] as? NSNumber)?.floatValue ?? 0
        let bl = (arguments?["blacks"] as? NSNumber)?.floatValue ?? 0
        let radius = CGFloat((arguments?["radius"] as? NSNumber)?.doubleValue ?? 24)

        let coeffTex: MTLTexture?
        if abs(hi) > 1e-4 || abs(sh) > 1e-4 {
            coeffTex = GuidedFilterPass.encodeCoefficients(
                cmd: cmd, guideTex: inTex, targetTex: nil, packKernel: "gf_pack_logluma",
                fullWidth: inTex.width, fullHeight: inTex.height, radius: radius, eps: 0.0025, selfGuided: true)
        } else {
            coeffTex = inTex
        }
        guard let coeffTex, let enc = cmd.makeComputeCommandEncoder() else { return }

        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        var u = MetalShaders.LocalToneUniforms(highlights: hi, shadows: sh, whites: wh, blacks: bl, offsetX: ox, offsetY: oy)
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(coeffTex, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.LocalToneUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage, highlights: Double, shadows: Double, whites: Double, blacks: Double, refScale: CGFloat) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite,
              abs(highlights) > 0.01 || abs(shadows) > 0.01 || abs(whites) > 0.01 || abs(blacks) > 0.01 else { return image }
        let args: [String: Any] = [
            "highlights": NSNumber(value: Float(highlights / 100.0)),
            "shadows": NSNumber(value: Float(shadows / 100.0)),
            "whites": NSNumber(value: Float(whites / 100.0)),
            "blacks": NSNumber(value: Float(blacks / 100.0)),
            "radius": NSNumber(value: Double(max(6, 26 * refScale))),
            "extent": MetalEngine.extentArgs(e)
        ]
        return (try? apply(withExtent: e, inputs: [image.cropped(to: e)], arguments: args)) ?? image
    }
}

// MARK: - 4. 暗通道去朦胧
final class MetalDehazeKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        MetalEngine.expandedROI(outputRect: outputRect, arguments: arguments, radiusKeys: ["radius"])
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("dehaze_apply") else { return }

        let amt = (arguments?["amount"] as? NSNumber)?.floatValue ?? 0
        let radius = CGFloat((arguments?["radius"] as? NSNumber)?.doubleValue ?? 24)
        guard let coeffTex = GuidedFilterPass.encodeCoefficients(
            cmd: cmd, guideTex: inTex, targetTex: nil, packKernel: "gf_pack_darkchannel",
            fullWidth: inTex.width, fullHeight: inTex.height, radius: radius, eps: 0.004, selfGuided: true),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        var u = MetalShaders.DehazeUniforms(amount: amt, offsetX: ox, offsetY: oy)
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(coeffTex, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.DehazeUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage, amount: Double, refScale: CGFloat) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite, abs(amount) > 0.01 else { return image }
        let args: [String: Any] = [
            "amount": NSNumber(value: Float(amount / 100.0)),
            "radius": NSNumber(value: Double(max(8, 28 * refScale))),
            "extent": MetalEngine.extentArgs(e)
        ]
        return (try? apply(withExtent: e, inputs: [image.cropped(to: e)], arguments: args)) ?? image
    }
}

// MARK: - 5. 保边清晰度与纹理
final class MetalEdgeDetailKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        MetalEngine.expandedROI(outputRect: outputRect, arguments: arguments, radiusKeys: ["clarityRadius", "textureRadius"])
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("edge_detail_apply") else { return }

        let clarity = (arguments?["clarity"] as? NSNumber)?.floatValue ?? 0
        let texture = (arguments?["texture"] as? NSNumber)?.floatValue ?? 0
        let clarityR = CGFloat((arguments?["clarityRadius"] as? NSNumber)?.doubleValue ?? 22)
        let textureR = CGFloat((arguments?["textureRadius"] as? NSNumber)?.doubleValue ?? 3.5)

        let cCoeff = abs(clarity) > 1e-4 ? GuidedFilterPass.encodeCoefficients(
            cmd: cmd, guideTex: inTex, targetTex: nil, packKernel: "gf_pack",
            fullWidth: inTex.width, fullHeight: inTex.height, radius: clarityR, eps: 0.018, selfGuided: true) : inTex
        let tCoeff = abs(texture) > 1e-4 ? GuidedFilterPass.encodeCoefficients(
            cmd: cmd, guideTex: inTex, targetTex: nil, packKernel: "gf_pack",
            fullWidth: inTex.width, fullHeight: inTex.height, radius: textureR, eps: 0.008, selfGuided: true) : inTex

        guard let cCoeff, let tCoeff, let enc = cmd.makeComputeCommandEncoder() else { return }
        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        var u = MetalShaders.EdgeDetailUniforms(clarity: clarity, texture: texture, offsetX: ox, offsetY: oy)
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(cCoeff, index: 1)
        enc.setTexture(tCoeff, index: 2)
        enc.setTexture(outTex, index: 3)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.EdgeDetailUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage, clarity: Double, texture: Double, refScale: CGFloat) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite,
              abs(clarity) > 0.01 || abs(texture) > 0.01 else { return image }
        let args: [String: Any] = [
            "clarity": NSNumber(value: Float(clarity / 100.0)),
            "texture": NSNumber(value: Float(texture / 100.0)),
            "clarityRadius": NSNumber(value: Double(max(6, 22.0 * refScale))),
            "textureRadius": NSNumber(value: Double(max(1.5, 3.5 * refScale))),
            "extent": MetalEngine.extentArgs(e)
        ]
        return (try? apply(withExtent: e, inputs: [image.cropped(to: e)], arguments: args)) ?? image
    }
}

// MARK: - 6. 5 通道浮点曲线 + Refine Sat + 颜色分级
final class MetalCurvesGradingKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let dev = MetalEngine.shared.device,
              let pApply = MetalEngine.shared.pipeline("curves_grading_apply"),
              let uData = arguments?["uniforms"] as? Data,
              let lutData = arguments?["luts"] as? Data,
              let lutBuf = lutData.withUnsafeBytes({ raw in
                  raw.baseAddress.flatMap { dev.makeBuffer(bytes: $0, length: lutData.count, options: .storageModeShared) }
              }),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        var u = uData.withUnsafeBytes { $0.load(as: MetalShaders.CurvesGradingUniforms.self) }
        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        u.offsetX = ox; u.offsetY = oy
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.CurvesGradingUniforms>.stride, index: 0)
        enc.setBuffer(lutBuf, offset: 0, index: 1)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    private static func gradeColor(_ g: ColorGrade) -> SIMD4<Float> {
        guard g.sat > 0 else { return SIMD4<Float>(0.5, 0.5, 0.5, 0) }
        let h = ((g.hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360.0
        let s = min(max(g.sat / 100.0, 0), 1)
        let l = 0.5
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let pp = 2 * l - q
        func hue2(_ t: Double) -> Double {
            var tt = t
            if tt < 0 { tt += 1 }
            if tt > 1 { tt -= 1 }
            if tt < 1.0 / 6 { return pp + (q - pp) * 6 * tt }
            if tt < 1.0 / 2 { return q }
            if tt < 2.0 / 3 { return pp + (q - pp) * (2.0 / 3 - tt) * 6 }
            return pp
        }
        return SIMD4<Float>(Float(hue2(h + 1.0 / 3)), Float(hue2(h)), Float(hue2(h - 1.0 / 3)), Float(s))
    }

    static func apply(_ image: CIImage, params p: EditParams) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite, CurveCube.needs(p) else { return image }
        let toneActive = !p.curve.isIdentity
        let lumaActive = !p.lumaCurve.isIdentity
        let rgbActive = !p.curveR.isIdentity || !p.curveG.isIdentity || !p.curveB.isIdentity
        let gradingActive = !p.gradeShadow.isNeutral || !p.gradeMid.isNeutral
            || !p.gradeHigh.isNeutral || p.calibShadowTint != 0 || p.gradeBlend != 50

        var luts = [Float](repeating: 0, count: 5 * 256)
        let curves = [p.curve, p.lumaCurve, p.curveR, p.curveG, p.curveB]
        for (ci, cv) in curves.enumerated() {
            let base = ci * 256
            for i in 0..<256 {
                luts[base + i] = Float(cv.value(at: Double(i) / 255.0))
            }
        }
        let u = MetalShaders.CurvesGradingUniforms(
            toneActive: toneActive ? 1 : 0,
            lumaActive: lumaActive ? 1 : 0,
            rgbCurveActive: rgbActive ? 1 : 0,
            refineSat: Float(min(max(p.refineSat / 100.0, 0), 1)),
            shadowRGB: gradeColor(p.gradeShadow),
            midRGB: gradeColor(p.gradeMid),
            highRGB: gradeColor(p.gradeHigh),
            shadowLum: Float(p.gradeShadow.lum / 100.0),
            midLum: Float(p.gradeMid.lum / 100.0),
            highLum: Float(p.gradeHigh.lum / 100.0),
            blendK: Float(min(max(p.gradeBlend / 50.0, 0), 2)),
            balance: Float(p.gradeBalance / 100.0 * 0.18),
            shadowTint: Float(p.calibShadowTint / 100.0),
            gradingActive: gradingActive ? 1 : 0,
            offsetX: 0, offsetY: 0
        )
        let uData = withUnsafeBytes(of: u) { Data($0) }
        let lutData = luts.withUnsafeBytes { Data($0) }
        return (try? apply(withExtent: e, inputs: [image], arguments: ["uniforms": uData, "luts": lutData])) ?? image
    }
}

// MARK: - 7. OKLCH 空间 HSL + Point Color
final class MetalOKLCHColorKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("oklch_color_apply"),
              let uData = arguments?["uniforms"] as? Data,
              let ptData = arguments?["points"] as? Data,
              let enc = cmd.makeComputeCommandEncoder() else { return }

        var u = uData.withUnsafeBytes { $0.load(as: MetalShaders.OKLCHColorUniforms.self) }
        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        u.offsetX = ox; u.offsetY = oy
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.OKLCHColorUniforms>.stride, index: 0)
        ptData.withUnsafeBytes { raw in
            if let base = raw.baseAddress, ptData.count > 0 {
                enc.setBytes(base, length: ptData.count, index: 1)
            } else {
                var dummy = MetalShaders.PointColorUniform(targetLCH: .zero, shiftLCH: .zero, rangeLCH: .zero)
                enc.setBytes(&dummy, length: MemoryLayout<MetalShaders.PointColorUniform>.stride, index: 1)
            }
        }
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func linearSRGBToOKLCH(_ rgb: [Double]) -> (L: Double, C: Double, h: Double) {
        func toLin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = toLin(rgb.count > 0 ? rgb[0] : 0.5)
        let g = toLin(rgb.count > 1 ? rgb[1] : 0.5)
        let b = toLin(rgb.count > 2 ? rgb[2] : 0.5)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(max(l, 0)), m_ = cbrt(max(m, 0)), s_ = cbrt(max(s, 0))
        let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        return (L, hypot(A, B), atan2(B, A))
    }

    static func apply(_ image: CIImage, hsl: HSLMix, pointColors: [PointColorSwatch], localHueShift: Double = 0) -> CIImage {
        let e = image.extent
        let activePts = Array(pointColors.filter { !$0.isNeutral }.prefix(16))
        let hslActive = !hsl.isNeutral
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite,
              hslActive || !activePts.isEmpty || abs(localHueShift) > 1e-4 else { return image }

        let bands = [hsl.red, hsl.orange, hsl.yellow, hsl.green, hsl.aqua, hsl.blue, hsl.purple, hsl.magenta]
        let u = MetalShaders.OKLCHColorUniforms(
            bandHue: SIMD4<Float>(Float(bands[0].hue), Float(bands[1].hue), Float(bands[2].hue), Float(bands[3].hue)),
            bandHue2: SIMD4<Float>(Float(bands[4].hue), Float(bands[5].hue), Float(bands[6].hue), Float(bands[7].hue)),
            bandSat: SIMD4<Float>(Float(bands[0].sat / 100), Float(bands[1].sat / 100), Float(bands[2].sat / 100), Float(bands[3].sat / 100)),
            bandSat2: SIMD4<Float>(Float(bands[4].sat / 100), Float(bands[5].sat / 100), Float(bands[6].sat / 100), Float(bands[7].sat / 100)),
            bandLum: SIMD4<Float>(Float(bands[0].lum / 100), Float(bands[1].lum / 100), Float(bands[2].lum / 100), Float(bands[3].lum / 100)),
            bandLum2: SIMD4<Float>(Float(bands[4].lum / 100), Float(bands[5].lum / 100), Float(bands[6].lum / 100), Float(bands[7].lum / 100)),
            hslActive: hslActive ? 1 : 0,
            pointCount: Int32(activePts.count),
            localHueShift: Float(localHueShift),
            offsetX: 0, offsetY: 0
        )
        let ptUniforms: [MetalShaders.PointColorUniform] = activePts.map { sw in
            let lch = linearSRGBToOKLCH(sw.sampleRGB)
            return MetalShaders.PointColorUniform(
                targetLCH: SIMD4<Float>(Float(lch.L), Float(lch.C), Float(lch.h), 1),
                shiftLCH: SIMD4<Float>(Float(sw.lumaShift / 100), Float(sw.chromaShift / 100), Float(sw.hueShift * .pi / 180), 0),
                rangeLCH: SIMD4<Float>(Float(sw.lumaRange), Float(sw.chromaRange), Float(sw.hueRange), Float(sw.range))
            )
        }
        let uData = withUnsafeBytes(of: u) { Data($0) }
        let ptData = ptUniforms.withUnsafeBytes { Data($0) }
        return (try? apply(withExtent: e, inputs: [image], arguments: ["uniforms": uData, "points": ptData])) ?? image
    }
}

// MARK: - 8. 分辨率无关物理银盐颗粒
final class MetalFilmGrainKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("film_grain_apply"),
              let uData = arguments?["uniforms"] as? Data,
              let enc = cmd.makeComputeCommandEncoder() else { return }

        var u = uData.withUnsafeBytes { $0.load(as: MetalShaders.FilmGrainUniforms.self) }
        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        u.offsetX = ox; u.offsetY = oy
        u.outOriginX = Int32(output.region.minX.rounded())
        u.outOriginY = Int32(output.region.minY.rounded())
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.FilmGrainUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage, amount: Double, size: Double, roughness: Double) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite, amount > 0.01 else { return image }
        let u = MetalShaders.FilmGrainUniforms(
            amount: Float(min(max(amount / 100, 0), 1)),
            size: Float(min(max(size, 0), 1)),
            roughness: Float(min(max(roughness, 0), 1)),
            aspect: Float(e.width / max(e.height, 1)),
            fullWidth: Float(e.width),
            fullHeight: Float(e.height),
            outOriginX: 0, outOriginY: 0, offsetX: 0, offsetY: 0
        )
        let uData = withUnsafeBytes(of: u) { Data($0) }
        return (try? apply(withExtent: e, inputs: [image], arguments: ["uniforms": uData])) ?? image
    }
}

// MARK: - 9. Guided Filter 边缘精修 / 布尔蒙版组合 / 溢出提示
final class MetalMaskRefineKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        MetalEngine.expandedROI(outputRect: outputRect, arguments: arguments, radiusKeys: ["radius"])
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count >= 2,
              let guideIn = inputs[0].metalTexture,
              let maskIn = inputs[1].metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("gf_apply_mask") else { return }

        let radius = CGFloat((arguments?["radius"] as? NSNumber)?.doubleValue ?? 8)
        let eps = (arguments?["eps"] as? NSNumber)?.floatValue ?? 0.002
        guard let coeffTex = GuidedFilterPass.encodeCoefficients(
            cmd: cmd, guideTex: guideIn, targetTex: maskIn, packKernel: "gf_pack",
            fullWidth: guideIn.width, fullHeight: guideIn.height, radius: radius, eps: eps, selfGuided: false),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let (ox, oy) = MetalEngine.textureOffset(inputRegion: inputs[0].region, outputRegion: output.region)
        var offset = SIMD2<Int32>(ox, oy)
        enc.setComputePipelineState(pApply)
        enc.setTexture(guideIn, index: 0)
        enc.setTexture(coeffTex, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&offset, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func refine(mask: CIImage, guide: CIImage, radius: CGFloat, eps: Float = 0.0015) -> CIImage {
        let e = guide.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite else { return mask }
        let args: [String: Any] = [
            "radius": NSNumber(value: Double(max(2, radius))),
            "eps": NSNumber(value: eps),
            "extent": MetalEngine.extentArgs(e)
        ]
        return (try? apply(withExtent: e, inputs: [guide.cropped(to: e), mask.cropped(to: e)], arguments: args)) ?? mask
    }
}

final class MetalMaskBooleanKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count >= 2,
              let baseTex = inputs[0].metalTexture,
              let subTex = inputs[1].metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("mask_boolean_combine"),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let mode = (arguments?["mode"] as? NSNumber)?.int32Value ?? 0
        let (ox0, oy0) = MetalEngine.textureOffset(inputRegion: inputs[0].region, outputRegion: output.region)
        let (ox1, oy1) = MetalEngine.textureOffset(inputRegion: inputs[1].region, outputRegion: output.region)
        var u = MetalShaders.BoolMaskUniforms(mode: mode, offsetX: ox0, offsetY: oy0, subOffsetX: ox1, subOffsetY: oy1)
        enc.setComputePipelineState(pApply)
        enc.setTexture(baseTex, index: 0)
        enc.setTexture(subTex, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.BoolMaskUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func combine(base: CIImage, sub: CIImage, op: MaskBoolOp, extent: CGRect) -> CIImage {
        guard MetalEngine.shared.isAvailable, !extent.isEmpty, !extent.isInfinite else { return base }
        let mode: Int32 = op == .add ? 0 : op == .subtract ? 1 : 2
        return (try? apply(withExtent: extent, inputs: [base.cropped(to: extent), sub.cropped(to: extent)],
                           arguments: ["mode": NSNumber(value: mode)])) ?? base
    }
}

final class MetalClippingOverlayKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("clipping_overlay"),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        var offset = SIMD2<Int32>(ox, oy)
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setBytes(&offset, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite else { return image }
        return (try? apply(withExtent: e, inputs: [image], arguments: nil)) ?? image
    }
}

final class MetalOpticalBokehKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let maxR = (arguments?["maxRadiusPx"] as? NSNumber)?.doubleValue ?? 0
        let pad = input == 0 || input == 1 ? CGFloat(ceil(min(max(maxR, 0), 120)) + 2) : 0
        let grown = pad > 0 ? outputRect.insetBy(dx: -pad, dy: -pad) : outputRect
        if let arr = arguments?["extent"] as? [Double], arr.count == 4 {
            let full = CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
            let clamped = grown.intersection(full)
            return clamped.isEmpty ? outputRect.intersection(full) : clamped
        }
        return grown
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count >= 2,
              let srcTex = inputs[0].metalTexture,
              let depTex = inputs[1].metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("bokeh_optical_apply"),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let (ox0, oy0) = MetalEngine.textureOffset(inputRegion: inputs[0].region, outputRegion: output.region)
        let (dx0, dy0) = MetalEngine.textureOffset(inputRegion: inputs[1].region, outputRegion: output.region)
        let arr = (arguments?["extent"] as? [Double]) ?? [0, 0, Double(outTex.width), Double(outTex.height)]
        var u = MetalShaders.OpticalBokehUniforms(
            maxRadiusPx: Float((arguments?["maxRadiusPx"] as? NSNumber)?.doubleValue ?? 18),
            focusDepth: Float((arguments?["focusDepth"] as? NSNumber)?.doubleValue ?? 0.12),
            focusRange: Float((arguments?["focusRange"] as? NSNumber)?.doubleValue ?? 0.20),
            blades: Int32((arguments?["blades"] as? NSNumber)?.intValue ?? 0),
            highlightBoost: Float(((arguments?["highlightBoost"] as? NSNumber)?.doubleValue ?? 35) / 100.0),
            catEye: Float(((arguments?["catEye"] as? NSNumber)?.doubleValue ?? 20) / 100.0),
            fullWidth: Float(arr.count == 4 ? max(arr[2], 1) : Double(outTex.width)),
            fullHeight: Float(arr.count == 4 ? max(arr[3], 1) : Double(outTex.height)),
            outOriginX: Float(output.region.minX - (arr.count == 4 ? arr[0] : 0)),
            outOriginY: Float((arr.count == 4 ? (arr[1] + arr[3]) : Double(outTex.height)) - output.region.maxY),
            offsetX: ox0,
            offsetY: oy0,
            depthOffsetX: dx0,
            depthOffsetY: dy0
        )
        enc.setComputePipelineState(pApply)
        enc.setTexture(srcTex, index: 0)
        enc.setTexture(depTex, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.OpticalBokehUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage, depthMask: CIImage, maxRadiusPx: Double,
                      focusDepth: Double, focusRange: Double, blades: Int,
                      highlightBoost: Double, catEye: Double) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite else { return image }
        let args: [String: Any] = [
            "maxRadiusPx": NSNumber(value: min(max(maxRadiusPx, 0), 120)),
            "focusDepth": NSNumber(value: min(max(focusDepth, 0), 1)),
            "focusRange": NSNumber(value: min(max(focusRange, 0.02), 0.6)),
            "blades": NSNumber(value: blades),
            "highlightBoost": NSNumber(value: min(max(highlightBoost, 0), 100)),
            "catEye": NSNumber(value: min(max(catEye, 0), 100)),
            "extent": MetalEngine.extentArgs(e)
        ]
        return (try? apply(withExtent: e, inputs: [image.cropped(to: e), depthMask.cropped(to: e)], arguments: args)) ?? image
    }
}

final class MetalDepthVisualizeKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count >= 2,
              let srcTex = inputs[0].metalTexture,
              let depTex = inputs[1].metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("depth_visualize_overlay"),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let (ox0, oy0) = MetalEngine.textureOffset(inputRegion: inputs[0].region, outputRegion: output.region)
        let (dx0, dy0) = MetalEngine.textureOffset(inputRegion: inputs[1].region, outputRegion: output.region)
        var u = MetalShaders.DepthVisUniforms(
            focusDepth: Float((arguments?["focusDepth"] as? NSNumber)?.doubleValue ?? 0.12),
            focusRange: Float((arguments?["focusRange"] as? NSNumber)?.doubleValue ?? 0.20),
            offsetX: ox0,
            offsetY: oy0,
            depthOffsetX: dx0,
            depthOffsetY: dy0
        )
        enc.setComputePipelineState(pApply)
        enc.setTexture(srcTex, index: 0)
        enc.setTexture(depTex, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.DepthVisUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage, depthMask: CIImage, focusDepth: Double, focusRange: Double) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite else { return image }
        let args: [String: Any] = [
            "focusDepth": NSNumber(value: min(max(focusDepth, 0), 1)),
            "focusRange": NSNumber(value: min(max(focusRange, 0.02), 0.6))
        ]
        return (try? apply(withExtent: e, inputs: [image.cropped(to: e), depthMask.cropped(to: e)], arguments: args)) ?? image
    }
}

final class MetalRawDenoiseKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let step = (arguments?["stepPx"] as? NSNumber)?.doubleValue ?? 1.0
        let pad = CGFloat(ceil(max(1.0, step) * 2.5) + 1)
        let grown = outputRect.insetBy(dx: -pad, dy: -pad)
        if let arr = arguments?["extent"] as? [Double], arr.count == 4 {
            let full = CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
            let clamped = grown.intersection(full)
            return clamped.isEmpty ? outputRect.intersection(full) : clamped
        }
        return grown
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("raw_denoise_apply"),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        let amount = Float((arguments?["amount"] as? NSNumber)?.doubleValue ?? 0.5)
        let detail = Float((arguments?["detail"] as? NSNumber)?.doubleValue ?? 0.5)
        let chromaOnly = (arguments?["chromaOnly"] as? NSNumber)?.boolValue == true
        let stepPx = Float((arguments?["stepPx"] as? NSNumber)?.doubleValue ?? 1.0)
        var u = MetalShaders.RawDenoiseUniforms(
            amount: amount,
            detail: detail,
            lumaSigma: 0.04 + 0.16 * amount * (1.0 - detail * 0.55),
            chromaSigma: 0.04 + 0.24 * amount,
            chromaOnly: chromaOnly ? 1 : 0,
            stepPx: stepPx,
            offsetX: ox,
            offsetY: oy
        )
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.RawDenoiseUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage, amount: Double, detail: Double,
                      chromaOnly: Bool = false, refScale: CGFloat = 1.0) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite, amount > 0 else { return image }
        let stepPx = min(max(Double(refScale), 1.0), 3.0)
        let args: [String: Any] = [
            "amount": NSNumber(value: min(max(amount / 100.0, 0), 1)),
            "detail": NSNumber(value: min(max(detail / 100.0, 0), 1)),
            "chromaOnly": NSNumber(value: chromaOnly),
            "stepPx": NSNumber(value: stepPx),
            "extent": MetalEngine.extentArgs(e)
        ]
        return (try? apply(withExtent: e, inputs: [image.cropped(to: e)], arguments: args)) ?? image
    }
}

final class MetalSuperResKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let grown = outputRect.insetBy(dx: -2, dy: -2)
        if let arr = arguments?["extent"] as? [Double], arr.count == 4 {
            let full = CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
            let clamped = grown.intersection(full)
            return clamped.isEmpty ? outputRect.intersection(full) : clamped
        }
        return grown
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first,
              let inTex = input.metalTexture,
              let outTex = output.metalTexture,
              let cmd = output.metalCommandBuffer,
              let pApply = MetalEngine.shared.pipeline("super_res_enhance"),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let (ox, oy) = MetalEngine.textureOffset(inputRegion: input.region, outputRegion: output.region)
        var u = MetalShaders.SuperResUniforms(
            sharpen: Float((arguments?["sharpen"] as? NSNumber)?.doubleValue ?? 0.55),
            edgePreserve: Float((arguments?["edgePreserve"] as? NSNumber)?.doubleValue ?? 0.85),
            offsetX: ox,
            offsetY: oy
        )
        enc.setComputePipelineState(pApply)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setBytes(&u, length: MemoryLayout<MetalShaders.SuperResUniforms>.stride, index: 0)
        MetalEngine.dispatch2D(enc, pipeline: pApply, width: outTex.width, height: outTex.height)
        enc.endEncoding()
    }

    static func apply(_ image: CIImage, sharpen: Double = 0.55, edgePreserve: Double = 0.85) -> CIImage {
        let e = image.extent
        guard MetalEngine.shared.isAvailable, !e.isEmpty, !e.isInfinite else { return image }
        let args: [String: Any] = [
            "sharpen": NSNumber(value: sharpen),
            "edgePreserve": NSNumber(value: edgePreserve),
            "extent": MetalEngine.extentArgs(e)
        ]
        return (try? apply(withExtent: e, inputs: [image.cropped(to: e)], arguments: args)) ?? image
    }
}
