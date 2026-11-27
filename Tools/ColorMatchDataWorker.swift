import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Phos Phase 1 训练数据无头反解与渲染验证 Worker。
/// 输入 `(source, target)` 成对图像清单（支持 RAW/DNG/TIFF/JPEG/PNG），调用真实 `ColorMatchEngine.solve`
/// 将专家成片反解为严格符合 `PhotoAIPlan` Schema 步进与范围的 Phos 参数，
/// 再经由真实 `Engine.render` 回渲计算 SSIM 与 OKLab ΔE，输出 768px 训练图与结构化 JSONL。
@main
enum ColorMatchDataWorker {

    struct PairInput: Decodable {
        let id: String
        let source: String
        let target: String
        let groupId: String?
        let styleLabel: String?
        let instruction: String?
        let summary: String?
        let protectSkinTones: Bool?
        let matchFilmTexture: Bool?
    }

    struct SolvedMetrics: Encodable {
        let initialDeltaE: Double
        let solverFinalDeltaE: Double
        let renderedDeltaE: Double
        let renderedSSIM: Double
        let elapsedMs: Double
        let passedGate: Bool
    }

    static func main() throws {
        let args = CommandLine.arguments
        func arg(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let pairsPath = arg("--pairs"), let outDirPath = arg("--out-dir") else {
            fputs("Usage: phos-colormatch-worker --pairs pairs.json --out-dir out_dir [--max-edge 768] [--min-ssim 0.72] [--max-de 14.0]\n", stderr)
            exit(2)
        }
        let maxEdge = CGFloat(Double(arg("--max-edge") ?? "768") ?? 768)
        let minSSIM = Double(arg("--min-ssim") ?? "0.72") ?? 0.72
        let maxDE = Double(arg("--max-de") ?? "14.0") ?? 14.0

        let pairsData = try Data(contentsOf: URL(fileURLWithPath: pairsPath))
        let pairs = try JSONDecoder().decode([PairInput].self, from: pairsData)

        let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
        let imagesDir = outDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        var lines: [String] = []
        var passed = 0
        var failed = 0

        for (idx, item) in pairs.enumerated() {
            autoreleasepool {
                let srcURL = URL(fileURLWithPath: item.source)
                let tgtURL = URL(fileURLWithPath: item.target)
                guard let rawSrc = Engine.decode(srcURL), let rawTgt = Engine.decode(tgtURL) else {
                    failed += 1
                    fputs("WARN [\(idx+1)/\(pairs.count)] decode failed: \(item.id)\n", stderr)
                    return
                }

                let src = resizeToLongEdge(rawSrc, maxEdge: maxEdge)
                let tgt = resizeToMatch(rawTgt, size: src.extent.size)

                var opts = ColorMatchOptions()
                opts.matchExposure = true
                opts.matchToneCurve = true
                opts.matchColorGrade = true
                opts.matchHSL = true
                opts.matchFilmTexture = item.matchFilmTexture ?? false
                opts.protectSkinTones = item.protectSkinTones ?? true
                opts.strength = 1.0

                let res = ColorMatchEngine.solve(source: src, reference: tgt, base: EditParams(), options: opts)
                let (planDict, quantizedParams) = quantizeToPhotoAIPlan(
                    res.params,
                    summary: item.summary ?? defaultSummary(for: res.params)
                )

                // 用严格量化后的 PhotoAIPlan 参数经由真实 Engine.render 渲染并评测 SSIM / OKLab ΔE
                let rendered = Engine.render(src, quantizedParams)
                let (rSSIM, rDE) = compareImages(rendered, tgt)
                let ok = rSSIM >= minSSIM && rDE <= maxDE
                if ok { passed += 1 } else { failed += 1 }

                // 导出 768px 训练输入图（原图）
                let relImgPath = "images/\(sanitizeID(item.id)).jpg"
                let imgDest = outDir.appendingPathComponent(relImgPath)
                let savedOK = saveJPEG(src, to: imgDest, quality: 0.90)
                guard savedOK else { failed += 1; return }

                let record: [String: Any] = [
                    "id": item.id,
                    "groupId": item.groupId ?? "pair-\(item.id)",
                    "styleLabel": item.styleLabel ?? "expert",
                    "instruction": item.instruction ?? "优化整体光影层次与色彩质感，呈现自然耐看的专业成片风格；保留人物肤色与画面原有氛围，不要新增蒙版。",
                    "image": relImgPath,
                    "sourcePath": item.source,
                    "targetPath": item.target,
                    "plan": planDict,
                    "metrics": [
                        "initialDeltaE": round3(res.initialDeltaE),
                        "solverFinalDeltaE": round3(res.finalDeltaE),
                        "renderedDeltaE": round3(rDE),
                        "renderedSSIM": round4(rSSIM),
                        "elapsedMs": round1(res.elapsedMs),
                        "passedGate": ok
                    ]
                ]
                if let jsonData = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                   let line = String(data: jsonData, encoding: .utf8) {
                    lines.append(line)
                }
                print(String(format: "[%d/%d] %@ | SSIM=%.3f dE=%.2f (init=%.2f) | %@ | %.0fms",
                             idx + 1, pairs.count, item.id, rSSIM, rDE, res.initialDeltaE,
                             ok ? "PASS" : "DROP", res.elapsedMs))
                fflush(stdout)
            }
        }

        let outFile = outDir.appendingPathComponent("solved_pairs.jsonl")
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: outFile, atomically: true, encoding: .utf8)
        print("DONE: total=\(pairs.count) passed=\(passed) dropped=\(failed) -> \(outFile.path)")
    }

    // MARK: - 量化至严格 PhotoAIPlan Schema 契约

    private static func roundStep(_ v: Double, step: Double, lo: Double, hi: Double) -> Double {
        let clamped = min(max(v, lo), hi)
        let stepped = (clamped / step).rounded() * step
        return (stepped * 100.0).rounded() / 100.0
    }

    private static func quantizeToPhotoAIPlan(_ solved: EditParams, summary: String) -> ([String: Any], EditParams) {
        var q = EditParams()
        var adj: [String: Any] = [:]

        func setNum(_ key: String, _ val: Double, step: Double, lo: Double, hi: Double, tol: Double,
                    assign: (Double) -> Void) {
            let rv = roundStep(val, step: step, lo: lo, hi: hi)
            if abs(rv) >= tol {
                assign(rv)
                adj[key] = step >= 1.0 ? Int(rv.rounded()) : rv
            }
        }

        setNum("exposure",    solved.exposure,    step: 0.05, lo: -5,   hi: 5,   tol: 0.05) { q.exposure = $0 }
        setNum("contrast",    solved.contrast,    step: 1,    lo: -100, hi: 100, tol: 2)    { q.contrast = $0 }
        setNum("highlights",  solved.highlights,  step: 1,    lo: -100, hi: 100, tol: 2)    { q.highlights = $0 }
        setNum("shadows",     solved.shadows,     step: 1,    lo: -100, hi: 100, tol: 2)    { q.shadows = $0 }
        setNum("whites",      solved.whites,      step: 1,    lo: -100, hi: 100, tol: 2)    { q.whites = $0 }
        setNum("blacks",      solved.blacks,      step: 1,    lo: -100, hi: 100, tol: 2)    { q.blacks = $0 }
        setNum("temperature", solved.temperature, step: 1,    lo: -100, hi: 100, tol: 2)    { q.temperature = $0 }
        setNum("tint",        solved.tint,        step: 1,    lo: -100, hi: 100, tol: 2)    { q.tint = $0 }
        setNum("vibrance",    solved.vibrance,    step: 1,    lo: -100, hi: 100, tol: 2)    { q.vibrance = $0 }
        setNum("saturation",  solved.saturation,  step: 1,    lo: -100, hi: 100, tol: 2)    { q.saturation = $0 }
        setNum("clarity",     solved.clarity,     step: 1,    lo: -100, hi: 100, tol: 2)    { q.clarity = $0 }
        setNum("texture",     solved.texture,     step: 1,    lo: -100, hi: 100, tol: 2)    { q.texture = $0 }
        setNum("dehaze",      solved.dehaze,      step: 1,    lo: -100, hi: 100, tol: 2)    { q.dehaze = $0 }
        setNum("grain",       solved.grain,       step: 1,    lo: 0,    hi: 100, tol: 2)    { q.grain = $0 }
        setNum("vignette",    solved.vignette,    step: 1,    lo: -100, hi: 100, tol: 2)    { q.vignette = $0 }

        var plan: [String: Any] = [
            "summary": String(summary.prefix(160)),
            "adjustments": adj,
            "masks": []
        ]

        // 5 点单调亮度曲线（仅在偏离恒等曲线 >= 0.02 时输出）
        if !solved.lumaCurve.isIdentity {
            let xs = [0.0, 0.25, 0.5, 0.75, 1.0]
            var ys: [Double] = []
            var prev = 0.0
            for x in xs {
                let rawY = solved.lumaCurve.value(at: x)
                let y = max(prev, roundStep(rawY, step: 0.01, lo: 0, hi: 1))
                ys.append(y)
                prev = y
            }
            let maxDev = zip(xs, ys).map { abs($0 - $1) }.max() ?? 0
            if maxDev >= 0.02 {
                let pts = zip(xs, ys).map { [$0, $1] }
                q.lumaCurve = ToneCurve(points: pts)
                plan["curves"] = ["luma": pts]
            }
        }

        // 8 通道 HSL（仅保留有实质调整的色域）
        let bandNames = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
        var hslDict: [String: [String: Int]] = [:]
        var qHSL = q.hsl
        for i in 0..<8 {
            let b = solved.hsl[i]
            let h = Int(roundStep(b.hue, step: 1, lo: -60, hi: 60).rounded())
            let s = Int(roundStep(b.sat, step: 1, lo: -100, hi: 100).rounded())
            let l = Int(roundStep(b.lum, step: 1, lo: -100, hi: 100).rounded())
            if abs(h) >= 3 || abs(s) >= 4 || abs(l) >= 4 {
                qHSL[i].hue = Double(h); qHSL[i].sat = Double(s); qHSL[i].lum = Double(l)
                hslDict[bandNames[i]] = ["hue": h, "sat": s, "lum": l]
            }
        }
        if !hslDict.isEmpty {
            q.hsl = qHSL
            plan["hsl"] = hslDict
        }

        // 三段颜色分级（仅保留饱和度 >= 3 或明度偏移 >= 3 的色轮）
        var gradeDict: [String: [String: Int]] = [:]
        func quantizeGrade(_ g: ColorGrade) -> (ColorGrade, [String: Int])? {
            let h = Int(roundStep(g.hue, step: 1, lo: 0, hi: 360).rounded())
            let s = Int(roundStep(g.sat, step: 1, lo: 0, hi: 100).rounded())
            let l = Int(roundStep(g.lum, step: 1, lo: -100, hi: 100).rounded())
            guard s >= 3 || abs(l) >= 3 else { return nil }
            var out = ColorGrade(); out.hue = Double(h); out.sat = Double(s); out.lum = Double(l)
            return (out, ["hue": h, "sat": s, "lum": l])
        }
        if let (g, d) = quantizeGrade(solved.gradeShadow) { q.gradeShadow = g; gradeDict["shadows"] = d }
        if let (g, d) = quantizeGrade(solved.gradeMid)    { q.gradeMid = g;    gradeDict["midtones"] = d }
        if let (g, d) = quantizeGrade(solved.gradeHigh)   { q.gradeHigh = g;   gradeDict["highlights"] = d }
        if !gradeDict.isEmpty { plan["grading"] = gradeDict }

        return (plan, q)
    }

    private static func defaultSummary(for p: EditParams) -> String {
        var parts: [String] = []
        if p.exposure >= 0.15 { parts.append("提亮整体曝光") }
        else if p.exposure <= -0.15 { parts.append("适当压低曝光") }
        if p.contrast >= 6 { parts.append("增强影调反差") }
        else if p.contrast <= -6 { parts.append("柔化画面反差") }
        if p.highlights <= -10 { parts.append("收回高光细节") }
        if p.shadows >= 10 { parts.append("抬升暗部层次") }
        if p.temperature >= 6 { parts.append("微调暖色温") }
        else if p.temperature <= -6 { parts.append("微调冷色温") }
        if p.vibrance >= 6 || p.saturation >= 6 { parts.append("丰富色彩表现") }
        else if p.vibrance <= -6 || p.saturation <= -6 { parts.append("收敛色彩饱和") }
        if !p.gradeShadow.isNeutral || !p.gradeHigh.isNeutral { parts.append("配合三段色彩分级定调") }
        if parts.isEmpty { return "微调画面明暗与色彩平衡，呈现自然耐看的成片观感。" }
        return parts.prefix(4).joined(separator: "，") + "。"
    }

    // MARK: - 图像缩放与渲染质量指标（SSIM & OKLab ΔE）

    private static func resizeToLongEdge(_ img: CIImage, maxEdge: CGFloat) -> CIImage {
        let e = img.extent
        let zeroed = (e.minX != 0 || e.minY != 0)
            ? img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            : img
        let long = max(zeroed.extent.width, zeroed.extent.height)
        guard long > maxEdge, long > 1 else { return zeroed }
        let s = maxEdge / long
        return zeroed.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    private static func resizeToMatch(_ img: CIImage, size: CGSize) -> CIImage {
        let e = img.extent
        let zeroed = (e.minX != 0 || e.minY != 0)
            ? img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            : img
        let sx = size.width / max(zeroed.extent.width, 1)
        let sy = size.height / max(zeroed.extent.height, 1)
        return zeroed.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func compareImages(_ a: CIImage, _ b: CIImage) -> (ssim: Double, deltaE: Double) {
        let side: CGFloat = 256
        let sa = resizeToLongEdge(a, maxEdge: side)
        let w = max(8, Int(sa.extent.width.rounded()))
        let h = max(8, Int(sa.extent.height.rounded()))
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let sb = resizeToMatch(b, size: rect.size)

        var bufA = [UInt8](repeating: 0, count: w * h * 4)
        var bufB = [UInt8](repeating: 0, count: w * h * 4)
        Engine.ctx.render(sa, toBitmap: &bufA, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: Engine.srgb)
        Engine.ctx.render(sb, toBitmap: &bufB, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: Engine.srgb)

        let px = w * h
        var lumaA = [Double](repeating: 0, count: px)
        var lumaB = [Double](repeating: 0, count: px)
        var sumDE = 0.0

        func toLin(_ u: UInt8) -> Double {
            let v = Double(u) / 255.0
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func rgbToOKLab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            let l = cbrt(max(0, 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b))
            let m = cbrt(max(0, 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b))
            let s = cbrt(max(0, 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b))
            let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
            return (L, A, B)
        }

        for i in 0..<px {
            let o = i * 4
            let ra = Double(bufA[o]) / 255.0, ga = Double(bufA[o+1]) / 255.0, ba = Double(bufA[o+2]) / 255.0
            let rb = Double(bufB[o]) / 255.0, gb = Double(bufB[o+1]) / 255.0, bb = Double(bufB[o+2]) / 255.0
            lumaA[i] = 0.2126 * ra + 0.7152 * ga + 0.0722 * ba
            lumaB[i] = 0.2126 * rb + 0.7152 * gb + 0.0722 * bb
            let la = rgbToOKLab(toLin(bufA[o]), toLin(bufA[o+1]), toLin(bufA[o+2]))
            let lb = rgbToOKLab(toLin(bufB[o]), toLin(bufB[o+1]), toLin(bufB[o+2]))
            let dL = la.0 - lb.0, dA = la.1 - lb.1, dB = la.2 - lb.2
            sumDE += sqrt(dL * dL + dA * dA + dB * dB) * 100.0
        }

        // 8×8 分块平均 SSIM（亮度通道）
        let bs = 8
        let c1 = 0.01 * 0.01, c2 = 0.03 * 0.03
        var ssimSum = 0.0
        var blocks = 0
        var y = 0
        while y + bs <= h {
            var x = 0
            while x + bs <= w {
                var ma = 0.0, mb = 0.0
                for dy in 0..<bs {
                    let row = (y + dy) * w + x
                    for dx in 0..<bs { ma += lumaA[row + dx]; mb += lumaB[row + dx] }
                }
                let invN = 1.0 / Double(bs * bs)
                ma *= invN; mb *= invN
                var va = 0.0, vb = 0.0, cov = 0.0
                for dy in 0..<bs {
                    let row = (y + dy) * w + x
                    for dx in 0..<bs {
                        let da = lumaA[row + dx] - ma, db = lumaB[row + dx] - mb
                        va += da * da; vb += db * db; cov += da * db
                    }
                }
                va *= invN; vb *= invN; cov *= invN
                let num = (2 * ma * mb + c1) * (2 * cov + c2)
                let den = (ma * ma + mb * mb + c1) * (va + vb + c2)
                ssimSum += num / max(den, 1e-9)
                blocks += 1
                x += bs
            }
            y += bs
        }
        let meanSSIM = blocks > 0 ? ssimSum / Double(blocks) : 0
        return (meanSSIM, sumDE / Double(max(px, 1)))
    }

    private static func saveJPEG(_ img: CIImage, to url: URL, quality: CGFloat) -> Bool {
        guard let cg = Engine.ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: Engine.srgb),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func sanitizeID(_ s: String) -> String {
        String(s.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
    }
    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
