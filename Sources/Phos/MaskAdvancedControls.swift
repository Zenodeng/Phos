import SwiftUI

/// 蒙版布尔组合（加 / 减 / 交）、AI 边缘精修以及局部色彩/LUT/曲线扩展控件（从 Inspector.swift 拆出以保持编译速度）。
struct MaskAdvancedControls: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    let mask: Mask

    private var hasVisionMask: Bool {
        mask.kind.usesVision || mask.components.contains { $0.enabled && $0.kind.usesVision }
    }

    private var combinableKinds: [MaskKind] {
        [.linear, .radial, .luminanceRange, .colorRange,
         .sky, .background, .subject, .person, .foreground,
         .faceSkin, .eyes, .lips, .teeth, .hair]
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

            HStack(spacing: 4) {
                Text(L10n.tr("布尔子蒙版"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: comp.op.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(WorkspaceTokens.accent)
                                .frame(width: 14)
                            Image(systemName: comp.kind.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(L10n.tr(comp.kind.label))
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { comp.enabled },
                                set: { on in
                                    var x = mask
                                    guard idx < x.components.count else { return }
                                    x.components[idx].enabled = on
                                    s.updateMask(x)
                                }
                            ))
                            .labelsHidden().controlSize(.mini)
                            Button {
                                var x = mask
                                guard idx < x.components.count else { return }
                                x.components[idx].inverted.toggle()
                                s.updateMask(x)
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
                                s.updateMask(x)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8.5))
                            }
                            .buttonStyle(WorkspaceButtonStyle()).controlSize(.mini)
                        }
                        if comp.kind == .luminanceRange {
                            SliderRow(label: "下限", value: Binding(
                                get: { idx < mask.components.count ? mask.components[idx].lumLow : comp.lumLow },
                                set: { v in
                                    var x = mask
                                    guard idx < x.components.count else { return }
                                    x.components[idx].lumLow = min(v, x.components[idx].lumHigh)
                                    s.updateMaskLive(x)
                                }
                            ), range: 0...1, defaultValue: 0, decimals: 2, step: 0.02) { s.endEdit() }
                            SliderRow(label: "上限", value: Binding(
                                get: { idx < mask.components.count ? mask.components[idx].lumHigh : comp.lumHigh },
                                set: { v in
                                    var x = mask
                                    guard idx < x.components.count else { return }
                                    x.components[idx].lumHigh = max(v, x.components[idx].lumLow)
                                    s.updateMaskLive(x)
                                }
                            ), range: 0...1, defaultValue: 0.55, decimals: 2, step: 0.02) { s.endEdit() }
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor).opacity(0.45)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MaskLocalExtraControls: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    let mask: Mask

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

            HStack(spacing: 6) {
                Text(L10n.tr("局部曲线"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
                }
                .menuStyle(.borderlessButton).fixedSize()
            }

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
