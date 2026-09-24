import SwiftUI
import CoreImage

@MainActor
func bind(_ kp: WritableKeyPath<EditParams, Double>, _ s: AppState) -> Binding<Double> {
    Binding(get: { s.params[keyPath: kp] }, set: { s.set(kp, $0) })
}

// MARK: - 分组容器
struct GroupBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = true
    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation { open.toggle() }
            } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).frame(width: 12)
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            if open {
                VStack(spacing: 3) { content }
                    .padding(.horizontal, 8).padding(.bottom, 8)
            }
            Divider()
        }
    }
}

// MARK: - 检视器
struct InspectorPane: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                GroupBox(title: "基本") {
                    SliderRow(label: "色温", value: bind(\.temperature, s)) { s.endEdit() }
                    SliderRow(label: "色调", value: bind(\.tint, s)) { s.endEdit() }
                    Divider().padding(.vertical, 2)
                    SliderRow(label: "曝光", value: bind(\.exposure, s), range: -5...5) { s.endEdit() }
                    SliderRow(label: "对比", value: bind(\.contrast, s)) { s.endEdit() }
                    SliderRow(label: "高光", value: bind(\.highlights, s)) { s.endEdit() }
                    SliderRow(label: "阴影", value: bind(\.shadows, s)) { s.endEdit() }
                    SliderRow(label: "白色", value: bind(\.whites, s)) { s.endEdit() }
                    SliderRow(label: "黑色", value: bind(\.blacks, s)) { s.endEdit() }
                    Divider().padding(.vertical, 2)
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
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
                    let g = s.params[keyPath: keyPath(i)]
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

    private let hueColors: [Color] = (0..<13).map {
        Color(hue: Double($0) / 12, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side / 2
            let center = CGPoint(x: r, y: r)
            let dot = dotPosition(radius: r)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: hueColors, center: .center))
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
            }
            let all = s.cluts.list()
            let shown = q.isEmpty ? Array(all.prefix(60))
                : Array(all.filter { $0.localizedCaseInsensitiveContains(q) }.prefix(60))
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
            Text("共 \(all.count) 个可用").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 蒙版面板
struct MaskPane: View {
    @EnvironmentObject var s: AppState

    private var maskHint: String {
        guard let id = s.selectedMask,
              let m = s.params.masks.first(where: { $0.id == id }) else {
            return "点上方按钮新建一个蒙版，然后在这里给它单独设参数"
        }
        switch m.kind {
        case .brush: return "已在画笔模式：直接在画布上按住拖动涂抹（一次拖动算一笔）；调「笔刷」改大小、「羽化」改边缘软硬"
        case .linear: return "直接拖画布或拖动蓝色圆点，整条渐变一起走"
        case .radial: return "拖动黄色圆点移动圆心，拖画布整体位移"
        case .colorRange: return "在画布上按住拖动，取哪点算哪点的颜色；「容差」控制收进来的颜色范围"
        case .luminanceRange: return "在画布上按住拖动取样亮度；也可用下面的上下界滑块手动框定"
        case .subject: return "系统视觉模型算显著性主体（本地跑，不联网），第一次算要等一两秒，结果会缓存"
        case .person: return "系统人物分割（本地跑），自动圈出画面里的人；换图或结果不准时点「重算」"
        }
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach([MaskKind.linear, .radial, .brush], id: \.self) { k in
                    Button(k.label) { s.addMask(k) }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Text("取样").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                ForEach([MaskKind.colorRange, .luminanceRange], id: \.self) { k in
                    Button(k.label) { s.addMask(k) }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Text("AI").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                ForEach([MaskKind.subject, .person], id: \.self) { k in
                    Button(k.label) { s.addMask(k) }.controlSize(.small)
                }
            }
            Text(maskHint)
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(s.params.masks) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: s.selectedMask == m.id ? "circle.inset.filled" : "circle")
                            .font(.system(size: 9))
                            .onTapGesture { s.selectedMask = (s.selectedMask == m.id ? nil : m.id) }
                        Text(m.name).font(.system(size: 11))
                        Spacer()
                        Toggle("", isOn: Binding(get: { m.enabled }, set: { var x = m; x.enabled = $0; s.updateMask(x) }))
                            .labelsHidden().controlSize(.mini)
                        Button("反") { var x = m; x.inverted.toggle(); s.updateMask(x) }.controlSize(.mini)
                        Button("×") { s.removeMask(m.id) }.controlSize(.mini)
                    }
                    if s.selectedMask == m.id {
                        if m.kind.usesVision {
                            HStack(spacing: 6) {
                                Button("重算 AI 蒙版") {
                                    var x = m
                                    Engine.invalidateAIMask(id: x.id)
                                    // 换个 id 强制刷新（缓存按 id 存）
                                    x.id = UUID()
                                    s.updateMask(x)
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
                                set: { var x = m; x.tolerance = $0; s.updateMask(x) }), range: 0.02...0.8) { s.endEdit() }
                        }
                        if m.kind == .luminanceRange {
                            SliderRow(label: "下限", value: Binding(
                                get: { m.lumLow },
                                set: { var x = m; x.lumLow = min($0, x.lumHigh); s.updateMask(x) }), range: 0...1) { s.endEdit() }
                            SliderRow(label: "上限", value: Binding(
                                get: { m.lumHigh },
                                set: { var x = m; x.lumHigh = max($0, x.lumLow); s.updateMask(x) }), range: 0...1) { s.endEdit() }
                            SliderRow(label: "软边", value: Binding(
                                get: { m.lumSoft },
                                set: { var x = m; x.lumSoft = $0; s.updateMask(x) }), range: 0.01...0.5) { s.endEdit() }
                        }
                        if m.kind == .brush {
                            SliderRow(label: "笔刷", value: Binding(
                                get: { m.strokes.last?.radius ?? 0.05 },
                                set: { var x = m; if !x.strokes.isEmpty { x.strokes[x.strokes.count - 1].radius = $0 } else { x.strokes.append(Stroke(pts: [], radius: $0, feather: x.feather)) }; s.updateMask(x) }),
                                range: 0.005...0.3) { s.endEdit() }
                        }
                        if m.kind == .radial {
                            SliderRow(label: "半径", value: Binding(
                                get: { m.radius },
                                set: { var x = m; x.radius = $0; s.updateMask(x) }), range: 0.05...1) { s.endEdit() }
                        }
                        SliderRow(label: "羽化", value: Binding(
                            get: { m.feather },
                            set: { var x = m; x.feather = $0; s.updateMask(x) }), range: 0...1) { s.endEdit() }
                        Divider()
                        SliderRow(label: "曝光", value: Binding(
                            get: { m.adjust.exposure },
                            set: { var x = m; x.adjust.exposure = $0; s.updateMask(x) }), range: -4...4) { s.endEdit() }
                        SliderRow(label: "对比", value: Binding(
                            get: { m.adjust.contrast },
                            set: { var x = m; x.adjust.contrast = $0; s.updateMask(x) })) { s.endEdit() }
                        SliderRow(label: "饱和", value: Binding(
                            get: { m.adjust.saturation },
                            set: { var x = m; x.adjust.saturation = $0; s.updateMask(x) })) { s.endEdit() }
                        SliderRow(label: "色温", value: Binding(
                            get: { m.adjust.temperature },
                            set: { var x = m; x.adjust.temperature = $0; s.updateMask(x) })) { s.endEdit() }
                        SliderRow(label: "清晰", value: Binding(
                            get: { m.adjust.clarity },
                            set: { var x = m; x.adjust.clarity = $0; s.updateMask(x) }), range: 0...100) { s.endEdit() }
                        SliderRow(label: "锐化", value: Binding(
                            get: { m.adjust.sharpen },
                            set: { var x = m; x.adjust.sharpen = $0; s.updateMask(x) }), range: 0...100) { s.endEdit() }
                    }
                }
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

// MARK: - 导出
struct ExportSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导出当前照片").font(.headline)
            Picker("格式", selection: $s.exportSettings.format) {
                Text("JPEG").tag("jpg"); Text("PNG").tag("png")
                Text("TIFF").tag("tiff"); Text("HEIC").tag("heic")
            }.pickerStyle(.segmented)
            SliderRow(label: "质量", value: $s.exportSettings.quality, range: 0.3...1)
            SliderRow(label: "长边", value: Binding(
                get: { Double(s.exportSettings.maxLongEdge) },
                set: { s.exportSettings.maxLongEdge = Int($0) }), range: 0...8000)
            Toggle("输出锐化", isOn: $s.exportSettings.sharpenForOutput)
            HStack {
                Button("取消") { dismiss() }
                Button("导出…") {
                    let p = NSSavePanel()
                    p.nameFieldStringValue = (s.current?.url.deletingPathExtension().lastPathComponent ?? "out")
                        + "." + s.exportSettings.format
                    if p.runModal() == .OK, let u = p.url { s.exportCurrent(to: u) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18).frame(width: 380)
    }
}

// MARK: - 批量
struct BatchSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) var dismiss
    @State private var onlyPicked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("批量导出").font(.headline)
            Text("会套用每张照片各自的调整（读它的 .rawforge.json）")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("格式", selection: $s.exportSettings.format) {
                Text("JPEG").tag("jpg"); Text("PNG").tag("png")
                Text("TIFF").tag("tiff"); Text("HEIC").tag("heic")
            }.pickerStyle(.segmented)
            SliderRow(label: "质量", value: $s.exportSettings.quality, range: 0.3...1)
            SliderRow(label: "长边", value: Binding(
                get: { Double(s.exportSettings.maxLongEdge) },
                set: { s.exportSettings.maxLongEdge = Int($0) }), range: 0...8000)
            Toggle("只导出已标记的照片", isOn: $onlyPicked)
            if s.batchRunning { ProgressView(value: s.batchProgress) }
            HStack {
                Button("取消") { dismiss() }
                Button("选择目录并导出") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url {
                        Task { await s.batchExport(to: u, onlyPicked: onlyPicked) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18).frame(width: 400)
    }
}
