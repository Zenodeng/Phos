import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 蒙版布尔组合（加 / 减 / 交）、子蒙版参数展开与编辑、AI 边缘精修、Sky 模型管理
/// 以及局部曲线 / 局部 OKLCH 点颜色 / 局部 CLUT 扩展控件（保持独立文件以加快 SwiftUI 编译并严控 <= 260pt 宽度）。
struct MaskAdvancedControls: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    let mask: Mask

    private var hasVisionMask: Bool {
        mask.kind.usesVision || mask.components.contains { $0.enabled && $0.kind.usesVision }
    }

    private var hasSkyMask: Bool {
        mask.kind == .sky || mask.components.contains { $0.kind == .sky }
    }

    private var combinableKinds: [MaskKind] {
        [.linear, .radial, .brush, .luminanceRange, .colorRange,
         .sky, .background, .subject, .person, .foreground,
         .faceSkin, .bodySkin, .eyes, .eyebrows, .lips, .teeth, .hair, .clothes]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if hasVisionMask {
                Toggle(L10n.tr("AI 边缘精修 (Guided Filter)"), isOn: Binding(
                    get: { mask.refineEdges },
                    set: { on in
                        var x = mask; x.refineEdges = on; s.updateMask(x)
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }

            if hasSkyMask {
                MaskSkyModelRow()
            }

            HStack(spacing: 4) {
                Text(L10n.tr("布尔子蒙版"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                ForEach(MaskBoolOp.allCases, id: \.self) { op in
                    Menu {
                        ForEach(combinableKinds, id: \.self) { kind in
                            Button {
                                var x = mask
                                var comp = MaskComponent(op: op, kind: kind)
                                if kind == .luminanceRange {
                                    comp.lumLow = 0.0; comp.lumHigh = 0.55
                                }
                                x.components.append(comp)
                                s.updateMask(x)
                                s.selectedMaskComponentID = comp.id
                            } label: {
                                Label(L10n.tr(kind.label), systemImage: kind.icon)
                            }
                        }
                    } label: {
                        Image(systemName: op.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 20, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.tr(op.label))
                    .accessibilityLabel(L10n.tr(op.label))
                }
            }

            if !mask.components.isEmpty {
                ForEach(Array(mask.components.enumerated()), id: \.element.id) { idx, comp in
                    MaskComponentRow(mask: mask, idx: idx, comp: comp)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MaskComponentRow: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    let mask: Mask
    let idx: Int
    let comp: MaskComponent

    private var isSelected: Bool { s.selectedMaskComponentID == comp.id }

    private func writeComp(_ next: MaskComponent, commit: Bool) {
        if commit {
            s.updateMaskComponent(maskID: mask.id, component: next)
        } else {
            s.updateMaskComponentLive(maskID: mask.id, component: next)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(MaskBoolOp.allCases, id: \.self) { op in
                        Button {
                            var c = comp; c.op = op
                            writeComp(c, commit: true)
                        } label: {
                            Label(L10n.tr(op.label), systemImage: op.symbol)
                        }
                    }
                } label: {
                    Image(systemName: comp.op.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WorkspaceTokens.accent)
                        .frame(width: 14, height: 14)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 16, height: 16)
                .help(L10n.tr("切换布尔运算"))

                Button {
                    s.selectedMaskComponentID = isSelected ? nil : comp.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: comp.kind.icon)
                            .font(.system(size: 9))
                            .foregroundStyle(isSelected ? WorkspaceTokens.accent : .secondary)
                        Text(L10n.tr(comp.kind.label))
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { comp.enabled },
                    set: { on in
                        var c = comp; c.enabled = on
                        writeComp(c, commit: true)
                    }
                ))
                .labelsHidden().controlSize(.mini)

                Button {
                    var c = comp; c.inverted.toggle()
                    writeComp(c, commit: true)
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 9))
                        .foregroundStyle(comp.inverted ? WorkspaceTokens.accent : .secondary)
                }
                .buttonStyle(WorkspaceButtonStyle()).controlSize(.mini)
                .help(L10n.tr("反转子蒙版"))

                Button {
                    var x = mask
                    x.components.removeAll { $0.id == comp.id }
                    if s.selectedMaskComponentID == comp.id { s.selectedMaskComponentID = nil }
                    s.updateMask(x)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5))
                }
                .buttonStyle(WorkspaceButtonStyle()).controlSize(.mini)
            }

            if isSelected {
                componentDetail
            } else if comp.kind == .luminanceRange {
                SliderRow(label: "下限", value: Binding(
                    get: { idx < mask.components.count ? mask.components[idx].lumLow : comp.lumLow },
                    set: { v in
                        var c = idx < mask.components.count ? mask.components[idx] : comp
                        c.lumLow = min(v, c.lumHigh)
                        writeComp(c, commit: false)
                    }
                ), range: 0...1, defaultValue: 0, decimals: 2, step: 0.02) { s.endEdit() }
                SliderRow(label: "上限", value: Binding(
                    get: { idx < mask.components.count ? mask.components[idx].lumHigh : comp.lumHigh },
                    set: { v in
                        var c = idx < mask.components.count ? mask.components[idx] : comp
                        c.lumHigh = max(v, c.lumLow)
                        writeComp(c, commit: false)
                    }
                ), range: 0...1, defaultValue: 0.55, decimals: 2, step: 0.02) { s.endEdit() }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? WorkspaceTokens.accent.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? WorkspaceTokens.accent.opacity(0.45) : Color.clear, lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var componentDetail: some View {
        let cur: MaskComponent = idx < mask.components.count ? mask.components[idx] : comp
        VStack(alignment: .leading, spacing: 3) {
            switch comp.kind {
            case .linear:
                Text(L10n.tr("可在画布直接拖动手柄调整渐变范围与方向"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .radial:
                SliderRow(label: "横半径", value: Binding(
                    get: { cur.radiusX ?? cur.radius },
                    set: { v in
                        var sub = MaskGeometry.ellipse(cur.asMask()); sub.radiusX = v
                        var c = cur; c.applyGeometry(from: sub); writeComp(c, commit: false)
                    }
                ), range: 0.05...1.5, defaultValue: 0.3) { s.endEdit() }
                SliderRow(label: "纵半径", value: Binding(
                    get: { cur.radiusY ?? cur.radius },
                    set: { v in
                        var sub = MaskGeometry.ellipse(cur.asMask()); sub.radiusY = v
                        var c = cur; c.applyGeometry(from: sub); writeComp(c, commit: false)
                    }
                ), range: 0.05...1.5, defaultValue: 0.3) { s.endEdit() }
                SliderRow(label: "旋转", value: Binding(
                    get: { cur.radialAngle },
                    set: { v in
                        var sub = MaskGeometry.ellipse(cur.asMask()); sub.radialAngle = v
                        var c = cur; c.applyGeometry(from: sub); writeComp(c, commit: false)
                    }
                ), range: -180...180, defaultValue: 0) { s.endEdit() }
                SliderRow(label: "羽化", value: Binding(
                    get: { cur.feather },
                    set: { v in
                        var c = cur; c.feather = v; writeComp(c, commit: false)
                    }
                ), range: 0...1, defaultValue: 0.6) { s.endEdit() }
            case .colorRange:
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: cur.sampleRGB[0], green: cur.sampleRGB[1], blue: cur.sampleRGB[2]))
                        .frame(width: 24, height: 15)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.25), lineWidth: 0.8))
                    Text(L10n.tr("拖动画面取色"))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                SliderRow(label: "容差", value: Binding(
                    get: { cur.tolerance },
                    set: { v in var c = cur; c.tolerance = v; writeComp(c, commit: false) }
                ), range: 0.02...0.8, defaultValue: 0.25) { s.endEdit() }
                SliderRow(label: "羽化", value: Binding(
                    get: { cur.feather },
                    set: { v in var c = cur; c.feather = v; writeComp(c, commit: false) }
                ), range: 0...1, defaultValue: 0.6) { s.endEdit() }
            case .luminanceRange:
                SliderRow(label: "下限", value: Binding(
                    get: { cur.lumLow },
                    set: { v in var c = cur; c.lumLow = min(v, c.lumHigh); writeComp(c, commit: false) }
                ), range: 0...1, defaultValue: 0, decimals: 2, step: 0.02) { s.endEdit() }
                SliderRow(label: "上限", value: Binding(
                    get: { cur.lumHigh },
                    set: { v in var c = cur; c.lumHigh = max(v, c.lumLow); writeComp(c, commit: false) }
                ), range: 0...1, defaultValue: 0.55, decimals: 2, step: 0.02) { s.endEdit() }
                SliderRow(label: "软边", value: Binding(
                    get: { cur.lumSoft },
                    set: { v in var c = cur; c.lumSoft = v; writeComp(c, commit: false) }
                ), range: 0.01...0.5, defaultValue: 0.15) { s.endEdit() }
            case .brush, .depth:
                HStack(spacing: 4) {
                    Text(L10n.tr("在画布涂抹子蒙版（\(cur.strokes.count) 笔）"))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !cur.strokes.isEmpty {
                        Button(L10n.tr("清空")) {
                            var c = cur; c.strokes = []
                            writeComp(c, commit: true)
                        }
                        .controlSize(.mini)
                    }
                }
                SliderRow(label: "笔刷", value: $s.brushRadius, range: 0.005...0.3, defaultValue: 0.05, photoScoped: false)
                if comp.kind == .brush {
                    Toggle(L10n.tr("自动边缘吸附"), isOn: $s.brushAutoMask)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10.5))
                }
                SliderRow(label: "羽化", value: Binding(
                    get: { cur.feather },
                    set: { v in var c = cur; c.feather = v; writeComp(c, commit: false) }
                ), range: 0...1, defaultValue: 0.6) { s.endEdit() }
            default:
                if comp.kind.usesVision {
                    HStack {
                        Button(L10n.tr("重算 AI 子蒙版")) {
                            s.recomputeMaskComponent(maskID: mask.id, componentID: comp.id)
                        }
                        .controlSize(.mini)
                        Spacer()
                    }
                }
            }
        }
    }
}

private struct MaskSkyModelRow: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var skyInstalled = CoreMLSkyEngine.shared.isModelInstalled
    @State private var skyStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: skyInstalled ? "cpu.fill" : "cpu")
                    .font(.system(size: 9))
                    .foregroundStyle(skyInstalled ? .green : .secondary)
                Text(L10n.tr(skyInstalled ? "Core ML 天空模型已就绪" : "内置零模型天空分割"))
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if skyInstalled {
                    Button(L10n.tr("移除")) {
                        do {
                            try CoreMLSkyEngine.shared.removeModel()
                            skyInstalled = CoreMLSkyEngine.shared.isModelInstalled
                            skyStatus = ""
                            s.render()
                        } catch {
                            skyStatus = error.localizedDescription
                        }
                    }
                    .controlSize(.mini)
                }
                Button(L10n.tr("导入…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [.package, .directory]
                    panel.message = L10n.tr("选择 SkySegmentation.mlpackage 或 .mlmodelc")
                    if panel.runModal() == .OK, let u = panel.url {
                        do {
                            try CoreMLSkyEngine.shared.installModel(from: u)
                            skyInstalled = CoreMLSkyEngine.shared.isModelInstalled
                            skyStatus = L10n.tr("已启用 Core ML 天空模型")
                            s.render()
                        } catch {
                            skyStatus = error.localizedDescription
                        }
                    }
                }
                .controlSize(.mini)
            }
            if !skyStatus.isEmpty {
                Text(skyStatus).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onAppear {
            skyInstalled = CoreMLSkyEngine.shared.isModelInstalled
        }
    }
}

struct MaskLocalExtraControls: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    let mask: Mask
    @State private var showCurveEditor = false

    private static let curvePresets: [(name: String, pts: [[Double]]?)] = [
        ("线性（无）", nil),
        ("柔和 S 曲线", [[0, 0], [0.25, 0.21], [0.75, 0.79], [1, 1]]),
        ("胶片褪色", [[0, 0.06], [0.25, 0.27], [0.75, 0.78], [1, 0.96]]),
        ("提亮中灰", [[0, 0], [0.5, 0.58], [1, 1]]),
        ("压暗高光", [[0, 0], [0.6, 0.56], [1, 0.90]])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SliderRow(label: "色相偏移", value: Binding(
                get: { mask.adjust.hueShift },
                set: { var x = mask; x.adjust.hueShift = $0; s.updateMaskLive(x) }
            ), range: -180...180, defaultValue: 0, unit: "°") { s.endEdit() }

            HStack(spacing: 4) {
                Text(L10n.tr("局部曲线"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    ForEach(Self.curvePresets, id: \.name) { preset in
                        Button(L10n.tr(preset.name)) {
                            var x = mask
                            if let pts = preset.pts {
                                var c = ToneCurve(); c.points = pts
                                x.adjust.curve = c
                            } else {
                                x.adjust.curve = nil
                            }
                            s.updateMask(x)
                        }
                    }
                } label: {
                    Text(L10n.tr(mask.adjust.curve == nil ? "线性（无）" : "已启用曲线"))
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 96, alignment: .trailing)

                Button {
                    showCurveEditor.toggle()
                } label: {
                    Image(systemName: showCurveEditor ? "chevron.up" : "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 10))
                }
                .buttonStyle(WorkspaceButtonStyle(selected: showCurveEditor))
                .controlSize(.mini)
                .help(L10n.tr("展开局部曲线编辑器"))
            }

            if showCurveEditor {
                VStack(spacing: 4) {
                    CurveEditor(points: Binding(
                        get: { mask.adjust.curve?.points ?? ToneCurve.identityPoints },
                        set: { pts in
                            var x = mask
                            let c = ToneCurve(points: pts)
                            x.adjust.curve = c.isIdentity ? nil : c
                            s.updateMaskLive(x)
                        }
                    ), color: WorkspaceTokens.accent) { s.endEdit() }
                    .frame(height: 144)

                    HStack {
                        Spacer()
                        Button(L10n.tr("复位局部曲线")) {
                            var x = mask; x.adjust.curve = nil; s.updateMask(x)
                        }
                        .controlSize(.mini)
                        .disabled(mask.adjust.curve == nil)
                    }
                }
                .padding(.vertical, 2)
            }

            MaskLocalPointColorSection(mask: mask)

            let cluts = s.cluts.list()
            HStack(spacing: 6) {
                Text(L10n.tr("局部 LUT"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(L10n.tr("无")) {
                        var x = mask; x.adjust.clutName = ""; s.updateMask(x)
                    }
                    ForEach(cluts.prefix(80), id: \.self) { name in
                        Button(name) {
                            var x = mask; x.adjust.clutName = name; s.updateMask(x)
                        }
                    }
                } label: {
                    Text(mask.adjust.clutName.isEmpty ? L10n.tr("无") : mask.adjust.clutName)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 120, alignment: .trailing)
            }
            if !mask.adjust.clutName.isEmpty {
                SliderRow(label: "LUT 浓度", value: Binding(
                    get: { mask.adjust.clutStrength },
                    set: { var x = mask; x.adjust.clutStrength = $0; s.updateMaskLive(x) }
                ), range: 0...1, defaultValue: 1.0, decimals: 2, step: 0.05) { s.endEdit() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MaskLocalPointColorSection: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    let mask: Mask

    private var pickingForThisMask: Bool {
        s.pointColorPicker && s.localPointColorMaskID == mask.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(L10n.tr("局部点颜色"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    s.parameterEdits.finishCurrent()
                    if pickingForThisMask {
                        s.pointColorPicker = false
                    } else {
                        s.localPointColorMaskID = mask.id
                        s.pointColorPicker = true
                    }
                } label: {
                    Label(L10n.tr(pickingForThisMask ? "取色中…" : "局部取色"),
                          systemImage: "eyedropper")
                        .font(.system(size: 10))
                }
                .buttonStyle(WorkspaceButtonStyle(prominent: pickingForThisMask))
                .controlSize(.mini)
                .disabled(s.source == nil || s.cropMode)
            }

            if let sw = mask.adjust.pointColor {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(
                            red: min(max(sw.sampleRGB.count > 0 ? sw.sampleRGB[0] : 0.5, 0), 1),
                            green: min(max(sw.sampleRGB.count > 1 ? sw.sampleRGB[1] : 0.5, 0), 1),
                            blue: min(max(sw.sampleRGB.count > 2 ? sw.sampleRGB[2] : 0.5, 0), 1)
                        ))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.primary.opacity(0.28), lineWidth: 0.8))
                    Toggle(L10n.tr("启用"), isOn: Binding(
                        get: { sw.enabled },
                        set: { on in
                            var x = mask; var copy = sw; copy.enabled = on
                            x.adjust.pointColor = copy; s.updateMask(x)
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    Spacer()
                    Button {
                        var x = mask; x.adjust.pointColor = nil; s.updateMask(x)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 9.5))
                    }
                    .buttonStyle(WorkspaceButtonStyle()).controlSize(.mini)
                    .help(L10n.tr("清除局部点颜色"))
                }

                SliderRow(label: "色相偏移", value: Binding(
                    get: { mask.adjust.pointColor?.hueShift ?? 0 },
                    set: { v in
                        var x = mask
                        if var copy = x.adjust.pointColor { copy.hueShift = v; x.adjust.pointColor = copy; s.updateMaskLive(x) }
                    }
                ), range: -180...180, defaultValue: 0, unit: "°") { s.endEdit() }

                SliderRow(label: "彩度偏移", value: Binding(
                    get: { mask.adjust.pointColor?.chromaShift ?? 0 },
                    set: { v in
                        var x = mask
                        if var copy = x.adjust.pointColor { copy.chromaShift = v; x.adjust.pointColor = copy; s.updateMaskLive(x) }
                    }
                ), range: -100...100, defaultValue: 0) { s.endEdit() }

                SliderRow(label: "明度偏移", value: Binding(
                    get: { mask.adjust.pointColor?.lumaShift ?? 0 },
                    set: { v in
                        var x = mask
                        if var copy = x.adjust.pointColor { copy.lumaShift = v; x.adjust.pointColor = copy; s.updateMaskLive(x) }
                    }
                ), range: -100...100, defaultValue: 0) { s.endEdit() }

                SliderRow(label: "总范围", value: Binding(
                    get: { mask.adjust.pointColor?.range ?? 0.4 },
                    set: { v in
                        var x = mask
                        if var copy = x.adjust.pointColor { copy.range = v; x.adjust.pointColor = copy; s.updateMaskLive(x) }
                    }
                ), range: 0.05...1.0, defaultValue: 0.4, decimals: 2, step: 0.01) { s.endEdit() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
