import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 生成 DMG 安装窗口的背景图。
///
/// 窗口内容区 660×420，同时输出 @2x 版本 —— Finder 在 Retina 上会自动挑 `@2x`。
/// 画的是「石墨 × 香槟金」那套语言：深色底、金色箭头、克制的文字层级。
///
///     swiftc -O Tools/DMGBackground.swift -o /tmp/mkbg && /tmp/mkbg Scripts/dmg
///
/// 单文件编译时不能写 `@main`（会与顶层代码冲突），所以入口放在文件末尾。
struct DMGBackground {
    static let width: CGFloat = 660
    static let height: CGFloat = 460

    // 坐标以「左下角」为原点（CoreGraphics 的约定）。
    // 注意 .DS_Store 里的 Iloc 用的是「从窗口顶部往下」的 y，两者要换算，
    // 换算关系见 settings.py 的注释。
    //
    // 版面自上而下：标题 / 副标题 / 拖拽提示 → 两个图标 + 箭头 → 必读文件。
    static let titleBaseline: CGFloat = 388
    static let subtitleBaseline: CGFloat = 358
    static let hintBaseline: CGFloat = 330
    static let arrowY: CGFloat = 255

    static let gold = CGColor(red: 0.788, green: 0.659, blue: 0.463, alpha: 1)   // #C9A876
    static let ink = CGColor(red: 0.078, green: 0.082, blue: 0.094, alpha: 1)    // #141518
    static let dim = CGColor(red: 0.541, green: 0.553, blue: 0.580, alpha: 1)    // #8A8D94

    static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    }

    static func draw(_ text: String, font: CTFont, color: CGColor,
                     centerX: CGFloat, baseline: CGFloat, in ctx: CGContext) {
        let attrs = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ] as CFDictionary
        guard let attr = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: centerX - bounds.width / 2, y: baseline)
        CTLineDraw(line, ctx)
    }

    static func render(scale: CGFloat) -> CGImage? {
        let px = Int(width * scale), py = Int(height * scale)
        guard let ctx = CGContext(data: nil, width: px, height: py,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)

        // 底色
        ctx.setFillColor(ink)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 顶部一层很淡的金色辉光，让标题区不至于死平
        if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor(red: 0.788, green: 0.659, blue: 0.463, alpha: 0.13),
                                          CGColor(red: 0.788, green: 0.659, blue: 0.463, alpha: 0)] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawRadialGradient(glow,
                                   startCenter: CGPoint(x: width / 2, y: height),
                                   startRadius: 0,
                                   endCenter: CGPoint(x: width / 2, y: height),
                                   endRadius: 260, options: [])
        }

        // 品牌
        draw("Phos", font: font(34, .semibold), color: gold,
             centerX: width / 2, baseline: titleBaseline, in: ctx)
        draw("macOS 原生 RAW 照片编辑器", font: font(12.5, .regular), color: dim,
             centerX: width / 2, baseline: subtitleBaseline, in: ctx)
        // 提示挪到上面，把下方整块留给「首次打开必读」那个文件
        draw("把 Phos 拖到右侧的「应用程序」文件夹", font: font(12.5, .medium), color: dim,
             centerX: width / 2, baseline: hintBaseline, in: ctx)

        // 两个图标之间的引导箭头
        let y = arrowY
        ctx.setStrokeColor(gold)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: 252, y: y))
        ctx.addLine(to: CGPoint(x: 392, y: y))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 374, y: y + 11))
        ctx.addLine(to: CGPoint(x: 392, y: y))
        ctx.addLine(to: CGPoint(x: 374, y: y - 11))
        ctx.strokePath()

        return ctx.makeImage()
    }

    /// `dpi` 必须写对：@2x 图要标 144 dpi，这样它的「点尺寸」才和 1x 一致，
    /// `tiffutil -cathidpicheck` 才会把它认成 HiDPI 配对而不是两张无关的图。
    static func write(_ image: CGImage, to path: String, dpi: Int) {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
        else { return }
        let props = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        CGImageDestinationFinalize(dest)
    }

    static func run() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Scripts/dmg"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        guard let one = render(scale: 1), let two = render(scale: 2) else {
            print("FAIL: 渲染失败")
            exit(1)
        }
        write(one, to: "\(out)/background.png", dpi: 72)
        write(two, to: "\(out)/background@2x.png", dpi: 144)
        print("已生成 \(out)/background.png（\(Int(width))×\(Int(height)) @72dpi）")
        print("已生成 \(out)/background@2x.png（\(Int(width * 2))×\(Int(height * 2)) @144dpi）")
    }
}

DMGBackground.run()
