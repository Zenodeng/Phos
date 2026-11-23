import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 色彩分类下的「参考图智能对色」轻量控制卡（可直接在侧栏匹配参考图，或打开完整 AI 对色工作台）。
struct ColorMatchMiniSection: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var options = ColorMatchOptions()
    @State private var lastResult: ColorMatchResult?
    @State private var externalRefURL: URL?

    private var activeRefURL: URL? {
        externalRefURL ?? s.referencePhotoURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)
            HStack {
                Text(L10n.tr("参考图智能对色"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(L10n.tr("工作台…")) {
                    s.nativeAITab = .colorMatch
                    s.showNativeAI = true
                }
                .controlSize(.mini)
            }

            HStack(spacing: 6) {
                Text(activeRefURL?.lastPathComponent ?? L10n.tr("未选参考图（默认用参考视图锁定图）"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(L10n.tr("选图…")) { pickReferenceFile() }
                    .controlSize(.mini)
            }

            Toggle(L10n.tr("保护肤色自然感"), isOn: $options.protectSkinTones)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))

            SliderRow(label: "对色强度", value: $options.strength, range: 0...1.5,
                      defaultValue: 1.0, decimals: 2, step: 0.05, photoScoped: false) {}

            if let res = lastResult {
                HStack(spacing: 4) {
                    ForEach(Array(res.referencePalette.enumerated()), id: \.offset) { _, rgb in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: rgb[0], green: rgb[1], blue: rgb[2]))
                            .frame(height: 11)
                    }
                }
                Text(L10n.tr("ΔE \(String(format: "%.1f", res.initialDeltaE)) → \(String(format: "%.1f", res.finalDeltaE))（\(Int(res.elapsedMs.rounded())) ms）"))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button {
                lastResult = s.runColorMatch(referenceURL: activeRefURL, options: options)
            } label: {
                Text(L10n.tr("匹配参考色调（全可微调）"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WorkspaceButtonStyle(prominent: activeRefURL != nil))
            .controlSize(.small)
            .disabled(s.source == nil || activeRefURL == nil)
        }
    }

    private func pickReferenceFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image, .rawImage]
        p.message = L10n.tr("选择参考电影截图或大师样片")
        if p.runModal() == .OK, let u = p.url {
            externalRefURL = u
        }
    }
}
