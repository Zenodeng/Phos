import SwiftUI

struct SyncSheet: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) var dismiss
    @State private var useCopied = false
    @State private var groups = EditGroup.defaults

    private var targets: [URL] {
        s.items.filter { s.selectedPhotos.contains($0.id) && (useCopied || $0.id != s.current?.id) }.map(\.url)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("同步调整")).font(.headline)
            Picker(L10n.tr("来源"), selection: $useCopied) {
                Text(L10n.tr("当前照片")).tag(false)
                Text(L10n.tr("已复制的调整")).tag(true)
            }.pickerStyle(.segmented).disabled(s.copiedParams == nil)
            Text(useCopied ? s.copiedName : (s.current?.url.lastPathComponent ?? ""))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Divider()
            ForEach(EditGroup.allCases) { group in
                Toggle(L10n.tr(group.label), isOn: Binding(
                    get: { groups.contains(group) },
                    set: { if $0 { groups.insert(group) } else { groups.remove(group) } }
                ))
            }
            Divider()
            HStack {
                Text(L10n.tr("\(targets.count) 张目标照片")).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("同步")) {
                    let params = useCopied ? s.copiedParams! : s.params
                    let urls = targets, selectedGroups = groups
                    s.syncGroups = selectedGroups
                    Task { await s.synchronize(params, to: urls, groups: selectedGroups) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(WorkspaceButtonStyle(prominent:true))
                .disabled(targets.isEmpty || groups.isEmpty || s.source == nil || s.syncRunning)
            }
        }.padding(20).frame(width: 420).workspaceGlassPanel()
            .onAppear { groups = s.syncGroups }
    }
}

struct SnapshotSheet: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var drafts:[EditSnapshot] = []
    @State private var name = ""
    @State private var photoID:UUID?
    @State private var error:String?
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L10n.tr("命名快照")).font(.system(size:17,weight:.semibold))
            Text(L10n.tr("保存调整的不同版本，原始照片始终保留")).font(.caption).foregroundStyle(WorkspaceTokens.secondaryText)
            HStack {
                TextField(L10n.tr("快照名称"),text:$name).textFieldStyle(.roundedBorder).onSubmit { add() }
                Button(L10n.tr("添加")) { add() }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || s.source == nil)
            }
            ScrollView {
                VStack(spacing:8) {
                    ForEach($drafts) { $snapshot in
                        HStack {
                            VStack(alignment:.leading,spacing:4) {
                                TextField(L10n.tr("名称"),text:$snapshot.name).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.tr("快照名称"))
                                Text(snapshot.created.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(WorkspaceTokens.secondaryText)
                            }
                            Button(L10n.tr("恢复")) { if persist() { s.commit(snapshot.params); dismiss() } }
                                .disabled(snapshot.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                            Button { drafts.removeAll { $0.id == snapshot.id } } label: { Image(systemName:"trash") }.help(L10n.tr("移除快照")).accessibilityLabel(L10n.tr("移除快照"))
                        }.padding(8).background(WorkspaceTokens.readoutColor,in:RoundedRectangle(cornerRadius:8))
                    }
                    if drafts.isEmpty { Text(L10n.tr("暂无快照")).foregroundStyle(WorkspaceTokens.secondaryText).padding(.vertical,50) }
                }
            }.frame(height:260)
            if let error { Text(L10n.tr(error)).font(.caption).foregroundStyle(WorkspaceTokens.error) }
            HStack {
                Button(L10n.tr("取消"),role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button(L10n.tr("保存")) { if persist() { dismiss() } }.keyboardShortcut(.defaultAction).buttonStyle(WorkspaceButtonStyle(prominent:true))
                    .disabled(drafts.contains { $0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty })
            }
        }.padding(20).frame(width:450).workspaceGlassPanel()
            .onAppear { drafts = s.snapshots; photoID = s.current?.id }
    }
    private func add() {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty, s.source != nil else { return }
        drafts.append(EditSnapshot(name:String(trimmed.prefix(120)),params:s.params)); name = ""
    }
    private func persist() -> Bool {
        guard photoID == s.current?.id else { error = "照片已改变，请重新打开快照"; return false }
        let previous = s.snapshots; s.snapshots = drafts
        if !s.saveCurrent() { s.snapshots = previous; error = "快照保存失败，原记录已保留"; return false }
        return true
    }
}

struct OutputPrecisionControls: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @Binding var settings: ExportSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.format == "tiff" {
                Picker(L10n.tr("位深"), selection: $settings.tiffBitDepth) {
                    Text(L10n.tr("8 位")).tag(8)
                    Text(L10n.tr("16 位")).tag(16)
                }.pickerStyle(.segmented)
            }
            Picker(L10n.tr("色彩空间"), selection: $settings.colorSpace) {
                ForEach(ExportColorSpace.allCases, id: \.self) { color in Text(L10n.tr(color.label)).tag(color) }
            }
        }
    }
}

struct MaskEditingControls: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle(L10n.tr("显示选区"), isOn: $s.showMaskOverlay).toggleStyle(.checkbox)
                Spacer()
                Picker(L10n.tr("蒙版工具"), selection: $s.maskTool) {
                    ForEach(MaskTool.allCases, id: \.self) { tool in
                        Image(systemName: tool.symbol).tag(tool).help(L10n.tr(tool.label)).accessibilityLabel(L10n.tr(tool.label))
                    }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 112)
            }
            if s.maskTool != .position {
                SliderRow(label: "笔刷", value: $s.brushRadius, range: 0.005...0.3, defaultValue:0.05, photoScoped:false)
                SliderRow(label: "软边", value: $s.brushFeather, range: 0...1, defaultValue:0.5, photoScoped:false)
            }
        }.font(.system(size: 11))
    }
}
