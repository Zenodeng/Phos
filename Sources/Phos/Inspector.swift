import SwiftUI
import CoreImage

@MainActor
func bind(_ kp: WritableKeyPath<EditParams, Double>, _ s: AppState) -> Binding<Double> {
    Binding(get: { s.params[keyPath: kp] }, set: { s.set(kp, $0) })
}

enum InspectorCategory: String, CaseIterable {
    case light = "明暗", color = "色彩", detail = "细节", geometry = "变换", masks = "蒙版"
    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .color: return "slider.horizontal.3"
        case .detail: return "circle.lefthalf.filled"
        case .geometry: return "crop"
        case .masks: return "circle.dashed"
        }
    }
    static func category(for title: String) -> Self {
        switch title {
        case "白平衡", "基本", "质感与饱和度": return .light
        case "曲线", "颜色分级", "HSL · 混色", "黑白", "校准", "胶片 CLUT": return .color
        case "细节", "效果", "焦外散景", "镜头校正": return .detail
        case "变换与裁剪": return .geometry
        default: return .masks
        }
    }
}
private struct InspectorCategoryKey: EnvironmentKey {
    static let defaultValue: InspectorCategory? = nil
}
extension EnvironmentValues {
    var inspectorCategory: InspectorCategory? {
        get { self[InspectorCategoryKey.self] }
        set { self[InspectorCategoryKey.self] = newValue }
    }
}

// MARK: - 分组容器
struct GroupBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = true
    @Environment(\.inspectorCategory) private var category
    var body: some View {
        if category == nil || category == InspectorCategory.category(for: title) {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).frame(height: 38)
            if open {
                VStack(spacing: 5) { content }
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 16) }
        }
    }
}

// MARK: - 检视器
struct InspectorPane: View {
    @EnvironmentObject var s: AppState
    @State private var category: InspectorCategory = .light
    @State private var confirmReset = false

    init(initialCategory: InspectorCategory = .light) {
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("调整").font(.system(size: 13, weight: .semibold))
                Spacer()
                ToolButton(systemImage: "arrow.counterclockwise", title: "恢复所有默认参数", disabled: s.source == nil) { confirmReset = true }
            }.padding(.horizontal, 16).frame(height: 42)
            HStack(spacing: 0) {
                ForEach(InspectorCategory.allCases, id: \.self) { tab in
                    Button { category = tab } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.symbol).font(.system(size: 13))
                            Text(tab.rawValue).font(.system(size: 10, weight: .medium))
                        }.frame(maxWidth: .infinity).frame(height: 48)
                        .foregroundStyle(category == tab ? StudioStyle.accent : Color.secondary)
                        .background(category == tab ? StudioStyle.accent.opacity(0.08) : .clear)
                        .overlay(alignment: .bottom) { if category == tab { Rectangle().fill(StudioStyle.accent).frame(height: 2) } }
                    }.buttonStyle(.plain).help(tab.rawValue)
                }
            }
            Divider()
        ScrollView {
            VStack(spacing: 0) {
                GroupBox(title: "白平衡") {
                    HStack {
                        Text("白平衡").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        ToolButton(systemImage: "eyedropper", title: "白平衡灰点取样",
                                   active: s.whiteBalancePicker,
                                   disabled: s.source == nil || s.previewing || s.whiteBalanceRunning || s.cropMode) {
                            s.showBefore = false
                            s.whiteBalancePicker.toggle()
                        }
                        ToolButton(systemImage: "arrow.counterclockwise", title: "重置白平衡") {
                            var p = s.params
                            p.whiteBalanceGains = [1, 1, 1]; p.temperature = 0; p.tint = 0
                            s.commit(p)
                        }
                    }
                    SliderRow(label: "色温", value: bind(\.temperature, s)) { s.endEdit() }
                    SliderRow(label: "色调", value: bind(\.tint, s)) { s.endEdit() }
                }
                GroupBox(title: "基本") {
                    SliderRow(label: "曝光", value: bind(\.exposure, s), range: -5...5) { s.endEdit() }
                    SliderRow(label: "对比", value: bind(\.contrast, s)) { s.endEdit() }
                    SliderRow(label: "高光", value: bind(\.highlights, s)) { s.endEdit() }
                    SliderRow(label: "阴影", value: bind(\.shadows, s)) { s.endEdit() }
                    SliderRow(label: "白色", value: bind(\.whites, s)) { s.endEdit() }
                    SliderRow(label: "黑色", value: bind(\.blacks, s)) { s.endEdit() }
                }
                GroupBox(title: "质感与饱和度") {
                    SliderRow(label: "纹理", value: bind(\.texture, s), range: -100...100) { s.endEdit() }
                    SliderRow(label: "清晰度", value: bind(\.clarity, s), range: 0...100) { s.endEdit() }
                    SliderRow(label: "去朦胧", value: bind(\.dehaze, s), range: -100...100) { s.endEdit() }
                    SliderRow(label: "鲜艳度", value: bind(\.vibrance, s), range: -100...100) { s.endEdit() }
                    SliderRow(label: "饱和", value: bind(\.saturation, s)) { s.endEdit() }
                    Divider().padding(.vertical, 2)
                    Toggle("HDR（压高光、拉暗部）",
                           isOn: Binding(get: { s.params.hdrMode },
                                         set: { s.set(\.hdrMode, $0); s.endEdit() }))
                        .font(.system(size: 11))
                    if s.params.hdrMode {
                        SliderRow(label: "HDR 极限", value: bind(\.hdrLimit, s), range: 0...100) { s.endEdit() }
                    }
                }

                GroupBox(title: "曲线") {
                    CurvePane()
                }

                GroupBox(title: "颜色分级") {
                    ColorGradePane()
                }

                GroupBox(title: "HSL · 混色") {
                    HSLPane()
                }

                GroupBox(title: "黑白") {
                    Toggle("转为黑白", isOn: Binding(get: { s.params.mono }, set: { s.set(\.mono, $0); s.endEdit() }))
                        .font(.system(size: 11))
                    if s.params.mono {
                        SliderRow(label: "红", value: bind(\.monoRed, s), range: 0...1) { s.endEdit() }
                        SliderRow(label: "绿", value: bind(\.monoGreen, s), range: 0...1) { s.endEdit() }
                        SliderRow(label: "蓝", value: bind(\.monoBlue, s), range: 0...1) { s.endEdit() }
                    }
                }

                GroupBox(title: "细节") {
                    SliderRow(label: "锐化", value: bind(\.sharpen, s), range: 0...2) { s.endEdit() }
                    SliderRow(label: "半径", value: bind(\.sharpenRadius, s), range: 0.3...3) { s.endEdit() }
                    SliderRow(label: "细节", value: bind(\.sharpenDetail, s), range: 0...1) { s.endEdit() }
                    SliderRow(label: "蒙版", value: bind(\.sharpenMask, s), range: 0...100) { s.endEdit() }
                    SliderRow(label: "降噪", value: bind(\.denoise, s), range: 0...100) { s.endEdit() }
                    SliderRow(label: "颜色降噪", value: bind(\.denoiseColor, s), range: 0...100) { s.endEdit() }
                    SliderRow(label: "颗粒", value: bind(\.grain, s), range: 0...100) { s.endEdit() }
                    SliderRow(label: "颗粒粗", value: bind(\.grainSize, s), range: 0...1) { s.endEdit() }
                }

                GroupBox(title: "效果") {
                    SliderRow(label: "暗角", value: bind(\.vignette, s), range: -100...100) { s.endEdit() }
                    SliderRow(label: "范围", value: bind(\.vignetteStart, s), range: 0...1) { s.endEdit() }
                    Divider().padding(.vertical, 2)
                    SliderRow(label: "光晕", value: bind(\.halation, s), range: 0...100) { s.endEdit() }
                    if s.params.halation > 0 {
                        SliderRow(label: "阈值", value: bind(\.halationThreshold, s), range: 0...100) { s.endEdit() }
                        SliderRow(label: "半径", value: bind(\.halationRadius, s), range: 0...1) { s.endEdit() }
                    }
                }

                GroupBox(title: "焦外散景") {
                    SliderRow(label: "强度", value: bind(\.bokehAmount, s),
                              range: 0...100) { s.endEdit() }
                    let hasPaintedDepth = s.params.masks.contains {
                        $0.kind == .depth && $0.enabled
                    }
                    Label(hasPaintedDepth
                          ? "深度来源：深度涂绘蒙版（白=虚化）"
                          : (s.hasDisparity
                             ? "深度来源：人像 disparity 辅助数据"
                             : "无深度数据：在下方局部调整里新建「深度涂绘」，把背景涂白"),
                          systemImage: hasPaintedDepth || s.hasDisparity
                              ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(hasPaintedDepth || s.hasDisparity
                                         ? Color.green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(title: "镜头校正") {
                    SliderRow(label: "色差", value: bind(\.caAmount, s), range: -100...100) { s.endEdit() }
                    Text("横向色差：R/B 通道反向微缩放（正=收红边）")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SliderRow(label: "紫边", value: bind(\.purpleFringe, s), range: 0...100) { s.endEdit() }
                    Text("抑制高亮度区域的蓝紫镶边（向灰度收敛）")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(title: "校准") {
                    CalibrationPane()
                }

                GroupBox(title: "胶片 CLUT") {
                    ClutPicker()
                    SliderRow(label: "浓度", value: bind(\.clutStrength, s), range: 0...1) { s.endEdit() }
                }

                GroupBox(title: "变换与裁剪") {
                    HStack(spacing: 6) {
                        Button("裁剪") { s.toggleCropMode() }.controlSize(.small)
                            .help("进入画布裁剪模式（R）：拖角/边裁剪、切画幅、自动校直")
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        Button("↺") { s.set(\.rotation, (s.params.rotation + 270) % 360 == 0 ? 0 : ((s.params.rotation + 270) % 360)); s.endEdit() }
                        Button("↻") { s.set(\.rotation, (s.params.rotation + 90) % 360); s.endEdit() }
                        Button("⇋") { s.set(\.flipped, !s.params.flipped); s.endEdit() }
                        Button("复位") {
                            s.set(\.cropX, 0); s.set(\.cropY, 0)
                            s.set(\.cropW, 1); s.set(\.cropH, 1)
                            s.set(\.straighten, 0); s.set(\.rotation, 0); s.set(\.flipped, false)
                            s.set(\.perspectiveAuto, false)
                            s.set(\.perspectiveV, 0); s.set(\.perspectiveH, 0)
                            s.endEdit()
                        }
                    }
                    .controlSize(.small)
                    SliderRow(label: "矫正", value: bind(\.straighten, s), range: -15...15) { s.endEdit() }
                    Divider().padding(.vertical, 2)
                    Toggle("自动透视（Vision 检测画面内四边形）",
                           isOn: Binding(get: { s.params.perspectiveAuto },
                                         set: { s.set(\.perspectiveAuto, $0); s.endEdit() }))
                        .font(.system(size: 11))
                    if !s.params.perspectiveAuto {
                        SliderRow(label: "垂直透视", value: bind(\.perspectiveV, s), range: -100...100) { s.endEdit() }
                        SliderRow(label: "水平透视", value: bind(\.perspectiveH, s), range: -100...100) { s.endEdit() }
                    } else {
                        Text("已按画面内检测到的四边形自动校正；手动滑块仅在关闭自动时生效")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    SliderRow(label: "裁左", value: bind(\.cropX, s), range: 0...1) { s.endEdit() }
                    SliderRow(label: "裁上", value: bind(\.cropY, s), range: 0...1) { s.endEdit() }
                    SliderRow(label: "宽", value: bind(\.cropW, s), range: 0.1...1) { s.endEdit() }
                    SliderRow(label: "高", value: bind(\.cropH, s), range: 0.1...1) { s.endEdit() }
                }

                GroupBox(title: "局部调整（蒙版）") {
                    MaskPane()
                }
            }
            .environment(\.inspectorCategory, category)
            .disabled(s.source == nil)
            .padding(.bottom, 16)
        }
        .id(category)
        }
        .background(StudioStyle.panel)
        .onChange(of: s.cropMode) { _, active in if active { category = .geometry } }
        .onChange(of: s.selectedMask) { _, id in if id != nil { category = .masks } }
        .alert("恢复所有默认参数？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) { s.selectedMask = nil; s.commit(EditParams()) }
        } message: { Text("此操作可撤销，原始照片不会改变。") }
    }
}

// MARK: - 曲线（色调 / 亮度 / 单通道）
struct CurvePane: View {
    @EnvironmentObject var s: AppState
    @State private var mode = 0     // 0 色调 1 亮度 2 R 3 G 4 B

    private let names = ["色调", "亮度", "R", "G", "B"]
    private var colors: [Color] {
        [.accentColor, Color(white: 0.92), Color(red: 0.95, green: 0.32, blue: 0.32),
         Color(red: 0.35, green: 0.85, blue: 0.4), Color(red: 0.4, green: 0.55, blue: 1.0)]
    }
    private var hints: [String] {
        ["RGB 合成曲线，三通道共用一条",
         "只动明暗，色调与饱和度基本不动（调曝光感最顺）",
         "红通道，往下压加青、往上提加红",
         "绿通道，往下压加洋红、往上提加绿",
         "蓝通道，往下压加黄、往上提加蓝"]
    }

    private func keyPath(_ i: Int) -> WritableKeyPath<EditParams, ToneCurve> {
        switch i {
        case 1: return \.lumaCurve
        case 2: return \.curveR
        case 3: return \.curveG
        case 4: return \.curveB
        default: return \.curve
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: $mode) {
                ForEach(0..<5, id: \.self) { i in Text(names[i]).tag(i) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small)

            CurveEditor(points: Binding(
                get: { s.params[keyPath: keyPath(mode)].points },
                set: { s.set(keyPath(mode), ToneCurve(points: $0)) }),
                color: colors[mode]) { s.endEdit() }
                .frame(height: 300)

            SliderRow(label: "Refine", value: bind(\.refineSat, s), range: 0...100) { s.endEdit() }
            Text("Refine Sat：曲线改完调子后把饱和度拉回来（只改明暗不改颜色浓淡）")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)

            HStack(spacing: 6) {
                Button("复位") { s.set(keyPath(mode), ToneCurve()); s.endEdit() }
                    .controlSize(.small)
                Text("单击空白加点 · 拖动任意移动 · 双击点删除")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(hints[mode])
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 曲线编辑器（正方形、控制点自由拖，像 Lightroom）
struct CurveEditor: View {
    @Binding var points: [[Double]]
    var color: Color = .accentColor
    var onEnd: () -> Void
    @State private var dragIndex: Int?

    /// 绘图区内边距：让四角的控制点圆圈不被切掉
    private let inset: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            // 整个编辑器就是一个固定边长的正方形坐标系：
            // 底板、网格、对角参考线、曲线、控制点全部用它，不允许各算各的
            // （之前底板只加了 frame 被对齐到左边，曲线却按居中偏移算，整条线右偏了 30pt）
            let side = max(min(geo.size.width, geo.size.height), 40)
            let plot = max(side - inset * 2, 10)
            let curve = ToneCurve(points: points)
            ZStack(alignment: .topLeading) {
                // 底板
                Rectangle()
                    .fill(Color.black.opacity(0.9))
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { v in
                        let p = norm(v.location, plot: plot)
                        // 双击已有点 = 删掉它
                        if let i = nearestPoint(to: p, plot: plot),
                           i != 0, i != points.count - 1 {
                            var pts = points; pts.remove(at: i); points = pts; onEnd()
                        }
                    })
                    .gesture(SpatialTapGesture(count: 1).onEnded { v in
                        let p = norm(v.location, plot: plot)
                        guard p[0] >= 0, p[0] <= 1, p[1] >= 0, p[1] <= 1 else { return }
                        guard nearestPoint(to: p, plot: plot) == nil else { return }
                        var pts = points
                        pts.append(p)
                        points = ToneCurve.sanitize(pts)
                        onEnd()
                    })

                // 网格 + 对角参考线
                Path { p in
                    for i in 1..<4 {
                        let v = inset + CGFloat(i) / 4 * plot
                        p.move(to: CGPoint(x: v, y: inset)); p.addLine(to: CGPoint(x: v, y: inset + plot))
                        p.move(to: CGPoint(x: inset, y: v)); p.addLine(to: CGPoint(x: inset + plot, y: v))
                    }
                    p.move(to: CGPoint(x: inset, y: inset + plot))
                    p.addLine(to: CGPoint(x: inset + plot, y: inset))
                }
                .stroke(Color.white.opacity(0.16), lineWidth: 1)

                // 曲线本体
                Path { path in
                    let steps = 180
                    for i in 0...steps {
                        let x = Double(i) / Double(steps)
                        let y = curve.value(at: x)
                        let pt = CGPoint(x: inset + CGFloat(x) * plot,
                                         y: inset + CGFloat(1 - y) * plot)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                }
                .stroke(color, lineWidth: 1.8)

                // 控制点
                ForEach(points.indices, id: \.self) { i in
                    Circle()
                        .fill(dragIndex == i ? color : .white)
                        .overlay(Circle().stroke(color, lineWidth: 1.2))
                        .frame(width: dragIndex == i ? 14 : 11, height: dragIndex == i ? 14 : 11)
                        .position(x: inset + CGFloat(points[i][0]) * plot,
                                  y: inset + CGFloat(1 - points[i][1]) * plot)
                        .contextMenu {
                            Button("删除该控制点") {
                                guard i != 0, i != points.count - 1 else { return }
                                var pts = points; pts.remove(at: i); points = pts; onEnd()
                            }
                            .disabled(i == 0 || i == points.count - 1)
                        }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                dragIndex = i
                                var pts = points
                                var x = Double((v.location.x - inset) / plot)
                                var y = Double(1 - (v.location.y - inset) / plot)
                                x = min(max(x, 0), 1); y = min(max(y, 0), 1)
                                // 首尾点只锁 x，中间点不许越过左右邻居，保证曲线是函数
                                if i == 0 { x = 0 }
                                else if i == points.count - 1 { x = 1 }
                                else {
                                    let lo = pts[i - 1][0] + 0.004
                                    let hi = pts[i + 1][0] - 0.004
                                    x = min(max(x, lo), hi)
                                }
                                pts[i] = [x, y]
                                points = pts
                            }
                            .onEnded { _ in dragIndex = nil; onEnd() })
                }
            }
            .frame(width: side, height: side, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 屏幕坐标 → 归一化曲线坐标（y 向上）
    private func norm(_ loc: CGPoint, plot: CGFloat) -> [Double] {
        [Double((loc.x - inset) / max(plot, 1)), Double(1 - (loc.y - inset) / max(plot, 1))]
    }

    /// 命中检测：离控制点小于 14pt 视为点到它了
    private func nearestPoint(to p: [Double], plot: CGFloat) -> Int? {
        let tol = 14.0 / Double(max(plot, 1))
        var best: Int?
        var bestD = tol
        for (i, q) in points.enumerated() {
            let d = ((q[0] - p[0]) * (q[0] - p[0]) + (q[1] - p[1]) * (q[1] - p[1])).squareRoot()
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}

// MARK: - 颜色分级（LR 式色轮：一次一个大球，三个圆点切换）
struct ColorGradePane: View {
    @EnvironmentObject var s: AppState
    @State private var band = 1     // 0 阴影 1 中间调 2 高光

    private let names = ["阴影", "中间调", "高光"]
    private func keyPath(_ i: Int) -> WritableKeyPath<EditParams, ColorGrade> {
        switch i { case 0: return \.gradeShadow; case 2: return \.gradeHigh; default: return \.gradeMid }
    }

    var body: some View {
        VStack(spacing: 8) {
            // 三个圆点按钮（同 LR 的「调整」排），选中档描白边
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(dotColor(i))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(band == i ? Color.white : .white.opacity(0.25),
                                                 lineWidth: band == i ? 2 : 1))
                        .onTapGesture { band = i }
                        .help(names[i])
                }
                Spacer()
                Button("复位") { s.set(keyPath(band), ColorGrade()); s.endEdit() }
                    .controlSize(.small)
            }

            Text(names[band])
                .font(.system(size: 11, weight: .medium))

            // 大色轮：拖到哪就是哪个色相/饱和度，双击复位
            GradeWheel(grade: Binding(
                get: { s.params[keyPath: keyPath(band)] },
                set: { s.set(keyPath(band), $0) })) { s.endEdit() }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 230)

            SliderRow(label: "明亮", value: Binding(
                get: { s.params[keyPath: keyPath(band)].lum },
                set: { var g = s.params[keyPath: keyPath(band)]; g.lum = $0; s.set(keyPath(band), g) }),
                range: -100...100) { s.endEdit() }

            Divider().padding(.vertical, 2)
            SliderRow(label: "混合", value: bind(\.gradeBlend, s), range: 0...100) { s.endEdit() }
            SliderRow(label: "平衡", value: bind(\.gradeBalance, s), range: -100...100) { s.endEdit() }
            Text("混合 50 = 标准量，0 不上色；平衡决定三档分界往哪边挪")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dotColor(_ i: Int) -> Color {
        let g = s.params[keyPath: keyPath(i)]
        guard g.sat > 0 else { return Color(white: 0.45) }
        return Color(hue: (g.hue.truncatingRemainder(dividingBy: 360)) / 360,
                     saturation: max(g.sat / 100, 0.15), brightness: 0.95)
    }
}

/// LR 式色轮：色相沿圆周、饱和度沿半径（外圈最浓，圆心无色）
struct GradeWheel: View {
    @Binding var grade: ColorGrade
    var onEnd: () -> Void
    @State private var dragging = false

    // 每 3° 一个色标：色标稀疏时 RGB 线性插值会把中间色相拉偏最多 10°，够密才对得准
    private let hueColors: [Color] = (0..<121).map {
        Color(hue: Double($0) / 120, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side / 2
            let center = CGPoint(x: r, y: r)
            let dot = dotPosition(radius: r)
            ZStack {
                // AngularGradient 的 0° 默认在 3 点钟方向且顺时针递增，
                // 而拖拽/圆点用「0° 朝上、顺时针」（同 LR / HSL 惯例），故起点要 -90° 才对齐
                Circle()
                    .fill(AngularGradient(colors: hueColors, center: .center,
                                          startAngle: .degrees(-90), endAngle: .degrees(270)))
                    .overlay(Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)],
                                                          center: .center, startRadius: 0, endRadius: r)))
                    .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                // 当前选色点
                Circle()
                    .fill(.white)
                    .frame(width: dragging ? 15 : 12, height: dragging ? 15 : 12)
                    .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1.2))
                    .position(dot)
                    .allowsHitTesting(false)
                // 中心小十字
                Circle().stroke(.white.opacity(0.5), lineWidth: 1)
                    .frame(width: 8, height: 8)
                    .position(center)
                    .allowsHitTesting(false)
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    let dx = Double(v.location.x - center.x)
                    let dy = Double(v.location.y - center.y)
                    let dist = (dx * dx + dy * dy).squareRoot()
                    let sat = min(dist / Double(r), 1) * 100
                    // 0° 朝上、顺时针为正（跟 LR 和 HSL 惯例一致）
                    var hue = atan2(dx, -dy) * 180 / .pi
                    if hue < 0 { hue += 360 }
                    grade = ColorGrade(hue: hue, sat: sat)
                }
                .onEnded { _ in dragging = false; onEnd() })
            .onTapGesture(count: 2) { grade = ColorGrade(); onEnd() }
        }
    }

    private func dotPosition(radius: CGFloat) -> CGPoint {
        let rad = CGFloat(grade.sat / 100) * radius * 0.98
        let a = CGFloat(grade.hue) * .pi / 180
        return CGPoint(x: radius + rad * sin(a), y: radius - rad * cos(a))
    }
}

// MARK: - 校准（改 RGB 三原色的原色）
struct CalibrationPane: View {
    @EnvironmentObject var s: AppState
    @State private var band = 0      // 0 红 1 绿 2 蓝

    private let names = ["红原色", "绿原色", "蓝原色"]
    private func keyPath(_ i: Int) -> WritableKeyPath<EditParams, PrimaryAdj> {
        switch i { case 1: return \.primGreen; case 2: return \.primBlue; default: return \.primRed }
    }

    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: $band) {
                ForEach(0..<3, id: \.self) { i in Text(names[i]).tag(i) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small)
            SliderRow(label: "色相", value: Binding(
                get: { s.params[keyPath: keyPath(band)].hue },
                set: { var v = s.params[keyPath: keyPath(band)]; v.hue = $0; s.set(keyPath(band), v) }),
                range: -60...60) { s.endEdit() }
            SliderRow(label: "饱和", value: Binding(
                get: { s.params[keyPath: keyPath(band)].sat },
                set: { var v = s.params[keyPath: keyPath(band)]; v.sat = $0; s.set(keyPath(band), v) }),
                range: -100...100) { s.endEdit() }
            Divider().padding(.vertical, 2)
            SliderRow(label: "阴影色", value: bind(\.calibShadowTint, s), range: -100...100) { s.endEdit() }
            HStack(spacing: 6) {
                Text("正值偏绿 · 负值偏洋红").font(.system(size: 9.5)).foregroundStyle(.secondary)
                Spacer()
                Button("全部复位") {
                    s.set(\.primRed, PrimaryAdj()); s.set(\.primGreen, PrimaryAdj())
                    s.set(\.primBlue, PrimaryAdj()); s.set(\.calibShadowTint, 0); s.endEdit()
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - HSL
struct HSLPane: View {
    @EnvironmentObject var s: AppState
    @State private var band = 0
    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: $band) {
                ForEach(0..<8, id: \.self) { i in Text(HSLMix.names[i]).tag(i) }
            }
            .labelsHidden().controlSize(.small)
            SliderRow(label: "色相", value: Binding(
                get: { s.params.hsl[band].hue },
                set: { var h = s.params.hsl; h[band].hue = $0; s.set(\.hsl, h) }), range: -60...60) { s.endEdit() }
            SliderRow(label: "饱和", value: Binding(
                get: { s.params.hsl[band].sat },
                set: { var h = s.params.hsl; h[band].sat = $0; s.set(\.hsl, h) }), range: -100...100) { s.endEdit() }
            SliderRow(label: "明亮", value: Binding(
                get: { s.params.hsl[band].lum },
                set: { var h = s.params.hsl; h[band].lum = $0; s.set(\.hsl, h) }), range: -100...100) { s.endEdit() }
            Button("清空 HSL") { s.set(\.hsl, HSLMix()); s.endEdit() }.controlSize(.small)
        }
    }
}

// MARK: - CLUT 选择
struct ClutPicker: View {
    @EnvironmentObject var s: AppState
    @State private var q = ""
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                TextField("搜索胶片…", text: $q).textFieldStyle(.roundedBorder).controlSize(.small)
                Button("清除") { s.set(\.clutName, ""); s.endEdit() }.controlSize(.small)
                Button("刷新") { s.cluts.invalidate(); s.endEdit() }.controlSize(.small)
                    .help("重新扫描 HaldCLUT 目录：往 ~/Documents/RawTherapee/HaldCLUT 里放了新 LUT 后点这里")
            }
            let all = s.cluts.list()
            // 不再截断到前 60 个：LUT 超过 300 个时，新放进去的会排在后头，不搜索就永远看不到
            let shown = q.isEmpty ? all
                : all.filter { $0.localizedCaseInsensitiveContains(q) }
            Menu {
                ForEach(shown, id: \.self) { name in
                    Button(name) { s.set(\.clutName, name); s.endEdit() }
                }
            } label: {
                HStack {
                    Text(s.params.clutName.isEmpty ? "选择胶片…" : s.params.clutName)
                        .font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            Text("共 \(all.count) 个可用 · 新放的 LUT 点「刷新」").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 蒙版面板
extension MaskKind {
    var icon: String {
        switch self {
        case .linear: return "arrow.up.right"
        case .radial: return "scope"
        case .brush: return "paintbrush"
        case .colorRange: return "eyedropper"
        case .luminanceRange: return "sun.max"
        case .subject: return "lasso"
        case .person: return "person.crop.square"
        case .foreground: return "scissors"
        case .depth: return "square.3.layers.3d"
        }
    }
}

struct MaskAddButton: View {
    @EnvironmentObject var s: AppState
    let kind: MaskKind
    var body: some View {
        Button { s.addMask(kind) } label: {
            HStack(spacing: 5) {
                Image(systemName: kind.icon)
                    .frame(width: 14)
                Text(kind.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.system(size: 10.5, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(kind.label)
    }
}

struct MaskPane: View {
    @EnvironmentObject var s: AppState

    private var maskHint: String {
        guard let id = s.selectedMask,
              let m = s.params.masks.first(where: { $0.id == id }) else {
            return "点上方按钮新建一个蒙版，然后在这里给它单独设参数"
        }
        switch m.kind {
        case .brush: return "已在画笔模式：直接在画布上按住拖动涂抹（一次拖动算一笔）；调「笔刷」改大小、「羽化」改边缘软硬"
        case .linear: return "点「拖画线性」后在画布上拖出三线渐变；拖中心移动，拖端点改宽度，拖旋转柄改变方向"
        case .radial: return "点「拖画径向」后拖出椭圆；拖中心移动，拖横/竖边缩放，拖旋转柄改变角度，羽化控制内外过渡"
        case .colorRange: return "在画布上按住拖动，取哪点算哪点的颜色；「容差」控制收进来的颜色范围"
        case .luminanceRange: return "在画布上按住拖动取样亮度；也可用下面的上下界滑块手动框定"
        case .subject: return "系统视觉模型算显著性主体（本地跑，不联网），第一次算要等一两秒，结果会缓存"
        case .person: return "系统人物分割（本地跑），自动圈出画面里的人；换图或结果不准时点「重算」"
        case .foreground: return "前景实例抠图（本地跑）：软边 float 蒙版，可直接在导出时选「透明背景抠图」；结果不准点「重算」"
        case .depth: return "散景深度涂绘：在画布上把想虚化的背景涂白、要清晰的主体留黑；配合「焦外散景」强度使用"
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(MaskKind.allCases, id: \.self) { k in
                    MaskAddButton(kind: k)
                }
            }
            if s.source != nil {
                HStack(spacing: 6) {
                    Button { s.startMaskDrawing(.linear) } label: {
                        Label("拖画线性", systemImage: "line.diagonal")
                    }
                    Button { s.startMaskDrawing(.radial) } label: {
                        Label("拖画径向", systemImage: "oval")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("像 Lightroom 一样在画布上拖动创建渐变蒙版")
            }
            Label(maskHint, systemImage: "text.bubble")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(s.params.masks) { m in
                let isSel = s.selectedMask == m.id
                let maskName = m.name
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: isSel ? "circle.inset.filled" : "circle")
                            .font(.system(size: 9))
                            .foregroundStyle(isSel ? Color.accentColor : .secondary)
                            .onTapGesture {
                                if isSel {
                                    s.selectedMask = nil
                                } else {
                                    s.selectedMask = m.id
                                    s.maskTool = .position
                                }
                            }
                        Image(systemName: m.kind.icon)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(maskName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(get: { m.enabled }, set: { var x = m; x.enabled = $0; s.updateMask(x) }))
                            .labelsHidden().controlSize(.mini)
                        Button {
                            var x = m; x.inverted.toggle(); s.updateMask(x)
                        } label: {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help(m.inverted ? "取消反转" : "反转蒙版")
                        Button {
                            s.duplicateMask(m.id)
                        } label: {
                            Image(systemName: "plus.square.on.square")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help("复制蒙版")
                        Button {
                            s.removeMask(m.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help("删除蒙版")
                    }
                    if s.selectedMask == m.id {
                        MaskEditingControls()
                        if m.kind.usesVision {
                            HStack(spacing: 6) {
                                Button("重算 AI 蒙版") {
                                    s.recomputeMask(m.id)
                                }
                                .controlSize(.small)
                                Spacer()
                            }
                        }
                        if m.kind == .colorRange {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(red: m.sampleRGB[0], green: m.sampleRGB[1], blue: m.sampleRGB[2]))
                                    .frame(width: 30, height: 18)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.3), lineWidth: 1))
                                Text("取样色（也可直接在画布上拖）")
                                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            SliderRow(label: "容差", value: Binding(
                                get: { m.tolerance },
                                set: { var x = m; x.tolerance = $0; s.updateMaskLive(x) }), range: 0.02...0.8) { s.endEdit() }
                        }
                        if m.kind == .luminanceRange {
                            SliderRow(label: "下限", value: Binding(
                                get: { m.lumLow },
                                set: { var x = m; x.lumLow = min($0, x.lumHigh); s.updateMaskLive(x) }), range: 0...1) { s.endEdit() }
                            SliderRow(label: "上限", value: Binding(
                                get: { m.lumHigh },
                                set: { var x = m; x.lumHigh = max($0, x.lumLow); s.updateMaskLive(x) }), range: 0...1) { s.endEdit() }
                            SliderRow(label: "软边", value: Binding(
                                get: { m.lumSoft },
                                set: { var x = m; x.lumSoft = $0; s.updateMaskLive(x) }), range: 0.01...0.5) { s.endEdit() }
                        }
                        if m.kind == .brush || m.kind == .depth {
                            SliderRow(label: "笔刷", value: Binding(
                                get: { m.strokes.last?.radius ?? 0.05 },
                                set: { var x = m; if !x.strokes.isEmpty { x.strokes[x.strokes.count - 1].radius = $0 } else { x.strokes.append(Stroke(pts: [], radius: $0, feather: x.feather)) }; s.updateMaskLive(x) }),
                                range: 0.005...0.3) { s.endEdit() }
                        }
                        if m.kind == .radial {
                            SliderRow(label: "横半径", value: Binding(
                                get: { m.radiusX ?? m.radius },
                                set: { var x = MaskGeometry.ellipse(m); x.radiusX = $0; s.updateMaskLive(x) }), range: 0.05...1.5) { s.endEdit() }
                            SliderRow(label: "纵半径", value: Binding(
                                get: { m.radiusY ?? m.radius },
                                set: { var x = MaskGeometry.ellipse(m); x.radiusY = $0; s.updateMaskLive(x) }), range: 0.05...1.5) { s.endEdit() }
                            SliderRow(label: "旋转", value: Binding(
                                get: { m.radialAngle },
                                set: { var x = MaskGeometry.ellipse(m); x.radialAngle = $0; s.updateMaskLive(x) }), range: -180...180) { s.endEdit() }
                        }
                        SliderRow(label: "羽化", value: Binding(
                            get: { m.feather },
                            set: { var x = m; x.feather = $0; s.updateMaskLive(x) }), range: 0...1) { s.endEdit() }
                        if m.kind != .depth {
                            Divider()
                            SliderRow(label: "曝光", value: Binding(
                                get: { m.adjust.exposure },
                                set: { var x = m; x.adjust.exposure = $0; s.updateMaskLive(x) }), range: -4...4) { s.endEdit() }
                            SliderRow(label: "对比", value: Binding(
                                get: { m.adjust.contrast },
                                set: { var x = m; x.adjust.contrast = $0; s.updateMaskLive(x) })) { s.endEdit() }
                            SliderRow(label: "饱和", value: Binding(
                                get: { m.adjust.saturation },
                                set: { var x = m; x.adjust.saturation = $0; s.updateMaskLive(x) })) { s.endEdit() }
                            SliderRow(label: "色温", value: Binding(
                                get: { m.adjust.temperature },
                                set: { var x = m; x.adjust.temperature = $0; s.updateMaskLive(x) })) { s.endEdit() }
                            SliderRow(label: "清晰", value: Binding(
                                get: { m.adjust.clarity },
                                set: { var x = m; x.adjust.clarity = $0; s.updateMaskLive(x) }), range: 0...100) { s.endEdit() }
                            SliderRow(label: "锐化", value: Binding(
                                get: { m.adjust.sharpen },
                                set: { var x = m; x.adjust.sharpen = $0; s.updateMaskLive(x) }), range: 0...100) { s.endEdit() }
                            SliderRow(label: "高光", value: Binding(
                                get: { m.adjust.highlights },
                                set: { var x = m; x.adjust.highlights = $0; s.updateMaskLive(x) })) { s.endEdit() }
                            SliderRow(label: "阴影", value: Binding(
                                get: { m.adjust.shadows },
                                set: { var x = m; x.adjust.shadows = $0; s.updateMaskLive(x) })) { s.endEdit() }
                            SliderRow(label: "纹理", value: Binding(
                                get: { m.adjust.texture },
                                set: { var x = m; x.adjust.texture = $0; s.updateMaskLive(x) }), range: -100...100) { s.endEdit() }
                            SliderRow(label: "去朦胧", value: Binding(
                                get: { m.adjust.dehaze },
                                set: { var x = m; x.adjust.dehaze = $0; s.updateMaskLive(x) }), range: -100...100) { s.endEdit() }
                            SliderRow(label: "降噪", value: Binding(
                                get: { m.adjust.denoise },
                                set: { var x = m; x.adjust.denoise = $0; s.updateMaskLive(x) }), range: 0...100) { s.endEdit() }
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSel ? Color.accentColor.opacity(0.09)
                               : Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSel ? Color.accentColor.opacity(0.4)
                            : Color(nsColor: .rfCardBorder), lineWidth: isSel ? 1 : 0.5))
            }
        }
    }
}

// MARK: - 导出
/// 水印设置（导出 / 批量导出共用）：文字或图片，九宫格定位、大小、不透明度、旋转
struct WatermarkControls: View {
    @Binding var settings: ExportSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("类型", selection: $settings.watermarkKind) {
                Text("文字").tag("text"); Text("图片").tag("image")
            }.pickerStyle(.segmented)

            if settings.watermarkKind == "text" {
                TextField("水印文字", text: $settings.watermarkText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Toggle("黑字（浅色画面用）", isOn: $settings.watermarkDarkText)
                    .font(.system(size: 10.5))
            } else {
                HStack(spacing: 6) {
                    Button("选择图片…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
                        if p.runModal() == .OK, let u = p.url {
                            settings.watermarkImagePath = u.path
                        }
                    }
                    Text(settings.watermarkImagePath.isEmpty
                         ? "未选择（PNG 带透明最佳）"
                         : URL(fileURLWithPath: settings.watermarkImagePath).lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("位置").font(.system(size: 10)).foregroundStyle(.secondary)
                    WMPosGrid(pos: $settings.watermarkPosition)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(settings.watermarkKind == "text" ? "字号（占长边）" : "宽度（占长边）")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $settings.watermarkScale, in: 0.01...0.30)
                    Text("不透明度 \(Int(settings.watermarkOpacity * 100))%")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $settings.watermarkOpacity, in: 0.05...1)
                    Text("旋转 \(Int(settings.watermarkRotation))°")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $settings.watermarkRotation, in: -45...45)
                }
            }
            SliderRow(label: "边距", value: $settings.watermarkMargin, range: 0...0.12)
            Text("水印只叠在导出文件上，不进预览、不进副档")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .onChange(of: settings.watermarkKind) { k in
            // 换类型时给个合适的默认大小，免得文字水印小得看不见
            if k == "image" { if settings.watermarkScale < 0.08 { settings.watermarkScale = 0.15 } }
            else            { if settings.watermarkScale > 0.12 { settings.watermarkScale = 0.05 } }
        }
    }
}

/// 3×3 九宫格位置选择
struct WMPosGrid: View {
    @Binding var pos: String
    private let rows = [["topLeft", "topCenter", "topRight"],
                        ["midLeft", "center", "midRight"],
                        ["bottomLeft", "bottomCenter", "bottomRight"]]
    var body: some View {
        VStack(spacing: 3) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(row, id: \.self) { p in
                        Button { pos = p } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(pos == p ? Color.accentColor : Color.secondary.opacity(0.22))
                                .frame(width: 22, height: 14)
                        }
                        .buttonStyle(.plain)
                        .help(p)
                    }
                }
            }
        }
    }
}

// MARK: - 导出目录行
/// 显示当前固定导出文件夹，可更改（写进 UserDefaults，源码不含个人路径）/ 在访达中显示
struct ExportDirRow: View {
    @AppStorage(ExportPaths.key) private var dir: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(ExportPaths.defaultDir.path)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(ExportPaths.defaultDir.path)
            Spacer()
            Button("更改…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true
                p.canChooseFiles = false
                p.directoryURL = ExportPaths.defaultDir
                if p.runModal() == .OK, let u = p.url { dir = u.path }
            }.controlSize(.small)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([ExportPaths.defaultDir])
            } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("在访达中显示")
        }
    }
}

struct ExportSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) var dismiss
    @State private var cutoutMode = false

    private var hasForeground: Bool {
        s.params.masks.contains { $0.kind == .foreground && $0.enabled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                Text("导出当前照片")
                    .font(.system(size: 15, weight: .bold))
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ExportDirRow()
                Divider()
                Picker("格式", selection: $s.exportSettings.format) {
                    if !cutoutMode { Text("JPEG").tag("jpg") }
                    Text("PNG").tag("png"); Text("TIFF").tag("tiff")
                    if !cutoutMode { Text("HEIC").tag("heic") }
                }.pickerStyle(.segmented)
                OutputPrecisionControls(settings: $s.exportSettings)
                SliderRow(label: "质量", value: $s.exportSettings.quality, range: 0.3...1)
                    .disabled(s.exportSettings.format == "tiff" || s.exportSettings.format == "png")
                SliderRow(label: "长边", value: Binding(
                    get: { Double(s.exportSettings.maxLongEdge) },
                    set: { s.exportSettings.maxLongEdge = Int($0) }), range: 0...8000)
                Toggle("输出锐化", isOn: $s.exportSettings.sharpenForOutput)

                Divider()
                Toggle("添加水印", isOn: $s.exportSettings.watermarkEnabled)
                    .font(.system(size: 11))
                if s.exportSettings.watermarkEnabled {
                    WatermarkControls(settings: $s.exportSettings)
                }

                Divider()
                Toggle("透明背景抠图（用主体抠图蒙版）", isOn: $cutoutMode)
                    .font(.system(size: 11))
                    .disabled(!hasForeground)
                if cutoutMode {
                    Text("透明背景需要 alpha：格式自动设为 PNG（也可选 TIFF）。HEIC alpha 兼容性未保证")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .onChange(of: cutoutMode) { on in
                if on, s.exportSettings.format != "png" && s.exportSettings.format != "tiff" {
                    s.exportSettings.format = "png"
                }
            }
            }.frame(maxHeight: 480)

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let ext = s.exportSettings.format
                    let p = NSSavePanel()
                    p.directoryURL = ExportPaths.defaultDir
                    p.nameFieldStringValue = (s.current?.url.deletingPathExtension()
                        .lastPathComponent ?? "out") + "." + ext
                    if p.runModal() == .OK, let u = p.url {
                        if cutoutMode { s.exportCutout(to: u) } else { s.exportCurrent(to: u) }
                        dismiss()
                    }
                } label: {
                    Label(cutoutMode ? "导出抠图…" : "导出…",
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(s.source == nil || s.exportRunning)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20).frame(width: 430).background(StudioStyle.panel)
    }
}

// MARK: - 批量
struct BatchSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) var dismiss
    @State private var onlyPicked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                Text("批量导出")
                    .font(.system(size: 15, weight: .bold))
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("会套用每张照片各自的调整（读它的 .rawforge.json）",
                      systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                ExportDirRow()
                Divider()
                Picker("格式", selection: $s.exportSettings.format) {
                    Text("JPEG").tag("jpg"); Text("PNG").tag("png")
                    Text("TIFF").tag("tiff"); Text("HEIC").tag("heic")
                }.pickerStyle(.segmented)
                OutputPrecisionControls(settings: $s.exportSettings)
                SliderRow(label: "质量", value: $s.exportSettings.quality, range: 0.3...1)
                    .disabled(s.exportSettings.format == "tiff" || s.exportSettings.format == "png")
                SliderRow(label: "长边", value: Binding(
                    get: { Double(s.exportSettings.maxLongEdge) },
                    set: { s.exportSettings.maxLongEdge = Int($0) }), range: 0...8000)
                Toggle("只导出已标记的照片", isOn: $onlyPicked)
                Divider()
                Toggle("添加水印", isOn: $s.exportSettings.watermarkEnabled)
                    .font(.system(size: 11))
                if s.exportSettings.watermarkEnabled {
                    WatermarkControls(settings: $s.exportSettings)
                }
                if s.batchRunning {
                    ProgressView(value: s.batchProgress)
                        .controlSize(.small)
                }
            }
            .padding(12)
            }.frame(maxHeight: 480)

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("选其他目录…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    p.directoryURL = ExportPaths.defaultDir
                    if p.runModal() == .OK, let u = p.url {
                        Task { await s.batchExport(to: u, onlyPicked: onlyPicked) }
                        dismiss()
                    }
                }
                .disabled(s.batchRunning || !s.items.contains { !onlyPicked || $0.picked })
                Button {
                    let dest = ExportPaths.defaultDir
                    Task { await s.batchExport(to: dest, onlyPicked: onlyPicked) }
                    dismiss()
                } label: {
                    Label("导出到固定文件夹", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(s.batchRunning || !s.items.contains { !onlyPicked || $0.picked })
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20).frame(width: 430).background(StudioStyle.panel)
    }
}
