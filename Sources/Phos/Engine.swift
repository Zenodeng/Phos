import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreVideo
import simd
import AppKit

enum Engine {

    // 固定的处理上下文。CIContext 一定要复用，别每次新建 —— 这是性能关键。
    static let ctx: CIContext = {
        let opts: [CIContextOption: Any] = [.cacheIntermediates: false,
                                            .allowLowPower: false]
        return CIContext(options: opts)
    }()

    static let srgb: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 「对比」数值 → CIColorControls 对比系数：`1 + 数值 / contrastScale`。
    /// 数值 ±100 对应 1 ± 100/contrastScale。调大 = 同一数值下画面更柔。
    /// 2026-10-08 由 200 收到 260（反馈：对比度容易调得太猛）。
    /// 注意：改这个会让已存旁档的观感变化，渲染回归的 tone 基准需要重烤。
    static let contrastScale = 260.0

    // MARK: - 解码
    static let rawSet: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "orf", "rw2",
                                      "dng", "pef", "erf", "sr2", "srf"]
    /// 浏览器里会出现的格式。RAW 之外全部交给 ImageIO，HEIF / AVIF / JPEG / PNG / TIFF 都能吃。
    static let browseSet: Set<String> = rawSet.union(["jpg", "jpeg", "jpe", "jfif", "png",
                                                      "tif", "tiff", "heic", "heif", "hif", "avif"])

    static func decode(_ url: URL) -> CIImage? {
        let ext = url.pathExtension.lowercased()
        if rawSet.contains(ext) {
            if let raw = CIRAWFilter(imageURL: url) {
                raw.isGamutMappingEnabled = true
                raw.scaleFactor = 1.0
                if let o = raw.outputImage { return o }
            }
            // RAW 解码失败就退回 ImageIO
        }
        // 必须带上 applyOrientationProperty：手机出的 JPEG / HEIC 方向写在 EXIF 里，
        // 不应用的话竖拍照片会躺倒（这个坑很常见）。
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    // MARK: - 主渲染
    static func geometry(_ source: CIImage, _ p: EditParams) -> CIImage {
        var img = source

        // 1) 翻转 / 90° 旋转
        if p.flipped || p.rotation != 0 {
            var t = CGAffineTransform.identity
            let e = img.extent
            if p.flipped { t = t.translatedBy(x: e.width, y: 0).scaledBy(x: -1, y: 1) }
            if p.rotation == 90 {
                t = t.translatedBy(x: e.height, y: 0).rotated(by: .pi / 2)
            } else if p.rotation == 180 {
                t = t.translatedBy(x: e.width, y: e.height).rotated(by: .pi)
            } else if p.rotation == 270 {
                t = t.translatedBy(x: 0, y: e.width).rotated(by: -.pi / 2)
            }
            img = img.transformed(by: t)
        }

        // 1b) 透视校正（自动：Vision 矩形检测；手动：垂直/水平滑块构四边形）
        if p.perspectiveAuto {
            if let quad = autoPerspectiveQuad(from: img) {
                img = applyPerspective(img, quad)
            }
        } else if p.perspectiveV != 0 || p.perspectiveH != 0 {
            img = applyPerspective(img, manualPerspectiveQuad(extent: img.extent,
                                                              vertical: p.perspectiveV,
                                                              horizontal: p.perspectiveH))
        }

        // 2) 水平矫正 + 裁剪（先定画框，后面所有调整都在框内）
        if p.straighten != 0 {
            let e = img.extent
            let a = CGFloat(p.straighten) * .pi / 180
            let cx = e.midX, cy = e.midY
            var t = CGAffineTransform(translationX: cx, y: cy)
            t = t.rotated(by: a)
            t = t.translatedBy(x: -cx, y: -cy)
            img = img.transformed(by: t)
        }
        if p.cropW < 0.999 || p.cropH < 0.999 || p.cropX > 0.001 || p.cropY > 0.001 {
            let e = img.extent
            var r = CGRect(x: e.minX + e.width * p.cropX,
                           y: e.minY + e.height * p.cropY,
                           width: e.width * p.cropW,
                           height: e.height * p.cropH)
            r = r.integral
            if !r.isEmpty { img = img.cropped(to: r) }
        }

        return img
    }

    static func render(_ source: CIImage, _ p: EditParams, disparityMask: CIImage? = nil,
                       selectedMask: UUID? = nil, maskPreview: ((CIImage) -> Void)? = nil) -> CIImage {
        var img = geometry(source, p)
        let gains = p.whiteBalanceGains
        if gains.count == 3, gains != [1, 1, 1], gains.allSatisfy({ $0.isFinite && $0 > 0 }) {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gains[0], y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gains[1], z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gains[2], w: 0)
            ])
        }
        // 2b) 镜头校正：横向色差（R/B 通道反向微缩放）与紫边抑制
        if p.caAmount != 0 { img = correctLateralCA(img, amount: p.caAmount) }
        if p.purpleFringe > 0 { img = defringePurple(img, strength: p.purpleFringe) }

        // 3) 白平衡
        if p.temperature != 0 || p.tint != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(6500 - p.temperature * 25),
                                               y: CGFloat(p.tint))
            ])
        }

        // 3b) 校准：改 RGB 三原色的原色（等价于换一套 RGB 基），放最前面定风格基调
        if !p.primRed.isNeutral || !p.primGreen.isNeutral || !p.primBlue.isNeutral {
            let m = Calibration.matrix(red: p.primRed, green: p.primGreen, blue: p.primBlue)
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
                "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
                "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }

        // 4) 曝光 / 对比 / 饱和
        if p.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: NSNumber(value: p.exposure)])
        }
        if p.contrast != 0 || p.saturation != 0 || p.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": NSNumber(value: p.vibrance / 100)])
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: NSNumber(value: 1 + p.contrast / contrastScale),
                kCIInputSaturationKey: NSNumber(value: 1 + p.saturation / 200)
            ])
        }

        // 4b) 去朦胧：本质是「去掉一层灰雾」—— 提对比 + 压低黑场，用矩阵一次做完
        //     正值为去雾，负值反向加雾（做空气感）
        if p.dehaze != 0 {
            let a = p.dehaze / 100
            // 别太狠：实测 +60 用 0.45/-0.085 会压出 27% 死黑，收着点
            let s = 1 + a * 0.22
            let bias = -a * 0.018
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ])
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: NSNumber(value: 1 + a * 0.16),
                kCIInputSaturationKey: NSNumber(value: 1 + max(a, 0) * 0.30)
            ])
        }

        // 4c) HDR：把高光压回来、暗部抬起来（CI 的高光/阴影恢复），Limit 控制压缩量
        if p.hdrMode {
            let amt = p.hdrLimit / 100
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": NSNumber(value: 1 - amt),
                "inputShadowAmount": NSNumber(value: amt * 0.8 - 0.1)
            ])
        }

        // 5) 高光/阴影/白/黑（纯色调滑块；用户曲线改由下面那条 LUT 管线处理）
        if p.blacks != 0 || p.shadows != 0 || p.highlights != 0 || p.whites != 0 {
            let xs: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
            var ys: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
            ys[0] += CGFloat(p.blacks / 100) * 0.10
            ys[1] += CGFloat(p.shadows / 100) * 0.10
            ys[3] += CGFloat(p.highlights / 100) * 0.10
            ys[4] += CGFloat(p.whites / 100) * 0.10
            for i in 0..<5 { ys[i] = min(max(ys[i], 0), 1) }
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: xs[0], y: ys[0]),
                "inputPoint1": CIVector(x: xs[1], y: ys[1]),
                "inputPoint2": CIVector(x: xs[2], y: ys[2]),
                "inputPoint3": CIVector(x: xs[3], y: ys[3]),
                "inputPoint4": CIVector(x: xs[4], y: ys[4])
            ])
        }

        // 5b) 色调曲线 + 亮度曲线 + 单独 RGB 通道曲线（一起烘进一张 3D LUT，避免多次采样损失）
        if let f = CurveCube.filter(p) {
            f.setValue(img, forKey: kCIInputImageKey)
            if let o = f.outputImage { img = o }
        }

        // 6) HSL
        if !p.hsl.isNeutral, let f = HSLCube.filter(p.hsl) {
            f.setValue(img, forKey: kCIInputImageKey)
            if let o = f.outputImage { img = o }
        }

        // 7) 黑白
        if p.mono {
            let wr = CGFloat(p.monoRed), wg = CGFloat(p.monoGreen), wb = CGFloat(p.monoBlue)
            let s = wr + wg + wb > 0 ? (wr + wg + wb) : 1
            let r = wr / s, g = wg / s, b = wb / s
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: g, z: b, w: 0),
                "inputGVector": CIVector(x: r, y: g, z: b, w: 0),
                "inputBVector": CIVector(x: r, y: g, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }

        // 8) 胶片 CLUT
        //    LUT（HALD/.cube）是感知域数据（sRGB/Rec709 编码），而管线里流动的是线性值。
        //    进 LUT 前先编码到 sRGB 感知域、出来再解回线性（同 CurveCube 的处理），
        //    否则索引和输出两头都错域：黑场被抬到 ~18% 灰，整段灰阶压扁——观感就是「灰片」。
        if let f = CLUTLibrary.shared.cubeFilter(name: p.clutName, strength: p.clutStrength) {
            f.setValue(img.applyingFilter("CILinearToSRGBToneCurve"), forKey: kCIInputImageKey)
            if let o = f.outputImage {
                img = o.applyingFilter("CISRGBToneCurveToLinear")
            }
        }

        // 9) 清晰度（大半径中频，做立体感）
        if p.clarity != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: NSNumber(value: 22),
                kCIInputIntensityKey: NSNumber(value: p.clarity / 100)
            ])
        }

        // 9b) 纹理（比清晰度更细一档的中频，管皮肤/材质的颗粒感）
        if p.texture != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: NSNumber(value: 3.5),
                kCIInputIntensityKey: NSNumber(value: p.texture / 100)
            ])
        }

        // 10) 降噪与锐化
        if p.denoiseColor > 0 {
            // 颜色降噪：中值滤波 + 按强度混合，去彩色噪点而基本不动亮度结构
            if let f = CIFilter(name: "CIDissolveTransition") {
                f.setValue(img, forKey: "inputImage")
                f.setValue(img.applyingFilter("CIMedianFilter"), forKey: "inputTargetImage")
                f.setValue(NSNumber(value: min(p.denoiseColor / 100, 1)), forKey: "inputTime")
                if let o = f.outputImage?.cropped(to: img.extent) { img = o }
            }
        }
        if p.denoise > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": NSNumber(value: p.denoise / 100 * 0.1),
                "inputSharpness": NSNumber(value: 0.4)
            ])
        }
        // 锐化：数量 / 半径 / 细节 / 蒙版 四个滑块
        // 细节 = 粗细两档混合（0 只做粗半径，1 全给细半径）
        // 蒙版 = 用边缘图限制锐化只落在边上，平区不放噪点
        if p.sharpen > 0 {
            let detail = min(max(p.sharpenDetail, 0), 1)
            var sharp = img
            if detail < 0.999 {
                sharp = sharp.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: NSNumber(value: max(p.sharpenRadius, 0.3)),
                    kCIInputIntensityKey: NSNumber(value: p.sharpen * (1 - detail))
                ])
            }
            if detail > 0.001 {
                sharp = sharp.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: NSNumber(value: 0.6),
                    kCIInputIntensityKey: NSNumber(value: p.sharpen * detail)
                ])
            }
            if p.sharpenMask > 0 {
                // 边缘图 → 只让边缘参与锐化；蒙版量越大，参与的区域越窄（只剩强边缘）
                // 高通掩膜：原图 - 模糊 = 只留细节。比 CIEdges 稳，量级也好控
                let blurred = img.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: NSNumber(value: 1.6)
                ])
                var edges = img.applyingFilter("CIDifferenceBlendMode", parameters: [
                    kCIInputBackgroundImageKey: blurred
                ])
                // CIEdges 出来的边缘很暗（实测均值 5/255）且不写 alpha，直接当掩膜会把
                // 锐化全挡掉。先 gamma 把边缘拉起来（蒙版量越大 → 指数越大 → 只留强边缘），
                // 再把强度同时写进 RGB 和 alpha，不管混合模式看哪个通道都生效
                // 指数越大 → 弱边缘被压得越狠 → 只有强边缘还留下（扫参得来的区间）
                edges = edges.applyingFilter("CIGammaAdjust", parameters: [
                    "inputPower": NSNumber(value: 0.45 + p.sharpenMask / 100 * 0.15)
                ])
                // 高通差分量级很小，必须放大（实测：增益 10 + 指数 0.5 时锐区保留 ~75%、平区几乎不动）
                let g = 10.0
                edges = edges.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.2126 * g, y: 0.7152 * g, z: 0.0722 * g, w: 0),
                    "inputGVector": CIVector(x: 0.2126 * g, y: 0.7152 * g, z: 0.0722 * g, w: 0),
                    "inputBVector": CIVector(x: 0.2126 * g, y: 0.7152 * g, z: 0.0722 * g, w: 0),
                    "inputAVector": CIVector(x: 0.2126 * g, y: 0.7152 * g, z: 0.0722 * g, w: 0)
                ])
                let masked = sharp.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: img,
                    kCIInputMaskImageKey: edges.cropped(to: img.extent)
                ])
                img = masked
            } else {
                img = sharp
            }
        }

        // 11) 暗角
        if p.vignette != 0 {
            let e = img.extent
            let r = max(e.width, e.height) * CGFloat(0.3 + p.vignetteStart * 0.7)
            img = img.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: NSNumber(value: p.vignette / 100 * 2.5),
                kCIInputRadiusKey: NSNumber(value: r)
            ])
        }

        // 11c) Halation 光晕：高光提取 → 大半径模糊 → 暖色染色 → 屏幕混合
        if p.halation > 0 {
            img = addHalation(img, amount: p.halation,
                              threshold: p.halationThreshold,
                              radiusFactor: p.halationRadius)
        }

        // 11d) 焦外散景：深度蒙版白色区域按半径可变模糊（CIMaskedVariableBlur 实测白=模糊）
        if p.bokehAmount > 0 {
            img = applyBokeh(img, p, disparityMask: disparityMask)
        }

        // 12) 颗粒
        if p.grain > 0 {
            img = addGrain(img, amount: p.grain, size: p.grainSize)
        }

        // 13) 蒙版
        if let mask = p.masks.first(where: { $0.id == selectedMask && $0.kind == .depth }),
           let image = maskImage(for: mask, extent: img.extent, analyzed: img) {
            maskPreview?(image)
        }
        img = applyMasks(img, p, selectedMask: selectedMask, maskPreview: maskPreview)

        return img
    }

    // MARK: - 颗粒
    private static func addGrain(_ img: CIImage, amount: Double, size: Double) -> CIImage {
        let e = img.extent
        guard let generator = CIFilter(name: "CIRandomGenerator"),
              let generated = generator.outputImage else { return img }
        var noise = generated.cropped(to: e)
        noise = noise.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: NSNumber(value: 0),
            kCIInputContrastKey: NSNumber(value: 0.5 + size * 2)
        ])
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: e)
        let alpha = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(amount / 100))).cropped(to: e)
        let mixed = noise.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: gray,
            kCIInputMaskImageKey: alpha
        ])
        return mixed.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
    }

    // MARK: - 蒙版
    private static func applyMasks(_ base: CIImage, _ p: EditParams,
                                   selectedMask: UUID?, maskPreview: ((CIImage) -> Void)?) -> CIImage {
        var out = base
        // depth 蒙版只喂散景，不做局部调整
        for m in p.masks where m.kind != .depth && (m.id == selectedMask || (m.enabled && !m.adjust.isNeutral)) {
            // Vision 蒙版要拿当前画面去跑模型（缓存按蒙版 id + 画幅尺寸）
            let maskImg = maskImage(for: m, extent: out.extent, analyzed: out)
            guard let maskImg else { continue }
            if m.id == selectedMask { maskPreview?(maskImg) }
            guard m.enabled, !m.adjust.isNeutral else { continue }
            var adj = out
            let a = m.adjust
            if a.exposure != 0 {
                adj = adj.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: NSNumber(value: a.exposure)])
            }
            if a.contrast != 0 || a.saturation != 0 {
                adj = adj.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: NSNumber(value: 1 + a.contrast / contrastScale),
                    kCIInputSaturationKey: NSNumber(value: 1 + a.saturation / 200)
                ])
            }
            if a.temperature != 0 || a.tint != 0 {
                adj = adj.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: CGFloat(6500 - a.temperature * 25), y: CGFloat(a.tint))
                ])
            }
            if a.dehaze != 0 {
                let amount = a.dehaze / 100
                let scale = 1 + amount * 0.22
                let bias = -amount * 0.018
                adj = adj.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
                ])
                adj = adj.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: NSNumber(value: 1 + amount * 0.16),
                    kCIInputSaturationKey: NSNumber(value: 1 + max(amount, 0) * 0.30)
                ])
            }
            if a.blacks != 0 || a.shadows != 0 || a.highlights != 0 || a.whites != 0 {
                let xs: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
                var ys: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
                ys[0] += CGFloat(a.blacks / 100) * 0.10
                ys[1] += CGFloat(a.shadows / 100) * 0.10
                ys[3] += CGFloat(a.highlights / 100) * 0.10
                ys[4] += CGFloat(a.whites / 100) * 0.10
                for i in 0..<5 { ys[i] = min(max(ys[i], 0), 1) }
                adj = adj.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: xs[0], y: ys[0]),
                    "inputPoint1": CIVector(x: xs[1], y: ys[1]),
                    "inputPoint2": CIVector(x: xs[2], y: ys[2]),
                    "inputPoint3": CIVector(x: xs[3], y: ys[3]),
                    "inputPoint4": CIVector(x: xs[4], y: ys[4])
                ])
            }
            if a.clarity != 0 {
                adj = adj.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: NSNumber(value: 22),
                    kCIInputIntensityKey: NSNumber(value: a.clarity / 100)
                ])
            }
            if a.texture != 0 {
                adj = adj.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: NSNumber(value: 3.5),
                    kCIInputIntensityKey: NSNumber(value: a.texture / 100)
                ])
            }
            if a.denoise > 0 {
                adj = adj.applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": NSNumber(value: a.denoise / 100 * 0.1),
                    "inputSharpness": NSNumber(value: 0.4)
                ])
            }
            if a.sharpen != 0 {
                adj = adj.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: NSNumber(value: 1.2),
                    kCIInputIntensityKey: NSNumber(value: a.sharpen / 100)
                ])
            }
            out = adj.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out,
                kCIInputMaskImageKey: maskImg
            ])
        }
        return out
    }

    /// 用颜色立方体给画面每个像素算权重 → 蒙版。
    /// 权重同时写进 RGB 和 alpha，省得纠结混合模式到底看哪个通道。
    private static func cubeWeight(_ data: Data, appliedTo src: CIImage, extent: CGRect) -> CIImage {
        guard let f = CIFilter(name: "CIColorCube") else { return CIImage(color: .black).cropped(to: extent) }
        f.setValue(RangeCube.dim, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        f.setValue(src, forKey: kCIInputImageKey)
        guard let o = f.outputImage else { return CIImage(color: .black).cropped(to: extent) }
        let w = o.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            "inputGVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            "inputBVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0)
        ])
        return w.cropped(to: extent)
    }

    static func maskImage(for m: Mask, extent: CGRect, analyzed: CIImage? = nil) -> CIImage? {
        let w = extent.width, h = extent.height
        var img: CIImage
        switch m.kind {
        case .linear:
            let p0 = CIVector(x: extent.minX + w * m.x0, y: extent.minY + h * m.y0)
            let p1 = CIVector(x: extent.minX + w * m.x1, y: extent.minY + h * m.y1)
            guard let gradient = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": p0, "inputPoint1": p1,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black
            ]), let output = gradient.outputImage else { return nil }
            img = output.cropped(to: extent)
        case .radial:
            if m.gradientVersion == 1 {
                guard !extent.isNull, !extent.isInfinite,
                      extent.minX.isFinite, extent.minY.isFinite,
                      extent.maxX.isFinite, extent.maxY.isFinite,
                      w.isFinite, h.isFinite, w > 0, h > 0,
                      m.x0.isFinite, m.y0.isFinite else { return nil }
                let cx = extent.minX + w * m.x0
                let cy = extent.minY + h * m.y0
                let radiusBase = min(w, h)
                let fallbackRadius = m.radius.isFinite ? min(max(m.radius, 0.003), 4) : 0.3
                let radiusX = m.radiusX ?? fallbackRadius
                let radiusY = m.radiusY ?? fallbackRadius
                let rx = radiusX.isFinite ? min(max(radiusX, 0.003), 4) : fallbackRadius
                let ry = radiusY.isFinite ? min(max(radiusY, 0.003), 4) : fallbackRadius
                guard cx.isFinite, cy.isFinite,
                      (radiusBase * rx).isFinite, (radiusBase * ry).isFinite else { return nil }
                let feather = m.feather.isFinite ? min(max(m.feather, 0), 1) : 0.6
                let angle = m.radialAngle.isFinite ? m.radialAngle.truncatingRemainder(dividingBy: 360) : 0
                // 局部圆的外边界固定，羽化只向内延伸；再缩放为椭圆并按图像坐标旋转。
                guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: 0, y: 0),
                    "inputRadius0": NSNumber(value: feather == 0 ? 0 : radiusBase * (1 - feather)),
                    "inputRadius1": NSNumber(value: feather == 0 ? radiusBase * 2 : radiusBase),
                    "inputColor0": CIColor.white, "inputColor1": CIColor.black
                ]), let output = gradient.outputImage else { return nil }
                // 零羽化用阈值构造硬边，避免两个渐变半径相等时的退化计算。
                let local = feather == 0
                    ? output.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": NSNumber(value: 0.5)])
                    : output
                let transform = CGAffineTransform(translationX: cx, y: cy)
                    .rotated(by: CGFloat(angle * .pi / 180))
                    .scaledBy(x: CGFloat(rx), y: CGFloat(ry))
                img = local.transformed(by: transform).cropped(to: extent)
            } else {
                let c = CIVector(x: extent.minX + w * m.x0, y: extent.minY + h * m.y0)
                let radiusBase = min(w, h)
                let r0 = max(0, radiusBase * m.radius * (1 - m.feather))
                let r1 = max(r0 + 1, radiusBase * m.radius * (1 + m.feather * 0.5))
                guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": c,
                    "inputRadius0": NSNumber(value: r0),
                    "inputRadius1": NSNumber(value: r1),
                    "inputColor0": CIColor.white, "inputColor1": CIColor.black
                ]), let output = gradient.outputImage else { return nil }
                img = output.cropped(to: extent)
            }
        case .brush, .depth:
            // depth 复用笔刷位图：用户涂白的区域 = 散景里被虚化的区域（不进局部调整，只喂给散景）
            guard let b = brushImage(m, extent: extent) else { return nil }
            img = b
        case .colorRange:
            // 范围蒙版必须作用在真实画面上：每个像素按自己的颜色/亮度查权重
            guard let srcImg = analyzed else { return nil }
            img = cubeWeight(RangeCube.colorMask(sample: m.sampleRGB, tolerance: m.tolerance),
                             appliedTo: srcImg, extent: extent)
            // 模糊会把画幅撑大，必须裁回去
            img = img.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: NSNumber(value: 1 + m.feather * 6)])
                .cropped(to: extent)
        case .luminanceRange:
            guard let srcImg = analyzed else { return nil }
            img = cubeWeight(RangeCube.luminanceMask(low: m.lumLow, high: m.lumHigh, soft: max(m.lumSoft, 0.01)),
                             appliedTo: srcImg, extent: extent)
        case .subject, .person, .foreground:
            // Vision 蒙版：拿当前画面跑模型（按 蒙版id + 画幅 缓存，不会每次渲染都跑）
            guard let srcImg = analyzed,
                  let ai = aiMask(for: m, extent: extent, analyzed: srcImg) else { return nil }
            img = ai
        }
        if m.inverted {
            img = img.applyingFilter("CIColorInvert")
        }
        if !m.refinements.isEmpty, let paint = refinementImage(m.refinements, extent: extent) {
            img = paint.composited(over: img).cropped(to: extent)
        }
        return img
    }

    private static func refinementImage(_ strokes: [Stroke], extent: CGRect) -> CIImage? {
        let side = 1024
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for stroke in strokes {
            let value: CGFloat = stroke.erasing ? 0 : 1
            let radius = max(2, stroke.radius * Double(side))
            let feather = min(max(stroke.feather, 0.01), 1)
            let colors = [CGColor(colorSpace: srgb, components: [value, value, value, 1])!,
                          CGColor(colorSpace: srgb, components: [value, value, value, 0])!] as CFArray
            guard let gradient = CGGradient(colorsSpace: srgb, colors: colors, locations: [0, 1]) else { continue }
            for point in stroke.points {
                let center = CGPoint(x: point.x * Double(side), y: point.y * Double(side))
                context.drawRadialGradient(gradient, startCenter: center, startRadius: radius * (1 - feather),
                                           endCenter: center, endRadius: radius, options: [.drawsBeforeStartLocation])
            }
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by:
            CGAffineTransform(translationX: extent.minX, y: extent.minY)
                .scaledBy(x: extent.width / Double(side), y: extent.height / Double(side)))
    }

    private static func brushImage(_ m: Mask, extent: CGRect) -> CIImage? {
        let side = 1024
        let cs = CGColorSpaceCreateDeviceGray()
        guard let cgctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // 底是黑（不生效），涂到的地方是白（生效）——以前画反了，
        // 结果「涂哪儿哪儿不生效」，看起来就像画笔不能用。
        cgctx.setFillColor(gray: 0, alpha: 1)
        cgctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        cgctx.setFillColor(gray: 1, alpha: 1)
        for st in m.strokes {
            let rad = max(2, st.radius * Double(side))
            for pt in st.points {
                let x = pt.x * Double(side), y = pt.y * Double(side)
                cgctx.addEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
                cgctx.fillPath()
            }
        }
        guard let cg = cgctx.makeImage() else { return nil }
        var img = CIImage(cgImage: cg)
        if m.feather > 0 {
            img = img.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: NSNumber(value: m.feather * 40)])
        }
        // 由 1024 方形拉伸到实际画幅（笔刷坐标是归一化的，允许长宽比拉伸）
        let sx = extent.width / CGFloat(side), sy = extent.height / CGFloat(side)
        img = img.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY).scaledBy(x: sx, y: sy))
        return img.cropped(to: extent.integral)
    }

    // MARK: - 多重曝光合成
    /// 把多帧合成一张。mode = .average 等权平均；.fusion 按曝光合适度加权；
    /// .denoise 对齐后平均 + 离群剔除（调用前应先走 alignFrames）。
    /// 走 CPU 分条融合：CI 的加法混合会把 1+1 截断成白，做不了加权求和，所以自己算。
    static func fuse(_ images: [CIImage], mode: MergeMode) -> CGImage? {
        guard images.count >= 2 else { return nil }
        let frames = normalizedCanvas(images)
        let base = frames[0].extent
        let w = Int(base.width.rounded()), h = Int(base.height.rounded())
        guard w > 1, h > 1 else { return nil }

        guard let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16,
                                  bytesPerRow: w * 8, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder16Little.rawValue) else { return nil }

        var yOff = 0
        while yOff < h {
            // 降噪要同时持有所有帧的同位置像素，条带取矮点控制内存
            let th = min(mode == .denoise ? 128 : 512, h - yOff)
            let rect = CGRect(x: base.minX, y: base.minY + CGFloat(yOff),
                              width: base.width, height: CGFloat(th))
            let tile: CGImage?
            if mode == .denoise {
                tile = denoiseTile(frames: frames, rect: rect, w: w, h: th)
            } else {
                tile = blendTile(frames: frames, rect: rect, w: w, h: th, mode: mode)
            }
            guard let tile else { return nil }
            out.draw(tile, in: CGRect(x: 0, y: yOff, width: w, height: th))
            yOff += th
        }
        return out.makeImage()
    }

    /// 可分离盒式模糊（只用于权重图，够用且 O(n)）
    static func boxBlur(_ a: inout [Float], w: Int, h: Int, radius: Int) {
        guard radius > 0, w > 1, h > 1 else { return }
        var tmp = [Float](repeating: 0, count: w * h)
        let n = Float(radius * 2 + 1)
        for y in 0..<h {
            let base = y * w
            var sum: Float = 0
            for x in -radius...radius { sum += a[base + min(max(x, 0), w - 1)] }
            for x in 0..<w {
                tmp[base + x] = sum / n
                sum += a[base + min(x + radius + 1, w - 1)] - a[base + max(x - radius, 0)]
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for y in -radius...radius { sum += tmp[min(max(y, 0), h - 1) * w + x] }
            for y in 0..<h {
                a[y * w + x] = sum / n
                sum += tmp[min(y + radius + 1, h - 1) * w + x] - tmp[max(y - radius, 0) * w + x]
            }
        }
    }

    /// 16 位 TIFF：合成结果先用 16 位存住，后续还能继续调
    static func write16(_ cg: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Phos", code: 21, userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }
        CGImageDestinationAddImage(dest, cg, nil)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "Phos", code: 22, userInfo: [NSLocalizedDescriptionKey: "写出失败"])
        }
    }

    // MARK: - AI 蒙版（系统 Vision，全本地、不联网）
    private static let aiCache = BoundedCache<String, CIImage>(capacity: 16)

    /// 手动刷新（换图、改参数后点「重算」时用）
    static func invalidateAIMask(id: UUID) {
        aiCache.removeAll { $0.hasPrefix(id.uuidString) }
    }

    static func aiMask(for m: Mask, extent: CGRect, analyzed: CIImage) -> CIImage? {
        let key = "\(m.id.uuidString)-\(Int(extent.width))x\(Int(extent.height))-\(m.kind.rawValue)"
        if let c = aiCache[key] { return c }
        guard let img = runVision(kind: m.kind, source: analyzed, extent: extent) else { return nil }
        aiCache[key] = img
        return img
    }

    private static func runVision(kind: MaskKind, source: CIImage, extent: CGRect) -> CIImage? {
        let e = source.extent
        guard e.width > 4, e.height > 4 else { return nil }
        // 缩小到 1024 跑模型，回来再拉伸 —— 分割精度够用，速度快得多
        let side: CGFloat = 1024
        let s = min(1, side / max(e.width, e.height))
        let small = s < 1 ? source.transformed(by: CGAffineTransform(scaleX: s, y: s)) : source
        guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: srgb) else { return nil }

        var pixelBuffer: CVPixelBuffer?
        switch kind {
        case .person:
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .accurate
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do { try handler.perform([req]) } catch { return nil }
            pixelBuffer = req.results?.first?.pixelBuffer
        case .foreground:
            // 主体抠图：前景实例模型，取分析分辨率 float 软蒙版，下面统一放大到全画幅
            let req = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do { try handler.perform([req]) } catch { return nil }
            guard let obs = req.results?.first else { return nil }
            do {
                pixelBuffer = try obs.generateMask(forInstances: obs.allInstances)
            } catch { return nil }
        case .subject:
            let req = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do { try handler.perform([req]) } catch { return nil }
            pixelBuffer = req.results?.first?.pixelBuffer
        default:
            return nil
        }
        guard let pb = pixelBuffer else { return nil }

        var mask = CIImage(cvPixelBuffer: pb)
        let me = mask.extent
        guard me.width > 1, me.height > 1 else { return nil }
        // 实测（缓冲逐行统计对照人框行号）：CVPixelBuffer 第 0 行 = 图顶，
        // 且 CIImage(cvPixelBuffer:) 出来就是正的 —— 不要做任何翻转，
        // 之前多加的那步翻转正是「AI 蒙版是倒的」的根因。
        let sx = extent.width / me.width
        let sy = extent.height / me.height
        let t = CGAffineTransform(translationX: extent.minX, y: extent.minY).scaledBy(x: sx, y: sy)
        mask = mask.transformed(by: t).cropped(to: extent)

        if kind == .subject {
            // 显著性热图偏软，拉一下对比让主体边界更明确
            mask = mask.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: NSNumber(value: 2.2),
                kCIInputBrightnessKey: NSNumber(value: -0.22)
            ])
        }
        if kind == .foreground {
            // 边缘精修 levels：轻提对比 = 边界略向外扩；软边来自 createScaledMask
            mask = mask.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: NSNumber(value: 1.25)
            ])
            mask = mask.applyingFilter("CIGammaAdjust", parameters: [
                "inputPower": NSNumber(value: 0.92)
            ])
        }
        return mask.cropped(to: extent)
    }

    // MARK: - 镜头校正（透视 / 色差 / 紫边）与地平线

    // —— 透视 ——
    typealias Quad = (tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint)

    static func applyPerspective(_ img: CIImage, _ quad: Quad) -> CIImage {
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return img }
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgPoint: quad.tl), forKey: "inputTopLeft")
        f.setValue(CIVector(cgPoint: quad.tr), forKey: "inputTopRight")
        f.setValue(CIVector(cgPoint: quad.bl), forKey: "inputBottomLeft")
        f.setValue(CIVector(cgPoint: quad.br), forKey: "inputBottomRight")
        guard let out = f.outputImage else { return img }
        // 滤镜自己的 extent 就是矫正后的矩形（内容铺满），但它可能带非零原点——
        // 平移回原点即可。之前拿四边形外接框去 crop，两者对不上会缩在角落出黑边（实测踩过）
        return out.transformed(by: CGAffineTransform(
            translationX: -out.extent.minX, y: -out.extent.minY))
    }

    /// 手动透视：垂直 = 顶/底边反向缩放（治楼宇后仰），水平 = 左/右边反向缩放
    static func manualPerspectiveQuad(extent: CGRect, vertical: Double, horizontal: Double) -> Quad {
        let v = CGFloat(vertical / 100), hp = CGFloat(horizontal / 100)
        let cx = extent.midX, cy = extent.midY
        let hw = extent.width / 2, hh = extent.height / 2
        let tw = hw * (1 + v * 0.35), bw = hw * (1 - v * 0.35)
        let lh = hh * (1 + hp * 0.35), rh = hh * (1 - hp * 0.35)
        return (CGPoint(x: cx - tw, y: cy + hh),
                CGPoint(x: cx + tw, y: cy + hh),
                CGPoint(x: cx + bw, y: cy - rh),
                CGPoint(x: cx - bw, y: cy - lh))
    }


    /// 自动透视：Vision 矩形检测，取最大且最接近四边形的候选
    static func autoPerspectiveQuad(from source: CIImage) -> Quad? {
        let e = source.extent
        // 不跨照片复用 Vision 四边形，避免同尺寸图片串用检测结果。
        let side: CGFloat = 1024
        let sc = min(1, side / max(e.width, e.height))
        let small = sc < 1 ? source.transformed(by: CGAffineTransform(scaleX: sc, y: sc)) : source
        guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: srgb) else { return nil }
        let req = VNDetectRectanglesRequest()
        req.minimumSize = 0.15
        req.minimumConfidence = 0.6
        req.maximumObservations = 1
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first else { return nil }
        // Vision 归一化坐标原点在左下，与 Core Image 一致，直接按比例映射即可
        func pt(_ n: CGPoint) -> CGPoint {
            CGPoint(x: e.minX + n.x * e.width, y: e.minY + n.y * e.height)
        }
        let quad = (pt(obs.topLeft), pt(obs.topRight), pt(obs.bottomRight), pt(obs.bottomLeft))
        // 结果只用于本次检测，不写入跨照片缓存。
        return quad
    }

    /// 地平线自动校直：返回建议的「矫正」角度（度）。检测不到返回 nil。
    static func autoStraightenAngle(from source: CIImage) -> Double? {
        let e = source.extent
        let side: CGFloat = 1024
        let sc = min(1, side / max(e.width, e.height))
        let small = sc < 1 ? source.transformed(by: CGAffineTransform(scaleX: sc, y: sc)) : source
        guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: srgb) else { return nil }
        let req = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first else { return nil }
        // Vision 归一化左下原点：angle 为地平线相对水平的倾角（弧度）。
        // 摆平 = 反向旋转；Core Image 的旋转同为左下原点逆时针为正，故取负号。
        return -Double(obs.angle) * 180 / .pi
    }

    /// 旋转后画幅内最大内接轴对齐矩形（经典解），返回归一化裁剪参数
    static func inscribedCrop(canvasW: CGFloat, canvasH: CGFloat, angleDeg: Double)
        -> (x: Double, y: Double, w: Double, h: Double) {
        let theta = abs(angleDeg) * .pi / 180
        let sinA = abs(sin(theta)), cosA = abs(cos(theta))
        // 原始内容矩形（旋转前）的宽高；旋转画幅 = 内容绕中心旋转后的外接框
        // 由画幅与角度反推内容尺寸：W = cw·cos + ch·sin, H = cw·sin + ch·cos（正交两解取一致者）
        // 这里直接解联立：内容 w0,h0 满足
        var w0 = (canvasW * cosA - canvasH * sinA) / max(cosA * cosA - sinA * sinA, 1e-4)
        var h0 = (canvasH * cosA - canvasW * sinA) / max(cosA * cosA - sinA * sinA, 1e-4)
        w0 = max(1, w0); h0 = max(1, h0)
        let longSide = max(w0, h0), shortSide = min(w0, h0)
        var rw: Double, rh: Double
        if longSide <= 2 * shortSide * sinA + 2 * shortSide * cosA {
            let x = longSide / 2
            rw = x / max(cosA, 1e-4)
            rh = x / max(sinA, 1e-4)
        } else {
            let cos2a = cosA * cosA - sinA * sinA
            rw = (longSide * cosA - shortSide * sinA) / cos2a
            rh = (longSide * sinA - shortSide * cosA) / cos2a
        }
        rw = min(rw, Double(canvasW)); rh = min(rh, Double(canvasH))
        let x = (Double(canvasW) - rw) / 2 / Double(canvasW)
        let y = (Double(canvasH) - rh) / 2 / Double(canvasH)
        return (x, y, rw / Double(canvasW), rh / Double(canvasH))
    }

    // —— 横向色差：R/B 通道绕中心反向微缩放后重组 ——
    // 重组用运行时 CIColorKernel：CIPlusCompositing 在 macOS 26 上返回空图、
    // 加法/最大值混合会被 alpha 语义吞通道（都实测踩过），kernel 是唯一干净的路子
    static func correctLateralCA(_ img: CIImage, amount: Double) -> CIImage {
        let e = img.extent
        let a = CGFloat(amount / 100)
        // kernel 在函数内创建（实测放 static let 里首次调用会丢 G/B 通道，原因不明）
        guard let k = try? CIColorKernel(source: "kernel vec4 caMerge(__sample r, __sample g, __sample b) { return vec4(r.r, g.g, b.b, 1.0); }") else {
            return img
        }
        let z = CIVector(x: 0, y: 0, z: 0, w: 0)
        let a1 = CIVector(x: 0, y: 0, z: 0, w: 1)
        func channelOnly(_ rv: CIVector, _ gv: CIVector, _ bv: CIVector, scale: CGFloat) -> CIImage {
            var one = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": rv, "inputGVector": gv, "inputBVector": bv, "inputAVector": a1
            ])
            if abs(scale - 1) > 1e-6 {
                let t = CGAffineTransform(translationX: e.midX, y: e.midY)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -e.midX, y: -e.midY)
                one = one.transformed(by: t).cropped(to: e)
            }
            return one
        }
        let rImg = channelOnly(CIVector(x: 1, y: 0, z: 0, w: 0), z, z, scale: 1 + a * 0.0012)
        let gImg = channelOnly(z, CIVector(x: 0, y: 1, z: 0, w: 0), z, scale: 1)
        let bImg = channelOnly(z, z, CIVector(x: 0, y: 0, z: 1, w: 0), scale: 1 - a * 0.0012)
        guard let merged = k.apply(extent: e, arguments: [rImg, gImg, bImg]) else {
            return img
        }
        return merged.cropped(to: e)
    }

    // —— 紫边抑制：高亮度 且 蓝分量显著高于 R/G 均值 → 向灰度收敛 ——
    private static let purpleCubeCache = BoundedCache<Int, Data>(capacity: 16)
    static func defringePurple(_ img: CIImage, strength: Double) -> CIImage {
        let key = Int(strength.rounded())
        let data: Data
        if let d = purpleCubeCache[key] { data = d } else { data = buildPurpleCube(strength: key); purpleCubeCache[key] = data }
        guard let f = CIFilter(name: "CIColorCube") else { return img }
        f.setValue(RangeCube.dim, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        f.setValue(img, forKey: kCIInputImageKey)
        guard let o = f.outputImage else { return img }
        return o.cropped(to: img.extent)
    }

    private static func buildPurpleCube(strength: Int) -> Data {
        let D = RangeCube.dim, last = D - 1
        func toPerc(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        func toLin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let k = Double(strength) / 100 * 0.85
        var out = [Float](repeating: 0, count: D * D * D * 4)
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let r = toPerc(Double(ri) / Double(last))
                    let g = toPerc(Double(gi) / Double(last))
                    let b = toPerc(Double(bi) / Double(last))
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let bl = b - (r + g) / 2
                    // 高亮度 AND 高蓝偏 → 紫边特征
                    let w1 = min(max((y - 0.55) / 0.1, 0), 1)
                    let w2 = min(max((bl - 0.05) / 0.08, 0), 1)
                    let w = w1 * w2 * k
                    let gr = min(max(y, 0), 1)
                    let o = (bi * D * D + gi * D + ri) * 4
                    out[o] = Float(toLin(r + (gr - r) * w))
                    out[o + 1] = Float(toLin(g + (gr - g) * w))
                    out[o + 2] = Float(toLin(b + (gr - b) * w))
                    out[o + 3] = 1
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }

    // —— Halation 光晕 ——
    private static let highlightCubeCache = BoundedCache<Int, Data>(capacity: 16)
    static func addHalation(_ img: CIImage, amount: Double, threshold: Double, radiusFactor: Double) -> CIImage {
        let e = img.extent
        let tKey = Int(threshold.rounded())
        let data: Data
        if let d = highlightCubeCache[tKey] { data = d } else { data = buildHighlightCube(threshold: tKey); highlightCubeCache[tKey] = data }
        // 1) 高光提取（亮度超过阈值的软掩膜）
        guard let hf = CIFilter(name: "CIColorCube") else { return img }
        hf.setValue(RangeCube.dim, forKey: "inputCubeDimension")
        hf.setValue(data, forKey: "inputCubeData")
        hf.setValue(img, forKey: kCIInputImageKey)
        guard var glow = hf.outputImage else { return img }
        // 2) 大半径模糊（半径按长边百分比）
        let longEdge = max(e.width, e.height)
        let radius = longEdge * (0.005 + radiusFactor * 0.015)
        glow = glow.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: NSNumber(value: radius)
        ]).cropped(to: e)
        // 3) 暖色染色（真实胶片的 Halation 集中在红通道）
        glow = glow.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.38, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.16, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        // 4) 强度：把辉光 RGB 乘上 amount 后屏幕混合（乘 0 即无效果）
        let k = CGFloat(min(max(amount / 100, 0), 1))
        glow = glow.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        return glow.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: img
        ]).cropped(to: e)
    }

    private static func buildHighlightCube(threshold: Int) -> Data {
        let D = RangeCube.dim, last = D - 1
        let t = 0.3 + Double(threshold) / 100 * 0.65   // 滑块 0-100 → 亮度阈值 0.30~0.95
        var out = [Float](repeating: 0, count: D * D * D * 4)
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let r = Double(ri) / Double(last)
                    let g = Double(gi) / Double(last)
                    let b = Double(bi) / Double(last)
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let w = min(max((y - t) / 0.08 + 0.5, 0), 1)   // 阈值处 ±0.08 软过渡
                    let o = (bi * D * D + gi * D + ri) * 4
                    out[o] = Float(w); out[o + 1] = Float(w); out[o + 2] = Float(w); out[o + 3] = 1
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }

    // MARK: - 直方图
    static func histogram(_ img: CIImage, bins: Int = 256) -> (r: [Int], g: [Int], b: [Int], l: [Int]) {
        let e = img.extent
        let scale = min(1, 400 / max(e.width, e.height))
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 0, h > 0 else { return ([], [], [], []) }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(small, toBitmap: &buf, rowBytes: w * 4, bounds: small.extent, format: .RGBA8, colorSpace: srgb)
        var r = [Int](repeating: 0, count: bins)
        var g = [Int](repeating: 0, count: bins)
        var b = [Int](repeating: 0, count: bins)
        var l = [Int](repeating: 0, count: bins)
        for i in 0..<(w * h) {
            let o = i * 4
            let rv = buf[o], gv = buf[o + 1], bv = buf[o + 2]
            let lr = 0.299 * Double(rv)
            let lg = 0.587 * Double(gv)
            let lb = 0.114 * Double(bv)
            let li = Int(lr + lg + lb)
            r[min(bins - 1, Int(Double(rv) / 255 * Double(bins - 1)))] += 1
            g[min(bins - 1, Int(Double(gv) / 255 * Double(bins - 1)))] += 1
            b[min(bins - 1, Int(Double(bv) / 255 * Double(bins - 1)))] += 1
            l[min(bins - 1, li * (bins - 1) / 255)] += 1
        }
        return (r, g, b, l)
    }

    // MARK: - 出图
    static func write(_ img: CIImage, to url: URL, settings: ExportSettings) throws {
        var out = img
        if settings.maxLongEdge > 0 {
            let e = img.extent
            let s = Double(settings.maxLongEdge) / Double(max(e.width, e.height))
            if s < 1 {
                // 一次 Lanczos 即可（早先这里先 transform 再 Lanczos，等于缩了两次，长边会变成 s² 倍）
                out = img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": NSNumber(value: s)])
            }
        }
        if settings.sharpenForOutput {
            out = out.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: NSNumber(value: 0.8),
                kCIInputIntensityKey: NSNumber(value: 0.4)
            ])
        }
        // 水印放在最后叠：尺寸按输出图算，锐化也不会把字描出毛边
        if settings.watermarkEnabled {
            out = applyWatermark(out, settings)
        }
        let format: CIFormat = settings.format == "tiff" && settings.tiffBitDepth == 16 ? .RGBA16 : .RGBA8
        guard let cg = ctx.createCGImage(out, from: out.extent, format: format,
                                        colorSpace: settings.colorSpace.cgColorSpace) else {
            throw NSError(domain: "Phos", code: 12, userInfo: [NSLocalizedDescriptionKey: "无法生成导出图像"])
        }
        let ut: UTType
        switch settings.format {
        case "png": ut = .png
        case "tiff": ut = .tiff
        case "heic": ut = .heic
        default: ut = .jpeg
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, ut.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Phos", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }
        var opts: [CFString: Any] = [:]
        if ut == .jpeg || ut == .heic {
            opts[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "Phos", code: 11, userInfo: [NSLocalizedDescriptionKey: "写出失败"])
        }
    }

    // MARK: - 水印
    /// 出图时叠加水印（只影响导出文件，不进预览 / 副档）。
    /// 文字用 AppKit 栅格化（带柔和投影），图片按比例缩放；九宫格定位 + 旋转 + 不透明度。
    static func applyWatermark(_ img: CIImage, _ s: ExportSettings) -> CIImage {
        let e = img.extent
        let longEdge = Double(max(e.width, e.height))
        guard longEdge > 1, s.watermarkOpacity > 0.002, s.watermarkScale > 0.001 else { return img }

        var layer: CIImage?
        if s.watermarkKind == "image", !s.watermarkImagePath.isEmpty {
            layer = imageWatermark(URL(fileURLWithPath: s.watermarkImagePath),
                                   width: CGFloat(longEdge * s.watermarkScale))
        }
        if layer == nil {
            let txt = s.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
            layer = textWatermark(txt.isEmpty ? "Phos" : txt,
                                  fontPx: CGFloat(longEdge * s.watermarkScale),
                                  dark: s.watermarkDarkText)
        }
        guard var wm = layer else { return img }

        // 九宫格定位（CI 坐标 y 向上）
        let we = wm.extent
        let margin = Double(min(e.width, e.height)) * s.watermarkMargin
        let cx: Double, cy: Double
        switch s.watermarkPosition {
        case "topLeft":      cx = e.minX + margin + we.width / 2;  cy = e.maxY - margin - we.height / 2
        case "topCenter":    cx = e.midX;                          cy = e.maxY - margin - we.height / 2
        case "topRight":     cx = e.maxX - margin - we.width / 2;  cy = e.maxY - margin - we.height / 2
        case "midLeft":      cx = e.minX + margin + we.width / 2;  cy = e.midY
        case "center":       cx = e.midX;                          cy = e.midY
        case "midRight":     cx = e.maxX - margin - we.width / 2;  cy = e.midY
        case "bottomLeft":   cx = e.minX + margin + we.width / 2;  cy = e.minY + margin + we.height / 2
        case "bottomCenter": cx = e.midX;                          cy = e.minY + margin + we.height / 2
        default:             cx = e.maxX - margin - we.width / 2;  cy = e.minY + margin + we.height / 2
        }
        // 先挪到锚点中心，再绕中心旋转，最后把水印自身中心对齐过去
        var t = CGAffineTransform(translationX: cx, y: cy)
        if s.watermarkRotation != 0 {
            t = t.rotated(by: CGFloat(s.watermarkRotation * .pi / 180))
        }
        t = t.translatedBy(x: -we.width / 2, y: -we.height / 2)
        wm = wm.transformed(by: t)

        // 不透明度：alpha 整体乘系数（RGB 不动）
        if s.watermarkOpacity < 0.999 {
            wm = wm.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: s.watermarkOpacity)
            ])
        }
        // 裁回原幅面：贴边 + 旋转时水印角会伸出图外，不裁的话画布会被撑大、整图错位
        return wm.composited(over: img).cropped(to: e)
    }

    /// 文字水印层：系统粗体 + 柔和投影，栅格化成带 alpha 的 CIImage
    private static func textWatermark(_ text: String, fontPx: CGFloat, dark: Bool) -> CIImage? {
        let px = max(8, fontPx)
        let font = NSFont.systemFont(ofSize: px, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = max(1, px * 0.07)
        shadow.shadowOffset = NSSize(width: 0, height: -max(1, px * 0.035))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: dark ? NSColor.black : NSColor.white,
            .shadow: shadow
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let ts = str.size()
        let pad = ceil(px * 0.4)   // 给投影留边，别裁掉
        let w = Int(ceil(ts.width + pad * 2)), h = Int(ceil(ts.height + pad * 2))
        guard w > 1, h > 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: w, height: h)   // 点 == 像素，避免被按 2x 缩
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        str.draw(at: NSPoint(x: pad, y: pad))
        gc.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    /// 图片水印层（logo / 拍摄者签名图）：按目标宽度等比缩放
    private static func imageWatermark(_ url: URL, width: CGFloat) -> CIImage? {
        guard let src = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let e = src.extent
        guard e.width > 1, width > 1 else { return nil }
        let k = width / e.width
        return src.transformed(by: CGAffineTransform(scaleX: k, y: k))
    }
}

// MARK: - HSL 立方体（把 8 个色相分区的选择性调整烘进一张 LUT）
enum HSLCube {
    static let dim = 32
    private static let cache = BoundedCache<UInt64, Data>(capacity: 24)

    static func filter(_ mix: HSLMix) -> CIFilter? {
        let key = hash(mix)
        let data: Data
        if let d = cache[key] { data = d } else {
            data = build(mix)
            cache[key] = data
        }
        guard let f = CIFilter(name: "CIColorCube") else { return nil }
        f.setValue(dim, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        return f
    }

    private static func hash(_ m: HSLMix) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        let vals = [m.red, m.orange, m.yellow, m.green, m.aqua, m.blue, m.purple, m.magenta]
        for b in vals {
            for v in [b.hue, b.sat, b.lum] {
                h ^= UInt64(bitPattern: Int64(v * 10))
                h = h &* 1099511628211
            }
        }
        return h
    }

    // 8 个分区的中心色相（度）
    private static let centers: [Double] = [0, 30, 60, 120, 180, 225, 270, 315]

    private static func build(_ m: HSLMix) -> Data {
        let bands = [m.red, m.orange, m.yellow, m.green, m.aqua, m.blue, m.purple, m.magenta]
        let D = dim
        var out = [Float](repeating: 0, count: D * D * D * 4)
        let last = Double(D - 1)
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let r = Double(ri) / last, g = Double(gi) / last, b = Double(bi) / last
                    let (h0, s0, l0) = rgbToHSL(r, g, b)
                    var dh: Double = 0, ds: Double = 1, dl: Double = 1
                    if s0 > 0.02 {
                        var total: Double = 0
                        var accH: Double = 0, accS: Double = 0, accL: Double = 0
                        for i in 0..<8 {
                            var d = abs(h0 - centers[i])
                            if d > 180 { d = 360 - d }
                            let w = max(0, 1 - d / 45)
                            if w <= 0 { continue }
                            total += w
                            accH += bands[i].hue * w
                            accS += (bands[i].sat / 100) * w
                            accL += (bands[i].lum / 100) * w
                        }
                        if total > 0 {
                            dh = accH / total
                            ds = 1 + accS / total
                            dl = 1 + accL / total
                        }
                    }
                    var hN = h0 + dh
                    while hN < 0 { hN += 360 }
                    while hN >= 360 { hN -= 360 }
                    let sN = min(max(s0 * ds, 0), 1)
                    let lN = min(max(l0 * dl, 0), 1)
                    let (rN, gN, bN) = hslToRGB(hN, sN, lN)
                    let o = (bi * D * D + gi * D + ri) * 4
                    out[o] = Float(rN); out[o + 1] = Float(gN); out[o + 2] = Float(bN); out[o + 3] = 1
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }

    private static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx == mn { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h * 60, s, l)
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue2(_ t: Double) -> Double {
            var tt = t
            if tt < 0 { tt += 1 }
            if tt > 1 { tt -= 1 }
            if tt < 1.0 / 6 { return p + (q - p) * 6 * tt }
            if tt < 1.0 / 2 { return q }
            if tt < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - tt) * 6 }
            return p
        }
        let hn = h / 360
        return (hue2(hn + 1.0 / 3), hue2(hn), hue2(hn - 1.0 / 3))
    }
}

// MARK: - 曲线立方体（亮度曲线 + 单独 RGB 通道曲线，一起烘成一张 LUT）
enum CurveCube {
    static let dim = 64
    private static let cache = BoundedCache<UInt64, Data>(capacity: 12)

    static func needs(_ p: EditParams) -> Bool {
        !p.curve.isIdentity || !p.lumaCurve.isIdentity || !p.curveR.isIdentity
            || !p.curveG.isIdentity || !p.curveB.isIdentity
            || p.refineSat > 0 || !p.gradeShadow.isNeutral
            || !p.gradeMid.isNeutral || !p.gradeHigh.isNeutral
            || p.calibShadowTint != 0
    }

    static func filter(_ p: EditParams) -> CIFilter? {
        guard needs(p) else { return nil }
        let key = hash(p)
        let data: Data
        if let d = cache[key] { data = d } else { data = build(p); cache[key] = data }
        guard let f = CIFilter(name: "CIColorCube") else { return nil }
        f.setValue(dim, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        return f
    }

    private static func hash(_ p: EditParams) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for cv in [p.curve, p.lumaCurve, p.curveR, p.curveG, p.curveB] {
            for pt in cv.points {
                for v in pt {
                    h ^= UInt64(bitPattern: Int64((v * 10000).rounded()))
                    h = h &* 1099511628211
                }
                h = h &* 1099511628211
            }
            h ^= UInt64(cv.points.count)
            h = h &* 1099511628211
        }
        for v in [p.refineSat,
                  p.gradeShadow.hue, p.gradeShadow.sat, p.gradeShadow.lum,
                  p.gradeMid.hue, p.gradeMid.sat, p.gradeMid.lum,
                  p.gradeHigh.hue, p.gradeHigh.sat, p.gradeHigh.lum,
                  p.gradeBlend, p.gradeBalance, p.calibShadowTint] {
            h ^= UInt64(bitPattern: Int64((v * 100).rounded()))
            h = h &* 1099511628211
        }
        return h
    }

    private static func build(_ p: EditParams) -> Data {
        let D = dim
        let last = D - 1
        // 先各自求 1D LUT，三层循环里只剩查表，快得多
        var lutT = [Double](repeating: 0, count: D)
        var lutR = [Double](repeating: 0, count: D)
        var lutG = [Double](repeating: 0, count: D)
        var lutB = [Double](repeating: 0, count: D)
        var lutL = [Double](repeating: 0, count: D)
        for i in 0..<D {
            let x = Double(i) / Double(last)
            lutT[i] = p.curve.value(at: x)
            lutR[i] = p.curveR.value(at: x)
            lutG[i] = p.curveG.value(at: x)
            lutB[i] = p.curveB.value(at: x)
            lutL[i] = p.lumaCurve.value(at: x)
        }
        let toneActive = !p.curve.isIdentity
        let lumaActive = !p.lumaCurve.isIdentity
        let refine = min(max(p.refineSat / 100, 0), 1) > 0
        let refineK = min(max(p.refineSat / 100, 0), 1)
        // 颜色分级：三档上色 + 平衡分界 + 混合强度
        let bal = p.gradeBalance / 100 * 0.18
        let b1 = 0.33 + bal, b2 = 0.67 + bal
        let gradShadow = tintRGB(p.gradeShadow)
        let gradMid = tintRGB(p.gradeMid)
        let gradHigh = tintRGB(p.gradeHigh)
        // 混合：50 = 标准量，0 = 完全不上色，100 = 双倍
        let blendK = min(max(p.gradeBlend / 50, 0), 2)
        let grading = !p.gradeShadow.isNeutral || !p.gradeMid.isNeutral
            || !p.gradeHigh.isNeutral || p.calibShadowTint != 0 || p.gradeBlend != 50

        // 关键：CIColorCube 的索引与输出都在线性空间，而曲线是给人看的感知曲线。
        // 所以进曲线前先编码到 sRGB 感知域、出来再解回线性，否则中灰根本推不动（实测踩过）。
        func toPerc(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        func toLin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func look(_ lut: [Double], _ linear: Double) -> Double {
            let idx = min(D - 1, max(0, Int((toPerc(linear) * Double(last)).rounded())))
            return toLin(lut[idx])
        }
        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        func ramp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
            guard hi > lo else { return x >= hi ? 1 : 0 }
            return min(max((x - lo) / (hi - lo), 0), 1)
        }

        /// 分级色 → RGB（亮度固定在 0.5，只取色相和饱和度）
        func tintRGB(_ g: ColorGrade) -> (Double, Double, Double)? {
            guard g.sat > 0 else { return nil }
            let h = ((g.hue.truncatingRemainder(dividingBy: 360)) + 360)
                .truncatingRemainder(dividingBy: 360) / 360
            let s = min(max(g.sat / 100, 0), 1)
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
            return (hue2(h + 1.0 / 3), hue2(h), hue2(h - 1.0 / 3))
        }

        // These stages depend on one channel only, not on the other two cube axes.
        var channelR = [Double](repeating: 0, count: D)
        var channelG = channelR, channelB = channelR, perceptualInput = channelR
        for i in 0..<D {
            let input = Double(i) / Double(last)
            let tone = toneActive ? look(lutT, input) : input
            channelR[i] = look(lutR, tone)
            channelG[i] = look(lutG, tone)
            channelB[i] = look(lutB, tone)
            perceptualInput[i] = toPerc(input)
        }

        var out = [Float](repeating: 0, count: D * D * D * 4)
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    // 线性索引值 →（色调曲线）→ 单独通道曲线 → （亮度曲线）
                    var r = channelR[ri]
                    var g = channelG[gi]
                    var b = channelB[bi]
                    if lumaActive {
                        // 亮度曲线：按目标亮度等比缩放 RGB，色调和饱和度基本不动
                        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        let target = look(lutL, y)
                        if y > 0.0005 {
                            let k = target / y
                            r = min(max(r * k, 0), 1)
                            g = min(max(g * k, 0), 1)
                            b = min(max(b * k, 0), 1)
                        } else {
                            r = target; g = target; b = target
                        }
                    }
                    // —— 感知域后处理：Refine Sat（保色）→ 颜色分级 → 阴影色调
                    if refine || grading {
                        var pr = toPerc(r), pg = toPerc(g), pb = toPerc(b)
                        if refine {
                            // 原始感知值（曲线前）用于取真实色度；把色度挂回新的亮度上
                            let y0 = luma(perceptualInput[ri], perceptualInput[gi], perceptualInput[bi])
                            let y1 = luma(pr, pg, pb)
                            let k = (y1 + 0.05) / (max(y0, 0.001) + 0.05)
                            let p0r = perceptualInput[ri]
                            let p0g = perceptualInput[gi]
                            let p0b = perceptualInput[bi]
                            let keepR = y1 + (p0r - y0) * k
                            let keepG = y1 + (p0g - y0) * k
                            let keepB = y1 + (p0b - y0) * k
                            pr = pr + (keepR - pr) * refineK
                            pg = pg + (keepG - pg) * refineK
                            pb = pb + (keepB - pb) * refineK
                            pr = min(max(pr, 0), 1); pg = min(max(pg, 0), 1); pb = min(max(pb, 0), 1)
                        }
                        if grading {
                            let y = luma(pr, pg, pb)
                            let wS = 1 - ramp(y, b1 - 0.16, b1 + 0.16)
                            let wH = ramp(y, b2 - 0.16, b2 + 0.16)
                            let wM = 1 - min(abs(y - 0.5) / 0.34, 1)
            // 上色时把色差里的亮度分量减掉：只上色、不改明暗，也不把暗部压死
            func tint(_ c: (Double, Double, Double)?, _ w: Double, _ sat: Double) -> (Double, Double, Double) {
                guard let c = c else { return (0, 0, 0) }
                let k = w * (sat / 100) * 0.42 * blendK
                let dr = (c.0 - 0.5) * k, dg = (c.1 - 0.5) * k, db = (c.2 - 0.5) * k
                let ly = 0.2126 * dr + 0.7152 * dg + 0.0722 * db
                return (dr - ly, dg - ly, db - ly)
            }
            let tS = tint(gradShadow, wS, p.gradeShadow.sat)
            let tM = tint(gradMid, wM, p.gradeMid.sat)
            let tH = tint(gradHigh, wH, p.gradeHigh.sat)
            var dr = tS.0 + tM.0 + tH.0
            var dg = tS.1 + tM.1 + tH.1
            var db = tS.2 + tM.2 + tH.2
                            // 各档明亮度：按该档权重整体提/压
                            let dl = (p.gradeShadow.lum * wS + p.gradeMid.lum * wM + p.gradeHigh.lum * wH) / 100 * 0.28
                            dr += dl; dg += dl; db += dl
                            // 校准面板的阴影色调：正偏绿、负偏洋红
                            if p.calibShadowTint != 0 {
                                let t = p.calibShadowTint / 100 * 0.35 * wS
                                if t > 0 { dg += t } else { dr += -t * 0.7; db += -t * 0.7 }
                            }
                            pr = min(max(pr + dr, 0), 1)
                            pg = min(max(pg + dg, 0), 1)
                            pb = min(max(pb + db, 0), 1)
                        }
                        r = toLin(pr); g = toLin(pg); b = toLin(pb)
                    }

                    let o = (bi * D * D + gi * D + ri) * 4
                    out[o] = Float(r); out[o + 1] = Float(g); out[o + 2] = Float(b); out[o + 3] = 1
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }
}

// MARK: - 校准：三原色各自改色相/饱和度 → 3×3 矩阵
enum Calibration {
    /// 把「原色旋转后」的基向量拼成矩阵，再做行归一化，保证白点还是白的
    static func matrix(red: PrimaryAdj, green: PrimaryAdj, blue: PrimaryAdj) -> [CGFloat] {
        func primary(_ hueDeg: Double, _ adj: PrimaryAdj) -> (Double, Double, Double) {
            let h = ((hueDeg + adj.hue).truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360) / 60.0
            let s = 1 + adj.sat / 100
            let c = s            // 饱和度缩放
            let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let seg = Int(h) % 6
            switch seg {
            case 0: return (c, x, 0)
            case 1: return (x, c, 0)
            case 2: return (0, c, x)
            case 3: return (0, x, c)
            case 4: return (x, 0, c)
            default: return (c, 0, x)
            }
        }
        let r = primary(0, red), g = primary(120, green), b = primary(240, blue)
        // 列 = 新原色
        let m = [[r.0, g.0, b.0],
                 [r.1, g.1, b.1],
                 [r.2, g.2, b.2]]
        // 行归一化：白点不变形
        var out = [CGFloat](repeating: 0, count: 9)
        for i in 0..<3 {
            let sum = m[i][0] + m[i][1] + m[i][2]
            let k = abs(sum) > 1e-6 ? 1.0 / sum : 1.0
            for j in 0..<3 { out[i * 3 + j] = CGFloat(m[i][j] * k) }
        }
        return out
    }
}

// MARK: - 范围蒙版（按颜色 / 按亮度取样）
enum RangeCube {
    static let dim = 32
    private static let colorCache = BoundedCache<[Double], Data>(capacity: 16)
    private static let luminanceCache = BoundedCache<[Double], Data>(capacity: 16)

    /// 线性 → 感知（取样色和亮度上下界都是感知值，比较必须在同一空间里做，
    /// 否则亮部会被线性空间放大距离、容差完全落空 —— 实测踩过）
    private static func toPerc(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// 越接近取样色越白；tolerance 控制范围宽窄
    static func colorMask(sample: [Double], tolerance: Double) -> Data {
        let D = dim, last = D - 1
        let sr = sample.count == 3 ? sample[0] : 0.5
        let sg = sample.count == 3 ? sample[1] : 0.5
        let sb = sample.count == 3 ? sample[2] : 0.5
        let tol = max(tolerance, 0.02)
        let key = [sr, sg, sb, tol]
        if let data = colorCache[key] { return data }
        var out = [Float](repeating: 0, count: D * D * D * 4)
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let r = toPerc(Double(ri) / Double(last))
                    let g = toPerc(Double(gi) / Double(last))
                    let b = toPerc(Double(bi) / Double(last))
                    let d = ((r - sr) * (r - sr) + (g - sg) * (g - sg) + (b - sb) * (b - sb)).squareRoot()
                    let w = min(max(1 - (d - tol * 0.5) / tol, 0), 1)
                    let o = (bi * D * D + gi * D + ri) * 4
                    out[o] = Float(w); out[o + 1] = Float(w); out[o + 2] = Float(w); out[o + 3] = 1
                }
            }
        }
        let data = out.withUnsafeBytes { Data($0) }
        colorCache[key] = data
        return data
    }

    /// 亮度落在 [low, high] 内为白，软边由 soft 控制
    static func luminanceMask(low: Double, high: Double, soft: Double) -> Data {
        let D = dim, last = D - 1
        let lo = min(low, high), hi = max(low, high)
        let s = max(soft, 0.001)
        let key = [lo, hi, s]
        if let data = luminanceCache[key] { return data }
        var out = [Float](repeating: 0, count: D * D * D * 4)
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let r = toPerc(Double(ri) / Double(last))
                    let g = toPerc(Double(gi) / Double(last))
                    let b = toPerc(Double(bi) / Double(last))
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let w = min(min((y - (lo - s)) / s, ((hi + s) - y) / s), 1)
                    let wc = min(max(w, 0), 1)
                    let o = (bi * D * D + gi * D + ri) * 4
                    out[o] = Float(wc); out[o + 1] = Float(wc); out[o + 2] = Float(wc); out[o + 3] = 1
                }
            }
        }
        let data = out.withUnsafeBytes { Data($0) }
        luminanceCache[key] = data
        return data
    }
}

// MARK: - 曝光合适度权重（多重曝光融合用，CPU 侧直接用公式，这里只留着常数以便调参）
enum WellExposed {
    static let center = 0.5      // 感知域的中灰
    static let sigma = 0.18
}
