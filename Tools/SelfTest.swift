// 引擎自测：验证 CLUT / HSL / 蒙版 / 裁剪 / 出图 是否真的生效
// 用 -D RAWFORGE_TESTING Sources/RawForge/*.swift Tools/SelfTest.swift 单独编译。
import Foundation
import CoreImage

func out(_ name: String, _ img: CIImage, _ p: EditParams) -> URL {
    let dest = URL(fileURLWithPath: "/tmp/rfselftest/\(name).jpg")
    let r = Engine.render(img, p)
    try? Engine.write(r, to: dest, settings: ExportSettings(quality: 0.95, maxLongEdge: 900))
    return dest
}

func stats(_ u: URL) -> (Double, Double) {
    guard let ci = CIImage(contentsOf: u) else { return (0, 0) }
    let h = Engine.histogram(ci)
    let tot = max(h.l.reduce(0, +), 1)
    var lum = 0.0
    for (i, v) in h.l.enumerated() { lum += Double(i) / 255.0 * Double(v) }
    lum = lum / Double(tot) * 255
    let sat: Double = {
        let e = ci.extent
        let s = min(1, 300 / max(e.width, e.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = Int(small.extent.width), hh = Int(small.extent.height)
        var buf = [UInt8](repeating: 0, count: w * hh * 4)
        Engine.ctx.render(small, toBitmap: &buf, rowBytes: w * 4, bounds: small.extent, format: .RGBA8, colorSpace: Engine.srgb)
        var acc = 0.0
        for i in 0..<(w * hh) {
            let o = i * 4
            let mx = max(buf[o], max(buf[o + 1], buf[o + 2]))
            let mn = min(buf[o], min(buf[o + 1], buf[o + 2]))
            acc += mx == 0 ? 0 : Double(mx - mn) / Double(mx)
        }
        return acc / Double(max(w * hh, 1)) * 100
    }()
    return (lum, sat)
}

func runSelfTest() {
    try? FileManager.default.createDirectory(atPath: "/tmp/rfselftest", withIntermediateDirectories: true)
    // 测试底图：环境变量 RF_TEST_IMG 指定，否则取 ~/Pictures 里第一张图
    let src: URL = {
        if let p = ProcessInfo.processInfo.environment["RF_TEST_IMG"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let pics = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let exts = ["jpg", "jpeg", "png", "heic", "tif", "tiff"]
        let files = (try? FileManager.default.contentsOfDirectory(at: pics, includingPropertiesForKeys: nil)) ?? []
        return files.first(where: { exts.contains($0.pathExtension.lowercased()) })
            ?? URL(fileURLWithPath: "/nonexistent")
    }()
    guard let img = Engine.decode(src) else { print("读不到测试图"); exit(1) }
    print("源图: \(Int(img.extent.width))×\(Int(img.extent.height))")

    let cluts = CLUTLibrary.shared.list()
    print("可用 CLUT: \(cluts.count) 个")

    let cases: [(String, EditParams)] = {
        var base = EditParams()

        var exposure = base; exposure.exposure = 1.0

        var cl = base; cl.clutName = "Color/Kodak/Kodak Kodachrome 64.png"; cl.clutStrength = 1.0

        var half = cl; half.clutStrength = 0.5

        var hsl = base; hsl.hsl.blue.sat = -80; hsl.hsl.blue.lum = -30

        var mono = base; mono.mono = true

        var masked = base
        var m = Mask(); m.kind = .radial; m.x0 = 0.3; m.y0 = 0.7; m.radius = 0.35
        m.adjust.exposure = 2.0; m.adjust.saturation = 40
        masked.masks = [m]

        var brushed = base
        var b = Mask(); b.kind = .brush; b.name = "笔刷"
        var st = Stroke(pts: [], radius: 0.08, feather: 0.3)
        for i in 0...60 { let t = Double(i) / 60; st.pts.append([0.2 + t * 0.6, 1 - (0.5 + 0.2 * sin(t * 6))]) }
        b.strokes = [st]; b.adjust.exposure = 1.5
        brushed.masks = [b]

        var cropped = base; cropped.cropX = 0.15; cropped.cropY = 0.15; cropped.cropW = 0.6; cropped.cropH = 0.6

        var rotated = base; rotated.rotation = 90

        var grained = base; grained.grain = 60; grained.clarity = 40

        return [("00_基准", base), ("01_曝光+1", exposure), ("02_Kodachrome64", cl),
                ("03_K64_浓度50", half), ("04_蓝色去饱和", hsl), ("05_黑白", mono),
                ("06_径向蒙版", masked), ("07_笔刷蒙版", brushed), ("08_裁剪", cropped),
                ("09_旋转90", rotated), ("10_清晰+颗粒", grained)]
    }()

    print("\n名称                 亮度    饱和度   体积")
    var baseline = (0.0, 0.0)
    for (name, p) in cases {
        let u = out(name, img, p)
        let (l, s) = stats(u)
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if name == "00_基准" { baseline = (l, s) }
        print(String(format: "%-18@ %7.1f %7.1f %7d KB", name, l, s, size / 1024))
    }

    // 校验：套了 CLUT 的必须跟基准不一样
    let cl = cases[2].1
    let u1 = out("chk_base", img, EditParams())
    let u2 = out("chk_clut", img, cl)
    let a = stats(u1), b2 = stats(u2)
    print("\n基准 vs Kodachrome: 亮度 \(String(format: "%.1f", a.0)) -> \(String(format: "%.1f", b2.0))，"
        + "饱和 \(String(format: "%.1f", a.1)) -> \(String(format: "%.1f", b2.1))")
    let changed = abs(a.0 - b2.0) > 0.5 || abs(a.1 - b2.1) > 0.5
    print(changed ? "✅ CLUT 生效" : "❌ CLUT 没起作用")

    // 校验裁剪尺寸
    let cr = cases[8].1
    let crImg = Engine.render(img, cr)
    print(String(format: "裁剪结果尺寸: %.0f×%.0f（原图 %.0f×%.0f）",
                 crImg.extent.width, crImg.extent.height, img.extent.width, img.extent.height))
    print(abs(crImg.extent.width - img.extent.width * 0.6) < 2 ? "✅ 裁剪正确" : "❌ 裁剪不对")

    // 校验旋转
    let rot = Engine.render(img, cases[9].1)
    print(abs(rot.extent.width - img.extent.height) < 2 ? "✅ 旋转正确" : "❌ 旋转不对")
}

@main
struct SelfTestMain {
    static func main() { runSelfTest() }
}
