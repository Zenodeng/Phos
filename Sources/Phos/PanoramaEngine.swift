import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision
import Accelerate
import simd

/// 全景拼接引擎（零第三方依赖：柱面 / 球面 / 平面投影 + 粗到精 NCC + MST 全局链配准 + 曝光增益均衡 + 多频段拉普拉斯金字塔融合 + 自动内接裁切）。
enum PanoramaEngine {

    struct StitchResult {
        let image: CGImage
        let usedFrames: Int
        let droppedFrames: Int
    }

    private struct GrayProxy {
        let w: Int
        let h: Int
        let luma: [Float]
        let alpha: [Float]
    }

    private struct PairMatch {
        let i: Int
        let j: Int
        /// Frame j relative to frame i in proxy coordinates (dx, dy)
        let dx: Double
        let dy: Double
        let ncc: Double
    }

    /// 端到端全景拼接主入口
    static func stitch(
        urls: [URL],
        projection: PanoramaProjection = .cylindrical,
        autoCrop: Bool = true,
        progress: (@Sendable (String) -> Void)? = nil
    ) -> StitchResult? {
        guard urls.count >= 2 else { return nil }
        progress?("解码 \(urls.count) 张全景素材…")

        var rawFrames: [CIImage] = []
        var focal35Samples: [Double] = []
        for u in urls {
            autoreleasepool {
                if let ci = Engine.decode(u) {
                    // 统一原点归零
                    let e = ci.extent
                    let normalized = (e.minX != 0 || e.minY != 0)
                        ? ci.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                        : ci
                    rawFrames.append(normalized)
                    if let f35 = readFocal35mm(url: u) { focal35Samples.append(f35) }
                }
            }
        }
        guard rawFrames.count >= 2 else { return nil }

        // 统一帧分辨率（以第 0 帧为基准尺寸）
        let frames0 = Engine.normalizedCanvas(rawFrames)
        let frameW = Int(frames0[0].extent.width.rounded())
        let frameH = Int(frames0[0].extent.height.rounded())
        guard frameW > 32, frameH > 32 else { return nil }

        // 估算像素焦距（无 EXIF 时默认 35mm 等效焦距）
        let focal35 = focal35Samples.isEmpty ? 35.0 : focal35Samples.sorted()[focal35Samples.count / 2]
        let focalPx = Double(max(frameW, frameH)) * max(12.0, min(focal35, 300.0)) / 36.0

        // Step 1: 投影预畸变（柱面 / 球面 / 平面直通）
        progress?("投影变换（\(projection.label)）…")
        var projected: [CIImage] = []
        projected.reserveCapacity(frames0.count)
        for f in frames0 {
            switch projection {
            case .planar:
                projected.append(f)
            case .cylindrical:
                projected.append(warpProjection(f, focalPx: focalPx, spherical: false) ?? f)
            case .spherical:
                projected.append(warpProjection(f, focalPx: focalPx, spherical: true) ?? f)
            }
        }

        // Step 2: 粗到精全对匹配（支持乱序、左→右、右→左与竖向全景）
        progress?("分析重叠区并配准帧顺序…")
        let coarseSide: CGFloat = 240
        let fineSide: CGFloat = 768
        let coarseScale = min(1.0, coarseSide / CGFloat(max(frameW, frameH)))
        let fineScale = min(1.0, fineSide / CGFloat(max(frameW, frameH)))

        let coarseProxies = projected.compactMap { makeGrayProxy($0, scale: coarseScale) }
        let fineProxies = projected.compactMap { makeGrayProxy($0, scale: fineScale) }
        guard coarseProxies.count == projected.count, fineProxies.count == projected.count else { return nil }

        var edges: [PairMatch] = []
        let n = projected.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                if let match = matchPair(coarseA: coarseProxies[i], coarseB: coarseProxies[j],
                                         fineA: fineProxies[i], fineB: fineProxies[j],
                                         coarseToFine: Double(fineScale / coarseScale)) {
                    if match.ncc >= 0.42 {
                        edges.append(PairMatch(i: i, j: j, dx: match.dx, dy: match.dy, ncc: match.ncc))
                    }
                }
            }
        }
        guard !edges.isEmpty else { return nil }

        // Step 3: 最大生成树（MST）连接最大连通分量，以中心帧为锚点降低累计误差
        edges.sort { $0.ncc > $1.ncc }
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let nx = parent[c]; parent[c] = r; c = nx }
            return r
        }
        var adj = [[(to: Int, dx: Double, dy: Double, ncc: Double)]](repeating: [], count: n)
        for e in edges {
            let ri = find(e.i), rj = find(e.j)
            if ri != rj {
                parent[ri] = rj
                // dx, dy 为 frame j 相对 frame i 的偏移（在 fineProxy 坐标系，Y 向下）
                adj[e.i].append((e.j, e.dx, e.dy, e.ncc))
                adj[e.j].append((e.i, -e.dx, -e.dy, e.ncc))
            }
        }

        // 找最大连通分量
        var compGroups: [Int: [Int]] = [:]
        for i in 0..<n { compGroups[find(i), default: []].append(i) }
        guard let bestComp = compGroups.values.max(by: { $0.count < $1.count }),
              bestComp.count >= 2 else { return nil }

        // 从分量内度数最高/最居中的节点做 BFS 链式坐标
        let root = bestComp.sorted()[bestComp.count / 2]
        var globalPos = [Int: (dx: Double, dy: Double)]()
        globalPos[root] = (0, 0)
        var queue = [root]
        var qi = 0
        while qi < queue.count {
            let u = queue[qi]; qi += 1
            let pu = globalPos[u]!
            for nb in adj[u] where globalPos[nb.to] == nil {
                globalPos[nb.to] = (pu.dx + nb.dx, pu.dy + nb.dy)
                queue.append(nb.to)
            }
        }

        let usedIndices = bestComp.sorted { (globalPos[$0]?.dx ?? 0) < (globalPos[$1]?.dx ?? 0) }
        let droppedCount = n - usedIndices.count
        guard usedIndices.count >= 2 else { return nil }

        // 换算到全分辨率像素偏移（注意 fineProxy 是 Y 向下，转为全图 Y 向下统一坐标系渲染）
        let invScale = 1.0 / Double(fineScale)
        var offsets: [(idx: Int, ox: Int, oy: Int)] = usedIndices.map { idx in
            let p = globalPos[idx]!
            return (idx, Int((p.dx * invScale).rounded()), Int((p.dy * invScale).rounded()))
        }
        let minOX = offsets.map(\.ox).min() ?? 0
        let minOY = offsets.map(\.oy).min() ?? 0
        offsets = offsets.map { ($0.idx, $0.ox - minOX, $0.oy - minOY) }

        let canvasW = (offsets.map { $0.ox + frameW }.max() ?? frameW)
        let canvasH = (offsets.map { $0.oy + frameH }.max() ?? frameH)
        // 控制极端巨幅上限（最长边上限 16384px，超限时按比例缩帧防爆内存）
        let maxPanoramaEdge = 16384.0
        let outScale = min(1.0, maxPanoramaEdge / Double(max(canvasW, canvasH)))
        let outW = max(2, Int((Double(canvasW) * outScale).rounded()))
        let outH = max(2, Int((Double(canvasH) * outScale).rounded()))
        let scaledFrameW = max(2, Int((Double(frameW) * outScale).rounded()))
        let scaledFrameH = max(2, Int((Double(frameH) * outScale).rounded()))

        // Step 4: 曝光增益补偿（按重叠区逐通道均衡亮度/白平衡微小漂移）
        progress?("均衡曝光与多频段拉普拉斯融合 \(usedIndices.count) 帧…")
        let gains = computeExposureGains(
            frames: usedIndices.map { projected[$0] },
            offsets: offsets.map { (Int((Double($0.ox) * Double(fineScale)).rounded()),
                                    Int((Double($0.oy) * Double(fineScale)).rounded())) },
            proxyScale: fineScale
        )

        // Step 5: 渲染所有有效帧到内存（RGBAf, Y-down）并用 4 级拉普拉斯金字塔多频段融合
        var frameBufs: [(ox: Int, oy: Int, w: Int, h: Int, data: [Float])] = []
        frameBufs.reserveCapacity(offsets.count)
        for (k, item) in offsets.enumerated() {
            let src = projected[item.idx]
            let g = gains[k]
            let scaled = outScale < 0.999
                ? src.transformed(by: CGAffineTransform(scaleX: outScale, y: outScale))
                : src
            let fw = scaledFrameW, fh = scaledFrameH
            var buf = [Float](repeating: 0, count: fw * fh * 4)
            let bRect = CGRect(x: scaled.extent.minX, y: scaled.extent.minY,
                               width: CGFloat(fw), height: CGFloat(fh))
            Engine.ctx.render(scaled, toBitmap: &buf, rowBytes: fw * 16, bounds: bRect,
                              format: .RGBAf, colorSpace: Engine.srgb)
            // 应用曝光增益补偿
            if abs(g.x - 1) > 0.002 || abs(g.y - 1) > 0.002 || abs(g.z - 1) > 0.002 {
                for p in 0..<(fw * fh) where buf[p * 4 + 3] > 0.01 {
                    buf[p * 4]     *= g.x
                    buf[p * 4 + 1] *= g.y
                    buf[p * 4 + 2] *= g.z
                }
            }
            let sox = Int((Double(item.ox) * outScale).rounded())
            let soy = Int((Double(item.oy) * outScale).rounded())
            frameBufs.append((sox, soy, fw, fh, buf))
        }

        // 多频段（4 层高斯/拉普拉斯金字塔）Voronoi 接缝融合
        guard var stitched = multiBandBlend(frames: frameBufs, outW: outW, outH: outH) else { return nil }

        // Step 6: 自动最大内接矩形裁切（消除柱面/抖动边缘黑边）
        var cropX = 0, cropY = 0, cropW = outW, cropH = outH
        if autoCrop {
            progress?("自动裁切全景黑边…")
            if let rect = largestValidRect(rgba: stitched, w: outW, h: outH) {
                cropX = rect.x; cropY = rect.y; cropW = rect.w; cropH = rect.h
            }
        }

        // 打包输出 16-bit RGBA CGImage（支持 sRGB 全动态范围）
        let finalCG = makeCGImage16(from: &stitched, fullW: outW,
                                    cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH)
        guard let finalCG else { return nil }
        return StitchResult(image: finalCG, usedFrames: usedIndices.count, droppedFrames: droppedCount)
    }

    // MARK: - 柱面 / 球面投影预畸变

    private static func warpProjection(_ img: CIImage, focalPx: Double, spherical: Bool) -> CIImage? {
        let e = img.extent
        let w = Int(e.width.rounded()), h = Int(e.height.rounded())
        guard w > 8, h > 8 else { return nil }

        var src = [Float](repeating: 0, count: w * h * 4)
        Engine.ctx.render(img, toBitmap: &src, rowBytes: w * 16, bounds: e,
                          format: .RGBAf, colorSpace: Engine.srgb)

        var dst = [Float](repeating: 0, count: w * h * 4)
        let cx = Double(w) * 0.5, cy = Double(h) * 0.5
        let f = max(Double(min(w, h)) * 0.45, focalPx)

        DispatchQueue.concurrentPerform(iterations: h) { y in
            let yd = Double(y) - cy
            let phi = spherical ? (yd / f) : 0.0
            let cosPhi = spherical ? cos(phi) : 1.0
            let sinPhi = spherical ? sin(phi) : 0.0
            for x in 0..<w {
                let xd = Double(x) - cx
                let theta = xd / f
                let cosT = cos(theta)
                if cosT <= 0.05 { continue }
                let sx: Double
                let sy: Double
                if spherical {
                    let z = cosPhi * cosT
                    if z <= 0.05 { continue }
                    sx = f * (cosPhi * sin(theta) / z) + cx
                    sy = f * (sinPhi / z) + cy
                } else {
                    sx = f * tan(theta) + cx
                    sy = (yd / cosT) + cy
                }
                if sx < 0 || sx >= Double(w - 1) || sy < 0 || sy >= Double(h - 1) { continue }
                let x0 = Int(sx), y0 = Int(sy)
                let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                let o00 = (y0 * w + x0) * 4
                let o10 = o00 + 4
                let o01 = ((y0 + 1) * w + x0) * 4
                let o11 = o01 + 4
                let w00 = (1 - fx) * (1 - fy)
                let w10 = fx * (1 - fy)
                let w01 = (1 - fx) * fy
                let w11 = fx * fy
                let dOff = (y * w + x) * 4
                for c in 0..<4 {
                    dst[dOff + c] = src[o00 + c] * w00 + src[o10 + c] * w10
                                  + src[o01 + c] * w01 + src[o11 + c] * w11
                }
            }
        }
        let data = dst.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 16,
                       size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: Engine.srgb)
    }

    // MARK: - 粗到精 NCC 配准

    private static func makeGrayProxy(_ img: CIImage, scale: CGFloat) -> GrayProxy? {
        let scaled = scale < 0.999 ? img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : img
        let e = scaled.extent
        let w = Int(e.width.rounded()), h = Int(e.height.rounded())
        guard w > 8, h > 8 else { return nil }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        Engine.ctx.render(scaled, toBitmap: &rgba, rowBytes: w * 16, bounds: e,
                          format: .RGBAf, colorSpace: Engine.srgb)
        var luma = [Float](repeating: 0, count: w * h)
        var alpha = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            luma[i] = 0.2126 * rgba[i * 4] + 0.7152 * rgba[i * 4 + 1] + 0.0722 * rgba[i * 4 + 2]
            alpha[i] = rgba[i * 4 + 3]
        }
        return GrayProxy(w: w, h: h, luma: luma, alpha: alpha)
    }

    private static func matchPair(
        coarseA: GrayProxy, coarseB: GrayProxy,
        fineA: GrayProxy, fineB: GrayProxy,
        coarseToFine: Double
    ) -> (dx: Double, dy: Double, ncc: Double)? {
        let cw = coarseA.w, ch = coarseA.h
        // 搜索范围：支持水平全景（大 dx 小 dy）与垂直全景（小 dx 大 dy）
        let maxDX = Int(Double(cw) * 0.80)
        let maxDY = Int(Double(ch) * 0.80)
        let step = max(2, min(cw, ch) / 48)

        var bestScore = -1.0
        var bestDX = 0
        var bestDY = 0

        // 1) 粗网格搜索（水平带 + 垂直带组合，避免 O(N^4)）
        func scanRange(dxRange: StrideThrough<Int>, dyRange: StrideThrough<Int>, sampleStep: Int) {
            for dy in dyRange {
                for dx in dxRange {
                    // 跳过几乎零重叠的位移
                    let ovW = cw - abs(dx), ovH = ch - abs(dy)
                    if ovW < cw / 6 || ovH < ch / 6 { continue }
                    let score = evalNCC(coarseA, coarseB, dx: dx, dy: dy, stride: sampleStep)
                    if score > bestScore {
                        bestScore = score
                        bestDX = dx; bestDY = dy
                    }
                }
            }
        }
        let hBand = Int(Double(ch) * 0.28)
        let vBand = Int(Double(cw) * 0.28)
        scanRange(dxRange: stride(from: -maxDX, through: maxDX, by: step),
                  dyRange: stride(from: -hBand, through: hBand, by: step),
                  sampleStep: 2)
        scanRange(dxRange: stride(from: -vBand, through: vBand, by: step),
                  dyRange: stride(from: -maxDY, through: maxDY, by: step),
                  sampleStep: 2)

        guard bestScore > 0.30 else { return nil }

        // 2) 粗网格局部 1px 精化
        let r0 = step
        var cdx = bestDX, cdy = bestDY
        for dy in (bestDY - r0)...(bestDY + r0) {
            for dx in (bestDX - r0)...(bestDX + r0) {
                let s = evalNCC(coarseA, coarseB, dx: dx, dy: dy, stride: 1)
                if s > bestScore { bestScore = s; cdx = dx; cdy = dy }
            }
        }

        // 3) 细代理图局部精化（半径 ±ceil(coarseToFine * 1.8)）
        let initFX = Int((Double(cdx) * coarseToFine).rounded())
        let initFY = Int((Double(cdy) * coarseToFine).rounded())
        let rad = max(4, Int(ceil(coarseToFine * 1.8)))

        var fBest = -1.0
        var fdx = initFX, fdy = initFY
        // 先步长 2 扫一轮，再步长 1 精确落地
        for dy in stride(from: initFY - rad, through: initFY + rad, by: 2) {
            for dx in stride(from: initFX - rad, through: initFX + rad, by: 2) {
                let s = evalNCC(fineA, fineB, dx: dx, dy: dy, stride: 3)
                if s > fBest { fBest = s; fdx = dx; fdy = dy }
            }
        }
        let fcx = fdx, fcy = fdy
        fBest = -1.0
        for dy in (fcy - 2)...(fcy + 2) {
            for dx in (fcx - 2)...(fcx + 2) {
                let s = evalNCC(fineA, fineB, dx: dx, dy: dy, stride: 2)
                if s > fBest { fBest = s; fdx = dx; fdy = dy }
            }
        }
        guard fBest > 0.40 else { return nil }

        // 4) 抛物线亚像素拟合
        let sxL = evalNCC(fineA, fineB, dx: fdx - 1, dy: fdy, stride: 2)
        let sxR = evalNCC(fineA, fineB, dx: fdx + 1, dy: fdy, stride: 2)
        let syU = evalNCC(fineA, fineB, dx: fdx, dy: fdy - 1, stride: 2)
        let syD = evalNCC(fineA, fineB, dx: fdx, dy: fdy + 1, stride: 2)
        let subX = parabolicOffset(sxL, fBest, sxR)
        let subY = parabolicOffset(syU, fBest, syD)
        return (Double(fdx) + subX, Double(fdy) + subY, fBest)
    }

    private static func parabolicOffset(_ left: Double, _ center: Double, _ right: Double) -> Double {
        let denom = 2.0 * (left - 2.0 * center + right)
        guard abs(denom) > 1e-6 else { return 0 }
        return min(max((left - right) / denom, -0.5), 0.5)
    }

    private static func evalNCC(_ a: GrayProxy, _ b: GrayProxy, dx: Int, dy: Int, stride st: Int) -> Double {
        // b 放在 (dx, dy)，所以重叠区是 a 上的 [x0, x1) × [y0, y1)
        let x0 = max(0, dx), x1 = min(a.w, b.w + dx)
        let y0 = max(0, dy), y1 = min(a.h, b.h + dy)
        guard x1 - x0 > 12, y1 - y0 > 12 else { return -1 }

        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
        var count = 0
        var y = y0
        while y < y1 {
            let rowA = y * a.w
            let rowB = (y - dy) * b.w
            var x = x0
            while x < x1 {
                let ia = rowA + x
                let ib = rowB + (x - dx)
                if a.alpha[ia] > 0.9 && b.alpha[ib] > 0.9 {
                    let va = Double(a.luma[ia])
                    let vb = Double(b.luma[ib])
                    sumA += va; sumB += vb
                    sumAA += va * va; sumBB += vb * vb
                    sumAB += va * vb
                    count += 1
                }
                x += st
            }
            y += st
        }
        guard count > 80 else { return -1 }
        let n = Double(count)
        let num = n * sumAB - sumA * sumB
        let denA = n * sumAA - sumA * sumA
        let denB = n * sumBB - sumB * sumB
        let denom = sqrt(max(denA, 0) * max(denB, 0))
        return denom > 1e-6 ? num / denom : -1
    }

    // MARK: - 曝光增益补偿

    private static func computeExposureGains(
        frames: [CIImage],
        offsets: [(ox: Int, oy: Int)],
        proxyScale: CGFloat
    ) -> [SIMD3<Float>] {
        let n = frames.count
        var gains = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: n)
        guard n >= 2 else { return gains }

        // 渲染轻量 RGB 代理
        var bufs: [(w: Int, h: Int, data: [Float])] = []
        for f in frames {
            let scaled = proxyScale < 0.999 ? f.transformed(by: CGAffineTransform(scaleX: proxyScale, y: proxyScale)) : f
            let e = scaled.extent
            let w = Int(e.width.rounded()), h = Int(e.height.rounded())
            var buf = [Float](repeating: 0, count: w * h * 4)
            Engine.ctx.render(scaled, toBitmap: &buf, rowBytes: w * 16, bounds: e,
                              format: .RGBAf, colorSpace: Engine.srgb)
            bufs.append((w, h, buf))
        }

        // 对数域迭代求相邻重叠区亮度比（Gauss-Seidel 12 轮即可收敛）
        var logG = [SIMD3<Double>](repeating: .zero, count: n)
        var pairRatios: [(i: Int, j: Int, logRatio: SIMD3<Double>)] = []
        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = offsets[j].ox - offsets[i].ox
                let dy = offsets[j].oy - offsets[i].oy
                let a = bufs[i], b = bufs[j]
                let x0 = max(0, dx), x1 = min(a.w, b.w + dx)
                let y0 = max(0, dy), y1 = min(a.h, b.h + dy)
                guard x1 - x0 > 16, y1 - y0 > 16 else { continue }
                var sA = SIMD3<Double>.zero, sB = SIMD3<Double>.zero
                var cnt = 0
                for y in stride(from: y0, to: y1, by: 3) {
                    for x in stride(from: x0, to: x1, by: 3) {
                        let ia = (y * a.w + x) * 4
                        let ib = ((y - dy) * b.w + (x - dx)) * 4
                        if a.data[ia + 3] > 0.95 && b.data[ib + 3] > 0.95 {
                            let ra = Double(a.data[ia]), ga = Double(a.data[ia + 1]), ba = Double(a.data[ia + 2])
                            let rb = Double(b.data[ib]), gb = Double(b.data[ib + 1]), bb = Double(b.data[ib + 2])
                            // 排除过曝和死黑像素，避免高光截断污染增益估计
                            if ra > 0.03 && ra < 0.92 && rb > 0.03 && rb < 0.92 &&
                               ga > 0.03 && ga < 0.92 && gb > 0.03 && gb < 0.92 {
                                sA += SIMD3(ra, ga, ba)
                                sB += SIMD3(rb, gb, bb)
                                cnt += 1
                            }
                        }
                    }
                }
                if cnt > 60 {
                    let ratio = SIMD3(
                        log(max(sA.x, 1e-4) / max(sB.x, 1e-4)),
                        log(max(sA.y, 1e-4) / max(sB.y, 1e-4)),
                        log(max(sA.z, 1e-4) / max(sB.z, 1e-4))
                    )
                    pairRatios.append((i, j, ratio))
                }
            }
        }
        guard !pairRatios.isEmpty else { return gains }

        for _ in 0..<14 {
            var acc = [SIMD3<Double>](repeating: .zero, count: n)
            var deg = [Double](repeating: 0.15, count: n) // 正则项拉向 0（即 gain = 1）
            for pr in pairRatios {
                // 目标：logG[j] - logG[i] ≈ logRatio (使 g_j * B ≈ g_i * A)
                acc[pr.i] += logG[pr.j] - pr.logRatio
                deg[pr.i] += 1
                acc[pr.j] += logG[pr.i] + pr.logRatio
                deg[pr.j] += 1
            }
            var mean = SIMD3<Double>.zero
            for i in 0..<n {
                logG[i] = acc[i] / deg[i]
                mean += logG[i]
            }
            mean /= Double(n)
            for i in 0..<n { logG[i] -= mean }
        }
        for i in 0..<n {
            gains[i] = SIMD3(
                Float(min(max(exp(logG[i].x), 0.72), 1.38)),
                Float(min(max(exp(logG[i].y), 0.72), 1.38)),
                Float(min(max(exp(logG[i].z), 0.72), 1.38))
            )
        }
        return gains
    }

    // MARK: - 4 层拉普拉斯金字塔多频段融合

    private static func multiBandBlend(
        frames: [(ox: Int, oy: Int, w: Int, h: Int, data: [Float])],
        outW: Int, outH: Int
    ) -> [Float]? {
        let pxCount = outW * outH
        let n = frames.count

        // 1) 为每个像素分配最近帧中心（Voronoi 最佳接缝）并统计有效覆盖
        var owner = [Int16](repeating: -1, count: pxCount)
        var bestDist = [Float](repeating: .greatestFiniteMagnitude, count: pxCount)
        var coverage = [Float](repeating: 0, count: pxCount)

        for k in 0..<n {
            let f = frames[k]
            let fcx = Float(f.ox) + Float(f.w) * 0.5
            let fcy = Float(f.oy) + Float(f.h) * 0.5
            let invW2 = 1.0 / max(Float(f.w * f.w) * 0.25, 1)
            let invH2 = 1.0 / max(Float(f.h * f.h) * 0.25, 1)
            for y in 0..<f.h {
                let gy = f.oy + y
                if gy < 0 || gy >= outH { continue }
                let dy = Float(gy) - fcy
                let dy2 = dy * dy * invH2
                let gRow = gy * outW
                let fRow = y * f.w
                for x in 0..<f.w {
                    let gx = f.ox + x
                    if gx < 0 || gx >= outW { continue }
                    let a = f.data[(fRow + x) * 4 + 3]
                    if a <= 0.5 { continue }
                    let gi = gRow + gx
                    coverage[gi] = 1
                    let dx = Float(gx) - fcx
                    let dist = dx * dx * invW2 + dy2
                    if dist < bestDist[gi] {
                        bestDist[gi] = dist
                        owner[gi] = Int16(k)
                    }
                }
            }
        }

        // 2) 分层拉普拉斯多频段融合（低频宽过渡消暗角，高频窄过渡消重影）
        let levels = 4
        var accLevels = (0..<levels).map { lv -> (w: Int, h: Int, rgb: [Float], wt: [Float]) in
            let lw = max(1, outW >> lv), lh = max(1, outH >> lv)
            return (lw, lh, [Float](repeating: 0, count: lw * lh * 3), [Float](repeating: 0, count: lw * lh))
        }

        for k in 0..<n {
            let f = frames[k]
            // 仅分配当前帧在全局画布的局部 ROI（加 32px 边界余量），内存极省！
            let pad = 32
            let rx0 = max(0, f.ox - pad)
            let ry0 = max(0, f.oy - pad)
            let rx1 = min(outW, f.ox + f.w + pad)
            let ry1 = min(outH, f.oy + f.h + pad)
            let rw = rx1 - rx0, rh = ry1 - ry0
            guard rw > 2, rh > 2 else { continue }

            var imgBuf = [Float](repeating: 0, count: rw * rh * 3)
            var maskBuf = [Float](repeating: 0, count: rw * rh)
            var validBuf = [Float](repeating: 0, count: rw * rh)

            for y in 0..<rh {
                let gy = ry0 + y
                let fy = gy - f.oy
                for x in 0..<rw {
                    let gx = rx0 + x
                    let fx = gx - f.ox
                    let li = y * rw + x
                    if fx >= 0 && fx < f.w && fy >= 0 && fy < f.h {
                        let fi = (fy * f.w + fx) * 4
                        let a = f.data[fi + 3]
                        if a > 0.5 {
                            imgBuf[li * 3]     = f.data[fi]
                            imgBuf[li * 3 + 1] = f.data[fi + 1]
                            imgBuf[li * 3 + 2] = f.data[fi + 2]
                            validBuf[li] = 1
                            maskBuf[li] = (owner[gy * outW + gx] == Int16(k)) ? 1 : 0
                        }
                    }
                }
            }
            // 将无效像素用最近有效边向外延展填充（避免高斯下采样把 0 黑边卷进金字塔！）
            bleedEdges(&imgBuf, valid: validBuf, w: rw, h: rh, passes: 16)

            // 构建当前帧的 4 层图像高斯金字塔与权重高斯金字塔
            var curImg = imgBuf, curMask = maskBuf, curValid = validBuf
            var cw = rw, ch = rh
            for lv in 0..<levels {
                let blurredImg = gaussianBlurRGB(curImg, w: cw, h: ch, radius: lv == 0 ? 3 : 5)
                let blurredMask = gaussianBlurGray(curMask, w: cw, h: ch, radius: lv == 0 ? 3 : 7)

                // 本层带通：最后一层存低频残差，其余层存高频拉普拉斯 (cur - blurred)
                let band = (lv == levels - 1) ? curImg : zipSub(curImg, blurredImg)
                let gScale = 1 << lv
                let gox = rx0 / gScale, goy = ry0 / gScale
                let lw = accLevels[lv].w, lh = accLevels[lv].h
                for y in 0..<ch {
                    let gy = goy + y
                    if gy < 0 || gy >= lh { continue }
                    for x in 0..<cw {
                        let gx = gox + x
                        if gx < 0 || gx >= lw { continue }
                        let li = y * cw + x
                        let wVal = blurredMask[li] * curValid[li]
                        if wVal <= 1e-5 { continue }
                        let gi = gy * lw + gx
                        accLevels[lv].rgb[gi * 3]     += band[li * 3] * wVal
                        accLevels[lv].rgb[gi * 3 + 1] += band[li * 3 + 1] * wVal
                        accLevels[lv].rgb[gi * 3 + 2] += band[li * 3 + 2] * wVal
                        accLevels[lv].wt[gi]          += wVal
                    }
                }

                if lv < levels - 1 {
                    let nw = max(1, cw / 2), nh = max(1, ch / 2)
                    curImg = downsampleRGB(blurredImg, w: cw, h: ch, nw: nw, nh: nh)
                    curMask = downsampleGray(blurredMask, w: cw, h: ch, nw: nw, nh: nh)
                    curValid = downsampleGray(curValid, w: cw, h: ch, nw: nw, nh: nh)
                    cw = nw; ch = nh
                }
            }
        }

        // 3) 自顶向下重建拉普拉斯金字塔
        var recon: [Float] = []
        for lv in stride(from: levels - 1, through: 0, by: -1) {
            let lw = accLevels[lv].w, lh = accLevels[lv].h
            var band = [Float](repeating: 0, count: lw * lh * 3)
            for i in 0..<(lw * lh) {
                let wt = accLevels[lv].wt[i]
                if wt > 1e-5 {
                    band[i * 3]     = accLevels[lv].rgb[i * 3] / wt
                    band[i * 3 + 1] = accLevels[lv].rgb[i * 3 + 1] / wt
                    band[i * 3 + 2] = accLevels[lv].rgb[i * 3 + 2] / wt
                }
            }
            if recon.isEmpty {
                recon = band
            } else {
                let prevW = accLevels[lv + 1].w, prevH = accLevels[lv + 1].h
                let up = upsampleRGB(recon, w: prevW, h: prevH, nw: lw, nh: lh)
                for i in 0..<band.count { band[i] += up[i] }
                recon = band
            }
        }

        var rgba = [Float](repeating: 0, count: pxCount * 4)
        for i in 0..<pxCount {
            if coverage[i] > 0.5 {
                rgba[i * 4]     = min(max(recon[i * 3], 0), 1)
                rgba[i * 4 + 1] = min(max(recon[i * 3 + 1], 0), 1)
                rgba[i * 4 + 2] = min(max(recon[i * 3 + 2], 0), 1)
                rgba[i * 4 + 3] = 1
            }
        }
        return rgba
    }

    // MARK: - 金字塔与滤波辅助

    private static func bleedEdges(_ rgb: inout [Float], valid: [Float], w: Int, h: Int, passes: Int) {
        var mask = valid
        for _ in 0..<passes {
            var nextRGB = rgb
            var nextMask = mask
            var changed = false
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    if mask[i] > 0.5 { continue }
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0, c: Float = 0
                    if x > 0 && mask[i - 1] > 0.5 { let j = (i - 1) * 3; sr += rgb[j]; sg += rgb[j+1]; sb += rgb[j+2]; c += 1 }
                    if x + 1 < w && mask[i + 1] > 0.5 { let j = (i + 1) * 3; sr += rgb[j]; sg += rgb[j+1]; sb += rgb[j+2]; c += 1 }
                    if y > 0 && mask[i - w] > 0.5 { let j = (i - w) * 3; sr += rgb[j]; sg += rgb[j+1]; sb += rgb[j+2]; c += 1 }
                    if y + 1 < h && mask[i + w] > 0.5 { let j = (i + w) * 3; sr += rgb[j]; sg += rgb[j+1]; sb += rgb[j+2]; c += 1 }
                    if c > 0 {
                        nextRGB[i * 3] = sr / c; nextRGB[i * 3 + 1] = sg / c; nextRGB[i * 3 + 2] = sb / c
                        nextMask[i] = 1; changed = true
                    }
                }
            }
            rgb = nextRGB; mask = nextMask
            if !changed { break }
        }
    }

    private static func zipSub(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { out[i] = a[i] - b[i] }
        return out
    }

    private static func gaussianBlurGray(_ src: [Float], w: Int, h: Int, radius: Int) -> [Float] {
        var out = src
        Engine.boxBlur(&out, w: w, h: h, radius: radius)
        Engine.boxBlur(&out, w: w, h: h, radius: radius)
        return out
    }

    private static func gaussianBlurRGB(_ src: [Float], w: Int, h: Int, radius: Int) -> [Float] {
        let px = w * h
        var r = [Float](repeating: 0, count: px)
        var g = [Float](repeating: 0, count: px)
        var b = [Float](repeating: 0, count: px)
        for i in 0..<px { r[i] = src[i * 3]; g[i] = src[i * 3 + 1]; b[i] = src[i * 3 + 2] }
        Engine.boxBlur(&r, w: w, h: h, radius: radius); Engine.boxBlur(&r, w: w, h: h, radius: radius)
        Engine.boxBlur(&g, w: w, h: h, radius: radius); Engine.boxBlur(&g, w: w, h: h, radius: radius)
        Engine.boxBlur(&b, w: w, h: h, radius: radius); Engine.boxBlur(&b, w: w, h: h, radius: radius)
        var out = [Float](repeating: 0, count: px * 3)
        for i in 0..<px { out[i * 3] = r[i]; out[i * 3 + 1] = g[i]; out[i * 3 + 2] = b[i] }
        return out
    }

    private static func downsampleGray(_ src: [Float], w: Int, h: Int, nw: Int, nh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: nw * nh)
        for y in 0..<nh {
            let sy0 = min(y * 2, h - 1), sy1 = min(y * 2 + 1, h - 1)
            for x in 0..<nw {
                let sx0 = min(x * 2, w - 1), sx1 = min(x * 2 + 1, w - 1)
                out[y * nw + x] = 0.25 * (src[sy0 * w + sx0] + src[sy0 * w + sx1]
                                        + src[sy1 * w + sx0] + src[sy1 * w + sx1])
            }
        }
        return out
    }

    private static func downsampleRGB(_ src: [Float], w: Int, h: Int, nw: Int, nh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: nw * nh * 3)
        for y in 0..<nh {
            let sy0 = min(y * 2, h - 1), sy1 = min(y * 2 + 1, h - 1)
            for x in 0..<nw {
                let sx0 = min(x * 2, w - 1), sx1 = min(x * 2 + 1, w - 1)
                let i00 = (sy0 * w + sx0) * 3, i10 = (sy0 * w + sx1) * 3
                let i01 = (sy1 * w + sx0) * 3, i11 = (sy1 * w + sx1) * 3
                let o = (y * nw + x) * 3
                for c in 0..<3 { out[o + c] = 0.25 * (src[i00 + c] + src[i10 + c] + src[i01 + c] + src[i11 + c]) }
            }
        }
        return out
    }

    private static func upsampleRGB(_ src: [Float], w: Int, h: Int, nw: Int, nh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: nw * nh * 3)
        let sxScale = Float(max(w - 1, 1)) / Float(max(nw - 1, 1))
        let syScale = Float(max(h - 1, 1)) / Float(max(nh - 1, 1))
        for y in 0..<nh {
            let fy = Float(y) * syScale
            let y0 = min(Int(fy), h - 1), y1 = min(y0 + 1, h - 1)
            let wy = fy - Float(y0)
            for x in 0..<nw {
                let fx = Float(x) * sxScale
                let x0 = min(Int(fx), w - 1), x1 = min(x0 + 1, w - 1)
                let wx = fx - Float(x0)
                let i00 = (y0 * w + x0) * 3, i10 = (y0 * w + x1) * 3
                let i01 = (y1 * w + x0) * 3, i11 = (y1 * w + x1) * 3
                let o = (y * nw + x) * 3
                let w00 = (1 - wx) * (1 - wy), w10 = wx * (1 - wy)
                let w01 = (1 - wx) * wy,       w11 = wx * wy
                for c in 0..<3 {
                    out[o + c] = src[i00 + c] * w00 + src[i10 + c] * w10
                               + src[i01 + c] * w01 + src[i11 + c] * w11
                }
            }
        }
        return out
    }

    // MARK: - 最大有效内接矩形自动裁切（O(W*H) 直方图栈算法）

    private static func largestValidRect(rgba: [Float], w: Int, h: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        let step = max(1, max(w, h) / 512)
        let sw = max(2, w / step), sh = max(2, h / step)
        var heights = [Int](repeating: 0, count: sw)
        var bestArea = 0
        var best = (x: 0, y: 0, w: sw, h: sh)

        for y in 0..<sh {
            let gy0 = y * step, gy1 = min(h, gy0 + step)
            for x in 0..<sw {
                let gx0 = x * step, gx1 = min(w, gx0 + step)
                // 仅当整个降采样格都有效时才计入，保证裁切后绝对无黑边
                var ok = true
                outer: for py in gy0..<gy1 {
                    for px in gx0..<gx1 {
                        if rgba[(py * w + px) * 4 + 3] < 0.99 { ok = false; break outer }
                    }
                }
                heights[x] = ok ? (heights[x] + 1) : 0
            }
            // 单调栈求当前行最大全 1 矩形
            var stack: [Int] = []
            for i in 0...sw {
                let curH = (i < sw) ? heights[i] : 0
                while let top = stack.last, heights[top] > curH {
                    stack.removeLast()
                    let rectH = heights[top]
                    let left = stack.last.map { $0 + 1 } ?? 0
                    let rectW = i - left
                    let area = rectW * rectH
                    if area > bestArea {
                        bestArea = area
                        best = (left, y - rectH + 1, rectW, rectH)
                    }
                }
                stack.append(i)
            }
        }
        guard bestArea > 16 else { return nil }
        let rx = min(w - 2, max(0, best.x * step + 1))
        let ry = min(h - 2, max(0, best.y * step + 1))
        let rw = min(w - rx, max(2, best.w * step - 2))
        let rh = min(h - ry, max(2, best.h * step - 2))
        return (rx, ry, rw, rh)
    }

    private static func makeCGImage16(from rgba: inout [Float], fullW: Int,
                                      cropX: Int, cropY: Int, cropW: Int, cropH: Int) -> CGImage? {
        var out16 = [UInt16](repeating: 0, count: cropW * cropH * 4)
        for y in 0..<cropH {
            let sy = cropY + y
            for x in 0..<cropW {
                let sx = cropX + x
                let sOff = (sy * fullW + sx) * 4
                let dOff = (y * cropW + x) * 4
                out16[dOff]     = UInt16(min(max(rgba[sOff],     0), 1) * 65535.0)
                out16[dOff + 1] = UInt16(min(max(rgba[sOff + 1], 0), 1) * 65535.0)
                out16[dOff + 2] = UInt16(min(max(rgba[sOff + 2], 0), 1) * 65535.0)
                out16[dOff + 3] = 65535
            }
        }
        let data = out16.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        return CGImage(
            width: cropW, height: cropH,
            bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: cropW * 8,
            space: Engine.srgb,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func readFocal35mm(url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return nil
        }
        if let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double, f35 > 5 {
            return f35
        }
        if let f = exif[kCGImagePropertyExifFocalLength as String] as? Double, f > 5 {
            return f
        }
        return nil
    }
}
