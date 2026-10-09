import Foundation
import CoreImage
import CoreGraphics

// CLUT 支持：HALD CLUT（PNG/TIF）+ .cube 3D LUT
//
// HALD 约定（已用 RawTherapee 的身份文件实测验证）：
//   图像边长 S，立方体边长 N，满足 S*S == N*N*N
//   索引 idx = r + g*N + b*N*N，像素位于 (idx % S, idx / S)
//
// .cube 约定（Adobe / DaVinci Resolve 标准）：
//   LUT_3D_SIZE N，随后 N^3 行 "R G B"，同样是 R 变化最快
//   即 idx = r + g*N + b*N*N —— 与 HALD 同序，可直接三线性插值重采样
//
// 两条路径产出的都是同一份 CIColorCube 数据：
//   Core Image 的 cubeDimension 上限低于 144，所以统一重采样到 64 级。
//   strength 直接烘进立方体（以恒等映射为基准插值），省一次混合。

final class CLUTLibrary: ObservableObject {
    static let shared = CLUTLibrary()

    var root: URL {
        let configured = UserDefaults.standard.string(forKey: "clutDirectory") ?? ""
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSString("~/Documents/RawTherapee/HaldCLUT").expandingTildeInPath)
    }

    private let cache = BoundedCache<String, Data>(capacity: 12)
    private struct HaldPixels {
        let side: Int
        let dimension: Int
        let bytes: [UInt8]
    }
    /// .cube 解析结果：size^3 * 3 个分量，按 idx = r + g*N + b*N*N 排列
    struct CubeLUT {
        let size: Int
        let values: [Float]
    }
    private let imageCache = BoundedCache<String, HaldPixels>(capacity: 2)
    private let cubeCache = BoundedCache<String, CubeLUT>(capacity: 6)
    private let listLock = NSLock()
    private var listCache: [String]?
    private let cubeDim = 64

    private static let haldExtensions: Set<String> = ["png", "tif", "tiff"]

    /// 列出所有可用 CLUT（相对根目录的路径，便于存进参数里）
    func list() -> [String] {
        listLock.lock()
        defer { listLock.unlock() }
        if let listCache { return listCache }
        var out: [String] = []
        // 解析 root 上的符号链接（macOS 的 /var -> /private/var、iCloud 下的 Documents 等），
        // 否则 enumerator 给出的路径与 root 前缀对不上，相对路径会算错。
        let rootPath = root.resolvingSymlinksInPath().path
        if let e = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                let ext = u.pathExtension.lowercased()
                if ext == "cube" {
                    // 只收 3D LUT：1D 的 CIColorCube 吃不下，列出来也只会选了没反应
                    if Self.is3DCube(u) { out.append(relative(u, rootPath: rootPath)) }
                } else if Self.haldExtensions.contains(ext) {
                    out.append(relative(u, rootPath: rootPath))
                }
            }
        }
        out.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        listCache = out
        return out
    }

    private func relative(_ u: URL, rootPath: String) -> String {
        let p = u.path
        if p.hasPrefix(rootPath + "/") {
            return String(p.dropFirst(rootPath.count + 1))
        }
        return u.lastPathComponent
    }

    /// 轻量嗅探：只读文件头，确认是 3D LUT（LUT_1D_SIZE 的不要）
    private static func is3DCube(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 8192)) ?? Data()
        guard let text = String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1) else { return false }
        let upper = text.uppercased()
        return upper.contains("LUT_3D_SIZE") && !upper.contains("LUT_1D_SIZE")
    }

    func invalidate() {
        listLock.lock()
        listCache = nil
        listLock.unlock()
        cache.removeAll()
        imageCache.removeAll()
        cubeCache.removeAll()
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
        guard let f = CIFilter(name: "CIColorCube") else { return nil }
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
        let url = root.appendingPathComponent(name)
        if url.pathExtension.lowercased() == "cube" {
            return buildCubeData(fromCube: url, strength: strength)
        }
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

    // MARK: - .cube

    /// 解析 .cube 文本（Adobe / Resolve 标准 3D LUT）。
    ///
    /// 编码用 Latin-1 兜底：不少中文 LUT 的注释行是 GBK，UTF-8 解不动整个文件，
    /// 但数值行全是 ASCII，Latin-1 一定读得下来；中文注释行本来就被跳过。
    static func parseCube(url: URL) -> CubeLUT? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return nil }

        var size = 0
        var values: [Float] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") { continue }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                size = parts.last.flatMap { Int($0) } ?? 0
                if size > 1 { values.reserveCapacity(size * size * size * 3) }
                continue
            }
            // 1D LUT / 非 [0,1] 定义域：不支持，跳过（DOMAIN 行本身也不是三元组，会被下面滤掉）
            if upper.hasPrefix("LUT_1D_SIZE") || upper.hasPrefix("DOMAIN_MIN") || upper.hasPrefix("DOMAIN_MAX") {
                continue
            }
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count == 3,
               let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                values.append(r); values.append(g); values.append(b)
            }
        }
        guard size > 1, values.count == size * size * size * 3 else { return nil }
        return CubeLUT(size: size, values: values)
    }

    /// 把 .cube 三线性插值重采样到 64 级，strength 以恒等映射为基准烘进立方体
    /// （与 HALD 路径同构，所以两条路出来的观感一致）
    private func buildCubeData(fromCube url: URL, strength: Double) -> Data? {
        let lut: CubeLUT
        if let cached = cubeCache[url.path] {
            lut = cached
        } else {
            guard let parsed = Self.parseCube(url: url) else { return nil }
            cubeCache[url.path] = parsed
            lut = parsed
        }
        let N = lut.size
        let D = cubeDim
        let lastD = Double(D - 1)
        let lastN = Double(N - 1)
        var out = [Float](repeating: 0, count: D * D * D * 4)

        lut.values.withUnsafeBufferPointer { vals in
            for b in 0..<D {
                let fb = Double(b) / lastD
                let cb = fb * lastN
                let b0 = Int(cb), b1 = min(b0 + 1, N - 1)
                let tb = cb - Double(b0)
                for g in 0..<D {
                    let fg = Double(g) / lastD
                    let cg = fg * lastN
                    let g0 = Int(cg), g1 = min(g0 + 1, N - 1)
                    let tg = cg - Double(g0)
                    for r in 0..<D {
                        let fr = Double(r) / lastD
                        let cr = fr * lastN
                        let r0 = Int(cr), r1 = min(r0 + 1, N - 1)
                        let tr = cr - Double(r0)

                        // 8 个角显式展开：这层循环跑 64^3 次，数组字面量会有分配开销
                        let i000 = (r0 + g0 * N + b0 * N * N) * 3
                        let i100 = (r1 + g0 * N + b0 * N * N) * 3
                        let i010 = (r0 + g1 * N + b0 * N * N) * 3
                        let i110 = (r1 + g1 * N + b0 * N * N) * 3
                        let i001 = (r0 + g0 * N + b1 * N * N) * 3
                        let i101 = (r1 + g0 * N + b1 * N * N) * 3
                        let i011 = (r0 + g1 * N + b1 * N * N) * 3
                        let i111 = (r1 + g1 * N + b1 * N * N) * 3

                        let w000 = (1 - tr) * (1 - tg) * (1 - tb)
                        let w100 = tr * (1 - tg) * (1 - tb)
                        let w010 = (1 - tr) * tg * (1 - tb)
                        let w110 = tr * tg * (1 - tb)
                        let w001 = (1 - tr) * (1 - tg) * tb
                        let w101 = tr * (1 - tg) * tb
                        let w011 = (1 - tr) * tg * tb
                        let w111 = tr * tg * tb

                        let dst = (b * D * D + g * D + r) * 4
                        let vR = w000 * Double(vals[i000]) + w100 * Double(vals[i100])
                               + w010 * Double(vals[i010]) + w110 * Double(vals[i110])
                               + w001 * Double(vals[i001]) + w101 * Double(vals[i101])
                               + w011 * Double(vals[i011]) + w111 * Double(vals[i111])
                        let vG = w000 * Double(vals[i000 + 1]) + w100 * Double(vals[i100 + 1])
                               + w010 * Double(vals[i010 + 1]) + w110 * Double(vals[i110 + 1])
                               + w001 * Double(vals[i001 + 1]) + w101 * Double(vals[i101 + 1])
                               + w011 * Double(vals[i011 + 1]) + w111 * Double(vals[i111 + 1])
                        let vB = w000 * Double(vals[i000 + 2]) + w100 * Double(vals[i100 + 2])
                               + w010 * Double(vals[i010 + 2]) + w110 * Double(vals[i110 + 2])
                               + w001 * Double(vals[i001 + 2]) + w101 * Double(vals[i101 + 2])
                               + w011 * Double(vals[i011 + 2]) + w111 * Double(vals[i111 + 2])
                        // .cube 允许负值 / >1（HDR 调色），cube data 里裁回 [0,1]
                        out[dst] = Float(fr + (min(max(vR, 0), 1) - fr) * strength)
                        out[dst + 1] = Float(fg + (min(max(vG, 0), 1) - fg) * strength)
                        out[dst + 2] = Float(fb + (min(max(vB, 0), 1) - fb) * strength)
                        out[dst + 3] = 1
                    }
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }
}
