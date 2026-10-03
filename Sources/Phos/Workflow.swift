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
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3) ?? Engine.srgb
        case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998) ?? Engine.srgb
        }
    }
}

/// 一次控制点拖动的会话。
///
/// 拖动过程中蒙版会被不断改写，而 `DragGesture` 给的是「从按下那一刻算起的累计位移」。
/// 如果每次都拿「当前蒙版」去叠加这个累计位移，位移会被反复累加 ——
/// 鼠标拖 120px，控制点能跑 240px 甚至上千 px，参考线看上去就是飘走了。
/// 所以这里固定住「按下点 + 按下那一刻的蒙版」，每次都用绝对坐标重新算。
struct MaskDragSession {
    let start: CGPoint
    let base: Mask

    init(start: CGPoint, base: Mask) {
        self.start = start
        self.base = base
    }

    func updated(_ control: MaskGeometry.Control, to end: CGPoint, size: CGSize,
                 constrained: Bool = false) -> Mask {
        MaskGeometry.dragging(base, control: control, from: start, to: end,
                              size: size, constrained: constrained)
    }
}

/// Geometry is computed in oriented image pixels (y up), not in a square normalized space.
/// The canvas, numeric controls and gesture tests use the same conversions.
enum MaskGeometry {
    enum Control { case move, linearStart, linearEnd, rotate, radialX, radialY, feather }

    // 蒙版参数一律是 Double，而 CGPoint / CGSize 是 CGFloat。两者混算时 cos/sin/atan2
    // 会同时匹配 CoreGraphics 的 CGFloat 版与 _math 的 Double 版，在完整 Xcode SDK 上
    // 会报 “ambiguous use of 'cos'”（命令行工具 SDK 反而能过）。所以本模块内部一律
    // 先转成 Double 计算，只在进出 CG* 的边界上转回 CGFloat。
    static func point(_ x: Double, _ y: Double, size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
    }
    static func center(_ mask: Mask, size: CGSize) -> CGPoint {
        mask.kind == .linear
            ? point((mask.x0 + mask.x1) / 2, (mask.y0 + mask.y1) / 2, size: size)
            : point(mask.x0, mask.y0, size: size)
    }
    static func angle(_ mask: Mask, size: CGSize) -> Double {
        if mask.kind == .radial { return mask.radialAngle }
        return atan2((mask.y1 - mask.y0) * Double(size.height),
                     (mask.x1 - mask.x0) * Double(size.width)) * 180 / Double.pi
    }
    static func width(_ mask: Mask, size: CGSize) -> Double {
        hypot((mask.x1 - mask.x0) * Double(size.width), (mask.y1 - mask.y0) * Double(size.height))
            / max(min(Double(size.width), Double(size.height)), 1)
    }
    static func radii(_ mask: Mask, size: CGSize) -> CGSize {
        let base = max(min(Double(size.width), Double(size.height)), 1)
        let outer = mask.gradientVersion == 1 ? 1 : 1 + mask.feather * 0.5
        return CGSize(width: CGFloat(base * (mask.radiusX ?? mask.radius) * outer),
                      height: CGFloat(base * (mask.radiusY ?? mask.radius) * outer))
    }
    static func innerRatio(_ mask: Mask) -> Double {
        mask.gradientVersion == 1 ? 1 - mask.feather : (1 - mask.feather) / (1 + mask.feather * 0.5)
    }
    /// Convert a legacy circle only on explicit geometry editing, preserving its inner/outer edges.
    static func ellipse(_ mask: Mask) -> Mask {
        guard mask.gradientVersion != 1 else { return mask }
        var result = mask
        let outer = 1 + mask.feather * 0.5
        result.radiusX = mask.radius * outer
        result.radiusY = mask.radius * outer
        result.feather = 1 - (1 - mask.feather) / outer
        result.gradientVersion = 1
        return result
    }
    static func rotatedPoint(center: CGPoint, x: Double, y: Double, angle: Double) -> CGPoint {
        let a = angle * Double.pi / 180
        return CGPoint(x: center.x + CGFloat(x * cos(a) - y * sin(a)),
                       y: center.y + CGFloat(x * sin(a) + y * cos(a)))
    }
    static func settingLinear(_ mask: Mask, width: Double? = nil, angle: Double? = nil,
                              size: CGSize) -> Mask {
        var result = mask
        let c = center(mask, size: size)
        let a = (angle ?? Self.angle(mask, size: size)) * Double.pi / 180
        let short = min(Double(size.width), Double(size.height))
        let half = max(0.003, width ?? Self.width(mask, size: size)) * short / 2
        result.x0 = (Double(c.x) - half * cos(a)) / Double(size.width)
        result.y0 = (Double(c.y) - half * sin(a)) / Double(size.height)
        result.x1 = (Double(c.x) + half * cos(a)) / Double(size.width)
        result.y1 = (Double(c.y) + half * sin(a)) / Double(size.height)
        return result
    }
    private static func imagePoint(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: p.x, y: size.height - p.y)
    }

    static func drawing(_ original: Mask, from start: CGPoint, to end: CGPoint,
                        size: CGSize, constrained: Bool = false) -> Mask {
        let start = imagePoint(start, size: size)
        let end = imagePoint(end, size: size)
        var result = original
        result.gradientVersion = 1
        let w = Double(size.width), h = Double(size.height)
        if original.kind == .linear {
            var dx = Double(end.x - start.x), dy = Double(end.y - start.y)
            if constrained {
                let length = hypot(dx, dy)
                let snap = (atan2(dy, dx) / (Double.pi / 4)).rounded() * (Double.pi / 4)
                dx = cos(snap) * length; dy = sin(snap) * length
            }
            result.x0 = Double(start.x) / w; result.y0 = Double(start.y) / h
            result.x1 = (Double(start.x) + dx) / w; result.y1 = (Double(start.y) + dy) / h
        } else {
            result.x0 = Double(start.x) / w; result.y0 = Double(start.y) / h
            let base = min(w, h)
            var rx = abs(Double(end.x - start.x)) / base, ry = abs(Double(end.y - start.y)) / base
            if constrained { rx = max(rx, ry); ry = rx }
            result.radiusX = min(max(rx, 0.003), 4)
            result.radiusY = min(max(ry, 0.003), 4)
            result.radialAngle = 0
        }
        return result
    }
    static func dragging(_ original: Mask, control: Control, from start: CGPoint, to end: CGPoint,
                         size: CGSize, constrained: Bool = false) -> Mask {
        let start = imagePoint(start, size: size)
        let end = imagePoint(end, size: size)
        var result = original
        // 手势坐标来自 CGPoint（CGFloat），蒙版参数一律是 Double。两边混算时 cos/sin 会同时
        // 匹配 CoreGraphics 的 CGFloat 版和 _math 的 Double 版，在完整 Xcode SDK 上会报
        // “ambiguous use of 'cos'”。所以这里先把像素量统一转成 Double 再算。
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let c = center(original, size: size)
        switch control {
        case .move:
            // Keep the shape intact at image edges; bounded off-canvas centers are useful for vignettes.
            let tx = min(max(dx / Double(size.width), -2 - original.x0), 3 - original.x0)
            let ty = min(max(dy / Double(size.height), -2 - original.y0), 3 - original.y0)
            result.x0 += tx; result.y0 += ty
            if original.kind == .linear { result.x1 += tx; result.y1 += ty }
        case .linearStart, .linearEnd:
            let a = angle(original, size: size) * Double.pi / 180
            let projection = dx * cos(a) + dy * sin(a)
            let shiftX = projection * cos(a) / Double(size.width)
            let shiftY = projection * sin(a) / Double(size.height)
            if control == .linearStart { result.x0 += shiftX; result.y0 += shiftY }
            else { result.x1 += shiftX; result.y1 += shiftY }
            if width(result, size: size) < 0.003 { return original }
        case .rotate:
            let initial = atan2(Double(start.y - c.y), Double(start.x - c.x))
            let current = atan2(Double(end.y - c.y), Double(end.x - c.x))
            var degrees = angle(original, size: size) + (current - initial) * 180 / Double.pi
            if constrained { degrees = (degrees / 15).rounded() * 15 }
            if original.kind == .linear { result = settingLinear(original, angle: degrees, size: size) }
            else { result = ellipse(original); result.radialAngle = degrees }
        case .radialX, .radialY, .feather:
            result = ellipse(original)
            let a = result.radialAngle * Double.pi / 180
            let ex = Double(end.x - c.x), ey = Double(end.y - c.y)
            let lx = ex * cos(a) + ey * sin(a)
            let ly = -ex * sin(a) + ey * cos(a)
            let base = Double(min(size.width, size.height))
            if control == .radialX { result.radiusX = min(max(abs(lx) / base, 0.003), 4) }
            if control == .radialY { result.radiusY = min(max(abs(ly) / base, 0.003), 4) }
            if constrained, control != .feather {
                let radius = control == .radialX ? result.radiusX : result.radiusY
                result.radiusX = radius; result.radiusY = radius
            }
            if control == .feather {
                let rx = max((result.radiusX ?? result.radius) * base, 1)
                let ry = max((result.radiusY ?? result.radius) * base, 1)
                result.feather = min(max(1 - hypot(lx / rx, ly / ry), 0), 1)
            }
        }
        return result
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
                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? Engine.srgb)
        let rgb = rgba.prefix(3).map(Double.init)
        guard rgb.allSatisfy({ $0.isFinite && $0 > 0.005 && $0 < 0.98 }) else { return nil }
        let luminance = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        let gains = rgb.map { luminance / $0 }
        guard gains.allSatisfy({ (0.125...8).contains($0) }) else { return nil }
        return gains
    }
}

#if !PHOS_TESTING
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
#endif
