import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 污点修复（Heal）、仿制克隆（Clone）与内容感知消除（Remove + 可选 Core ML LaMa）面板。
struct RetouchPane: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var modelStatusMessage = ""
    @State private var modelInstalled = CoreMLInpaintingEngine.shared.isModelInstalled
    @State private var modelSummary = CoreMLInpaintingEngine.shared.modelSummary ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("污点与消除"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkspaceTokens.primaryText)
                Spacer()
                Button {
                    s.parameterEdits.finishCurrent()
                    s.retouchActive.toggle()
                } label: {
                    Label(L10n.tr(s.retouchActive ? "涂抹修复中" : "修复画笔"),
                          systemImage: "bandage")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(WorkspaceButtonStyle(prominent: s.retouchActive))
                .controlSize(.small)
                .disabled(s.source == nil || s.cropMode)
            }

            Picker(L10n.tr("修复模式"), selection: $s.retouchMode) {
                ForEach(RetouchMode.allCases, id: \.self) { m in
                    Text(L10n.tr(m.label)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            SliderRow(label: "画笔大小", value: $s.retouchRadius, range: 0.005...0.15,
                      defaultValue: 0.035, decimals: 3, step: 0.005, photoScoped: false)
            SliderRow(label: "边缘羽化", value: $s.retouchFeather, range: 0.05...1.0,
                      defaultValue: 0.45, decimals: 2, step: 0.05, photoScoped: false)
            SliderRow(label: "不透明度", value: $s.retouchOpacity, range: 0.1...1.0,
                      defaultValue: 1.0, decimals: 2, step: 0.05, photoScoped: false)

            Text(L10n.tr("在画布拖动涂抹可消除瑕疵；按住 Option 点击画面可自定义修复/仿制采样源点。"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !s.params.retouchSpots.isEmpty {
                Divider().padding(.vertical, 2)
                HStack {
                    Text(L10n.tr("已添加 \(s.params.retouchSpots.count) 处修复"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("全部清除")) {
                        s.parameterEdits.invalidate()
                        s.selectedRetouchSpotID = nil
                        var p = s.params
                        p.retouchSpots = []
                        s.commit(p)
                    }
                    .controlSize(.mini)
                }

                ForEach(Array(s.params.retouchSpots.enumerated()), id: \.element.id) { idx, spot in
                    let isSel = s.selectedRetouchSpotID == spot.id
                    HStack(spacing: 5) {
                        Button {
                            s.selectedRetouchSpotID = isSel ? nil : spot.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: spot.mode == .heal ? "bandage" : spot.mode == .clone ? "doc.on.doc" : "wand.and.rays")
                                    .font(.system(size: 9))
                                Text("#\(idx + 1) \(L10n.tr(spot.mode.label))")
                                    .font(.system(size: 10.5))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSel ? WorkspaceTokens.accent : .primary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { spot.enabled },
                            set: { on in
                                var x = spot; x.enabled = on
                                var p = s.params
                                if let pos = p.retouchSpots.firstIndex(where: { $0.id == spot.id }) {
                                    p.retouchSpots[pos] = x
                                    s.commit(p)
                                }
                            }
                        ))
                        .labelsHidden().controlSize(.mini)
                        Button {
                            s.removeRetouchSpot(spot.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .buttonStyle(WorkspaceButtonStyle()).controlSize(.mini)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(isSel ? WorkspaceTokens.accent.opacity(0.1) : Color.clear))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: modelInstalled ? "cpu.fill" : "cpu")
                    .font(.system(size: 9.5))
                    .foregroundStyle(modelInstalled ? .green : .secondary)
                let baseStatus = L10n.tr(modelInstalled ? "Core ML LaMa 模型已就绪" : "内置离线 PatchMatch（可选导 Core ML 模型）")
                Text(modelInstalled && !modelSummary.isEmpty ? "\(baseStatus)（\(modelSummary)）" : baseStatus)
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if modelInstalled {
                    Button(L10n.tr("移除模型")) {
                        do {
                            try CoreMLInpaintingEngine.shared.removeModel()
                            modelInstalled = CoreMLInpaintingEngine.shared.isModelInstalled
                            modelSummary = ""
                            modelStatusMessage = L10n.tr("已移除 LaMa Core ML 模型")
                            s.render()
                        } catch {
                            modelStatusMessage = error.localizedDescription
                        }
                    }
                    .controlSize(.mini)
                }
                Button(L10n.tr("导入模型…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [.package, .directory]
                    panel.message = L10n.tr("选择 LaMa.mlpackage 或编译后的 LaMa.mlmodelc")
                    if panel.runModal() == .OK, let u = panel.url {
                        do {
                            try CoreMLInpaintingEngine.shared.installModel(from: u)
                            modelInstalled = CoreMLInpaintingEngine.shared.isModelInstalled
                            modelSummary = CoreMLInpaintingEngine.shared.modelSummary ?? ""
                            modelStatusMessage = L10n.tr("已安装 LaMa Core ML 模型")
                            if modelInstalled {
                                CoreMLInpaintingEngine.shared.preloadInBackground { summary in
                                    DispatchQueue.main.async {
                                        modelSummary = summary ?? ""
                                    }
                                }
                            }
                            s.render()
                        } catch {
                            modelStatusMessage = error.localizedDescription
                        }
                    }
                }
                .controlSize(.mini)
            }
            if !modelStatusMessage.isEmpty {
                Text(modelStatusMessage).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            modelInstalled = CoreMLInpaintingEngine.shared.isModelInstalled
            if modelInstalled {
                if let cached = CoreMLInpaintingEngine.shared.modelSummary {
                    modelSummary = cached
                } else {
                    CoreMLInpaintingEngine.shared.preloadInBackground { summary in
                        DispatchQueue.main.async {
                            modelSummary = summary ?? ""
                        }
                    }
                }
            } else {
                modelSummary = ""
            }
        }
    }
}
