import Foundation
import CoreImage

// MARK: - 曲线：自由控制点（点数任意，横竖都能拖，像 Lightroom）
struct ToneCurve: Codable, Equatable {
    /// 归一化控制点 [[x, y], ...]，x 升序，首尾固定落在 0 / 1 两条边上。
    var points: [[Double]] = ToneCurve.identityPoints

    static let identityPoints: [[Double]] = [[0, 0], [0.25, 0.25], [0.5, 0.5], [0.75, 0.75], [1, 1]]

    init() {}
    init(points: [[Double]]) { self.points = Self.sanitize(points) }

    /// 排序 + 夹到 [0,1] + 合并过近的点，保证曲线始终是一条函数
    static func sanitize(_ raw: [[Double]]) -> [[Double]] {
        var p = raw.map { [min(max($0[0], 0), 1), min(max($0[1], 0), 1)] }
            .sorted { $0[0] < $1[0] }
        guard p.count >= 2 else { return identityPoints }
        var out: [[Double]] = []
        for q in p {
            if let last = out.last, q[0] - last[0] < 0.006 {
                out[out.count - 1] = q
            } else {
                out.append(q)
            }
        }
        if out.count < 2 { return identityPoints }
        return out
    }

    /// 是否等价于对角直线（用采样判断，2 个点的直线也算）
    var isIdentity: Bool {
        for i in 0...16 {
            let x = Double(i) / 16
            if abs(value(at: x) - x) > 0.004 { return false }
        }
        return true
    }

    /// 单调三次插值（Fritsch–Carlson），支持任意点数与非均匀间距：曲线平滑且不过冲
    func value(at x: Double) -> Double {
        let p = points.count >= 2 ? points : Self.identityPoints
        let xc = min(max(x, 0), 1)
        if xc <= p[0][0] { return p[0][1] }
        let n = p.count
        if xc >= p[n - 1][0] { return p[n - 1][1] }
        var k = 0
        while k < n - 2 && xc > p[k + 1][0] { k += 1 }
        let h = p[k + 1][0] - p[k][0]
        guard h > 1e-9 else { return p[k][1] }

        func secant(_ i: Int) -> Double {
            max(p[i + 1][0] - p[i][0], 1e-9) > 0
                ? (p[i + 1][1] - p[i][1]) / max(p[i + 1][0] - p[i][0], 1e-9) : 0
        }
        func tangent(_ i: Int) -> Double {
            if i == 0 { return secant(0) }
            if i == n - 1 { return secant(n - 2) }
            return (p[i + 1][1] - p[i - 1][1]) / max(p[i + 1][0] - p[i - 1][0], 1e-9)
        }
        let d = secant(k)
        var m0 = tangent(k), m1 = tangent(k + 1)
        if abs(d) < 1e-9 {
            m0 = 0; m1 = 0
        } else {
            var a = m0 / d, b = m1 / d
            if a < 0 { a = 0; m0 = 0 }
            if b < 0 { b = 0; m1 = 0 }
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m0 = t * a * d
                m1 = t * b * d
            }
        }
        let t = (xc - p[k][0]) / h, t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        let v = h00 * p[k][1] + h10 * h * m0 + h01 * p[k + 1][1] + h11 * h * m1
        return min(max(v, 0), 1)
    }

    // 兼容旧副档：以前是固定 5 个 x 的 ys 数组，读进来转成自由控制点
    enum CodingKeys: String, CodingKey { case points, ys }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pts = try c.decodeIfPresent([[Double]].self, forKey: .points) {
            points = Self.sanitize(pts)
        } else if let ys = try c.decodeIfPresent([Double].self, forKey: .ys) {
            let xs = [0.0, 0.25, 0.5, 0.75, 1.0]
            points = Self.sanitize(zip(xs, ys).map { [$0, $1] })
        } else {
            points = Self.identityPoints
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
    }
}

// MARK: - HSL：8 个色相分区
struct HSLBand: Codable, Equatable {
    var hue: Double = 0
    var sat: Double = 0
    var lum: Double = 0
    var isNeutral: Bool { hue == 0 && sat == 0 && lum == 0 }
}
struct HSLMix: Codable, Equatable {
    var red    = HSLBand()
    var orange = HSLBand()
    var yellow = HSLBand()
    var green  = HSLBand()
    var aqua   = HSLBand()
    var blue   = HSLBand()
    var purple = HSLBand()
    var magenta = HSLBand()
    var isNeutral: Bool {
        [red, orange, yellow, green, aqua, blue, purple, magenta].allSatisfy { $0.isNeutral }
    }
    static let names = ["红", "橙", "黄", "绿", "青", "蓝", "紫", "洋红"]
    subscript(i: Int) -> HSLBand {
        get { [red, orange, yellow, green, aqua, blue, purple, magenta][i] }
        set {
            switch i {
            case 0: red = newValue
            case 1: orange = newValue
            case 2: yellow = newValue
            case 3: green = newValue
            case 4: aqua = newValue
            case 5: blue = newValue
            case 6: purple = newValue
            default: magenta = newValue
            }
        }
    }
}

// MARK: - 颜色分级（阴影 / 中间调 / 高光各自上色）
struct ColorGrade: Codable, Equatable {
    var hue: Double = 0        // 度，0...360
    var sat: Double = 0        // 0...100
    var lum: Double = 0        // -100...100 该档的明亮度偏移
    var isNeutral: Bool { sat == 0 && lum == 0 }

    enum CodingKeys: String, CodingKey { case hue, sat, lum }

    // 宽容解码：旧副档没有 lum 字段时不整份作废
    init() {}
    init(hue: Double, sat: Double) { self.hue = hue; self.sat = sat }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        sat = try c.decodeIfPresent(Double.self, forKey: .sat) ?? 0
        lum = try c.decodeIfPresent(Double.self, forKey: .lum) ?? 0
    }
}

// MARK: - 校准：单个原色的色相 / 饱和度
struct PrimaryAdj: Codable, Equatable {
    var hue: Double = 0        // -60...60
    var sat: Double = 0        // -100...100
    var isNeutral: Bool { hue == 0 && sat == 0 }
}

// MARK: - 局部调整（蒙版内生效的那组参数）
struct LocalAdjust: Codable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0
    var clarity: Double = 0
    var sharpen: Double = 0
    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && saturation == 0 && temperature == 0 && clarity == 0 && sharpen == 0
    }
}

// MARK: - 蒙版
enum MaskKind: String, Codable, CaseIterable {
    case linear, radial, brush, colorRange, luminanceRange, subject, person
    var label: String {
        switch self {
        case .linear: return "线性渐变"
        case .radial: return "径向渐变"
        case .brush: return "画笔"
        case .colorRange: return "颜色范围"
        case .luminanceRange: return "亮度范围"
        case .subject: return "选择主体"
        case .person: return "选择人物"
        }
    }
    /// 是否用到了系统视觉模型（Vision），这类蒙版计算较重，需要缓存
    var usesVision: Bool { self == .subject || self == .person }
    var isSampler: Bool { self == .colorRange || self == .luminanceRange }
}

struct Stroke: Codable, Equatable {
    var points: [CGPoint] { pts.map { CGPoint(x: $0[0], y: $0[1]) } }
    var pts: [[Double]] = []
    var radius: Double = 0.05
    var feather: Double = 0.5
}

struct Mask: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: MaskKind = .linear
    var enabled: Bool = true
    var inverted: Bool = false

    init() {}
    // 线性：起点终点；径向：圆心 + 半径；都用归一化坐标
    var x0: Double = 0.3, y0: Double = 0.2
    var x1: Double = 0.7, y1: Double = 0.8
    var radius: Double = 0.3
    var feather: Double = 0.6
    var strokes: [Stroke] = []
    var adjust = LocalAdjust()
    var name: String = "蒙版"

    // 颜色范围：取样色 + 容差；亮度范围：上下界 + 软边
    var sampleRGB: [Double] = [0.5, 0.5, 0.5]
    var tolerance: Double = 0.25
    var lumLow: Double = 0.2
    var lumHigh: Double = 0.8
    var lumSoft: Double = 0.15

    enum CodingKeys: String, CodingKey {
        case id, kind, enabled, inverted, x0, y0, x1, y1, radius, feather, strokes, adjust, name
        case sampleRGB, tolerance, lumLow, lumHigh, lumSoft
    }

    // 宽容解码：旧副档缺取样/范围字段时用默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = Mask()
        id         = try c.decodeIfPresent(UUID.self, forKey: .id)         ?? base.id
        kind       = try c.decodeIfPresent(MaskKind.self, forKey: .kind)   ?? base.kind
        enabled    = try c.decodeIfPresent(Bool.self, forKey: .enabled)    ?? base.enabled
        inverted   = try c.decodeIfPresent(Bool.self, forKey: .inverted)   ?? base.inverted
        x0         = try c.decodeIfPresent(Double.self, forKey: .x0)       ?? base.x0
        y0         = try c.decodeIfPresent(Double.self, forKey: .y0)       ?? base.y0
        x1         = try c.decodeIfPresent(Double.self, forKey: .x1)       ?? base.x1
        y1         = try c.decodeIfPresent(Double.self, forKey: .y1)       ?? base.y1
        radius     = try c.decodeIfPresent(Double.self, forKey: .radius)   ?? base.radius
        feather    = try c.decodeIfPresent(Double.self, forKey: .feather)  ?? base.feather
        strokes    = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? base.strokes
        adjust     = try c.decodeIfPresent(LocalAdjust.self, forKey: .adjust) ?? base.adjust
        name       = try c.decodeIfPresent(String.self, forKey: .name)     ?? base.name
        sampleRGB  = try c.decodeIfPresent([Double].self, forKey: .sampleRGB) ?? base.sampleRGB
        tolerance  = try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? base.tolerance
        lumLow     = try c.decodeIfPresent(Double.self, forKey: .lumLow)   ?? base.lumLow
        lumHigh    = try c.decodeIfPresent(Double.self, forKey: .lumHigh)  ?? base.lumHigh
        lumSoft    = try c.decodeIfPresent(Double.self, forKey: .lumSoft)  ?? base.lumSoft
    }
}

// MARK: - 主参数表
struct EditParams: Codable, Equatable {
    // 基本
    var temperature: Double = 0      // -100...100
    var tint: Double = 0
    var exposure: Double = 0         // EV
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var clarity: Double = 0
    var texture: Double = 0          // 纹理：中频细节（比清晰度更细）
    var dehaze: Double = 0           // 去朦胧：正值去雾，负值加雾
    var hdrMode: Bool = false        // HDR：压高光拉暗部
    var hdrLimit: Double = 50        // HDR Limit：参与压缩的亮度上限
    var vibrance: Double = 0
    var saturation: Double = 0

    // 曲线 / 颜色
    var curve = ToneCurve()          // 色调曲线（RGB 合成，与高光/阴影/白/黑共用一条）
    var lumaCurve = ToneCurve()      // 亮度曲线：只动明暗，尽量保住饱和度
    var curveR = ToneCurve()         // 单独通道曲线
    var curveG = ToneCurve()
    var curveB = ToneCurve()
    var refineSat: Double = 0        // Refine Sat：曲线改调子不动饱和度
    var hsl = HSLMix()

    // 颜色分级（阴影 / 中间调 / 高光 分别上色）
    var gradeShadow = ColorGrade()
    var gradeMid = ColorGrade()
    var gradeHigh = ColorGrade()
    var gradeBlend: Double = 50      // 混合：整体上色强度（50 = 标准量）
    var gradeBalance: Double = 0     // 平衡：三档分界左右移动

    // 黑白
    var mono: Bool = false
    var monoRed: Double = 0.4
    var monoGreen: Double = 0.4
    var monoBlue: Double = 0.2

    // 细节
    var sharpen: Double = 0.35
    var sharpenRadius: Double = 1.0
    var sharpenDetail: Double = 0.5   // 细节：只影响高频的程度
    var sharpenMask: Double = 0       // 蒙版：按住边缘，平区不被放大噪点
    var denoise: Double = 0
    var denoiseColor: Double = 0
    var grain: Double = 0
    var grainSize: Double = 0.6

    // 效果
    var vignette: Double = 0
    var vignetteStart: Double = 0.6
    var halation: Double = 0           // 光晕强度 0...100
    var halationThreshold: Double = 60 // 高光阈值 0...100
    var halationRadius: Double = 0.33  // 半径 0...1 → 长边的 0.5%~2%

    // 镜头校正
    var caAmount: Double = 0           // 横向色差 -100...100
    var purpleFringe: Double = 0       // 紫边抑制 0...100

    // 变换 / 裁剪（归一化，相对整张图）
    var perspectiveAuto: Bool = false  // 自动透视（Vision 矩形检测）
    var perspectiveV: Double = 0       // 垂直透视 -100...100
    var perspectiveH: Double = 0       // 水平透视 -100...100

    // 校准：改 RGB 三原色的原色（定风格的隐藏武器）
    var primRed = PrimaryAdj()
    var primGreen = PrimaryAdj()
    var primBlue = PrimaryAdj()
    var calibShadowTint: Double = 0   // 阴影偏色（偏绿/偏洋红）

    // 胶片
    var clutName: String = ""        // 相对 CLUT 根目录的路径
    var clutStrength: Double = 1.0

    // 变换 / 裁剪（归一化，相对整张图）
    var rotation: Int = 0            // 0/90/180/270
    var flipped: Bool = false
    var straighten: Double = 0       // 度
    var cropX: Double = 0, cropY: Double = 0, cropW: Double = 1, cropH: Double = 1

    var masks: [Mask] = []

    init() {}

    var isNeutral: Bool {
        self == EditParams()
    }

    /// 裁剪模式用的副本：裁剪参数临时归零（画布上显示整幅）
    var cropNeutral: EditParams {
        var c = self
        c.cropX = 0; c.cropY = 0; c.cropW = 1; c.cropH = 1
        return c
    }

    static let neutral = EditParams()

    enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks
        case clarity, vibrance, saturation, texture, dehaze, hdrMode, hdrLimit
        case curve, hsl
        case lumaCurve, curveR, curveG, curveB, refineSat
        case gradeShadow, gradeMid, gradeHigh, gradeBlend, gradeBalance
        case mono, monoRed, monoGreen, monoBlue
        case sharpen, sharpenRadius, sharpenDetail, sharpenMask
        case denoise, denoiseColor, grain, grainSize
        case vignette, vignetteStart
        case halation, halationThreshold, halationRadius
        case caAmount, purpleFringe
        case primRed, primGreen, primBlue, calibShadowTint
        case clutName, clutStrength
        case rotation, flipped, straighten
        case perspectiveAuto, perspectiveV, perspectiveH
        case cropX, cropY, cropW, cropH
        case masks
    }

    // 宽容解码：旧副档缺新字段时用默认值，不整份作废
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = EditParams()
        temperature    = try c.decodeIfPresent(Double.self, forKey: .temperature)    ?? base.temperature
        tint           = try c.decodeIfPresent(Double.self, forKey: .tint)           ?? base.tint
        exposure       = try c.decodeIfPresent(Double.self, forKey: .exposure)       ?? base.exposure
        contrast       = try c.decodeIfPresent(Double.self, forKey: .contrast)       ?? base.contrast
        highlights     = try c.decodeIfPresent(Double.self, forKey: .highlights)     ?? base.highlights
        shadows        = try c.decodeIfPresent(Double.self, forKey: .shadows)        ?? base.shadows
        whites         = try c.decodeIfPresent(Double.self, forKey: .whites)         ?? base.whites
        blacks         = try c.decodeIfPresent(Double.self, forKey: .blacks)         ?? base.blacks
        clarity        = try c.decodeIfPresent(Double.self, forKey: .clarity)        ?? base.clarity
        texture        = try c.decodeIfPresent(Double.self, forKey: .texture)        ?? base.texture
        dehaze         = try c.decodeIfPresent(Double.self, forKey: .dehaze)         ?? base.dehaze
        hdrMode        = try c.decodeIfPresent(Bool.self, forKey: .hdrMode)          ?? base.hdrMode
        hdrLimit       = try c.decodeIfPresent(Double.self, forKey: .hdrLimit)       ?? base.hdrLimit
        vibrance       = try c.decodeIfPresent(Double.self, forKey: .vibrance)       ?? base.vibrance
        saturation     = try c.decodeIfPresent(Double.self, forKey: .saturation)     ?? base.saturation
        refineSat      = try c.decodeIfPresent(Double.self, forKey: .refineSat)      ?? base.refineSat
        gradeShadow    = try c.decodeIfPresent(ColorGrade.self, forKey: .gradeShadow) ?? base.gradeShadow
        gradeMid       = try c.decodeIfPresent(ColorGrade.self, forKey: .gradeMid)   ?? base.gradeMid
        gradeHigh      = try c.decodeIfPresent(ColorGrade.self, forKey: .gradeHigh)  ?? base.gradeHigh
        gradeBlend     = try c.decodeIfPresent(Double.self, forKey: .gradeBlend)     ?? base.gradeBlend
        gradeBalance   = try c.decodeIfPresent(Double.self, forKey: .gradeBalance)   ?? base.gradeBalance
        sharpenDetail  = try c.decodeIfPresent(Double.self, forKey: .sharpenDetail)  ?? base.sharpenDetail
        sharpenMask    = try c.decodeIfPresent(Double.self, forKey: .sharpenMask)    ?? base.sharpenMask
        primRed        = try c.decodeIfPresent(PrimaryAdj.self, forKey: .primRed)    ?? base.primRed
        primGreen      = try c.decodeIfPresent(PrimaryAdj.self, forKey: .primGreen)  ?? base.primGreen
        primBlue       = try c.decodeIfPresent(PrimaryAdj.self, forKey: .primBlue)   ?? base.primBlue
        calibShadowTint = try c.decodeIfPresent(Double.self, forKey: .calibShadowTint) ?? base.calibShadowTint
        curve          = try c.decodeIfPresent(ToneCurve.self, forKey: .curve)       ?? base.curve
        lumaCurve      = try c.decodeIfPresent(ToneCurve.self, forKey: .lumaCurve)   ?? base.lumaCurve
        curveR         = try c.decodeIfPresent(ToneCurve.self, forKey: .curveR)      ?? base.curveR
        curveG         = try c.decodeIfPresent(ToneCurve.self, forKey: .curveG)      ?? base.curveG
        curveB         = try c.decodeIfPresent(ToneCurve.self, forKey: .curveB)      ?? base.curveB
        hsl            = try c.decodeIfPresent(HSLMix.self, forKey: .hsl)            ?? base.hsl
        mono           = try c.decodeIfPresent(Bool.self, forKey: .mono)             ?? base.mono
        monoRed        = try c.decodeIfPresent(Double.self, forKey: .monoRed)        ?? base.monoRed
        monoGreen      = try c.decodeIfPresent(Double.self, forKey: .monoGreen)      ?? base.monoGreen
        monoBlue       = try c.decodeIfPresent(Double.self, forKey: .monoBlue)       ?? base.monoBlue
        sharpen        = try c.decodeIfPresent(Double.self, forKey: .sharpen)        ?? base.sharpen
        sharpenRadius  = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius)  ?? base.sharpenRadius
        denoise        = try c.decodeIfPresent(Double.self, forKey: .denoise)        ?? base.denoise
        denoiseColor   = try c.decodeIfPresent(Double.self, forKey: .denoiseColor)   ?? base.denoiseColor
        grain          = try c.decodeIfPresent(Double.self, forKey: .grain)          ?? base.grain
        grainSize      = try c.decodeIfPresent(Double.self, forKey: .grainSize)      ?? base.grainSize
        vignette       = try c.decodeIfPresent(Double.self, forKey: .vignette)       ?? base.vignette
        vignetteStart  = try c.decodeIfPresent(Double.self, forKey: .vignetteStart)  ?? base.vignetteStart
        halation       = try c.decodeIfPresent(Double.self, forKey: .halation)       ?? base.halation
        halationThreshold = try c.decodeIfPresent(Double.self, forKey: .halationThreshold) ?? base.halationThreshold
        halationRadius = try c.decodeIfPresent(Double.self, forKey: .halationRadius) ?? base.halationRadius
        caAmount       = try c.decodeIfPresent(Double.self, forKey: .caAmount)       ?? base.caAmount
        purpleFringe   = try c.decodeIfPresent(Double.self, forKey: .purpleFringe)   ?? base.purpleFringe
        perspectiveAuto = try c.decodeIfPresent(Bool.self, forKey: .perspectiveAuto) ?? base.perspectiveAuto
        perspectiveV   = try c.decodeIfPresent(Double.self, forKey: .perspectiveV)   ?? base.perspectiveV
        perspectiveH   = try c.decodeIfPresent(Double.self, forKey: .perspectiveH)   ?? base.perspectiveH
        clutName       = try c.decodeIfPresent(String.self, forKey: .clutName)       ?? base.clutName
        clutStrength   = try c.decodeIfPresent(Double.self, forKey: .clutStrength)   ?? base.clutStrength
        rotation       = try c.decodeIfPresent(Int.self, forKey: .rotation)          ?? base.rotation
        flipped        = try c.decodeIfPresent(Bool.self, forKey: .flipped)          ?? base.flipped
        straighten     = try c.decodeIfPresent(Double.self, forKey: .straighten)     ?? base.straighten
        cropX          = try c.decodeIfPresent(Double.self, forKey: .cropX)          ?? base.cropX
        cropY          = try c.decodeIfPresent(Double.self, forKey: .cropY)          ?? base.cropY
        cropW          = try c.decodeIfPresent(Double.self, forKey: .cropW)          ?? base.cropW
        cropH          = try c.decodeIfPresent(Double.self, forKey: .cropH)          ?? base.cropH
        masks          = try c.decodeIfPresent([Mask].self, forKey: .masks)          ?? base.masks
    }
}

// MARK: - 预设
struct Preset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var params: EditParams
    var builtin: Bool = false
}

// MARK: - 导出设置
struct ExportSettings: Codable, Equatable {
    var format: String = "jpg"       // jpg / png / tiff / heic
    var quality: Double = 0.95
    var maxLongEdge: Int = 0         // 0 = 不缩放
    var sharpenForOutput: Bool = false
}

// MARK: - 多重曝光合成模式
enum MergeMode: String, Codable, CaseIterable {
    case average, fusion
    var label: String {
        switch self {
        case .average: return "平均合成"
        case .fusion:  return "曝光融合"
        }
    }
    var hint: String {
        switch self {
        case .average: return "所有帧等权叠加：适合降噪、流水/星轨，张数越多越干净"
        case .fusion:  return "按每像素的曝光合适度加权：每张取它曝光最好的部分，适合大光比的包围曝光"
        }
    }
}

// MARK: - 副档存档（非破坏编辑）
struct Sidecar: Codable {
    var version: Int = 1
    var app: String = "RawForge"
    var params: EditParams
    var rating: Int = 0
    var picked: Bool = false
}

enum SidecarStore {
    static func url(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("rawforge.json")
    }
    static func load(for url: URL) -> Sidecar? {
        let s = url.deletingPathExtension().appendingPathExtension("rawforge.json")
        guard let d = try? Data(contentsOf: s),
              let c = try? JSONDecoder().decode(Sidecar.self, from: d) else { return nil }
        return c
    }
    static func save(_ s: Sidecar, for url: URL) {
        let dest = url.deletingPathExtension().appendingPathExtension("rawforge.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(s) else { return }
        try? d.write(to: dest)
    }
}

// MARK: - 历史栈
final class History: ObservableObject {
    @Published var stack: [EditParams] = []
    @Published var index: Int = -1

    func push(_ p: EditParams) {
        if index < stack.count - 1 { stack.removeSubrange((index + 1)...) }
        stack.append(p)
        if stack.count > 200 { stack.removeFirst() }
        index = stack.count - 1
    }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < stack.count - 1 }
    func undo() -> EditParams? {
        guard canUndo else { return nil }
        index -= 1; return stack[index]
    }
    func redo() -> EditParams? {
        guard canRedo else { return nil }
        index += 1; return stack[index]
    }
}
