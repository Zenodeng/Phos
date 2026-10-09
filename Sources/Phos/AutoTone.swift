import Foundation
import CoreImage
import CoreGraphics

// MARK: - 自动影调（一键「自动」）
//
// 分两步：`measure` 先把图按几何裁框之后降采样到长边 256，在 sRGB 感知域统计
// 亮度百分位、平均彩度与通道均值；`solve` 再由这些数字反解出一组调整量。
// 拆开是为了能单独把中间量打出来校准 —— 不然只能对着最终参数猜是哪一步偏了。
//
// 设计取向是**保守**。自动修图最怕的不是「不够狠」，而是「把好照片改坏」：
// 每一项都有硬上限，低调（夜景）/ 高调（雪景）会主动收敛，
// 用户已经自己定过白平衡时干脆不碰白平衡。
//
// 注意：统计必须在 `Engine.geometry()` 之后做。用户裁过图的话，
// 被裁掉的天空或暗角会污染直方图，反解出来的参数就是错的。
enum AutoTone {

    /// 自动求解出的一组调整量。只包含自动会碰的字段，其余一律留空。
    ///
    /// 故意不含 `blacks` / `whites`：这两个滑块在当前管线里是单向的
    /// （`blacks` 只能抬黑场、`whites` 只能压白场，另一端会被 clamp 吃掉），
    /// 自动去动它们容易帮倒忙。影调交给 exposure / contrast / highlights / shadows。
    struct Solution: Equatable, Sendable {
        var exposure: Double = 0      // EV
        var contrast: Double = 0
        var highlights: Double = 0
        var shadows: Double = 0
        var vibrance: Double = 0
        var dehaze: Double = 0
        var denoise: Double = 0       // 只在夜景策略下给，见 SceneTuning
        var gains: [Double] = [1, 1, 1]

        /// 大范围过曝时，压「亮区」的局部曝光（EV，负值）。
        /// 会落成一张亮度范围蒙版 —— 只压亮区，不连累主体。
        var highlightMaskExposure: Double = 0
        /// 上面那张蒙版的亮度起点（感知域）。因为蒙版在管线最后才应用，
        /// 它看到的是**全局调整之后**的画面，所以这个值由 `analyze` 实测决定。
        var highlightMaskLow: Double = 0.80

        var isNeutral: Bool {
            abs(exposure) < 0.001 && abs(contrast) < 0.001 && abs(highlights) < 0.001
                && abs(shadows) < 0.001 && abs(vibrance) < 0.001 && abs(dehaze) < 0.001
                && abs(denoise) < 0.001 && abs(highlightMaskExposure) < 0.001
                && gains == [1, 1, 1]
        }
    }

    /// 按场景给求解结果做偏置。所有数值都是「相对通用策略的倍数 / 上限」，
    /// 刻意取得温和 —— 场景识别会错，判错了也不能把照片改坏。
    struct SceneTuning: Equatable, Sendable {
        var exposureScale = 1.0
        var contrastScale = 1.0
        var highlightsScale = 1.0
        var shadowsScale = 1.0
        var dehazeScale = 1.0
        var vibranceCap = AutoTone.vibranceCap
        var denoise = 0.0
        /// 额外暖调（食物、日落一类），直接折进白平衡增益里
        var warmth = 0.0

        /// 按识别置信度把偏置往通用策略回拉。
        /// 置信度低（Vision 没认出来）时几乎等于不做场景偏置。
        func blended(_ k: Double) -> SceneTuning {
            let f = min(max(k, 0), 1)
            var o = SceneTuning()
            o.exposureScale   = 1 + (exposureScale - 1) * f
            o.contrastScale   = 1 + (contrastScale - 1) * f
            o.highlightsScale = 1 + (highlightsScale - 1) * f
            o.shadowsScale    = 1 + (shadowsScale - 1) * f
            o.dehazeScale     = 1 + (dehazeScale - 1) * f
            o.vibranceCap     = AutoTone.vibranceCap + (vibranceCap - AutoTone.vibranceCap) * f
            o.denoise         = denoise * f
            o.warmth          = warmth * f
            return o
        }
    }

    /// 各场景的策略。
    static func tuning(for scene: PhotoScene) -> SceneTuning {
        var t = SceneTuning()
        switch scene {
        case .portrait:
            // 皮肤最怕两件事：线性空间的对比（会把脸压脏）和过度加饱和（会发红发艳）
            t.contrastScale = 0.0
            t.dehazeScale = 0.6
            t.vibranceCap = 8
            t.highlightsScale = 1.2   // 护住额头、鼻梁的高光
            t.shadowsScale = 1.1
        case .landscape:
            t.dehazeScale = 1.3       // 风光最吃去朦胧
            t.vibranceCap = 18
            t.highlightsScale = 1.2   // 护住云层
        case .night:
            t.exposureScale = 0.7     // 夜色别硬拉
            t.contrastScale = 0.0
            t.dehazeScale = 0.5
            t.vibranceCap = 8
            t.shadowsScale = 0.8
            t.denoise = 35            // 夜景暗部噪点最明显
        case .snow:
            t.exposureScale = 0.4     // 雪景本来就该亮，按中灰压下去就废了
            t.highlightsScale = 1.3   // 雪面纹理一爆就没了
            t.vibranceCap = 12
        case .food:
            t.warmth = 0.030
            t.vibranceCap = 20
            t.contrastScale = 0.6
        case .document:
            // 截图、文档不需要「修图」，一律不动
            t.exposureScale = 0
            t.contrastScale = 0
            t.highlightsScale = 0
            t.shadowsScale = 0
            t.dehazeScale = 0
            t.vibranceCap = 0
        case .other:
            break
        }
        return t
    }

    /// 画面统计量（全部在 sRGB 感知域，0…1）。留着给测试工具打表校准用。
    struct Stats: Equatable, Sendable {
        var median = 0.0
        var p01 = 0.0
        var p05 = 0.0
        var p10 = 0.0
        var p95 = 0.0
        var p99 = 0.0
        var span = 0.0        // p95 - p05
        var avgSat = 0.0      // 绝对色度 (max-min)/255 的均值
        var clipHigh = 0.0    // 亮度 ≥ 250 的像素占比
        var avgR = 0.0        // 全图通道均值（灰度世界用）
        var avgG = 0.0
        var avgB = 0.0
        var neutralR = 0.0    // 近中性像素的通道均值（更可靠的白平衡参考）
        var neutralG = 0.0
        var neutralB = 0.0
        var neutralShare = 0.0  // 近中性像素占比
        /// 线性值超过白场的像素占比，以及这些像素的平均线性亮度。
        /// 用来判断高光**还有没有救**：RAW 解出来的线性值可以超过 1.0，
        /// 压曝光能换回真实细节；JPEG / HEIF 在文件里就削平了，压下去只是把白变灰。
        var linearOverShare = 0.0
        var linearOverLevel = 0.0
    }

    /// 中灰目标：sRGB 感知域 0.44 ≈ 线性 0.16。
    /// 定得比教科书上的 18% 灰（sRGB 0.46）略低 —— 真实照片的像素中位数天然
    /// 低于中灰，按 0.46 校正会让每一张都系统性偏亮。
    static let targetMedian = 0.44
    /// 统计用的长边像素数。再大也不会更准，只是更慢。
    static let sampleEdge: CGFloat = 256

    // MARK: 引擎响应系数（实测标定，改前先用 Tools/AutoToneTest.swift isolate 复测）

    /// 对比滑块的上限。
    ///
    /// 这个管线是在**线性空间**跑的，`CIColorControls` 的对比绕线性 0.5（≈ sRGB 0.735）
    /// 放大，所以比 sRGB 0.735 暗的像素统统被压下去。实测：
    /// 对比 +30 会把 p05 从 0.231 砸到 0.052、中位亮度从 0.475 压到 0.425；
    /// 对中位 0.051 的夜景，contrast +8 就能把曝光 +0.8 EV 提上来的亮度全部吃回去。
    ///
    /// 结论：自动里对比只当配角，拉层次主要交给去朦胧（走矩阵 + 偏置，温和得多）。
    static let contrastCap = 8.0
    /// 对比每 +1 大约给画面加多少绝对彩度（实测 对比 +30 → 彩度 +0.076）
    static let contrastChromaGain = 0.0022
    /// 去朦胧每 +1 大约加多少彩度（实测 去朦胧 +30 → 彩度 +0.086）
    static let dehazeChromaGain = 0.0026
    /// 鲜艳度每 +1 大约加多少彩度（实测 鲜艳度 +30 → 彩度 +0.070）
    static let vibranceChromaGain = 0.0024
    /// 鲜艳度上限（通用策略）。实测：大幅提亮鲜艳度会把肤色和有偏色的白区一起放大。
    static let vibranceCap = 15.0

    // MARK: 白平衡参考

    /// 「近中性」的判定：绝对色度低于这个值的像素，被认为本来就不该有颜色。
    static let neutralChroma = 0.10
    /// 近中性像素占比低于这个值，就认为画面里没有可用的白参考
    static let neutralMinShare = 0.02
    /// 占比达到这个值就完全信任近中性样本
    static let neutralFullShare = 0.15
    /// 校正强度：近中性像素本身也带一点固有颜色，全量校正会过冲
    static let neutralCorrection = 0.80
    /// 完全没有白参考时退回灰度世界的权重（压得很低，因为它很容易被大片色块带偏）
    static let grayFallbackWeight = 0.45

    // MARK: 高光可恢复性与「压高光」蒙版

    /// 线性值超过白场的像素占比达到这个数、且平均超过白场这个倍数，才算「高光还有救」。
    /// RAW 解出来的线性值可以超过 1.0，压曝光能换回真实细节；
    /// JPEG / HEIF 在文件里就削平了 —— 实测一张 18% 像素爆白的 HEIF，
    /// 压到 -3 EV 天空依然是一片纯灰，没有任何细节回来。
    static let recoverableOverShare = 0.01
    static let recoverableOverLevel = 1.10

    /// 过曝面积达到这个占比才考虑压高光区域
    static let highlightClipTrigger = 0.03
    /// 压高光蒙版的局部曝光上限（EV）
    static let highlightMaskCap = 0.70
    /// 蒙版上边缘的羽化宽度（感知域）
    static let highlightMaskSoft = 0.10

    /// 「自动压高光」蒙版用固定 id：再点一次自动是**原地更新**，不会攒出一堆蒙版，
    /// 强度拖回 0 时也能准确地把这一张撤掉。
    /// 用户手动建的蒙版都是随机 UUID，不会撞上。
    static let autoMaskID = UUID(uuidString: "A0700A07-0000-4000-A000-000000000001")!
    static let autoMaskName = "自动压高光"

    // MARK: - 测量

    /// 统计画面。无副作用，可后台执行。
    static func measure(_ source: CIImage, params: EditParams) -> Stats? {
        // 只统计用户实际看到的构图
        let geo = Engine.geometry(source, params)
        let extent = geo.extent
        guard extent.width >= 8, extent.height >= 8 else { return nil }

        let scale = min(1, sampleEdge / max(extent.width, extent.height))
        let small = geo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width.rounded()), h = Int(small.extent.height.rounded())
        guard w > 0, h > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: w * h * 4)
        Engine.ctx.render(small, toBitmap: &buf, rowBytes: w * 4, bounds: small.extent,
                          format: .RGBA8, colorSpace: Engine.srgb)

        var hist = [Double](repeating: 0, count: 256)
        var total = 0.0
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, wbCount = 0.0
        var nR = 0.0, nG = 0.0, nB = 0.0, neutralCount = 0.0
        var satSum = 0.0, satCount = 0.0
        var clipHigh = 0.0

        for i in 0..<(w * h) {
            let o = i * 4
            let r = Double(buf[o]), g = Double(buf[o + 1]), b = Double(buf[o + 2])
            // 与 Engine.histogram 一致的感知亮度权重
            let bin = min(255, max(0, Int((0.299 * r + 0.587 * g + 0.114 * b) / 255 * 255)))
            hist[bin] += 1
            total += 1
            if bin >= 250 { clipHigh += 1 }

            // 白平衡样本：过曝和死黑像素的色度不可信，排除
            if bin >= 8 && bin <= 247 {
                sumR += r; sumG += g; sumB += b; wbCount += 1
            }
            // 彩度用**绝对**色度 (max-min)/255，而不是 HSV 的 (max-min)/max。
            // HSV 的 S 是相对量，对暗部会虚高：一个 (10,34,50) 的深蓝像素
            // 绝对色度只有 0.16，HSV 却算成 0.80。用它标定会让所有照片
            // 都显示「彩度很高」，鲜艳度永远被压到下限。
            let mx = max(r, g, b), mn = min(r, g, b)
            let chroma = (mx - mn) / 255
            satSum += chroma
            satCount += 1

            // 近中性样本：这些像素「本来就不该有颜色」，它们偏了才是真的偏色。
            // 亮度带排除死黑与接近溢出的像素 —— 两端的色度都不可信。
            if chroma < neutralChroma && bin >= 32 && bin <= 245 {
                nR += r; nG += g; nB += b; neutralCount += 1
            }
        }
        guard total > 0, wbCount > 0 else { return nil }

        func percentile(_ p: Double) -> Double {
            let target = p * total
            var acc = 0.0
            for i in 0..<256 {
                acc += hist[i]
                if acc >= target { return Double(i) / 255 }
            }
            return 1
        }

        var st = Stats()
        st.p01 = percentile(0.01)
        st.p05 = percentile(0.05)
        st.p10 = percentile(0.10)
        st.median = percentile(0.50)
        st.p95 = percentile(0.95)
        st.p99 = percentile(0.99)
        st.span = st.p95 - st.p05
        st.clipHigh = clipHigh / total
        st.avgSat = satCount > 0 ? satSum / satCount : 0
        st.avgR = sumR / wbCount
        st.avgG = sumG / wbCount
        st.avgB = sumB / wbCount
        st.neutralShare = neutralCount / total
        if neutralCount > 0 {
            st.neutralR = nR / neutralCount
            st.neutralG = nG / neutralCount
            st.neutralB = nB / neutralCount
        }

        // 再渲一遍到**扩展线性**空间，看白场之上还有没有东西。
        // sRGB 那遍已经在 1.0 处削平了，只有线性值才看得出余量。
        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? Engine.srgb
        var lin = [Float](repeating: 0, count: w * h * 4)
        // 注意 rowBytes：RGBAf 每像素 16 字节，不是 4。传小了 render 会静默失败、
        // 缓冲区留在全 0，于是「有没有高光余量」永远算成没有。
        Engine.ctx.render(small, toBitmap: &lin, rowBytes: w * 16, bounds: small.extent,
                          format: .RGBAf, colorSpace: linearSpace)
        var overCount = 0.0, overSum = 0.0
        for i in 0..<(w * h) {
            let o = i * 4
            let y = 0.2126 * Double(lin[o]) + 0.7152 * Double(lin[o + 1]) + 0.0722 * Double(lin[o + 2])
            // 留一点浮点余量，1.02 以下不算「真的超过白场」
            if y > 1.02 { overCount += 1; overSum += y }
        }
        st.linearOverShare = overCount / total
        st.linearOverLevel = overCount > 0 ? overSum / overCount : 0
        return st
    }

    // MARK: - 求解

    /// - Parameters:
    ///   - scene: 识别到的题材，决定用哪套策略
    ///   - sceneBlend: 0…1，识别置信度换算来的采纳比例。低置信度时趋近 0，
    ///                 等于退回通用策略 —— 判错了也不会把照片改坏。
    static func solve(_ st: Stats, scene: PhotoScene = .other, sceneBlend: Double = 0) -> Solution {
        var out = Solution()
        let p01 = st.p01, p05 = st.p05, p10 = st.p10
        let median = st.median, p95 = st.p95, p99 = st.p99
        let span = st.span, clipHigh = st.clipHigh, avgSat = st.avgSat
        var tune = tuning(for: scene).blended(sceneBlend)
        // 统计上的兜底：Vision 经常认不出夜景（只会给 outdoor / land / grass），
        // 但「整体又暗又没什么亮部」这个特征本身就很可靠，用它补一刀。
        if scene != .night, median < 0.16, p99 < 0.55 {
            tune = tuning(for: .night).blended(1)
        }

        // --- 曝光：把中位亮度拉向中灰 ---
        var ev = log2(toLinear(targetMedian) / max(toLinear(median), 1e-4))
        if p99 < 0.30 { ev = max(ev, 0) }               // 极暗画面只提不压，别把夜色拉成灰
        if median > 0.68 && p99 > 0.95 { ev *= 0.45 }   // 高调（雪、逆光白背景）：中位数天然偏高
        // 低调（夜景、烛光）：中位数天然偏低，压一压提亮冲动，并给一个绝对上限。
        // 实测 138 张系统壁纸里有 39% 会顶到硬上限，其中绝大多数是这种本就该暗的图。
        if median < 0.18 && p99 < 0.60 { ev *= 0.50 }
        if median < 0.18 { ev = min(ev, 1.0) }
        if median < 0.10 { ev = min(ev, 0.8) }
        // 「高光还能不能救回来」决定过曝时该不该整体压暗：
        //   有真实余量（RAW 的线性值超过白场）→ 压下来能换回细节，值得做；
        //   已经削平（JPEG / HEIF）→ 压下去只是把白变灰，还要连累本来曝光正确的主体。
        // 实测一张 18% 像素爆白的 HEIF，压到 -3 EV 天空依然是一片纯灰，没有任何细节回来。
        let recoverable = st.linearOverShare > recoverableOverShare
            && st.linearOverLevel > recoverableOverLevel
        // 黑白场都已经到位：曝光本身不差，硬推只会削掉一端。
        // 阈值取 5%：亮天空、镜面反光打头的 1~2% 溢出是正常的，不算「炸了」。
        if p01 < 0.05 && p99 > 0.95 && (clipHigh < 0.05 || !recoverable) { ev *= 0.35 }
        // 提亮不能把最亮的 1% 推过白场 —— 天空、云层、雪面一爆就救不回来了。
        // 这条比任何固定阈值都准：它按画面自己还剩多少高光余量来定上限。
        if ev > 0 {
            let headroom = log2(toLinear(0.985) / max(toLinear(p99), 1e-4))
            ev = min(ev, max(headroom, 0))
        }
        // 场景策略在这里介入：雪景不该被压暗、夜景不该硬拉、截图根本不该动。
        // 放在所有保护逻辑之后 —— 场景是「额外的意愿」，不该绕过安全阀。
        ev *= tune.exposureScale
        ev = clamp(ev, -1.2, 1.2)
        out.exposure = abs(ev) < 0.12 ? 0 : ev

        // --- 高光：过曝就压回来，亮部发闷就抬一点 ---
        // 「发闷」只在画面整体不暗时才成立：暗画面的高光低是曝光不足的表现，
        // 交给曝光和阴影去补，这里再抬一次等于同一件事做两遍。
        if clipHigh > 0.002 {
            out.highlights = -clamp(18 + clipHigh * 2600, 18, 55)
        } else if p95 < 0.68 && median > 0.28 {
            out.highlights = clamp((0.68 - p95) * 70, 0, 28)
        }
        // 人像/风光/雪景都要求多护一点高光（额头、云层、雪面纹理）
        out.highlights = clamp(out.highlights * tune.highlightsScale, -100, 100)

        // --- 阴影：暗部压死就抬，发灰就压 ---
        var shadows = 0.0
        if p10 < 0.20 {
            shadows = clamp((0.20 - p10) * 320, 0, 50)
        } else if p10 > 0.34 {
            shadows = -clamp((p10 - 0.34) * 220, 0, 32)
        }
        // 整体很暗的画面抬阴影会毁氛围，收一半
        if median < 0.18 { shadows *= 0.5 }
        // 曝光已经大幅提亮时，阴影再抬一次等于同一件事做两遍
        if ev > 0.5 { shadows *= 0.7 }
        // 已经有实打实的黑场（p05 贴地）：暗部是画面结构而不是欠曝，
        // 剪影、夜景的黑色是要留住的，抬阴影等于把氛围洗掉
        if p05 < 0.02 { shadows *= 0.35 }
        out.shadows = clamp(shadows * tune.shadowsScale, -100, 100)

        // 先算曝光修正之后还剩多少动态范围。
        // 直接用原始 span 判断会误判：一张欠曝的夜景 span 天然就小，
        // 但那是「没曝光够」而不是「缺对比」，拿对比去补只会压出死黑。
        let shift = pow(2.0, ev)
        let spanAfter = toSRGB(toLinear(p95) * shift) - toSRGB(toLinear(p05) * shift)

        // --- 去朦胧：管「铺不开」这件事，是这里的主力 ---
        // 两个来源：① 连最暗的 1% 都悬在半空 = 蒙了一层灰；
        //          ② 曝光修正后动态范围仍然窄 = 整体发平。
        // 之所以让去朦胧挑大梁而不是对比滑块：它走的是矩阵 + 偏置，
        // 对暗部温和得多，见下面 contrastCap 的说明。
        var dehaze = 0.0
        if p01 > 0.12 && span < 0.88 {
            dehaze = clamp((p01 - 0.10) * 180, 0, 25)
        }
        if spanAfter < 0.72 {
            dehaze = max(dehaze, clamp((0.72 - spanAfter) * 45, 0, 25))
        }
        // 人像要收着（去朦胧会让皮肤发干发艳），风光可以更足
        out.dehaze = clamp(dehaze * tune.dehazeScale, 0, 25)

        // --- 对比：只补一点点 ---
        // 这个滑块在线性空间里绕 0.5 放大，而线性 0.5 相当于 sRGB 0.735 ——
        // 也就是说**比 sRGB 0.735 暗的像素全都会被正对比压下去**。
        // 对暗画面它是纯粹的整体压暗：实测一张中位 0.051 的夜景，
        // 曝光 +0.8 EV 提上来的亮度会被 contrast +8 全部吃回去。
        // 所以自动只给很小的量，且暗画面一律不给。
        if spanAfter < 0.72 {
            out.contrast = clamp((0.72 - spanAfter) * 25, 0, contrastCap)
        } else if spanAfter > 0.94 {
            out.contrast = -clamp((spanAfter - 0.94) * 180, 0, 15)
        }
        if median < 0.25 { out.contrast = 0 }
        // 高光已经溢出时加对比只会让它更糟（对比绕 0.5 放大，亮端还要往上走）
        if clipHigh > 0.002 { out.contrast = min(out.contrast, 0) }
        out.contrast = clamp(out.contrast * tune.contrastScale, -100, 100)
        if abs(out.contrast) < 3 { out.contrast = 0 }

        // --- 鲜艳度：按「还差多少彩度」补齐，而不是按原始彩度补齐 ---
        // 关键：这个管线里对比和去朦胧都会顺带加彩度（实测对比 +30 会让彩度涨 30%），
        // 三件事各算各的叠起来必然过饱和 —— 一张冰叶菊海岸能被推成刺眼的猩红。
        // 所以先把前面两项预计会加上的彩度算进来，鲜艳度只补差额，甚至可以给负值回拉。
        var predictedSat = avgSat
        if out.contrast > 0 { predictedSat += out.contrast * contrastChromaGain }
        if out.dehaze > 0 { predictedSat += out.dehaze * dehazeChromaGain }
        // 反解而不是按比例缩放：鲜艳度自己也会加彩度，直接乘系数会重复计算，
        // 结果是「补偿完仍然过饱和」。这里按「还差多少」除以它自己的增益来解。
        // 实测 138 张系统壁纸的绝对色度均值 0.26（0.01…0.71）。
        // 目标定在 0.26 而不是更高：大幅提亮鲜艳度会把人像的肤色和有偏色的白区一起放大，
        // 实测一张中位彩度只有 0.09 的人物照，鲜艳度顶到 20 时白衬衫的色偏被明显加强。
        out.vibrance = clamp((0.26 - predictedSat) / vibranceChromaGain, -14, tune.vibranceCap)
        if abs(out.vibrance) < 4 { out.vibrance = 0 }
        // 夜景补一点降噪：暗部噪点在提亮之后最显眼
        out.denoise = tune.denoise

        // --- 白平衡：优先信「本来就不该有颜色」的那批像素 ---
        //
        // 原来用整幅的灰度世界，在一张人物照上翻过车：画面里大片绿植把平均值拉绿，
        // 灰度世界判定「整体偏绿」于是抬蓝，可真正该当白参考的白衬衫和天空本来就偏冷 ——
        // 结果白衬衫的 R/B 从 0.92 掉到 0.82，白衣服越发发蓝。
        //
        // 换成先挑出近中性像素（绝对色度 < neutralChroma）：这些像素本来就该是灰的，
        // 它们偏了才是真的偏色。绿植、花朵、天空这类有色像素直接排除在外。
        // 画面里确实没有近中性色时（比如整幅红花特写），退回灰度世界但把权重压很低。
        var deltaR = 0.0, deltaB = 0.0
        if st.neutralShare >= neutralMinShare, st.neutralR > 1, st.neutralG > 1, st.neutralB > 1 {
            // 中性像素占比越高越可信；刚够门槛时只信一半
            let confidence = clamp(st.neutralShare / neutralFullShare, 0.55, 1.0)
            deltaR = (clamp(st.neutralG / st.neutralR, 0.86, 1.16) - 1) * confidence
            deltaB = (clamp(st.neutralG / st.neutralB, 0.86, 1.16) - 1) * confidence
        } else if st.avgR > 1, st.avgG > 1, st.avgB > 1 {
            deltaR = (clamp(st.avgG / st.avgR, 0.88, 1.14) - 1) * grayFallbackWeight
            deltaB = (clamp(st.avgG / st.avgB, 0.88, 1.14) - 1) * grayFallbackWeight
        }
        var r = 1 + deltaR * neutralCorrection
        var b = 1 + deltaB * neutralCorrection
        if abs(r - 1) < 0.012 { r = 1 }
        if abs(b - 1) < 0.012 { b = 1 }
        // 场景暖调（食物一类）叠在偏色校正之上，最后一起夹住
        if tune.warmth != 0 {
            r *= 1 + tune.warmth
            b *= 1 - tune.warmth
        }
        out.gains = [clamp(r, 0.86, 1.16), 1, clamp(b, 0.86, 1.16)]

        // --- 大范围过曝：用局部蒙版压亮区 ---
        // 全局手段动不了纯白：`whites` 滑块最多把 1.0 拉到 0.90，
        // 而 `highlights` 只管 0.75 那个点。真要压暗爆掉的天/水只能靠局部蒙版。
        // 好处是只压亮区，不连累主体 —— 这张人物照的主体曝光本来是对的。
        if clipHigh > highlightClipTrigger {
            var amount = clamp(((clipHigh - highlightClipTrigger) / 0.15).squareRoot(), 0, 1)
            // 可恢复的高光已经被全局曝光压过一轮了，蒙版就少压一点，别叠两遍
            if recoverable { amount *= 0.6 }
            out.highlightMaskExposure = -amount * highlightMaskCap
        }

        return out
    }

    /// 一步到位：测量 + 求解。
    /// 传 `scene` 就走场景策略，不传（nil）就是纯通用策略 —— 测试里用后者。
    static func analyze(_ source: CIImage, params: EditParams, scene: SceneGuess? = nil) -> Solution {
        guard let st = measure(source, params: params) else { return Solution() }
        var sol = scene.map { solve(st, scene: $0.scene, sceneBlend: $0.blend) } ?? solve(st)
        guard sol.highlightMaskExposure < 0 else { return sol }

        // 蒙版在管线**最后**才应用，它看到的已经是「全局调整之后」的画面。
        // 所以阈值必须按调完之后的亮度来定 —— 拿原始统计直接套会选错区域
        // （全局曝光一压，原本爆白的天空可能已经掉到 0.85 以下了）。
        // 多渲一次 256px 的小图，几毫秒的事。
        let preview = applyGlobal(sol, to: params, strength: 1)
        if let after = measure(source, params: preview) {
            // 锚在 p99 稍下一点：只要「最亮的那 1%」。
            // 留太多余量会把白衬衫这类本来就该白的亮部一起压灰。
            sol.highlightMaskLow = clamp(after.p99 - 0.03, 0.55, 0.95)
        }
        return sol
    }

    // MARK: - 套用

    /// 把自动结果按强度混进现有参数：0 = 完全不动，1 = 全量套用。
    ///
    /// 语义是「在当前值上叠加」而不是「替换成自动值」——
    /// 这样用户已经手动调过的部分不会被抹掉。
    ///
    /// `strength` 允许取负值（-1…1）：强度滑杆是按**增量**调用的，
    /// 从 100% 拖回 60% 时传的是 -0.4，相当于把之前加上的量按比例减回去。
    /// 增量式而不是「从快照重算」有个好处：中途手动改过别的滑块也不会被覆盖。
    static func apply(_ solution: Solution, to base: EditParams, strength: Double) -> EditParams {
        let k = clamp(strength, -1, 1)
        let p = applyGlobal(solution, to: base, strength: k)
        return applyHighlightMask(solution, to: p, delta: k)
    }

    /// 只套「全局参数」那一半。`analyze` 推演蒙版阈值时也用它 ——
    /// 那时候蒙版还没加进去，正好要的就是这个中间状态。
    private static func applyGlobal(_ solution: Solution, to base: EditParams, strength: Double) -> EditParams {
        let k = clamp(strength, -1, 1)
        guard abs(k) > 1e-9 else { return base }
        var p = base
        p.exposure   = clamp(p.exposure   + solution.exposure   * k, -5, 5)
        p.contrast   = clamp(p.contrast   + solution.contrast   * k, -100, 100)
        p.highlights = clamp(p.highlights + solution.highlights * k, -100, 100)
        p.shadows    = clamp(p.shadows    + solution.shadows    * k, -100, 100)
        p.vibrance   = clamp(p.vibrance   + solution.vibrance   * k, -100, 100)
        p.dehaze     = clamp(p.dehaze     + solution.dehaze     * k, -100, 100)
        p.denoise    = clamp(p.denoise    + solution.denoise    * k, 0, 100)

        // 用户自己定过白平衡（色温/色调，或灰点取样留下的增益）就不去动它 —— 别跟用户打架
        let gains = solution.gains
        let untouched = p.temperature == 0 && p.tint == 0 && p.whiteBalanceGains == [1, 1, 1]
        if untouched, gains.count == 3, gains != [1, 1, 1] {
            let cur = p.whiteBalanceGains.count == 3 ? p.whiteBalanceGains : [1, 1, 1]
            // 增益是乘性的：在指数域插值，强度 0.5 相当于「校正量开一半」而不是「色彩减半」
            p.whiteBalanceGains = (0..<3).map { i in
                clamp(cur[i] * pow(max(gains[i], 1e-3), k), 0.25, 4)
            }
        }
        return p
    }

    /// 增量维护「自动压高光」那张蒙版。
    ///
    /// 这里必须是**增量**而不是绝对值：强度滑杆是按 delta 调的，
    /// 从 100% 拖到 60% 传进来的是 -0.4，写绝对值会把蒙版直接设成 -0.4×amount。
    /// 用固定 id 找到那张蒙版原地改，所以再点一次自动也不会攒出一堆蒙版。
    private static func applyHighlightMask(_ solution: Solution, to base: EditParams,
                                           delta: Double) -> EditParams {
        guard abs(solution.highlightMaskExposure) > 1e-9, abs(delta) > 1e-9 else { return base }
        var out = base
        let index = out.masks.firstIndex { $0.id == autoMaskID }
        let current = (index.map { out.masks[$0].adjust.exposure } ?? 0)
            + solution.highlightMaskExposure * delta

        guard abs(current) >= 0.02 else {
            // 压到几乎没有就把蒙版撤掉，不在蒙版列表里留一张空壳
            if let index { out.masks.remove(at: index) }
            return out
        }
        if let index {
            out.masks[index].adjust.exposure = current
            out.masks[index].lumLow = solution.highlightMaskLow
        } else {
            var m = Mask()
            m.id = autoMaskID
            m.kind = .luminanceRange
            m.name = autoMaskName
            m.lumLow = solution.highlightMaskLow
            m.lumHigh = 1.0
            m.lumSoft = highlightMaskSoft
            m.adjust.exposure = current
            out.masks.append(m)
        }
        return out
    }

    // MARK: - 小工具

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    /// sRGB 感知值 → 线性值。曝光是线性域相乘，算 EV 必须先换算。
    private static func toLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// 线性值 → sRGB 感知值
    private static func toSRGB(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055
    }
}
