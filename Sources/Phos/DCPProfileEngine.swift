import Foundation
import CoreImage
import CoreGraphics
import simd

/// Adobe DNG Camera Profile（.dcp）原生纯 Swift 二进制解析器与色彩查找管线（零第三方库、零 App 体积膨胀）。
/// 完整解析 TIFF/DNG IFD 标签：
/// - `ColorMatrix1/2` (50721/50722) & `CalibrationIlluminant1/2` (50778/50779)
/// - `ForwardMatrix1/2` (50964/50965)
/// - `ProfileName` (50936) & `UniqueCameraModelRestriction` (50931)
/// - `ProfileHueSatMapDims` (50937) + `ProfileHueSatMapData1/2` (50938/50939)
/// - `ProfileLookTableDims` (50981) + `ProfileLookTableData` (50982)
/// - `ProfileToneCurve` (50940)
struct DCPProfile: Equatable, Identifiable {
    struct CurvePoint: Equatable {
        let x: Double
        let y: Double
    }
    let id: String              // 文件名或内置标识
    let name: String            // 展示名称
    let cameraRestriction: String
    let isBuiltin: Bool
    let illuminant1: Int        // EXIF LightSource (17=StdA 2856K, 21=D65 6504K, 23=D50 5003K)
    let illuminant2: Int
    let colorMatrix1: [Double]  // 9 个值 (XYZ->Camera)
    let colorMatrix2: [Double]
    let forwardMatrix1: [Double] // 9 个值 (Camera->XYZ D50)
    let forwardMatrix2: [Double]
    let hueSatDims: [Int]       // [hueDivs, satDivs, valDivs]
    let hueSatData1: [Float]    // count * 3 (dHue deg, satScale, valScale)
    let hueSatData2: [Float]
    let lookTableDims: [Int]    // [hueDivs, satDivs, valDivs]
    let lookTableData: [Float]
    let toneCurve: [CurvePoint] // (x, y) 控制点对

    var hasCameraMatrix: Bool {
        forwardMatrix1.count == 9 || colorMatrix1.count == 9
    }

    var hasColorLook: Bool {
        !hueSatData1.isEmpty || !lookTableData.isEmpty || toneCurve.count >= 2 || hasCameraMatrix
    }
}

enum DCPProfileEngine {

    static let flatBuiltinID = "__flat__"
    static let vividBuiltinID = "__vivid__"
    static let portraitBuiltinID = "__portrait__"

    static var profilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos/CameraProfiles", isDirectory: true)
    }

    private static let lock = NSLock()
    private static var parsedCache: [String: DCPProfile] = [:]
    private static let cubeCache = BoundedCache<String, Data>(capacity: 24)
    private static let cubeDim = 33

    struct ProfileChoice: Identifiable, Equatable {
        let id: String
        let name: String
        let subtitle: String
        let isDCP: Bool
    }

    /// 列出所有可用配置文件：内置轻量配置文件 + 用户导入的 `.dcp` 文件
    static func availableProfiles() -> [ProfileChoice] {
        var list: [ProfileChoice] = [
            ProfileChoice(id: "", name: "默认（标准）", subtitle: "原始解码输出", isDCP: false),
            ProfileChoice(id: flatBuiltinID, name: "中性线性（Flat）", subtitle: "压平反差保留最大动态范围", isDCP: false),
            ProfileChoice(id: vividBuiltinID, name: "鲜艳风光（Vivid）", subtitle: "加深蓝天绿叶与微反差", isDCP: false),
            ProfileChoice(id: portraitBuiltinID, name: "人像柔和（Portrait）", subtitle: "柔化肤色红黄过渡与高光滚降", isDCP: false)
        ]
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: nil) {
            let dcps = files.filter { $0.pathExtension.lowercased() == "dcp" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for url in dcps {
                let id = url.lastPathComponent
                if let p = loadProfile(id: id) {
                    let sub = p.cameraRestriction.isEmpty ? "Adobe DCP" : p.cameraRestriction
                    list.append(ProfileChoice(id: id, name: p.name, subtitle: sub, isDCP: true))
                }
            }
        }
        return list
    }

    /// 导入外部 `.dcp` 文件并安全校验，落盘至 `~/Library/Application Support/Phos/CameraProfiles/`
    @discardableResult
    static func importDCP(from sourceURL: URL) throws -> DCPProfile {
        let data = try Data(contentsOf: sourceURL)
        guard data.count <= 32 * 1024 * 1024 else {
            throw NSError(domain: "Phos", code: 401, userInfo: [NSLocalizedDescriptionKey: "DCP 文件超过 32 MB 限制"])
        }
        let parsed = try parseDCP(data: data, id: sourceURL.lastPathComponent)
        let fm = FileManager.default
        try fm.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let dest = profilesDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try data.write(to: dest, options: .atomic)
        lock.lock()
        parsedCache[dest.lastPathComponent] = parsed
        lock.unlock()
        return parsed
    }

    static func loadProfile(id: String) -> DCPProfile? {
        guard !id.isEmpty,
              id != flatBuiltinID, id != vividBuiltinID, id != portraitBuiltinID else { return nil }
        lock.lock()
        if let hit = parsedCache[id] { lock.unlock(); return hit }
        lock.unlock()
        let url = profilesDirectory.appendingPathComponent(id)
        guard let data = try? Data(contentsOf: url),
              let parsed = try? parseDCP(data: data, id: id) else { return nil }
        lock.lock()
        parsedCache[id] = parsed
        lock.unlock()
        return parsed
    }

    /// 供 `Engine.render` 在白平衡之后、主曝光与色彩分级之前应用相机配置文件。
    static func apply(
        _ img: CIImage,
        profileID: String,
        amount: Double = 1.0,
        temperatureKelvin: Double = 5500,
        inputIsCameraRGB: Bool = false
    ) -> CIImage {
        guard !profileID.isEmpty, amount > 0.001 else { return img }
        let clampedAmount = min(max(amount, 0.0), 2.0)

        let tempBucket = Int((temperatureKelvin / 250.0).rounded()) * 250
        let amtKey = Int((clampedAmount * 100).rounded())
        let cacheKey = "\(profileID)|\(amtKey)|\(tempBucket)|\(inputIsCameraRGB ? 1 : 0)"

        let cubeData: Data
        if let hit = cubeCache[cacheKey] {
            cubeData = hit
        } else {
            let built: Data?
            switch profileID {
            case flatBuiltinID:
                built = buildBuiltinCube(kind: .flat, amount: clampedAmount)
            case vividBuiltinID:
                built = buildBuiltinCube(kind: .vivid, amount: clampedAmount)
            case portraitBuiltinID:
                built = buildBuiltinCube(kind: .portrait, amount: clampedAmount)
            default:
                if let dcp = loadProfile(id: profileID) {
                    built = buildDCPCube(dcp: dcp, amount: clampedAmount,
                                         kelvin: Double(tempBucket),
                                         inputIsCameraRGB: inputIsCameraRGB)
                } else {
                    built = nil
                }
            }
            guard let built else { return img }
            cubeData = built
            cubeCache[cacheKey] = cubeData
        }

        guard let f = CIFilter(name: "CIColorCube") else { return img }
        f.setValue(cubeDim, forKey: "inputCubeDimension")
        f.setValue(cubeData, forKey: "inputCubeData")
        f.setValue(img, forKey: kCIInputImageKey)
        return (f.outputImage ?? img).cropped(to: img.extent)
    }

    // MARK: - Adobe DCP 二进制（TIFF IFD）解析器

    static func parseDCP(data: Data, id: String) throws -> DCPProfile {
        guard data.count >= 16 else {
            throw NSError(domain: "Phos", code: 402, userInfo: [NSLocalizedDescriptionKey: "无效的 DCP 文件头"])
        }
        let b0 = data[0], b1 = data[1]
        let littleEndian: Bool
        if b0 == 0x49 && b1 == 0x49 { littleEndian = true }       // "II"
        else if b0 == 0x4D && b1 == 0x4D { littleEndian = false } // "MM"
        else {
            throw NSError(domain: "Phos", code: 403, userInfo: [NSLocalizedDescriptionKey: "DCP 字节序标识无效"])
        }

        func u16(_ off: Int) -> UInt16 {
            guard off >= 0, off + 2 <= data.count else { return 0 }
            let a = UInt16(data[off]), b = UInt16(data[off + 1])
            return littleEndian ? (a | (b << 8)) : ((a << 8) | b)
        }
        func u32(_ off: Int) -> UInt32 {
            guard off >= 0, off + 4 <= data.count else { return 0 }
            let a = UInt32(data[off]), b = UInt32(data[off + 1]), c = UInt32(data[off + 2]), d = UInt32(data[off + 3])
            return littleEndian ? (a | (b << 8) | (c << 16) | (d << 24)) : ((a << 24) | (b << 16) | (c << 8) | d)
        }
        func i32(_ off: Int) -> Int32 { Int32(bitPattern: u32(off)) }
        func f32(_ off: Int) -> Float { Float(bitPattern: u32(off)) }

        let magic = u16(2)
        // Adobe DCP 规定 magic = 0x4352 ("CR")，部分工具写标准 TIFF 42
        guard magic == 0x4352 || magic == 42 else {
            throw NSError(domain: "Phos", code: 404, userInfo: [NSLocalizedDescriptionKey: "不是标准的 Adobe DCP 配置文件"])
        }

        let ifdOffset = Int(u32(4))
        guard ifdOffset >= 8, ifdOffset + 2 <= data.count else {
            throw NSError(domain: "Phos", code: 405, userInfo: [NSLocalizedDescriptionKey: "DCP IFD 偏移越界"])
        }

        let entryCount = Int(u16(ifdOffset))
        var profileName = (id as NSString).deletingPathExtension
        var cameraRestriction = ""
        var illum1 = 17, illum2 = 21
        var cm1: [Double] = [], cm2: [Double] = []
        var fm1: [Double] = [], fm2: [Double] = []
        var hsDims: [Int] = [], hsData1: [Float] = [], hsData2: [Float] = []
        var lookDims: [Int] = [], lookData: [Float] = []
        var toneCurve: [DCPProfile.CurvePoint] = []

        func typeSize(_ t: UInt16) -> Int {
            switch t {
            case 1, 2, 6, 7: return 1
            case 3, 8:       return 2
            case 4, 9, 11:   return 4
            case 5, 10, 12:  return 8
            default:         return 1
            }
        }

        func readSRationalArray(off: Int, count: Int) -> [Double] {
            guard count <= 1024, off + count * 8 <= data.count else { return [] }
            var out: [Double] = []
            out.reserveCapacity(count)
            for k in 0..<count {
                let num = Double(i32(off + k * 8))
                let den = Double(i32(off + k * 8 + 4))
                out.append(abs(den) > 1e-12 ? (num / den) : 0)
            }
            return out
        }

        func readFloatArray(off: Int, count: Int) -> [Float] {
            guard count <= 4_000_000, off + count * 4 <= data.count else { return [] }
            var out: [Float] = []
            out.reserveCapacity(count)
            for k in 0..<count { out.append(f32(off + k * 4)) }
            return out
        }

        func readUInt32Array(off: Int, count: Int) -> [Int] {
            guard count <= 64, off + count * 4 <= data.count else { return [] }
            return (0..<count).map { Int(u32(off + $0 * 4)) }
        }

        func readASCII(off: Int, count: Int) -> String {
            guard count > 0, count <= 1024, off + count <= data.count else { return "" }
            let slice = data[off..<(off + count)]
            let cleaned = slice.prefix { $0 != 0 }
            return String(decoding: cleaned, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for i in 0..<min(entryCount, 256) {
            let eOff = ifdOffset + 2 + i * 12
            guard eOff + 12 <= data.count else { break }
            let tag = u16(eOff)
            let typ = u16(eOff + 2)
            let cnt = Int(u32(eOff + 4))
            let totalBytes = cnt * typeSize(typ)
            let valOff = totalBytes <= 4 ? (eOff + 8) : Int(u32(eOff + 8))
            guard valOff >= 0, valOff + min(totalBytes, 4) <= data.count else { continue }

            switch tag {
            case 50721: cm1 = readSRationalArray(off: valOff, count: cnt)
            case 50722: cm2 = readSRationalArray(off: valOff, count: cnt)
            case 50778: illum1 = Int(typ == 3 ? u16(valOff) : UInt16(min(u32(valOff), 65535)))
            case 50779: illum2 = Int(typ == 3 ? u16(valOff) : UInt16(min(u32(valOff), 65535)))
            case 50931: cameraRestriction = readASCII(off: valOff, count: cnt)
            case 50936:
                let s = readASCII(off: valOff, count: cnt)
                if !s.isEmpty { profileName = s }
            case 50937: hsDims = readUInt32Array(off: valOff, count: cnt)
            case 50938: hsData1 = readFloatArray(off: valOff, count: cnt)
            case 50939: hsData2 = readFloatArray(off: valOff, count: cnt)
            case 50940:
                let raw = readFloatArray(off: valOff, count: cnt)
                var pts: [DCPProfile.CurvePoint] = []
                for k in stride(from: 0, to: raw.count - 1, by: 2) {
                    pts.append(DCPProfile.CurvePoint(x: Double(raw[k]), y: Double(raw[k + 1])))
                }
                toneCurve = pts
            case 50964: fm1 = readSRationalArray(off: valOff, count: cnt)
            case 50965: fm2 = readSRationalArray(off: valOff, count: cnt)
            case 50981: lookDims = readUInt32Array(off: valOff, count: cnt)
            case 50982: lookData = readFloatArray(off: valOff, count: cnt)
            default: break
            }
        }

        let profile = DCPProfile(
            id: id, name: profileName, cameraRestriction: cameraRestriction, isBuiltin: false,
            illuminant1: illum1, illuminant2: illum2,
            colorMatrix1: cm1, colorMatrix2: cm2,
            forwardMatrix1: fm1, forwardMatrix2: fm2,
            hueSatDims: hsDims, hueSatData1: hsData1, hueSatData2: hsData2,
            lookTableDims: lookDims, lookTableData: lookData,
            toneCurve: toneCurve
        )
        guard profile.hasColorLook else {
            throw NSError(domain: "Phos", code: 406, userInfo: [NSLocalizedDescriptionKey: "DCP 文件不包含有效的色彩矩阵、LookTable 或色调曲线"])
        }
        return profile
    }

    // MARK: - 3D LUT 烘焙（Linear Working Space）

    private enum BuiltinKind { case flat, vivid, portrait }

    private static func buildBuiltinCube(kind: BuiltinKind, amount: Double) -> Data {
        let D = cubeDim, last = Double(D - 1)
        let k = min(max(amount, 0), 2)
        var out = [Float](repeating: 0, count: D * D * D * 4)

        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let r0 = Double(ri) / last, g0 = Double(gi) / last, b0 = Double(bi) / last
                    var (h, s, v) = rgbToHSV(toPerc(r0), toPerc(g0), toPerc(b0))
                    switch kind {
                    case .flat:
                        // 温和压缩高光、抬升暗部并略降过饱和，便于后期二次调色
                        v = 0.04 + 0.90 * pow(v, 0.90)
                        s *= 0.88
                    case .vivid:
                        // 微 S 曲线 + 天空蓝/植被绿加饱和压明度
                        let sCurve = v < 0.5 ? 0.5 * pow(2 * v, 1.14) : 1.0 - 0.5 * pow(2 * (1 - v), 1.14)
                        v = sCurve
                        let blueW = hueWeight(h, center: 215, width: 45)
                        let greenW = hueWeight(h, center: 120, width: 45)
                        s = min(1.0, s * (1.12 + 0.14 * blueW + 0.10 * greenW))
                        v = min(max(v - 0.04 * blueW * s, 0), 1)
                    case .portrait:
                        // 保护并柔化肤色（橙红区 15°-45°），降低生硬红黄饱和并柔和高光滚降
                        let skinW = hueWeight(h, center: 26, width: 28)
                        h = (h + 2.5 * skinW).truncatingRemainder(dividingBy: 360)
                        s *= (0.95 - 0.10 * skinW)
                        v = v > 0.72 ? 0.72 + (v - 0.72) * 0.92 : v * 1.03
                        v = min(max(v, 0), 1)
                    }
                    let (pr, pg, pb) = hsvToRGB(h, min(max(s, 0), 1), min(max(v, 0), 1))
                    let rl = toLin(pr), gl = toLin(pg), bl = toLin(pb)
                    let r = max(0, r0 + (rl - r0) * k)
                    let g = max(0, g0 + (gl - g0) * k)
                    let b = max(0, b0 + (bl - b0) * k)
                    let o = (bi * D * D + gi * D + ri) * 4
                    out[o] = Float(r); out[o + 1] = Float(g); out[o + 2] = Float(b); out[o + 3] = 1
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }

    private static func buildDCPCube(dcp: DCPProfile, amount: Double, kelvin: Double, inputIsCameraRGB: Bool) -> Data {
        let D = cubeDim, last = Double(D - 1)
        let k = min(max(amount, 0), 2)
        // 计算双光源插值权重 t ∈ [0, 1]（0 = Illuminant1，1 = Illuminant2）
        let t1 = illuminantKelvin(dcp.illuminant1)
        let t2 = illuminantKelvin(dcp.illuminant2)
        let invT = 1.0 / max(kelvin, 1500)
        let inv1 = 1.0 / t1, inv2 = 1.0 / t2
        let interp: Double = abs(inv2 - inv1) > 1e-6
            ? min(max((invT - inv1) / (inv2 - inv1), 0), 1)
            : 0.0

        // 线性相机 RGB -> 线性 sRGB 3×3 转换矩阵（当 inputIsCameraRGB = true 时生效）
        let camToSRGB: simd_double3x3? = inputIsCameraRGB ? buildCameraToLinearSRGB(dcp: dcp, t: interp) : nil

        // 预烘焙 1D ProfileToneCurve LUT（256 项，感知域）
        let curveLUT: [Double]? = dcp.toneCurve.count >= 2 ? buildToneCurveLUT(dcp.toneCurve, size: 256) : nil

        // 合并双光源 HueSatMap（若提供 2 张表则按色温权重插值）
        let hasHS = dcp.hueSatDims.count == 3 && !dcp.hueSatData1.isEmpty
        var mergedHS: [Float] = []
        if hasHS {
            if dcp.hueSatData2.count == dcp.hueSatData1.count && interp > 1e-4 {
                let w2 = Float(interp), w1 = 1 - w2
                mergedHS = zip(dcp.hueSatData1, dcp.hueSatData2).map { $0 * w1 + $1 * w2 }
            } else {
                mergedHS = dcp.hueSatData1
            }
        }
        let hasLook = dcp.lookTableDims.count == 3 && !dcp.lookTableData.isEmpty

        var out = [Float](repeating: 0, count: D * D * D * 4)
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let r0 = Double(ri) / last, g0 = Double(gi) / last, b0 = Double(bi) / last
                    var r = r0, g = g0, b = b0

                    // 1) Camera RGB -> Linear sRGB（仅 LibRaw 原始相机空间模式）
                    if let m = camToSRGB {
                        let v = m * SIMD3<Double>(r, g, b)
                        r = min(max(v.x, 0), 1)
                        g = min(max(v.y, 0), 1)
                        b = min(max(v.z, 0), 1)
                    }

                    // 2) HueSatMap（DNG 标准在线性 ProPhoto/sRGB HSV 上应用色相偏移与饱和/明度倍率）
                    if hasHS {
                        var (h, s, v) = rgbToHSV(r, g, b)
                        let (dh, sm, vm) = sampleHSVMap(h: h, s: s, v: v, dims: dcp.hueSatDims, table: mergedHS)
                        h = ((h + dh).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                        s = min(max(s * sm, 0), 1)
                        v = min(max(v * vm, 0), 1)
                        (r, g, b) = hsvToRGB(h, s, v)
                    }

                    // 3) LookTable（风格查找表：Adobe Color / Portrait / Fuji 胶片风格核心）
                    if hasLook {
                        var (h, s, v) = rgbToHSV(r, g, b)
                        let (dh, sm, vm) = sampleHSVMap(h: h, s: s, v: v, dims: dcp.lookTableDims, table: dcp.lookTableData)
                        h = ((h + dh).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                        s = min(max(s * sm, 0), 1)
                        v = min(max(v * vm, 0), 1)
                        (r, g, b) = hsvToRGB(h, s, v)
                    }

                    // 4) ProfileToneCurve（在感知域逐通道查找并映射回线性）
                    if let lut = curveLUT {
                        let pr = sampleLUT(lut, toPerc(r))
                        let pg = sampleLUT(lut, toPerc(g))
                        let pb = sampleLUT(lut, toPerc(b))
                        r = toLin(pr); g = toLin(pg); b = toLin(pb)
                    }

                    // 按 amount（0...2）混合
                    let rf = inputIsCameraRGB ? r : max(0, r0 + (r - r0) * k)
                    let gf = inputIsCameraRGB ? g : max(0, g0 + (g - g0) * k)
                    let bf = inputIsCameraRGB ? b : max(0, b0 + (b - b0) * k)
                    let o = (bi * D * D + gi * D + ri) * 4
                    out[o] = Float(rf); out[o + 1] = Float(gf); out[o + 2] = Float(bf); out[o + 3] = 1
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }

    private static func buildCameraToLinearSRGB(dcp: DCPProfile, t: Double) -> simd_double3x3? {
        // XYZ D50 -> Linear sRGB D65（Bradford 色度适应矩阵）
        let xyzD50ToSRGB = simd_double3x3(rows: [
            SIMD3( 3.1338561, -1.6168667, -0.4906146),
            SIMD3(-0.9787684,  1.9161415,  0.0334540),
            SIMD3( 0.0719453, -0.2289914,  1.4052427)
        ])

        func mat3(_ a: [Double]) -> simd_double3x3 {
            simd_double3x3(rows: [
                SIMD3(a[0], a[1], a[2]),
                SIMD3(a[3], a[4], a[5]),
                SIMD3(a[6], a[7], a[8])
            ])
        }
        func lerpMat(_ m1: [Double], _ m2: [Double]) -> simd_double3x3 {
            if m2.count == 9 {
                let blended = zip(m1, m2).map { $0 * (1 - t) + $1 * t }
                return mat3(blended)
            }
            return mat3(m1)
        }

        if dcp.forwardMatrix1.count == 9 {
            let fm = lerpMat(dcp.forwardMatrix1, dcp.forwardMatrix2)
            return normalizeRowsForWhite(xyzD50ToSRGB * fm)
        }
        if dcp.colorMatrix1.count == 9 {
            let cm = lerpMat(dcp.colorMatrix1, dcp.colorMatrix2)
            guard abs(cm.determinant) > 1e-8 else { return nil }
            let camToXYZ = cm.inverse
            return normalizeRowsForWhite(xyzD50ToSRGB * camToXYZ)
        }
        return nil
    }

    /// 保持中性白点 [1,1,1] 映射仍为 [1,1,1]
    private static func normalizeRowsForWhite(_ m: simd_double3x3) -> simd_double3x3 {
        let w = m * SIMD3<Double>(1, 1, 1)
        let s = simd_double3x3(diagonal: SIMD3(
            abs(w.x) > 1e-5 ? 1.0 / w.x : 1.0,
            abs(w.y) > 1e-5 ? 1.0 / w.y : 1.0,
            abs(w.z) > 1e-5 ? 1.0 / w.z : 1.0
        ))
        return s * m
    }

    /// DNG 规范三维 HSV 表三线性插值（维度排列：Val -> Hue -> Sat，每格 3 个 Float：dHue, satScale, valScale）
    private static func sampleHSVMap(h: Double, s: Double, v: Double, dims: [Int], table: [Float]) -> (Double, Double, Double) {
        let hDivs = dims[0], sDivs = dims[1], vDivs = dims[2]
        guard hDivs >= 2, sDivs >= 2, vDivs >= 1,
              table.count >= hDivs * sDivs * vDivs * 3 else { return (0, 1, 1) }

        let hPos = (h / 360.0) * Double(hDivs)
        let h0 = ((Int(floor(hPos)) % hDivs) + hDivs) % hDivs
        let h1 = (h0 + 1) % hDivs
        let fh = hPos - floor(hPos)

        let sPos = min(max(s, 0), 1) * Double(sDivs - 1)
        let s0 = min(Int(floor(sPos)), sDivs - 1)
        let s1 = min(s0 + 1, sDivs - 1)
        let fs = sPos - Double(s0)

        let vPos = vDivs > 1 ? min(max(v, 0), 1) * Double(vDivs - 1) : 0.0
        let v0 = min(Int(floor(vPos)), vDivs - 1)
        let v1 = min(v0 + 1, vDivs - 1)
        let fv = vPos - Double(v0)

        func entry(_ vi: Int, _ hi: Int, _ si: Int) -> SIMD3<Double> {
            let idx = ((vi * hDivs + hi) * sDivs + si) * 3
            return SIMD3(Double(table[idx]), Double(table[idx + 1]), Double(table[idx + 2]))
        }
        func lerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }

        let c000 = entry(v0, h0, s0), c001 = entry(v0, h0, s1)
        let c010 = entry(v0, h1, s0), c011 = entry(v0, h1, s1)
        let c100 = entry(v1, h0, s0), c101 = entry(v1, h0, s1)
        let c110 = entry(v1, h1, s0), c111 = entry(v1, h1, s1)

        let c00 = lerp(c000, c001, fs), c01 = lerp(c010, c011, fs)
        let c10 = lerp(c100, c101, fs), c11 = lerp(c110, c111, fs)
        let c0 = lerp(c00, c01, fh),    c1 = lerp(c10, c11, fh)
        let res = lerp(c0, c1, fv)
        return (res.x, res.y, res.z)
    }

    private static func buildToneCurveLUT(_ pts: [DCPProfile.CurvePoint], size: Int) -> [Double] {
        let sorted = pts.sorted { $0.x < $1.x }
        var lut = [Double](repeating: 0, count: size)
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            if x <= sorted.first!.x { lut[i] = sorted.first!.y; continue }
            if x >= sorted.last!.x  { lut[i] = sorted.last!.y; continue }
            var hi = 1
            while hi < sorted.count && sorted[hi].x < x { hi += 1 }
            let lo = hi - 1
            let dx = max(sorted[hi].x - sorted[lo].x, 1e-6)
            let t = (x - sorted[lo].x) / dx
            lut[i] = min(max(sorted[lo].y + (sorted[hi].y - sorted[lo].y) * t, 0), 1)
        }
        return lut
    }

    private static func sampleLUT(_ lut: [Double], _ x: Double) -> Double {
        let pos = min(max(x, 0), 1) * Double(lut.count - 1)
        let i0 = Int(floor(pos)), i1 = min(i0 + 1, lut.count - 1)
        let f = pos - Double(i0)
        return lut[i0] + (lut[i1] - lut[i0]) * f
    }

    private static func illuminantKelvin(_ code: Int) -> Double {
        switch code {
        case 17: return 2856.0 // Standard Light A
        case 18: return 4874.0 // Standard Light B
        case 19: return 6774.0 // Standard Light C
        case 20: return 5503.0 // D55
        case 21: return 6504.0 // D65
        case 22: return 7504.0 // D75
        case 23: return 5003.0 // D50
        default: return 5500.0
        }
    }

    private static func hueWeight(_ h: Double, center: Double, width: Double) -> Double {
        var d = abs(h - center)
        if d > 180 { d = 360 - d }
        return max(0, 1 - d / width)
    }

    private static func toPerc(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func toLin(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        let s = mx > 1e-6 ? d / mx : 0
        var h = 0.0
        if d > 1e-6 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, s, mx)
    }

    private static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        if s <= 1e-6 { return (v, v, v) }
        let hh = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60.0
        let i = Int(floor(hh)) % 6
        let f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
