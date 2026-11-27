import Foundation
import CoreImage
import CoreGraphics
import SwiftUI
import simd

/// Guided Upright（2–4 条参考线透视校正）纯数学单应性求解与画布交互叠加层。
/// 坐标系约定：源图与输出图均为 Core Image 规范（左下为原点，Y 向上，像素单位）。
enum GuidedUprightEngine {

    struct Solution: Equatable {
        /// 源图定向后像素坐标 → 最终输出像素坐标（含平移与内接裁切）
        let homography: simd_double3x3
        /// 最终输出像素坐标 → 源图定向后像素坐标
        let inverseHomography: simd_double3x3
        /// 透视变换后四角（供 CIPerspectiveTransform 使用）
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
        /// 内接无黑边裁切矩形（位于透视后坐标系）
        let cropRect: CGRect
        /// 最终输出画布尺寸（原点归零）
        let outputSize: CGSize
        let sourceSize: CGSize

        func mapSourceNormalizedToOutput(_ n: CGPoint) -> CGPoint {
            let sx = n.x * sourceSize.width
            let sy = n.y * sourceSize.height
            let q = homography * SIMD3<Double>(Double(sx), Double(sy), 1.0)
            guard abs(q.z) > 1e-8 else { return n }
            let ox = q.x / q.z
            let oy = q.y / q.z
            return CGPoint(
                x: ox / max(Double(outputSize.width), 1.0),
                y: oy / max(Double(outputSize.height), 1.0)
            )
        }

        func mapOutputNormalizedToSource(_ n: CGPoint) -> CGPoint {
            let ox = n.x * outputSize.width
            let oy = n.y * outputSize.height
            let q = inverseHomography * SIMD3<Double>(Double(ox), Double(oy), 1.0)
            guard abs(q.z) > 1e-8 else { return n }
            let sx = q.x / q.z
            let sy = q.y / q.z
            return CGPoint(
                x: min(max(sx / max(Double(sourceSize.width), 1.0), 0), 1),
                y: min(max(sy / max(Double(sourceSize.height), 1.0), 0), 1)
            )
        }
    }

    private struct Seg {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var mid: SIMD2<Double> { (a + b) * 0.5 }
        var dir: SIMD2<Double> { b - a }
        var len: Double { simd_length(b - a) }
        var isHorizontal: Bool { abs(dir.x) >= abs(dir.y) }
        /// 齐次直线方程 l · [x, y, 1]^T = 0
        var line: SIMD3<Double> {
            simd_cross(SIMD3<Double>(a.x, a.y, 1.0), SIMD3<Double>(b.x, b.y, 1.0))
        }
    }

    /// 根据 2–4 条参考线求解透视校正单应矩阵。不足 2 条有效参考线时返回 nil。
    static func solve(guides: [UprightGuide], extent: CGRect, constrainCrop: Bool = true) -> Solution? {
        let W = Double(extent.width), H = Double(extent.height)
        guard W > 8, H > 8, guides.count >= 2 else { return nil }
        let cx = W * 0.5, cy = H * 0.5
        let minLen = max(8.0, min(W, H) * 0.025)

        var verticals: [Seg] = []
        var horizontals: [Seg] = []
        for g in guides.prefix(4) {
            let a = SIMD2<Double>(g.x0 * W - cx, g.y0 * H - cy)
            let b = SIMD2<Double>(g.x1 * W - cx, g.y1 * H - cy)
            let seg = Seg(a: a, b: b)
            guard seg.len >= minLen else { continue }
            if seg.isHorizontal {
                // 统一指向 +X
                let ordered = seg.a.x <= seg.b.x ? seg : Seg(a: seg.b, b: seg.a)
                horizontals.append(ordered)
            } else {
                // 统一指向 +Y
                let ordered = seg.a.y <= seg.b.y ? seg : Seg(a: seg.b, b: seg.a)
                verticals.append(ordered)
            }
        }

        // 超过 2 条同类参考线时保留间距最大的两条（最稳健）
        if verticals.count > 2 {
            verticals.sort { $0.mid.x < $1.mid.x }
            verticals = [verticals.first!, verticals.last!]
        }
        if horizontals.count > 2 {
            horizontals.sort { $0.mid.y < $1.mid.y }
            horizontals = [horizontals.first!, horizontals.last!]
        }
        guard verticals.count + horizontals.count >= 2 else { return nil }

        // Step 1: 求解无穷远直线 l = (l1, l2, 1)^T 使平行组灭点送回无穷远
        var l1 = 0.0, l2 = 0.0
        let vVP: SIMD3<Double>? = verticals.count == 2 ? vanishingPoint(verticals[0], verticals[1]) : nil
        let hVP: SIMD3<Double>? = horizontals.count == 2 ? vanishingPoint(horizontals[0], horizontals[1]) : nil

        if let vv = vVP, let hv = hVP {
            // 解 2×2 线性方程组：
            // l1 * vv.x + l2 * vv.y = -vv.z
            // l1 * hv.x + l2 * hv.y = -hv.z
            let det = vv.x * hv.y - vv.y * hv.x
            if abs(det) > 1e-10 {
                l1 = (-vv.z * hv.y + vv.y * hv.z) / det
                l2 = (-vv.x * hv.z + vv.z * hv.x) / det
            } else {
                (l1, l2) = singleVPProjection(vv)
            }
        } else if let vv = vVP {
            (l1, l2) = singleVPProjection(vv)
        } else if let hv = hVP {
            (l1, l2) = singleVPProjection(hv)
        }

        // 安全阻尼：确保四角分母 l1*u + l2*v + 1 >= 0.30，永不跨越灭线导致画面翻转爆裂
        let cornersCentered: [SIMD2<Double>] = [
            SIMD2(-cx,  cy), // TL
            SIMD2( cx,  cy), // TR
            SIMD2( cx, -cy), // BR
            SIMD2(-cx, -cy)  // BL
        ]
        var minDenom = 1.0
        for c in cornersCentered {
            minDenom = min(minDenom, l1 * c.x + l2 * c.y + 1.0)
        }
        if minDenom < 0.30 {
            let maxNeg = 1.0 - minDenom
            if maxNeg > 1e-9 {
                let damp = 0.70 / maxNeg
                l1 *= damp
                l2 *= damp
            }
        }

        let Hproj = simd_double3x3(rows: [
            SIMD3(1.0, 0.0, 0.0),
            SIMD3(0.0, 1.0, 0.0),
            SIMD3(l1,  l2,  1.0)
        ])

        func applyH(_ M: simd_double3x3, _ p: SIMD2<Double>) -> SIMD2<Double> {
            let q = M * SIMD3<Double>(p.x, p.y, 1.0)
            return SIMD2<Double>(q.x / q.z, q.y / q.z)
        }

        // Step 2: 仿射矫正，把投影后的竖线方向对齐 (0,1)、横线方向对齐 (1,0)
        var avgV = SIMD2<Double>(0, 0)
        for s in verticals {
            let d = applyH(Hproj, s.b) - applyH(Hproj, s.a)
            let norm = simd_length(d)
            if norm > 1e-6 {
                let u = d / norm
                avgV += (u.y >= 0 ? u : -u)
            }
        }
        var avgH = SIMD2<Double>(0, 0)
        for s in horizontals {
            let d = applyH(Hproj, s.b) - applyH(Hproj, s.a)
            let norm = simd_length(d)
            if norm > 1e-6 {
                let u = d / norm
                avgH += (u.x >= 0 ? u : -u)
            }
        }

        var a00 = 1.0, a01 = 0.0, a10 = 0.0, a11 = 1.0
        let hasV = simd_length(avgV) > 1e-6
        let hasH = simd_length(avgH) > 1e-6

        if hasV && hasH {
            let ev = simd_normalize(avgV)
            let eh = simd_normalize(avgH)
            // [eh, ev] 矩阵逆：把 eh -> (1, 0)，ev -> (0, 1)
            let det = eh.x * ev.y - ev.x * eh.y
            if abs(det) > 0.25 {
                let invSqrt = 1.0 / sqrt(abs(det))
                let sign = det > 0 ? 1.0 : -1.0
                a00 =  ev.y / det * sqrt(abs(det)) * sign
                a01 = -ev.x / det * sqrt(abs(det)) * sign
                a10 = -eh.y / det * sqrt(abs(det)) * sign
                a11 =  eh.x / det * sqrt(abs(det)) * sign
                _ = invSqrt
                // 验证映射符号保证不镜像翻转
                if a00 * a11 - a01 * a10 < 0 {
                    a00 = -a00; a01 = -a01
                }
            }
        } else if hasV {
            let ev = simd_normalize(avgV)
            let theta = atan2(ev.x, ev.y)
            let c = cos(theta), s = sin(theta)
            a00 = c; a01 = -s; a10 = s; a11 = c
        } else if hasH {
            let eh = simd_normalize(avgH)
            let theta = -atan2(eh.y, eh.x)
            let c = cos(theta), s = sin(theta)
            a00 = c; a01 = -s; a10 = s; a11 = c
        }

        let Haff = simd_double3x3(rows: [
            SIMD3(a00, a01, 0.0),
            SIMD3(a10, a11, 0.0),
            SIMD3(0.0, 0.0, 1.0)
        ])

        let Hcenter = Haff * Hproj

        // Step 3: 保持合理尺度（让变换后外接面积与原图接近，不暴涨显存）
        let rawCorners = cornersCentered.map { applyH(Hcenter, $0) }
        guard rawCorners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }

        // 校验凸性与手性（TL->TR->BR->BL 在 Y 向上坐标系为顺时针，即有向面积 < 0）
        if !isValidConvexQuad(rawCorners) { return nil }

        let areaAfter = abs(quadArea(rawCorners))
        let areaBefore = W * H
        guard areaAfter > 1e-3 else { return nil }
        let scale = min(max(sqrt(areaBefore / areaAfter), 0.35), 2.5)

        let Hscale = simd_double3x3(rows: [
            SIMD3(scale, 0.0, 0.0),
            SIMD3(0.0, scale, 0.0),
            SIMD3(0.0, 0.0, 1.0)
        ])

        // 源像素坐标 → 中心坐标
        let TtoCenter = simd_double3x3(rows: [
            SIMD3(1.0, 0.0, -cx - Double(extent.minX)),
            SIMD3(0.0, 1.0, -cy - Double(extent.minY)),
            SIMD3(0.0, 0.0, 1.0)
        ])
        let Hraw = Hscale * Hcenter * TtoCenter

        // 映射原图四角到透视后坐标（再平移使外接框原点在 (0, 0)）
        let srcPts: [SIMD2<Double>] = [
            SIMD2(Double(extent.minX), Double(extent.maxY)), // TL
            SIMD2(Double(extent.maxX), Double(extent.maxY)), // TR
            SIMD2(Double(extent.maxX), Double(extent.minY)), // BR
            SIMD2(Double(extent.minX), Double(extent.minY))  // BL
        ]
        let warpedUnshifted = srcPts.map { applyH(Hraw, $0) }
        let minX = warpedUnshifted.map(\.x).min() ?? 0
        let minY = warpedUnshifted.map(\.y).min() ?? 0
        let maxX = warpedUnshifted.map(\.x).max() ?? W
        let maxY = warpedUnshifted.map(\.y).max() ?? H
        let bboxW = maxX - minX, bboxH = maxY - minY
        // 防止极端透视拉出巨型画布（上限 2.4x 原图边长）
        let capScale = min(1.0, (max(W, H) * 2.4) / max(bboxW, bboxH, 1.0))

        let Tshift = simd_double3x3(rows: [
            SIMD3(capScale, 0.0, -minX * capScale),
            SIMD3(0.0, capScale, -minY * capScale),
            SIMD3(0.0, 0.0, 1.0)
        ])
        let Hwarped = Tshift * Hraw
        let qPts = srcPts.map { applyH(Hwarped, $0) }

        let tl = CGPoint(x: qPts[0].x, y: qPts[0].y)
        let tr = CGPoint(x: qPts[1].x, y: qPts[1].y)
        let br = CGPoint(x: qPts[2].x, y: qPts[2].y)
        let bl = CGPoint(x: qPts[3].x, y: qPts[3].y)
        let fullBounds = CGRect(
            x: 0, y: 0,
            width: max(2, (maxX - minX) * capScale),
            height: max(2, (maxY - minY) * capScale)
        )

        let cropRect: CGRect
        if constrainCrop, let inscribed = largestInscribedRect(in: qPts),
           inscribed.width >= 16, inscribed.height >= 16 {
            cropRect = inscribed
        } else {
            cropRect = fullBounds
        }

        let Tcrop = simd_double3x3(rows: [
            SIMD3(1.0, 0.0, -Double(cropRect.minX)),
            SIMD3(0.0, 1.0, -Double(cropRect.minY)),
            SIMD3(0.0, 0.0, 1.0)
        ])
        let Hfinal = Tcrop * Hwarped
        let detFinal = Hfinal.determinant
        guard detFinal.isFinite, abs(detFinal) > 1e-12 else { return nil }
        let Hinv = Hfinal.inverse

        return Solution(
            homography: Hfinal,
            inverseHomography: Hinv,
            tl: tl, tr: tr, br: br, bl: bl,
            cropRect: cropRect,
            outputSize: cropRect.size,
            sourceSize: extent.size
        )
    }

    /// 对定向后的源图执行 Guided Upright 透视变换（可选内接裁切去黑边）
    static func apply(_ img: CIImage, guides: [UprightGuide], constrainCrop: Bool = true) -> CIImage {
        guard let sol = solve(guides: guides, extent: img.extent, constrainCrop: constrainCrop) else {
            return img
        }
        return apply(img, solution: sol)
    }

    static func apply(_ img: CIImage, solution sol: Solution) -> CIImage {
        guard let f = CIFilter(name: "CIPerspectiveTransform") else { return img }
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgPoint: sol.tl), forKey: "inputTopLeft")
        f.setValue(CIVector(cgPoint: sol.tr), forKey: "inputTopRight")
        f.setValue(CIVector(cgPoint: sol.br), forKey: "inputBottomRight")
        f.setValue(CIVector(cgPoint: sol.bl), forKey: "inputBottomLeft")
        guard let warped = f.outputImage else { return img }
        let crop = sol.cropRect.integral
        guard crop.width >= 4, crop.height >= 4 else { return img }
        return warped
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    // MARK: - 几何辅助

    private static func vanishingPoint(_ s1: Seg, _ s2: Seg) -> SIMD3<Double>? {
        let vp = simd_cross(s1.line, s2.line)
        let n = simd_length(SIMD2<Double>(vp.x, vp.y))
        guard n > 1e-9 else { return nil }
        // 若两线几乎平行（交点距离超过 100 倍画幅），视为无需透视汇聚
        if abs(vp.z) / n < 1e-6 { return nil }
        return vp
    }

    private static func singleVPProjection(_ vp: SIMD3<Double>) -> (Double, Double) {
        let denom = vp.x * vp.x + vp.y * vp.y
        guard denom > 1e-12 else { return (0, 0) }
        return (-vp.z * vp.x / denom, -vp.z * vp.y / denom)
    }

    private static func quadArea(_ pts: [SIMD2<Double>]) -> Double {
        guard pts.count == 4 else { return 0 }
        var sum = 0.0
        for i in 0..<4 {
            let p = pts[i], q = pts[(i + 1) % 4]
            sum += p.x * q.y - q.x * p.y
        }
        return sum * 0.5
    }

    private static func isValidConvexQuad(_ pts: [SIMD2<Double>]) -> Bool {
        guard pts.count == 4 else { return false }
        var sign = 0.0
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4], c = pts[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-6 { return false }
            if sign == 0 { sign = cross }
            else if sign * cross < 0 { return false }
        }
        return true
    }

    /// 计算凸四边形内最大面积的轴对齐内接矩形（精确零黑边）。
    static func largestInscribedRect(in quad: [SIMD2<Double>]) -> CGRect? {
        guard quad.count == 4 else { return nil }
        let yMin = quad.map(\.y).min() ?? 0
        let yMax = quad.map(\.y).max() ?? 0
        guard yMax - yMin > 4 else { return nil }

        // 对给定水平线 y，求与凸四边形左右边界交点 [xL, xR]
        func xSpan(at y: Double) -> (Double, Double)? {
            var xs: [Double] = []
            for i in 0..<4 {
                let p = quad[i], q = quad[(i + 1) % 4]
                if (p.y <= y && q.y >= y) || (q.y <= y && p.y >= y) {
                    let dy = q.y - p.y
                    if abs(dy) < 1e-9 {
                        xs.append(p.x); xs.append(q.x)
                    } else {
                        let t = (y - p.y) / dy
                        if t >= -1e-6 && t <= 1 + 1e-6 {
                            xs.append(p.x + t * (q.x - p.x))
                        }
                    }
                }
            }
            guard let lo = xs.min(), let hi = xs.max(), hi > lo + 1 else { return nil }
            return (lo, hi)
        }

        // 在纵轴上均匀采样 80 层，枚举上下界 [y0, y1] 求最大内接矩形（因凸性，区间内每条扫描线都包含 [max(xL0,xL1), min(xR0,xR1)]）
        let steps = 80
        var ys: [Double] = []
        var spans: [(Double, Double)] = []
        for i in 1..<steps {
            let y = yMin + (yMax - yMin) * Double(i) / Double(steps)
            if let sp = xSpan(at: y) {
                ys.append(y)
                spans.append(sp)
            }
        }
        guard ys.count >= 2 else { return nil }

        var bestArea = 0.0
        var bestRect: CGRect?
        for i in 0..<(ys.count - 1) {
            var curL = spans[i].0
            var curR = spans[i].1
            for j in (i + 1)..<ys.count {
                curL = max(curL, spans[j].0)
                curR = min(curR, spans[j].1)
                let w = curR - curL
                if w <= 1 { break }
                let h = ys[j] - ys[i]
                let area = w * h
                if area > bestArea {
                    bestArea = area
                    // 向内缩 1px 消除双线性插值边界半透明细线
                    let pad = min(1.0, min(w, h) * 0.02)
                    bestRect = CGRect(x: curL + pad, y: ys[i] + pad,
                                      width: max(1, w - pad * 2), height: max(1, h - pad * 2))
                }
            }
        }
        return bestRect
    }
}

#if !PHOS_TESTING || PHOS_APP_TESTING
// MARK: - 画布交互：Guided Upright 参考线绘制与拖拽层
struct GuidedUprightOverlay: View {
    @EnvironmentObject var s: AppState
    let frameSize: CGSize
    let solution: GuidedUprightEngine.Solution?

    @State private var draftGuide: UprightGuide? = nil
    @State private var dragHandle: (id: UUID, isEnd: Bool)? = nil
    @State private var dragStartSolution: GuidedUprightEngine.Solution? = nil
    @State private var editToken: ParameterEditCoordinator.Token? = nil

    private func toCanvasPoint(_ srcNorm: CGPoint, using sol: GuidedUprightEngine.Solution?) -> CGPoint {
        let outNorm = sol?.mapSourceNormalizedToOutput(srcNorm) ?? srcNorm
        return CGPoint(
            x: outNorm.x * frameSize.width,
            y: (1.0 - outNorm.y) * frameSize.height
        )
    }

    private func toSourceNormalized(_ canvasPt: CGPoint, using sol: GuidedUprightEngine.Solution?) -> CGPoint {
        let nx = min(max(Double(canvasPt.x / max(frameSize.width, 1)), 0), 1)
        let ny = min(max(1.0 - Double(canvasPt.y / max(frameSize.height, 1)), 0), 1)
        let outNorm = CGPoint(x: nx, y: ny)
        return sol?.mapOutputNormalizedToSource(outNorm) ?? outNorm
    }

    var body: some View {
        let activeSol = dragStartSolution ?? solution
        let guides = draftGuide.map { s.params.uprightGuides + [$0] } ?? s.params.uprightGuides

        ZStack(alignment: .topLeading) {
            // 透明交互层：空白处拖动即可新增参考线（最多 4 条）
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            guard s.params.uprightGuides.count < 4 else { return }
                            if dragStartSolution == nil { dragStartSolution = solution }
                            let solRef = dragStartSolution
                            let p0 = toSourceNormalized(v.startLocation, using: solRef)
                            let p1 = toSourceNormalized(v.location, using: solRef)
                            draftGuide = UprightGuide(x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y)
                        }
                        .onEnded { _ in
                            if let g = draftGuide, hypot(g.x1 - g.x0, g.y1 - g.y0) > 0.025 {
                                var next = s.params.uprightGuides
                                if next.count < 4 {
                                    next.append(g)
                                    s.set(\.perspectiveAuto, false)
                                    s.set(\.uprightGuides, next)
                                    s.endEdit()
                                }
                            }
                            draftGuide = nil
                            dragStartSolution = nil
                        }
                )

            // 绘制参考线与垂直/水平辅助虚线
            Canvas { ctx, _ in
                for g in guides {
                    let p0 = toCanvasPoint(CGPoint(x: g.x0, y: g.y0), using: activeSol)
                    let p1 = toCanvasPoint(CGPoint(x: g.x1, y: g.y1), using: activeSol)
                    var line = Path()
                    line.move(to: p0)
                    line.addLine(to: p1)
                    ctx.stroke(line, with: .color(.black.opacity(0.65)), lineWidth: 3.0)
                    let accent = g.isHorizontal
                        ? Color(red: 0.35, green: 0.80, blue: 1.0)
                        : Color(red: 1.0, green: 0.78, blue: 0.25)
                    ctx.stroke(line, with: .color(accent), lineWidth: 1.6)
                }
            }
            .allowsHitTesting(false)

            // 每条已保存参考线的两端可拖动手柄 + 中点删除按钮
            ForEach(s.params.uprightGuides) { g in
                let p0 = toCanvasPoint(CGPoint(x: g.x0, y: g.y0), using: activeSol)
                let p1 = toCanvasPoint(CGPoint(x: g.x1, y: g.y1), using: activeSol)
                let mid = CGPoint(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)
                let color = g.isHorizontal
                    ? Color(red: 0.35, green: 0.80, blue: 1.0)
                    : Color(red: 1.0, green: 0.78, blue: 0.25)

                guideHandle(id: g.id, isEnd: false, point: p0, color: color)
                guideHandle(id: g.id, isEnd: true, point: p1, color: color)

                Button {
                    var next = s.params.uprightGuides
                    next.removeAll { $0.id == g.id }
                    s.set(\.uprightGuides, next)
                    s.endEdit()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .position(mid)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    private func guideHandle(id: UUID, isEnd: Bool, point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(6)
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if editToken == nil {
                            editToken = s.parameterEdits.begin()
                            dragStartSolution = solution
                            dragHandle = (id, isEnd)
                        }
                        guard s.parameterEdits.valid(editToken),
                              let idx = s.params.uprightGuides.firstIndex(where: { $0.id == id }) else { return }
                        let srcPt = toSourceNormalized(v.location, using: dragStartSolution)
                        var next = s.params.uprightGuides
                        if isEnd {
                            next[idx].x1 = srcPt.x; next[idx].y1 = srcPt.y
                        } else {
                            next[idx].x0 = srcPt.x; next[idx].y0 = srcPt.y
                        }
                        s.set(\.uprightGuides, next)
                    }
                    .onEnded { _ in
                        if s.parameterEdits.complete(editToken) { s.endEdit() }
                        editToken = nil
                        dragHandle = nil
                        dragStartSolution = nil
                    }
            )
    }
}
#endif
