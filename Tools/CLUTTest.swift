import Foundation
import CoreImage
import CoreGraphics
import ImageIO

// .cube 3D LUT 原生支持的回归测试。
//
// 与 test_autotone.sh 一样绕开 -D PHOS_TESTING 的全量编译
// （那条路会卡在 Inspector.swift 的类型检查），只编译引擎相关文件。
//
// 用法：bash Scripts/test_clut.sh

@main
struct CLUTTest {

    static var failures = 0

    typealias Transform = (Double, Double, Double) -> (Double, Double, Double)

    static let identityT: Transform = { r, g, b in (r, g, b) }
    static let swapRBT: Transform = { r, g, b in (b, g, r) }   // 红蓝互换，方向好认
    static let warmT: Transform = { r, g, b in                  // 非平凡：抬红压蓝
        (min(r * 1.1 + 0.02, 1), g, max(b * 0.9 - 0.02, 0))
    }

    static let DIM = 64

    // MARK: - 断言

    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ✓ \(msg)") } else { print("  ✗ \(msg)"); failures += 1 }
    }
    static func section(_ s: String) { print("\n== \(s) ==") }

    // MARK: - 造文件

    static func fmt(_ v: Double) -> String { String(format: "%.6f", v) }

    /// 写 .cube。行列顺序必须是 R 最快（外层 b、中层 g、内层 r）
    @discardableResult
    static func writeCube(_ t: Transform, to url: URL, N: Int = 33, lineEnding: String = "\n") -> Bool {
        var s = "TITLE \"test\"\(lineEnding)LUT_3D_SIZE \(N)\(lineEnding)\(lineEnding)"
        for b in 0..<N {
            for g in 0..<N {
                for r in 0..<N {
                    let o = t(Double(r) / Double(N - 1), Double(g) / Double(N - 1), Double(b) / Double(N - 1))
                    s += "\(fmt(o.0)) \(fmt(o.1)) \(fmt(o.2))\(lineEnding)"
                }
            }
        }
        guard let d = s.data(using: .utf8) else { return false }
        return (try? d.write(to: url)) != nil
    }

    /// 写一个 HALD PNG：idx = r + g*N + b*N*N，像素在 (idx % S, idx / S)
    @discardableResult
    static func writeHALD(_ t: Transform, to url: URL, N: Int = 64) -> Bool {
        let S = Int(Double(N * N * N).squareRoot())
        guard S * S == N * N * N else { return false }
        var px = [UInt8](repeating: 0, count: S * S * 4)
        for k in 0..<(N * N * N) {
            let o = t(Double(k % N) / Double(N - 1),
                      Double((k / N) % N) / Double(N - 1),
                      Double(k / (N * N)) / Double(N - 1))
            let p = ((k / S) * S + (k % S)) * 4
            px[p] = UInt8(clamping: Int((o.0 * 255).rounded()))
            px[p + 1] = UInt8(clamping: Int((o.1 * 255).rounded()))
            px[p + 2] = UInt8(clamping: Int((o.2 * 255).rounded()))
            px[p + 3] = 255
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: S * 4, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - 取 cube data

    static func cubeData(_ name: String, strength: Double) -> Data? {
        guard let f = CLUTLibrary.shared.cubeFilter(name: name, strength: strength),
              let raw = f.value(forKey: "inputCubeData") else { return nil }
        if let d = raw as? Data { return d }
        if let d = raw as? NSData { return d as Data }
        return nil
    }

    static func cubeValue(_ data: Data, _ r: Int, _ g: Int, _ b: Int, _ c: Int) -> Double {
        var out = 0.0
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let fp = p.bindMemory(to: Float.self)
            out = Double(fp[(b * DIM * DIM + g * DIM + r) * 4 + c])
        }
        return out
    }

    // MARK: - 端到端用

    static func srgbToLinear(_ s: Double) -> Double {
        s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    static func renderOnePixel(_ filter: CIFilter, srgb: (Double, Double, Double)) -> (Double, Double, Double)? {
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let base = CIImage(color: CIColor(red: srgbToLinear(srgb.0),
                                          green: srgbToLinear(srgb.1),
                                          blue: srgbToLinear(srgb.2))).cropped(to: rect)
        // 模拟 Engine.render 的做法：进 LUT 前先编码到 sRGB 感知域
        filter.setValue(base.applyingFilter("CILinearToSRGBToneCurve"), forKey: kCIInputImageKey)
        guard let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        Engine.ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: rect,
                          format: .RGBA8, colorSpace: Engine.srgb)
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    // MARK: - 主流程

    static func main() {
        let args = CommandLine.arguments
        // 直接扫一个真实目录，确认某个 LUT 有没有被收录
        if args.count >= 3, args[1] == "list" {
            UserDefaults.standard.set((args[2] as NSString).expandingTildeInPath, forKey: "clutDirectory")
            CLUTLibrary.shared.invalidate()
            let l = CLUTLibrary.shared.list()
            print("共 \(l.count) 个：")
            for n in l { print("  \(n)") }
            exit(0)
        }
        selfTest()
    }

    static func selfTest() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phos-clut-test-\(getpid())")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 用临时目录当 CLUT 根，绝不碰用户真实配置
        UserDefaults.standard.set(tmp.path, forKey: "clutDirectory")
        CLUTLibrary.shared.invalidate()

        let fIdentity = tmp.appendingPathComponent("identity.cube")
        let fSwap = tmp.appendingPathComponent("swaprb.cube")
        let fWarm = tmp.appendingPathComponent("warm.cube")
        let fHald = tmp.appendingPathComponent("hald_swap.png")
        let fOneD = tmp.appendingPathComponent("oned.cube")

        writeCube(identityT, to: fIdentity)
        writeCube(swapRBT, to: fSwap)
        writeCube(warmT, to: fWarm)
        writeHALD(swapRBT, to: fHald)

        // 1D LUT：不该出现在列表里
        let oneDText = "LUT_1D_SIZE 4\n0 0 0\n0.33 0.33 0.33\n0.66 0.66 0.66\n1 1 1\n"
        try? oneDText.data(using: .utf8)?.write(to: fOneD)

        // 非 UTF-8 中文注释 + CRLF 行尾：验证编码回退与行尾健壮性
        do {
            var data = Data([0x23, 0xC4, 0xE3])                 // '#' + GBK「你」
            data.append(contentsOf: Array("\r\n".utf8))
            var body = "TITLE \"x\"\r\nLUT_3D_SIZE 33\r\n"
            for b in 0..<33 {
                for g in 0..<33 {
                    for r in 0..<33 {
                        let o = swapRBT(Double(r) / 32, Double(g) / 32, Double(b) / 32)
                        body += "\(fmt(o.0)) \(fmt(o.1)) \(fmt(o.2))\r\n"
                    }
                }
            }
            data.append(contentsOf: Array(body.utf8))
            try? data.write(to: tmp.appendingPathComponent("crlf_gbk.cube"))
        }

        // MARK: 1. 列表收录

        section("列表收录")
        let list = CLUTLibrary.shared.list()
        print("  扫到 \(list.count) 个：\(list.joined(separator: ", "))")
        check(list.contains("identity.cube"), "收录 .cube（identity）")
        check(list.contains("swaprb.cube"), "收录 .cube（swaprb）")
        check(list.contains("crlf_gbk.cube"), "收录非 UTF-8 注释 + CRLF 的 .cube")
        check(list.contains("hald_swap.png"), "收录 HALD PNG")
        check(!list.contains("oned.cube"), "排除 1D LUT（CIColorCube 吃不下）")

        // MARK: 2. 解析与插值

        section("identity.cube → 恒等映射")
        if let d = cubeData("identity.cube", strength: 1.0) {
            var worst = 0.0
            for i in 0..<64 {
                let r = (i * 7) % 64, g = (i * 13) % 64, b = (i * 29) % 64
                for c in 0..<3 {
                    let expect = Double(c == 0 ? r : (c == 1 ? g : b)) / 63.0
                    worst = max(worst, abs(cubeValue(d, r, g, b, c) - expect))
                }
            }
            check(worst < 1e-5, "64 点抽样最大偏差 \(String(format: "%.2e", worst))")
        } else {
            check(false, "identity.cube 无法构建 cube")
        }

        section("swaprb.cube → 红蓝互换")
        if let d = cubeData("swaprb.cube", strength: 1.0) {
            var worst = 0.0
            for i in 0..<64 {
                let r = (i * 11) % 64, g = (i * 17) % 64, b = (i * 23) % 64
                worst = max(worst, abs(cubeValue(d, r, g, b, 0) - Double(b) / 63.0))
                worst = max(worst, abs(cubeValue(d, r, g, b, 1) - Double(g) / 63.0))
                worst = max(worst, abs(cubeValue(d, r, g, b, 2) - Double(r) / 63.0))
            }
            check(worst < 1e-5, "64 点抽样最大偏差 \(String(format: "%.2e", worst))")
        } else {
            check(false, "swaprb.cube 无法构建 cube")
        }

        section("strength 混合：0.5 强度 = 恒等与原映射的中点")
        if let full = cubeData("swaprb.cube", strength: 1.0),
           let half = cubeData("swaprb.cube", strength: 0.5) {
            var worst = 0.0
            for i in 0..<64 {
                let r = (i * 11) % 64, g = (i * 17) % 64, b = (i * 23) % 64
                for c in 0..<3 {
                    let mid = 0.5 * (Double(c == 0 ? r : (c == 1 ? g : b)) / 63.0
                                     + cubeValue(full, r, g, b, c))
                    worst = max(worst, abs(cubeValue(half, r, g, b, c) - mid))
                }
            }
            check(worst < 1e-5, "半强度最大偏差 \(String(format: "%.2e", worst))")
        } else {
            check(false, "strength 采样失败")
        }

        section("非平凡变换 warm.cube")
        if let d = cubeData("warm.cube", strength: 1.0) {
            // 输入中灰：R 应被抬高、B 应被压低
            let r = cubeValue(d, 32, 32, 32, 0)
            let g = cubeValue(d, 32, 32, 32, 1)
            let b = cubeValue(d, 32, 32, 32, 2)
            check(r > 32.0 / 63.0 && b < 32.0 / 63.0,
                  "中灰 R 抬高 (\(String(format: "%.3f", r)))、B 压低 (\(String(format: "%.3f", b)))")
            check(abs(g - 32.0 / 63.0) < 0.01, "G 基本不动 (\(String(format: "%.3f", g)))")
        } else {
            check(false, "warm.cube 无法构建 cube")
        }

        // MARK: 3. .cube 与 HALD 等价

        section(".cube 与 HALD 同一变换应等价")
        if let dCube = cubeData("swaprb.cube", strength: 1.0),
           let dHald = cubeData("hald_swap.png", strength: 1.0) {
            var worst = 0.0
            for i in 0..<64 {
                let r = (i * 11) % 64, g = (i * 17) % 64, b = (i * 23) % 64
                for c in 0..<3 {
                    worst = max(worst, abs(cubeValue(dCube, r, g, b, c) - cubeValue(dHald, r, g, b, c)))
                }
            }
            // HALD 走的是 uint8，量化误差上限约 1/255
            check(worst <= 2.0 / 255.0, "两条路径最大偏差 \(String(format: "%.4f", worst))（容差 2/255）")
        } else {
            check(false, "等价性采样失败")
        }

        // MARK: 4. 端到端

        section("端到端：swap LUT 下偏红输入应变偏蓝")
        if let f = CLUTLibrary.shared.cubeFilter(name: "swaprb.cube", strength: 1.0),
           let o = renderOnePixel(f, srgb: (0.80, 0.30, 0.15)) {
            // 输入偏红 (0.8,0.3,0.15) → 交换后应偏蓝 (0.15,0.3,0.8)
            check(o.2 > o.0 + 0.5, "输出 B(\(String(format: "%.3f", o.2))) 远高于 R(\(String(format: "%.3f", o.0)))")
            check(abs(o.2 - 0.80) < 0.04 && abs(o.0 - 0.15) < 0.04,
                  "输出 ≈ (0.15, 0.30, 0.80)，实得 (\(String(format: "%.3f", o.0)), \(String(format: "%.3f", o.1)), \(String(format: "%.3f", o.2)))")
        } else {
            check(false, "端到端渲染失败")
        }

        // MARK: - 收尾

        try? FileManager.default.removeItem(at: tmp)
        print("\n" + String(repeating: "-", count: 46))
        if failures == 0 {
            print("全部通过 ✓")
            exit(0)
        } else {
            print("失败 \(failures) 项 ✗")
            exit(1)
        }
    }
}
