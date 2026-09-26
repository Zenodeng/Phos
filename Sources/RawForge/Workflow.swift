import Foundation
import CoreImage

struct EditSnapshot: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var created = Date()
    var params: EditParams
}

enum ExportColorSpace: String, Codable, CaseIterable {
    case sRGB, displayP3, adobeRGB
    var label: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB (1998)"
        }
    }
    var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: return Engine.srgb
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        }
    }
}

enum MaskTool: String, CaseIterable {
    case position, paint, erase
    var symbol: String {
        switch self {
        case .position: return "move.3d"
        case .paint: return "paintbrush.pointed"
        case .erase: return "eraser"
        }
    }
    var label: String {
        switch self {
        case .position: return "定位与取样"
        case .paint: return "添加选区"
        case .erase: return "擦除选区"
        }
    }
}

enum EditGroup: String, CaseIterable, Identifiable {
    case whiteBalance, tone, color, detail, effects, lens, geometry, masks
    var id: Self { self }
    static let defaults: Set<EditGroup> = [.whiteBalance, .tone, .color, .detail, .effects, .lens]
    var label: String {
        switch self {
        case .whiteBalance: return "白平衡"
        case .tone: return "曝光与明暗"
        case .color: return "曲线、色彩与胶片"
        case .detail: return "锐化与降噪"
        case .effects: return "颗粒、暗角与光晕"
        case .lens: return "色差与紫边"
        case .geometry: return "裁剪、旋转与透视"
        case .masks: return "局部蒙版与散景"
        }
    }

    static func applying(_ source: EditParams, to target: EditParams, groups: Set<EditGroup>) -> EditParams {
        var p = target
        if groups.contains(.whiteBalance) {
            p.temperature = source.temperature; p.tint = source.tint
            p.whiteBalanceGains = source.whiteBalanceGains
        }
        if groups.contains(.tone) {
            p.exposure = source.exposure; p.contrast = source.contrast
            p.highlights = source.highlights; p.shadows = source.shadows
            p.whites = source.whites; p.blacks = source.blacks
            p.clarity = source.clarity; p.texture = source.texture; p.dehaze = source.dehaze
            p.hdrMode = source.hdrMode; p.hdrLimit = source.hdrLimit
        }
        if groups.contains(.color) {
            p.vibrance = source.vibrance; p.saturation = source.saturation
            p.curve = source.curve; p.lumaCurve = source.lumaCurve
            p.curveR = source.curveR; p.curveG = source.curveG; p.curveB = source.curveB
            p.refineSat = source.refineSat; p.hsl = source.hsl
            p.gradeShadow = source.gradeShadow; p.gradeMid = source.gradeMid; p.gradeHigh = source.gradeHigh
            p.gradeBlend = source.gradeBlend; p.gradeBalance = source.gradeBalance
            p.mono = source.mono; p.monoRed = source.monoRed; p.monoGreen = source.monoGreen; p.monoBlue = source.monoBlue
            p.primRed = source.primRed; p.primGreen = source.primGreen; p.primBlue = source.primBlue
            p.calibShadowTint = source.calibShadowTint
            p.clutName = source.clutName; p.clutStrength = source.clutStrength
        }
        if groups.contains(.detail) {
            p.sharpen = source.sharpen; p.sharpenRadius = source.sharpenRadius
            p.sharpenDetail = source.sharpenDetail; p.sharpenMask = source.sharpenMask
            p.denoise = source.denoise; p.denoiseColor = source.denoiseColor
        }
        if groups.contains(.effects) {
            p.grain = source.grain; p.grainSize = source.grainSize
            p.vignette = source.vignette; p.vignetteStart = source.vignetteStart
            p.halation = source.halation; p.halationRadius = source.halationRadius; p.halationThreshold = source.halationThreshold
        }
        if groups.contains(.lens) { p.caAmount = source.caAmount; p.purpleFringe = source.purpleFringe }
        if groups.contains(.geometry) {
            p.rotation = source.rotation; p.flipped = source.flipped; p.straighten = source.straighten
            p.cropX = source.cropX; p.cropY = source.cropY; p.cropW = source.cropW; p.cropH = source.cropH
            p.perspectiveAuto = source.perspectiveAuto; p.perspectiveV = source.perspectiveV; p.perspectiveH = source.perspectiveH
        }
        if groups.contains(.masks) {
            p.masks = source.masks.map { original in
                var mask = original
                mask.id = UUID()
                return mask
            }
            p.bokehAmount = source.bokehAmount
        }
        return p
    }
}

struct BatchEditResult {
    var succeeded: [URL] = []
    var failures: [String] = []
}

enum BatchEditor {
    static func apply(_ params: EditParams, to urls: [URL], groups: Set<EditGroup>) -> BatchEditResult {
        var result = BatchEditResult()
        guard !groups.isEmpty else { return result }
        for url in urls {
            do {
                var sidecar = try SidecarStore.read(for: url) ?? Sidecar(params: EditParams())
                sidecar.snapshots.append(EditSnapshot(name: "批量同步前", params: sidecar.params))
                sidecar.params = EditGroup.applying(params, to: sidecar.params, groups: groups)
                try SidecarStore.write(sidecar, for: url)
                result.succeeded.append(url)
            } catch {
                result.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return result
    }
}

extension Engine {
    /// Coordinates are normalized in the oriented, geometrically corrected image, with y pointing up.
    static func sampledWhiteBalance(_ source: CIImage, params: EditParams, point: CGPoint) -> [Double]? {
        let image = geometry(source, params)
        let e = image.extent
        guard !e.isEmpty, point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
        let radius = max(2, min(e.width, e.height) * 0.004)
        let region = CGRect(x: e.minX + point.x * e.width - radius,
                            y: e.minY + point.y * e.height - radius,
                            width: radius * 2, height: radius * 2).intersection(e)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var rgba = [Float](repeating: 0, count: 4)
        ctx.render(average, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let rgb = rgba.prefix(3).map(Double.init)
        guard rgb.allSatisfy({ $0.isFinite && $0 > 0.005 && $0 < 0.98 }) else { return nil }
        let luminance = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        let gains = rgb.map { luminance / $0 }
        guard gains.allSatisfy({ (0.125...8).contains($0) }) else { return nil }
        return gains
    }
}

@MainActor
extension AppState {
    func recomputeMask(_ id: UUID) {
        guard let index = params.masks.firstIndex(where: { $0.id == id }) else { return }
        var next = params
        next.masks[index].id = UUID()
        Engine.invalidateAIMask(id: id)
        commit(next)
        selectedMask = next.masks[index].id
    }

    func copyAdjustments() {
        guard source != nil else { return }
        copiedParams = params
        copiedName = current?.url.lastPathComponent ?? ""
        status = "已复制 \(copiedName) 的调整"
    }

    func synchronize(_ parameters: EditParams, to urls: [URL], groups: Set<EditGroup>) async {
        guard !syncRunning, !groups.isEmpty, !urls.isEmpty, saveCurrent() else { return }
        syncRunning = true
        let result = await Task.detached(priority: .userInitiated) {
            BatchEditor.apply(parameters, to: urls, groups: groups)
        }.value
        syncRunning = false
        if let url = current?.url, result.succeeded.contains(url), let saved = SidecarStore.load(for: url) {
            snapshots = saved.snapshots
            params = saved.params
            history.push(params)
            selectedMask = nil
            render()
        }
        status = "已同步 \(result.succeeded.count) 张，失败 \(result.failures.count) 张"
        if !result.failures.isEmpty { workflowError = result.failures.joined(separator: "\n") }
    }

    func createSnapshot(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source != nil, !name.isEmpty else { return }
        snapshots.append(EditSnapshot(name: String(name.prefix(120)), params: params))
        if !saveCurrent() { snapshots.removeLast() }
    }

    func renameSnapshot(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        let previous = snapshots[index].name
        snapshots[index].name = String(name.prefix(120))
        if !saveCurrent() { snapshots[index].name = previous }
    }

    func deleteSnapshot(_ id: UUID) {
        let previous = snapshots
        snapshots.removeAll { $0.id == id }
        if !saveCurrent() { snapshots = previous }
    }

    func restoreSnapshot(_ id: UUID) {
        guard let snapshot = snapshots.first(where: { $0.id == id }) else { return }
        selectedMask = nil
        commit(snapshot.params)
        status = "已恢复快照：\(snapshot.name)"
    }

    func sampleWhiteBalance(at point: CGPoint) {
        guard let source, !whiteBalanceRunning, !previewing else { return }
        let captured = params, photoID = current?.id
        whiteBalanceRunning = true
        whiteBalancePicker = false
        Task {
            let gains = await Task.detached(priority: .userInitiated) {
                autoreleasepool { Engine.sampledWhiteBalance(source, params: captured, point: point) }
            }.value
            whiteBalanceRunning = false
            guard photoID == current?.id, params == captured else { return }
            guard let gains else {
                status = "取样无效：请避开过曝、纯黑和强烈彩色区域"
                return
            }
            var next = captured
            next.whiteBalanceGains = gains
            next.temperature = 0; next.tint = 0
            commit(next)
            status = "已按灰点校正白平衡"
        }
    }
}
