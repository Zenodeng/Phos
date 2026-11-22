import Foundation
import CoreImage
import CoreGraphics
import Vision
import CoreML

/// 高级蒙版引擎：布尔组合（加/减/交）、天空与人脸五官语义分割、Guided Filter 全分辨率边缘精修。
enum MaskEngine {
    private static let maskCache = BoundedCache<String, CIImage>(capacity: 24)

    static func invalidateCache(for id: UUID) {
        maskCache.removeAll { $0.contains(id.uuidString) }
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

        if !m.refinements.isEmpty, let paint = Engine.refinementImage(m.refinements, extent: extent) {
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
        case .faceSkin, .eyes, .lips, .teeth, .hair:
            let key = "\(kind.rawValue)-\(m.id.uuidString)-\(Int(extent.width))x\(Int(extent.height))"
            if let hit = maskCache[key] { return hit }
            guard let out = portraitPartMask(kind: kind, source: analyzed, extent: extent) else { return nil }
            maskCache[key] = out
            return out
        }
    }

    // MARK: - 天空分割（Core ML 可选加速 + 零模型地平线/前景/顶部连通域混合算法）
    private static func skyMask(source: CIImage, extent: CGRect) -> CIImage? {
        let e = source.extent
        guard e.width > 8, e.height > 8 else { return nil }
        let side: CGFloat = 512
        let s = min(1, side / max(e.width, e.height))
        let small = s < 1 ? source.transformed(by: CGAffineTransform(scaleX: s, y: s)) : source
        guard let cg = Engine.ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: Engine.srgb) else { return nil }

        // 0) 如用户放了 Core ML 天空分割模型则优先使用
        if let mlOut = runCoreMLSkyIfPresent(cg: cg, targetExtent: extent) {
            return mlOut
        }

        let w = cg.width, h = cg.height
        guard w > 4, h > 4 else { return nil }

        // 1) 前景掩膜（用于剔除伸入天空的人、建筑、前景物）
        var fgBuffer = [UInt8](repeating: 0, count: w * h)
        let fgReq = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([fgReq])
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

        // 2) 地平线估计（若有则限制大致下界，无则用保守 0.72 下界）
        let horizonReq = VNDetectHorizonRequest()
        try? handler.perform([horizonReq])
        let minSkyRowFromBottom = 0.22 // 最低不过底部 22%（除非确认连续同色天空）

        // 3) 读取小图像素并从顶部多列采样种子色
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = Engine.srgb
        if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // CGContext 原点在左下，row 0 是图底，row h-1 是图顶。在 px 内存里（y-down），row 0 是图顶！
        var seeds: [(r: Double, g: Double, b: Double)] = []
        let topRows = max(2, h / 18)
        for y in 0..<topRows {
            for x in stride(from: 0, to: w, by: max(1, w / 24)) {
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
        let meanR = seeds.map(\.r).reduce(0, +) / Double(seeds.count)
        let meanG = seeds.map(\.g).reduce(0, +) / Double(seeds.count)
        let meanB = seeds.map(\.b).reduce(0, +) / Double(seeds.count)

        // 4) 结合垂直渐变和前景剔除从顶部 BFS 连通域扩张
        var skyScore = [UInt8](repeating: 0, count: w * h)
        var visited = [Bool](repeating: false, count: w * h)
        var queue = [Int]()
        queue.reserveCapacity(w * h / 2)

        func pixelMatches(_ idx: Int, row: Int) -> UInt8 {
            if fgBuffer[idx] > 135 { return 0 }
            let o = idx * 4
            let r = Double(px[o]) / 255, g = Double(px[o + 1]) / 255, b = Double(px[o + 2]) / 255
            let dr = r - meanR, dg = g - meanG, db = b - meanB
            // 允许天空纵向（地平线处）适度偏亮泛白
            let dist = (dr * dr + dg * dg + db * db).squareRoot()
            let rowFromTop = Double(row) / Double(h)
            let tol = 0.34 + 0.12 * (1.0 - rowFromTop)
            let blueBoost = (b >= r * 0.92 && b >= g * 0.85) ? 0.08 : 0.0
            let soft = min(max(1.0 - (dist - (tol * 0.45 + blueBoost)) / max(tol * 0.65, 0.05), 0.0), 1.0)
            let verticalFade = rowFromTop > (1.0 - minSkyRowFromBottom) ? max(0.0, (1.0 - rowFromTop) / minSkyRowFromBottom) : 1.0
            return UInt8(min(max(soft * verticalFade * 255.0, 0), 255))
        }

        for x in 0..<w {
            let idx = x
            let sc = pixelMatches(idx, row: 0)
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
            let neighbors = [
                cx > 0 ? cur - 1 : -1,
                cx + 1 < w ? cur + 1 : -1,
                cy > 0 ? cur - w : -1,
                cy + 1 < h ? cur + w : -1
            ]
            for nb in neighbors where nb >= 0 && !visited[nb] {
                visited[nb] = true
                let sc = pixelMatches(nb, row: nb / w)
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
        let modelURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos/Models/SkySegmentation.mlmodelc")
        guard FileManager.default.fileExists(atPath: modelURL.path),
              let model = try? MLModel(contentsOf: modelURL),
              let vnModel = try? VNCoreMLModel(for: model) else { return nil }
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        guard let obs = req.results?.first as? VNPixelBufferObservation else { return nil }
        var mask = CIImage(cvPixelBuffer: obs.pixelBuffer)
        let sx = targetExtent.width / max(mask.extent.width, 1)
        let sy = targetExtent.height / max(mask.extent.height, 1)
        mask = mask.transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY)
            .scaledBy(x: sx, y: sy)).cropped(to: targetExtent)
        return mask
    }

    // MARK: - 人物细粒度分部位分割 (faceSkin / eyes / lips / teeth / hair)
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
        if kind == .hair || kind == .faceSkin {
            requests.append(personReq)
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform(requests)
        guard let faces = landmarkReq.results, !faces.isEmpty else {
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

        for face in faces {
            let box = face.boundingBox
            guard let lm = face.landmarks else { continue }
            switch kind {
            case .eyes:
                ctx.setFillColor(gray: 1, alpha: 1)
                addPolygon(mappedPoints(lm.leftEye, in: box)); ctx.fillPath()
                addPolygon(mappedPoints(lm.rightEye, in: box)); ctx.fillPath()
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
                    // 补全前额弧顶（faceContour 只到两侧颧骨/太阳穴）
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
                // 减去眼、眉、嘴唇
                ctx.setFillColor(gray: 0, alpha: 1)
                for reg in [lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow, lm.outerLips] {
                    addPolygon(mappedPoints(reg, in: box)); ctx.fillPath()
                }
            case .hair:
                // 头部上方和左右延伸发区，稍后与 person segmentation 交叉并减去人脸
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

        guard let maskCG = ctx.makeImage() else { return nil }
        var mask = CIImage(cgImage: maskCG)
        let blurRadius: Double = (kind == .eyes || kind == .lips || kind == .teeth) ? 1.8 : 4.5
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

        // 头发与人物整体分割求交，确保边缘准确跟人物轮廓走
        if kind == .hair, let pb = personReq.results?.first?.pixelBuffer {
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
