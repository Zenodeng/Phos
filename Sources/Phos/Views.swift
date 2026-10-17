import SwiftUI
import CoreImage
import UniformTypeIdentifiers

// MARK: - 便捷改参（拖动时实时渲染，松手才进历史栈）
extension AppState {
    func set<T>(_ kp: WritableKeyPath<EditParams, T>, _ v: T) {
        params[keyPath: kp] = v
        render()
    }
    func endEdit() {
        history.push(params)
        saveCurrent()
    }
}

// MARK: - 通用滑块行
enum SliderRoundTripPolicy {
    /// A native slider can echo a few ULPs of normalization noise while refreshing.
    /// It is not an edit and must not change the stored photo parameters.
    static func isEdit(_ proposed: Double, current: Double, range: ClosedRange<Double>) -> Bool {
        guard proposed.isFinite, current.isFinite else { return false }
        let tolerance = 8 * max(max(current.ulp, proposed.ulp), (range.upperBound - range.lowerBound).ulp)
        return abs(proposed - current) > tolerance
    }
}

struct SliderRow: View {
    @EnvironmentObject private var photoState: AppState
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var response: Double = 1
    var defaultValue: Double = 0
    var unit = ""
    var decimals: Int? = nil
    var step: Double = 1
    var photoScoped = true
    var onEdit: () -> Void = {}
    @State private var draft = ""
    @State private var initialDraft = ""
    @State private var invalid = false
    @State private var inputToken: ParameterEditCoordinator.Token?
    @State private var sliderToken: ParameterEditCoordinator.Token?
    @State private var localStart: Double = 0
    @State private var sliderActive = false
    @State private var sliderCancelled = false
    @State private var numericActive = false
    @FocusState private var focused: Bool
    private var precision: Int { decimals ?? (range.upperBound - range.lowerBound >= 50 ? 0 : 2) }
    private var formatted: String { String(format:"%.*f",precision,value) }
    private var modified: Bool { value != defaultValue }
    private var bipolar: Bool { range.lowerBound < 0 && range.upperBound > 0 }
    private func position(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        if response == 1 { return (v-range.lowerBound)/span }
        if bipolar {
            let n = min(max(v/max(abs(range.lowerBound),abs(range.upperBound)),-1),1)
            return ((n < 0 ? -1 : 1)*pow(abs(n),1/response)+1)/2
        }
        return pow(min(max((v-range.lowerBound)/span,0),1),1/response)
    }
    private func actual(_ position: Double) -> Double {
        let u = min(max(position,0),1), span = range.upperBound-range.lowerBound
        if response == 1 { return range.lowerBound+u*span }
        if bipolar { let n = (u-0.5)*2; return (n < 0 ? -1 : 1)*pow(abs(n),response)*max(abs(range.lowerBound),abs(range.upperBound)) }
        return range.lowerBound+pow(u,response)*span
    }
    private var sliderBinding: Binding<Double> {
        Binding(get:{ position(value) },set:{ next in
            guard !sliderCancelled else { return }
            if photoScoped, let sliderToken, !photoState.parameterEdits.valid(sliderToken) { sliderCancelled = true; return }
            let candidate = actual(next)
            guard SliderRoundTripPolicy.isEdit(candidate,current:value,range:range) else { return }
            beginSlider(); value = candidate
        })
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:6) {
                Text(label).font(.system(size:12)).foregroundStyle(WorkspaceTokens.primaryText)
                    .lineLimit(1).help(label)
                if modified { Circle().fill(WorkspaceTokens.accent).frame(width:3,height:3).accessibilityLabel("已修改") }
                Spacer(minLength:4)
                if !unit.isEmpty { Text(unit).font(.system(size:10)).foregroundStyle(WorkspaceTokens.secondaryText) }
                TextField(label,text:$draft)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size:11,design:.monospaced)).monospacedDigit()
                    .foregroundStyle(invalid ? WorkspaceTokens.error : WorkspaceTokens.primaryText)
                    .padding(.horizontal,6).frame(width:62,height:22)
                    .background(WorkspaceTokens.readoutColor,in:RoundedRectangle(cornerRadius:5))
                    .overlay(RoundedRectangle(cornerRadius:5).strokeBorder(invalid ? WorkspaceTokens.error : focused ? WorkspaceTokens.accent : WorkspaceTokens.hairline,lineWidth:focused || invalid ? 1.5 : 0.5).allowsHitTesting(false))
                    .focused($focused).onSubmit { commitInput(leaving:false) }
                    .onExitCommand { cancelInput() }
                    .onChange(of:focused) { _, active in if active { startInput() } else { commitInput(leaving:true) } }
                    .accessibilityLabel(label+"数值").accessibilityHint(invalid ? "请输入有效数字" : "Enter确认，Esc取消")
                    .help("输入数值，Enter确认，Esc取消；范围 \(range.lowerBound) 至 \(range.upperBound)")
            }.frame(height:24)
            ZStack(alignment:.leading) {
                Slider(value:sliderBinding,in:0...1) { editing in
                    if editing { sliderCancelled = false; beginSlider() }
                    else { if sliderActive { finishSlider() }; sliderCancelled = false }
                }.controlSize(.mini).tint(WorkspaceTokens.accent).accessibilityLabel(label+"滑杆")
                GeometryReader { g in
                    Rectangle().fill(WorkspaceTokens.secondaryText.opacity(0.5)).frame(width:1,height:4)
                        .position(x:6+CGFloat(position(defaultValue))*(g.size.width-12),y:g.size.height/2)
                }.allowsHitTesting(false)
            }.frame(height:18)
            if invalid { Text("请输入有效数字").font(.system(size:10)).foregroundStyle(WorkspaceTokens.error).frame(maxWidth:.infinity,alignment:.trailing) }
        }.frame(minHeight:44)
        .onAppear { draft = formatted }
        .onChange(of:value) { _, _ in if !focused { draft = formatted } }
        .onChange(of:photoState.parameterInputGeneration) { _, _ in resetInput() }
        .onExitCommand {
            if numericActive { cancelInput() }
            else if sliderToken != nil { photoState.parameterEdits.invalidate(); sliderToken = nil }
        }
        .contextMenu { Button("复位"+label) { photoState.parameterEdits.invalidate(); if value != defaultValue { value = defaultValue; onEdit() } }.disabled(!modified) }
    }
    private func startInput() {
        initialDraft = String(value); draft = initialDraft; invalid = false; numericActive = true
        if photoScoped { inputToken = photoState.parameterEdits.begin(finish:{ commitInput(leaving:true) },cancel:{ resetInput() }) }
    }
    private func commitInput(leaving: Bool) {
        guard numericActive else { return }
        if photoScoped && !photoState.parameterEdits.valid(inputToken) { resetInput(); return }
        guard draft != initialDraft else { finishInput(); return }
        guard let parsed = ParameterInputPolicy.value(draft,in:range) else {
            invalid = true
            if leaving { cancelInput() }
            return
        }
        if photoScoped { _ = photoState.parameterEdits.complete(inputToken) }
        numericActive = false
        if parsed != value { value = parsed; onEdit() }
        resetInput()
    }
    private func finishInput() {
        if photoScoped { _ = photoState.parameterEdits.complete(inputToken) }
        resetInput()
    }
    private func resetInput() { if sliderActive { sliderCancelled = true }; numericActive = false; inputToken = nil; sliderToken = nil; sliderActive = false; invalid = false; draft = formatted; focused = false }
    private func cancelInput() {
        if photoScoped && photoState.parameterEdits.valid(inputToken) { photoState.parameterEdits.invalidate() }
        resetInput()
    }
    private func beginSlider() {
        guard !sliderActive else { return }
        sliderActive = true; localStart = value
        if photoScoped { sliderToken = photoState.parameterEdits.begin() }
    }
    private func finishSlider() {
        if photoScoped { guard photoState.parameterEdits.complete(sliderToken) else { sliderToken = nil; return } }
        sliderToken = nil; sliderActive = false; if value != localStart { onEdit() }
    }
}

// MARK: - 主窗口
struct MainWindow: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            HSplitView {
                BrowserPane().frame(minWidth: 200, idealWidth: 250, maxWidth: 380)
                VStack(spacing: 0) {
                    CanvasPane()
                    HistogramBar()
                }
                .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .rfDivider)).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: .rfDivider)).frame(width: 1) }
                .frame(minWidth: 520)
                InspectorPane().frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                    .disabled(s.source == nil)
            }
            StatusBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Rectangle().fill(Color.accentColor.opacity(0.65)).frame(height: 2) }
        .disabled(s.syncRunning)
        .sheet(isPresented: $s.showExport) { ExportSheet() }
        .sheet(isPresented: $s.showBatch) { BatchSheet() }
        .sheet(isPresented: $s.showMerge) { MergeSheet() }
        .sheet(isPresented: $s.showSync) { SyncSheet() }
        .sheet(isPresented: $s.showSnapshots) { SnapshotSheet() }
        .alert("操作未完成", isPresented: Binding(get: { s.workflowError != nil },
                                                set: { if !$0 { s.workflowError = nil } })) {
            Button("好") { s.workflowError = nil }
        } message: { Text(s.workflowError ?? "") }
    }
}

// MARK: - 顶栏
struct TopBar: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        HStack(spacing: 6) {
            ToolButton(systemImage: "folder", title: "打开文件夹（⌘O）") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                if p.runModal() == .OK, let u = p.url { s.openFolder(u) }
            }
            ToolDivider()
            ToolButton(systemImage: "square.on.square", title: "前后对比（⌘B）",
                       active: s.showBefore) { s.showBefore.toggle() }
            ToolDivider()
            PillToggle(title: "全像素", isOn: $s.fullResPreview,
                       helpText: "关：预览走 2200px 代理图（快）。开：整条管线按原图全分辨率渲染（慢但所见即所得）")
            PillButton(title: "1:1", active: s.oneToOne,
                       helpText: "按屏幕像素 1:1 显示，检查锐度用") {
                s.fullResPreview = true
                s.oneToOne.toggle()
            }
            ToolDivider()
            ToolButton(systemImage: "arrow.uturn.backward", title: "撤销（⌘Z）",
                       disabled: !s.history.canUndo) { s.undo() }
            ToolButton(systemImage: "arrow.uturn.forward", title: "重做（⇧⌘Z）",
                       disabled: !s.history.canRedo) { s.redo() }
            ToolDivider()
            Menu {
                ForEach(s.loadPresets()) { p in
                    Button(p.name) { s.commit(p.params) }
                }
                Divider()
                Button("保存当前为预设…") { savePreset() }
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 30, height: 26)
                    .foregroundStyle(Color.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("预设")
            ToolButton(systemImage: "clock.arrow.circlepath", title: "命名快照",
                       disabled: s.source == nil) { s.showSnapshots = true }
            ToolButton(systemImage: "doc.on.doc", title: "复制调整",
                       disabled: s.source == nil) { s.copyAdjustments() }
            ToolButton(systemImage: "arrow.triangle.2.circlepath", title: "同步调整",
                       disabled: s.source == nil) { s.showSync = true }
            ToolDivider()
            ToolButton(systemImage: "square.and.arrow.down", title: "导出当前照片（⌘E）") {
                s.showExport = true
            }
            ToolButton(systemImage: "tray.and.arrow.down", title: "批量导出") {
                s.showBatch = true
            }
            ToolDivider()
            ToolButton(systemImage: "scissors", title: "裁剪（⌘R）",
                       active: s.cropMode, shortcut: "r") { s.toggleCropMode() }
            ToolButton(systemImage: "rectangle.stack", title: "多重曝光合成（⇧⌘M）") {
                s.showMerge = true
            }
            Spacer()
            if s.previewing {
                ProgressView().controlSize(.small).padding(.trailing, 2)
            }
            Text(s.current?.url.lastPathComponent ?? "未打开")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    func savePreset() {
        let a = NSAlert()
        a.messageText = "预设名称"
        a.addButton(withTitle: "保存"); a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.placeholderString = "我的风格"
        a.accessoryView = tf
        guard a.runModal() == .alertFirstButtonReturn, !tf.stringValue.isEmpty else { return }
        var ps = s.loadPresets()
        ps.append(Preset(name: tf.stringValue, params: s.params))
        s.savePresets(ps)
    }
}

// MARK: - 浏览器
struct BrowserPane: View {
    @EnvironmentObject var s: AppState
    let cols = [GridItem(.adaptive(minimum: 92), spacing: 8)]
    var visibleCount: Int {
        s.items.filter { s.filterRating == 0 || $0.rating >= s.filterRating }.count
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(s.folder?.lastPathComponent ?? "未选择文件夹")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(visibleCount)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .rfPill)))
                Menu {
                    Button("全部") { s.filterRating = 0 }
                    ForEach(1...5, id: \.self) { r in
                        Button("≥ \(r) 星") { s.filterRating = r }
                    }
                } label: {
                    Image(systemName: s.filterRating == 0 ? "line.3.horizontal.decrease" : "star.fill")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 9).padding(.vertical, 7)

            ScrollView {
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(Array(s.items.enumerated()), id: \.element.id) { idx, it in
                        if s.filterRating == 0 || it.rating >= s.filterRating {
                            ThumbCell(item: it, selected: idx == s.currentIndex)
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        if s.selectedPhotos.contains(it.id) { s.selectedPhotos.remove(it.id) }
                                        else { s.selectedPhotos.insert(it.id) }
                                    } else if NSEvent.modifierFlags.contains(.shift) {
                                        let start = max(0, min(s.currentIndex, idx)), end = max(s.currentIndex, idx)
                                        for index in start...end where s.filterRating == 0 || s.items[index].rating >= s.filterRating {
                                            s.selectedPhotos.insert(s.items[index].id)
                                        }
                                    } else { s.select(idx) }
                                }
                                .overlay(alignment: .topLeading) {
                                    Button {
                                        if s.selectedPhotos.contains(it.id) { s.selectedPhotos.remove(it.id) }
                                        else { s.selectedPhotos.insert(it.id) }
                                    } label: {
                                        Image(systemName: s.selectedPhotos.contains(it.id) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(.white)
                                            .padding(4).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                                    }.buttonStyle(.plain).help("选择用于同步：\(it.url.lastPathComponent)")
                                        .padding(3)
                                }
                        }
                    }
                }
                .padding(8)
            }
            Divider()
            HStack {
                Text("已选 \(s.selectedPhotos.count)").font(.caption).monospacedDigit()
                Spacer()
                ToolButton(systemImage: "checkmark.square", title: "选择当前筛选的所有照片") {
                    s.selectedPhotos = Set(s.items.filter { s.filterRating == 0 || $0.rating >= s.filterRating }.map(\.id))
                }
                ToolButton(systemImage: "xmark", title: "清除选择") { s.selectedPhotos = [] }
                ToolButton(systemImage: "arrow.triangle.2.circlepath", title: "同步所选照片",
                           disabled: s.selectedPhotos.isEmpty || s.source == nil) { s.showSync = true }
            }.padding(6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ThumbCell: View {
    let item: PhotoItem
    let selected: Bool
    @State private var hover = false
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let cg = item.thumb {
                    Image(decorative: cg, scale: 1).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .frame(width: 92, height: 92).clipped()
            .cornerRadius(6)

            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= item.rating ? "star.fill" : "star")
                        .font(.system(size: 7))
                        .foregroundStyle(i <= item.rating ? .yellow : .white.opacity(0.75))
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(4)

            if item.picked {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.system(size: 15))
                    .padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .scaleEffect(hover && !selected ? 1.03 : 1)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? Color.accentColor : Color(nsColor: .rfCardBorder),
                    lineWidth: selected ? 2.5 : 0.5))
        .shadow(color: selected ? Color.accentColor.opacity(0.35) : .clear,
                radius: 5, x: 0, y: 2)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - 画布
struct CanvasPane: View {
    @EnvironmentObject var s: AppState
    @ObservedObject var session: WorkspaceSessionState = WorkspaceSessionState(persist: false)
    @State private var canvasSize: CGSize = .zero
    @State private var gestureScale: CGFloat?
    @State private var panOrigin: CGSize?
    @State private var maskOrigin: Mask?
    @State private var maskGestureStart: CGPoint?
    @State private var drawingStart: CGPoint?
    @State private var drawingOriginal: Mask?
    @State private var maskOriginSize: CGSize = .zero
    @State private var lastBrush: CGPoint?
    @State private var painting = false
    @State private var sampled = false

    /// 当前可以在画布上直接拖控制点的蒙版：位置调整模式、非裁剪、非对比、非白平衡取样。
    /// 适合窗口与 1:1 两个分支共用，避免两边条件写歪。
    private var editableMask: Mask? {
        guard !s.cropMode, !s.showBefore, !s.whiteBalancePicker, s.maskTool == .position else { return nil }
        return s.maskDraft ?? s.selectedMask.flatMap { id in s.params.masks.first(where: { $0.id == id }) }
    }

    private var preciseTool: Bool { s.cropMode || s.whiteBalancePicker || s.selectedMask != nil || s.maskDrawingKind != nil }
    private func layout(_ size: CGSize) -> WorkspaceLayout {
        WorkspaceLayout.resolve(size: size, topInset: session.topInset, browserVisible: session.browserVisible,
                                inspectorVisible: session.inspectorVisible, mode: session.mode,
                                browserWidth: session.browserWidth, inspectorWidth: session.inspectorWidth)
    }
    private func imageRect(_ frame: PreviewFrame?, layout: WorkspaceLayout) -> CGRect {
        guard let frame else { return .zero }
        var safe = layout.safeCanvas
        if s.cropMode { safe.origin.y += 42; safe.size.height = max(1, safe.height - 42) }
        if preciseTool { return DisplayTransform.rect(bitmap: frame.bitmapSize, in: safe, fill: false) }
        if session.viewport.mode == .manual {
            let factor = session.viewport.screenPixelsPerEditedPixel / max(session.backingScale, 1)
            let size = CGSize(width: frame.editedExtent.width * factor, height: frame.editedExtent.height * factor)
            let center = session.viewport.editedImageCenter
            return CGRect(x: safe.midX - center.x * size.width, y: safe.midY - (1 - center.y) * size.height,
                          width: size.width, height: size.height)
        }
        return DisplayTransform.rect(bitmap: frame.bitmapSize, in: session.usesFill ? layout.canvas : safe, fill: session.usesFill)
    }
    private var frame: PreviewFrame? {
        guard let frame = s.displayFrame, frame.key.photoID == s.current?.id else { return nil }
        let purpose: PreviewPurpose = s.showBefore ? .beforeOriginal : s.cropMode ? .cropReference : .edited
        return frame.key.purpose == purpose ? frame : nil
    }
    var body: some View {
        GeometryReader { geo in
            let shell = layout(geo.size)
            let displayed = frame
            let rect = imageRect(displayed, layout: shell)
            let pixelReady = s.oneToOne && displayed?.fullResolution == true
            ZStack(alignment: .topLeading) {
                StudioStyle.canvas
                if let displayed, pixelReady {
                    let pixelSize = CGSize(width: CGFloat(displayed.image.width) / max(session.backingScale, 1),
                                           height: CGFloat(displayed.image.height) / max(session.backingScale, 1))
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: displayed.image, scale: 1).resizable()
                            .frame(width: pixelSize.width, height: pixelSize.height)
                            .overlay { selectionOverlay(width: pixelSize.width, height: pixelSize.height) }
                            .overlay(alignment: .topLeading) {
                                if let mask = editableMask { MaskOverlay(mask: mask, frame: CGRect(origin: .zero, size: pixelSize)) }
                            }
                            .gesture(canvasGesture(frame: CGRect(origin: .zero, size: pixelSize), pixelView: true),
                                     including: s.selectedMask != nil || s.whiteBalancePicker ? .all : .subviews)
                    }
                    .frame(width: shell.safeCanvas.width, height: shell.safeCanvas.height)
                    .offset(x: shell.safeCanvas.minX, y: shell.safeCanvas.minY)
                } else if let displayed {
                    Image(decorative: displayed.image, scale: 1).resizable()
                        .frame(width: rect.width, height: rect.height)
                        .overlay { selectionOverlay(width: rect.width, height: rect.height) }
                        .overlay(alignment: .topLeading) {
                            if let mask = editableMask { MaskOverlay(mask: mask, frame: CGRect(origin: .zero, size: rect.size)) }
                        }
                        .position(x: rect.midX, y: rect.midY)
                } else {
                    VStack(spacing: 12) {
                        if s.previewing || s.folderLoading { ProgressView().controlSize(.small) }
                        else { Image(systemName: s.current == nil ? "photo.on.rectangle.angled" : "exclamationmark.triangle").font(.system(size: 32, weight: .light)) }
                        Text(s.previewing ? "正在准备照片…" : s.current == nil ? "打开文件夹开始编辑" : s.status).font(.system(size: 13))
                        if s.current == nil { Text("RAW · HEIF · JPEG · PNG · TIFF · AVIF").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    .frame(width: shell.safeCanvas.width, height: shell.safeCanvas.height)
                    .position(x: shell.safeCanvas.midX, y: shell.safeCanvas.midY)
                }
                if s.cropMode, displayed != nil, !pixelReady {
                    CropOverlay(frame: rect)
                    CropBar().frame(width: shell.safeCanvas.width, height: shell.safeCanvas.height)
                        .offset(x: shell.safeCanvas.minX, y: shell.safeCanvas.minY)
                }
                if s.oneToOne && !pixelReady && displayed != nil {
                    Label("正在准备完整像素…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11)).padding(8).background(.regularMaterial, in: Capsule())
                        .position(x: shell.safeCanvas.midX, y: shell.safeCanvas.minY + 20)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(canvasGesture(frame: rect), including: pixelReady ? .subviews : .all)
            .simultaneousGesture(MagnificationGesture().onChanged { value in
                guard let displayed, !preciseTool, !s.oneToOne else { return }
                let transform = DisplayTransform(frame: displayed, imageRect: rect, backingScale: session.backingScale)
                if gestureScale == nil {
                    gestureScale = transform.screenPixelsPerEditedPixel
                    session.viewport.editedImageCenter = transform.normalizedPoint(CGPoint(x: shell.safeCanvas.midX, y: shell.safeCanvas.midY), requireInside: false) ?? CGPoint(x: 0.5, y: 0.5)
                }
                session.viewport.mode = .manual
                session.viewport.screenPixelsPerEditedPixel = min(max((gestureScale ?? 1) * value, 0.02), 16)
            }.onEnded { _ in gestureScale = nil })
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, size in canvasSize = size }
            .onChange(of: s.current?.id) { _, _ in session.viewport.editedImageCenter = CGPoint(x: 0.5, y: 0.5); panOrigin = nil }
            .onChange(of: s.canvasResetID) { _, _ in session.viewport.editedImageCenter = CGPoint(x: 0.5, y: 0.5); gestureScale = nil }
        }
    }

    @ViewBuilder
    func selectionOverlay(width: CGFloat, height: CGFloat) -> some View {
        if s.showMaskOverlay, !s.showBefore, !s.cropMode,
           s.previewFrame?.maskID == (s.maskDraft?.id ?? s.selectedMask), let mask = s.previewFrame?.mask {
            Color.red.opacity(0.45)
                .mask(Image(decorative: mask, scale: 1).resizable().luminanceToAlpha())
                .frame(width: width, height: height).allowsHitTesting(false)
        }
    }

    /// 只挂一个拖拽手势，内部按当前状态分流 —— 以前挂了三个 gesture，
    /// 平移手势在最外层会把事件吞掉，画笔永远收不到点，这是画笔失效的根因。
    func canvasGesture(frame: CGRect, pixelView: Bool = false) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard (!s.oneToOne || pixelView), !s.cropMode, !s.showBefore else { return }
                guard frame.contains(v.startLocation) else { return }
                if s.whiteBalancePicker { return }
                if let drawingKind = s.maskDrawingKind {
                    drawGradient(v.location, start: v.startLocation, frame: frame, kind: drawingKind)
                    return
                }
                if let id = s.selectedMask,
                   let m = s.params.masks.first(where: { $0.id == id }) {
                    if s.maskTool != .position {
                        paint(v.location, frame: frame, mask: m, refining: true)
                        return
                    }
                    switch m.kind {
                    case .brush, .depth:
                        paint(v.location, frame: frame, mask: m)
                    case .linear, .radial:
                        if maskGestureStart == nil {
                            maskGestureStart = v.startLocation
                            maskOrigin = m
                            maskOriginSize = CGSize(width: frame.width, height: frame.height)
                        }
                        let start = maskGestureStart ?? v.startLocation
                        let origin = maskOrigin ?? m
                        let updated = MaskGeometry.dragging(origin, control: .move,
                                                            from: start, to: v.location,
                                                            size: maskOriginSize,
                                                            constrained: NSEvent.modifierFlags.contains(.shift))
                        s.updateMaskLive(updated)
                    case .colorRange, .luminanceRange:
                        // 取样类蒙版：在画布上拖到哪儿就取哪儿的颜色/亮度
                        sample(v.location, frame: frame, mask: m)
                    case .subject, .person, .foreground:
                        break        // AI 蒙版不需要手绘
                    }
                } else {
                    guard let displayed = self.frame else { return }
                    if panOrigin == nil { panOrigin = CGSize(width: frame.minX, height: frame.minY) }
                    let moved = CGRect(x: (panOrigin?.width ?? 0) + v.translation.width,
                                       y: (panOrigin?.height ?? 0) + v.translation.height,
                                       width: frame.width, height: frame.height)
                    let transform = DisplayTransform(frame: displayed, imageRect: moved, backingScale: session.backingScale)
                    // The safe viewport is anchored at the same edited-image point in either layout.
                    let shell = layout(canvasSize)
                    let anchor = CGPoint(x: shell.safeCanvas.midX, y: shell.safeCanvas.midY)
                    session.viewport.editedImageCenter = transform.normalizedPoint(anchor, requireInside: false) ?? CGPoint(x: 0.5, y: 0.5)
                    session.viewport.screenPixelsPerEditedPixel = transform.screenPixelsPerEditedPixel
                    session.viewport.mode = .manual
                }
            }
            .onEnded { value in
                if s.whiteBalancePicker, !s.cropMode, !s.showBefore, frame.contains(value.location) {
                    s.sampleWhiteBalance(at: CGPoint(x: (value.location.x - frame.minX) / frame.width,
                                                    y: 1 - (value.location.y - frame.minY) / frame.height))
                }
                if s.maskDrawingKind != nil {
                    s.finishMaskDrawing()
                } else if painting { painting = false; s.endEdit() }
                else if maskOrigin != nil || sampled { s.endEdit() }
                panOrigin = nil; maskOrigin = nil; maskGestureStart = nil
                drawingStart = nil; drawingOriginal = nil; maskOriginSize = .zero
                lastBrush = nil; sampled = false
            }
    }

    /// 画笔：屏幕点 → 归一化坐标（y 向上，跟引擎里的笔刷位图一致）
    func paint(_ loc: CGPoint, frame: CGRect, mask m: Mask, refining: Bool = false) {
        let p = CGPoint(x: min(max((loc.x - frame.minX) / max(frame.width, 1), 0), 1),
                        y: min(max(1 - (loc.y - frame.minY) / max(frame.height, 1), 0), 1))
        var mm = m
        var strokes = refining ? mm.refinements : mm.strokes
        if !painting {
            painting = true
            let rad = refining ? s.brushRadius : (mm.strokes.last?.radius ?? 0.05)
            strokes.append(Stroke(pts: [[Double(p.x), Double(p.y)]], radius: rad,
                                  feather: refining ? s.brushFeather : mm.feather, erasing: refining && s.maskTool == .erase))
            if refining { mm.refinements = strokes } else { mm.strokes = strokes }
            lastBrush = p
            s.updateMaskLive(mm)
            return
        }
        guard !strokes.isEmpty else { return }
        let from = lastBrush ?? p
        // 中间补点：手快拖过时不会画成一串断开的圆点
        let step = max(0.003, (strokes.last?.radius ?? 0.05) / 4)
        let dx = Double(p.x - from.x), dy = Double(p.y - from.y)
        let dist = (dx * dx + dy * dy).squareRoot()
        let n = max(1, Int(dist / step))
        for i in 1...n {
            let t = Double(i) / Double(n)
            strokes[strokes.count - 1].pts.append([Double(from.x) + dx * t, Double(from.y) + dy * t])
        }
        if refining { mm.refinements = strokes } else { mm.strokes = strokes }
        lastBrush = p
        s.updateMaskLive(mm)
    }

    /// 颜色范围 / 亮度范围蒙版：在画布上拖到哪儿就取哪儿
    func sample(_ loc: CGPoint, frame: CGRect, mask m: Mask) {
        guard let cg = s.preview else { return }
        let nx = min(max((loc.x - frame.minX) / max(frame.width, 1), 0), 1)
        let ny = min(max(1 - (loc.y - frame.minY) / max(frame.height, 1), 0), 1)
        let px = min(cg.width - 1, Int(nx * CGFloat(cg.width))), py = min(cg.height - 1, Int(ny * CGFloat(cg.height)))
        var buf = [UInt8](repeating: 0, count: 4)
        Engine.ctx.render(CIImage(cgImage: cg), toBitmap: &buf, rowBytes: 4,
                          bounds: CGRect(x: px, y: py, width: 1, height: 1),
                          format: .RGBA8, colorSpace: Engine.srgb)
        let r = Double(buf[0]) / 255, g = Double(buf[1]) / 255, b = Double(buf[2]) / 255
        var mm = m
        if m.kind == .colorRange {
            mm.sampleRGB = [r, g, b]
        } else {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let half = max(mm.lumSoft, 0.08) * 0.7
            mm.lumLow = min(max(y - half, 0), 1)
            mm.lumHigh = min(max(y + half, 0), 1)
        }
        sampled = true
        s.updateMaskLive(mm)
    }

    /// 线性 / 径向蒙版：在画布上直接拖，整体位移（旧手势兼容入口）
    func moveMask(_ t: CGSize, frame: CGRect, mask m: Mask) {
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: start.x + t.width, y: start.y + t.height)
        let updated = MaskGeometry.dragging(m, control: .move, from: start, to: end,
                                            size: frame.size)
        s.updateMaskLive(updated)
    }

    func drawGradient(_ loc: CGPoint, start: CGPoint, frame: CGRect, kind: MaskKind) {
        guard frame.width > 1, frame.height > 1 else { return }
        let localStart = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
        let localEnd = CGPoint(x: loc.x - frame.minX, y: loc.y - frame.minY)
        let size = frame.size
        var original = drawingOriginal
        if original == nil {
            var mask = s.maskDrawingTarget.flatMap { id in
                s.params.masks.first(where: { $0.id == id })
            } ?? Mask()
            mask.kind = kind
            mask.name = mask.name == "蒙版" ? kind.label : mask.name
            mask.id = s.maskDrawingTarget ?? mask.id
            original = mask
            drawingOriginal = mask
            drawingStart = localStart
        }
        guard let original, let drawingStart else { return }
        let draft = MaskGeometry.drawing(original, from: drawingStart, to: localEnd,
                                         size: size,
                                         constrained: NSEvent.modifierFlags.contains(.shift))
        s.updateMaskDraft(draft)
    }
}

// MARK: - 蒙版操作层
struct MaskOverlay: View {
    @EnvironmentObject var s: AppState
    let mask: Mask
    let frame: CGRect

    private var size: CGSize { frame.size }
    private var center: CGPoint {
        let p = MaskGeometry.center(mask, size: size)
        return CGPoint(x: p.x, y: frame.height - p.y)
    }
    private var angle: Double { -MaskGeometry.angle(mask, size: size) }
    private var radii: CGSize { MaskGeometry.radii(mask, size: size) }

    var body: some View {
        ZStack {
            if mask.kind == .linear {
                linearGuides
            } else if mask.kind == .radial {
                radialGuides
            }
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }

    private var linearGuides: some View {
        let p0 = CGPoint(x: frame.width * CGFloat(mask.x0), y: frame.height * CGFloat(1 - mask.y0))
        let p1 = CGPoint(x: frame.width * CGFloat(mask.x1), y: frame.height * CGFloat(1 - mask.y1))
        let c = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = max(hypot(dx, dy), 1)
        let nx = -dy / len, ny = dx / len
        // 参考线沿法线双向延伸的长度。原先取画面高度，宽幅照片（长边 2200、高很小）时
        // 不够长，三条线画不到画面边缘；取对角线长度在任何画幅下都覆盖得住。
        let reach: CGFloat = hypot(frame.width, frame.height)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: p0.x - nx * reach, y: p0.y - ny * reach))
                path.addLine(to: CGPoint(x: p0.x + nx * reach, y: p0.y + ny * reach))
                path.move(to: CGPoint(x: c.x - nx * reach, y: c.y - ny * reach))
                path.addLine(to: CGPoint(x: c.x + nx * reach, y: c.y + ny * reach))
                path.move(to: CGPoint(x: p1.x - nx * reach, y: p1.y - ny * reach))
                path.addLine(to: CGPoint(x: p1.x + nx * reach, y: p1.y + ny * reach))
            }
            .stroke(Color.white.opacity(0.78), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            Handle(position: p0, color: .cyan, onMove: { start, end in
                edit(.linearStart, from: start, to: end)
            }, onEnd: { endDrag() })
            Handle(position: p1, color: .cyan, onMove: { start, end in
                edit(.linearEnd, from: start, to: end)
            }, onEnd: { endDrag() })
            Handle(position: c, color: .white, size: 12, onMove: { start, end in
                edit(.move, from: start, to: end)
            }, onEnd: { endDrag() })
            Handle(position: CGPoint(x: c.x + nx * 26, y: c.y + ny * 26), color: .orange, size: 12,
                   onMove: { start, end in edit(.rotate, from: start, to: end) },
                   onEnd: { endDrag() })
        }
    }

    private var radialGuides: some View {
            let c = center
        let rx = radii.width, ry = radii.height
        return ZStack {
            Ellipse()
                .stroke(Color.yellow.opacity(0.9), lineWidth: 1.5)
                .frame(width: rx * 2, height: ry * 2)
                .rotationEffect(.degrees(-angle))
                .position(c)
                .allowsHitTesting(false)
            Ellipse()
                .stroke(Color.yellow.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: rx * 2 * CGFloat(MaskGeometry.innerRatio(mask)),
                       height: ry * 2 * CGFloat(MaskGeometry.innerRatio(mask)))
                .rotationEffect(.degrees(-angle))
                .position(c)
                .allowsHitTesting(false)
            Handle(position: c, color: .yellow, size: 14, onMove: { start, end in
                edit(.move, from: start, to: end)
            }, onEnd: { endDrag() })
            // angle 是 Double、rx/ry 是 CGFloat，混算会让 cos/sin 同时匹配
            // CoreGraphics 的 CGFloat 版和 _math 的 Double 版，这里统一按 Double 算再转回。
            let a = angle * Double.pi / 180
            let rxD = Double(rx), ryD = Double(ry)
            let xHandle = CGPoint(x: c.x + CGFloat(rxD * cos(a)), y: c.y - CGFloat(ryD * sin(a)))
            let yHandle = CGPoint(x: c.x + CGFloat(rxD * sin(a)), y: c.y + CGFloat(ryD * cos(a)))
            Handle(position: xHandle, color: .yellow, size: 12,
                   onMove: { start, end in edit(.radialX, from: start, to: end) }, onEnd: { endDrag() })
            Handle(position: yHandle, color: .yellow, size: 12,
                   onMove: { start, end in edit(.radialY, from: start, to: end) }, onEnd: { endDrag() })
            Handle(position: CGPoint(x: c.x + CGFloat((rxD + 24) * cos(a)),
                                     y: c.y - CGFloat((ryD + 24) * sin(a))), color: .orange, size: 12,
                   onMove: { start, end in edit(.rotate, from: start, to: end) },
                   onEnd: { endDrag() })
        }
    }

    /// 当前这次拖动的会话：记住按下点和按下那一刻的蒙版。
    /// 不能拿「当前蒙版」去叠加 DragGesture 的累计位移，否则控制点越拖越远。
    @State private var drag: MaskDragSession?

    private func edit(_ control: MaskGeometry.Control, from start: CGPoint, to end: CGPoint) {
        // 按下点变了说明是新的拖动：重建会话，避免上一次拖动没收到 onEnded 时残留
        if drag == nil || drag?.start != start {
            drag = MaskDragSession(start: start, base: mask)
        }
        guard let session = drag else { return }
        let updated = session.updated(control, to: end, size: frame.size,
                                      constrained: NSEvent.modifierFlags.contains(.shift))
        s.updateMaskLive(updated)
    }

    private func endDrag() {
        drag = nil
        s.endEdit()
    }
}

struct Handle: View {
    let position: CGPoint
    var color: Color = .cyan
    var size: CGFloat = 14
    /// 回调给出「按下点」和「当前点」，都在叠加层本地坐标里。
    /// 不要在这里算 position + v.translation：translation 是从按下那一刻算起的累计值，
    /// 而叠加层每一帧都会按新蒙版重算 position，两者相加会让控制点越拖越远（参考线飘走）。
    var onMove: (CGPoint, CGPoint) -> Void
    var onEnd: () -> Void = {}
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .position(position)
            .gesture(DragGesture().onChanged { v in
                onMove(v.startLocation, v.location)
            }.onEnded { _ in onEnd() })
    }
}

// MARK: - 直方图
struct HistogramBar: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HistogramView(bins: s.hist)
                .frame(width: 260, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(s.showBefore ? Color.orange : Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text(s.showBefore ? "原图" : "调整后")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(String(format: "原图 %d × %d",
                            Int(s.sourceSize.width), Int(s.sourceSize.height)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(s.lastPreviewScale >= 0.999
                     ? "预览：全像素"
                     : String(format: "预览：%d%%（代理图）", Int(s.lastPreviewScale * 100)))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(s.lastPreviewScale >= 0.999 ? Color.green : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().fill(Color(nsColor: .rfCardBorder)).frame(height: 0.5),
                 alignment: .top)
    }
}

struct HistogramView: View {
    let bins: (r: [Int], g: [Int], b: [Int], l: [Int])
    var body: some View {
        Canvas { ctx, size in
            guard !bins.l.isEmpty else { return }
            let maxV = max(bins.r.max() ?? 1, bins.g.max() ?? 1, bins.b.max() ?? 1, 1)
            func path(_ v: [Int]) -> Path {
                var p = Path()
                let n = v.count
                for i in 0..<n {
                    let x = Double(i) / Double(max(1,n - 1)) * size.width
                    let y = size.height - Double(v[i]) / Double(maxV) * size.height
                    if i == 0 { p.move(to: CGPoint(x: x, y: size.height)) }
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.fill(path(bins.l), with: .color(WorkspaceTokens.secondaryText.opacity(0.24)))
            ctx.fill(path(bins.r), with: .color(.red.opacity(0.45)))
            ctx.fill(path(bins.g), with: .color(.green.opacity(0.45)))
            ctx.fill(path(bins.b), with: .color(.blue.opacity(0.45)))
        }
        .background(WorkspaceTokens.chartColor)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color(nsColor: .rfCardBorder), lineWidth: 0.5))
    }
}

// MARK: - 裁剪叠加层与工具条
struct CropBar: View {
    @EnvironmentObject var s: AppState
    private let presets: [(String, Double?)] = [("自由", nil), ("1:1", 1), ("4:3", 4.0/3), ("3:2", 3.0/2), ("16:9", 16.0/9)]
    var body: some View {
        VStack {
            HStack(spacing: 3) {
                Text("画幅")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 4)
                ForEach(presets, id: \.0) { name, ratio in
                    BarButton(title: name) { s.applyCropAspect(ratio) }
                }
                Rectangle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 3)
                BarButton(title: "↺", help: "逆时针旋转 90°") {
                    s.set(\.rotation, (s.params.rotation + 270) % 360); s.endEdit()
                }
                BarButton(title: "↻", help: "顺时针旋转 90°") {
                    s.set(\.rotation, (s.params.rotation + 90) % 360); s.endEdit()
                }
                BarButton(title: "⇋", help: "水平翻转") {
                    s.set(\.flipped, !s.params.flipped); s.endEdit()
                }
                BarButton(title: "自动校直", help: "Vision 检测地平线并自动裁切") {
                    s.autoStraighten()
                }
                Rectangle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 3)
                Button {
                    s.toggleCropMode()
                } label: {
                    Text("完成")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return)
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
            .padding(.top, 10)
            Spacer()
        }
    }
}

/// 裁剪浮动条里的小按钮
struct BarButton: View {
    let title: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(hover ? .white : .white.opacity(0.75))
                .background(Capsule().fill(hover ? .white.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// 裁剪框叠加：暗化外部 + 三分线 + 八向手柄 + 框内拖动
struct CropOverlay: View {
    @EnvironmentObject var s: AppState
    let frame: CGRect          // 预览图在画布上的显示矩形
    @State private var moveOrigin: [Double]?

    // 归一化裁剪参数 → 叠加层本地坐标（原点 = 显示图左上）
    private var rect: CGRect {
        CGRect(x: CGFloat(s.params.cropX) * frame.width,
               y: (1 - CGFloat(s.params.cropY) - CGFloat(s.params.cropH)) * frame.height,
               width: CGFloat(s.params.cropW) * frame.width,
               height: CGFloat(s.params.cropH) * frame.height)
    }

    var body: some View {
        let r = rect
        ZStack {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: frame.size))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle().stroke(Color.white, lineWidth: 1)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)

            Path { p in
                for i in 1..<3 {
                    let fx = r.minX + r.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: fx, y: r.minY)); p.addLine(to: CGPoint(x: fx, y: r.maxY))
                    let fy = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: r.minX, y: fy)); p.addLine(to: CGPoint(x: r.maxX, y: fy))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
            .allowsHitTesting(false)

            ForEach(handles(in: r), id: \.0) { h in
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .position(h.1)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cropSpace"))
                        .onChanged { v in drag(h.0, to: v.location) }
                        .onEnded { _ in s.endEdit() })
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(r.width - 24, 10), height: max(r.height - 24, 10))
                .position(x: r.midX, y: r.midY)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cropSpace"))
                    .onChanged { v in move(by: v.translation) }
                    .onEnded { _ in moveOrigin = nil; s.endEdit() })
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
        .coordinateSpace(name: "cropSpace")
    }

    private func handles(in r: CGRect) -> [(String, CGPoint)] {
        [("tl", CGPoint(x: r.minX, y: r.minY)), ("t", CGPoint(x: r.midX, y: r.minY)),
         ("tr", CGPoint(x: r.maxX, y: r.minY)), ("l", CGPoint(x: r.minX, y: r.midY)),
         ("r", CGPoint(x: r.maxX, y: r.midY)), ("bl", CGPoint(x: r.minX, y: r.maxY)),
         ("b", CGPoint(x: r.midX, y: r.maxY)), ("br", CGPoint(x: r.maxX, y: r.maxY))]
    }

    private func drag(_ role: String, to loc: CGPoint) {
        let nx = min(max(loc.x / max(frame.width, 1), 0), 1)
        let ny = min(max(1 - loc.y / max(frame.height, 1), 0), 1)   // 归一化 y 向上
        var x0 = s.params.cropX, y0 = s.params.cropY
        var x1 = x0 + s.params.cropW, y1 = y0 + s.params.cropH
        let m = 0.05
        switch role {
        case "tl": x0 = min(nx, x1 - m); y1 = max(ny, y0 + m)
        case "tr": x1 = max(nx, x0 + m); y1 = max(ny, y0 + m)
        case "bl": x0 = min(nx, x1 - m); y0 = min(ny, y1 - m)
        case "br": x1 = max(nx, x0 + m); y0 = min(ny, y1 - m)
        case "t":  y1 = max(ny, y0 + m)
        case "b":  y0 = min(ny, y1 - m)
        case "l":  x0 = min(nx, x1 - m)
        case "r":  x1 = max(nx, x0 + m)
        default: break
        }
        s.set(\.cropX, x0); s.set(\.cropY, y0)
        s.set(\.cropW, x1 - x0); s.set(\.cropH, y1 - y0)
    }

    private func move(by t: CGSize) {
        if moveOrigin == nil {
            moveOrigin = [s.params.cropX, s.params.cropY,
                          s.params.cropX + s.params.cropW, s.params.cropY + s.params.cropH]
        }
        guard let o = moveOrigin else { return }
        let w = o[2] - o[0], h = o[3] - o[1]
        let dx = Double(t.width / max(frame.width, 1))
        let dy = -Double(t.height / max(frame.height, 1))   // 显示 y 向下 → 归一化向上
        let x0 = min(max(o[0] + dx, 0), 1 - w)
        let y0 = min(max(o[1] + dy, 0), 1 - h)
        s.set(\.cropX, x0); s.set(\.cropY, y0)
        s.set(\.cropW, w); s.set(\.cropH, h)
    }
}

// MARK: - 状态栏
struct StatusBar: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(s.previewing ? Color.orange : Color.green)
            Text(s.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let it = s.current {
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= it.rating ? "star.fill" : "star")
                            .foregroundStyle(i <= it.rating ? .yellow : .secondary.opacity(0.5))
                            .font(.system(size: 11))
                            .onTapGesture { s.setRating(i == it.rating ? 0 : i) }
                    }
                }
                Button {
                    s.togglePick()
                } label: {
                    Label(it.picked ? "已标记" : "标记",
                          systemImage: it.picked ? "checkmark" : "flag")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .foregroundStyle(it.picked ? Color.white : Color.primary)
                        .background(Capsule().fill(it.picked ? Color.accentColor
                                                      : Color(nsColor: .rfPill)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - 多重曝光合成
struct MergeSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) var dismiss

    /// 面板内直接勾选的当前文件夹照片
    @State private var selected: Set<UUID> = []
    /// 从文件夹外另外添加的文件
    @State private var external: [URL] = []
    @State private var mergeMode:MergeMode = .fusion
    @State private var alignEnabled = true
    @State private var alignMethod:AlignMethod = .translation

    /// 最终合成顺序：文件夹照片按列表顺序，外部文件追加在后
    var list: [URL] {
        let inFolder = s.items.filter { selected.contains($0.id) }.map { $0.url }
        return inFolder + external
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                Text("多重曝光合成")
                    .font(.system(size: 15, weight: .bold))
            }

            // 合成方式
            VStack(alignment: .leading, spacing: 6) {
                Picker("方式", selection: $mergeMode) {
                    ForEach(MergeMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(s.mergeRunning)
                Text(mergeMode.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 对齐选项
            VStack(alignment: .leading, spacing: 6) {
                Toggle("先对齐帧（重叠区 NCC < 0.7 的帧自动剔除）", isOn: Binding(
                    get: { alignEnabled || mergeMode == .denoise },
                    set: { alignEnabled = $0 }))
                    .font(.system(size: 10.5))
                    .disabled(mergeMode == .denoise || s.mergeRunning)
                if alignEnabled || mergeMode == .denoise {
                    Picker("对齐方式", selection: $alignMethod) {
                        ForEach(AlignMethod.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(s.mergeRunning)
                    Text("平移：只补偿手持位移，快。透视：额外抗旋转/透视错位，帧歪得厉害时用")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            // 照片多选列表
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("点击勾选要合成的照片")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("全选") { selected = Set(s.items.map { $0.id }) }
                    Button("全不选") { selected.removeAll() }
                    Button("选已标记") {
                        selected = Set(s.items.filter { $0.picked }.map { $0.id })
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(s.mergeRunning)

                ScrollView {
                    VStack(spacing: 2) {
                        if s.items.isEmpty {
                            Text("还没有打开文件夹：点下面「添加文件…」直接选，或先 ⌘O 打开文件夹")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        ForEach(s.items) { item in
                            MergeRow(
                                title: item.url.lastPathComponent,
                                thumb: item.thumb,
                                checked: selected.contains(item.id)) {
                                    toggle(item.id)
                                }
                        }
                        // 文件夹外添加的文件
                        ForEach(Array(external.enumerated()), id: \.offset) { i, u in
                            MergeRow(title: u.lastPathComponent, thumb: nil,
                                     checked: true, removable: true) {
                                external.remove(at: i)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: 210)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .rfCardBorder), lineWidth: 0.5))

                HStack(spacing: 8) {
                    Button {
                        choose()
                    } label: {
                        Label("添加文件夹外的文件…", systemImage: "doc.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .disabled(s.mergeRunning)
                    Spacer()
                    Text("已选 \(list.count) 张" + (list.count < 2 ? "（至少选 2 张）" : ""))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(list.count >= 2 ? Color.green : .secondary)
                }
            }

            if s.mergeRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(s.mergeProgress).font(.system(size: 11))
                }
            }
            Label("输出 16 位 TIFF，文件名为「首张_合成.tif」，落在首张所在目录，合成后自动载入继续调色",
                  systemImage: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(s.mergeRunning)
                Button {
                    let urls = list
                    s.mergeMode = mergeMode; s.alignEnabled = alignEnabled; s.alignMethod = alignMethod
                    Task { await s.mergeExposures(urls) }
                } label: {
                    Label("开始合成", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(list.count < 2 || s.mergeRunning)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20).frame(width: 470).background(Color(nsColor:WorkspaceTokens.panel))
        .onAppear {
            mergeMode = s.mergeMode; alignEnabled = s.alignEnabled; alignMethod = s.alignMethod
            // 默认带上之前已标记的照片
            selected = Set(s.items.filter { $0.picked }.map { $0.id })
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.message = "选择要加入合成的照片（可按住 ⌘ 多选）"
        if p.runModal() == .OK {
            for u in p.urls where !external.contains(u) { external.append(u) }
        }
    }
}

// 合成面板里的可勾选行
struct MergeRow: View {
    let title: String
    let thumb: CGImage?
    let checked: Bool
    var removable: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if let thumb {
                        Image(decorative: thumb, scale: 1)
                            .resizable().scaledToFill()
                    } else {
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                .clipped()
                .cornerRadius(4)

                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: removable ? "xmark.circle.fill"
                    : (checked ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 14))
                    .foregroundStyle(removable ? AnyShapeStyle(Color.secondary)
                        : (checked ? AnyShapeStyle(Color.accentColor)
                           : AnyShapeStyle(HierarchicalShapeStyle.tertiary)))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(checked && !removable
                          ? Color.accentColor.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
    }
}
