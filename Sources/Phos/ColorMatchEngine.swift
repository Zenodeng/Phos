import Foundation
import CoreImage
import CoreGraphics

struct ColorMatchOptions: Equatable {
    var matchExposure: Bool = true
    var matchToneCurve: Bool = true
    var matchColorGrade: Bool = true
    var matchHSL: Bool = true
    var matchFilmTexture: Bool = false
    var protectSkinTones: Bool = true
    var strength: Double = 1.0
}

struct ColorMatchResult {
    var params: EditParams
    var initialDeltaE: Double
    var finalDeltaE: Double
    var elapsedMs: Double
    var referencePalette: [[Double]]
    var sourcePalette: [[Double]]
    var changedGroups: [String]
}

/// P3 参考图 → 全可编辑参数反解引擎（OKLab/OKLCH 感知统计 + 前向色彩模型多轮坐标下降）。
enum ColorMatchEngine {
    private struct LabStats {
        var samples: [(Float, Float, Float)] // (rLin, gLin, bLin)
        var qL: [Double]                     // 7 分位亮度 [0.02, 0.10, 0.25, 0.50, 0.75, 0.90, 0.98]
        var meanAB_Shadow: (Double, Double)
        var meanAB_Mid: (Double, Double)
        var meanAB_High: (Double, Double)
        var meanChroma: Double
        var sectorChroma: [Double]
        var sectorHue: [Double]
        var sectorLum: [Double]
        var sectorWeights: [Double]
        var grainEnergy: Double
        var highlightFraction: Double
        var palette: [[Double]]
    }

    static func solve(source: CIImage, reference: CIImage, base: EditParams,
                      options: ColorMatchOptions = ColorMatchOptions()) -> ColorMatchResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let alignedSrc = Engine.geometry(source, base)
        let srcStats = extractStats(alignedSrc)
        let refStats = extractStats(reference)

        let initDE = lossDeltaE(source: srcStats.samples, target: refStats, params: base)
        var solved = base

        // 阶段 1：解析初值反解
        if options.matchExposure {
            let srcMid = max(srcStats.qL[3], 0.04)
            let refMid = max(refStats.qL[3], 0.04)
            // OKLab L 近似立方根，转为线性曝光 EV 估计
            let srcLinMid = pow(srcMid, 3.0)
            let refLinMid = pow(refMid, 3.0)
            let evDelta = min(max(log2(max(refLinMid, 1e-4) / max(srcLinMid, 1e-4)), -2.5), 2.5)
            solved.exposure = clamp(base.exposure + evDelta, -4.5...4.5)

            let srcSpread = max(srcStats.qL[5] - srcStats.qL[1], 0.08)
            let refSpread = max(refStats.qL[5] - refStats.qL[1], 0.08)
            let contrastRatio = log2(refSpread / srcSpread) * 48.0
            solved.contrast = clamp(base.contrast + contrastRatio, -85...85)
            solved.contrastPivot = clamp((refStats.qL[3] - 0.5) * 40.0, -35...35)

            let srcHead = srcStats.qL[6] - srcStats.qL[5]
            let refHead = refStats.qL[6] - refStats.qL[5]
            if refHead < srcHead * 0.85 {
                solved.highlightRolloff = clamp(max(base.highlightRolloff, 25 + (srcHead - refHead) * 180), 0...85)
            }

            let shDiff = (refStats.qL[1] - srcStats.qL[1]) - (refStats.qL[3] - srcStats.qL[3]) * 0.5
            let hiDiff = (refStats.qL[5] - srcStats.qL[5]) - (refStats.qL[3] - srcStats.qL[3]) * 0.5
            solved.shadows = clamp(base.shadows + shDiff * 170.0, -90...90)
            solved.highlights = clamp(base.highlights + hiDiff * 170.0, -90...90)
            solved.blacks = clamp(base.blacks + (refStats.qL[0] - srcStats.qL[0]) * 140.0, -80...80)
            solved.whites = clamp(base.whites + (refStats.qL[6] - srcStats.qL[6]) * 140.0, -80...80)
        }

        if options.matchToneCurve {
            // 按关键分位残差构造单调 5 点亮度曲线（保留基线曲线结构）
            let shift1 = (refStats.qL[1] - srcStats.qL[1]) * 0.28
            let shift2 = (refStats.qL[3] - srcStats.qL[3]) * 0.22
            let shift3 = (refStats.qL[5] - srcStats.qL[5]) * 0.28
            let y0 = clamp(refStats.qL[0] * 0.25, 0...0.16)
            let y1 = clamp(0.25 + shift1, max(y0 + 0.04, 0.08)...0.42)
            let y2 = clamp(0.50 + shift2, max(y1 + 0.06, 0.30)...0.70)
            let y3 = clamp(0.75 + shift3, max(y2 + 0.06, 0.58)...0.94)
            let y4 = clamp(1.0 - max(0.0, 0.96 - refStats.qL[6]) * 0.35, max(y3 + 0.03, 0.84)...1.0)
            solved.lumaCurve = ToneCurve(points: [[0, y0], [0.25, y1], [0.5, y2], [0.75, y3], [1, y4]])
        }

        if options.matchColorGrade {
            // 中间调色温/色调对齐
            let daMid = refStats.meanAB_Mid.0 - srcStats.meanAB_Mid.0
            let dbMid = refStats.meanAB_Mid.1 - srcStats.meanAB_Mid.1
            solved.temperature = clamp(base.temperature + dbMid * 260.0, -85...85)
            solved.tint = clamp(base.tint + daMid * 260.0, -85...85)

            // 阴影 / 中间调 / 高光 三轮颜色分级反解
            let shGrad = okLabVecToGrade(da: refStats.meanAB_Shadow.0 - srcStats.meanAB_Shadow.0 * 0.7 - daMid * 0.4,
                                         db: refStats.meanAB_Shadow.1 - srcStats.meanAB_Shadow.1 * 0.7 - dbMid * 0.4)
            let midGrad = okLabVecToGrade(da: daMid * 0.45, db: dbMid * 0.45)
            let hiGrad = okLabVecToGrade(da: refStats.meanAB_High.0 - srcStats.meanAB_High.0 * 0.7 - daMid * 0.4,
                                         db: refStats.meanAB_High.1 - srcStats.meanAB_High.1 * 0.7 - dbMid * 0.4)
            solved.gradeShadow = shGrad
            solved.gradeMid = midGrad
            solved.gradeHigh = hiGrad
            solved.gradeBlend = 50
            solved.gradeBalance = clamp((refStats.qL[3] - 0.5) * 60.0, -50...50)

            let cDelta = (refStats.meanChroma - srcStats.meanChroma) / max(srcStats.meanChroma, 0.03)
            solved.vibrance = clamp(base.vibrance + cDelta * 36.0, -80...80)
            solved.saturation = clamp(base.saturation + cDelta * 28.0, -80...80)
        }

        if options.matchHSL {
            var hsl = base.hsl
            for i in 0..<8 {
                let sw = srcStats.sectorWeights[i], rw = refStats.sectorWeights[i]
                guard sw > 0.005 || rw > 0.005 else { continue }
                let sScale = (i == 1 && options.protectSkinTones) ? 0.45 : 1.0
                let hScale = (i == 1 && options.protectSkinTones) ? 0.25 : 1.0
                let dh = wrapDeg(refStats.sectorHue[i] - srcStats.sectorHue[i])
                let sc = max(srcStats.sectorChroma[i], 0.02), rc = max(refStats.sectorChroma[i], 0.02)
                let dSat = ((rc - sc) / sc) * 45.0
                let dLum = (refStats.sectorLum[i] - srcStats.sectorLum[i]) * 95.0
                hsl[i].hue = clamp(hsl[i].hue + clamp(dh * 0.45, -28...28) * hScale, -45...45)
                hsl[i].sat = clamp(hsl[i].sat + dSat * sScale, -75...75)
                hsl[i].lum = clamp(hsl[i].lum + dLum * sScale, -60...60)
            }
            solved.hsl = hsl
        }

        if options.matchFilmTexture {
            if refStats.grainEnergy > srcStats.grainEnergy * 1.15 {
                solved.grain = clamp(max(base.grain, (refStats.grainEnergy - srcStats.grainEnergy) * 520.0), 0...65)
                solved.grainRoughness = 0.58
            }
            if refStats.highlightFraction > 0.03 {
                solved.halation = clamp(max(base.halation, refStats.highlightFraction * 180.0), 0...35)
            }
        }

        // 阶段 2：前向色彩代理坐标下降精修（保证 ΔE 单调下降）
        var best = solved
        var bestDE = lossDeltaE(source: srcStats.samples, target: refStats, params: best)
        let steps: [(WritableKeyPath<EditParams, Double>, ClosedRange<Double>, [Double])] = [
            (\.exposure, -4.5...4.5, [0.35, -0.35, 0.14, -0.14]),
            (\.contrast, -85...85, [12, -12, 5, -5]),
            (\.highlights, -90...90, [15, -15, 6, -6]),
            (\.shadows, -90...90, [15, -15, 6, -6]),
            (\.temperature, -85...85, [10, -10, 4, -4]),
            (\.tint, -85...85, [8, -8, 3, -3]),
            (\.saturation, -80...80, [10, -10, 4, -4]),
            (\.vibrance, -80...80, [10, -10, 4, -4]),
            (\.gradeShadow.sat, 0...100, [8, -8, 4, -4]),
            (\.gradeMid.sat, 0...100, [8, -8, 4, -4]),
            (\.gradeHigh.sat, 0...100, [8, -8, 4, -4])
        ]
        for _ in 0..<3 {
            var improved = false
            for (kp, rng, deltas) in steps {
                if !options.matchExposure && (kp == \.exposure || kp == \.contrast || kp == \.highlights || kp == \.shadows) { continue }
                if !options.matchColorGrade && (kp == \.temperature || kp == \.tint || kp == \.saturation || kp == \.vibrance || kp == \.gradeShadow.sat || kp == \.gradeMid.sat || kp == \.gradeHigh.sat) { continue }
                let cur = best[keyPath: kp]
                for d in deltas {
                    var cand = best
                    cand[keyPath: kp] = clamp(cur + d, rng)
                    let de = lossDeltaE(source: srcStats.samples, target: refStats, params: cand)
                    if de + 0.01 < bestDE {
                        best = cand
                        bestDE = de
                        improved = true
                        break
                    }
                }
            }
            if !improved { break }
        }

        // 若求解偏离太大导致比基准更差，安全混合或回退确保 ΔE 不升
        if bestDE > initDE {
            best = base
            bestDE = initDE
        }

        let finalParams = blend(from: base, to: best, strength: options.strength)
        let finalDE = lossDeltaE(source: srcStats.samples, target: refStats, params: finalParams)
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        let changed = WorkspaceParametersChangedGroups(base: base, target: finalParams)

        return ColorMatchResult(
            params: finalParams,
            initialDeltaE: initDE,
            finalDeltaE: finalDE,
            elapsedMs: elapsed,
            referencePalette: refStats.palette,
            sourcePalette: srcStats.palette,
            changedGroups: changed
        )
    }

    static func blend(from base: EditParams, to target: EditParams, strength: Double) -> EditParams {
        let a = clamp(strength, 0...1.5)
        if abs(a) < 1e-6 { return base }
        if abs(a - 1.0) < 1e-6 { return target }
        func lerp(_ b: Double, _ t: Double, _ rng: ClosedRange<Double>) -> Double {
            clamp(b + (t - b) * a, rng)
        }
        func lerpGrade(_ b: ColorGrade, _ t: ColorGrade) -> ColorGrade {
            var g = t
            g.sat = lerp(b.sat, t.sat, 0...100)
            g.lum = lerp(b.lum, t.lum, -100...100)
            if abs(b.sat) < 0.5 { g.hue = t.hue }
            else {
                let dH = wrapDeg(t.hue - b.hue)
                var h = (b.hue + dH * min(a, 1.0)).truncatingRemainder(dividingBy: 360)
                if h < 0 { h += 360 }
                g.hue = h
            }
            return g
        }
        var out = base
        out.temperature = lerp(base.temperature, target.temperature, -100...100)
        out.tint = lerp(base.tint, target.tint, -100...100)
        out.exposure = lerp(base.exposure, target.exposure, -5...5)
        out.contrast = lerp(base.contrast, target.contrast, -100...100)
        out.contrastPivot = lerp(base.contrastPivot, target.contrastPivot, -50...50)
        out.highlightRolloff = lerp(base.highlightRolloff, target.highlightRolloff, 0...100)
        out.highlights = lerp(base.highlights, target.highlights, -100...100)
        out.shadows = lerp(base.shadows, target.shadows, -100...100)
        out.whites = lerp(base.whites, target.whites, -100...100)
        out.blacks = lerp(base.blacks, target.blacks, -100...100)
        out.vibrance = lerp(base.vibrance, target.vibrance, -100...100)
        out.saturation = lerp(base.saturation, target.saturation, -100...100)
        out.gradeShadow = lerpGrade(base.gradeShadow, target.gradeShadow)
        out.gradeMid = lerpGrade(base.gradeMid, target.gradeMid)
        out.gradeHigh = lerpGrade(base.gradeHigh, target.gradeHigh)
        out.gradeBlend = lerp(base.gradeBlend, target.gradeBlend, 0...100)
        out.gradeBalance = lerp(base.gradeBalance, target.gradeBalance, -100...100)
        out.grain = lerp(base.grain, target.grain, 0...100)
        out.grainRoughness = lerp(base.grainRoughness, target.grainRoughness, 0...1)
        out.halation = lerp(base.halation, target.halation, 0...100)
        for i in 0..<8 {
            out.hsl[i].hue = lerp(base.hsl[i].hue, target.hsl[i].hue, -45...45)
            out.hsl[i].sat = lerp(base.hsl[i].sat, target.hsl[i].sat, -100...100)
            out.hsl[i].lum = lerp(base.hsl[i].lum, target.hsl[i].lum, -100...100)
        }
        // 插值单调亮度曲线
        let xs = [0.0, 0.25, 0.5, 0.75, 1.0]
        var pts: [[Double]] = []
        var prevY = 0.0
        for x in xs {
            let yb = base.lumaCurve.value(at: x)
            let yt = target.lumaCurve.value(at: x)
            var y = clamp(yb + (yt - yb) * a, 0...1)
            if x > 0 { y = max(prevY + 0.005, y) }
            prevY = min(y, 1.0)
            pts.append([x, prevY])
        }
        out.lumaCurve = ToneCurve(points: pts)
        return out
    }

    private static func WorkspaceParametersChangedGroups(base: EditParams, target: EditParams) -> [String] {
        var groups: [String] = []
        if base.temperature != target.temperature || base.tint != target.tint { groups.append("白平衡") }
        if base.exposure != target.exposure || base.contrast != target.contrast || base.highlights != target.highlights || base.shadows != target.shadows || base.whites != target.whites || base.blacks != target.blacks { groups.append("基本") }
        if base.vibrance != target.vibrance || base.saturation != target.saturation { groups.append("质感与饱和度") }
        if base.lumaCurve != target.lumaCurve { groups.append("曲线") }
        if base.gradeShadow != target.gradeShadow || base.gradeMid != target.gradeMid || base.gradeHigh != target.gradeHigh { groups.append("颜色分级") }
        if base.hsl != target.hsl { groups.append("HSL · 混色") }
        if base.grain != target.grain { groups.append("细节") }
        if base.halation != target.halation { groups.append("效果") }
        return groups
    }

    private static func extractStats(_ img: CIImage) -> LabStats {
        let side = 72
        let e = img.extent
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let small = img.cropped(to: e)
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / max(1, e.width),
                                               y: CGFloat(side) / max(1, e.height)))
        var buf = [Float](repeating: 0, count: side * side * 4)
        Engine.ctx.render(small, toBitmap: &buf, rowBytes: side * 16, bounds: rect,
                          format: .RGBAf, colorSpace: Engine.workingColorSpace)

        let n = side * side
        var samples: [(Float, Float, Float)] = []
        samples.reserveCapacity(512)
        var ls = [Double](); ls.reserveCapacity(n)
        var labAll = [(Double, Double, Double)](); labAll.reserveCapacity(n)

        var shA = 0.0, shB = 0.0, shN = 0.0
        var mdA = 0.0, mdB = 0.0, mdN = 0.0
        var hiA = 0.0, hiB = 0.0, hiN = 0.0
        var cSum = 0.0
        var hiCount = 0

        var secC = [Double](repeating: 0, count: 8)
        var secH = [Double](repeating: 0, count: 8)
        var secL = [Double](repeating: 0, count: 8)
        var secW = [Double](repeating: 0, count: 8)
        let centers = [25.0, 55.0, 95.0, 145.0, 195.0, 255.0, 300.0, 335.0]

        for i in 0..<n {
            let r = max(Float(0), buf[i * 4])
            let g = max(Float(0), buf[i * 4 + 1])
            let b = max(Float(0), buf[i * 4 + 2])
            if i % 10 == 0 && samples.count < 512 {
                samples.append((r, g, b))
            }
            let (l, aa, bb) = linearRGBToOKLab(Double(r), Double(g), Double(b))
            ls.append(l)
            labAll.append((l, aa, bb))
            let c = hypot(aa, bb)
            cSum += c
            if 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) > 0.85 { hiCount += 1 }
            if l < 0.38 { shA += aa; shB += bb; shN += 1 }
            else if l < 0.68 { mdA += aa; mdB += bb; mdN += 1 }
            else { hiA += aa; hiB += bb; hiN += 1 }

            if c > 0.03 {
                var hDeg = atan2(bb, aa) * 180.0 / .pi
                if hDeg < 0 { hDeg += 360 }
                for sIdx in 0..<8 {
                    let d = abs(wrapDeg(hDeg - centers[sIdx]))
                    if d < 42 {
                        let w = (1.0 - d / 42.0) * c
                        secC[sIdx] += c * w
                        secH[sIdx] += wrapDeg(hDeg - centers[sIdx]) * w
                        secL[sIdx] += l * w
                        secW[sIdx] += w
                    }
                }
            }
        }

        // 局部高频粗糙度（估算参考图颗粒水平）
        var grainAccum = 0.0
        var grainCount = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let c0 = labAll[y * side + x].0
                if c0 < 0.15 || c0 > 0.85 { continue }
                let avg = (labAll[y * side + x - 1].0 + labAll[y * side + x + 1].0 +
                           labAll[(y - 1) * side + x].0 + labAll[(y + 1) * side + x].0) * 0.25
                let diff = abs(c0 - avg)
                if diff < 0.08 { grainAccum += diff; grainCount += 1 }
            }
        }

        ls.sort()
        let qs = [0.02, 0.10, 0.25, 0.50, 0.75, 0.90, 0.98].map { q -> Double in
            ls[min(ls.count - 1, max(0, Int((Double(ls.count - 1) * q).rounded())))]
        }

        for i in 0..<8 where secW[i] > 1e-6 {
            secC[i] /= secW[i]
            secH[i] = centers[i] + secH[i] / secW[i]
            secL[i] /= secW[i]
            secW[i] /= Double(n)
        }

        // 5 档亮度桶主导色板 (sRGB 0...1)
        var bucketRGB = [[Double]](repeating: [0, 0, 0], count: 5)
        var bucketN = [Double](repeating: 0, count: 5)
        for i in 0..<n {
            let l = labAll[i].0
            let bi = min(4, max(0, Int(l * 5.0)))
            bucketRGB[bi][0] += toPerc(Double(max(0, buf[i * 4])))
            bucketRGB[bi][1] += toPerc(Double(max(0, buf[i * 4 + 1])))
            bucketRGB[bi][2] += toPerc(Double(max(0, buf[i * 4 + 2])))
            bucketN[bi] += 1
        }
        var pal: [[Double]] = []
        for bi in 0..<5 {
            if bucketN[bi] > 0 {
                pal.append([min(1, bucketRGB[bi][0] / bucketN[bi]),
                            min(1, bucketRGB[bi][1] / bucketN[bi]),
                            min(1, bucketRGB[bi][2] / bucketN[bi])])
            } else {
                let g = Double(bi) * 0.2 + 0.1
                pal.append([g, g, g])
            }
        }

        return LabStats(
            samples: samples,
            qL: qs,
            meanAB_Shadow: (shN > 0 ? shA / shN : 0, shN > 0 ? shB / shN : 0),
            meanAB_Mid: (mdN > 0 ? mdA / mdN : 0, mdN > 0 ? mdB / mdN : 0),
            meanAB_High: (hiN > 0 ? hiA / hiN : 0, hiN > 0 ? hiB / hiN : 0),
            meanChroma: cSum / Double(max(n, 1)),
            sectorChroma: secC, sectorHue: secH, sectorLum: secL, sectorWeights: secW,
            grainEnergy: grainCount > 0 ? grainAccum / Double(grainCount) : 0,
            highlightFraction: Double(hiCount) / Double(max(n, 1)),
            palette: pal
        )
    }

    /// 前向快速色彩代理（与 Metal 渲染管线近似对齐）：计算编辑后相对参考统计的复合 ΔE。
    private static func lossDeltaE(source: [(Float, Float, Float)], target: LabStats, params p: EditParams) -> Double {
        let evGain = pow(2.0, p.exposure)
        let tempShift = -p.temperature / 100.0 * 0.045
        let tintShift = p.tint / 100.0 * 0.045
        let satScale = max(0.0, 1.0 + p.saturation / 200.0 + p.vibrance / 260.0)
        let slope = p.contrast >= 0 ? (1.0 + p.contrast / 100.0 * 0.85) : (1.0 / (1.0 - p.contrast / 100.0 * 0.72))
        let pivot = 0.18 * pow(2.0, -p.contrastPivot / 100.0 * 0.8)

        let shAB = gradeToOKLab(p.gradeShadow, blend: p.gradeBlend)
        let mdAB = gradeToOKLab(p.gradeMid, blend: p.gradeBlend)
        let hiAB = gradeToOKLab(p.gradeHigh, blend: p.gradeBlend)

        var ls = [Double](); ls.reserveCapacity(source.count)
        var shA = 0.0, shB = 0.0, shN = 0.0
        var mdA = 0.0, mdB = 0.0, mdN = 0.0
        var hiA = 0.0, hiB = 0.0, hiN = 0.0
        var cSum = 0.0

        for (r0, g0, b0) in source {
            var r = Double(r0) * evGain
            var g = Double(g0) * evGain
            var b = Double(b0) * evGain

            let y0 = max(0.2126 * r + 0.7152 * g + 0.0722 * b, 1e-5)
            let x = log2(y0 / pivot)
            let yContrast = pivot * pow(2.0, clamp(x * slope, -10...10))
            let cScale = yContrast / y0
            r *= cScale; g *= cScale; b *= cScale

            // 影调近似偏移（高光/阴影/白/黑）
            let pL = toPerc(yContrast)
            let shW = pow(max(0, 1.0 - pL * 1.4), 1.6)
            let hiW = pow(max(0, (pL - 0.35) / 0.65), 1.6)
            let toneBoost = (p.shadows / 100.0 * 0.32 * shW) + (p.highlights / 100.0 * 0.32 * hiW)
                + (p.whites / 100.0 * 0.2 * pow(pL, 2.2)) + (p.blacks / 100.0 * 0.2 * pow(1.0 - pL, 2.2))
            let yTone = max(1e-5, yContrast * pow(2.0, toneBoost))
            let tScale = yTone / max(yContrast, 1e-5)
            r *= tScale; g *= tScale; b *= tScale

            var (l, aa, bb) = linearRGBToOKLab(r, g, b)
            if !p.lumaCurve.isIdentity {
                l = clamp(p.lumaCurve.value(at: clamp(l, 0...1)), 0...1)
            }
            aa = aa * satScale + tintShift
            bb = bb * satScale - tempShift

            let bal = p.gradeBalance / 100.0 * 0.15
            if l < 0.38 + bal { aa += shAB.0; bb += shAB.1; shA += aa; shB += bb; shN += 1 }
            else if l < 0.68 + bal { aa += mdAB.0; bb += mdAB.1; mdA += aa; mdB += bb; mdN += 1 }
            else { aa += hiAB.0; bb += hiAB.1; hiA += aa; hiB += bb; hiN += 1 }

            ls.append(l)
            cSum += hypot(aa, bb)
        }

        guard !ls.isEmpty else { return 0 }
        ls.sort()
        let qs = [0.02, 0.10, 0.25, 0.50, 0.75, 0.90, 0.98].map { q -> Double in
            ls[min(ls.count - 1, max(0, Int((Double(ls.count - 1) * q).rounded())))]
        }

        var lErr = 0.0
        for i in 0..<qs.count {
            let d = qs[i] - target.qL[i]
            lErr += d * d
        }
        lErr /= Double(qs.count)

        let curSh = (shN > 0 ? shA / shN : 0, shN > 0 ? shB / shN : 0)
        let curMd = (mdN > 0 ? mdA / mdN : 0, mdN > 0 ? mdB / mdN : 0)
        let curHi = (hiN > 0 ? hiA / hiN : 0, hiN > 0 ? hiB / hiN : 0)

        let abErr = (pow(curSh.0 - target.meanAB_Shadow.0, 2) + pow(curSh.1 - target.meanAB_Shadow.1, 2) +
                     pow(curMd.0 - target.meanAB_Mid.0, 2) + pow(curMd.1 - target.meanAB_Mid.1, 2) +
                     pow(curHi.0 - target.meanAB_High.0, 2) + pow(curHi.1 - target.meanAB_High.1, 2)) / 3.0
        let cErr = pow((cSum / Double(source.count)) - target.meanChroma, 2)
        return 100.0 * sqrt(lErr * 1.3 + abErr * 2.4 + cErr * 0.8)
    }

    private static func gradeToOKLab(_ g: ColorGrade, blend: Double) -> (Double, Double) {
        guard g.sat > 0.1 else { return (0, 0) }
        let k = clamp(blend / 50.0, 0...2.0) * (g.sat / 100.0) * 0.055
        let rad = g.hue * .pi / 180.0
        return (cos(rad) * k, sin(rad) * k)
    }

    private static func okLabVecToGrade(da: Double, db: Double) -> ColorGrade {
        let mag = hypot(da, db)
        let sat = clamp(mag * 420.0, 0...75)
        if sat < 2.0 { return ColorGrade() }
        var deg = atan2(db, da) * 180.0 / .pi
        if deg < 0 { deg += 360 }
        return ColorGrade(hue: deg, sat: sat)
    }

    private static func linearRGBToOKLab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(max(0, l)), m_ = cbrt(max(0, m)), s_ = cbrt(max(0, s))
        let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        return (L, A, B)
    }

    private static func toPerc(_ v: Double) -> Double {
        let a = max(0, v)
        return a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1.0 / 2.4) - 0.055
    }

    private static func wrapDeg(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
}
