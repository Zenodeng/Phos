import Foundation
import CoreImage
import CoreGraphics

// HALD CLUT 支持
// 约定（已用 RawTherapee 的身份文件实测验证）：
//   图像边长 S，立方体边长 N，满足 S*S == N*N*N
//   索引 idx = r + g*N + b*N*N，像素位于 (idx % S, idx / S)
// Core Image 的 cubeDimension 上限低于 144，所以重采样到 64 级。

final class CLUTLibrary: ObservableObject {
    static let shared = CLUTLibrary()

    var root: URL {
        URL(fileURLWithPath: NSString("~/Documents/RawTherapee/HaldCLUT").expandingTildeInPath)
    }

    private let cache = BoundedCache<String, Data>(capacity: 12)
    private struct HaldPixels {
        let side: Int
        let dimension: Int
        let bytes: [UInt8]
    }
    private let imageCache = BoundedCache<String, HaldPixels>(capacity: 2)
    private let listLock = NSLock()
    private var listCache: [String]?
    private let cubeDim = 64

    /// 列出所有可用 CLUT（相对根目录的路径，便于存进参数里）
    func list() -> [String] {
        listLock.lock()
        defer { listLock.unlock() }
        if let listCache { return listCache }
        var out: [String] = []
        if let e = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                let ext = u.pathExtension.lowercased()
                guard ext == "png" || ext == "tif" || ext == "tiff" else { continue }
                let rel = u.path.replacingOccurrences(of: root.path + "/", with: "")
                out.append(rel)
            }
        }
        out.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        listCache = out
        return out
    }

    func invalidate() {
        listLock.lock()
        listCache = nil
        listLock.unlock()
        cache.removeAll()
        imageCache.removeAll()
    }

    /// 生成一个 CIColorCube 滤镜；strength 直接烘进立方体里，省一次混合
    func cubeFilter(name: String, strength: Double) -> CIFilter? {
        guard !name.isEmpty, strength > 0 else { return nil }
        let key = "\(name)|\(round(strength * 100))"
        let data: Data
        if let d = cache[key] {
            data = d
        } else {
            guard let d = buildCube(name: name, strength: strength) else { return nil }
            cache[key] = d
            data = d
        }
        let f = CIFilter(name: "CIColorCube")!
        f.setValue(cubeDim, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        return f
    }

    private func pixels(name: String) -> HaldPixels? {
        if let cached = imageCache[name] { return cached }
        let url = root.appendingPathComponent(name)
        guard let img = CIImage(contentsOf: url) else { return nil }
        let S = Int(img.extent.width)
        guard S > 0, abs(img.extent.width - img.extent.height) < 1 else { return nil }
        let N = Int(round(pow(Double(S) * Double(S), 1.0 / 3.0)))
        guard N * N * N == S * S else { return nil }

        // 把整张 CLUT 渲染成 RGBA8
        var buf = [UInt8](repeating: 0, count: S * S * 4)
        Engine.ctx.render(img, toBitmap: &buf, rowBytes: S * 4, bounds: img.extent,
                          format: .RGBA8, colorSpace: Engine.srgb)
        let pixels = HaldPixels(side: S, dimension: N, bytes: buf)
        imageCache[name] = pixels
        return pixels
    }

    private func buildCube(name: String, strength: Double) -> Data? {
        guard let pixels = pixels(name: name) else { return nil }
        let S = pixels.side, N = pixels.dimension, buf = pixels.bytes
        let D = cubeDim
        let lastD = Double(D - 1)
        let lastN = Double(N - 1)
        var out = [Float](repeating: 0, count: D * D * D * 4)

        for b in 0..<D {
            let fb = Double(b) / lastD
            for g in 0..<D {
                let fg = Double(g) / lastD
                for r in 0..<D {
                    let fr = Double(r) / lastD
                    let ri = Int((fr * lastN).rounded())
                    let gi = Int((fg * lastN).rounded())
                    let bi = Int((fb * lastN).rounded())
                    let idx = ri + gi * N + bi * N * N
                    let px = idx % S
                    let py = idx / S
                    let o = (py * S + px) * 4
                    let dst = (b * D * D + g * D + r) * 4
                    for c in 0..<3 {
                        let clutV = Double(buf[o + c]) / 255.0
                        let srcV = c == 0 ? fr : (c == 1 ? fg : fb)
                        out[dst + c] = Float(srcV + (clutV - srcV) * strength)
                    }
                    out[dst + 3] = 1
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }
}
