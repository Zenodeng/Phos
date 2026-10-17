// 自动流水线：筛掉没对上焦的 → 按主体裁成 3:2 / 2:3 → 统一色调与曝光 → 导出。
//
// 和 BatchAuto 一样走命令行（界面上一次只能处理一张），复用 Phos 自家的
// Engine / SceneClassifier / AutoTone / Sidecar，出来的结果与在界面里手调一致。
//
// 用法：
//   AutoFinish focus <图片或目录...>                 只打清晰度分并给出建议阈值
//   AutoFinish run   --out <导出目录> [选项] <目录>    跑完整流水线
//
// 选项：
//   --out <目录>         导出目录（run 必填）
//   --focus-ratio <0..1> 相对阈值：低于「全批中位分 × 该比例」判为脱焦，默认 0.45
//   --crop <auto|none>   auto=按主体取向裁成 3:2/2:3（默认），none=保留原画幅
//   --min-retain <0..1>  裁切后至少保留的原图面积比例，防止裁太狠，默认 0.40
//   --scene <名称>       影调题材，默认 portrait（护肤色、不加对比、饱和克制）
//   --wb-unify <0..1>    白平衡向全批中位数靠拢的比例，0=各算各的，1=完全统一，默认 0.6
//   --long-edge <px>     导出长边，0=原始尺寸（默认）
//   --quality <0..1>     JPEG 质量，默认 0.92
//   --limit <n>          只处理前 n 张（调试用）
//   --dry                不写旁档也不导出，只打印决定
//
// 安全边界：只写 .rawforge.json 与导出目录，绝不改动原始照片。

import Foundation
import CoreImage
import Vision

@main
struct AutoFinish {
    // MARK: - 入口

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else { usage(); exit(2) }
        args.removeFirst()

        var outDir = ""
        var focusRatio = 0.45
        var doCrop = true
        var minRetain = 0.40
        var sceneName = "portrait"
        var wbUnify = 0.6
        var longEdge = 0
        var quality = 0.92
        var limit = 0
        var dry = false
        var styleName = ""          // "" = 只要自动影调；sports = 再叠一层风格
        var styleStrength = 1.0
        var noCull = false
        var paths: [String] = []

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--out":        i += 1; outDir = args[safe: i] ?? ""
            case "--focus-ratio": i += 1; focusRatio = Double(args[safe: i] ?? "") ?? 0.45
            case "--crop":       i += 1; doCrop = (args[safe: i] ?? "auto") != "none"
            case "--min-retain": i += 1; minRetain = Double(args[safe: i] ?? "") ?? 0.40
            case "--scene":      i += 1; sceneName = args[safe: i] ?? "portrait"
            case "--wb-unify":   i += 1; wbUnify = Double(args[safe: i] ?? "") ?? 0.6
            case "--long-edge":  i += 1; longEdge = Int(args[safe: i] ?? "") ?? 0
            case "--quality":    i += 1; quality = Double(args[safe: i] ?? "") ?? 0.92
            case "--limit":      i += 1; limit = Int(args[safe: i] ?? "") ?? 0
            case "--style":      i += 1; styleName = args[safe: i] ?? ""
            case "--style-strength": i += 1; styleStrength = Double(args[safe: i] ?? "") ?? 1
            case "--no-cull":    noCull = true
            case "--dry":        dry = true
            default:             paths.append(args[i])
            }
            i += 1
        }
        guard !paths.isEmpty else { print("没有指定图片或目录"); exit(2) }

        var files = collect(paths)
        if limit > 0 { files = Array(files.prefix(limit)) }
        guard !files.isEmpty else { print("没有找到可处理的图片"); exit(2) }
        print("待处理 \(files.count) 张\n")

        if mode == "focus" { focusOnly(files); exit(0) }
        if mode == "sweep" { styleSweep(files, styleStrength); exit(0) }
        if mode == "diag" { styleDiag(files, styleStrength); exit(0) }
        guard mode == "run" else { print("未知模式：\(mode)"); exit(2) }
        guard !outDir.isEmpty else { print("run 需要 --out <导出目录>"); exit(2) }

        run(files,
            outDir: URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath),
            focusRatio: noCull ? 0 : focusRatio, doCrop: doCrop, minRetain: minRetain,
            scene: PhotoScene(rawValue: sceneName), wbUnify: wbUnify,
            longEdge: longEdge, quality: quality, dry: dry,
            style: styleName.isEmpty ? nil : styleName, styleStrength: styleStrength)
    }

    /// 风格标定：对同一张图试几档强度，把渲染结果的统计量打表出来。
    /// 目的就是把「有劲儿」翻译成能对比的数字，而不是靠猜。
    static func styleSweep(_ files: [URL], _ k: Double) {
        guard let url = files.first else { print("没有图片"); exit(2) }
        guard let src = Engine.decode(url) else { print("无法解码"); exit(2) }
        print("标定图：\(url.lastPathComponent)\n")
        print(String(format: "%-10@ %7@ %7@ %7@ %7@ %7@ %8@",
                     "强度" as NSString, "中位" as NSString, "p05" as NSString,
                     "p95" as NSString, "跨度" as NSString, "彩度" as NSString, "高光溢" as NSString))
        func show(_ label: String, _ p: EditParams) {
            // ⚠️ 必须先 render 再 measure：AutoTone.measure 只套几何（裁剪/旋转），
            // 不套曝光对比。拿 (src, params) 当结果量，量到的永远是处理前的原图，
            // 于是每一行都一样 —— 等于没标定。
            guard let st = AutoTone.measure(Engine.render(src, p), params: EditParams()) else { return }
            print(String(format: "%-10@ %7.3f %7.3f %7.3f %7.3f %7.4f %8.4f", label as NSString,
                         st.median, st.p05, st.p95, st.span, st.avgSat, st.clipHigh))
        }
        show("原图", EditParams())

        let guess = SceneGuess(scene: .portrait, confidence: 1)
        let sol = AutoTone.analyze(src, params: EditParams(), scene: guess)
        let autoOnly = AutoTone.apply(sol, to: EditParams(), strength: 1)
        show("仅自动", autoOnly)
        for s in [0.6, 0.8, 1.0, 1.3, 1.6] {
            var p = autoOnly
            sportsStyle(s * k).apply(to: &p)
            show(String(format: "运动%.1f", s * k), p)
        }
        print("\n怎么判：跨度要明显拉开、彩度比「仅自动」高一截、高光溢出不涨太多。")
    }

    /// 逐参数诊断：一次只叠一个风格分量，看清是谁在压暗部。
    /// 先前的猜测（blacks / contrast）都被标定推翻了，所以改成逐个拆开量。
    static func styleDiag(_ files: [URL], _ k: Double) {
        guard let url = files.first else { print("没有图片"); exit(2) }
        guard let src = Engine.decode(url) else { print("无法解码"); exit(2) }
        let guess = SceneGuess(scene: .portrait, confidence: 1)
        let sol = AutoTone.analyze(src, params: EditParams(), scene: guess)
        let autoOnly = AutoTone.apply(sol, to: EditParams(), strength: 1)
        print("逐参数诊断（基准 = 仅自动影调）：\(url.lastPathComponent)")
        print(String(format: "%-12@ %7@ %7@ %7@ %7@ %7@", "项" as NSString, "中位" as NSString,
                     "p05" as NSString, "跨度" as NSString, "彩度" as NSString, "高光溢" as NSString))
        func show(_ label: String, _ p: EditParams) {
            guard let st = AutoTone.measure(Engine.render(src, p), params: EditParams()) else { return }
            print(String(format: "%-12@ %7.3f %7.3f %7.3f %7.3f %8.4f", label as NSString,
                         st.median, st.p05, st.span, st.avgSat, st.clipHigh))
        }
        show("基准", autoOnly)
        let full = sportsStyle(k)
        show("整套", { var p = autoOnly; full.apply(to: &p); return p }())
        let names = ["contrast", "clarity", "texture", "vibrance", "saturation",
                     "dehaze", "whites", "blacks", "temperature", "sharpen"]
        for n in names {
            var l = StyleLayer()
            switch n {
            case "contrast": l.contrast = full.contrast
            case "clarity": l.clarity = full.clarity
            case "texture": l.texture = full.texture
            case "vibrance": l.vibrance = full.vibrance
            case "saturation": l.saturation = full.saturation
            case "dehaze": l.dehaze = full.dehaze
            case "whites": l.whites = full.whites
            case "blacks": l.blacks = full.blacks
            case "temperature": l.temperature = full.temperature
            case "sharpen": l.sharpen = full.sharpen
            default: break
            }
            var p = autoOnly
            l.apply(to: &p)
            show("+" + n, p)
        }
    }


    static func usage() {
        print("""
        用法:
          AutoFinish focus <图片或目录...>
          AutoFinish run --out <导出目录> [选项] <图片或目录...>
        """)
    }

    // MARK: - 单张的分析结果

    struct Info {
        let url: URL
        var size: CGSize = .zero
        var focus: Double = 0        // 主体区域拉普拉斯方差（无主体时取全画面）
        var focusGlobal: Double = 0   // 归一化分（全画面）
        var focusRaw: Double = 0      // 拉普拉斯方差原始值，只用于打印
        var subject: CGRect? = nil   // 归一化，原点在左下（与 CIImage / Vision 一致）
        var subjectKind: String = "无"
        var crop: CGRect? = nil      // 归一化裁剪框
        var gains: [Double] = [1, 1, 1]
        var solution: AutoTone.Solution? = nil
        var culled = false
    }

    // MARK: - 风格层

    /// 在自动影调之上再叠一层固定风格。单位与 EditParams 一致。
    ///
    /// 这套参数是**数值标定**出来的，不是凭手感：先在少量照片上试算，
    /// 看渲染结果的亮度分布 / 彩度 / 高光溢出，再定数值。理由见 memory 里
    /// 「渲染管线跑在线性空间」——对比是绕线性 0.5 放大的，按 sRGB 直觉估会严重跑偏。
    struct StyleLayer {
        var contrast: Double = 0      // 线性空间的对比，压暗部很凶，别多给
        var clarity: Double = 0       // 局部对比：运动感的真正来源，比全局对比安全
        var texture: Double = 0
        var vibrance: Double = 0
        var saturation: Double = 0
        var dehaze: Double = 0
        var whites: Double = 0
        var blacks: Double = 0
        var temperature: Double = 0
        var sharpen: Double = 0

        func scaled(_ k: Double) -> StyleLayer {
            StyleLayer(contrast: contrast * k, clarity: clarity * k, texture: texture * k,
                       vibrance: vibrance * k, saturation: saturation * k, dehaze: dehaze * k,
                       whites: whites * k, blacks: blacks * k,
                       temperature: temperature * k, sharpen: sharpen * k)
        }
        func apply(to p: inout EditParams) {
            p.contrast   += contrast
            p.clarity    += clarity
            p.texture    += texture
            p.vibrance   += vibrance
            p.saturation += saturation
            p.dehaze     += dehaze
            p.whites     += whites
            p.blacks     += blacks
            p.temperature += temperature
            p.sharpen    += sharpen
        }
    }

    /// 「运动系」风格：高局部对比、控高光、饱和偏足、轻微暖。
    ///
    /// ⚠️ 标定过的两条红线：
    /// 1) `contrast` 和 `blacks` 都不敢多给。第一版给了 contrast +9 / blacks -7，
    ///    结果 p05 从 0.075 被压到 0.000 —— 暗部清零。运动会大量主体在阴影里
    ///    （看台、树荫、傍晚），清零就是把人脸拍成黑洞。现在改用「高 clarity + 低对比」：
    ///    clarity 是局部对比，只拉反差不压整体，出劲儿但不动暗部。
    /// 2) 中位数会被风格拉低（对比和压黑都收光），所以 whites 要给正的去补。
    static func sportsStyle(_ k: Double) -> StyleLayer {
        StyleLayer(contrast: 4, clarity: 18, texture: 6,
                   vibrance: 10, saturation: 5, dehaze: 8,
                   whites: 7, blacks: -2.5, temperature: 3,
                   sharpen: 0.14).scaled(k)
    }

    // MARK: - 只打清晰度分

    struct Row {
        let name: String
        let lap: Double        // 整幅原生（判据）
        let lapSubject: Double // 主体区原生（参考）
        let norm: Double
        let lumaVar: Double
    }

    static func focusOnly(_ files: [URL]) {
        var rows: [Row] = []
        for url in files {
            guard let src = Engine.decode(url) else { continue }
            let r = measureFocus(src, subject: detectSubject(src))
            rows.append(Row(name: url.lastPathComponent, lap: r.lapVar,
                            lapSubject: r.lapSubject, norm: r.score, lumaVar: r.lumaVar))
        }
        let laps = rows.map { $0.lap }.sorted()
        guard let med = laps[safe: laps.count / 2] else { exit(1) }
        print("全批对焦分（拉普拉斯方差，整幅原生分辨率）中位数：\(String(format: "%.1f", med))")
        print("分位：p05=\(q(laps, 0.05))  p10=\(q(laps, 0.10))  p25=\(q(laps, 0.25))  p50=\(q(laps, 0.50))  p75=\(q(laps, 0.75))  p90=\(q(laps, 0.90))")
        print("最低 20 张：")
        for r in rows.sorted(by: { $0.lap < $1.lap }).prefix(20) {
            print(String(format: "  %-16@ 整幅 %9.1f  主体 %9.1f  归一 %.5f  灰度方差 %7.1f",
                         r.name as NSString, r.lap, r.lapSubject, r.norm, r.lumaVar))
        }
        print("最高 5 张（对照）：")
        for r in rows.sorted(by: { $0.lap > $1.lap }).prefix(5) {
            print(String(format: "  %-16@ 整幅 %9.1f  主体 %9.1f  归一 %.5f  灰度方差 %7.1f",
                         r.name as NSString, r.lap, r.lapSubject, r.norm, r.lumaVar))
        }
        for ratio in [0.20, 0.25, 0.30, 0.35, 0.45] {
            let t = med * ratio
            print(String(format: "阈值 中位×%.2f = %8.1f → 剔除 %d 张",
                         ratio, t, rows.filter { $0.lap < t }.count))
        }

        // 落一份明细，方便按连拍串核对：同一串的分数应当彼此接近，
        // 如果串内忽高忽低说明这个指标不稳，不能拿来筛片。
        let dump = "build/autofinish/focus-scores.txt"
        try? FileManager.default.createDirectory(atPath: "build/autofinish",
                                                 withIntermediateDirectories: true)
        var text = "# 名称\t整幅分\t主体分\t归一化\t灰度方差\n"
        for r in rows {
            text += String(format: "%@\t%.1f\t%.1f\t%.5f\t%.1f\n",
                           r.name, r.lap, r.lapSubject, r.norm, r.lumaVar)
        }
        try? text.write(toFile: dump, atomically: true, encoding: .utf8)
        print("\n明细已写入 \(dump)")

        // 抽查主体框：确认 Vision 的坐标原点（左下）与 CIImage 一致、框的位置说得通
        print("\n主体框抽查（归一化，原点左下）：")
        var shown = 0
        for url in files where shown < 8 {
            guard let src = Engine.decode(url) else { continue }
            if let s = detectSubject(src) {
                print(String(format: "  %-16@ x %.3f  y %.3f  宽 %.3f  高 %.3f",
                             url.lastPathComponent as NSString,
                             s.minX, s.minY, s.width, s.height))
            } else {
                print("  \(url.lastPathComponent)  未识别到主体")
            }
            shown += 1
        }
    }

    static func q(_ sorted: [Double], _ p: Double) -> String {
        guard !sorted.isEmpty else { return "-" }
        let i = min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))
        return String(format: "%.1f", sorted[i])
    }


    // MARK: - 完整流水线

    static func run(_ files: [URL], outDir: URL, focusRatio: Double, doCrop: Bool,
                    minRetain: Double, scene: PhotoScene?, wbUnify: Double,
                    longEdge: Int, quality: Double, dry: Bool,
                    style: String? = nil, styleStrength: Double = 1) {
        let fm = FileManager.default
        if !dry { try? fm.createDirectory(at: outDir, withIntermediateDirectories: true) }

        // ---- 第一遍：解码 → 主体检测 → 清晰度打分 ----
        print("① 检测主体 + 清晰度打分…")
        var infos: [Info] = []
        for (n, url) in files.enumerated() {
            if n % 50 == 0 { print("   \(n)/\(files.count)") }
            // ⚠️ 每张都要 autoreleasepool：CI 的中间结果是 autorelease 的，
            // 顶层循环没有外层 pool，不手动放就会一路攒到进程退出 —— 383 张跑到第 40 张
            // 左右就被系统 OOM 杀掉（Killed: 9）。
            var made: Info?
            autoreleasepool {
                guard let src = Engine.decode(url) else {
                    print("   跳过（无法解码）：\(url.lastPathComponent)"); return
                }
                var info = Info(url: url)
                info.size = CGSize(width: src.extent.width, height: src.extent.height)
                let subj = detectSubject(src)
                info.subject = subj
                info.subjectKind = subj == nil ? "无" : "有"
                let fr = measureFocus(src, subject: subj)
                info.focus = fr.lapVar
                info.focusRaw = fr.lapVar
                info.focusGlobal = fr.lapVar
                made = info
            }
            if let m = made { infos.append(m) }
        }

        // ---- 筛掉脱焦 ----
        let scored = infos.map { $0.focus }.sorted()
        guard let med = scored[safe: scored.count / 2] else { exit(1) }
        let threshold = med * focusRatio
        var culled: [Info] = []
        for i in infos.indices {
            if infos[i].focus < threshold { infos[i].culled = true; culled.append(infos[i]) }
        }
        let kept = infos.filter { !$0.culled }
        print("\n② 清晰度阈值 \(String(format: "%.1f", threshold))（中位 \(String(format: "%.1f", med)) × \(focusRatio)）")
        print("   脱焦剔除 \(culled.count) 张，保留 \(kept.count) 张")
        if !culled.isEmpty {
            print("   剔除清单（按分数升序）：")
            for c in culled.sorted(by: { $0.focus < $1.focus }).prefix(20) {
                print(String(format: "     %-16@ 方差 %8.1f（中位的 %3.0f%%）",
                             c.url.lastPathComponent as NSString, c.focus,
                             c.focus / med * 100))
            }
            if culled.count > 20 { print("     … 另有 \(culled.count - 20) 张") }
        }

        // ---- 裁切决策 ----
        print("\n③ 裁切决策（\(doCrop ? "按主体取向裁 3:2 / 2:3" : "保留原画幅")）")
        var portraitCount = 0, landscapeCount = 0, noSubject = 0
        for i in infos.indices where !infos[i].culled {
            guard doCrop, let s = infos[i].subject else { noSubject += 1; continue }
            let c = planCrop(imageSize: infos[i].size, subject: s, minRetain: minRetain)
            infos[i].crop = c
            if c.width < c.height * (infos[i].size.width / infos[i].size.height) {
                // 归一化宽高要乘回原图尺寸才能比
            }
            let pxW = c.width * infos[i].size.width, pxH = c.height * infos[i].size.height
            if pxW < pxH { portraitCount += 1 } else { landscapeCount += 1 }
        }
        print("   竖幅 2:3 \(portraitCount) 张　横幅 3:2 \(landscapeCount) 张　未识别到主体（保留全画幅）\(noSubject) 张")

        // ---- 第二遍：带裁切跑自动影调，收集白平衡 ----
        print("\n④ 自动影调（题材：\(scene?.label ?? "自动识别")）…")
        if let style { print("   叠加风格：\(style)（强度 \(styleStrength)）") }
        var gainR: [Double] = [], gainG: [Double] = [], gainB: [Double] = []
        for i in infos.indices where !infos[i].culled {
            var got: (AutoTone.Solution, [Double])?
            autoreleasepool {
                guard let src = Engine.decode(infos[i].url) else { return }
                var base = SidecarStore.load(for: infos[i].url)?.params ?? EditParams()
                if let c = infos[i].crop {
                    base.cropX = c.minX; base.cropY = c.minY
                    base.cropW = c.width; base.cropH = c.height
                }
                let guess = scene.map { SceneGuess(scene: $0, confidence: 1) } ?? SceneClassifier.classify(src)
                let sol = AutoTone.analyze(src, params: base, scene: guess)
                got = (sol, sol.gains)
            }
            guard let g = got else { continue }
            infos[i].solution = g.0
            infos[i].gains = g.1
            if g.1.count == 3 {
                gainR.append(g.1[0]); gainG.append(g.1[1]); gainB.append(g.1[2])
            }
        }
        let medGains = [median(gainR), median(gainG), median(gainB)]
        print(String(format: "   全批白平衡中位数增益 R %.3f  G %.3f  B %.3f（统一度 %.0f%%）",
                     medGains[0], medGains[1], medGains[2], wbUnify * 100))

        // ---- 第三遍：白平衡向中位数靠拢 → 写旁档 → 导出 ----
        print("\n⑤ 写旁档 + 导出…")
        var settings = ExportSettings()
        settings.format = "jpg"
        settings.quality = quality
        settings.maxLongEdge = longEdge

        var exported = 0, failed = 0
        var outMedians: [Double] = [], outClips: [Double] = [], inMedians: [Double] = []
        for i in infos.indices where !infos[i].culled {
            var got: (median: Double, clip: Double, before: Double, ok: Bool)?
            autoreleasepool {
                guard let src = Engine.decode(infos[i].url), let sol = infos[i].solution else { return }
                var base = SidecarStore.load(for: infos[i].url)?.params ?? EditParams()
                if let c = infos[i].crop {
                    base.cropX = c.minX; base.cropY = c.minY
                    base.cropW = c.width; base.cropH = c.height
                }
                // 增益是乘性的，所以在指数域向中位数插值。
                var s2 = sol
                s2.gains = (0..<3).map { k in
                    pow(max(medGains[k], 1e-3), wbUnify) * pow(max(sol.gains[k], 1e-3), 1 - wbUnify)
                }
                let next0 = AutoTone.apply(s2, to: base, strength: 1)
                var next = next0
                // 风格层叠在最后：自动管「对不对」，风格管「哪一路」
                if let style, style == "sports" {
                    sportsStyle(styleStrength).apply(to: &next)
                }
                infos[i].gains = s2.gains

                if !dry {
                    var sc = SidecarStore.load(for: infos[i].url) ?? Sidecar(params: base)
                    sc.params = next
                    sc.version = 2
                    if !SidecarStore.save(sc, for: infos[i].url) {
                        print("   旁档写入失败：\(infos[i].url.lastPathComponent)")
                    }
                }

                // 用最终参数渲一遍，顺便核对曝光与高光。
                // ⚠️ 必须量「渲染结果」：AutoTone.measure 只套几何（裁剪/旋转），
                // 不套曝光对比这些影调参数。量 (src, next) 拿到的还是处理前的原图，
                // 那样这个自检等于没做。
                // 「处理前」= 裁好但没上影调；「处理后」= 最终成片。两者都量，改善才有对照。
                let before = AutoTone.measure(src, params: base)?.median ?? -1
                let rendered = Engine.render(src, next)
                var med: Double? = nil, clip: Double? = nil
                if let st = AutoTone.measure(rendered, params: EditParams()) {
                    med = st.median; clip = st.clipHigh
                }

                var ok = true
                if !dry {
                    let stem = infos[i].url.deletingPathExtension().lastPathComponent
                    let dest = outDir.appendingPathComponent("\(stem).jpg")
                    do {
                        try Engine.write(rendered, to: dest, settings: settings)
                    } catch {
                        print("   导出失败 \(stem)：\(error.localizedDescription)")
                        ok = false
                    }
                }
                got = (med ?? -1, clip ?? -1, before, ok)
            }
            guard let g = got else { failed += 1; continue }
            if g.median >= 0 { outMedians.append(g.median); outClips.append(g.clip) }
            if g.before >= 0 { inMedians.append(g.before) }
            if g.ok { exported += 1 } else { failed += 1 }
        }

        // ---- 疑似脱焦的单独导出一份小图，方便人工复核（原片一律不动、不删）----
        if !culled.isEmpty && !dry {
            let rejectDir = outDir.appendingPathComponent("疑似脱焦-请复核")
            try? fm.createDirectory(at: rejectDir, withIntermediateDirectories: true)
            var rs = settings
            rs.maxLongEdge = 1600
            for c in culled {
                autoreleasepool {
                    guard let src = Engine.decode(c.url) else { return }
                    let img = Engine.render(src, EditParams())
                    let stem = c.url.deletingPathExtension().lastPathComponent
                    try? Engine.write(img, to: rejectDir.appendingPathComponent("\(stem).jpg"), settings: rs)
                }
            }
            print("\n   疑似脱焦 \(culled.count) 张已导出到「疑似脱焦-请复核/」（原片未动，可自行删掉这个文件夹）")
        }

        // ---- 汇总自检 ----
        print("\n———— 汇总 ————")
        print("保留并导出 \(exported) 张　脱焦剔除 \(culled.count) 张　失败 \(failed) 张")
        if !outMedians.isEmpty {
            let m = outMedians.sorted()
            print(String(format: "亮度中位数 处理前：均值 %.3f　标准差 %.3f", mean(inMedians), stdev(inMedians)))
            print(String(format: "亮度中位数 处理后：均值 %.3f　最小 %.3f　最大 %.3f　标准差 %.3f",
                         mean(outMedians), m.first!, m.last!, stdev(outMedians)))
            print(String(format: "  → 离散度 %.3f → %.3f（越小越统一）", stdev(inMedians), stdev(outMedians)))
            print(String(format: "高光溢出（亮度≥250 占比）均值 %.4f　超过 1%% 的有 %d 张",
                         mean(outClips), outClips.filter { $0 > 0.01 }.count))
        }
        if !dry {
            print("导出目录：\(outDir.path)")
            var report = "Phos 自动流水线报告\n"
            report += "共 \(infos.count) 张，脱焦剔除 \(culled.count) 张，导出 \(exported) 张\n\n"
            report += "剔除清单（整幅原生分辨率拉普拉斯方差，阈值 \(String(format: "%.1f", threshold))）：\n"
            for c in culled.sorted(by: { $0.focus < $1.focus }) {
                report += String(format: "  %-16@ %.1f\n", c.url.lastPathComponent as NSString, c.focus)
            }
            try? report.write(to: outDir.appendingPathComponent("_处理报告.txt"),
                              atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 清晰度：拉普拉斯方差

    /// 渲成灰度位图。长边压到 longEdge（只在比 longEdge 大时才缩）。
    ///
    /// ⚠️ 别把 longEdge 调小来对焦评估「提速」：从 6192 缩到 1600 相当于
    /// 先把 4px 以内的细节平均掉了，而脱焦/运动模糊的尺度恰恰就在几个像素。
    /// 缩完再测，糊片和锐片的分值会挤到一起，等于白测。主体区通常只占画面
    /// 一小块，按原生分辨率渲它并不贵。
    static func lumaBitmap(_ img: CIImage, crop: CGRect? = nil, longEdge: CGFloat) -> (Int, Int, [UInt8]) {
        var base = img
        if let c = crop {
            let r = c.integral.intersection(img.extent)
            if !r.isEmpty { base = img.cropped(to: r) }
        }
        let e = base.extent
        let scale = min(1, longEdge / max(e.width, e.height))
        let small = scale < 1 ? base.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : base
        let w = max(1, Int(small.extent.width.rounded()))
        let h = max(1, Int(small.extent.height.rounded()))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        Engine.ctx.render(small, toBitmap: &buf, rowBytes: w * 4, bounds: small.extent,
                          format: .RGBA8, colorSpace: Engine.srgb)
        var luma = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            luma[i] = UInt8((0.299 * Double(buf[o]) + 0.587 * Double(buf[o + 1]) + 0.114 * Double(buf[o + 2])).rounded())
        }
        return (w, h, luma)
    }

    /// 归一化 rect（左下原点）内的对焦指标。
    ///
    /// `lapVar` 是拉普拉斯方差 —— 但它是**有量纲的**：纹理密的画面（人群、草地）
    /// 天然就比空旷画面（天空、跑道）高十几倍，直接横向比会误杀低纹理但清晰的照片。
    /// 所以再算一个 `score = lapVar / (lumaVar + 1)`：模糊会先把高频砍掉，
    /// 而大尺度对比度基本保留，这个比值因此更接近「锐不锐」本身，与内容关系小得多。
    static func focusMetrics(_ luma: [UInt8], w: Int, h: Int, rect: CGRect) -> (lapVar: Double, score: Double) {
        var x0 = Int((rect.minX * CGFloat(w)).rounded())
        var y0 = Int((rect.minY * CGFloat(h)).rounded())
        var x1 = Int((rect.maxX * CGFloat(w)).rounded())
        var y1 = Int((rect.maxY * CGFloat(h)).rounded())
        x0 = max(1, min(w - 2, x0)); x1 = max(x0 + 2, min(w - 1, x1))
        y0 = max(1, min(h - 2, y0)); y1 = max(y0 + 2, min(h - 1, y1))
        var sum = 0.0, sum2 = 0.0, n = 0.0
        var gsum = 0.0, gsum2 = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let c = Double(luma[y * w + x])
                let l = 4 * c
                    - Double(luma[y * w + x - 1]) - Double(luma[y * w + x + 1])
                    - Double(luma[(y - 1) * w + x]) - Double(luma[(y + 1) * w + x])
                sum += l; sum2 += l * l; n += 1
                gsum += c; gsum2 += c * c
            }
        }
        guard n > 1 else { return (0, 0) }
        let m = sum / n
        let lapVar = max(0, sum2 / n - m * m)
        let gm = gsum / n
        let lumaVar = max(0, gsum2 / n - gm * gm)
        return (lapVar, lapVar / (lumaVar + 1.0))
    }

    /// 对焦打分。优先量主体区（人糊了但背景锐，整幅均值会掩盖过去），
    /// 但主体区太平（比如框到了天空）就没法判断，退回整幅。
    struct FocusResult {
        var lapVar: Double = 0      // 整幅原生分辨率的拉普拉斯方差：主判据
        var lapSubject: Double = 0  // 主体区原生分辨率：只作参考，不作判据
        var lumaVar: Double = 0     // 整幅灰度方差
        var score: Double = 0       // lapVar / (lumaVar + 1)，内容归一化后的参考值
    }

    /// 对焦打分。
    ///
    /// 判据统一用**整幅 + 原生分辨率**的拉普拉斯方差，不用主体区：
    /// 主体框的大小和落点一变，测出来的区域就变了，同一串连拍能差出几十倍
    /// （实测 07144=33 对 07147=2165），那是「量了不同的东西」不是「对焦不同」。
    /// 整幅 + 固定原生分辨率 = 每张图同一把尺子，可比。
    ///
    /// 原生分辨率这条也不能省：从 6192 缩到 1600 等于先把几个像素的细节平均掉了，
    /// 而脱焦的尺度恰恰就在几个像素。标定过：6192px 下 1px 高斯模糊就让方差掉 7 倍，
    /// 2px 掉 47 倍；缩到 1600 再测，糊片和锐片会挤在一起分不开。
    static func measureFocus(_ src: CIImage, subject: CGRect? = nil) -> FocusResult {
        var out = FocusResult()
        let (w, h, luma) = lumaBitmap(src, longEdge: 100000)
        guard w > 8, h > 8 else { return out }
        let full = focusMetrics(luma, w: w, h: h, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        out.lapVar = full.lapVar
        out.lumaVar = lumaMetrics(luma).var
        out.score = full.score
        if let s = subject {
            out.lapSubject = focusMetrics(luma, w: w, h: h, rect: s).lapVar
        }
        return out
    }

    static func lumaMetrics(_ luma: [UInt8]) -> (var: Double, mean: Double) {
        var s = 0.0, s2 = 0.0
        for v in luma { let d = Double(v); s += d; s2 += d * d }
        let n = Double(max(1, luma.count))
        let m = s / n
        return (max(0, s2 / n - m * m), m)
    }

    // MARK: - 主体检测

    /// 依次试：人体框 → 人脸 → 显著性。返回归一化 rect（左下原点）。
    static func detectSubject(_ img: CIImage) -> CGRect? {
        let handler = VNImageRequestHandler(ciImage: img, options: [:])
        // 1) 人体：运动会几乎都是人，最准
        let human = VNDetectHumanRectanglesRequest()
        if let _ = try? handler.perform([human]),
           let obs = human.results as? [VNDetectedObjectObservation], !obs.isEmpty {
            return unionBox(obs.map { $0.boundingBox })
        }
        // 2) 人脸：远景人太小、人体框不出来时，脸往往还在
        let face = VNDetectFaceRectanglesRequest()
        if let _ = try? handler.perform([face]),
           let obs = face.results as? [VNHumanObservation], !obs.isEmpty {
            return unionBox(obs.map { $0.boundingBox })
        }
        // 3) 显著性兜底
        let sal = VNGenerateAttentionBasedSaliencyImageRequest()
        if let _ = try? handler.perform([sal]),
           let obs = sal.results?.first as? VNSaliencyImageObservation,
           let salient = obs.salientObjects, !salient.isEmpty {
            return unionBox(salient.map { $0.boundingBox })
        }
        return nil
    }

    static func unionBox(_ boxes: [CGRect]) -> CGRect? {
        guard let first = boxes.first else { return nil }
        var r = first
        for b in boxes.dropFirst() { r = r.union(b) }
        return r
    }

    // MARK: - 裁切决策

    /// 按主体形状选横竖，取能框住主体（带留白）的最小目标比例框，再夹回画面内。
    /// 留太多白会显得没裁，所以主体外只放 12% 边距；不够放就整体放大到 minRetain。
    static func planCrop(imageSize: CGSize, subject: CGRect, minRetain: Double) -> CGRect {
        let W = imageSize.width, H = imageSize.height
        // 主体框先还原成像素比例判断形状
        let sw = subject.width * W, sh = subject.height * H

        // 两道保险，避免误检把照片裁坏：
        // 1) 主体占画面不到 3%，大概率是误检（检测到个莫名其妙的小框），不裁；
        // 2) 主体高度不到画面 1/4 就不转竖幅 —— 远景里的人太小，
        //    硬切成 2:3 会把上下大片空景切掉，反而不如留横幅。
        guard subject.width * subject.height >= 0.03 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let tall = sw < sh * 0.85 && subject.height >= 0.25
        let a: CGFloat = tall ? 2.0 / 3.0 : 3.0 / 2.0   // 目标 宽/高

        // 主体框 + 12% 留白
        let padX = subject.width * 0.12, padY = subject.height * 0.12
        var box = CGRect(x: subject.minX - padX, y: subject.minY - padY,
                         width: subject.width + padX * 2, height: subject.height + padY * 2)

        // 撑到目标比例：以「像素」为单位算（W/H 可能不是 1:1）
        var bw = max(box.width * W, box.height * H * a)
        var bh = bw / a
        if bh < box.height * H { bh = box.height * H; bw = bh * a }

        // 至少保留 minRetain 的像素数，防止把单人裁得只剩一张脸
        let minArea = W * H * CGFloat(minRetain)
        if bw * bh < minArea {
            let s = sqrt(Double(minArea / (bw * bh)))
            bw *= CGFloat(s); bh *= CGFloat(s)
        }

        // 夹回画面：超了就等比缩到能放下
        let fit = min(1.0, W / bw, H / bh)
        bw *= fit; bh *= fit

        // 定位：让主体框居中，再夹到画面内
        let cx = box.midX * W, cy = box.midY * H
        var x = cx - bw / 2, y = cy - bh / 2
        x = max(0, min(W - bw, x))
        y = max(0, min(H - bh, y))

        return CGRect(x: x / W, y: y / H, width: bw / W, height: bh / H)
    }

    // MARK: - 工具

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 1 }
        let s = v.sorted()
        return s[s.count / 2]
    }
    static func mean(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        return v.reduce(0, +) / Double(v.count)
    }
    static func stdev(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = mean(v)
        return sqrt(v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1))
    }

    static func collect(_ paths: [String]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var isDir: ObjCBool = false
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // 递归：已导入照片里常见 Selected/ 之类的二级目录
                guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])
                else { continue }
                for case let u as URL in e where Engine.browseSet.contains(u.pathExtension.lowercased()) {
                    out.append(u)
                }
            } else if Engine.browseSet.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
