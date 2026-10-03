import SwiftUI

// MARK: - Premium workspace shell
// The editing engine and Inspector remain unchanged; this file owns the visual shell,
// so the high-frequency editing controls stay stable while the workspace gains hierarchy.

struct PremiumMainWindow: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(spacing: 0) {
            PremiumTopBar()
            HSplitView {
                PremiumBrowserPane()
                    .frame(width: 320)
                PremiumWorkspace()
                    .frame(minWidth: 540, maxWidth: .infinity)
                InspectorPane()
                    .frame(width: 360)
                    .disabled(s.source == nil)
            }
            PremiumStatusBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(s.syncRunning)
        .sheet(isPresented: $s.showExport) { ExportSheet() }
        .sheet(isPresented: $s.showBatch) { BatchSheet() }
        .sheet(isPresented: $s.showMerge) { MergeSheet() }
        .sheet(isPresented: $s.showSync) { SyncSheet() }
        .sheet(isPresented: $s.showSnapshots) { SnapshotSheet() }
        .alert("操作未完成", isPresented: Binding(get: { s.workflowError != nil }, set: { if !$0 { s.workflowError = nil } })) {
            Button("好") { s.workflowError = nil }
        } message: { Text(s.workflowError ?? "") }
    }
}

struct PremiumTopBar: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .frame(width: 30, height: 30)
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("PHOS")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(1.4)
                        Text(s.folder?.lastPathComponent ?? "编辑工作区")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(width: 176, alignment: .leading)

                HStack(spacing: 4) {
                    PremiumToolButton(icon: "folder", label: "打开", help: "打开文件夹（⌘O）") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { s.openFolder(url) }
                    }
                    PremiumToolButton(icon: "square.on.square", label: "对比", active: s.showBefore, help: "前后对比（⌘B）") { s.showBefore.toggle() }
                    PremiumToolButton(icon: "scissors", label: "裁剪", active: s.cropMode, help: "裁剪（⌘R）") { s.toggleCropMode() }
                }
                .padding(4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Spacer(minLength: 10)

                HStack(spacing: 6) {
                    PremiumIconButton(icon: "arrow.uturn.backward", help: "撤销（⌘Z）", disabled: !s.history.canUndo) { s.undo() }
                    PremiumIconButton(icon: "arrow.uturn.forward", help: "重做（⇧⌘Z）", disabled: !s.history.canRedo) { s.redo() }
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 2)
                    Menu {
                        ForEach(s.loadPresets()) { preset in Button(preset.name) { s.commit(preset.params) } }
                        Divider()
                        Button("保存当前为预设…") { savePreset() }
                    } label: {
                        Label("预设", systemImage: "wand.and.stars")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                HStack(spacing: 5) {
                    PremiumIconButton(icon: "clock.arrow.circlepath", help: "命名快照", disabled: s.source == nil) { s.showSnapshots = true }
                    PremiumIconButton(icon: "doc.on.doc", help: "复制调整", disabled: s.source == nil) { s.copyAdjustments() }
                    PremiumIconButton(icon: "arrow.triangle.2.circlepath", help: "同步调整", disabled: s.source == nil) { s.showSync = true }
                    PremiumActionButton(title: "导出", icon: "square.and.arrow.down") { s.showExport = true }
                }
                .padding(4)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack(spacing: 14) {
                Text(s.current?.url.lastPathComponent ?? "未选择照片")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(s.current == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if s.source != nil {
                    Text("•").foregroundStyle(.tertiary)
                    Text(s.showBefore ? "原图预览" : "调整预览")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(s.showBefore ? .orange : .accentColor)
                }
                Spacer()
                HStack(spacing: 6) {
                    PremiumToggle(title: "全像素", isOn: $s.fullResPreview)
                    PremiumToggle(title: "1:1", isOn: $s.oneToOne) { s.fullResPreview = true }
                    if s.previewing { ProgressView().controlSize(.small).padding(.leading, 4) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
    }

    private func savePreset() {
        let alert = NSAlert(); alert.messageText = "预设名称"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "我的风格"; alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        var presets = s.loadPresets()
        presets.append(Preset(name: field.stringValue, params: s.params)); s.savePresets(presets)
    }
}

struct PremiumToolButton: View {
    let icon: String
    let label: String
    var active = false
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .padding(.horizontal, 9).frame(height: 26)
            .background((active ? Color.accentColor.opacity(0.13) : hovering ? Color.primary.opacity(0.07) : .clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain).help(help).onHover { hovering = $0 }
    }
}

struct PremiumIconButton: View {
    let icon: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : Color.primary)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain).disabled(disabled).help(help).onHover { hovering = $0 }
    }
}

struct PremiumActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11).frame(height: 28)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain).help(title)
    }
}

struct PremiumToggle: View {
    let title: String
    @Binding var isOn: Bool
    var onTurnOn: (() -> Void)? = nil
    var body: some View {
        Button {
            isOn.toggle(); if isOn { onTurnOn?() }
        } label: {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? .white : .secondary)
                .padding(.horizontal, 9).frame(height: 23)
                .background(isOn ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct PremiumBrowserPane: View {
    @EnvironmentObject var s: AppState
    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 166), spacing: 12)]
    private var count: Int { s.items.filter { s.filterRating == 0 || $0.rating >= s.filterRating }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("素材浏览").font(.system(size: 12, weight: .bold))
                    Text("\(count) 张照片").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("全部照片") { s.filterRating = 0 }
                    ForEach(1...5, id: \.self) { rating in Button("≥ \(rating) 星") { s.filterRating = rating } }
                } label: {
                    Image(systemName: s.filterRating == 0 ? "line.3.horizontal.decrease.circle" : "star.fill")
                        .foregroundStyle(s.filterRating == 0 ? Color.secondary : Color.yellow)
                        .frame(width: 28, height: 28)
                }.menuStyle(.borderlessButton).help("筛选照片")
            }
            .padding(.horizontal, 18).padding(.vertical, 16)

            if s.items.isEmpty {
                VStack(spacing: 11) {
                    Image(systemName: "photo.stack").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("还没有照片").font(.system(size: 12, weight: .semibold))
                    Text("从顶部打开一个素材文件夹").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(s.items.enumerated()), id: \.element.id) { index, item in
                            if s.filterRating == 0 || item.rating >= s.filterRating {
                                PremiumThumbCell(item: item, selected: index == s.currentIndex, checked: s.selectedPhotos.contains(item.id))
                                    .onTapGesture {
                                        if NSEvent.modifierFlags.contains(.command) {
                                            if s.selectedPhotos.contains(item.id) { s.selectedPhotos.remove(item.id) } else { s.selectedPhotos.insert(item.id) }
                                        } else { s.select(index) }
                                    }
                                    .onTapGesture(count: 2) { s.select(index) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                }
            }

            HStack(spacing: 8) {
                Label("已选 \(s.selectedPhotos.count)", systemImage: "checkmark.circle")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                PremiumIconButton(icon: "checkmark.square", help: "选择当前筛选的所有照片") {
                    s.selectedPhotos = Set(s.items.filter { s.filterRating == 0 || $0.rating >= s.filterRating }.map(\.id))
                }
                PremiumIconButton(icon: "xmark", help: "清除选择") { s.selectedPhotos = [] }
                PremiumIconButton(icon: "arrow.triangle.2.circlepath", help: "同步所选照片", disabled: s.selectedPhotos.isEmpty || s.source == nil) { s.showSync = true }
            }.padding(.horizontal, 12).padding(.vertical, 9)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
    }
}

struct PremiumThumbCell: View {
    let item: PhotoItem
    let selected: Bool
    let checked: Bool
    @EnvironmentObject var s: AppState
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let cg = item.thumb { Image(decorative: cg, scale: 1).resizable().scaledToFill() }
                    else { Rectangle().fill(.quaternary); ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity).aspectRatio(1.35, contentMode: .fit).clipped()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 1) {
                        ForEach(1...5, id: \.self) { i in Image(systemName: i <= item.rating ? "star.fill" : "star").font(.system(size: 7)).foregroundStyle(i <= item.rating ? .yellow : .white.opacity(0.8)) }
                    }.padding(.horizontal, 5).padding(.vertical, 4).background(.black.opacity(0.55), in: Capsule()).padding(6)
                }
                Button {
                    if checked { s.selectedPhotos.remove(item.id) } else { s.selectedPhotos.insert(item.id) }
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(checked ? Color.accentColor : .white)
                        .shadow(radius: 2).padding(7)
                }.buttonStyle(.plain).help("选择用于同步")
            }
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1))
            Text(item.url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 10, weight: selected ? .bold : .medium)).foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .scaleEffect(hovering && !selected ? 1.015 : 1)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct PremiumWorkspace: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(spacing: 0) {
            CanvasPane()
                .overlay(alignment: .topLeading) {
                    if s.source != nil {
                        HStack(spacing: 7) {
                            Circle().fill(s.showBefore ? .orange : .green).frame(width: 6, height: 6)
                            Text(s.showBefore ? "原图" : "实时预览").font(.system(size: 10, weight: .bold))
                            Text(s.oneToOne ? "100%" : "适合窗口").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).frame(height: 27)
                        .background(.ultraThinMaterial, in: Capsule()).padding(14)
                    }
                }
            PremiumHistogramBar()
        }
        .background(Color(nsColor: .rfCanvas))
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
    }
}

struct PremiumHistogramBar: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        HStack(spacing: 12) {
            HistogramView(bins: s.hist).frame(width: 238, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.showBefore ? "原始影像" : "调整后影像").font(.system(size: 11, weight: .bold))
                Text(s.sourceSize == .zero ? "等待载入" : String(format: "%d × %d", Int(s.sourceSize.width), Int(s.sourceSize.height)))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("预览质量").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Text(s.lastPreviewScale >= 0.999 ? "全像素" : String(format: "%d%% 代理", Int(s.lastPreviewScale * 100)))
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(s.lastPreviewScale >= 0.999 ? .green : .secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
    }
}

struct PremiumStatusBar: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(s.previewing ? .orange : .green).frame(width: 6, height: 6)
            Text(s.status).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let current = s.current {
                HStack(spacing: 4) {
                    Text(current.url.pathExtension.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    ForEach(1...5, id: \.self) { index in
                        Image(systemName: index <= current.rating ? "star.fill" : "star")
                            .font(.system(size: 10)).foregroundStyle(index <= current.rating ? .yellow : .secondary.opacity(0.45))
                            .onTapGesture { s.setRating(index == current.rating ? 0 : index) }
                    }
                    Button { s.togglePick() } label: { Image(systemName: current.picked ? "flag.fill" : "flag") }.buttonStyle(.plain).help("标记照片")
                }
            }
        }
        .padding(.horizontal, 16).frame(height: 29)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
    }
}
