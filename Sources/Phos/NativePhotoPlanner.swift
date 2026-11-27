import Foundation
import CoreImage
import CoreGraphics

struct NativeAIPlanResult {
    var params: EditParams
    var summary: String
    var detail: String
    var addedMasks: Int
    var lumaShift: Double
    var chromaShift: Double
}

/// P3 Swift 原生 AI 修图编排器（零 Python 依赖：图像像素统计 + 意图解析 + 自动局部蒙版 + 前后像素闭环校验）。
enum NativePhotoPlanner {
    static func plan(instruction: String, source: CIImage, base: EditParams,
                     disparityMask: CIImage? = nil) -> NativeAIPlanResult {
        let q = instruction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scale = min(1.0, 480.0 / max(source.extent.width, source.extent.height, 1.0))
        let small = scale < 1
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source
        let smallDisparity: CIImage? = disparityMask.map { d in
            if abs(d.extent.width - small.extent.width) <= 0.5 && abs(d.extent.height - small.extent.height) <= 0.5 {
                return d
            }
            let sx = small.extent.width / max(d.extent.width, 1)
            let sy = small.extent.height / max(d.extent.height, 1)
            return d
                .transformed(by: CGAffineTransform(translationX: -d.extent.minX, y: -d.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: small.extent.minX, y: small.extent.minY))
                .cropped(to: small.extent)
        }

        let preStats = measureStats(Engine.render(small, base, disparityMask: smallDisparity))
        var cand = base
        var actions: [String] = []
        var addedMasks = 0

        let scaleK: Double = containsAny(q, ["强", "重度", "大幅", "extreme", "strong"]) ? 1.35
            : containsAny(q, ["轻", "微", "适度", "slight", "subtle", "soft"]) ? 0.72 : 1.0

        // 1) 基础自动均衡意图或全能润色
        let wantsAuto = q.isEmpty || containsAny(q, ["自动", "均衡", "通透", "平衡", "natural", "auto", "clean"])
        if wantsAuto || containsAny(q, ["提亮", "bright", "暗部", "shadow", "压暗", "dark", "高光", "highlight"]) {
            if preStats.medianY < 0.36 || containsAny(q, ["提亮", "bright", "暗部", "shadow"]) {
                let lift = (preStats.medianY < 0.32 ? 0.55 : 0.35) * scaleK
                cand.exposure = clamp(cand.exposure + lift * (containsAny(q, ["暗部", "shadow"]) ? 0.45 : 1.0), -4.5...4.5)
                cand.shadows = clamp(cand.shadows + 36.0 * scaleK, -100...100)
                actions.append("提亮暗部与中间调")
            }
            if preStats.p95Y > 0.88 || containsAny(q, ["高光", "过曝", "highlight"]) {
                cand.highlights = clamp(cand.highlights - 42.0 * scaleK, -100...100)
                cand.highlightRolloff = clamp(max(cand.highlightRolloff, 35.0 * scaleK), 0...100)
                actions.append("柔化高光并保留层次")
            }
            if containsAny(q, ["通透", "clarity", "clean", "透亮"]) {
                cand.dehaze = clamp(cand.dehaze + 14.0 * scaleK, -100...100)
                cand.clarity = clamp(cand.clarity + 12.0 * scaleK, -100...100)
                cand.contrast = clamp(cand.contrast + 10.0 * scaleK, -100...100)
                actions.append("增强反差与通透度")
            }
        }

        // 2) 色彩倾向与风格
        if containsAny(q, ["暖", "温暖", "日落", "夕阳", "金", "warm", "golden"]) {
            cand.temperature = clamp(cand.temperature + 18.0 * scaleK, -100...100)
            cand.gradeShadow = ColorGrade(hue: 215, sat: 10.0 * scaleK)
            cand.gradeHigh = ColorGrade(hue: 42, sat: 16.0 * scaleK)
            actions.append("营造温暖高光与冷调阴影")
        } else if containsAny(q, ["冷", "日系", "清新", "蓝调", "cool", "fresh", "japanese"]) {
            cand.temperature = clamp(cand.temperature - 14.0 * scaleK, -100...100)
            cand.shadows = clamp(cand.shadows + 24.0 * scaleK, -100...100)
            cand.lumaCurve = ToneCurve(points: [[0, 0.04], [0.25, 0.29], [0.5, 0.54], [0.75, 0.78], [1, 0.96]])
            cand.gradeHigh = ColorGrade(hue: 198, sat: 12.0 * scaleK)
            actions.append("青蓝清新影调与柔和黑场")
        }

        if containsAny(q, ["电影", "胶片", "复古", "cinematic", "film", "kodak", "portra"]) {
            cand.contrast = clamp(cand.contrast + 16.0 * scaleK, -100...100)
            cand.contrastPivot = -8
            cand.highlightRolloff = max(cand.highlightRolloff, 48.0)
            cand.grain = clamp(max(cand.grain, 22.0 * scaleK), 0...100)
            cand.grainRoughness = 0.58
            cand.halation = clamp(max(cand.halation, 16.0 * scaleK), 0...100)
            if cand.gradeShadow.isNeutral { cand.gradeShadow = ColorGrade(hue: 195, sat: 14.0 * scaleK) }
            if cand.gradeHigh.isNeutral { cand.gradeHigh = ColorGrade(hue: 38, sat: 15.0 * scaleK) }
            actions.append("加入电影曲线、银盐颗粒与胶片色温分级")
        }

        if containsAny(q, ["黑白", "单色", "bw", "mono", "black"]) {
            cand.mono = true
            cand.contrast = clamp(cand.contrast + 22.0 * scaleK, -100...100)
            cand.grain = clamp(max(cand.grain, 24.0 * scaleK), 0...100)
            actions.append("转换高反差银盐黑白")
        } else if containsAny(q, ["鲜艳", "浓郁", "vivid", "vibrant"]) {
            cand.vibrance = clamp(cand.vibrance + 26.0 * scaleK, -100...100)
            cand.saturation = clamp(cand.saturation + 10.0 * scaleK, -100...100)
            actions.append("提升感知自然彩度")
        }

        // 3) 局部 AI 蒙版与光学特性联动
        if containsAny(q, ["天空", "蓝天", "云", "sky"]) {
            var sky = Mask()
            sky.kind = .sky
            sky.name = "AI 天空压暗"
            sky.adjust.exposure = -0.45 * scaleK
            sky.adjust.dehaze = 18.0 * scaleK
            sky.adjust.saturation = 14.0 * scaleK
            cand.masks.append(sky)
            addedMasks += 1
            actions.append("新建天空局部蒙版压暗提蓝")
        }

        if containsAny(q, ["人像", "肤色", "人物", "皮肤", "portrait", "skin"]) {
            var skin = Mask()
            skin.kind = .faceSkin
            skin.name = "AI 肤色润饰"
            skin.adjust.exposure = 0.18 * scaleK
            skin.adjust.texture = -14.0 * scaleK
            skin.adjust.saturation = -6.0 * scaleK
            cand.masks.append(skin)
            addedMasks += 1
            actions.append("新建人脸皮肤蒙版柔化纹理")
        }

        if containsAny(q, ["虚化", "散景", "大光圈", "浅景深", "bokeh", "blur", "背景虚化"]) {
            cand.bokehAmount = clamp(max(cand.bokehAmount, 48.0 * scaleK), 0...100)
            cand.bokehAutoDepth = true
            actions.append("开启 P3 单目深度光学散景")
        }

        if containsAny(q, ["降噪", "夜景", "纯净", "denoise", "clean noise", "night"]) {
            cand.aiDenoise = clamp(max(cand.aiDenoise, 45.0 * scaleK), 0...100)
            cand.aiDenoiseDetail = 60
            actions.append("启用线性 RAW 域保边降噪")
        }

        if actions.isEmpty {
            // 若用户指令较抽象，执行基础影调与自然色彩微调保障闭环有效
            cand.exposure = clamp(cand.exposure + (0.45 - preStats.medianY) * 1.1, -1.5...1.5)
            cand.contrast = clamp(cand.contrast + 12.0, -100...100)
            cand.vibrance = clamp(cand.vibrance + 14.0, -100...100)
            actions.append("执行全局光影均衡与自然彩度微调")
        }

        // 像素闭环核对
        let postStats = measureStats(Engine.render(small, cand, disparityMask: smallDisparity))
        let lumaShift = postStats.medianY - preStats.medianY
        let chromaShift = postStats.meanC - preStats.meanC

        let summary = actions.joined(separator: "；")
        let detail = String(format: "原生离线编排 · 中位亮度 %+.3f · 平均彩度 %+.3f%@",
                            lumaShift, chromaShift, addedMasks > 0 ? " · 新增 \(addedMasks) 个智能蒙版" : "")
        return NativeAIPlanResult(params: cand, summary: summary, detail: detail,
                                  addedMasks: addedMasks, lumaShift: lumaShift, chromaShift: chromaShift)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }

    private static func measureStats(_ img: CIImage) -> (medianY: Double, p95Y: Double, meanC: Double) {
        let side = 48
        let e = img.extent
        let small = img.cropped(to: e)
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / max(1, e.width),
                                               y: CGFloat(side) / max(1, e.height)))
        var buf = [Float](repeating: 0, count: side * side * 4)
        Engine.ctx.render(small, toBitmap: &buf, rowBytes: side * 16,
                          bounds: CGRect(x: 0, y: 0, width: side, height: side),
                          format: .RGBAf, colorSpace: Engine.srgb)
        var ys = [Double](); ys.reserveCapacity(side * side)
        var cSum = 0.0
        for i in 0..<(side * side) {
            let r = Double(min(max(buf[i * 4], 0), 1))
            let g = Double(min(max(buf[i * 4 + 1], 0), 1))
            let b = Double(min(max(buf[i * 4 + 2], 0), 1))
            ys.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            cSum += max(r, g, b) - min(r, g, b)
        }
        ys.sort()
        let med = ys[ys.count / 2]
        let p95 = ys[min(ys.count - 1, Int(Double(ys.count) * 0.95))]
        return (med, p95, cSum / Double(max(1, ys.count)))
    }
}
