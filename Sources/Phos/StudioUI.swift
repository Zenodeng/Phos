import AppKit
import SwiftUI

// Shared legacy content uses the workspace's system accent during its staged migration.
enum StudioStyle {
    static let panel = Color(nsColor: .rfDynamic(light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.075, alpha: 1)))
    static let surface = Color(nsColor: .rfDynamic(light: .white, dark: NSColor(white: 0.105, alpha: 1)))
    static let canvas = Color(nsColor: .rfDynamic(light: NSColor(white: 0.89, alpha: 1), dark: NSColor(white: 0.035, alpha: 1)))
    static let accent = WorkspaceTokens.accent
    static let line = Color.primary.opacity(0.10)
}

#if PHOS_TESTING || PHOS_BASELINE || PHOS_APPEARANCE_TEST || DEBUG
// The shipping editor has one root: WorkspaceWindow.
struct StudioMainWindow: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @AppStorage("rf.appearance") private var appearance = "system"
    var initialInspectorCategory: InspectorCategory = .light
    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar()
            HSplitView {
                StudioBrowser().frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
                StudioWorkspace().frame(minWidth: 440, maxWidth: .infinity)
                InspectorPane(initialCategory: initialInspectorCategory).frame(minWidth: 330, idealWidth: 360, maxWidth: 440)
            }
            // 手动「检查更新…」的结果。挂在 HSplitView 上，和上面的 workflowError 弹窗分开
            .alert("检查更新", isPresented: $s.showUpdateResult) {
                if s.availableUpdate != nil { Button(L10n.tr("前往下载")) { s.openUpdatePage() } }
                Button(L10n.tr("好"), role: .cancel) {}
            } message: {
                if let info = s.availableUpdate {
                    Text(L10n.tr("发现新版本 \(info.version)（当前 \(UpdateChecker.currentVersion)）。"))
                } else {
                    Text(L10n.tr("已是最新版本 \(UpdateChecker.currentVersion)。"))
                }
            }
            PremiumStatusBar()
        }
        // 启动时静默查一次版本：有新版才会在工具栏冒出提示图标
        .task { s.checkForUpdates(silent: true) }
        .background(StudioStyle.panel).tint(StudioStyle.accent)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .disabled(s.syncRunning)
        .sheet(isPresented: $s.showExport) { ExportSheet().tint(StudioStyle.accent) }
        .sheet(isPresented: $s.showBatch) { BatchSheet().tint(StudioStyle.accent) }
        .sheet(isPresented: $s.showMerge) { MergeSheet().tint(StudioStyle.accent) }
        .sheet(isPresented: $s.showSync) { SyncSheet().tint(StudioStyle.accent) }
        .sheet(isPresented: $s.showSnapshots) { SnapshotSheet().tint(StudioStyle.accent) }
        .onExitCommand { s.cancelMaskDrawing() }
        .alert("操作未完成", isPresented: Binding(get: { s.workflowError != nil }, set: { if !$0 { s.workflowError = nil } })) {
            Button(L10n.tr("好")) { s.workflowError = nil }
        } message: { Text(L10n.tr(s.workflowError ?? "")) }
    }
}

#endif

struct StudioToolbar: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    private func savePreset() {
        let alert = NSAlert(); alert.messageText = L10n.tr("预设名称")
        alert.addButton(withTitle: L10n.tr("保存")); alert.addButton(withTitle: L10n.tr("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var presets = s.loadPresets(); presets.append(Preset(name: name, params: s.params)); s.savePresets(presets)
    }
    @AppStorage("rf.appearance") private var appearance = "system"
    var body: some View {
        HStack(spacing: 8) {
            Label("Phos", systemImage: "camera.aperture").font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioStyle.accent)
            if let update = s.availableUpdate { UpdateBadge(info: update) }
            ToolDivider()
            ToolButton(systemImage: "folder", title: L10n.tr("打开文件夹")) {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                if p.runModal() == .OK, let url = p.url { s.openFolder(url) }
            }
            ToolButton(systemImage: "crop", title: L10n.tr("裁剪"), active: s.cropMode, disabled: s.source == nil) { s.toggleCropMode() }
            ToolButton(systemImage: "sparkles", title: L10n.tr("自动影调（强度滑杆在右侧检查器）"),
                       disabled: s.source == nil || s.autoRunning || s.syncRunning) { s.runAutoTone() }
            StudioHistoryButtons(history: s.history)
            Text(s.current?.url.lastPathComponent ?? "Phos Studio").font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle).frame(minWidth: 60, maxWidth: .infinity)
            Picker(L10n.tr("前后对比"), selection: $s.showBefore) {
                Text(L10n.tr("原图")).tag(true); Text(L10n.tr("调整")).tag(false)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 108).disabled(s.source == nil)
            ToolDivider()
            Menu {
                ForEach(s.loadPresets()) { preset in Button(preset.name) { s.commit(preset.params) } }
                Divider()
                Button(L10n.tr("保存当前为预设…")) { savePreset() }
            } label: { Image(systemName: "wand.and.stars").frame(width: 26) }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("预设")).disabled(s.source == nil)
            ToolButton(systemImage: "clock.arrow.circlepath", title: L10n.tr("命名快照"), disabled: s.source == nil) { s.showSnapshots = true }
            ToolButton(systemImage: "doc.on.doc", title: L10n.tr("复制调整"), disabled: s.source == nil) { s.copyAdjustments() }
            ToolButton(systemImage: "arrow.triangle.2.circlepath", title: L10n.tr("同步调整"), disabled: s.source == nil) { s.showSync = true }
            Menu {
                Button(L10n.tr("批量导出…")) { s.showBatch = true }.disabled(s.items.isEmpty)
                Button(L10n.tr("多重曝光合成…")) { s.showMerge = true }
                Divider()
                Picker(L10n.tr("外观"), selection: $appearance) {
                    Text(L10n.tr("跟随系统")).tag("system"); Text(L10n.tr("深色")).tag("dark"); Text(L10n.tr("浅色")).tag("light")
                }
                Divider()
                Button(L10n.tr("检查更新…")) { s.checkForUpdates(silent: false) }
            } label: { Image(systemName: "ellipsis").frame(width: 24) }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("更多操作与外观"))
            Button { s.showExport = true } label: { Label(L10n.tr("导出"), systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).disabled(s.source == nil || s.exportRunning)
        }.padding(.horizontal, 14).frame(height: 50).background(StudioStyle.panel)
            .overlay(alignment: .bottom) { Divider() }
    }
}

private struct StudioHistoryButtons: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @ObservedObject var history: History
    var body: some View {
        HStack(spacing: 2) {
            ToolButton(systemImage: "arrow.uturn.backward", title: L10n.tr("撤销"), disabled: !history.canUndo || s.source == nil) { s.undo() }
            ToolButton(systemImage: "arrow.uturn.forward", title: L10n.tr("重做"), disabled: !history.canRedo || s.source == nil) { s.redo() }
        }
    }
}

/// 发现新版本时才出现的小提示。平时完全不存在，不占位置。
private struct UpdateBadge: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    let info: UpdateInfo
    @State private var hover = false

    var body: some View {
        Button { s.openUpdatePage() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 11.5, weight: .semibold))
                Text(L10n.tr(info.version)).font(.system(size: 10.5, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .foregroundStyle(StudioStyle.accent)
            .background(Capsule().fill(StudioStyle.accent.opacity(hover ? 0.24 : 0.14)))
            .overlay(Capsule().stroke(StudioStyle.accent.opacity(hover ? 0.55 : 0.30), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L10n.tr("Phos \(info.version) 已发布，点击前往下载"))
    }
}

struct StudioBrowser: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    var transparent = false
    private var visible: [Int] { s.visiblePhotoIndices }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(L10n.tr("素材浏览")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Menu {
                        Button(L10n.tr("全部星级")) { s.filterRating = 0 }
                        ForEach(1...5, id: \.self) { n in Button(L10n.tr("至少 \(n) 星")) { s.filterRating = n } }
                        Toggle(L10n.tr("仅已标记"), isOn: $s.filterPicked)
                    } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 22) }
                        .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("筛选照片"))
                }
                Text(s.folder?.lastPathComponent ?? "未打开文件夹").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack {
                    Text(L10n.tr("\(visible.count) 张 · 已选 \(s.selectedPhotos.count)")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if s.filterRating > 0 || s.filterPicked {
                        Button { s.filterRating = 0; s.filterPicked = false } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help(L10n.tr("清除筛选"))
                    }
                }
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: 12) {
                        ForEach(visible, id: \.self) { index in
                            StudioThumbnail(item: s.items[index], selected: index == s.currentIndex)
                                .id(s.items[index].id)
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) { toggle(s.items[index].id) }
                                    else if NSEvent.modifierFlags.contains(.shift) {
                                        let low = max(0, min(s.currentIndex, index)), high = max(s.currentIndex, index)
                                        for i in visible where (low...high).contains(i) { s.selectedPhotos.insert(s.items[i].id) }
                                    } else { s.select(index) }
                                }
                        }
                    }.padding(12)
                }.overlay {
                    if visible.isEmpty { Text(L10n.tr(s.items.isEmpty ? "暂无照片" : "无匹配照片")).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .onChange(of: s.currentIndex) { _, _ in
                    if let current = s.current, visible.contains(s.currentIndex) { proxy.scrollTo(current.id, anchor: .center) }
                }
            }
            Divider()
            HStack {
                ToolButton(systemImage: "checkmark.square", title: L10n.tr("选择筛选结果"), disabled: visible.isEmpty) {
                    s.selectedPhotos = Set(visible.map { s.items[$0].id })
                }
                ToolButton(systemImage: "xmark", title: L10n.tr("取消多选"), disabled: s.selectedPhotos.isEmpty) { s.selectedPhotos = [] }
                Spacer()
                ToolButton(systemImage: "arrow.triangle.2.circlepath", title: L10n.tr("同步所选照片"), disabled: s.selectedPhotos.isEmpty || s.source == nil) { s.showSync = true }
            }.padding(.horizontal, 10).frame(height: 40)
        }.background(transparent ? Color.clear : StudioStyle.panel).clipped()
    }
    private func toggle(_ id: UUID) {
        if s.selectedPhotos.contains(id) { s.selectedPhotos.remove(id) } else { s.selectedPhotos.insert(id) }
    }
}

struct StudioThumbnail: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    let item: PhotoItem
    let selected: Bool
    private var checked: Bool { s.selectedPhotos.contains(item.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Image dimensions cannot expand the grid: the rectangle owns layout.
            Rectangle().fill(StudioStyle.canvas).aspectRatio(1.35, contentMode: .fit)
                .overlay {
                    if let image = item.thumb {
                        GeometryReader { geometry in
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    } else { Image(systemName: "photo").foregroundStyle(.secondary) }
                }.clipped().clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topTrailing) {
                    Button {
                        if checked { s.selectedPhotos.remove(item.id) } else { s.selectedPhotos.insert(item.id) }
                    } label: {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(checked ? StudioStyle.accent : .white).frame(width: 24, height: 24)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).padding(4).help(L10n.tr("选择用于同步"))
                }
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    Image(systemName: n <= item.rating ? "star.fill" : "star").font(.system(size: 8))
                        .foregroundStyle(n <= item.rating ? Color.yellow : Color.secondary.opacity(0.4))
                }
                Spacer(minLength: 0)
                if item.picked { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(StudioStyle.accent) }
            }
            Text(item.url.lastPathComponent).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle).help(item.url.lastPathComponent)
        }.padding(6).background(selected ? StudioStyle.accent.opacity(0.08) : StudioStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? StudioStyle.accent : StudioStyle.line, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(Rectangle())
    }
}

struct StudioWorkspace: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ToolButton(systemImage: "chevron.left", title: L10n.tr("上一张"), disabled: s.previousVisiblePhotoIndex == nil) {
                    if let index = s.previousVisiblePhotoIndex { s.select(index) }
                }
                ToolButton(systemImage: "chevron.right", title: L10n.tr("下一张"), disabled: s.nextVisiblePhotoIndex == nil) {
                    if let index = s.nextVisiblePhotoIndex { s.select(index) }
                }
                Text(L10n.tr(s.visiblePhotoPosition.map { "\($0) / \(s.visiblePhotoIndices.count)" } ?? "— / \(s.visiblePhotoIndices.count)"))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .help(s.visiblePhotoPosition == nil ? "当前照片不在筛选结果中" : "筛选结果中的位置")
                Spacer(minLength: 0)
                Toggle(L10n.tr("全像素"), isOn: $s.fullResPreview).toggleStyle(.checkbox).font(.system(size: 10)).disabled(s.source == nil)
                ToolButton(systemImage: "1.magnifyingglass", title: L10n.tr("1:1 检查"), active: s.oneToOne, disabled: s.source == nil || s.cropMode) { s.oneToOne.toggle() }
                ToolButton(systemImage: "arrow.up.left.and.arrow.down.right", title: L10n.tr("适合窗口"), disabled: s.source == nil) { s.oneToOne = false; s.canvasResetID = UUID() }
            }.padding(.horizontal, 10).frame(height: 38)
            CanvasPane().clipped()
            HStack(spacing: 12) {
                HistogramView(bins: s.hist).frame(width: 155, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("调整后直方图")).font(.system(size: 11, weight: .medium))
                    Text(L10n.tr(s.source == nil ? "—" : "\(Int(s.sourceSize.width)) × \(Int(s.sourceSize.height))"))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if s.previewing { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 14).frame(height: 62)
        }.background(StudioStyle.canvas)
    }
}
