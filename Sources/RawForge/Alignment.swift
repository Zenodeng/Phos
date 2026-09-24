import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision
import CoreVideo
import simd

// MARK: - 对齐方式（UI 与 Engine 共用）
enum AlignMethod: String, Codable, CaseIterable {
    case translation, homography
    var label: String {
        switch self {
        case .translation: return "平移（快）"
        case .homography:  return "透视（稳）"
        }
    }
}

struct AlignOutcome {
    var frames: [CIImage]
    var dropped: Int = 0
    var scores: [Double] = []
}

extension Engine {

    // MARK: - 画幅归一化：按短边放大 + 居中裁切 + 原点归零
    static func normalizedCanvas(_ images: [CIImage]) -> [CIImage] {
        let base = images[0].extent
        return images.map { img in
            let e = img.extent
            if abs(e.width - base.width) < 1 && abs(e.height - base.height) < 1
                && abs(e.minX - base.minX) < 1 && abs(e.minY - base.minY) < 1 {
                return img
            }
            let s = max(base.width / e.width, base.height / e.height)
            let t = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let te = t.extent
            let crop = CGRect(x: te.midX - base.width / 2, y: te.midY - base.height / 2,
                              width: base.width, height: base.height)
            return t.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        }
    }

    // MARK: - 代理图
    fileprivate static func proxyCG(_ imgIn: CIImage, longEdge: CGFloat = 1024)
        -> (cg: CGImage, scale: CGFloat)? {
        // 固定到原点画布并保留真实 alpha：平移帧的 extent 带非零原点且有透明边。
        // 不能直接 cropped（会把空区域填成 alpha=1），先合成到透明画布上
        let e0 = imgIn.extent
        let fixed = CGRect(x: 0, y: 0, width: e0.width, height: e0.height)
        let canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: fixed)
        var img = imgIn.composited(over: canvas)
        img = img.cropped(to: fixed)
        let s = min(1, longEdge / max(fixed.width, fixed.height))
        let small = s < 1 ? img.transformed(by: CGAffineTransform(scaleX: s, y: s)) : img
        guard let cg = ctx.createCGImage(small, from: small.extent,
                                         format: .RGBA8, colorSpace: srgb) else { return nil }
        return (cg, s)
    }

    // MARK: - 多帧对齐
    /// 在 ~1024px 代理上跑 Vision 图像注册 → NCC 质量门 → 全分辨率应用变换。
    /// 参考帧 = 第 0 帧。NCC 低于阈值（默认 0.7）的帧直接剔除，宁可少帧不要鬼影。
    static func alignFrames(_ images: [CIImage], method: AlignMethod,
                            threshold: Double = 0.7) -> AlignOutcome {
        guard images.count >= 2 else { return AlignOutcome(frames: images) }
        let frames = normalizedCanvas(images)
        let ref = frames[0]
        let W = ref.extent.width, H = ref.extent.height
        guard let rp = proxyCG(ref) else { return AlignOutcome(frames: frames) }

        let proxyExtent = CGRect(x: 0, y: 0, width: CGFloat(rp.cg.width),
                                 height: CGFloat(rp.cg.height))
        var kept: [CIImage] = [ref]
        var dropped = 0
        var scores: [Double] = []

        for fi in 1..<frames.count {
            guard let fp = proxyCG(frames[fi]) else { dropped += 1; continue }
            var alignedProxy: CIImage?
            var fullAligned: CIImage?

            switch method {
            case .translation:
                let req = VNTranslationalImageRegistrationRequest(targetedCGImage: fp.cg)
                let handler = VNImageRequestHandler(cgImage: rp.cg, options: [:])
                do { try handler.perform([req]) } catch { dropped += 1; continue }
                guard let obs = req.results?.first else { dropped += 1; continue }
                let t = obs.alignmentTransform
                alignedProxy = CIImage(cgImage: fp.cg).transformed(by: t)
                // 代理变换 → 全分辨率：T_full = S⁻¹·T·S（S 把全图缩到代理）
                let ps = fp.scale
                let down = CGAffineTransform(scaleX: ps, y: ps)
                let up = CGAffineTransform(scaleX: 1 / ps, y: 1 / ps)
                let fullT = up.concatenating(t).concatenating(down)
                fullAligned = frames[fi].transformed(by: fullT)
                    .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))

            case .homography:
                let req = VNHomographicImageRegistrationRequest(targetedCGImage: fp.cg)
                let handler = VNImageRequestHandler(cgImage: rp.cg, options: [:])
                do { try handler.perform([req]) } catch { dropped += 1; continue }
                guard let obs = req.results?.first else { dropped += 1; continue }
                let Hm = obs.warpTransform
                let ps = Float(fp.scale)
                let S3 = simd_float3x3(diagonal: SIMD3<Float>(ps, ps, 1))
                let Hfull = S3.inverse * Hm * S3

                func quad(of m: simd_float3x3, w: CGFloat, h: CGFloat)
                    -> (tl: CGPoint, tr: CGPoint, bl: CGPoint, br: CGPoint) {
                    func pr(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                        let q = m * SIMD3<Float>(Float(x), Float(y), 1)
                        return CGPoint(x: CGFloat(q.x / q.z), y: CGFloat(q.y / q.z))
                    }
                    return (pr(0, h), pr(w, h), pr(0, 0), pr(w, 0))
                }
                func perspectiveFilter(_ src: CIImage, _ q: (tl: CGPoint, tr: CGPoint,
                                                              bl: CGPoint, br: CGPoint))
                    -> CIImage? {
                    let f = CIFilter(name: "CIPerspectiveTransform")!
                    f.setValue(src, forKey: kCIInputImageKey)
                    f.setValue(CIVector(cgPoint: q.tl), forKey: "inputTopLeft")
                    f.setValue(CIVector(cgPoint: q.tr), forKey: "inputTopRight")
                    f.setValue(CIVector(cgPoint: q.bl), forKey: "inputBottomLeft")
                    f.setValue(CIVector(cgPoint: q.br), forKey: "inputBottomRight")
                    return f.outputImage
                }
                let pq = quad(of: Hm, w: CGFloat(fp.cg.width), h: CGFloat(fp.cg.height))
                alignedProxy = perspectiveFilter(CIImage(cgImage: fp.cg), pq)
                let fq = quad(of: Hfull, w: W, h: H)
                fullAligned = perspectiveFilter(frames[fi], fq)?
                    .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
            }

            guard let ap = alignedProxy, let fa = fullAligned else { dropped += 1; continue }
            let overlap = ap.extent.intersection(proxyExtent)
            guard overlap.width > 24, overlap.height > 24 else { dropped += 1; continue }
            let score = nccScore(refCG: rp.cg, aligned: ap, overlap: overlap)
            scores.append(score)
            if score < threshold { dropped += 1; continue }
            kept.append(fa)
        }
        return AlignOutcome(frames: kept, dropped: dropped, scores: scores)
    }

    /// 归一化互相关（灰度，重叠区抽样 2px）。方向就算算反了，这里也会给出低分把帧剔掉。
    static func nccScore(refCG: CGImage, aligned: CIImage, overlap r: CGRect)
        -> Double {
        let step: CGFloat = 2
        let w = Int(r.width / step), h = Int(r.height / step)
        guard w > 8, h > 8 else { return 0 }
        let t = CGAffineTransform(scaleX: 1 / step, y: 1 / step)
        let rr = CGRect(x: r.minX / step, y: r.minY / step,
                        width: CGFloat(w), height: CGFloat(h))
        let a = CIImage(cgImage: refCG).cropped(to: r).transformed(by: t)
        let b = aligned.cropped(to: r).transformed(by: t)

        var ab = [UInt8](repeating: 0, count: w * h * 4)
        var bb = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(a, toBitmap: &ab, rowBytes: w * 4, bounds: rr,
                   format: .RGBA8, colorSpace: srgb)
        ctx.render(b, toBitmap: &bb, rowBytes: w * 4, bounds: rr,
                   format: .RGBA8, colorSpace: srgb)

        var xs: [Double] = [], ys: [Double] = []
        xs.reserveCapacity(w * h / 2); ys.reserveCapacity(w * h / 2)
        for i in 0..<(w * h) {
            if ab[i * 4 + 3] > 240, bb[i * 4 + 3] > 240 {
                xs.append(Double(ab[i * 4]) * 0.299 + Double(ab[i * 4 + 1]) * 0.587
                          + Double(ab[i * 4 + 2]) * 0.114)
                ys.append(Double(bb[i * 4]) * 0.299 + Double(bb[i * 4 + 1]) * 0.587
                          + Double(bb[i * 4 + 2]) * 0.114)
            }
        }
        guard xs.count > 100 else { return 0 }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in xs.indices {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        let denom = (sxx * syy).squareRoot()
        return denom > 1e-6 ? sxy / denom : 0
    }

    // MARK: - 平均/融合分块（自旧 fuse 内联逻辑迁出）
    static func blendTile(frames: [CIImage], rect: CGRect,
                          w: Int, h: Int, mode: MergeMode) -> CGImage? {
        let px = w * h
        var num = [Float](repeating: 0, count: px * 4)
        var den = [Float](repeating: 0, count: px)

        for f in frames {
            var buf = [Float](repeating: 0, count: px * 4)
            ctx.render(f, toBitmap: &buf, rowBytes: w * 4 * MemoryLayout<Float>.size,
                       bounds: rect, format: .RGBAf, colorSpace: srgb)
            // 透视对齐后的帧边缘可能透明：记录覆盖，别把黑边平均进来
            var covered = [Float](repeating: 1, count: px)
            for i in 0..<px where buf[i * 4 + 3] <= 0.5 { covered[i] = 0 }
            var wt = covered
            if mode == .fusion {
                for i in 0..<px where covered[i] > 0 {
                    let r = buf[i * 4], g = buf[i * 4 + 1], b = buf[i * 4 + 2]
                    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let d = (lum - Float(WellExposed.center)) / Float(WellExposed.sigma)
                    wt[i] = covered[i] * max(expf(-0.5 * d * d), 0.002)
                }
                boxBlur(&wt, w: w, h: h, radius: 12)
            }
            for i in 0..<px {
                let k = wt[i]
                num[i * 4]     += buf[i * 4]     * k
                num[i * 4 + 1] += buf[i * 4 + 1] * k
                num[i * 4 + 2] += buf[i * 4 + 2] * k
                num[i * 4 + 3] += buf[i * 4 + 3] * k
                den[i]         += k
            }
        }
        for i in 0..<px {
            let d = max(den[i], 1e-5)
            num[i * 4] /= d; num[i * 4 + 1] /= d; num[i * 4 + 2] /= d
            num[i * 4 + 3] = 1
        }

        let size = CGSize(width: w, height: h)
        let ci = CIImage(bitmapData: Data(bytes: num, count: num.count * 4),
                         bytesPerRow: w * 16, size: size, format: .RGBAf, colorSpace: srgb)
        return ctx.createCGImage(ci, from: CGRect(origin: .zero, size: size),
                                 format: .RGBA16, colorSpace: srgb)
    }

    // MARK: - 手持降噪分块：对齐后 mean + kσ 离群剔除
    static func denoiseTile(frames: [CIImage], rect: CGRect,
                            w: Int, h: Int) -> CGImage? {
        let px = w * h
        let n = frames.count

        // 1) 所有帧同位置像素全部渲染
        var bufs: [[Float]] = []
        bufs.reserveCapacity(n)
        for f in frames {
            var buf = [Float](repeating: 0, count: px * 4)
            ctx.render(f, toBitmap: &buf, rowBytes: w * 4 * MemoryLayout<Float>.size,
                       bounds: rect, format: .RGBAf, colorSpace: srgb)
            bufs.append(buf)
        }

        // 2) σ 估计：参考帧 vs 其余帧的 |Δluma| 直方图 → 中位数（MAD）→ σ
        let bins = 512
        var hist = [Int](repeating: 0, count: bins)
        var counted = 0
        for fi in 1..<n {
            let b = bufs[fi], r = bufs[0]
            for i in 0..<px where b[i * 4 + 3] > 0.5 && r[i * 4 + 3] > 0.5 {
                let lumB = 0.2126 * b[i * 4] + 0.7152 * b[i * 4 + 1]
                           + 0.0722 * b[i * 4 + 2]
                let lumR = 0.2126 * r[i * 4] + 0.7152 * r[i * 4 + 1]
                           + 0.0722 * r[i * 4 + 2]
                let d = abs(lumB - lumR)
                hist[min(Int(d * Float(bins)), bins - 1)] += 1
                counted += 1
            }
        }
        var sigma: Float = 0.02
        if counted > 100 {
            let half = counted / 2
            var acc = 0, medianBin = 0
            for bi in 0..<bins {
                acc += hist[bi]
                if acc >= half { medianBin = bi; break }
            }
            sigma = min(max(Float(medianBin) / Float(bins) * 1.4826, 0.008), 0.2)
        }
        let k: Float = 2.5

        // 3) 逐像素：偏离参考 > kσ 的通道直接取参考值，其余平均
        var out = [Float](repeating: 0, count: px * 4)
        for i in 0..<px {
            let r = bufs[0]
            let rl = r[i * 4], rg = r[i * 4 + 1], rb = r[i * 4 + 2]
            let lumR = 0.2126 * rl + 0.7152 * rg + 0.0722 * rb
            let refClipped = lumR >= 0.99 || lumR <= 0.01
            var ar: Float = 0, ag: Float = 0, ab: Float = 0, count: Float = 0
            for fi in 0..<n {
                let b = bufs[fi]
                if b[i * 4 + 3] <= 0.5 { continue }
                if refClipped {
                    ar += b[i * 4]; ag += b[i * 4 + 1]; ab += b[i * 4 + 2]
                } else {
                    ar += abs(b[i * 4] - rl) > k * sigma ? rl : b[i * 4]
                    ag += abs(b[i * 4 + 1] - rg) > k * sigma ? rg : b[i * 4 + 1]
                    ab += abs(b[i * 4 + 2] - rb) > k * sigma ? rb : b[i * 4 + 2]
                }
                count += 1
            }
            if count < 1 {
                out[i * 4] = rl; out[i * 4 + 1] = rg; out[i * 4 + 2] = rb
            } else {
                out[i * 4] = ar / count; out[i * 4 + 1] = ag / count
                out[i * 4 + 2] = ab / count
            }
            out[i * 4 + 3] = 1
        }

        let size = CGSize(width: w, height: h)
        let ci = CIImage(bitmapData: Data(bytes: out, count: out.count * 4),
                         bytesPerRow: w * 16, size: size, format: .RGBAf, colorSpace: srgb)
        return ctx.createCGImage(ci, from: CGRect(origin: .zero, size: size),
                                 format: .RGBA16, colorSpace: srgb)
    }

    // MARK: - 焦外散景
    static func applyBokeh(_ img: CIImage, _ p: EditParams,
                           disparityMask: CIImage?) -> CIImage {
        let e = img.extent
        // 深度来源：优先用户的「深度涂绘」蒙版，其次 HEIC disparity
        var depth: CIImage? = nil
        if let dm = p.masks.first(where: { $0.kind == .depth && $0.enabled }) {
            depth = maskImage(for: dm, extent: e, analyzed: img)
        } else if let d = disparityMask {
            depth = d
        }
        guard let mask = depth?.cropped(to: e) else { return img }

        let radius = max(e.width, e.height) * CGFloat(p.bokehAmount / 100) * 0.03
        let f = CIFilter(name: "CIMaskedVariableBlur")!
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(mask, forKey: "inputMask")
        f.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage else { return img }
        return out.cropped(to: e)
    }

    // MARK: - iPhone 人像 HEIC disparity 深度
    private static var disparityCache: [String: CIImage] = [:]

    static func hasDisparity(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0,
                                                         kCGImageAuxiliaryDataTypeDisparity) != nil
    }

    /// 读 disparity 辅助数据 → 按百分位归一化 → 取反（近黑远白，白端被散景模糊）
    static func disparityBokehMask(for url: URL, target extent: CGRect) -> CIImage? {
        let key = "\(url.path)-\(Int(extent.width))x\(Int(extent.height))"
        if let c = disparityCache[key] { return c }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                src, 0, kCGImageAuxiliaryDataTypeDisparity) as? [CFString: Any],
              let data = aux[kCGImageAuxiliaryDataInfoData] as? Data,
              let desc = aux[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any]
        else { return nil }

        let dw = (desc[kCGImagePropertyWidth] as? Int) ?? 0
        let dh = (desc[kCGImagePropertyHeight] as? Int) ?? 0
        let pf = (desc[kCGImagePropertyPixelFormat] as? UInt32)
                  ?? kCVPixelFormatType_DisparityFloat16
        let bpr = (desc["BytesPerRow" as CFString] as? Int) ?? (dw * 2)
        guard dw > 1, dh > 1 else { return nil }

        var pb: CVPixelBuffer?
        let rc = CVPixelBufferCreate(kCFAllocatorDefault, dw, dh, pf,
                                     [kCVPixelBufferBytesPerRowAlignmentKey: bpr] as CFDictionary,
                                     &pb)
        guard rc == kCVReturnSuccess, let pixelBuffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        data.withUnsafeBytes { raw in
            if let dst = CVPixelBufferGetBaseAddress(pixelBuffer),
               let base = raw.baseAddress {
                dst.copyMemory(from: base, byteCount: min(data.count, bpr * dh))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var disp = CIImage(cvPixelBuffer: pixelBuffer)
        // disparity 按文件存储方向，主图解码已应用 EXIF 方向，这里要对齐
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let ori = props[kCGImagePropertyOrientation] as? UInt32, ori != 1 {
            disp = disp.oriented(forExifOrientation: Int32(ori))
        }

        // 百分位：直接扫 half float 原始数据，取 2%/98%
        var vals: [Float] = []
        vals.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { raw in
            let n = data.count / 2
            raw.bindMemory(to: UInt16.self).withMemoryRebound(to: UInt16.self) { ptr in
                for i in 0..<n {
                    let v = Float(Float16(bitPattern: ptr[i]))
                    if v.isFinite, v > 0 { vals.append(v) }
                }
            }
        }
        guard vals.count > 100 else { return nil }
        vals.sort()
        let lo = vals[vals.count * 2 / 100]
        let hi = vals[vals.count * 98 / 100]
        let s = 1 / max(hi - lo, 1e-4)
        let bias = 1 + lo * s

        // 只取 R（单分量缓冲其他通道不确定）→ 复制到 RGB → 反向归一化：1-(d-lo)s
        let cgS = CGFloat(s), cgB = CGFloat(bias)
        var m = disp.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -cgS, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: -cgS, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: -cgS, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: cgB, y: cgB, z: cgB, w: 0)
        ])
        m = m.applyingFilter("CIColorClamp")

        let de = disp.extent
        let scx = extent.width / de.width, scy = extent.height / de.height
        m = m.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
            .scaledBy(x: scx, y: scy)).cropped(to: extent)

        disparityCache[key] = m
        return m
    }
}
