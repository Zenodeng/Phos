import SwiftUI

/// OKLCH 感知空间下的精准点颜色采样与 3D 范围微调面板。
struct PointColorPane: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var selectedID: UUID?

    private var selectedIndex: Int? {
        guard !s.params.pointColors.isEmpty else { return nil }
        if let selectedID, let idx = s.params.pointColors.firstIndex(where: { $0.id == selectedID }) {
            return idx
        }
        return s.params.pointColors.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.tr("点颜色 (OKLCH)"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkspaceTokens.primaryText)
                Spacer()
                Button {
                    s.parameterEdits.finishCurrent()
                    s.localPointColorMaskID = nil
                    s.pointColorPicker.toggle()
                } label: {
                    Label(L10n.tr(s.pointColorPicker ? "正在画布取色…" : "取色"),
                          systemImage: "eyedropper")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(WorkspaceButtonStyle(prominent: s.pointColorPicker))
                .controlSize(.small)
                .disabled(s.source == nil || s.cropMode)
                .help(L10n.tr("在画布上点击采样目标色样"))

                if !s.params.pointColors.isEmpty {
                    Button(L10n.tr("清空")) {
                        s.parameterEdits.invalidate()
                        selectedID = nil
                        var p = s.params
                        p.pointColors = []
                        s.commit(p)
                    }
                    .controlSize(.small)
                }
            }

            if s.params.pointColors.isEmpty {
                Text(L10n.tr("点「取色」后点击画面颜色，单独偏转其色相、彩度与明度而不连带其他色彩。"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(s.params.pointColors) { sw in
                            let isSel = s.params.pointColors[selectedIndex ?? 0].id == sw.id
                            Button {
                                selectedID = sw.id
                            } label: {
                                Circle()
                                    .fill(Color(
                                        red: min(max(sw.sampleRGB.count > 0 ? sw.sampleRGB[0] : 0.5, 0), 1),
                                        green: min(max(sw.sampleRGB.count > 1 ? sw.sampleRGB[1] : 0.5, 0), 1),
                                        blue: min(max(sw.sampleRGB.count > 2 ? sw.sampleRGB[2] : 0.5, 0), 1)
                                    ))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle().stroke(isSel ? WorkspaceTokens.accent : Color.primary.opacity(0.28),
                                                        lineWidth: isSel ? 2 : 0.8)
                                    )
                                    .opacity(sw.enabled ? 1.0 : 0.4)
                            }
                            .buttonStyle(.plain)
                            .help(sw.name)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let idx = selectedIndex {
                    HStack(spacing: 6) {
                        Toggle(L10n.tr("启用"), isOn: Binding(
                            get: { s.params.pointColors[idx].enabled },
                            set: { v in
                                var arr = s.params.pointColors
                                arr[idx].enabled = v
                                var p = s.params; p.pointColors = arr; s.commit(p)
                            }
                        ))
                        .font(.system(size: 10.5))
                        Spacer()
                        Button {
                            var arr = s.params.pointColors
                            arr.remove(at: idx)
                            selectedID = arr.last?.id
                            var p = s.params; p.pointColors = arr; s.commit(p)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(WorkspaceButtonStyle())
                        .controlSize(.mini)
                        .help(L10n.tr("删除当前色样"))
                    }

                    SliderRow(label: "色相偏移", value: Binding(
                        get: { idx < s.params.pointColors.count ? s.params.pointColors[idx].hueShift : 0 },
                        set: { v in
                            var arr = s.params.pointColors
                            guard idx < arr.count else { return }
                            arr[idx].hueShift = v
                            s.set(\.pointColors, arr)
                        }
                    ), range: -180...180, defaultValue: 0, unit: "°") { s.endEdit() }

                    SliderRow(label: "彩度偏移", value: Binding(
                        get: { idx < s.params.pointColors.count ? s.params.pointColors[idx].chromaShift : 0 },
                        set: { v in
                            var arr = s.params.pointColors
                            guard idx < arr.count else { return }
                            arr[idx].chromaShift = v
                            s.set(\.pointColors, arr)
                        }
                    ), range: -100...100, defaultValue: 0) { s.endEdit() }

                    SliderRow(label: "明度偏移", value: Binding(
                        get: { idx < s.params.pointColors.count ? s.params.pointColors[idx].lumaShift : 0 },
                        set: { v in
                            var arr = s.params.pointColors
                            guard idx < arr.count else { return }
                            arr[idx].lumaShift = v
                            s.set(\.pointColors, arr)
                        }
                    ), range: -100...100, defaultValue: 0) { s.endEdit() }

                    SliderRow(label: "总范围", value: Binding(
                        get: { idx < s.params.pointColors.count ? s.params.pointColors[idx].range : 0.4 },
                        set: { v in
                            var arr = s.params.pointColors
                            guard idx < arr.count else { return }
                            arr[idx].range = v
                            s.set(\.pointColors, arr)
                        }
                    ), range: 0.05...1.0, defaultValue: 0.4, decimals: 2, step: 0.01) { s.endEdit() }

                    SliderRow(label: "色相范围", value: Binding(
                        get: { idx < s.params.pointColors.count ? s.params.pointColors[idx].hueRange : 0.45 },
                        set: { v in
                            var arr = s.params.pointColors
                            guard idx < arr.count else { return }
                            arr[idx].hueRange = v
                            s.set(\.pointColors, arr)
                        }
                    ), range: 0.1...1.0, defaultValue: 0.45, decimals: 2, step: 0.01) { s.endEdit() }

                    SliderRow(label: "彩度范围", value: Binding(
                        get: { idx < s.params.pointColors.count ? s.params.pointColors[idx].chromaRange : 0.6 },
                        set: { v in
                            var arr = s.params.pointColors
                            guard idx < arr.count else { return }
                            arr[idx].chromaRange = v
                            s.set(\.pointColors, arr)
                        }
                    ), range: 0.1...1.0, defaultValue: 0.6, decimals: 2, step: 0.01) { s.endEdit() }

                    SliderRow(label: "明度范围", value: Binding(
                        get: { idx < s.params.pointColors.count ? s.params.pointColors[idx].lumaRange : 0.7 },
                        set: { v in
                            var arr = s.params.pointColors
                            guard idx < arr.count else { return }
                            arr[idx].lumaRange = v
                            s.set(\.pointColors, arr)
                        }
                    ), range: 0.1...1.0, defaultValue: 0.7, decimals: 2, step: 0.01) { s.endEdit() }
                }
            }
        }
    }
}
