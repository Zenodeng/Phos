import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 焦外散景高级光学控制（嵌入 Inspector「焦外散景」组，严格适配 232pt 内栏宽）。
struct BokehAdvancedControls: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var depthInstalled = CoreMLDepthEngine.shared.isModelInstalled

    private var hasPaintedDepth: Bool {
        s.params.masks.contains { $0.kind == .depth && $0.enabled }
    }

    private var depthSourceDesc: String {
        if hasPaintedDepth { return "深度来源：深度涂绘蒙版（白=虚化）" }
        if s.hasDisparity { return "深度来源：人像 disparity 辅助数据" }
        if depthInstalled && s.params.bokehAutoDepth { return "深度来源：Core ML DepthAnythingV2" }
        if s.params.bokehAutoDepth { return "深度来源：内置单目深度（离线）" }
        return "无深度数据：可开启自动单目深度或新建「深度涂绘」"
    }

    private static let bladeChoices: [(Int, String)] = [
        (0, "圆形"), (5, "5 叶"), (6, "6 叶"), (7, "7 叶"), (8, "8 叶")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.tr(depthSourceDesc),
                  systemImage: (hasPaintedDepth || s.hasDisparity || s.params.bokehAutoDepth)
                      ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 9.5))
                .foregroundStyle((hasPaintedDepth || s.hasDisparity || s.params.bokehAutoDepth) ? Color.green : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(L10n.tr("自动单目深度估计"), isOn: Binding(
                get: { s.params.bokehAutoDepth },
                set: { s.set(\.bokehAutoDepth, $0); s.endEdit() }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            if s.params.bokehAmount > 0 || s.showDepthOverlay {
                SliderRow(label: "焦平面", value: Binding(
                    get: { s.params.bokehFocusDepth },
                    set: { s.set(\.bokehFocusDepth, $0) }
                ), range: 0...1, defaultValue: 0.12, decimals: 2, step: 0.01) { s.endEdit() }

                SliderRow(label: "清晰范围", value: Binding(
                    get: { s.params.bokehFocusRange },
                    set: { s.set(\.bokehFocusRange, $0) }
                ), range: 0.02...0.6, defaultValue: 0.20, decimals: 2, step: 0.01) { s.endEdit() }

                SliderRow(label: "高光光斑", value: Binding(
                    get: { s.params.bokehHighlightBoost },
                    set: { s.set(\.bokehHighlightBoost, $0) }
                ), range: 0...100, defaultValue: 35, decimals: 0, step: 1) { s.endEdit() }

                SliderRow(label: "猫眼旋焦", value: Binding(
                    get: { s.params.bokehCatEye },
                    set: { s.set(\.bokehCatEye, $0) }
                ), range: 0...100, defaultValue: 20, decimals: 0, step: 1) { s.endEdit() }

                HStack(spacing: 6) {
                    Text(L10n.tr("光圈叶片"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { s.params.bokehBlades },
                        set: { s.set(\.bokehBlades, $0); s.endEdit() }
                    )) {
                        ForEach(Self.bladeChoices, id: \.0) { cnt, title in
                            Text(L10n.tr(title)).tag(cnt)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(maxWidth: 112)
                }

                HStack(spacing: 6) {
                    Button {
                        s.bokehFocusPicker.toggle()
                        if s.bokehFocusPicker {
                            s.whiteBalancePicker = false
                            s.pointColorPicker = false
                            s.retouchActive = false
                        }
                    } label: {
                        Label(L10n.tr(s.bokehFocusPicker ? "画布点选对焦中…" : "点击画布对焦"),
                              systemImage: "scope")
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                    }
                    .buttonStyle(WorkspaceButtonStyle(selected: s.bokehFocusPicker))
                    .controlSize(.mini)

                    Spacer(minLength: 4)

                    Toggle(L10n.tr("深度图"), isOn: $s.showDepthOverlay)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10.5))
                }
            }

            HStack(spacing: 6) {
                Text(L10n.tr(depthInstalled ? "已启用 DepthAnythingV2" : "可选 DepthAnythingV2 模型"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button(L10n.tr(depthInstalled ? "管理模型" : "导入…")) {
                    s.nativeAITab = .models
                    s.showNativeAI = true
                }
                .controlSize(.mini)
            }
        }
        .onAppear { depthInstalled = CoreMLDepthEngine.shared.isModelInstalled }
        .onReceive(NotificationCenter.default.publisher(for: .phosAIModelsChanged)) { _ in
            depthInstalled = CoreMLDepthEngine.shared.isModelInstalled
        }
    }
}

/// RAW 线性域保边降噪与 2x 超分控制（嵌入 Inspector「细节」组）。
struct NeuralDenoiseControls: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var neuralDenoiseInstalled = CoreMLDenoiseEngine.shared.isModelInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SliderRow(label: "AI 降噪", value: Binding(
                get: { s.params.aiDenoise },
                set: { s.set(\.aiDenoise, $0) }
            ), range: 0...100, defaultValue: 0, decimals: 0, step: 1) { s.endEdit() }

            if s.params.aiDenoise > 0 {
                SliderRow(label: "细节保留", value: Binding(
                    get: { s.params.aiDenoiseDetail },
                    set: { s.set(\.aiDenoiseDetail, $0) }
                ), range: 0...100, defaultValue: 50, decimals: 0, step: 1) { s.endEdit() }
            }

            Toggle(L10n.tr("导出 2x 超分辨率增强"), isOn: Binding(
                get: { s.params.superResolution },
                set: { s.set(\.superResolution, $0); s.endEdit() }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            Text(L10n.tr(neuralDenoiseInstalled
                         ? "已加载 Core ML 神经降噪模型（全分辨率实时非破坏应用）。"
                         : "采用 Metal 线性 RAW 域保边降噪与方向性结构张量超分，零额外大体积 DNG。"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { neuralDenoiseInstalled = CoreMLDenoiseEngine.shared.isModelInstalled }
        .onReceive(NotificationCenter.default.publisher(for: .phosAIModelsChanged)) { _ in
            neuralDenoiseInstalled = CoreMLDenoiseEngine.shared.isModelInstalled
        }
    }
}

extension Notification.Name {
    static let phosAIModelsChanged = Notification.Name("phosAIModelsChanged")
}
