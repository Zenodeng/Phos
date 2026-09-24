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
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var onEdit: () -> Void = {}

    /// 双极滑块（范围跨 0）显示中心零位标记
    private var bipolar: Bool { range.lowerBound < 0 && range.upperBound > 0 }

    /// 按量程决定小数位：大量程取整，小量程保留 1~2 位
    private var text: String {
        let span = range.upperBound - range.lowerBound
        if span >= 50 { return String(format: "%.0f", value) }
        if span > 5   { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    // 数值直接输入
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var valueHover = false

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .frame(width: 52, alignment: .leading)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack {
                Slider(value: $value, in: range) { editing in if !editing { onEdit() } }
                    .controlSize(.small)
                if bipolar {
                    Capsule()
                        .fill(Color.primary.opacity(0.3))
                        .frame(width: 2, height: 7)
                        .allowsHitTesting(false)
                }
            }
            valueField
                .frame(width: 44, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var valueField: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .focused($fieldFocused)
                .onSubmit(commitInput)
                .onExitCommand { cancelInput() }
                .onAppear { fieldFocused = true }
                .onChange(of: fieldFocused) { focused in
                    // 点到别处（失焦）等同确认
                    if !focused { commitInput() }
                }
        } else {
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(valueHover ? Color.primary : .secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(valueHover ? Color(nsColor: .rfPill) : .clear)
                )
                .contentShape(Rectangle())
                .help("单击直接输入数值（最多两位小数，范围 \(format(range.lowerBound)) ~ \(format(range.upperBound))）")
                .onHover { valueHover = $0 }
                .onTapGesture { startInput() }
        }
    }

    private func format(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        if s.contains(".") {
            s = s.trimmingCharacters(in: ["0"]).trimmingCharacters(in: ["."])
        }
        return s
    }

    private func startInput() {
        draft = format(value)
        editing = true
    }

    private func cancelInput() {
        editing = false
        draft = ""
    }

    private func commitInput() {
        guard editing else { return }
        var raw = draft.trimmingCharacters(in: .whitespaces)
        // 兼容中文输入法里的逗号小数点，如 1,5
        if raw.contains("."), !raw.contains(",") { } else if raw.contains(",") {
            raw = raw.replacingOccurrences(of: ",", with: ".")
        }
        if let v = Double(raw) {
            // 最多两位小数 + 夹到合法范围
            let rounded = (v * 100).rounded() / 100
            let clamped = min(max(rounded, range.lowerBound), range.upperBound)
            value = clamped
            onEdit()
        }
        cancelInput()
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
                .frame(minWidth: 520)
                InspectorPane().frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
            StatusBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $s.showExport) { ExportSheet() }
        .sheet(isPresented: $s.showBatch) { BatchSheet() }
        .sheet(isPresented: $s.showMerge) { MergeSheet() }
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
                       active: s.showBefore) { s.refreshBefore(); s.showBefore.toggle() }
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
                                .onTapGesture { s.select(idx) }
                        }
                    }
                }
                .padding(8)
            }
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
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panOrigin: CGSize?
    @State private var maskOrigin: [Double]?
    @State private var lastBrush: CGPoint?
    @State private var painting = false
    @State private var sampled = false

    var body: some View {
        GeometryReader { geo in
            let img = (s.showBefore ? s.beforeImage : s.preview)
            let fit = fitRect(img: img, in: geo.size)
            // 预览图在画布上的真实显示矩形：
            // ZStack 里带显式 frame 的子视图默认居中，再叠 offset ——
            // 之前叠加层用 fit.midX - geo.w/2 当原点（恒为 0），少了居中那一半，整体错位半幅
            let dispRect = CGRect(
                x: (geo.size.width - fit.width * scale) / 2 + offset.width,
                y: (geo.size.height - fit.height * scale) / 2 + offset.height,
                width: fit.width * scale, height: fit.height * scale)
            ZStack {
                Color(white: 0.08)
                if s.oneToOne, let cg = img {
                    // 1:1：按屏幕像素原样摆，外面套滚动视图，检查锐度用
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: cg, scale: 1)
                            .frame(width: CGFloat(cg.width), height: CGFloat(cg.height))
                    }
                } else {
                if let cg = img {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .frame(width: fit.width * scale, height: fit.height * scale)
                        .offset(x: fit.midX - geo.size.width / 2 + offset.width,
                                y: fit.midY - geo.size.height / 2 + offset.height)
                        .overlay(alignment: .topLeading) {
                            if !s.cropMode, let id = s.selectedMask,
                               let m = s.params.masks.first(where: { $0.id == id }) {
                                // overlay 的本地原点就是图片左上角，frame 必须从 0 起
                                MaskOverlay(mask: m, frame: CGRect(
                                    x: 0, y: 0, width: dispRect.width, height: dispRect.height))
                            }
                        }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                        Text("打开一个文件夹开始")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("支持 RAW · HEIF/HEIC · JPEG · PNG · TIFF · AVIF")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                }
            }
            .contentShape(Rectangle())
            .gesture(canvasGesture(frame: fit))
            .simultaneousGesture(MagnificationGesture().onChanged { v in
                scale = min(max(scale * (1 + (v - 1) * 0.5), 0.2), 8)
            })
            .onChange(of: s.currentIndex) { scale = 1; offset = .zero }
            // 裁剪模式：叠加裁剪框（作为画布兄弟视图，需要真实显示矩形）
            if s.cropMode, img != nil, !s.oneToOne {
                CropOverlay(frame: dispRect)
                CropBar()
            }
        }
    }

    func fitRect(img: CGImage?, in size: CGSize) -> CGRect {
        guard let cg = img else { return .zero }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let sc = min(size.width / iw, size.height / ih)
        let w = iw * sc, h = ih * sc
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// 只挂一个拖拽手势，内部按当前状态分流 —— 以前挂了三个 gesture，
    /// 平移手势在最外层会把事件吞掉，画笔永远收不到点，这是画笔失效的根因。
    func canvasGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard !s.oneToOne, !s.cropMode else { return }   // 裁剪模式交给 CropOverlay
                if let id = s.selectedMask,
                   let m = s.params.masks.first(where: { $0.id == id }) {
                    switch m.kind {
                    case .brush, .depth:
                        paint(v.location, frame: frame, mask: m)
                    case .linear, .radial:
                        moveMask(v.translation, frame: frame, mask: m)
                    case .colorRange, .luminanceRange:
                        // 取样类蒙版：在画布上拖到哪儿就取哪儿的颜色/亮度
                        sample(v.location, frame: frame, mask: m)
                    case .subject, .person, .foreground:
                        break        // AI 蒙版不需要手绘
                    }
                } else {
                    if panOrigin == nil { panOrigin = offset }
                    offset = CGSize(width: (panOrigin?.width ?? 0) + v.translation.width,
                                    height: (panOrigin?.height ?? 0) + v.translation.height)
                }
            }
            .onEnded { _ in
                if painting { painting = false; s.endEdit() }
                else if maskOrigin != nil || sampled { s.endEdit() }
                panOrigin = nil; maskOrigin = nil; lastBrush = nil; sampled = false
            }
    }

    /// 画笔：屏幕点 → 归一化坐标（y 向上，跟引擎里的笔刷位图一致）
    func paint(_ loc: CGPoint, frame: CGRect, mask m: Mask) {
        let p = CGPoint(x: min(max((loc.x - frame.minX) / max(frame.width, 1), 0), 1),
                        y: min(max(1 - (loc.y - frame.minY) / max(frame.height, 1), 0), 1))
        var mm = m
        if !painting {
            painting = true
            let rad = mm.strokes.last?.radius ?? 0.05
            mm.strokes.append(Stroke(pts: [[Double(p.x), Double(p.y)]], radius: rad, feather: mm.feather))
            lastBrush = p
            s.updateMaskLive(mm)
            return
        }
        guard !mm.strokes.isEmpty else { return }
        let from = lastBrush ?? p
        // 中间补点：手快拖过时不会画成一串断开的圆点
        let step = max(0.003, (mm.strokes.last?.radius ?? 0.05) / 4)
        let dx = Double(p.x - from.x), dy = Double(p.y - from.y)
        let dist = (dx * dx + dy * dy).squareRoot()
        let n = max(1, Int(dist / step))
        for i in 1...n {
            let t = Double(i) / Double(n)
            mm.strokes[mm.strokes.count - 1].pts.append([Double(from.x) + dx * t, Double(from.y) + dy * t])
        }
        lastBrush = p
        s.updateMaskLive(mm)
    }

    /// 颜色范围 / 亮度范围蒙版：在画布上拖到哪儿就取哪儿
    func sample(_ loc: CGPoint, frame: CGRect, mask m: Mask) {
        guard let cg = s.preview else { return }
        let nx = min(max((loc.x - frame.minX) / max(frame.width, 1), 0), 1)
        let ny = min(max(1 - (loc.y - frame.minY) / max(frame.height, 1), 0), 1)
        let px = Int(nx * CGFloat(cg.width)), py = Int(ny * CGFloat(cg.height))
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

    /// 线性 / 径向蒙版：在画布上直接拖，整体位移
    func moveMask(_ t: CGSize, frame: CGRect, mask m: Mask) {
        if maskOrigin == nil { maskOrigin = [m.x0, m.y0, m.x1, m.y1] }
        guard let o = maskOrigin, frame.width > 1, frame.height > 1 else { return }
        var mm = m
        let dx = Double(t.width / frame.width)
        let dy = -Double(t.height / frame.height)
        func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
        mm.x0 = clamp01(o[0] + dx); mm.y0 = clamp01(o[1] + dy)
        mm.x1 = clamp01(o[2] + dx); mm.y1 = clamp01(o[3] + dy)
        s.updateMaskLive(mm)
    }
}

// MARK: - 蒙版操作层
struct MaskOverlay: View {
    @EnvironmentObject var s: AppState
    let mask: Mask
    let frame: CGRect
    var body: some View {
        ZStack {
            if mask.kind == .linear {
                Handle(pos: CGPoint(x: mask.x0, y: 1 - mask.y0), frame: frame) { p in
                    var m = mask; m.x0 = p.x; m.y0 = 1 - p.y; s.updateMaskLive(m)
                } onEnd: { s.endEdit() }
                Handle(pos: CGPoint(x: mask.x1, y: 1 - mask.y1), frame: frame) { p in
                    var m = mask; m.x1 = p.x; m.y1 = 1 - p.y; s.updateMaskLive(m)
                } onEnd: { s.endEdit() }
            } else if mask.kind == .radial {
                Handle(pos: CGPoint(x: mask.x0, y: 1 - mask.y0), frame: frame, color: .yellow) { p in
                    var m = mask; m.x0 = p.x; m.y0 = 1 - p.y; s.updateMaskLive(m)
                } onEnd: { s.endEdit() }
                Circle()
                    .stroke(Color.yellow.opacity(0.8), lineWidth: 1.5)
                    .frame(width: frame.width * mask.radius * 2, height: frame.width * mask.radius * 2)
                    .position(x: frame.minX + frame.width * mask.x0, y: frame.minY + frame.height * (1 - mask.y0))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }
}

struct Handle: View {
    let pos: CGPoint
    let frame: CGRect
    var color: Color = .cyan
    let onMove: (CGPoint) -> Void
    var onEnd: () -> Void = {}
    var body: some View {
        Circle().fill(color).frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .position(x: frame.width * pos.x, y: frame.height * pos.y)
            .gesture(DragGesture().onChanged { v in
                let p = CGPoint(x: (v.location.x + frame.width * pos.x) / max(frame.width, 1),
                                y: (v.location.y + frame.height * pos.y) / max(frame.height, 1))
                onMove(CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)))
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
                    let x = Double(i) / Double(n - 1) * size.width
                    let y = size.height - Double(v[i]) / Double(maxV) * size.height
                    if i == 0 { p.move(to: CGPoint(x: x, y: size.height)) }
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.fill(path(bins.l), with: .color(.white.opacity(0.22)))
            ctx.fill(path(bins.r), with: .color(.red.opacity(0.45)))
            ctx.fill(path(bins.g), with: .color(.green.opacity(0.45)))
            ctx.fill(path(bins.b), with: .color(.blue.opacity(0.45)))
        }
        .background(Color(white: 0.10))
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
                Picker("方式", selection: $s.mergeMode) {
                    ForEach(MergeMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(s.mergeRunning)
                Text(s.mergeMode.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 对齐选项
            VStack(alignment: .leading, spacing: 6) {
                Toggle("先对齐帧（重叠区 NCC < 0.7 的帧自动剔除）", isOn: Binding(
                    get: { s.alignEnabled || s.mergeMode == .denoise },
                    set: { s.alignEnabled = $0 }))
                    .font(.system(size: 10.5))
                    .disabled(s.mergeMode == .denoise || s.mergeRunning)
                if s.alignEnabled || s.mergeMode == .denoise {
                    Picker("对齐方式", selection: $s.alignMethod) {
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
        .padding(20).frame(width: 470)
        .onAppear {
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
