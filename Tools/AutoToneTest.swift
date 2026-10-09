import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 自动影调的独立验证工具。
//
// 不走 -D PHOS_TESTING 全量编译（那条路会卡在 Inspector.swift 的类型检查），
// 只编译引擎相关文件 + 本文件，所以能稳定跑。
//
// 用法：
//   AutoToneTest synthetic                      合成图自检（有已知答案）
//   AutoToneTest analyze <输出目录> <图片...>     输出自动参数并渲染前后对比图
//   AutoToneTest sweep <目录>                    批量统计参数分布，专找离谱值

@main
struct AutoToneTest {

    static var failures = 0

    static func expect(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok {
            print("PASS: \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
        } else {
            failures += 1
            print("FAIL: \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
        }
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("用法: AutoToneTest synthetic | analyze <outdir> <img...> | sweep <dir>")
            exit(2)
        }
        switch args[1] {
        case "synthetic": synthetic()
        case "analyze":   analyze(Array(args.dropFirst(2)))
        case "sweep":     sweep(Array(args.dropFirst(2)))
        case "isolate":   isolate(Array(args.dropFirst(2)))
        case "scene":     scene(Array(args.dropFirst(2)))
        case "expsweep":  expsweep(Array(args.dropFirst(2)))
        case "hdr":       hdrProbe()
        default:
            print("未知模式: \(args[1])"); exit(2)
        }
        if failures > 0 { print("\n\(failures) 项未通过"); exit(1) }
    }

    // MARK: - 合成图

    /// 造一张横向渐变图：亮度从 lo 线性到 hi，再乘上通道系数做偏色。
    static func ramp(lo: Double, hi: Double, tint: (Double, Double, Double) = (1, 1, 1),
                     clipAbove: Double? = nil, size: Int = 256) -> CIImage {
        var buf = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                var v = lo + (hi - lo) * Double(x) / Double(size - 1)
                if let cap = clipAbove, v > cap { v = 1.0 }
                let o = (y * size + x) * 4
                buf[o]     = UInt8(clamping: Int(min(v * tint.0, 1) * 255))
                buf[o + 1] = UInt8(clamping: Int(min(v * tint.1, 1) * 255))
                buf[o + 2] = UInt8(clamping: Int(min(v * tint.2, 1) * 255))
                buf[o + 3] = 255
            }
        }
        return CIImage(bitmapData: Data(buf), bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8, colorSpace: Engine.srgb)
    }

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func toLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// 造一张**线性值可以超过白场**的图，模拟 RAW 的高光余量。
    ///
    /// 外观和 `ramp` 一样（渲到 sRGB 都在 1.0 处削平），但削平的那些像素
    /// 在线性域里保留 `headroom` 倍的余量 —— 这正是 RAW 和 JPEG/HEIF 的区别。
    static func hdrRamp(lo: Double, hi: Double, clipAbove: Double, headroom: Double,
                        size: Int = 256) -> CIImage {
        var buf = [Float](repeating: 1, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                var v = lo + (hi - lo) * Double(x) / Double(size - 1)
                var gain = 1.0
                if v > clipAbove { v = 1.0; gain = headroom }
                let lin = Float(toLinear(v) * gain)
                let o = (y * size + x) * 4
                buf[o] = lin; buf[o + 1] = lin; buf[o + 2] = lin; buf[o + 3] = 1
            }
        }
        return CIImage(bitmapData: Data(bytes: buf, count: buf.count * 4),
                       bytesPerRow: size * 16,
                       size: CGSize(width: size, height: size),
                       format: .RGBAf, colorSpace: linearSpace)
    }

    /// 造一张横向分区图：segs = [(占比, (r,g,b)), …]，用来模拟「大片绿植 + 中性白参考」这类场景
    static func blocks(_ segs: [(Double, (Double, Double, Double))], size: Int = 256) -> CIImage {
        var buf = [UInt8](repeating: 255, count: size * size * 4)
        let total = segs.reduce(0) { $0 + $1.0 }
        var x0 = 0
        for (i, seg) in segs.enumerated() {
            let w = i == segs.count - 1 ? size - x0 : Int(Double(size) * seg.0 / total)
            for y in 0..<size {
                for x in x0..<min(x0 + w, size) {
                    let o = (y * size + x) * 4
                    buf[o]     = UInt8(clamping: Int(seg.1.0 * 255))
                    buf[o + 1] = UInt8(clamping: Int(seg.1.1 * 255))
                    buf[o + 2] = UInt8(clamping: Int(seg.1.2 * 255))
                    buf[o + 3] = 255
                }
            }
            x0 += w
        }
        return CIImage(bitmapData: Data(buf), bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8, colorSpace: Engine.srgb)
    }

    static func synthetic() {
        let neutral = EditParams()

        // 1) 基本铺满量程的灰阶（末端不溢出）：本来就是均衡的，自动不该乱动。
        //    用 0.98 收尾而不是 1.0 —— 线性渐变在顶端会有 2%+ 的像素正好落在 255，
        //    那会被判成「过曝」，触发的是另一条保护逻辑，不是这里要测的。
        let full = AutoTone.analyze(ramp(lo: 0, hi: 0.98), params: neutral)
        expect(abs(full.exposure) < 0.2, "满量程灰阶：曝光基本不动",
               String(format: "ev=%.2f", full.exposure))
        expect(abs(full.contrast) < 8, "满量程灰阶：对比基本不动",
               String(format: "contrast=%.1f", full.contrast))

        // 2) 整体偏暗：应该提亮
        let dark = AutoTone.analyze(ramp(lo: 0.02, hi: 0.28), params: neutral)
        expect(dark.exposure > 0.4, "暗画面：提亮",
               String(format: "ev=%.2f", dark.exposure))

        // 3) 整体偏亮：应该压暗，但不能压到死
        let bright = AutoTone.analyze(ramp(lo: 0.60, hi: 0.99), params: neutral)
        expect(bright.exposure < -0.3, "亮画面：压暗",
               String(format: "ev=%.2f", bright.exposure))

        // 4) 低对比（灰蒙蒙）：主要靠去朦胧拉开，对比只补一点点
        let flat = AutoTone.analyze(ramp(lo: 0.30, hi: 0.58), params: neutral)
        expect(flat.dehaze >= 15, "低对比：去朦胧挑大梁",
               String(format: "dehaze=%.1f", flat.dehaze))
        expect(flat.contrast <= AutoTone.contrastCap && flat.contrast > 3,
               "低对比：对比只给小量",
               String(format: "contrast=%.1f（上限 %.0f）", flat.contrast, AutoTone.contrastCap))

        // 5) 高光大面积溢出：压高光
        let blown = AutoTone.analyze(ramp(lo: 0.05, hi: 1.0, clipAbove: 0.7), params: neutral)
        expect(blown.highlights < -15, "高光溢出：压高光",
               String(format: "highlights=%.1f", blown.highlights))

        // 6) 暗部压死：抬阴影
        let crushed = AutoTone.analyze(ramp(lo: 0.0, hi: 0.9), params: neutral)
        expect(crushed.shadows >= 0, "暗部压死：抬阴影或不动",
               String(format: "shadows=%.1f", crushed.shadows))

        // 7) 偏暖画面：白平衡应该往冷里拉（压红、提蓝）
        let warm = AutoTone.analyze(ramp(lo: 0.1, hi: 0.9, tint: (1.12, 1.0, 0.86)), params: neutral)
        expect(warm.gains[0] < 0.995, "偏暖：压红通道",
               String(format: "gains=[%.3f, %.3f, %.3f]", warm.gains[0], warm.gains[1], warm.gains[2]))
        expect(warm.gains[2] > 1.005, "偏暖：提蓝通道",
               String(format: "gains=[%.3f, %.3f, %.3f]", warm.gains[0], warm.gains[1], warm.gains[2]))

        // 8) 中性灰阶：不该动白平衡
        expect(full.gains == [1, 1, 1], "中性画面：白平衡不动",
               String(format: "gains=[%.3f, %.3f, %.3f]", full.gains[0], full.gains[1], full.gains[2]))

        // 9) 用户已定过白平衡：自动不去覆盖它
        var userWB = EditParams()
        userWB.temperature = -30
        let kept = AutoTone.apply(warm, to: userWB, strength: 1)
        expect(kept.whiteBalanceGains == [1, 1, 1] && kept.temperature == -30,
               "用户已设白平衡：自动不覆盖")

        // 10) 强度 0 必须完全等于原参数
        let zero = AutoTone.apply(full, to: neutral, strength: 0)
        expect(zero == neutral, "强度 0：参数不变")

        // 11) 强度单调：强度越大，改动越多
        let half = AutoTone.apply(dark, to: neutral, strength: 0.5)
        expect(abs(half.exposure - dark.exposure * 0.5) < 0.001,
               "强度 0.5：改动量减半",
               String(format: "%.3f vs %.3f", half.exposure, dark.exposure * 0.5))

        // 12) 参数必须落在滑块量程内
        let extreme = AutoTone.analyze(ramp(lo: 0.0, hi: 1.0, clipAbove: 0.4), params: neutral)
        let applied = AutoTone.apply(extreme, to: neutral, strength: 1)
        expect((-5...5).contains(applied.exposure)
                && (-100...100).contains(applied.contrast)
                && (-100...100).contains(applied.highlights)
                && (-100...100).contains(applied.shadows)
                && (-100...100).contains(applied.vibrance),
               "极端输入：参数仍在量程内",
               String(format: "ev=%.2f c=%.1f h=%.1f s=%.1f v=%.1f",
                      applied.exposure, applied.contrast, applied.highlights,
                      applied.shadows, applied.vibrance))

        // 13) 过饱和防护：对比 + 去朦胧 + 鲜艳度三件事都会加彩度，
        //     叠起来必须仍然收得住（这是「冰叶菊海岸被推成猩红」那个 bug 的回归测试）
        for (name, scene) in [("暖调场景", ramp(lo: 0.10, hi: 0.90, tint: (1.10, 0.95, 0.85))),
                              ("灰雾场景", ramp(lo: 0.30, hi: 0.62, tint: (1.02, 1.0, 0.98)))] {
            let sol = AutoTone.analyze(scene, params: neutral)
            let before = measureImage(Engine.render(scene, neutral))
            let after = measureImage(Engine.render(scene, AutoTone.apply(sol, to: neutral, strength: 1)))
            let ratio = after.sat / max(before.sat, 1e-6)
            expect(ratio < 1.35, "\(name)：自动后彩度增幅 < 35%",
                   String(format: "%.2f×（%.3f → %.3f）", ratio, before.sat, after.sat))
        }

        // 14) 对比不能压出死黑：加对比后 p05 不该被砸到 0 附近
        let flatScene = ramp(lo: 0.30, hi: 0.62, tint: (1.02, 1.0, 0.98))
        let flatSol = AutoTone.analyze(flatScene, params: neutral)
        let flatAfter = measureImage(Engine.render(flatScene, AutoTone.apply(flatSol, to: neutral, strength: 1)))
        expect(flatAfter.p05 > 0.10, "灰雾场景：加对比后暗部没被压死",
               String(format: "p05=%.3f（对比 %+.1f）", flatAfter.p05, flatSol.contrast))

        // 15) 暗画面回归：对比在线性空间会把暗图整体压暗，
        //     自动必须给 0，且提亮要真的落到画面上（不能被对比吃掉）
        let darkScene = ramp(lo: 0.03, hi: 0.30)
        let darkSol = AutoTone.analyze(darkScene, params: neutral)
        expect(darkSol.contrast == 0, "暗画面：不给正对比",
               String(format: "contrast=%.1f", darkSol.contrast))
        let darkBefore = measureImage(Engine.render(darkScene, neutral))
        let darkAfter = measureImage(Engine.render(darkScene, AutoTone.apply(darkSol, to: neutral, strength: 1)))
        // 只要求「确实变亮」而不是「变亮多少」：低调画面的提亮被刻意压在 1 EV 以内，
        // 因为统计上分不出「欠曝的白天」和「本来就该暗的夜景」，宁可保守。
        expect(darkAfter.median > darkBefore.median + 0.03, "暗画面：自动后确实变亮",
               String(format: "中位 %.3f → %.3f", darkBefore.median, darkAfter.median))

        // 16) 白平衡方向回归：绿植占多数、白参考偏冷的场景。
        //     这是灰度世界的经典翻车现场 —— 它会把「整体偏绿」当成偏色去抬蓝，
        //     结果白衬衫越来越蓝。改用近中性像素采样后应该往中性走。
        let foliage = blocks([(0.55, (0.235, 0.431, 0.157)),    // 大片绿植
                              (0.25, (0.784, 0.831, 0.855)),    // 偏冷的白衬衫
                              (0.20, (0.627, 0.549, 0.471))])   // 暖灰混凝土
        let foliageSol = AutoTone.analyze(foliage, params: neutral)
        let rbBefore = 0.784 / 0.855
        let rbAfter = rbBefore * (foliageSol.gains[0] / foliageSol.gains[2])
        expect(abs(rbAfter - 1) < abs(rbBefore - 1), "绿植场景：白参考朝中性走，而不是更蓝",
               String(format: "R/B %.3f → %.3f（gains=[%.3f, 1, %.3f]）",
                      rbBefore, rbAfter, foliageSol.gains[0], foliageSol.gains[2]))

        // 17) 没有中性参考时（整幅彩色）只能退回灰度世界，但改动必须很小。
        //     这里和上一条是两种不同的失效场景：
        //       上一条 = 画面有色块但也有中性区 → 走中性采样，准；
        //       这一条 = 画面里根本没有中性区（整幅被染色，或纯色块） → 只能猜，所以要克制。
        let allColor = blocks([(0.5, (0.75, 0.22, 0.18)), (0.5, (0.15, 0.35, 0.62))])
        let allColorSol = AutoTone.analyze(allColor, params: neutral)
        expect(abs(allColorSol.gains[0] - 1) < 0.08 && abs(allColorSol.gains[2] - 1) < 0.08,
               "整幅彩色：没有白参考时改动很小",
               String(format: "gains=[%.3f, %.3f, %.3f]",
                      allColorSol.gains[0], allColorSol.gains[1], allColorSol.gains[2]))

        // 18) 增量套用可逆：这是「再点一次自动不会叠加」的基础 ——
        //     先把上一次自动加的量按 -100% 减掉，再套新的，才等价于重新自动一次
        let once = AutoTone.apply(dark, to: neutral, strength: 1)
        let undone = AutoTone.apply(dark, to: once, strength: -1)
        expect(abs(undone.exposure) < 1e-9 && abs(undone.contrast) < 1e-9
                && abs(undone.shadows) < 1e-9 && abs(undone.dehaze) < 1e-9
                && abs(undone.vibrance) < 1e-9 && undone.whiteBalanceGains == [1, 1, 1],
               "增量套用可逆（再点一次自动不会叠加）",
               String(format: "ev=%.9f shadows=%.9f", undone.exposure, undone.shadows))

        // 场景策略 -----------------------------------------------------------------
        func solveFor(_ img: CIImage, _ scene: PhotoScene, _ blend: Double = 1) -> AutoTone.Solution {
            guard let st = AutoTone.measure(img, params: neutral) else { return AutoTone.Solution() }
            return AutoTone.solve(st, scene: scene, sceneBlend: blend)
        }

        // 20) 夜景策略：提亮更克制，并补一点降噪
        let dusk = ramp(lo: 0.15, hi: 0.55)
        let duskGeneric = solveFor(dusk, .other)
        let duskNight = solveFor(dusk, .night)
        expect(duskNight.exposure < duskGeneric.exposure && duskNight.denoise > 0,
               "夜景策略：提亮更克制且补降噪",
               String(format: "ev %.2f → %.2f，denoise %.0f",
                      duskGeneric.exposure, duskNight.exposure, duskNight.denoise))

        // 21) 统计兜底：Vision 认不出夜景时（只会给 outdoor / land / grass），
        //     靠「整体又暗又没什么亮部」也能补上夜景策略
        let darkNight = solveFor(ramp(lo: 0.02, hi: 0.28), .other)
        expect(darkNight.denoise > 0, "极暗画面：自动补上夜景策略",
               String(format: "denoise %.0f", darkNight.denoise))

        // 22) 人像策略：鲜艳度不高于通用，且不给正对比（线性空间的对比会把脸压脏）
        let skin = ramp(lo: 0.10, hi: 0.90, tint: (1.05, 1.0, 0.95))
        let skinGeneric = solveFor(skin, .other)
        let skinPortrait = solveFor(skin, .portrait)
        expect(skinPortrait.vibrance <= skinGeneric.vibrance + 1e-9 && skinPortrait.contrast == 0,
               "人像策略：鲜艳度更保守且不给正对比",
               String(format: "vibrance %.0f → %.0f，contrast %.1f",
                      skinGeneric.vibrance, skinPortrait.vibrance, skinPortrait.contrast))

        // 23) 文档截图策略：什么都不动
        expect(solveFor(ramp(lo: 0.05, hi: 0.95), .document).isNeutral,
               "文档截图策略：不做任何调整")

        // 24) 置信度为 0 时退回通用策略（判错了也不能把照片改坏）
        let lowConf = solveFor(dusk, .night, 0)
        expect(abs(lowConf.exposure - duskGeneric.exposure) < 1e-9 && lowConf.denoise == 0,
               "置信度为 0：退回通用策略",
               String(format: "ev %.2f vs %.2f", lowConf.exposure, duskGeneric.exposure))

        // 高光处理 -----------------------------------------------------------------
        // 26) 大面积过曝（8-bit 已削平）：压高光走**局部蒙版**，只压亮区不连累主体
        let clipped = ramp(lo: 0.0, hi: 1.0, clipAbove: 0.55)
        let clippedSol = AutoTone.analyze(clipped, params: neutral)
        expect(clippedSol.highlightMaskExposure < -0.2,
               "大面积过曝：生成压高光蒙版",
               String(format: "局部曝光 %.2f EV @ 亮度 ≥ %.2f",
                      clippedSol.highlightMaskExposure, clippedSol.highlightMaskLow))
        let clippedApplied = AutoTone.apply(clippedSol, to: neutral, strength: 1)
        expect(clippedApplied.masks.contains { $0.id == AutoTone.autoMaskID && $0.kind == .luminanceRange },
               "套用后确实多出一张亮度范围蒙版")

        // 27) 强度拖回 0：蒙版被撤掉，不在列表里留空壳
        let cleared = AutoTone.apply(clippedSol, to: clippedApplied, strength: -1)
        expect(!cleared.masks.contains { $0.id == AutoTone.autoMaskID },
               "强度拖回 0：压高光蒙版被撤掉")

        // 28) 再点一次自动不会攒出第二张蒙版（固定 id 原地更新）
        let twice = AutoTone.apply(clippedSol, to: clippedApplied, strength: 1)
        expect(twice.masks.filter { $0.id == AutoTone.autoMaskID }.count == 1,
               "重复套用：蒙版只有一张")

        // 29) 高光**不可恢复**时不该为了救它把整张照片压暗
        //     （这是 HEIF 的实际情况：文件里就削平了，压下去只是把白变灰）
        expect(abs(clippedSol.exposure) < 0.2,
               "高光已削平：不做大幅整体压暗",
               String(format: "ev=%.2f（线性余量 %.1f%%）",
                      clippedSol.exposure, AutoTone.measure(clipped, params: neutral)!.linearOverShare * 100))

        // 30) 有真实线性余量（RAW）时，允许整体压暗换回细节
        let hdr = hdrRamp(lo: 0.0, hi: 1.0, clipAbove: 0.55, headroom: 1.6)
        let hdrSol = AutoTone.analyze(hdr, params: neutral)
        expect(hdrSol.exposure < clippedSol.exposure - 0.2,
               "有线性余量：允许整体压暗换细节",
               String(format: "ev %.2f（余量 %.1f%% / %.2f×） vs 削平 %.2f",
                      hdrSol.exposure,
                      AutoTone.measure(hdr, params: neutral)!.linearOverShare * 100,
                      AutoTone.measure(hdr, params: neutral)!.linearOverLevel,
                      clippedSol.exposure))

        // 32) 范围蒙版的权重不该被放大：`Engine.cubeWeight` 曾经把 R+G+B
        //     塞进三个通道，等于把蒙版强度乘了 3 —— 一个 -1 EV 的亮度蒙版
        //     会把整幅画面直接压成黑，而不是压一半。这条是那个 bug 的回归测试。
        let brightField = ramp(lo: 0.85, hi: 0.95)
        var masked = EditParams()
        var lm = Mask()
        lm.kind = .luminanceRange
        lm.lumLow = 0.5; lm.lumHigh = 1.0; lm.lumSoft = 0.05
        lm.adjust.exposure = -1.0
        masked.masks = [lm]
        let mBefore = measureImage(Engine.render(brightField, neutral))
        let mAfter = measureImage(Engine.render(brightField, masked))
        // -1 EV 让线性值减半：sRGB 0.90 → 约 0.66，所以中位不该掉到一半以下
        expect(mAfter.median > mBefore.median * 0.6,
               "范围蒙版：-1 EV 只压一半，不该压成黑",
               String(format: "中位 %.3f → %.3f（%+.1f EV 等效 %.2f）",
                      mBefore.median, mAfter.median, -1.0,
                      log2(mAfter.median / mBefore.median)))

        // 33) 裁剪后统计：整幅是暗的，但裁到亮区，就该按亮区判曝光
        var cropped = EditParams()
        cropped.cropX = 0.5; cropped.cropY = 0; cropped.cropW = 0.5; cropped.cropH = 1
        let cropBright = AutoTone.analyze(ramp(lo: 0.05, hi: 0.95), params: cropped)
        let cropFull = AutoTone.analyze(ramp(lo: 0.05, hi: 0.95), params: neutral)
        expect(cropBright.exposure < cropFull.exposure,
               "裁到亮区：判定比整幅更该压暗",
               String(format: "裁剪 %.2f < 整幅 %.2f", cropBright.exposure, cropFull.exposure))
    }

    // MARK: - 单图 / 批量

    static func analyze(_ args: [String]) {
        guard args.count >= 2 else { print("用法: analyze <outdir> <img...>"); exit(2) }
        let outDir = URL(fileURLWithPath: args[0])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for (i, path) in args.dropFirst().enumerated() {
            let url = URL(fileURLWithPath: path)
            guard let src = Engine.decode(url) else { print("跳过（无法解码）: \(path)"); continue }
            let neutral = EditParams()
            guard let st = AutoTone.measure(src, params: neutral) else { print("跳过（统计失败）: \(path)"); continue }
            let guess = SceneClassifier.classify(src)
            let solution = AutoTone.solve(st, scene: guess.scene, sceneBlend: guess.blend)
            print(String(format: "[%d] %@", i, url.lastPathComponent))
            print(String(format: "     场景  %@（置信 %.2f，采纳 %.0f%%）  %@",
                         guess.scene.label as NSString, guess.confidence, guess.blend * 100,
                         guess.scene.hint as NSString))
            print(String(format: "     统计  median=%.3f p01=%.3f p05=%.3f p10=%.3f p95=%.3f p99=%.3f span=%.3f",
                         st.median, st.p01, st.p05, st.p10, st.p95, st.p99, st.span))
            print(String(format: "           avgSat=%.3f clipHigh=%.4f rgb=[%.1f %.1f %.1f]",
                         st.avgSat, st.clipHigh, st.avgR, st.avgG, st.avgB))
            print(String(format: "           近中性占比=%.1f%%  中性均值=[%.1f %.1f %.1f]",
                         st.neutralShare * 100, st.neutralR, st.neutralG, st.neutralB))
            print(String(format: "     自动  ev=%+.2f contrast=%+.1f highlights=%+.1f shadows=%+.1f vibrance=%+.1f dehaze=%+.1f denoise=%.0f gains=[%.3f %.3f %.3f]",
                         solution.exposure, solution.contrast,
                         solution.highlights, solution.shadows, solution.vibrance, solution.dehaze,
                         solution.denoise, solution.gains[0], solution.gains[1], solution.gains[2]))
            if solution.highlightMaskExposure < 0 {
                print(String(format: "     压高光蒙版  局部 %+.2f EV @ 亮度 ≥ %.2f（羽化 %.2f）",
                             solution.highlightMaskExposure, solution.highlightMaskLow,
                             AutoTone.highlightMaskSoft))
            }
            let after = AutoTone.apply(solution, to: neutral, strength: 1)
            write(Engine.render(src, neutral), outDir.appendingPathComponent(String(format: "%02d-before.jpg", i)))
            write(Engine.render(src, after), outDir.appendingPathComponent(String(format: "%02d-after.jpg", i)))
            // 去掉压高光蒙版的那一版，用来分辨「效果是全局来的还是蒙版来的」
            if after.masks.contains(where: { $0.id == AutoTone.autoMaskID }) {
                var noMask = after
                noMask.masks.removeAll { $0.id == AutoTone.autoMaskID }
                write(Engine.render(src, noMask), outDir.appendingPathComponent(String(format: "%02d-nomask.jpg", i)))
            }
        }
    }

    static func sweep(_ args: [String]) {
        guard let dir = args.first else { print("用法: sweep <dir>"); exit(2) }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                      includingPropertiesForKeys: nil) else {
            print("读不到目录: \(dir)"); exit(2)
        }
        let images = files.filter { ["jpg", "jpeg", "png", "heic", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !images.isEmpty else { print("目录里没有图片"); exit(2) }

        var evs: [Double] = [], contrasts: [Double] = [], highlights: [Double] = []
        var shadows: [Double] = [], vibrance: [Double] = [], dehaze: [Double] = []
        var gainSpread: [Double] = []
        var medians: [Double] = [], avgSats: [Double] = []
        var skipped = 0

        for url in images {
            guard let src = Engine.decode(url), let st = AutoTone.measure(src, params: EditParams()) else {
                skipped += 1; continue
            }
            let s = AutoTone.solve(st)
            evs.append(s.exposure); contrasts.append(s.contrast)
            highlights.append(s.highlights); shadows.append(s.shadows)
            vibrance.append(s.vibrance); dehaze.append(s.dehaze)
            gainSpread.append(max(abs(s.gains[0] - 1), abs(s.gains[2] - 1)))
            medians.append(st.median); avgSats.append(st.avgSat)
        }

        func report(_ name: String, _ v: [Double]) {
            guard !v.isEmpty else { return }
            let mean = v.reduce(0, +) / Double(v.count)
            print(String(format: "%-12@  均值 %+7.2f   最小 %+7.2f   最大 %+7.2f",
                         name as NSString, mean, v.min()!, v.max()!))
        }
        print("共 \(images.count) 张（跳过 \(skipped)），有效 \(evs.count)\n")
        report("中位亮度", medians)
        report("平均彩度", avgSats)
        report("曝光 EV", evs)
        report("对比", contrasts)
        report("高光", highlights)
        report("阴影", shadows)
        report("鲜艳度", vibrance)
        report("去朦胧", dehaze)
        report("白平衡偏移", gainSpread)

        // 离谱值排查：正常照片不该被自动推到这些边界
        let wildEV = zip(images, evs).filter { abs($0.1) >= 1.19 }.map { $0.0.lastPathComponent }
        let wildContrast = zip(images, contrasts).filter { $0.1 >= 54 }.map { $0.0.lastPathComponent }
        let wildWB = zip(images, gainSpread).filter { $0.1 >= 0.12 }.map { $0.0.lastPathComponent }
        print("\n曝光顶到上限的: \(wildEV.count) 张 \(wildEV.prefix(6))")
        print("对比顶到上限的: \(wildContrast.count) 张 \(wildContrast.prefix(6))")
        print("白平衡大改的: \(wildWB.count) 张 \(wildWB.prefix(6))")
    }

    // MARK: - 高光余量探针
    //
    // 回答一个决定性的问题：**Core Image 这条管线到底保不保留超过白场的线性值**。
    // 如果每一环都夹在 [0,1]，那连 RAW 的高光也救不回来 —— 「压高光」就只能是
    // 「把白变灰」，而不是「恢复细节」，功能定位完全不同。
    static func hdrProbe() {
        let img = hdrRamp(lo: 0.0, hi: 1.0, clipAbove: 0.55, headroom: 1.6)
        print(String(format: "合成图：55%% 的像素线性值 = %.2f（外观上渲到 sRGB 都是 1.0）", 1.6))

        func maxLinear(_ image: CIImage, _ label: String) {
            let e = image.extent
            let w = Int(e.width), h = Int(e.height)
            var buf = [Float](repeating: 0, count: w * h * 4)
            Engine.ctx.render(image, toBitmap: &buf, rowBytes: w * 4 * 4, bounds: e,
                              format: .RGBAf, colorSpace: linearSpace)
            var mx = 0.0
            for i in stride(from: 0, to: w * h * 4, by: 4) { mx = max(mx, Double(buf[i])) }
            print(String(format: "  %-28@ 最大线性值 %.3f", label as NSString, mx))
        }

        maxLinear(img, "① 原始 CIImage")
        maxLinear(Engine.geometry(img, EditParams()), "② 过 geometry（恒等）")
        maxLinear(Engine.render(img, EditParams()), "③ 过 Engine.render")
        maxLinear(Engine.render(img, EditParams()).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)),
                  "④ 再降采样")

        // 顺便验证：压曝光能不能把超过白场的部分拉回可见范围
        var neg = EditParams(); neg.exposure = -1.0
        maxLinear(Engine.render(img, neg), "⑤ render 曝光 -1 EV")
    }

    // MARK: - 曝光扫描
    //
    // 回答一个关键问题：过曝区域里**还有没有数据**。
    // 有的话压曝光能把高光救回来；没有的话压下去只是把白变成灰。
    // 判据是画面本身：RAW 解出来的线性值可以超过 1.0，JPEG/HEIF 通常已经削平。
    static func expsweep(_ args: [String]) {
        guard args.count >= 2 else { print("用法: expsweep <出图目录> <图片>"); exit(2) }
        let outDir = URL(fileURLWithPath: args[0])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: args[1])
        guard let src = Engine.decode(url) else { print("无法解码: \(args[1])"); exit(2) }
        print("曝光扫描：\(url.lastPathComponent)")
        for ev in [0.0, -0.5, -1.0, -2.0, -3.0] {
            var p = EditParams()
            p.exposure = ev
            let img = Engine.render(src, p)
            write(img, outDir.appendingPathComponent(String(format: "ev%+.1f.jpg", ev)))
            let s = measureImage(img)
            print(String(format: "  ev %+.1f  中位 %.3f  p05 %.3f  p95 %.3f  彩度 %.3f",
                         ev, s.median, s.p05, s.p95, s.sat))
        }
    }

    // MARK: - 场景识别
    //
    // 只打印 Vision 认出来的东西，不做判断 —— 标定场景关键词表时要先看真实数据。
    static func scene(_ args: [String]) {
        guard !args.isEmpty else { print("用法: scene <图片...>"); exit(2) }
        for path in args {
            let url = URL(fileURLWithPath: path)
            guard let src = Engine.decode(url) else { print("跳过（无法解码）: \(path)"); continue }
            let guess = SceneClassifier.classify(src)
            print(String(format: "%-34@ → %@（%.2f）",
                         url.lastPathComponent as NSString, guess.scene.label as NSString, guess.confidence))
            print("      前 6 标签: \(guess.top.joined(separator: " | "))")
        }
    }

    // MARK: - 单参数隔离
    //
    // 校准用：每次只打开一个调整项，量它单独对画面做了什么。
    // 没有这一步就只能对着「自动前后的差异」猜是哪个参数干的 —— 会猜错。
    static func isolate(_ args: [String]) {
        guard let path = args.first, let src = Engine.decode(URL(fileURLWithPath: path)) else {
            print("用法: isolate <图片>"); exit(2)
        }
        print("基准：\(URL(fileURLWithPath: path).lastPathComponent)")
        let base = measureImage(Engine.render(src, EditParams()))
        print(String(format: "  %-14@ 中位 %.3f  p05 %.3f  p95 %.3f  彩度 %.3f",
                     "原始" as NSString, base.median, base.p05, base.p95, base.sat))

        var cases: [(String, (inout EditParams) -> Void)] = []
        func add(_ name: String, _ apply: @escaping (inout EditParams) -> Void) { cases.append((name, apply)) }
        for v in [-30.0, -15.0, 15.0, 30.0] {
            add(String(format: "对比 %+.0f", v)) { $0.contrast = v }
        }
        for v in [-30.0, 30.0] {
            add(String(format: "曝光 %+.0f", v)) { $0.exposure = v / 10 }
        }
        for v in [-30.0, 30.0] {
            add(String(format: "阴影 %+.0f", v)) { $0.shadows = v }
            add(String(format: "高光 %+.0f", v)) { $0.highlights = v }
        }
        for v in [15.0, 30.0] {
            add(String(format: "去朦胧 %+.0f", v)) { $0.dehaze = v }
            add(String(format: "鲜艳度 %+.0f", v)) { $0.vibrance = v }
        }

        for (name, mutate) in cases {
            var p = EditParams()
            mutate(&p)
            let s = measureImage(Engine.render(src, p))
            print(String(format: "  %-14@ 中位 %.3f  p05 %.3f  p95 %.3f  彩度 %.3f   Δ彩度 %+.3f",
                         name as NSString, s.median, s.p05, s.p95, s.sat, s.sat - base.sat))
        }
    }

    struct QuickStats { var median = 0.0, p05 = 0.0, p95 = 0.0, sat = 0.0 }

    /// 直接从渲染结果量，绕开 AutoTone 的统计口径，用来核对引擎真实响应
    static func measureImage(_ img: CIImage) -> QuickStats {
        let e = img.extent
        let scale = min(1, 256 / max(e.width, e.height))
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width.rounded()), h = Int(small.extent.height.rounded())
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        Engine.ctx.render(small, toBitmap: &buf, rowBytes: w * 4, bounds: small.extent,
                          format: .RGBA8, colorSpace: Engine.srgb)
        var lum: [Double] = [], sat = 0.0
        for i in 0..<(w * h) {
            let o = i * 4
            let r = Double(buf[o]), g = Double(buf[o + 1]), b = Double(buf[o + 2])
            lum.append((0.299 * r + 0.587 * g + 0.114 * b) / 255)
            sat += (max(r, g, b) - min(r, g, b)) / 255
        }
        lum.sort()
        var s = QuickStats()
        s.median = lum[lum.count / 2]
        s.p05 = lum[Int(0.05 * Double(lum.count))]
        s.p95 = lum[Int(0.95 * Double(lum.count))]
        s.sat = sat / Double(lum.count)
        return s
    }

    // MARK: - 落盘

    static func write(_ img: CIImage, _ url: URL) {
        var settings = ExportSettings()
        settings.format = "jpg"
        settings.quality = 0.92
        do { try Engine.write(img, to: url, settings: settings) }
        catch { print("写图失败 \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}
