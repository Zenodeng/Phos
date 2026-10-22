import SwiftUI

/// UI metadata reads the real model defaults. It never supplies engine defaults.
struct ParameterDescriptor: Identifiable {
    let id: String
    let label: String
    let keyPath: WritableKeyPath<EditParams, Double>
    let range: ClosedRange<Double>
    let group: String
    var unit = ""
    var decimals = 0
    var step = 1.0
    var response = 1.0
    var defaultValue: Double { EditParams()[keyPath: keyPath] }
    func isModified(_ params: EditParams) -> Bool { params[keyPath: keyPath] != defaultValue }
    static let all: [Self] = [
        .init(id:"temperature",label:"色温",keyPath:\.temperature,range:-100...100,group:"白平衡"),
        .init(id:"tint",label:"色调",keyPath:\.tint,range:-100...100,group:"白平衡"),
        .init(id:"exposure",label:"曝光",keyPath:\.exposure,range:-5...5,group:"基本",unit:"EV",decimals:2,step:0.01),
        .init(id:"contrast",label:"对比度",keyPath:\.contrast,range:-100...100,group:"基本",response:1.8),
        .init(id:"highlights",label:"高光",keyPath:\.highlights,range:-100...100,group:"基本"),
        .init(id:"shadows",label:"阴影",keyPath:\.shadows,range:-100...100,group:"基本"),
        .init(id:"whites",label:"白色",keyPath:\.whites,range:-100...100,group:"基本"),
        .init(id:"blacks",label:"黑色",keyPath:\.blacks,range:-100...100,group:"基本"),
        .init(id:"texture",label:"纹理",keyPath:\.texture,range:-100...100,group:"质感与饱和度"),
        .init(id:"clarity",label:"清晰度",keyPath:\.clarity,range:0...100,group:"质感与饱和度"),
        .init(id:"dehaze",label:"去朦胧",keyPath:\.dehaze,range:-100...100,group:"质感与饱和度"),
        .init(id:"vibrance",label:"鲜艳度",keyPath:\.vibrance,range:-100...100,group:"质感与饱和度"),
        .init(id:"saturation",label:"饱和度",keyPath:\.saturation,range:-100...100,group:"质感与饱和度"),
        .init(id:"hdrLimit",label:"HDR 极限",keyPath:\.hdrLimit,range:0...100,group:"质感与饱和度"),
        .init(id:"refineSat",label:"饱和度补偿",keyPath:\.refineSat,range:0...100,group:"曲线"),
        .init(id:"gradeBlend",label:"混合",keyPath:\.gradeBlend,range:0...100,group:"颜色分级"),
        .init(id:"gradeBalance",label:"平衡",keyPath:\.gradeBalance,range:-100...100,group:"颜色分级"),
        .init(id:"monoRed",label:"红",keyPath:\.monoRed,range:0...1,group:"黑白",decimals:2,step:0.01),
        .init(id:"monoGreen",label:"绿",keyPath:\.monoGreen,range:0...1,group:"黑白",decimals:2,step:0.01),
        .init(id:"monoBlue",label:"蓝",keyPath:\.monoBlue,range:0...1,group:"黑白",decimals:2,step:0.01),
        .init(id:"sharpen",label:"锐化",keyPath:\.sharpen,range:0...2,group:"细节",decimals:2,step:0.01),
        .init(id:"sharpenRadius",label:"半径",keyPath:\.sharpenRadius,range:0.3...3,group:"细节",unit:"px",decimals:2,step:0.01),
        .init(id:"sharpenDetail",label:"细节",keyPath:\.sharpenDetail,range:0...1,group:"细节",decimals:2,step:0.01),
        .init(id:"sharpenMask",label:"边缘蒙版",keyPath:\.sharpenMask,range:0...100,group:"细节"),
        .init(id:"denoise",label:"明度降噪",keyPath:\.denoise,range:0...100,group:"细节"),
        .init(id:"denoiseColor",label:"颜色降噪",keyPath:\.denoiseColor,range:0...100,group:"细节"),
        .init(id:"grain",label:"颗粒",keyPath:\.grain,range:0...100,group:"细节"),
        .init(id:"grainSize",label:"颗粒大小",keyPath:\.grainSize,range:0...1,group:"细节",decimals:2,step:0.01),
        .init(id:"vignette",label:"暗角",keyPath:\.vignette,range:-100...100,group:"效果"),
        .init(id:"vignetteStart",label:"暗角范围",keyPath:\.vignetteStart,range:0...1,group:"效果",decimals:2,step:0.01),
        .init(id:"halation",label:"光晕",keyPath:\.halation,range:0...100,group:"效果"),
        .init(id:"halationThreshold",label:"高光阈值",keyPath:\.halationThreshold,range:0...100,group:"效果"),
        .init(id:"halationRadius",label:"光晕半径",keyPath:\.halationRadius,range:0...1,group:"效果",decimals:2,step:0.01),
        .init(id:"bokehAmount",label:"强度",keyPath:\.bokehAmount,range:0...100,group:"焦外散景"),
        .init(id:"caAmount",label:"色差",keyPath:\.caAmount,range:-100...100,group:"镜头校正"),
        .init(id:"purpleFringe",label:"紫边",keyPath:\.purpleFringe,range:0...100,group:"镜头校正"),
        .init(id:"calibShadowTint",label:"阴影色",keyPath:\.calibShadowTint,range:-100...100,group:"校准"),
        .init(id:"clutStrength",label:"浓度",keyPath:\.clutStrength,range:0...1,group:"胶片 CLUT",decimals:2,step:0.01),
        .init(id:"straighten",label:"矫正",keyPath:\.straighten,range:-15...15,group:"变换与裁剪",unit:"°",decimals:2,step:0.01),
        .init(id:"perspectiveV",label:"垂直透视",keyPath:\.perspectiveV,range:-100...100,group:"变换与裁剪"),
        .init(id:"perspectiveH",label:"水平透视",keyPath:\.perspectiveH,range:-100...100,group:"变换与裁剪"),
        .init(id:"cropX",label:"裁左",keyPath:\.cropX,range:0...1,group:"变换与裁剪",decimals:2,step:0.01),
        .init(id:"cropY",label:"裁上",keyPath:\.cropY,range:0...1,group:"变换与裁剪",decimals:2,step:0.01),
        .init(id:"cropW",label:"宽",keyPath:\.cropW,range:0.1...1,group:"变换与裁剪",decimals:2,step:0.01),
        .init(id:"cropH",label:"高",keyPath:\.cropH,range:0.1...1,group:"变换与裁剪",decimals:2,step:0.01)
    ]
    static func named(_ id: String) -> Self { all.first { $0.id == id }! }
}

enum ParameterGroupSchema {
    static let titles = ["白平衡","基本","质感与饱和度","曲线","颜色分级","HSL · 混色","黑白","细节","效果","焦外散景","镜头校正","校准","胶片 CLUT","变换与裁剪","局部调整（蒙版）"]
    static func reset(_ group: String, in original: EditParams) -> EditParams {
        var p = original; let d = EditParams()
        for field in ParameterDescriptor.all where field.group == group { p[keyPath:field.keyPath] = field.defaultValue }
        switch group {
        case "白平衡": p.whiteBalanceGains = d.whiteBalanceGains
        case "质感与饱和度": p.hdrMode = d.hdrMode
        case "曲线": p.curve = d.curve; p.lumaCurve = d.lumaCurve; p.curveR = d.curveR; p.curveG = d.curveG; p.curveB = d.curveB
        case "颜色分级": p.gradeShadow = d.gradeShadow; p.gradeMid = d.gradeMid; p.gradeHigh = d.gradeHigh
        case "HSL · 混色": p.hsl = d.hsl
        case "黑白": p.mono = d.mono
        case "校准": p.primRed = d.primRed; p.primGreen = d.primGreen; p.primBlue = d.primBlue
        case "胶片 CLUT": p.clutName = d.clutName
        case "变换与裁剪": p.rotation = d.rotation; p.flipped = d.flipped; p.perspectiveAuto = d.perspectiveAuto
        case "局部调整（蒙版）": p.masks = []
        default: break
        }
        return p
    }
    static func modified(_ group: String, in p: EditParams) -> Bool { reset(group,in:p) != p }
}

/// One photo-bound transaction, shared by numbers, sliders, curves and wheels.
/// Command invalidation runs before the command; a late native blur cannot undo it.
@MainActor final class ParameterEditCoordinator {
    struct Token: Equatable { let id = UUID(); let photoID: UUID?; let generation: UInt }
    private weak var state: AppState?
    private(set) var generation: UInt = 0
    private(set) var token: Token?
    private var initial: EditParams?
    private var finish: (() -> Void)?
    private var cancel: (() -> Void)?
    init(state: AppState) { self.state = state }
    func begin(finish: (() -> Void)? = nil, cancel: (() -> Void)? = nil) -> Token {
        finishCurrent()
        let next = Token(photoID:state?.current?.id,generation:generation)
        token = next; initial = state?.params; self.finish = finish; self.cancel = cancel
        state?.pendingPhotoEditID = next.id
        state?.finishPendingPhotoEdit = { [weak self] in self?.finishCurrent() }
        return next
    }
    func valid(_ candidate: Token?) -> Bool {
        guard let candidate, candidate == token, candidate.generation == generation else { return false }
        return state?.current?.id == candidate.photoID
    }
    @discardableResult func complete(_ candidate: Token?) -> Bool {
        guard valid(candidate) else { return false }; clear(); return true
    }
    func finishCurrent() {
        guard token != nil else { return }
        if let finish { finish() }
        else { clear(); state?.endEdit() }
        // Invalid numeric drafts are cancelled when leaving their context.
        if token != nil { invalidate() }
    }
    func invalidate() {
        let original = initial, callback = cancel
        let changed = original != nil && original != state?.params
        clear(); generation &+= 1
        state?.parameterInputGeneration = generation
        if changed, let original { state?.params = original; state?.render() }
        callback?()
    }
    private func clear() {
        token = nil; initial = nil; finish = nil; cancel = nil
        state?.pendingPhotoEditID = nil; state?.finishPendingPhotoEdit = nil
    }
}

struct WorkspacePhotoParameter: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    let id: String
    @EnvironmentObject private var s: AppState
    var body: some View {
        let d = ParameterDescriptor.named(id)
        SliderRow(label:d.label,value:bind(d.keyPath,s),range:d.range,response:d.response,
                  defaultValue:d.defaultValue,unit:d.unit,decimals:d.decimals,step:d.step) { s.endEdit() }
    }
}

/// UI-only context survives switching tabs, themes and hosting carriers.
@MainActor final class WorkspaceInspectorState: ObservableObject {
    @Published var category: InspectorCategory = .light
    @Published var expanded: [String:Bool] = [:]
    @Published var curveChannel = 0
    @Published var gradeBand = 1
    @Published var calibrationBand = 0
    @Published var hslBand = 0
    @Published var clutQuery = ""
    @Published var showPresets = false
    @Published var showInformation = false
    func isExpanded(_ title: String) -> Bool { expanded[title] ?? true }
}
