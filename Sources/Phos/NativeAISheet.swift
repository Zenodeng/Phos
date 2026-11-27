import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum NativeAITab: String, CaseIterable {
    case edit
    case colorMatch
    case models

    var label: String {
        switch self {
        case .edit: return "原生智能修图"
        case .colorMatch: return "参考图对色"
        case .models: return "端侧模型中心"
        }
    }
}

/// P3 零 Python 端侧 AI 工作台（Swift 原生修图编排 + 参考图全可编辑参数反解 + 5 槽位 Core ML 模型中心）。
struct NativeAISheet: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var instruction: String = L10n.tr("自然通透，提亮暗部，温暖电影感")
    @State private var planResult: NativeAIPlanResult?
    @State private var planPreview: CGImage?
    @State private var planBusy = false

    @State private var refURL: URL?
    @State private var refThumb: CGImage?
    @State private var matchOptions = ColorMatchOptions()
    @State private var matchResult: ColorMatchResult?
    @State private var matchPreview: CGImage?
    @State private var matchBusy = false

    @State private var modelStatuses: [AIModelSlotStatus] = AIModelHub.shared.slots
    @State private var modelNote: String = ""

    private static let quickPrompts = [
        "自然通透，平衡明暗",
        "日系清新通透，柔和暗部",
        "温暖电影感，加少量颗粒与光晕",
        "压暗过曝天空，增强蓝天层次",
        "夜景纯净降噪，高光柔滑",
        "高反差银盐黑白"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.tr("端侧原生 AI 工作台"), systemImage: "sparkles.rectangle.stack")
                    .font(.title3.bold())
                Spacer()
                Picker("", selection: $s.nativeAITab) {
                    ForEach(NativeAITab.allCases, id: \.self) { t in
                        Text(L10n.tr(t.label)).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 310)
            }

            Group {
                switch s.nativeAITab {
                case .edit: nativeEditTab
                case .colorMatch: colorMatchTab
                case .models: modelHubTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Button(L10n.tr("打开旧版 MLX-VLM 实验窗口…")) {
                    s.showNativeAI = false
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        s.showPhotoAI = true
                    }
                }
                .controlSize(.small)
                .disabled(s.source == nil)

                Spacer()
                Button(L10n.tr("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 740, height: 590)
        .onAppear {
            refURL = s.referencePhotoURL
            modelStatuses = AIModelHub.shared.slots
            loadRefThumbnail()
        }
    }

    // MARK: - 1. Swift 原生修图编排（零 Python）
    private var nativeEditTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("无需安装 Python 或外部服务端：结合像素直方图、OKLab 色偏与 Vision 语义在 Swift 原生端侧生成可微调参数与蒙版。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(L10n.tr("输入修图要求…"), text: $instruction, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.roundedBorder)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.quickPrompts, id: \.self) { p in
                        Button(L10n.tr(p)) { instruction = L10n.tr(p); runNativePlan() }
                            .controlSize(.mini)
                    }
                }
            }

            HStack(spacing: 12) {
                previewBox(title: "当前效果", cg: s.preview)
                previewBox(title: "原生 AI 预览", cg: planPreview)
            }

            if let res = planResult {
                Text(L10n.tr(res.summary)).font(.callout)
                Text(res.detail).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L10n.tr(planBusy ? "推算中…" : "生成预览")) { runNativePlan() }
                    .disabled(planBusy || s.source == nil)
                Button(L10n.tr("应用参数")) {
                    guard let res = planResult else { return }
                    s.applyAICandidate(res.params,
                                       statusMessage: L10n.tr("已应用原生 AI 参数，全部滑杆可继续微调"))
                    dismiss()
                }
                .buttonStyle(WorkspaceButtonStyle(prominent: true))
                .disabled(planResult == nil || s.source == nil)
            }
        }
    }

    // MARK: - 2. 参考图全可编辑参数反解
    private var colorMatchTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(L10n.tr("选择参考图…")) { pickReferenceImage() }
                Text(refURL?.lastPathComponent ?? L10n.tr("请选择参考电影截图或大师样片"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let res = matchResult {
                    Text("ΔE \(String(format: "%.1f", res.initialDeltaE)) → \(String(format: "%.1f", res.finalDeltaE)) · \(Int(res.elapsedMs.rounded())) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.green)
                }
            }

            HStack(spacing: 12) {
                Toggle(L10n.tr("曝光与对比"), isOn: $matchOptions.matchExposure).toggleStyle(.checkbox)
                Toggle(L10n.tr("亮度曲线"), isOn: $matchOptions.matchToneCurve).toggleStyle(.checkbox)
                Toggle(L10n.tr("颜色分级"), isOn: $matchOptions.matchColorGrade).toggleStyle(.checkbox)
                Toggle(L10n.tr("HSL 色区"), isOn: $matchOptions.matchHSL).toggleStyle(.checkbox)
                Toggle(L10n.tr("颗粒/光晕"), isOn: $matchOptions.matchFilmTexture).toggleStyle(.checkbox)
                Toggle(L10n.tr("保护肤色"), isOn: $matchOptions.protectSkinTones).toggleStyle(.checkbox)
            }
            .font(.system(size: 11))

            SliderRow(label: "匹配强度", value: $matchOptions.strength, range: 0...1.5,
                      defaultValue: 1.0, decimals: 2, step: 0.05, photoScoped: false) {}

            HStack(spacing: 12) {
                previewBox(title: "参考样片", cg: refThumb)
                previewBox(title: "对色后效果", cg: matchPreview ?? s.preview)
            }

            if let res = matchResult {
                HStack(spacing: 8) {
                    Text(L10n.tr("参考色板")).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        ForEach(Array(res.referencePalette.enumerated()), id: \.offset) { _, rgb in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(red: rgb[0], green: rgb[1], blue: rgb[2]))
                                .frame(width: 24, height: 14)
                        }
                    }
                    Spacer()
                    Text(L10n.tr("涉及分组：\(res.changedGroups.joined(separator: " / "))"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            HStack {
                Spacer()
                Button(L10n.tr(matchBusy ? "反解计算中…" : "反解可编辑参数")) { runColorMatchPreview() }
                    .disabled(matchBusy || s.source == nil || refURL == nil)
                Button(L10n.tr("应用到照片")) {
                    guard let res = matchResult else { return }
                    s.applyAICandidate(res.params,
                                       statusMessage: L10n.tr("已完成参考图对色（全部滑杆与曲线可继续微调）"))
                    dismiss()
                }
                .buttonStyle(WorkspaceButtonStyle(prominent: true))
                .disabled(matchResult == nil || s.source == nil)
            }
        }
    }

    // MARK: - 3. 端侧 Core ML 模型中心（5 槽位）
    private var modelHubTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("所有可选 Core ML 模型均存放在 ~/Library/Application Support/Phos/Models，未安装时各功能均可使用内置零模型 Metal/Vision 算法正常运作。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(modelStatuses) { st in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: st.installed ? "checkmark.seal.fill" : "shippingbox")
                                .font(.system(size: 16))
                                .foregroundStyle(st.installed ? Color.green : .secondary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(L10n.tr(st.slot.title)).font(.system(size: 12, weight: .semibold))
                                    if let sz = st.sizeText {
                                        Text(sz).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    Text(st.slot.fileName).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                                Text(L10n.tr(st.slot.fallbackDescription))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }

                            Spacer()

                            if let cmd = st.slot.installScriptCommand {
                                Button(L10n.tr("复制安装命令")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(cmd, forType: .string)
                                    modelNote = L10n.tr("已复制终端安装命令：\(cmd)")
                                }
                                .controlSize(.mini)
                            }
                            Button(L10n.tr(st.installed ? "替换…" : "导入…")) { importModel(st.slot) }
                                .controlSize(.mini)
                            if st.installed {
                                Button(L10n.tr("移除"), role: .destructive) { removeModel(st.slot) }
                                    .controlSize(.mini)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                    }
                }
            }

            if !modelNote.isEmpty {
                Text(modelNote).font(.caption).foregroundStyle(WorkspaceTokens.accent)
            }
        }
    }

    private func previewBox(title: String, cg: CGImage?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(title)).font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.15))
                if let cg {
                    Image(decorative: cg, scale: 1).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity)
    }

    private func runNativePlan() {
        guard let src = s.source else { return }
        planBusy = true
        let baseParams = s.params
        let instr = instruction
        let url = s.current?.url
        Task.detached {
            let disp = url.flatMap { Engine.disparityBokehMask(for: $0, target: src.extent) }
            let res = NativePhotoPlanner.plan(instruction: instr, source: src, base: baseParams, disparityMask: disp)
            let scale = min(1.0, 640.0 / max(src.extent.width, src.extent.height, 1.0))
            let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let smallDisp = url.flatMap { Engine.disparityBokehMask(for: $0, target: small.extent) }
            let rendered = Engine.render(small, res.params, disparityMask: smallDisp)
            let cg = Engine.ctx.createCGImage(rendered, from: rendered.extent, format: .RGBA8, colorSpace: Engine.srgb)
            await MainActor.run {
                planResult = res
                planPreview = cg
                planBusy = false
            }
        }
    }

    private func pickReferenceImage() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image, .rawImage]
        if p.runModal() == .OK, let u = p.url {
            refURL = u
            loadRefThumbnail()
        }
    }

    private func loadRefThumbnail() {
        guard let u = refURL else { refThumb = nil; return }
        Task.detached {
            guard let ci = Engine.decode(u) else { return }
            let scale = min(1.0, 640.0 / max(ci.extent.width, ci.extent.height, 1.0))
            let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cg = Engine.ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: Engine.srgb)
            await MainActor.run { refThumb = cg }
        }
    }

    private func runColorMatchPreview() {
        guard let src = s.source, let u = refURL else { return }
        matchBusy = true
        let baseParams = s.params
        let opts = matchOptions
        Task.detached {
            guard let refCI = Engine.decode(u) else {
                await MainActor.run { matchBusy = false }
                return
            }
            let res = ColorMatchEngine.solve(source: src, reference: refCI, base: baseParams, options: opts)
            let scale = min(1.0, 640.0 / max(src.extent.width, src.extent.height, 1.0))
            let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let rendered = Engine.render(small, res.params)
            let cg = Engine.ctx.createCGImage(rendered, from: rendered.extent, format: .RGBA8, colorSpace: Engine.srgb)
            await MainActor.run {
                matchResult = res
                matchPreview = cg
                matchBusy = false
            }
        }
    }

    private func importModel(_ slot: AIModelSlot) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.item]
        p.message = L10n.tr("选择 \(slot.fileName) 或 .mlpackage 模型")
        if p.runModal() == .OK, let u = p.url {
            do {
                try AIModelHub.shared.install(slot: slot, from: u)
                modelStatuses = AIModelHub.shared.slots
                modelNote = L10n.tr("已导入 \(slot.fileName)")
                NotificationCenter.default.post(name: .phosAIModelsChanged, object: nil)
                s.render()
            } catch {
                modelNote = error.localizedDescription
            }
        }
    }

    private func removeModel(_ slot: AIModelSlot) {
        do {
            try AIModelHub.shared.remove(slot: slot)
            modelStatuses = AIModelHub.shared.slots
            modelNote = L10n.tr("已移除 \(slot.fileName)")
            NotificationCenter.default.post(name: .phosAIModelsChanged, object: nil)
            s.render()
        } catch {
            modelNote = error.localizedDescription
        }
    }
}
