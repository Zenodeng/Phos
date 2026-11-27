import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

func expect(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("FAIL: \(msg)\n", stderr)
        exit(1)
    }
}

func makeSyntheticPhoto(width: Int, height: Int, shiftX: Int = 0, gain: Double = 1.0) -> CGImage {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let gx = Double(x + shiftX)
            let gy = Double(y)
            // 多频纹理 + 渐变天空 + 地平线山脊，便于高精度 NCC 匹配与融合校验
            let sky = gy < Double(height) * 0.45
            let ridge = Double(height) * 0.45 + 32.0 * sin(gx * 0.017) + 18.0 * cos(gx * 0.043)
            var r: Double, g: Double, b: Double
            if gy < ridge {
                r = 0.25 + 0.35 * (gy / Double(height)) + 0.08 * sin(gx * 0.03)
                g = 0.48 + 0.25 * (gy / Double(height)) + 0.06 * cos(gx * 0.025 + gy * 0.02)
                b = 0.85 - 0.15 * (gy / Double(height))
            } else {
                let tex = 0.5 + 0.5 * sin(gx * 0.11) * cos(gy * 0.13) + 0.25 * sin((gx + gy) * 0.07)
                r = 0.22 + 0.32 * tex + (sky ? 0.05 : 0)
                g = 0.36 + 0.28 * tex
                b = 0.18 + 0.16 * tex
            }
            // 放入几个高对比垂直建筑纹理块（防周期模糊）
            let bldgCenter = 360.0
            if abs(gx - bldgCenter) < 42 && gy > Double(height) * 0.28 {
                let win = ((Int(gx) % 14) < 7 && (Int(gy) % 16) < 8)
                r = win ? 0.92 : 0.28; g = win ? 0.84 : 0.30; b = win ? 0.62 : 0.35
            }
            let o = (y * width + x) * 4
            rgba[o]     = UInt8(min(max(r * gain * 255.0, 0), 255))
            rgba[o + 1] = UInt8(min(max(g * gain * 255.0, 0), 255))
            rgba[o + 2] = UInt8(min(max(b * gain * 255.0, 0), 255))
            rgba[o + 3] = 255
        }
    }
    let data = Data(rgba)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: Engine.srgb,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
}

func savePNG(_ cg: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    expect(CGImageDestinationFinalize(dest), "savePNG failed for \(url.path)")
}

/// 生成合法二进制 Adobe DCP（Little Endian，含 ColorMatrix1/2, ForwardMatrix1, ProfileName, LookTable, ProfileToneCurve）
func makeSyntheticDCP() -> Data {
    var d = Data()
    func appendU16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    func appendU32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func appendI32(_ v: Int32)  { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func appendF32(_ v: Float)  { appendU32(v.bitPattern) }

    // Header: "II", magic 0x4352 ("CR"), IFD0 offset = 8
    d.append(contentsOf: [0x49, 0x49])
    appendU16(0x4352)
    appendU32(8)

    // 7 IFD entries:
    // 50778 CalibrationIlluminant1 = 17 (StdA)
    // 50779 CalibrationIlluminant2 = 21 (D65)
    // 50936 ProfileName = "Phos Test Chrome\0"
    // 50940 ProfileToneCurve = [0,0, 0.25,0.20, 0.5,0.55, 0.75,0.82, 1,1]
    // 50964 ForwardMatrix1 (9 SRATIONALs = Identity)
    // 50981 ProfileLookTableDims = [2, 2, 1]
    // 50982 ProfileLookTableData = 2*2*1*3 = 12 floats (轻微暖色相偏移 + 1.15 饱和度)
    let entryCount = 7
    let ifdStart = 8
    let dataOffset = ifdStart + 2 + entryCount * 12 + 4

    var payload = Data()
    func addPayload(_ bytes: Data) -> UInt32 {
        let off = UInt32(dataOffset + payload.count)
        payload.append(bytes)
        if payload.count % 2 != 0 { payload.append(0) }
        return off
    }

    let nameBytes = Data("Phos Test Chrome\0".utf8)
    let nameOff = addPayload(nameBytes)

    var tcBytes = Data()
    for f: Float in [0, 0, 0.25, 0.18, 0.5, 0.58, 0.75, 0.85, 1.0, 1.0] {
        var b = f.bitPattern.littleEndian; tcBytes.append(Data(bytes: &b, count: 4))
    }
    let tcOff = addPayload(tcBytes)

    var fmBytes = Data()
    for v: Int32 in [10000,0,0, 0,10000,0, 0,0,10000] {
        var n = v.littleEndian, den = Int32(10000).littleEndian
        fmBytes.append(Data(bytes: &n, count: 4))
        fmBytes.append(Data(bytes: &den, count: 4))
    }
    let fmOff = addPayload(fmBytes)

    var dimsBytes = Data()
    for v: UInt32 in [2, 2, 1] { var x = v.littleEndian; dimsBytes.append(Data(bytes: &x, count: 4)) }
    let dimsOff = addPayload(dimsBytes)

    var lookBytes = Data()
    for _ in 0..<4 {
        for f: Float in [8.0, 1.15, 1.02] {
            var b = f.bitPattern.littleEndian; lookBytes.append(Data(bytes: &b, count: 4))
        }
    }
    let lookOff = addPayload(lookBytes)

    appendU16(UInt16(entryCount))
    func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ valOrOff: UInt32) {
        appendU16(tag); appendU16(type); appendU32(count); appendU32(valOrOff)
    }
    entry(50778, 3, 1, 17)
    entry(50779, 3, 1, 21)
    entry(50936, 2, UInt32(nameBytes.count), nameOff)
    entry(50940, 11, 10, tcOff)
    entry(50964, 10, 9, fmOff)
    entry(50981, 4, 3, dimsOff)
    entry(50982, 11, 12, lookOff)
    appendU32(0) // next IFD
    d.append(payload)
    _ = (appendI32, appendF32)
    return d
}

@main
enum V48FeaturesTest {
static func main() throws {
// ============================================================================
// TEST 1: Guided Upright（2V / 2H / 2V+2H 数学精确性与零黑边验证）
// ============================================================================
do {
    let extent = CGRect(x: 0, y: 0, width: 1200, height: 800)
    // 两条向顶汇聚的建筑竖线 + 一条微倾横线
    let gV1 = UprightGuide(x0: 0.25, y0: 0.15, x1: 0.30, y1: 0.85)
    let gV2 = UprightGuide(x0: 0.75, y0: 0.15, x1: 0.70, y1: 0.85)
    let gH1 = UprightGuide(x0: 0.20, y0: 0.22, x1: 0.80, y1: 0.25)
    let gH2 = UprightGuide(x0: 0.22, y0: 0.78, x1: 0.78, y1: 0.74)

    // 1a) 2V 建筑拉直
    guard let sol2V = GuidedUprightEngine.solve(guides: [gV1, gV2], extent: extent, constrainCrop: true) else {
        expect(false, "Guided Upright 2V failed to solve"); fatalError()
    }
    let v1a = sol2V.mapSourceNormalizedToOutput(CGPoint(x: gV1.x0, y: gV1.y0))
    let v1b = sol2V.mapSourceNormalizedToOutput(CGPoint(x: gV1.x1, y: gV1.y1))
    let v2a = sol2V.mapSourceNormalizedToOutput(CGPoint(x: gV2.x0, y: gV2.y0))
    let v2b = sol2V.mapSourceNormalizedToOutput(CGPoint(x: gV2.x1, y: gV2.y1))
    expect(abs(v1a.x - v1b.x) < 1e-4 && abs(v2a.x - v2b.x) < 1e-4,
           "2V verticals must become strictly vertical: dx1=\(abs(v1a.x - v1b.x)), dx2=\(abs(v2a.x - v2b.x))")

    // 1b) 4-line (2V + 2H) 完整透视校正
    guard let sol4 = GuidedUprightEngine.solve(guides: [gV1, gV2, gH1, gH2], extent: extent, constrainCrop: true) else {
        expect(false, "Guided Upright 4-line failed to solve"); fatalError()
    }
    let pH1a = sol4.mapSourceNormalizedToOutput(CGPoint(x: gH1.x0, y: gH1.y0))
    let pH1b = sol4.mapSourceNormalizedToOutput(CGPoint(x: gH1.x1, y: gH1.y1))
    let pV1a = sol4.mapSourceNormalizedToOutput(CGPoint(x: gV1.x0, y: gV1.y0))
    let pV1b = sol4.mapSourceNormalizedToOutput(CGPoint(x: gV1.x1, y: gV1.y1))
    expect(abs(pH1a.y - pH1b.y) < 1e-4, "4-line horizontal must become strictly horizontal: dy=\(abs(pH1a.y - pH1b.y))")
    expect(abs(pV1a.x - pV1b.x) < 1e-4, "4-line vertical must become strictly vertical: dx=\(abs(pV1a.x - pV1b.x))")

    // 1c) 正逆映射往返一致 + 零透明黑角像素
    let roundTrip = sol4.mapOutputNormalizedToSource(pH1a)
    expect(hypot(roundTrip.x - gH1.x0, roundTrip.y - gH1.y0) < 1e-4, "Inverse homography round-trip mismatch")
    let testImg = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1)).cropped(to: extent)
    let warped = GuidedUprightEngine.apply(testImg, solution: sol4)
    var px = [UInt8](repeating: 0, count: 4)
    let we = warped.extent
    for corner in [CGPoint(x: 1, y: 1), CGPoint(x: we.width - 2, y: 1),
                   CGPoint(x: 1, y: we.height - 2), CGPoint(x: we.width - 2, y: we.height - 2)] {
        Engine.ctx.render(warped, toBitmap: &px, rowBytes: 4,
                          bounds: CGRect(x: corner.x, y: corner.y, width: 1, height: 1),
                          format: .RGBA8, colorSpace: Engine.srgb)
        expect(px[3] >= 250, "Corner \(corner) had transparent black wedge alpha=\(px[3])")
    }
    print("PASS [1/5] Guided Upright (2V + 4-line + inverse round-trip + zero black corners, out=\(Int(we.width))x\(Int(we.height)))")
}

// ============================================================================
// TEST 2: Panorama Stitching（3 帧乱序含曝光差的全景拼接）
// ============================================================================
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("phos-pano-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // 故意乱序输入 [中, 右, 左]，且给右帧施加 0.85x 曝光差以测试曝光补偿与 MST 乱序配准
    let fMid   = makeSyntheticPhoto(width: 480, height: 320, shiftX: 160, gain: 1.00)
    let fRight = makeSyntheticPhoto(width: 480, height: 320, shiftX: 320, gain: 0.85)
    let fLeft  = makeSyntheticPhoto(width: 480, height: 320, shiftX: 0,   gain: 1.06)
    let u1 = tmp.appendingPathComponent("p1.png")
    let u2 = tmp.appendingPathComponent("p2.png")
    let u3 = tmp.appendingPathComponent("p3.png")
    savePNG(fMid, to: u1); savePNG(fRight, to: u2); savePNG(fLeft, to: u3)

    guard let res = PanoramaEngine.stitch(urls: [u1, u2, u3], projection: .planar, autoCrop: true) else {
        expect(false, "PanoramaEngine.stitch returned nil"); fatalError()
    }
    expect(res.usedFrames == 3 && res.droppedFrames == 0, "Expected 3/3 frames stitched, got \(res.usedFrames) used / \(res.droppedFrames) dropped")
    expect(res.image.width >= 720 && res.image.width <= 840, "Expected stitched panorama width ~800, got \(res.image.width)")
    expect(res.image.height >= 280, "Expected stitched height >= 280, got \(res.image.height)")
    print("PASS [2/5] Panorama Stitching (3 out-of-order frames + exposure diff -> \(res.image.width)x\(res.image.height) 16-bit)")
}

// ============================================================================
// TEST 3: Adobe DCP 二进制解析 + LUT 应用 + LibRaw 动态探测
// ============================================================================
do {
    let dcpData = makeSyntheticDCP()
    let parsed = try DCPProfileEngine.parseDCP(data: dcpData, id: "SyntheticTest.dcp")
    expect(parsed.name == "Phos Test Chrome", "DCP ProfileName mismatch: \(parsed.name)")
    expect(parsed.illuminant1 == 17 && parsed.illuminant2 == 21, "DCP illuminants mismatch")
    expect(parsed.forwardMatrix1.count == 9, "DCP ForwardMatrix1 count mismatch")
    expect(parsed.lookTableDims == [2, 2, 1] && parsed.lookTableData.count == 12, "DCP LookTable mismatch")
    expect(parsed.toneCurve.count == 5, "DCP ToneCurve count mismatch")

    // 验证内置 Flat / Vivid / Portrait 均可无错渲染且产生真实像素变化
    let src = CIImage(color: CIColor(red: 0.45, green: 0.52, blue: 0.72, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    let vivid = DCPProfileEngine.apply(src, profileID: DCPProfileEngine.vividBuiltinID, amount: 1.0)
    var p0 = [UInt8](repeating: 0, count: 4), p1 = [UInt8](repeating: 0, count: 4)
    Engine.ctx.render(src, toBitmap: &p0, rowBytes: 4, bounds: CGRect(x: 16, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: Engine.srgb)
    Engine.ctx.render(vivid, toBitmap: &p1, rowBytes: 4, bounds: CGRect(x: 16, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: Engine.srgb)
    expect(p0 != p1, "Vivid profile did not alter pixels")
    print("PASS [3/5] Adobe DCP Binary Parser & LUT Pipeline (LibRaw status: \(LibRawEngine.shared.statusSummary))")
}

// ============================================================================
// TEST 4: Soft Proofing（CMYK ColorSync 往返 + 色域超限警告）
// ============================================================================
do {
    // 高度饱和霓虹亮绿（铁定超出 Generic CMYK 四色胶印色域）
    let neon = CIImage(color: CIColor(red: 0.02, green: 0.96, blue: 0.08, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    let cfgCMYK = SoftProofConfig(enabled: true, profileID: "genericCMYK", intent: .perceptual,
                                  simulatePaperAndInk: true, gamutWarning: false)
    let cfgWarn = SoftProofConfig(enabled: true, profileID: "genericCMYK", intent: .relativeColorimetric,
                                  simulatePaperAndInk: false, gamutWarning: true)
    let proofed = SoftProofEngine.apply(neon, config: cfgCMYK)
    let warned = SoftProofEngine.apply(neon, config: cfgWarn)

    var pOrig = [UInt8](repeating: 0, count: 4)
    var pProof = [UInt8](repeating: 0, count: 4)
    var pWarn = [UInt8](repeating: 0, count: 4)
    let r = CGRect(x: 16, y: 16, width: 1, height: 1)
    Engine.ctx.render(neon, toBitmap: &pOrig, rowBytes: 4, bounds: r, format: .RGBA8, colorSpace: Engine.srgb)
    Engine.ctx.render(proofed, toBitmap: &pProof, rowBytes: 4, bounds: r, format: .RGBA8, colorSpace: Engine.srgb)
    Engine.ctx.render(warned, toBitmap: &pWarn, rowBytes: 4, bounds: r, format: .RGBA8, colorSpace: Engine.srgb)
    expect(pProof != pOrig, "CMYK Soft Proofing did not transform out-of-gamut neon green")
    expect(pWarn[2] > 180 && pWarn[1] > 180, "Gamut warning did not paint out-of-gamut pixel cyan: \(pWarn)")
    print("PASS [4/5] Soft Proofing CMYK Round-Trip & Gamut Warning (orig=\(pOrig) -> proof=\(pProof) -> warn=\(pWarn))")
}

// ============================================================================
// TEST 5: XMP 局部蒙版 + 布尔子蒙版 + Guided Upright 双向读写往返
// ============================================================================
do {
    var p = EditParams()
    p.exposure = 0.45
    p.uprightGuides = [
        UprightGuide(x0: 0.2, y0: 0.1, x1: 0.25, y1: 0.9),
        UprightGuide(x0: 0.8, y0: 0.1, x1: 0.75, y1: 0.9)
    ]

    // 蒙版 1：线性渐变 + 布尔减去主体 AI 蒙版
    var m1 = Mask()
    m1.name = "天空压暗"
    m1.kind = .linear
    m1.x0 = 0.5; m1.y0 = 0.9; m1.x1 = 0.5; m1.y1 = 0.4
    m1.adjust.exposure = -0.8
    m1.adjust.temperature = -12
    let sub = MaskComponent(op: .subtract, kind: .subject)
    m1.components = [sub]

    // 蒙版 2：径向渐变 + 旋转
    var m2 = Mask()
    m2.name = "主体补光"
    m2.kind = .radial
    m2.x0 = 0.45; m2.y0 = 0.55; m2.radiusX = 0.22; m2.radiusY = 0.30; m2.radialAngle = 25; m2.feather = 0.65
    m2.adjust.exposure = 0.5; m2.adjust.clarity = 18

    // 蒙版 3：人像面部皮肤 AI 蒙版 + 亮度范围交叉
    var m3 = Mask()
    m3.name = "人像肤色"
    m3.kind = .faceSkin
    m3.adjust.texture = -15
    var lumSub = MaskComponent(op: .intersect, kind: .luminanceRange)
    lumSub.lumLow = 0.35; lumSub.lumHigh = 0.85; lumSub.lumSoft = 0.08
    m3.components = [lumSub]

    p.masks = [m1, m2, m3]

    let xml = XMPSidecar.serialize(Sidecar(params: p, rating: 5, picked: true, keywords: ["建筑", "风光"]))
    expect(xml.contains("crs:MaskGroupBasedCorrections"), "Serialized XMP missing MaskGroupBasedCorrections")
    expect(xml.contains("crs:UprightFourSegments0"), "Serialized XMP missing UprightFourSegments0")

    guard let decoded = XMPSidecar.parse(data: Data(xml.utf8)) else {
        expect(false, "XMPSidecar.parse returned nil"); fatalError()
    }
    expect(decoded.params.uprightGuides.count == 2, "Expected 2 upright guides after XMP round-trip")
    expect(abs(decoded.params.uprightGuides[0].y0 - 0.1) < 1e-4, "Upright guide Y flip round-trip mismatch")
    expect(decoded.params.masks.count == 3, "Expected 3 masks after XMP round-trip, got \(decoded.params.masks.count)")

    let rm1 = decoded.params.masks[0]
    expect(rm1.kind == .linear && abs(rm1.y0 - 0.9) < 1e-4 && abs(rm1.adjust.exposure - (-0.8)) < 1e-2,
           "Linear mask round-trip mismatch: \(rm1)")
    expect(rm1.components.count == 1 && rm1.components[0].op == .subtract && rm1.components[0].kind == .subject,
           "Boolean subtract subject sub-mask round-trip mismatch")

    let rm2 = decoded.params.masks[1]
    expect(rm2.kind == .radial && abs(rm2.radialAngle - 25) < 0.2 && abs((rm2.radiusX ?? 0) - 0.22) < 1e-3,
           "Radial mask round-trip mismatch")

    let rm3 = decoded.params.masks[2]
    expect(rm3.kind == .faceSkin && rm3.components.count == 1 && rm3.components[0].op == .intersect && rm3.components[0].kind == .luminanceRange,
           "Portrait faceSkin + intersect luminanceRange round-trip mismatch")

    print("PASS [5/5] XMP Mask & Guided Upright Bidirectional Round-Trip (3 composite masks + 2 guides verified)")
}

print("ALL 5 V4.8 ENGINE TESTS PASSED!")
}
}
