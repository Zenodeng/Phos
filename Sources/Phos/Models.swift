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
        let p = raw.compactMap { pair -> [Double]? in
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return nil }
            return [min(max(pair[0], 0), 1), min(max(pair[1], 0), 1)]
        }.sorted { $0[0] < $1[0] }
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
        if out[0][0] > 0 { out.insert([0, out[0][1]], at: 0) }
        if out[out.count - 1][0] < 1 { out.append([1, out[out.count - 1][1]]) }
        out[0][0] = 0
        out[out.count - 1][0] = 1
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

// MARK: - 颜色标签与点颜色
enum ColorLabel: String, Codable, CaseIterable {
    case none, red, yellow, green, blue, purple
    var label: String {
        switch self {
        case .none: return "无色标"
        case .red: return "红"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        }
    }
}

struct PointColorSwatch: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "色样"
    var sampleRGB: [Double] = [0.5, 0.5, 0.5]
    var hueShift: Double = 0         // -180...180
    var chromaShift: Double = 0      // -100...100
    var lumaShift: Double = 0        // -100...100
    var range: Double = 0.4          // 0.05...1.0
    var hueRange: Double = 0.45      // 0.1...1.0
    var chromaRange: Double = 0.6    // 0.1...1.0
    var lumaRange: Double = 0.7      // 0.1...1.0
    var enabled: Bool = true

    var isNeutral: Bool {
        !enabled || (abs(hueShift) < 1e-4 && abs(chromaShift) < 1e-4 && abs(lumaShift) < 1e-4)
    }

    init() {}
    init(sampleRGB: [Double], name: String = "色样") {
        self.sampleRGB = sampleRGB
        self.name = name
    }
    enum CodingKeys: String, CodingKey {
        case id, name, sampleRGB, hueShift, chromaShift, lumaShift
        case range, hueRange, chromaRange, lumaRange, enabled
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PointColorSwatch()
        id          = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name        = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        sampleRGB   = try c.decodeIfPresent([Double].self, forKey: .sampleRGB) ?? d.sampleRGB
        hueShift    = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? d.hueShift
        chromaShift = try c.decodeIfPresent(Double.self, forKey: .chromaShift) ?? d.chromaShift
        lumaShift   = try c.decodeIfPresent(Double.self, forKey: .lumaShift) ?? d.lumaShift
        range       = try c.decodeIfPresent(Double.self, forKey: .range) ?? d.range
        hueRange    = try c.decodeIfPresent(Double.self, forKey: .hueRange) ?? d.hueRange
        chromaRange = try c.decodeIfPresent(Double.self, forKey: .chromaRange) ?? d.chromaRange
        lumaRange   = try c.decodeIfPresent(Double.self, forKey: .lumaRange) ?? d.lumaRange
        enabled     = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    }
}

// MARK: - 污点修复与内容感知消除
enum RetouchMode: String, Codable, CaseIterable {
    case heal, clone, remove
    var label: String {
        switch self {
        case .heal: return "污点修复"
        case .clone: return "仿制克隆"
        case .remove: return "智能消除"
        }
    }
}

struct RetouchSpot: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var mode: RetouchMode = .heal
    /// 归一化坐标 [[x, y], ...]，y 向上。单点为圆形污点，多点为涂抹路径。
    var points: [[Double]] = []
    var sourceX: Double? = nil
    var sourceY: Double? = nil
    var radius: Double = 0.025
    var feather: Double = 0.5
    var opacity: Double = 1.0
    var enabled: Bool = true

    init() {}
    init(mode: RetouchMode, pts: [[Double]] = [], radius: Double = 0.025, feather: Double = 0.5) {
        self.mode = mode; self.points = pts; self.radius = radius; self.feather = feather
    }
    enum CodingKeys: String, CodingKey {
        case id, mode, points, sourceX, sourceY, radius, feather, opacity, enabled
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RetouchSpot()
        id      = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        mode    = try c.decodeIfPresent(RetouchMode.self, forKey: .mode) ?? d.mode
        points  = try c.decodeIfPresent([[Double]].self, forKey: .points) ?? d.points
        sourceX = try c.decodeIfPresent(Double.self, forKey: .sourceX)
        sourceY = try c.decodeIfPresent(Double.self, forKey: .sourceY)
        radius  = try c.decodeIfPresent(Double.self, forKey: .radius) ?? d.radius
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? d.feather
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    }
}

// MARK: - 局部调整（蒙版内生效的那组参数）
struct LocalAdjust: Codable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0
    var clarity: Double = 0
    var sharpen: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var tint: Double = 0
    var texture: Double = 0
    var dehaze: Double = 0
    var denoise: Double = 0
    var hueShift: Double = 0
    var pointColor: PointColorSwatch? = nil
    var curve: ToneCurve? = nil
    var clutName: String = ""
    var clutStrength: Double = 1.0

    init() {}

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperature, clarity, sharpen
        case highlights, shadows, whites, blacks, tint, texture, dehaze, denoise
        case hueShift, pointColor, curve, clutName, clutStrength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        denoise = try c.decodeIfPresent(Double.self, forKey: .denoise) ?? 0
        hueShift = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? 0
        pointColor = try c.decodeIfPresent(PointColorSwatch.self, forKey: .pointColor)
        curve = try c.decodeIfPresent(ToneCurve.self, forKey: .curve)
        clutName = try c.decodeIfPresent(String.self, forKey: .clutName) ?? ""
        clutStrength = try c.decodeIfPresent(Double.self, forKey: .clutStrength) ?? 1.0
    }

    var isNeutral: Bool {
        let curveNeutral = curve == nil || curve?.isIdentity == true
        let pcNeutral = pointColor == nil || pointColor?.isNeutral == true
        let clutNeutral = clutName.isEmpty || clutStrength <= 0
        return exposure == 0 && contrast == 0 && saturation == 0 && temperature == 0 && clarity == 0 && sharpen == 0
            && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0
            && tint == 0 && texture == 0 && dehaze == 0 && denoise == 0
            && hueShift == 0 && curveNeutral && pcNeutral && clutNeutral
    }
}

// MARK: - 蒙版与布尔组合
enum MaskBoolOp: String, Codable, CaseIterable {
    case add, subtract, intersect
    var label: String {
        switch self {
        case .add: return "添加"
        case .subtract: return "减去"
        case .intersect: return "交叉"
        }
    }
    var symbol: String {
        switch self {
        case .add: return "plus.square"
        case .subtract: return "minus.square"
        case .intersect: return "square.on.square"
        }
    }
}

enum MaskKind: String, Codable, CaseIterable {
    case linear, radial, brush, colorRange, luminanceRange, subject, person, foreground, depth
    case sky, background, faceSkin, bodySkin, eyes, eyebrows, lips, teeth, hair, clothes
    var label: String {
        switch self {
        case .linear: return "线性渐变"
        case .radial: return "径向渐变"
        case .brush: return "画笔"
        case .colorRange: return "颜色范围"
        case .luminanceRange: return "亮度范围"
        case .subject: return "选择主体"
        case .person: return "选择人物"
        case .foreground: return "主体抠图"
        case .depth: return "深度涂绘"
        case .sky: return "选择天空"
        case .background: return "选择背景"
        case .faceSkin: return "面部皮肤"
        case .bodySkin: return "身体皮肤"
        case .eyes: return "眼睛"
        case .eyebrows: return "眉毛"
        case .lips: return "嘴唇"
        case .teeth: return "牙齿"
        case .hair: return "头发"
        case .clothes: return "衣服"
        }
    }
    /// 是否用到了系统视觉模型（Vision），这类蒙版计算较重，需要缓存
    var usesVision: Bool {
        switch self {
        case .subject, .person, .foreground, .sky, .background,
             .faceSkin, .bodySkin, .eyes, .eyebrows, .lips, .teeth, .hair, .clothes:
            return true
        default:
            return false
        }
    }
    var isSampler: Bool { self == .colorRange || self == .luminanceRange }
}

struct MaskComponent: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var op: MaskBoolOp = .add
    var kind: MaskKind = .linear
    var enabled: Bool = true
    var inverted: Bool = false
    var x0: Double = 0.3, y0: Double = 0.2
    var x1: Double = 0.7, y1: Double = 0.8
    var radius: Double = 0.3
    var gradientVersion: Int? = 1
    var radiusX: Double? = 0.3
    var radiusY: Double? = 0.3
    var radialAngle: Double = 0
    var feather: Double = 0.6
    var strokes: [Stroke] = []
    var sampleRGB: [Double] = [0.5, 0.5, 0.5]
    var tolerance: Double = 0.25
    var lumLow: Double = 0.2
    var lumHigh: Double = 0.8
    var lumSoft: Double = 0.15

    init() {}
    init(op: MaskBoolOp, kind: MaskKind) {
        self.op = op; self.kind = kind
    }

    func asMask() -> Mask {
        var m = Mask()
        m.id = id
        m.kind = kind
        m.enabled = enabled
        m.inverted = inverted
        m.x0 = x0; m.y0 = y0; m.x1 = x1; m.y1 = y1
        m.radius = radius
        m.gradientVersion = gradientVersion
        m.radiusX = radiusX; m.radiusY = radiusY
        m.radialAngle = radialAngle
        m.feather = feather
        m.strokes = strokes
        m.sampleRGB = sampleRGB; m.tolerance = tolerance
        m.lumLow = lumLow; m.lumHigh = lumHigh; m.lumSoft = lumSoft
        m.refineEdges = false
        return m
    }

    mutating func applyGeometry(from m: Mask) {
        x0 = m.x0; y0 = m.y0; x1 = m.x1; y1 = m.y1
        radius = m.radius
        gradientVersion = m.gradientVersion
        radiusX = m.radiusX; radiusY = m.radiusY
        radialAngle = m.radialAngle
        feather = m.feather
        strokes = m.strokes
        sampleRGB = m.sampleRGB; tolerance = m.tolerance
        lumLow = m.lumLow; lumHigh = m.lumHigh; lumSoft = m.lumSoft
    }

    enum CodingKeys: String, CodingKey {
        case id, op, kind, enabled, inverted, x0, y0, x1, y1, radius
        case gradientVersion, radiusX, radiusY, radialAngle, feather, strokes
        case sampleRGB, tolerance, lumLow, lumHigh, lumSoft
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MaskComponent()
        id       = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        op       = try c.decodeIfPresent(MaskBoolOp.self, forKey: .op) ?? d.op
        kind     = try c.decodeIfPresent(MaskKind.self, forKey: .kind) ?? d.kind
        enabled  = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? d.inverted
        x0       = try c.decodeIfPresent(Double.self, forKey: .x0) ?? d.x0
        y0       = try c.decodeIfPresent(Double.self, forKey: .y0) ?? d.y0
        x1       = try c.decodeIfPresent(Double.self, forKey: .x1) ?? d.x1
        y1       = try c.decodeIfPresent(Double.self, forKey: .y1) ?? d.y1
        radius   = try c.decodeIfPresent(Double.self, forKey: .radius) ?? d.radius
        gradientVersion = try c.decodeIfPresent(Int.self, forKey: .gradientVersion) ?? d.gradientVersion
        radiusX  = try c.decodeIfPresent(Double.self, forKey: .radiusX) ?? d.radiusX
        radiusY  = try c.decodeIfPresent(Double.self, forKey: .radiusY) ?? d.radiusY
        radialAngle = try c.decodeIfPresent(Double.self, forKey: .radialAngle) ?? d.radialAngle
        feather  = try c.decodeIfPresent(Double.self, forKey: .feather) ?? d.feather
        strokes  = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? d.strokes
        sampleRGB = try c.decodeIfPresent([Double].self, forKey: .sampleRGB) ?? d.sampleRGB
        tolerance = try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? d.tolerance
        lumLow   = try c.decodeIfPresent(Double.self, forKey: .lumLow) ?? d.lumLow
        lumHigh  = try c.decodeIfPresent(Double.self, forKey: .lumHigh) ?? d.lumHigh
        lumSoft  = try c.decodeIfPresent(Double.self, forKey: .lumSoft) ?? d.lumSoft
    }
}

struct Stroke: Codable, Equatable {
    var points: [CGPoint] { pts.map { CGPoint(x: $0[0], y: $0[1]) } }
    var pts: [[Double]] = []
    var radius: Double = 0.05
    var feather: Double = 0.5
    var erasing: Bool = false
    var autoMask: Bool = false
    var autoMaskTolerance: Double = 0.16
    var sampleRGB: [Double]? = nil
    var pressures: [Double] = []

    init(pts: [[Double]] = [], radius: Double = 0.05, feather: Double = 0.5, erasing: Bool = false,
         autoMask: Bool = false, autoMaskTolerance: Double = 0.16,
         sampleRGB: [Double]? = nil, pressures: [Double] = []) {
        self.pts = pts; self.radius = radius; self.feather = feather; self.erasing = erasing
        self.autoMask = autoMask; self.autoMaskTolerance = autoMaskTolerance
        self.sampleRGB = sampleRGB; self.pressures = pressures
    }
    enum CodingKeys: String, CodingKey {
        case pts, radius, feather, erasing, autoMask, autoMaskTolerance, sampleRGB, pressures
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pts = try c.decodeIfPresent([[Double]].self, forKey: .pts) ?? []
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.05
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.5
        erasing = try c.decodeIfPresent(Bool.self, forKey: .erasing) ?? false
        autoMask = try c.decodeIfPresent(Bool.self, forKey: .autoMask) ?? false
        autoMaskTolerance = try c.decodeIfPresent(Double.self, forKey: .autoMaskTolerance) ?? 0.16
        sampleRGB = try c.decodeIfPresent([Double].self, forKey: .sampleRGB)
        pressures = try c.decodeIfPresent([Double].self, forKey: .pressures) ?? []
    }
}

struct Mask: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: MaskKind = .linear
    var enabled: Bool = true
    var inverted: Bool = false

    init() {}
    // 线性：起点终点；径向：圆心归一化，半径为图像短边的比例
    var x0: Double = 0.3, y0: Double = 0.2
    var x1: Double = 0.7, y1: Double = 0.8
    var radius: Double = 0.3
    var gradientVersion: Int? = nil
    var radiusX: Double? = nil
    var radiusY: Double? = nil
    var radialAngle: Double = 0    // 度，图像 y 向上，逆时针为正
    var feather: Double = 0.6
    var strokes: [Stroke] = []
    var refinements: [Stroke] = []
    var adjust = LocalAdjust()
    var name: String = "蒙版"

    // 颜色范围：取样色 + 容差；亮度范围：上下界 + 软边
    var sampleRGB: [Double] = [0.5, 0.5, 0.5]
    var tolerance: Double = 0.25
    var lumLow: Double = 0.2
    var lumHigh: Double = 0.8
    var lumSoft: Double = 0.15
    var components: [MaskComponent] = []
    var refineEdges: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, kind, enabled, inverted, x0, y0, x1, y1, radius, feather, strokes, adjust, name
        case gradientVersion, radiusX, radiusY, radialAngle
        case sampleRGB, tolerance, lumLow, lumHigh, lumSoft
        case refinements, components, refineEdges
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
        gradientVersion = try c.decodeIfPresent(Int.self, forKey: .gradientVersion)
        radiusX    = try c.decodeIfPresent(Double.self, forKey: .radiusX)
        radiusY    = try c.decodeIfPresent(Double.self, forKey: .radiusY)
        radialAngle = try c.decodeIfPresent(Double.self, forKey: .radialAngle) ?? 0
        feather    = try c.decodeIfPresent(Double.self, forKey: .feather)  ?? base.feather
        strokes    = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? base.strokes
        refinements = try c.decodeIfPresent([Stroke].self, forKey: .refinements) ?? []
        adjust     = try c.decodeIfPresent(LocalAdjust.self, forKey: .adjust) ?? base.adjust
        name       = try c.decodeIfPresent(String.self, forKey: .name)     ?? base.name
        sampleRGB  = try c.decodeIfPresent([Double].self, forKey: .sampleRGB) ?? base.sampleRGB
        tolerance  = try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? base.tolerance
        lumLow     = try c.decodeIfPresent(Double.self, forKey: .lumLow)   ?? base.lumLow
        lumHigh    = try c.decodeIfPresent(Double.self, forKey: .lumHigh)  ?? base.lumHigh
        lumSoft    = try c.decodeIfPresent(Double.self, forKey: .lumSoft)  ?? base.lumSoft
        components = try c.decodeIfPresent([MaskComponent].self, forKey: .components) ?? []
        refineEdges = try c.decodeIfPresent(Bool.self, forKey: .refineEdges) ?? true
    }
}

// MARK: - 主参数表
struct EditParams: Codable, Equatable {
    // 基本
    var temperature: Double = 0      // -100...100
    var tint: Double = 0
    var whiteBalanceGains: [Double] = [1, 1, 1]
    var exposure: Double = 0         // EV
    var contrast: Double = 0
    var contrastPivot: Double = 0    // -50...50，对比度中灰支点偏移
    var highlightRolloff: Double = 0 // 0...100，AgX 高光柔滑滚降
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
    var pointColors: [PointColorSwatch] = [] // OKLCH 点颜色精确色板

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
    var aiDenoise: Double = 0         // AI/Metal RAW 线性域保边降噪 0...100
    var aiDenoiseDetail: Double = 50  // AI 降噪细节保留 0...100
    var superResolution: Bool = false // 2x 超分辨率导出/全像素增强
    var grain: Double = 0
    var grainSize: Double = 0.6
    var grainRoughness: Double = 0.5
    var retouchSpots: [RetouchSpot] = []

    // 效果
    var vignette: Double = 0
    var vignetteStart: Double = 0.6
    var halation: Double = 0           // 光晕强度 0...100
    var halationThreshold: Double = 60 // 高光阈值 0...100
    var halationRadius: Double = 0.33  // 半径 0...1 → 长边的 0.5%~2%

    // 焦外散景：0 = 关闭，0...100 控制虚化强度。
    // 深度蒙版来源：深度涂绘蒙版 > HEIC disparity > P3 单目深度估计
    var bokehAmount: Double = 0
    var bokehFocusDepth: Double = 0.12     // 焦平面深度 0（近）...1（远）
    var bokehFocusRange: Double = 0.20     // 清晰景深带宽 0.02...0.6
    var bokehBlades: Int = 0               // 0=圆形，5/6/7/8=多边形光圈叶片
    var bokehHighlightBoost: Double = 35   // 线性 HDR 高光散景光斑增益 0...100
    var bokehCatEye: Double = 20           // 边角机械暗角猫眼旋焦 0...100
    var bokehAutoDepth: Bool = true        // 无 disparity/手涂深度时自动启用单目深度估计

    // 镜头校正
    var lensCorrection: LensCorrection? = nil
    var rawEmbeddedLensCorrection: Bool = true
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

    /// 按预设强度（0.0...2.0，1.0 = 原预设）从中性参数向当前预设做线性缩放，保留几何与离散开关。
    func scaled(by amount: Double) -> EditParams {
        let a = min(max(amount, 0.0), 2.0)
        if abs(a - 1.0) < 1e-6 { return self }
        let d = EditParams()
        var out = self

        func s(_ v: Double, _ base: Double, _ range: ClosedRange<Double>) -> Double {
            let scaled = base + (v - base) * a
            return min(max(scaled, range.lowerBound), range.upperBound)
        }
        func scaleCurve(_ c: ToneCurve) -> ToneCurve {
            if c.isIdentity { return c }
            let pts = c.points.map { pt -> [Double] in
                guard pt.count >= 2 else { return pt }
                let x = pt[0]
                let y = min(max(x + (pt[1] - x) * a, 0.0), 1.0)
                return [x, y]
            }
            return ToneCurve(points: pts)
        }
        func scaleBand(_ b: HSLBand) -> HSLBand {
            HSLBand(hue: s(b.hue, 0, -100...100),
                    sat: s(b.sat, 0, -100...100),
                    lum: s(b.lum, 0, -100...100))
        }
        func scaleGrade(_ g: ColorGrade) -> ColorGrade {
            var r = g
            r.sat = s(g.sat, 0, 0...100)
            r.lum = s(g.lum, 0, -100...100)
            return r
        }
        func scalePrim(_ p: PrimaryAdj) -> PrimaryAdj {
            PrimaryAdj(hue: s(p.hue, 0, -60...60), sat: s(p.sat, 0, -100...100))
        }

        out.temperature = s(temperature, d.temperature, -100...100)
        out.tint = s(tint, d.tint, -100...100)
        if whiteBalanceGains.count == 3 {
            out.whiteBalanceGains = zip(whiteBalanceGains, d.whiteBalanceGains).map { s($0, $1, 0.1...4.0) }
        }
        out.exposure = s(exposure, d.exposure, -5...5)
        out.contrast = s(contrast, d.contrast, -100...100)
        out.contrastPivot = s(contrastPivot, d.contrastPivot, -1...1)
        out.highlightRolloff = s(highlightRolloff, d.highlightRolloff, 0...100)
        out.highlights = s(highlights, d.highlights, -100...100)
        out.shadows = s(shadows, d.shadows, -100...100)
        out.whites = s(whites, d.whites, -100...100)
        out.blacks = s(blacks, d.blacks, -100...100)
        out.texture = s(texture, d.texture, -100...100)
        out.clarity = s(clarity, d.clarity, 0...100)
        out.dehaze = s(dehaze, d.dehaze, -100...100)
        out.vibrance = s(vibrance, d.vibrance, -100...100)
        out.saturation = s(saturation, d.saturation, -100...100)

        out.curve = scaleCurve(curve)
        out.lumaCurve = scaleCurve(lumaCurve)
        out.curveR = scaleCurve(curveR)
        out.curveG = scaleCurve(curveG)
        out.curveB = scaleCurve(curveB)
        out.refineSat = s(refineSat, d.refineSat, 0...100)

        out.hsl.red = scaleBand(hsl.red)
        out.hsl.orange = scaleBand(hsl.orange)
        out.hsl.yellow = scaleBand(hsl.yellow)
        out.hsl.green = scaleBand(hsl.green)
        out.hsl.aqua = scaleBand(hsl.aqua)
        out.hsl.blue = scaleBand(hsl.blue)
        out.hsl.purple = scaleBand(hsl.purple)
        out.hsl.magenta = scaleBand(hsl.magenta)

        out.pointColors = pointColors.map { sw in
            var copy = sw
            copy.hueShift = s(sw.hueShift, 0, -180...180)
            copy.chromaShift = s(sw.chromaShift, 0, -100...100)
            copy.lumaShift = s(sw.lumaShift, 0, -100...100)
            return copy
        }

        out.gradeShadow = scaleGrade(gradeShadow)
        out.gradeMid = scaleGrade(gradeMid)
        out.gradeHigh = scaleGrade(gradeHigh)
        out.gradeBlend = s(gradeBlend, d.gradeBlend, 0...100)
        out.gradeBalance = s(gradeBalance, d.gradeBalance, -100...100)

        out.mono = mono && a > 0.001
        out.monoRed = s(monoRed, d.monoRed, 0...1)
        out.monoGreen = s(monoGreen, d.monoGreen, 0...1)
        out.monoBlue = s(monoBlue, d.monoBlue, 0...1)

        out.sharpen = s(sharpen, d.sharpen, 0...2)
        out.denoise = s(denoise, d.denoise, 0...100)
        out.denoiseColor = s(denoiseColor, d.denoiseColor, 0...100)
        out.aiDenoise = s(aiDenoise, d.aiDenoise, 0...100)
        out.grain = s(grain, d.grain, 0...100)

        out.vignette = s(vignette, d.vignette, -100...100)
        out.halation = s(halation, d.halation, 0...100)
        out.bokehAmount = s(bokehAmount, d.bokehAmount, 0...100)
        out.bokehHighlightBoost = s(bokehHighlightBoost, d.bokehHighlightBoost, 0...100)
        out.bokehCatEye = s(bokehCatEye, d.bokehCatEye, 0...100)
        out.caAmount = s(caAmount, d.caAmount, -100...100)
        out.purpleFringe = s(purpleFringe, d.purpleFringe, 0...100)

        out.primRed = scalePrim(primRed)
        out.primGreen = scalePrim(primGreen)
        out.primBlue = scalePrim(primBlue)
        out.calibShadowTint = s(calibShadowTint, d.calibShadowTint, -100...100)
        out.clutStrength = s(clutStrength, 0.0, 0...1)
        if out.clutStrength <= 0.0001 { out.clutName = "" }
        return out
    }

    static let neutral = EditParams()

    enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, contrast, contrastPivot, highlightRolloff
        case highlights, shadows, whites, blacks
        case whiteBalanceGains
        case clarity, vibrance, saturation, texture, dehaze, hdrMode, hdrLimit
        case curve, hsl, pointColors
        case lumaCurve, curveR, curveG, curveB, refineSat
        case gradeShadow, gradeMid, gradeHigh, gradeBlend, gradeBalance
        case mono, monoRed, monoGreen, monoBlue
        case sharpen, sharpenRadius, sharpenDetail, sharpenMask
        case denoise, denoiseColor, aiDenoise, aiDenoiseDetail, superResolution
        case grain, grainSize, grainRoughness, retouchSpots
        case vignette, vignetteStart
        case halation, halationThreshold, halationRadius
        case bokehAmount, bokehFocusDepth, bokehFocusRange, bokehBlades
        case bokehHighlightBoost, bokehCatEye, bokehAutoDepth
        case lensCorrection, rawEmbeddedLensCorrection
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
        whiteBalanceGains = try c.decodeIfPresent([Double].self, forKey: .whiteBalanceGains) ?? [1, 1, 1]
        exposure       = try c.decodeIfPresent(Double.self, forKey: .exposure)       ?? base.exposure
        contrast       = try c.decodeIfPresent(Double.self, forKey: .contrast)       ?? base.contrast
        contrastPivot  = try c.decodeIfPresent(Double.self, forKey: .contrastPivot)  ?? base.contrastPivot
        highlightRolloff = try c.decodeIfPresent(Double.self, forKey: .highlightRolloff) ?? base.highlightRolloff
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
        pointColors    = try c.decodeIfPresent([PointColorSwatch].self, forKey: .pointColors) ?? base.pointColors
        mono           = try c.decodeIfPresent(Bool.self, forKey: .mono)             ?? base.mono
        monoRed        = try c.decodeIfPresent(Double.self, forKey: .monoRed)        ?? base.monoRed
        monoGreen      = try c.decodeIfPresent(Double.self, forKey: .monoGreen)      ?? base.monoGreen
        monoBlue       = try c.decodeIfPresent(Double.self, forKey: .monoBlue)       ?? base.monoBlue
        sharpen        = try c.decodeIfPresent(Double.self, forKey: .sharpen)        ?? base.sharpen
        sharpenRadius  = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius)  ?? base.sharpenRadius
        denoise        = try c.decodeIfPresent(Double.self, forKey: .denoise)        ?? base.denoise
        denoiseColor   = try c.decodeIfPresent(Double.self, forKey: .denoiseColor)   ?? base.denoiseColor
        aiDenoise      = try c.decodeIfPresent(Double.self, forKey: .aiDenoise)      ?? base.aiDenoise
        aiDenoiseDetail = try c.decodeIfPresent(Double.self, forKey: .aiDenoiseDetail) ?? base.aiDenoiseDetail
        superResolution = try c.decodeIfPresent(Bool.self, forKey: .superResolution) ?? base.superResolution
        grain          = try c.decodeIfPresent(Double.self, forKey: .grain)          ?? base.grain
        grainSize      = try c.decodeIfPresent(Double.self, forKey: .grainSize)      ?? base.grainSize
        grainRoughness = try c.decodeIfPresent(Double.self, forKey: .grainRoughness) ?? base.grainRoughness
        retouchSpots   = try c.decodeIfPresent([RetouchSpot].self, forKey: .retouchSpots) ?? base.retouchSpots
        vignette       = try c.decodeIfPresent(Double.self, forKey: .vignette)       ?? base.vignette
        vignetteStart  = try c.decodeIfPresent(Double.self, forKey: .vignetteStart)  ?? base.vignetteStart
        halation       = try c.decodeIfPresent(Double.self, forKey: .halation)       ?? base.halation
        halationThreshold = try c.decodeIfPresent(Double.self, forKey: .halationThreshold) ?? base.halationThreshold
        halationRadius = try c.decodeIfPresent(Double.self, forKey: .halationRadius) ?? base.halationRadius
        bokehAmount    = try c.decodeIfPresent(Double.self, forKey: .bokehAmount)    ?? base.bokehAmount
        bokehFocusDepth = try c.decodeIfPresent(Double.self, forKey: .bokehFocusDepth) ?? base.bokehFocusDepth
        bokehFocusRange = try c.decodeIfPresent(Double.self, forKey: .bokehFocusRange) ?? base.bokehFocusRange
        bokehBlades    = try c.decodeIfPresent(Int.self, forKey: .bokehBlades)       ?? base.bokehBlades
        bokehHighlightBoost = try c.decodeIfPresent(Double.self, forKey: .bokehHighlightBoost) ?? base.bokehHighlightBoost
        bokehCatEye    = try c.decodeIfPresent(Double.self, forKey: .bokehCatEye)    ?? base.bokehCatEye
        bokehAutoDepth = try c.decodeIfPresent(Bool.self, forKey: .bokehAutoDepth)   ?? base.bokehAutoDepth
        lensCorrection = try c.decodeIfPresent(LensCorrection.self, forKey: .lensCorrection)
        if lensCorrection?.valid == false { lensCorrection = nil }
        rawEmbeddedLensCorrection = try c.decodeIfPresent(Bool.self, forKey: .rawEmbeddedLensCorrection) ?? base.rawEmbeddedLensCorrection
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
    var tiffBitDepth: Int = 16
    var colorSpace: ExportColorSpace = .sRGB
    var preserveMetadata: Bool = true
    var stripGPS: Bool = false
    var copyrightText: String = ""
    var exportHDR: Bool = false

    // MARK: 水印（只在出图时叠加，不进预览、不进副档）
    var watermarkEnabled: Bool = false
    var watermarkKind: String = "text"        // text / image
    var watermarkText: String = "Phos"
    var watermarkDarkText: Bool = false       // false=白字，true=黑字（浅色画面用）
    var watermarkImagePath: String = ""       // 图片水印的本地路径（png 带透明最好）
    var watermarkPosition: String = "bottomRight"  // 九宫格：topLeft…bottomRight
    var watermarkScale: Double = 0.05         // 占输出长边比例：文字=字号，图片=宽度
    var watermarkOpacity: Double = 0.55
    var watermarkRotation: Double = 0         // 度，绕水印中心
    var watermarkMargin: Double = 0.03        // 距边缘留白，占短边比例

    init() {}

    enum CodingKeys: String, CodingKey {
        case format, quality, maxLongEdge, sharpenForOutput, tiffBitDepth, colorSpace
        case preserveMetadata, stripGPS, copyrightText, exportHDR
        case watermarkEnabled, watermarkKind, watermarkText, watermarkDarkText
        case watermarkImagePath, watermarkPosition, watermarkScale
        case watermarkOpacity, watermarkRotation, watermarkMargin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        format            = try c.decodeIfPresent(String.self, forKey: .format) ?? d.format
        quality           = try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality
        maxLongEdge       = try c.decodeIfPresent(Int.self, forKey: .maxLongEdge) ?? d.maxLongEdge
        sharpenForOutput  = try c.decodeIfPresent(Bool.self, forKey: .sharpenForOutput) ?? d.sharpenForOutput
        tiffBitDepth      = try c.decodeIfPresent(Int.self, forKey: .tiffBitDepth) ?? d.tiffBitDepth
        colorSpace        = try c.decodeIfPresent(ExportColorSpace.self, forKey: .colorSpace) ?? d.colorSpace
        preserveMetadata  = try c.decodeIfPresent(Bool.self, forKey: .preserveMetadata) ?? d.preserveMetadata
        stripGPS          = try c.decodeIfPresent(Bool.self, forKey: .stripGPS) ?? d.stripGPS
        copyrightText     = try c.decodeIfPresent(String.self, forKey: .copyrightText) ?? d.copyrightText
        exportHDR         = try c.decodeIfPresent(Bool.self, forKey: .exportHDR) ?? d.exportHDR
        watermarkEnabled  = try c.decodeIfPresent(Bool.self, forKey: .watermarkEnabled) ?? d.watermarkEnabled
        watermarkKind     = try c.decodeIfPresent(String.self, forKey: .watermarkKind) ?? d.watermarkKind
        watermarkText     = try c.decodeIfPresent(String.self, forKey: .watermarkText) ?? d.watermarkText
        watermarkDarkText = try c.decodeIfPresent(Bool.self, forKey: .watermarkDarkText) ?? d.watermarkDarkText
        watermarkImagePath = try c.decodeIfPresent(String.self, forKey: .watermarkImagePath) ?? d.watermarkImagePath
        watermarkPosition = try c.decodeIfPresent(String.self, forKey: .watermarkPosition) ?? d.watermarkPosition
        watermarkScale    = try c.decodeIfPresent(Double.self, forKey: .watermarkScale) ?? d.watermarkScale
        watermarkOpacity  = try c.decodeIfPresent(Double.self, forKey: .watermarkOpacity) ?? d.watermarkOpacity
        watermarkRotation = try c.decodeIfPresent(Double.self, forKey: .watermarkRotation) ?? d.watermarkRotation
        watermarkMargin   = try c.decodeIfPresent(Double.self, forKey: .watermarkMargin) ?? d.watermarkMargin
    }

    /// 九宫格锚点（左上 → 右下），给 UI 用
    static let wmPositions: [String] = [
        "topLeft", "topCenter", "topRight",
        "midLeft", "center", "midRight",
        "bottomLeft", "bottomCenter", "bottomRight"
    ]
}

// MARK: - 导出目录
/// 导出 / 批量导出的默认落盘目录。
/// 本机偏好写在 UserDefaults（`defaults write com.zeno.phos exportDirectory <路径>`），
/// 源码不含任何个人路径 —— 发到 GitHub 上就是通用逻辑，无需删改：
/// 未配置时退回桌面。目录不存在会自动创建。
enum ExportPaths {
    static let key = "exportDirectory"
    private static let legacySuite = "com.zeno.rawforge"

    static var configured: String {
        #if PHOS_QA
        return QAWorkspace.exports.path
        #else
        if let current = UserDefaults.standard.string(forKey: key), !current.isEmpty {
            return current
        }
        return UserDefaults(suiteName: legacySuite)?.string(forKey: key) ?? ""
        #endif
    }

    static var defaultDir: URL {
        let fm = FileManager.default
        let base: URL
        let s = configured
        if !s.isEmpty {
            base = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        } else {
            base = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

// MARK: - 多重曝光合成模式
enum MergeMode: String, Codable, CaseIterable {
    case average, fusion, denoise
    var label: String {
        switch self {
        case .average: return "平均合成"
        case .fusion:  return "曝光融合"
        case .denoise: return "手持降噪"
        }
    }
    var hint: String {
        switch self {
        case .average: return "所有帧等权叠加：适合降噪、流水/星轨，张数越多越干净"
        case .fusion:  return "按每像素的曝光合适度加权：每张取它曝光最好的部分，适合大光比的包围曝光"
        case .denoise: return "对齐后逐像素平均：偏离参考帧 kσ 的像素按参考值取，压手持噪点与移动物体鬼影（自动开启帧对齐）"
        }
    }
}

// MARK: - 虚拟副本
struct VirtualCopy: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "副本 1"
    var created: Date = Date()
    var params: EditParams = EditParams()
    var rating: Int = 0
    var picked: Bool = false
    var colorLabel: ColorLabel = .none
    var rejected: Bool = false
    var snapshots: [EditSnapshot] = []

    init(id: UUID = UUID(), name: String = "副本 1", created: Date = Date(),
         params: EditParams = EditParams(), rating: Int = 0, picked: Bool = false,
         colorLabel: ColorLabel = .none, rejected: Bool = false, snapshots: [EditSnapshot] = []) {
        self.id = id; self.name = name; self.created = created; self.params = params
        self.rating = rating; self.picked = picked; self.colorLabel = colorLabel
        self.rejected = rejected; self.snapshots = snapshots
    }
    enum CodingKeys: String, CodingKey {
        case id, name, created, params, rating, picked, colorLabel, rejected, snapshots
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "副本"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        params = try c.decodeIfPresent(EditParams.self, forKey: .params) ?? EditParams()
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        picked = try c.decodeIfPresent(Bool.self, forKey: .picked) ?? false
        colorLabel = try c.decodeIfPresent(ColorLabel.self, forKey: .colorLabel) ?? .none
        rejected = try c.decodeIfPresent(Bool.self, forKey: .rejected) ?? false
        snapshots = try c.decodeIfPresent([EditSnapshot].self, forKey: .snapshots) ?? []
    }
}

// MARK: - 副档存档（非破坏编辑）
struct Sidecar: Codable {
    var version: Int = 2
    var app: String = "Phos"
    var params: EditParams
    var rating: Int = 0
    var picked: Bool = false
    var colorLabel: ColorLabel = .none
    var rejected: Bool = false
    var keywords: [String] = []
    var snapshots: [EditSnapshot] = []
    var virtualCopies: [VirtualCopy] = []

    init(params: EditParams, rating: Int = 0, picked: Bool = false, snapshots: [EditSnapshot] = [],
         colorLabel: ColorLabel = .none, rejected: Bool = false, keywords: [String] = [],
         virtualCopies: [VirtualCopy] = []) {
        self.params = params; self.rating = rating; self.picked = picked; self.snapshots = snapshots
        self.colorLabel = colorLabel; self.rejected = rejected; self.keywords = keywords
        self.virtualCopies = virtualCopies
    }
    enum CodingKeys: String, CodingKey {
        case version, app, params, rating, picked, colorLabel, rejected, keywords, snapshots, virtualCopies
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? "Phos"
        params = try c.decode(EditParams.self, forKey: .params)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        picked = try c.decodeIfPresent(Bool.self, forKey: .picked) ?? false
        colorLabel = try c.decodeIfPresent(ColorLabel.self, forKey: .colorLabel) ?? .none
        rejected = try c.decodeIfPresent(Bool.self, forKey: .rejected) ?? false
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        snapshots = try c.decodeIfPresent([EditSnapshot].self, forKey: .snapshots) ?? []
        virtualCopies = try c.decodeIfPresent([VirtualCopy].self, forKey: .virtualCopies) ?? []
    }
}

enum SidecarStore {
    static func url(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("rawforge.json")
    }
    static func existingURL(for imageURL: URL) -> URL {
        let modern = url(for: imageURL)
        if FileManager.default.fileExists(atPath: modern.path) { return modern }
        return imageURL.deletingPathExtension().appendingPathExtension("rawforge.json")
    }
    static func read(for imageURL: URL) throws -> Sidecar? {
        let path = existingURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: path))
    }
    static func load(for url: URL) -> Sidecar? { try? read(for: url) }

    static func write(_ s: Sidecar, for imageURL: URL) throws {
        #if PHOS_QA
        try QAWorkspace.scope.requireWritableImage(imageURL)
        #endif
        // Never silently overwrite a damaged edit file.
        _ = try read(for: imageURL)
        let dest = url(for: imageURL)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: dest, options: .atomic)
    }
    @discardableResult
    static func save(_ s: Sidecar, for url: URL) -> Bool {
        do { try write(s, for: url); return true } catch { return false }
    }
}

// MARK: - 历史栈
final class History: ObservableObject {
    @Published var stack: [EditParams] = []
    @Published var index: Int = -1

    func push(_ p: EditParams) {
        if stack.indices.contains(index), stack[index] == p { return }
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
