import SwiftUI

struct SyncSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) var dismiss
    @State private var useCopied = false

    private var targets: [URL] {
        s.items.filter { s.selectedPhotos.contains($0.id) && (useCopied || $0.id != s.current?.id) }.map(\.url)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("同步调整").font(.headline)
            Picker("来源", selection: $useCopied) {
                Text("当前照片").tag(false)
                Text("已复制的调整").tag(true)
            }.pickerStyle(.segmented).disabled(s.copiedParams == nil)
            Text(useCopied ? s.copiedName : (s.current?.url.lastPathComponent ?? ""))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Divider()
            ForEach(EditGroup.allCases) { group in
                Toggle(group.label, isOn: Binding(
                    get: { s.syncGroups.contains(group) },
                    set: { if $0 { s.syncGroups.insert(group) } else { s.syncGroups.remove(group) } }
                ))
            }
            Divider()
            HStack {
                Text("\(targets.count) 张目标照片").foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("同步") {
                    let params = useCopied ? s.copiedParams! : s.params
                    let urls = targets, groups = s.syncGroups
                    Task { await s.synchronize(params, to: urls, groups: groups) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(targets.isEmpty || s.syncGroups.isEmpty || s.source == nil || s.syncRunning)
            }
        }.padding(22).frame(width: 420)
    }
}

struct SnapshotSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var renaming: UUID?
    @State private var renamed = ""
    @State private var deleting: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("命名快照").font(.headline)
            HStack {
                TextField("快照名称", text: $name)
                    .onSubmit { save() }
                Button(action: save) { Image(systemName: "plus") }
                    .help("保存当前调整为快照")
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || s.source == nil)
            }
            List {
                ForEach(s.snapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.name).lineLimit(1)
                            Text(snapshot.created.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { s.restoreSnapshot(snapshot.id); dismiss() } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }.help("恢复此快照")
                        Button { renaming = snapshot.id; renamed = snapshot.name } label: {
                            Image(systemName: "pencil")
                        }.help("重命名快照")
                        Button { deleting = snapshot.id } label: {
                            Image(systemName: "trash")
                        }.help("删除快照")
                    }.buttonStyle(.borderless).padding(.vertical, 3)
                }
            }.frame(height: 280)
                .overlay { if s.snapshots.isEmpty { Text("暂无快照").foregroundStyle(.secondary) } }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 460)
            .alert("重命名快照", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名称", text: $renamed)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let id = renaming { s.renameSnapshot(id, name: renamed) }
                    renaming = nil
                }
            }
            .alert("删除这个快照？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) {
                    if let id = deleting { s.deleteSnapshot(id) }
                    deleting = nil
                }
            }
    }
    private func save() {
        s.createSnapshot(name: name)
        name = ""
    }
}

struct OutputPrecisionControls: View {
    @Binding var settings: ExportSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.format == "tiff" {
                Picker("位深", selection: $settings.tiffBitDepth) {
                    Text("8 位").tag(8)
                    Text("16 位").tag(16)
                }.pickerStyle(.segmented)
            }
            Picker("色彩空间", selection: $settings.colorSpace) {
                ForEach(ExportColorSpace.allCases, id: \.self) { color in Text(color.label).tag(color) }
            }
        }
    }
}

struct MaskEditingControls: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("显示选区", isOn: $s.showMaskOverlay).toggleStyle(.checkbox)
                Spacer()
                Picker("蒙版工具", selection: $s.maskTool) {
                    ForEach(MaskTool.allCases, id: \.self) { tool in
                        Image(systemName: tool.symbol).tag(tool).help(tool.label)
                    }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 112)
            }
            if s.maskTool != .position {
                SliderRow(label: "笔刷", value: $s.brushRadius, range: 0.005...0.3)
                SliderRow(label: "软边", value: $s.brushFeather, range: 0...1)
            }
        }.font(.system(size: 11))
    }
}
