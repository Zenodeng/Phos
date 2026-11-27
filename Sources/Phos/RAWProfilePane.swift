import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 相机配置文件（内置 / 导入 Adobe .dcp）与可选 LibRaw 解码器控制面板（零 App 体积膨胀）。
struct RAWProfilePane: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var profiles: [DCPProfileEngine.ProfileChoice] = DCPProfileEngine.availableProfiles()
    @State private var libRawReady: Bool = LibRawEngine.shared.isAvailable
    @State private var libRawStatus: String = LibRawEngine.shared.statusSummary
    @State private var copiedInstallCmd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 1. 相机配置文件（.dcp）
            HStack(spacing: 6) {
                Text(L10n.tr("配置文件"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)
                Picker("", selection: Binding(
                    get: { s.params.cameraProfileName },
                    set: { s.set(\.cameraProfileName, $0); s.endEdit() }
                )) {
                    ForEach(profiles) { choice in
                        Text(choice.isDCP ? choice.name : L10n.tr(choice.name)).tag(choice.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                Button(L10n.tr("导入 .dcp…")) {
                    s.importDCPProfile {
                        profiles = DCPProfileEngine.availableProfiles()
                    }
                }
                .controlSize(.small)
            }

            if !s.params.cameraProfileName.isEmpty {
                SliderRow(label: "配置强度", value: Binding(
                    get: { s.params.cameraProfileAmount },
                    set: { s.set(\.cameraProfileAmount, $0) }
                ), range: 0...2, defaultValue: 1.0, decimals: 2, step: 0.05) { s.endEdit() }
            }

            Divider().padding(.vertical, 1)

            // 2. 可选 RAW 解码后端（Apple RAW vs LibRaw）
            HStack(spacing: 6) {
                Text(L10n.tr("RAW 解码"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)
                Picker("", selection: Binding(
                    get: { s.params.rawDecoderMode },
                    set: { s.set(\.rawDecoderMode, $0); s.endEdit() }
                )) {
                    ForEach(RawDecoderMode.allCases, id: \.self) { m in
                        Text(L10n.tr(m.label)).tag(m)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }

            if s.params.rawDecoderMode == .libRaw || libRawReady {
                HStack(spacing: 6) {
                    Circle()
                        .fill(libRawReady ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(L10n.tr(libRawStatus))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    if !libRawReady {
                        Button(L10n.tr(copiedInstallCmd ? "已复制命令" : "复制安装命令")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(LibRawEngine.installCommand, forType: .string)
                            copiedInstallCmd = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedInstallCmd = false }
                        }
                        .controlSize(.mini)
                    }
                    Button {
                        LibRawEngine.shared.rescan()
                        libRawReady = LibRawEngine.shared.isAvailable
                        libRawStatus = LibRawEngine.shared.statusSummary
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("重新检测可选 LibRaw 动态库"))
                }
            }

            if s.params.rawDecoderMode == .libRaw && libRawReady {
                HStack(spacing: 6) {
                    Text(L10n.tr("高光重建"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { s.params.libRawHighlightMode },
                        set: { s.set(\.libRawHighlightMode, $0); s.endEdit() }
                    )) {
                        Text(L10n.tr("裁剪 (0)")).tag(0)
                        Text(L10n.tr("保留无裁 (1)")).tag(1)
                        Text(L10n.tr("混合 (2)")).tag(2)
                        Text(L10n.tr("色彩重建 (5)")).tag(5)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            profiles = DCPProfileEngine.availableProfiles()
            libRawReady = LibRawEngine.shared.isAvailable
            libRawStatus = LibRawEngine.shared.statusSummary
        }
    }
}
