import Foundation
import CoreImage
import CoreGraphics
import AppKit
import SwiftUI

enum SoftProofIntent: String, Codable, CaseIterable {
    case perceptual, relativeColorimetric
    var label: String {
        switch self {
        case .perceptual:           return "感知"
        case .relativeColorimetric: return "相对色度"
        }
    }
    var nsIntent: NSColorRenderingIntent {
        switch self {
        case .perceptual:           return .perceptual
        case .relativeColorimetric: return .relativeColorimetric
        }
    }
}

struct SoftProofConfig: Equatable {
    var enabled: Bool = false
    /// "sRGB" | "displayP3" | "adobeRGB" | "genericCMYK" | 导入的 .icc/.icm 文件名
    var profileID: String = "sRGB"
    var intent: SoftProofIntent = .perceptual
    var simulatePaperAndInk: Bool = false
    var gamutWarning: Bool = false
}

/// 商业印刷 / 目标色彩空间软打样（Soft Proofing）引擎。
/// 通过 macOS 原生 ColorSync CMM（`NSBitmapImageRep.converting(to:renderingIntent:)`）执行
/// `Working Linear sRGB → Target ICC（含 CMYK/自定义微喷纸 ICC）→ Working Linear sRGB` 往返烘焙 33³ 3D LUT，
/// 支持感知/相对色度意图、模拟纸白墨黑与目标色域超限警示，零第三方依赖、零 App 体积膨胀且保持 60fps 实时预览。
enum SoftProofEngine {

    struct ProfileChoice: Identifiable, Equatable {
        let id: String
        let name: String
        let isCMYK: Bool
        let isCustom: Bool
    }

    static var iccDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos/ICCProfiles", isDirectory: true)
    }

    private static let cubeDim = 33
    private static let cubeCache = BoundedCache<String, Data>(capacity: 16)

    static func availableProfiles() -> [ProfileChoice] {
        var list: [ProfileChoice] = [
            ProfileChoice(id: "sRGB", name: "sRGB（网页/社媒）", isCMYK: false, isCustom: false),
            ProfileChoice(id: "displayP3", name: "Display P3（Apple 广色域）", isCMYK: false, isCustom: false),
            ProfileChoice(id: "adobeRGB", name: "Adobe RGB (1998)", isCMYK: false, isCustom: false),
            ProfileChoice(id: "genericCMYK", name: "Generic CMYK（四色胶印）", isCMYK: true, isCustom: false)
        ]
        if let files = try? FileManager.default.contentsOfDirectory(at: iccDirectory, includingPropertiesForKeys: nil) {
            let iccs = files.filter { ["icc", "icm"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for u in iccs {
                if let cs = loadCustomColorSpace(url: u) {
                    let isCMYK = cs.model == .cmyk
                    let title = (u.lastPathComponent as NSString).deletingPathExtension
                    list.append(ProfileChoice(id: u.lastPathComponent, name: title, isCMYK: isCMYK, isCustom: true))
                }
            }
        }
        return list
    }

    @discardableResult
    static func importICC(from sourceURL: URL) throws -> ProfileChoice {
        let data = try Data(contentsOf: sourceURL)
        guard data.count <= 16 * 1024 * 1024,
              let cs = CGColorSpace(iccData: data as CFData),
              [CGColorSpaceModel.rgb, .cmyk, .monochrome].contains(cs.model) else {
            throw NSError(domain: "Phos", code: 501, userInfo: [NSLocalizedDescriptionKey: "无效或不支持的 ICC 色彩配置文件"])
        }
        try FileManager.default.createDirectory(at: iccDirectory, withIntermediateDirectories: true)
        let dest = iccDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try data.write(to: dest, options: .atomic)
        let title = (dest.lastPathComponent as NSString).deletingPathExtension
        return ProfileChoice(id: dest.lastPathComponent, name: title, isCMYK: cs.model == .cmyk, isCustom: true)
    }

    static func resolveColorSpace(id: String) -> CGColorSpace {
        switch id {
        case "sRGB":        return Engine.srgb
        case "displayP3":   return CGColorSpace(name: CGColorSpace.displayP3) ?? Engine.srgb
        case "adobeRGB":    return CGColorSpace(name: CGColorSpace.adobeRGB1998) ?? Engine.srgb
        case "genericCMYK": return CGColorSpace(name: CGColorSpace.genericCMYK) ?? Engine.srgb
        default:
            let url = iccDirectory.appendingPathComponent(id)
            return loadCustomColorSpace(url: url) ?? Engine.srgb
        }
    }

    /// 供 `Engine.write` 导出阶段解析自定义 ICC（优先自定义路径，其次内置 ExportColorSpace）。
    static func exportColorSpace(for settings: ExportSettings) -> CGColorSpace {
        if !settings.customICCProfilePath.isEmpty {
            let direct = URL(fileURLWithPath: settings.customICCProfilePath)
            if let cs = loadCustomColorSpace(url: direct) { return cs }
            let managed = iccDirectory.appendingPathComponent(settings.customICCProfilePath)
            if let cs = loadCustomColorSpace(url: managed) { return cs }
            if settings.customICCProfilePath == "genericCMYK",
               let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK) {
                return cmyk
            }
        }
        return settings.colorSpace.cgColorSpace
    }

    private static func loadCustomColorSpace(url: URL) -> CGColorSpace? {
        guard let data = try? Data(contentsOf: url), data.count <= 16 * 1024 * 1024 else { return nil }
        return CGColorSpace(iccData: data as CFData)
    }

    /// 在最终显示输出上叠加软打样（与可选目标色域超限警告）。
    static func apply(_ img: CIImage, config: SoftProofConfig) -> CIImage {
        guard config.enabled else { return img }
        let key = "\(config.profileID)|\(config.intent.rawValue)|\(config.simulatePaperAndInk ? 1 : 0)|\(config.gamutWarning ? 1 : 0)"
        let data: Data
        if let hit = cubeCache[key] {
            data = hit
        } else if let built = buildProofCube(config: config) {
            data = built
            cubeCache[key] = data
        } else {
            return img
        }
        guard let f = CIFilter(name: "CIColorCube") else { return img }
        f.setValue(cubeDim, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        f.setValue(img, forKey: kCIInputImageKey)
        return (f.outputImage ?? img).cropped(to: img.extent)
    }

    /// 烘焙 33³ ColorSync 往返软打样 3D LUT（CIColorCube 线性域输入/输出）
    private static func buildProofCube(config: SoftProofConfig) -> Data? {
        let D = cubeDim
        let last = Double(D - 1)
        let w = D * D, h = D // 1089 × 33 像素对应全部 35,937 个立方体格点

        // 1) 构造 16-bit sRGB 感知格点图（覆盖 Display P3 广色域样本可选：用 Display P3 做源空间更能准确检出 P3->sRGB/CMYK 超色域！）
        let srcCS = CGColorSpace(name: CGColorSpace.displayP3) ?? Engine.srgb
        guard let nsSrcCS = NSColorSpace(cgColorSpace: srcCS),
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: w, pixelsHigh: h,
                  bitsPerSample: 8, samplesPerPixel: 4,
                  hasAlpha: true, isPlanar: false,
                  colorSpaceName: .calibratedRGB,
                  bytesPerRow: w * 4, bitsPerPixel: 32
              ),
              let taggedRep = rep.retagging(with: nsSrcCS),
              let ptr = taggedRep.bitmapData else { return nil }

        // 先把 CIColorCube 的线性 sRGB 格点坐标转成 Display P3 感知 8-bit，才能真实检测广色域落入 sRGB/CMYK 时的色域裁切
        func toPerc(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        func toLin(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        // 记录原始感知 sRGB 供色域差值计算
        var origSRGB = [Double](repeating: 0, count: D * D * D * 3)
        // 线性 sRGB -> 线性 Display P3 矩阵
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let rl = Double(ri) / last, gl = Double(gi) / last, bl = Double(bi) / last
                    let idx = bi * D * D + gi * D + ri
                    origSRGB[idx * 3]     = toPerc(rl)
                    origSRGB[idx * 3 + 1] = toPerc(gl)
                    origSRGB[idx * 3 + 2] = toPerc(bl)

                    let p3r = min(max(0.8224621 * rl + 0.1775380 * gl + 0.0000000 * bl, 0), 1)
                    let p3g = min(max(0.0331941 * rl + 0.9668058 * gl + 0.0000000 * bl, 0), 1)
                    let p3b = min(max(0.0170827 * rl + 0.0723974 * gl + 0.9105199 * bl, 0), 1)
                    let o = idx * 4
                    ptr[o]     = UInt8((toPerc(p3r) * 255.0).rounded())
                    ptr[o + 1] = UInt8((toPerc(p3g) * 255.0).rounded())
                    ptr[o + 2] = UInt8((toPerc(p3b) * 255.0).rounded())
                    ptr[o + 3] = 255
                }
            }
        }

        // 2) 通过 macOS ColorSync CMM 往返目标 ICC：Source -> Target ICC -> sRGB
        let targetCG = resolveColorSpace(id: config.profileID)
        guard let nsTargetCS = NSColorSpace(cgColorSpace: targetCG),
              let nsSRGB = NSColorSpace(cgColorSpace: Engine.srgb) else { return nil }

        let inTarget = taggedRep.converting(to: nsTargetCS, renderingIntent: config.intent.nsIntent)
        let roundTripped = inTarget?.converting(to: nsSRGB, renderingIntent: .relativeColorimetric)
        guard let rt = roundTripped, let rtPtr = rt.bitmapData else { return nil }

        let rtBpp = rt.bitsPerPixel / 8
        let rtBpr = rt.bytesPerRow
        let isCMYK = targetCG.model == .cmyk
        let gamutThreshold = isCMYK ? 0.048 : 0.036

        var out = [Float](repeating: 0, count: D * D * D * 4)
        for bi in 0..<D {
            for gi in 0..<D {
                for ri in 0..<D {
                    let idx = bi * D * D + gi * D + ri
                    let y = idx / w, x = idx % w
                    let off = y * rtBpr + x * rtBpp
                    var pr = Double(rtPtr[off]) / 255.0
                    var pg = Double(rtPtr[off + 1]) / 255.0
                    var pb = Double(rtPtr[off + 2]) / 255.0

                    let oR = origSRGB[idx * 3]
                    let oG = origSRGB[idx * 3 + 1]
                    let oB = origSRGB[idx * 3 + 2]
                    let delta = sqrt((pr - oR) * (pr - oR) + (pg - oG) * (pg - oG) + (pb - oB) * (pb - oB))

                    // 模拟纸白与墨黑（压缩极端黑位 Dmax 并将纸白柔和偏暖）
                    if config.simulatePaperAndInk {
                        let dMaxLift = isCMYK ? 0.045 : 0.022
                        let whiteR = isCMYK ? 0.945 : 0.972
                        let whiteG = isCMYK ? 0.938 : 0.968
                        let whiteB = isCMYK ? 0.915 : 0.954
                        pr = dMaxLift + pr * (whiteR - dMaxLift)
                        pg = dMaxLift + pg * (whiteG - dMaxLift)
                        pb = dMaxLift + pb * (whiteB - dMaxLift)
                    }

                    // 目标色域超限警告：将超出色域的格点高亮为青蓝色（与常规红/蓝溢出警示清晰区分）
                    if config.gamutWarning && delta > gamutThreshold {
                        let strength = min(max((delta - gamutThreshold) / 0.06, 0.35), 0.92)
                        pr = pr * (1 - strength) + 0.04 * strength
                        pg = pg * (1 - strength) + 0.86 * strength
                        pb = pb * (1 - strength) + 0.96 * strength
                    }

                    let o = idx * 4
                    out[o]     = Float(toLin(pr))
                    out[o + 1] = Float(toLin(pg))
                    out[o + 2] = Float(toLin(pb))
                    out[o + 3] = 1
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }
}

#if !PHOS_TESTING || PHOS_APP_TESTING
// MARK: - 画布顶部软打样控制条
struct SoftProofBannerView: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var profiles: [SoftProofEngine.ProfileChoice] = SoftProofEngine.availableProfiles()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "printer.filled.and.paper")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkspaceTokens.accent)
            Text(L10n.tr("软打样"))
                .font(.system(size: 11, weight: .semibold))

            Picker("", selection: $s.softProof.profileID) {
                ForEach(profiles) { p in
                    Text(L10n.tr(p.name)).tag(p.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 165)

            Picker("", selection: $s.softProof.intent) {
                ForEach(SoftProofIntent.allCases, id: \.self) { it in
                    Text(L10n.tr(it.label)).tag(it)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 112)

            Toggle(L10n.tr("纸墨"), isOn: $s.softProof.simulatePaperAndInk)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))
                .help(L10n.tr("模拟纸张白点与油墨黑位动态范围"))

            Toggle(L10n.tr("色域警示"), isOn: $s.softProof.gamutWarning)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))
                .help(L10n.tr("用青色标出超出目标配置文件色域的区域"))

            Button(L10n.tr("导入 ICC…")) {
                s.importICCProfile {
                    profiles = SoftProofEngine.availableProfiles()
                }
            }
            .controlSize(.small)

            Button {
                s.softProof.enabled = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("退出软打样 (⇧S)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
        .onAppear { profiles = SoftProofEngine.availableProfiles() }
    }
}
#endif
