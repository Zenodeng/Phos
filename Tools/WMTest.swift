// 水印自测：验证 ①长边缩放正确（旧代码会缩两次）②文字水印落在预期区域
// ③图片水印 + 旋转 + 居中 ④不透明度生效。不参与 App 构建，单独编译。
//   swiftc -O -sdk <SDK> -target arm64-apple-macosx15.0 \
//     -D PHOS_TESTING Sources/Phos/*.swift \
//     Tools/WMTest.swift -o /tmp/rfwmtest_bin
import Foundation
import CoreImage
import AppKit

let dir = URL(fileURLWithPath: "/tmp/rfwmtest")

func pixels(_ img: CIImage) -> (w: Int, h: Int, buf: [UInt8]) {
    let e = img.extent
    let w = Int(e.width), h = Int(e.height)
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    Engine.ctx.render(img, toBitmap: &buf, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: Engine.srgb)
    return (w, h, buf)
}

/// 区域平均亮度（rect 用归一化坐标，y 从上往下 —— CIContext.render 的第 0 行是图顶）
func regionLum(_ img: CIImage, _ rect: CGRect) -> Double {
    let (w, h, buf) = pixels(img)
    var acc = 0.0, n = 0
    let x0 = Int(CGFloat(w) * rect.minX), x1 = Int(CGFloat(w) * rect.maxX)
    let y0 = Int(CGFloat(h) * rect.minY), y1 = Int(CGFloat(h) * rect.maxY)
    for y in y0..<max(y0 + 1, y1) {
        for x in x0..<max(x0 + 1, x1) {
            let o = (y * w + x) * 4
            acc += 0.299 * Double(buf[o]) + 0.587 * Double(buf[o + 1]) + 0.114 * Double(buf[o + 2])
            n += 1
        }
    }
    return acc / Double(max(n, 1))
}

func load(_ u: URL) -> CIImage? { CIImage(contentsOf: u) }

func regionDifference(_ lhs: CIImage, _ rhs: CIImage, _ rect: CGRect) -> Double {
    let a = pixels(lhs), b = pixels(rhs)
    precondition(a.w == b.w && a.h == b.h)
    var total = 0.0, count = 0
    for y in Int(Double(a.h) * rect.minY)..<Int(Double(a.h) * rect.maxY) {
        for x in Int(Double(a.w) * rect.minX)..<Int(Double(a.w) * rect.maxX) {
            let offset = (y * a.w + x) * 4
            for channel in 0..<3 {
                total += abs(Double(a.buf[offset + channel]) - Double(b.buf[offset + channel]))
                count += 1
            }
        }
    }
    return total / Double(max(count, 1))
}

func runWMTest() {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // 测试底图：有真实照片就用照片，否则合成渐变
    // 测试底图：环境变量 RF_TEST_IMG 指定，否则取 ~/Pictures 里第一张图；都没有就合成渐变
    let photo: URL = {
        if let p = ProcessInfo.processInfo.environment["RF_TEST_IMG"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let pics = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let exts = ["jpg", "jpeg", "png", "heic", "tif", "tiff"]
        let files = (try? FileManager.default.contentsOfDirectory(at: pics, includingPropertiesForKeys: nil)) ?? []
        return files.first(where: { exts.contains($0.pathExtension.lowercased()) })
            ?? URL(fileURLWithPath: "/nonexistent")
    }()
    var base: CIImage
    if FileManager.default.fileExists(atPath: photo.path), let im = Engine.decode(photo) {
        base = im
        print("底图: 真实照片 \(Int(im.extent.width))×\(Int(im.extent.height))")
    } else {
        base = CIImage(color: CIColor(red: 0.18, green: 0.32, blue: 0.58))
            .cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        print("底图: 合成渐变 1600×1000")
    }

    // 做一张图片水印（logo）：红圆 + 白字，带透明背景
    let logoPath = dir.appendingPathComponent("logo.png")
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 120,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 320, height: 120)
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    NSColor.systemRed.setFill()
    NSBezierPath(ovalIn: NSRect(x: 8, y: 18, width: 84, height: 84)).fill()
    ("ZENO STUDIO" as NSString).draw(at: NSPoint(x: 104, y: 44),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white])
    gc.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: logoPath)

    // ① 基准（无水印）+ 长边缩放校验
    var s0 = ExportSettings(quality: 0.95, maxLongEdge: 800)
    s0.format = "png"
    try! Engine.write(base, to: dir.appendingPathComponent("00_base.png"), settings: s0)
    let b0 = load(dir.appendingPathComponent("00_base.png"))!
    let long0 = Int(max(b0.extent.width, b0.extent.height))
    print("① 长边缩放: 输出 \(Int(b0.extent.width))×\(Int(b0.extent.height))，期望长边 800")
    print(long0 == 800 ? "✅ 缩放正确" : "❌ 长边不对（应 800 实 \(long0)）")
    precondition(long0 == 800, "Incorrect output size")

    // ② 文字水印：白字右下角
    var s1 = s0
    s1.watermarkEnabled = true
    s1.watermarkKind = "text"
    s1.watermarkText = "© Zeno 2026"
    s1.watermarkPosition = "bottomRight"
    s1.watermarkScale = 0.05
    s1.watermarkOpacity = 0.8
    try! Engine.write(base, to: dir.appendingPathComponent("01_text_br.png"), settings: s1)
    let t1 = load(dir.appendingPathComponent("01_text_br.png"))!
    let sameSize = t1.extent == b0.extent
    print("② 幅面不变: \(Int(t1.extent.width))×\(Int(t1.extent.height))")
    print(sameSize ? "✅ 幅面正确" : "❌ 画布被撑大/缩小")
    precondition(sameSize, "Watermark changed canvas")
    let brBox = CGRect(x: 0.55, y: 0.86, width: 0.44, height: 0.14)   // 右下角（y 从上往下）
    let d1 = regionLum(t1, brBox) - regionLum(b0, brBox)
    print("② 文字水印右下角亮度差: \(String(format: "%.1f", d1))")
    print(d1 > 3 ? "✅ 文字水印生效" : "❌ 文字没画上去")
    precondition(d1 > 3, "Missing text watermark")

    // ③ 图片水印：居中 + 旋转 20°
    var s2 = s0
    s2.watermarkEnabled = true
    s2.watermarkKind = "image"
    s2.watermarkImagePath = logoPath.path
    s2.watermarkPosition = "center"
    s2.watermarkScale = 0.25
    s2.watermarkOpacity = 0.9
    s2.watermarkRotation = 20
    try! Engine.write(base, to: dir.appendingPathComponent("02_img_center.png"), settings: s2)
    let t2 = load(dir.appendingPathComponent("02_img_center.png"))!
    let cBox = CGRect(x: 0.38, y: 0.45, width: 0.24, height: 0.10)   // 正中 logo 实际占位
    let d2 = regionDifference(t2, b0, cBox)
    print("③ 中心图片水印逐像素 RGB 差: \(String(format: "%.1f", d2))")
    print(d2 > 1.5 ? "✅ 图片水印生效" : "❌ 图片水印没画上去")
    precondition(d2 > 1.5, "Missing image watermark")

    // ④ 低不透明度应比高不透明度变化小
    var s3 = s1
    s3.watermarkOpacity = 0.15
    try! Engine.write(base, to: dir.appendingPathComponent("03_text_fade.png"), settings: s3)
    let t3 = load(dir.appendingPathComponent("03_text_fade.png"))!
    let d3 = regionLum(t3, brBox) - regionLum(b0, brBox)
    print("④ 不透明度 15% 亮度差: \(String(format: "%.1f", d3))（80% 时是 \(String(format: "%.1f", d1))）")
    print(d3 > 0.5 && d3 < d1 ? "✅ 不透明度生效" : "⚠️ 变化不单调")
    precondition(d3 > 0.5 && d3 < d1, "Incorrect watermark opacity")

    // ⑤ 九宫格各位置都出图（转一圈，检查幅面 + 落点）
    for pos in ExportSettings.wmPositions {
        var sp = s1
        sp.watermarkPosition = pos
        sp.watermarkText = pos
        sp.watermarkRotation = -15
        try! Engine.write(base, to: dir.appendingPathComponent("pos_\(pos).png"), settings: sp)
        let pi = load(dir.appendingPathComponent("pos_\(pos).png"))!
        if pi.extent != b0.extent {
            print("❌ \(pos) 幅面变成 \(Int(pi.extent.width))×\(Int(pi.extent.height))")
        }
        precondition(pi.extent == b0.extent, "Watermark changed canvas: \(pos)")
    }
    print("⑤ 九宫格 9 张已出到 \(dir.path)/pos_*.png（幅面应全为 \(Int(b0.extent.width))×\(Int(b0.extent.height))）")
}

@main
struct WMTestMain {
    static func main() { runWMTest() }
}
