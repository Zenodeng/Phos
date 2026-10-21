import SwiftUI
import CoreImage

@MainActor
func bind(_ kp: WritableKeyPath<EditParams, Double>, _ s: AppState) -> Binding<Double> {
    Binding(get: { s.params[keyPath: kp] }, set: { s.set(kp, $0) })
}

/// 「对比」滑块的响应指数：>1 时中段更精细 —— 靠近零位每拖一像素走过的数值更小，
/// 不容易一拖就过；两端仍能到达 ±100。数值本身的意义不变（引擎映射没动）。
/// 想让手感更钝就调大，想更接近线性就调小。
let contrastResponse = 1.8

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

// MARK: - 自动影调
//
// 一键自动 + 强度滑杆。滑杆按增量调，所以拖回 0% 等于把自动加的那部分减掉，
// 中途手动改过的滑块不会被覆盖（见 AppState.setAutoStrength）。
private struct AutoToneRow: View {
    @EnvironmentObject var s: AppState

    private var strengthBinding: Binding<Double> {
        Binding(get: { s.autoStrength }, set: { s.setAutoStrength($0, persist: false) })
    }
    private var busy: Bool { s.autoRunning }
    private var blocked: Bool { s.source == nil || busy || s.cropMode || s.syncRunning }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button { s.runAutoTone() } label: {
                    HStack(spacing: 5) {
                        if busy {
                            ProgressView().controlSize(.small).scaleEffect(0.62).frame(width: 13, height: 13)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 11.5))
                        }
                        Text(busy ? "分析中…" : "自动").font(.system(size: 11.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .foregroundStyle(blocked ? Color.secondary.opacity(0.5) : WorkspaceTokens.primaryText)
                    .modifier(WorkspaceGlassDecoration(selected: true, radius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(WorkspaceButtonStyle(chrome: false))
                .disabled(blocked)
                .help("按画面直方图自动给出曝光、对比、高光阴影、去朦胧、鲜艳度与白平衡")

                if s.autoSolution != nil || s.autoScene != nil {
                    ToolButton(systemImage: "arrow.uturn.backward", title: "撤销自动调整") {
                        s.setAutoStrength(0, persist: true)
                        s.clearAutoTone()
                    }
                }
            }
            if let guess = s.autoScene {
                HStack(spacing: 8) {
                    Text("场景")
                        .frame(width: 58, alignment: .leading)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    // 识别错了可以自己换一个重跑 —— 不让「魔法」不可控
                    Menu {
                        ForEach(PhotoScene.allCases) { scene in
                            Button(scene.label) { s.runAutoTone(forcedScene: scene) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(guess.scene.label).font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(StudioStyle.accent)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(s.autoRunning)
                    .help("识别有误？从这里选一个题材重新自动")
                    Text("\(Int((guess.confidence * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(guess.scene.hint)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(minHeight: 24)
            }
            if s.autoSolution != nil {
                HStack(spacing: 10) {
                    Text("自动强度")
                        .frame(width: 58, alignment: .leading)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Slider(value: strengthBinding, in: 0...1) { editing in
                        if !editing { s.setAutoStrength(s.autoStrength, persist: true) }
                    }.controlSize(.small)
                    Text("\(Int((s.autoStrength * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioStyle.accent)
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(minHeight: 28)
            }
        }
        .padding(.bottom, 2)
    }
}

// MARK: - 分组容器
struct GroupBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @EnvironmentObject private var s: AppState
    @EnvironmentObject private var ui: WorkspaceInspectorState
    @Environment(\.inspectorCategory) private var category
    private var modified: Bool { ParameterGroupSchema.modified(title,in:s.params) }
    var body: some View {
        if category == nil || category == InspectorCategory.category(for:title) {
            VStack(spacing:0) {
                HStack(spacing:6) {
                    Button {
                        s.parameterEdits.finishCurrent()
                        ui.expanded[title] = !ui.isExpanded(title)
                    } label: {
                        HStack(spacing:7) {
                            Image(systemName:ui.isExpanded(title) ? "chevron.down" : "chevron.right")
                                .font(.system(size:8,weight:.semibold)).frame(width:10)
                            Text(title).font(.system(size:12,weight:.semibold))
                            if modified { Circle().fill(WorkspaceTokens.accent).frame(width:4,height:4).accessibilityLabel("已修改") }
                            Spacer(minLength:0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(title+"分组")
                    if title == "白平衡" {
                        Button {
                            s.parameterEdits.finishCurrent(); s.showBefore = false; s.whiteBalancePicker.toggle()
                        } label: { Image(systemName:"eyedropper").font(.system(size:11)).frame(width:24,height:24) }
                            .buttonStyle(.plain).foregroundStyle(s.whiteBalancePicker ? WorkspaceTokens.accent : WorkspaceTokens.secondaryText)
                            .disabled(s.source == nil || s.previewing || s.whiteBalanceRunning || s.cropMode)
                            .help("白平衡灰点取样").accessibilityLabel("白平衡灰点取样")
                    }
                    Button {
                        s.parameterEdits.invalidate()
                        if title == "局部调整（蒙版）" { s.selectedMask = nil }
                        s.commit(ParameterGroupSchema.reset(title,in:s.params))
                    } label: { Image(systemName:"arrow.counterclockwise").font(.system(size:11)).frame(width:24,height:24) }
                        .buttonStyle(WorkspaceButtonStyle()).disabled(!modified).opacity(modified ? 1 : 0.35)
                        .help("复位"+title).accessibilityLabel("复位"+title)
                }.frame(height:34)
                if ui.isExpanded(title) { VStack(spacing:0) { content }.padding(.bottom,10) }
            }.padding(.horizontal,12)
                .overlay(alignment:.bottom) { WorkspaceTokens.hairline.frame(height:0.5).padding(.horizontal,12) }
        }
    }
}

// MARK: - 检视器
@MainActor struct InspectorPane: View {
    @EnvironmentObject var s: AppState
    @ObservedObject private var ui: WorkspaceInspectorState
    private var category: InspectorCategory { ui.category }
    @State private var confirmReset = false
    @Namespace private var categoryGlass
    @Environment(\.workspaceAccessibility) private var glassOptions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var transparent: Bool

    init(initialCategory: InspectorCategory = .light, transparent: Bool = false, ui: WorkspaceInspectorState? = nil) {
        let context = ui ?? WorkspaceInspectorState()
        if ui == nil { context.category = initialCategory }
        self.ui = context
        self.transparent = transparent
    }

    var body: some View {
        VStack(spacing: 0) {
            if !transparent {
            HStack {
                Text("参数").font(.system(size:10,weight:.medium)).foregroundStyle(WorkspaceTokens.secondaryText)
                Spacer()
                Button { s.parameterEdits.invalidate(); confirmReset = true } label: { Image(systemName:"arrow.counterclockwise").font(.system(size:11)) }
                    .buttonStyle(.plain).disabled(s.source == nil).help("恢复所有默认参数").accessibilityLabel("恢复所有默认参数")
            }.padding(.horizontal,12).frame(height:24)
            }
            HStack(spacing: 0) {
                ForEach(InspectorCategory.allCases, id: \.self) { tab in
                    Button { s.parameterEdits.finishCurrent(); ui.category = tab } label: {
                        VStack(spacing: 7) {
                            Image(systemName: tab.symbol).font(.system(size: 13)).frame(height: 18)
                            Text(tab.rawValue).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(height: 13)
                        }.frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(category == tab ? (transparent ? WorkspaceTokens.primaryText : StudioStyle.accent) : Color.secondary)
                        .background {
                            if category == tab {
                                Color.clear.modifier(WorkspaceGlassDecoration(selected: true))
                                    .matchedGeometryEffect(id: "inspectorCategory", in: categoryGlass)
                            }
                        }
                    }.buttonStyle(WorkspaceButtonStyle(chrome:false)).help(tab.rawValue)
                }
            }
            .animation(reduceMotion || glassOptions.reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82), value: category)
            Divider()
        ScrollView {
            VStack(spacing: 0) {
                GroupBox(title: "白平衡") {
                    WorkspacePhotoParameter(id: "temperature")
                    WorkspacePhotoParameter(id: "tint")
                }
                GroupBox(title: "基本") {
                    AutoToneRow()
                    WorkspacePhotoParameter(id: "exposure")
                    WorkspacePhotoParameter(id: "contrast")
                    WorkspacePhotoParameter(id: "highlights")
                    WorkspacePhotoParameter(id: "shadows")
                    WorkspacePhotoParameter(id: "whites")
                    WorkspacePhotoParameter(id: "blacks")
                }
                GroupBox(title: "质感与饱和度") {
                    WorkspacePhotoParameter(id: "texture")
                    WorkspacePhotoParameter(id: "clarity")
                    WorkspacePhotoParameter(id: "dehaze")
                    WorkspacePhotoParameter(id: "vibrance")
                    WorkspacePhotoParameter(id: "saturation")
                    Divider().padding(.vertical, 2)
                    Toggle("HDR（压高光、拉暗部）",
                           isOn: Binding(get: { s.params.hdrMode },
                                         set: { s.set(\.hdrMode, $0); s.endEdit() }))
                        .font(.system(size: 11))
                    if s.params.hdrMode {
                        WorkspacePhotoParameter(id: "hdrLimit")
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
                        WorkspacePhotoParameter(id: "monoRed")
                        WorkspacePhotoParameter(id: "monoGreen")
                        WorkspacePhotoParameter(id: "monoBlue")
                    }
                }

                GroupBox(title: "细节") {
                    WorkspacePhotoParameter(id: "sharpen")
                    WorkspacePhotoParameter(id: "sharpenRadius")
                    WorkspacePhotoParameter(id: "sharpenDetail")
                    WorkspacePhotoParameter(id: "sharpenMask")
                    WorkspacePhotoParameter(id: "denoise")
                    WorkspacePhotoParameter(id: "denoiseColor")
                    WorkspacePhotoParameter(id: "grain")
                    WorkspacePhotoParameter(id: "grainSize")
                }

                GroupBox(title: "效果") {
                    WorkspacePhotoParameter(id: "vignette")
                    WorkspacePhotoParameter(id: "vignetteStart")
                    Divider().padding(.vertical, 2)
                    WorkspacePhotoParameter(id: "halation")
                    if s.params.halation > 0 {
                        WorkspacePhotoParameter(id: "halationThreshold")
                        WorkspacePhotoParameter(id: "halationRadius")
                    }
                }

                GroupBox(title: "焦外散景") {
                    WorkspacePhotoParameter(id: "bokehAmount")
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
                    WorkspacePhotoParameter(id: "caAmount")
                    Text("横向色差：R/B 通道反向微缩放（正=收红边）")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    WorkspacePhotoParameter(id: "purpleFringe")
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
                    WorkspacePhotoParameter(id: "clutStrength")
                }

                GroupBox(title: "变换与裁剪") {
                    HStack(spacing: 6) {
                        Button { s.toggleCropMode() } label: {
                            Text("裁剪").font(.system(size:11)).frame(height:14)
                        }.controlSize(.small)
                            .help("进入画布裁剪模式（R）：拖角/边裁剪、切画幅、自动校直")
                        Button { s.autoStraighten() } label: {
                            Text(s.autoLevelRunning ? "检测中…" : "自动水平").font(.system(size:11)).frame(height:14)
                        }.controlSize(.small)
                            .disabled(s.source == nil || s.autoLevelRunning)
                            .help("本地检测地平线并校正倾斜，可撤销")
                        Spacer()
                    }.padding(.bottom,6)
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
                    WorkspacePhotoParameter(id: "straighten")
                    Divider().padding(.vertical, 2)
                    Toggle("自动透视（Vision 检测画面内四边形）",
                           isOn: Binding(get: { s.params.perspectiveAuto },
                                         set: { s.set(\.perspectiveAuto, $0); s.endEdit() }))
                        .font(.system(size: 11))
                    if !s.params.perspectiveAuto {
                        WorkspacePhotoParameter(id: "perspectiveV")
                        WorkspacePhotoParameter(id: "perspectiveH")
                    } else {
                        Text("已按画面内检测到的四边形自动校正；手动滑块仅在关闭自动时生效")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    WorkspacePhotoParameter(id: "cropX")
                    WorkspacePhotoParameter(id: "cropY")
                    WorkspacePhotoParameter(id: "cropW")
                    WorkspacePhotoParameter(id: "cropH")
                }

                GroupBox(title: "局部调整（蒙版）") {
                    MaskPane()
                }
            }
            .environment(\.inspectorCategory, category)
            .disabled(s.source == nil)
            .padding(.bottom, 16)
        }
        
        }
        .environmentObject(ui)
        .background(transparent ? Color.clear : StudioStyle.panel)
        .onChange(of: s.cropMode) { _, active in if active { s.parameterEdits.finishCurrent(); ui.category = .geometry } }
        .onChange(of: s.selectedMask) { _, id in if id != nil { s.parameterEdits.finishCurrent(); ui.category = .masks } }
        .alert("恢复所有默认参数？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) { s.selectedMask = nil; s.commit(EditParams()) }
        } message: { Text("此操作可撤销，原始照片不会改变。") }
    }
}

// MARK: - 曲线（色调 / 亮度 / 单通道）
struct CurvePane: View {
    @EnvironmentObject var s: AppState
    @EnvironmentObject private var ui: WorkspaceInspectorState
    private var mode: Int { ui.curveChannel }
    @State private var showExpanded = false

    private let names = ["色调", "亮度", "R", "G", "B"]
    private var colors: [Color] {
        [WorkspaceTokens.accent, WorkspaceTokens.primaryText, Color(red: 0.95, green: 0.32, blue: 0.32),
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
            Picker("曲线通道", selection: Binding(get:{mode},set:{s.parameterEdits.finishCurrent(); ui.curveChannel = $0})) {
                ForEach(0..<5, id: \.self) { i in Text(names[i]).tag(i) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small)

            CurveEditor(points: Binding(
                get: { s.params[keyPath: keyPath(mode)].points },
                set: { s.set(keyPath(mode), ToneCurve(points: $0)) }),
                color: colors[mode]) { s.endEdit() }
                .frame(height: 200)

            HStack {
                Text("输入 → 输出").font(.system(size:10)).foregroundStyle(WorkspaceTokens.secondaryText)
                Spacer()
                Button("展开曲线…") { s.parameterEdits.finishCurrent(); showExpanded = true }.controlSize(.small)
                    .popover(isPresented:$showExpanded) {
                        VStack(spacing:12) {
                            HStack { Text("曲线 · \(names[mode])").font(.headline); Spacer(); Button("完成") { s.parameterEdits.finishCurrent(); showExpanded = false } }
                            CurveEditor(points:Binding(get:{s.params[keyPath:keyPath(mode)].points},set:{s.set(keyPath(mode),ToneCurve(points:$0))}),color:colors[mode]) { s.endEdit() }
                                .frame(width:320,height:320)
                        }.padding(16).environmentObject(s)
                    }
            }.padding(.vertical,5)
            WorkspacePhotoParameter(id: "refineSat")
            Text("Refine Sat：曲线改完调子后把饱和度拉回来（只改明暗不改颜色浓淡）")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)

            HStack(spacing: 6) {
                Button("复位") { s.parameterEdits.invalidate(); s.set(keyPath(mode), ToneCurve()); s.endEdit() }
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
    var color: Color = WorkspaceTokens.accent
    var onEnd: () -> Void
    @State private var dragIndex: Int?
    @EnvironmentObject private var s: AppState
    @State private var editToken: ParameterEditCoordinator.Token?
    @State private var expanded = false

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
                RoundedRectangle(cornerRadius:8)
                    .fill(WorkspaceTokens.chartColor)
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
                .stroke(WorkspaceTokens.secondaryText.opacity(0.20), lineWidth: 0.5)

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
                        .fill(dragIndex == i ? color : WorkspaceTokens.readoutColor)
                        .overlay(Circle().stroke(color, lineWidth: 1.2))
                        .frame(width: dragIndex == i ? 14 : 11, height: dragIndex == i ? 14 : 11)
                        .position(x: inset + CGFloat(points[i][0]) * plot,
                                  y: inset + CGFloat(1 - points[i][1]) * plot)
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel("曲线控制点 \(i+1)")
                        .accessibilityValue(String(format:"输入 %.2f，输出 %.2f",points[i][0],points[i][1]))
                        .accessibilityAdjustableAction { direction in
                            s.parameterEdits.finishCurrent()
                            var next = points; next[i][1] = min(max(next[i][1] + (direction == .increment ? 0.01 : -0.01),0),1); points = next; onEnd()
                        }
                        .contextMenu {
                            Button("删除该控制点") {
                                guard i != 0, i != points.count - 1 else { return }
                                var pts = points; pts.remove(at: i); points = pts; onEnd()
                            }
                            .disabled(i == 0 || i == points.count - 1)
                        }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace:.named("curvePlot"))
                            .onChanged { v in
                                if editToken == nil { editToken = s.parameterEdits.begin() }
                                guard s.parameterEdits.valid(editToken) else { return }
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
                            .onEnded { _ in
                                dragIndex = nil
                                if s.parameterEdits.complete(editToken) { onEnd() }; editToken = nil
                            })
                }
            }
            .coordinateSpace(name:"curvePlot")
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
    @EnvironmentObject private var ui: WorkspaceInspectorState
    private var band: Int { ui.gradeBand }
    @State private var showExpanded = false

    private let names = ["阴影", "中间调", "高光"]
    private func keyPath(_ i: Int) -> WritableKeyPath<EditParams, ColorGrade> {
        switch i { case 0: return \.gradeShadow; case 2: return \.gradeHigh; default: return \.gradeMid }
    }

    var body: some View {
        VStack(spacing: 8) {
            // 三个圆点按钮（同 LR 的「调整」排），选中档描白边
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { i in
                    Button { s.parameterEdits.finishCurrent(); ui.gradeBand = i } label: {
                    Circle()
                        .fill(dotColor(i))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(band == i ? WorkspaceTokens.primaryText : WorkspaceTokens.secondaryText.opacity(0.4),
                                                 lineWidth: band == i ? 2 : 1))
                    }.buttonStyle(.plain).accessibilityLabel(names[i])
                        .accessibilityAddTraits(band == i ? .isSelected : []).help(names[i])
                }
                Spacer()
                Button("复位") { s.parameterEdits.invalidate(); s.set(keyPath(band), ColorGrade()); s.endEdit() }
                    .controlSize(.small)
            }

            Text(names[band])
                .font(.system(size: 11, weight: .medium))

            // 大色轮：拖到哪就是哪个色相/饱和度，双击复位
            GradeWheel(grade: Binding(
                get: { s.params[keyPath: keyPath(band)] },
                set: { s.set(keyPath(band), $0) })) { s.endEdit() }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 176)
            Button("展开色轮…") { s.parameterEdits.finishCurrent(); showExpanded = true }.controlSize(.small)
                .popover(isPresented:$showExpanded) {
                    VStack(spacing:12) {
                        HStack { Text("颜色分级 · \(names[band])").font(.headline); Spacer(); Button("完成") { s.parameterEdits.finishCurrent(); showExpanded = false } }
                        GradeWheel(grade:Binding(get:{s.params[keyPath:keyPath(band)]},set:{s.set(keyPath(band),$0)})) { s.endEdit() }.frame(width:280,height:280)
                    }.padding(16).environmentObject(s)
                }


            SliderRow(label:"色相",value:Binding(get:{s.params[keyPath:keyPath(band)].hue},set:{var g = s.params[keyPath:keyPath(band)]; g.hue = $0; s.set(keyPath(band),g)}),range:0...360,unit:"°") { s.endEdit() }
            SliderRow(label:"饱和度",value:Binding(get:{s.params[keyPath:keyPath(band)].sat},set:{var g = s.params[keyPath:keyPath(band)]; g.sat = $0; s.set(keyPath(band),g)}),range:0...100) { s.endEdit() }
            SliderRow(label: "明亮", value: Binding(
                get: { s.params[keyPath: keyPath(band)].lum },
                set: { var g = s.params[keyPath: keyPath(band)]; g.lum = $0; s.set(keyPath(band), g) }),
                range: -100...100) { s.endEdit() }

            Divider().padding(.vertical, 2)
            WorkspacePhotoParameter(id: "gradeBlend")
            WorkspacePhotoParameter(id: "gradeBalance")
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
    @EnvironmentObject private var s: AppState
    @State private var editToken: ParameterEditCoordinator.Token?

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
                    if editToken == nil { editToken = s.parameterEdits.begin() }
                    guard s.parameterEdits.valid(editToken) else { return }
                    dragging = true
                    let dx = Double(v.location.x - center.x)
                    let dy = Double(v.location.y - center.y)
                    let dist = (dx * dx + dy * dy).squareRoot()
                    let sat = min(dist / Double(r), 1) * 100
                    // 0° 朝上、顺时针为正（跟 LR 和 HSL 惯例一致）
                    var hue = atan2(dx, -dy) * 180 / .pi
                    if hue < 0 { hue += 360 }
                    var next = grade; next.hue = hue; next.sat = sat; grade = next
                }
                .onEnded { _ in dragging = false; if s.parameterEdits.complete(editToken) { onEnd() }; editToken = nil })
            .onTapGesture(count: 2) { s.parameterEdits.invalidate(); grade = ColorGrade(); onEnd() }
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
    @EnvironmentObject private var ui: WorkspaceInspectorState
    private var band: Int { ui.calibrationBand }

    private let names = ["红原色", "绿原色", "蓝原色"]
    private func keyPath(_ i: Int) -> WritableKeyPath<EditParams, PrimaryAdj> {
        switch i { case 1: return \.primGreen; case 2: return \.primBlue; default: return \.primRed }
    }

    var body: some View {
        VStack(spacing: 4) {
            Picker("校准原色", selection: Binding(get:{band},set:{s.parameterEdits.finishCurrent(); ui.calibrationBand = $0})) {
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
            WorkspacePhotoParameter(id: "calibShadowTint")
            HStack(spacing: 6) {
                Text("正值偏绿 · 负值偏洋红").font(.system(size: 9.5)).foregroundStyle(.secondary)
                Spacer()
                Button("全部复位") {
                    s.parameterEdits.invalidate()
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
    @EnvironmentObject private var ui: WorkspaceInspectorState
    private var band: Int { ui.hslBand }
    var body: some View {
        VStack(spacing: 4) {
            Picker("HSL 颜色", selection: Binding(get:{band},set:{s.parameterEdits.finishCurrent(); ui.hslBand = $0})) {
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
            Button("清空 HSL") { s.parameterEdits.invalidate(); s.set(\.hsl, HSLMix()); s.endEdit() }.controlSize(.small)
        }
    }
}

// MARK: - CLUT 选择
struct ClutPicker: View {
    @EnvironmentObject var s: AppState
    @EnvironmentObject private var ui: WorkspaceInspectorState
    private var q: String { ui.clutQuery }
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                TextField("搜索胶片…", text: $ui.clutQuery).textFieldStyle(.roundedBorder).controlSize(.small)
                Button("清除") { s.set(\.clutName, ""); s.endEdit() }.controlSize(.small)
                Button("刷新") { s.cluts.invalidate(); s.render() }.controlSize(.small)
                    .help("重新扫描 HaldCLUT 目录：往 ~/Documents/RawTherapee/HaldCLUT 里放了新 LUT 后点这里（HALD 的 PNG/TIF 与 .cube 都认）")
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
            Text(all.isEmpty ? "暂无胶片 LUT，可添加 HALD 或 cube 文件后刷新" : shown.isEmpty ? "没有匹配的胶片" : "共 \(all.count) 个可用 · 搜索结果 \(shown.count) 个").font(.system(size: 9.5)).foregroundStyle(.secondary)
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
        .buttonStyle(WorkspaceButtonStyle())
        .controlSize(.small)
        .help(kind.label)
    }
}

struct MaskPane: View {
    @EnvironmentObject var s: AppState

    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var renaming = false
    private var maskHint: String {
        guard let id = s.selectedMask,
              let m = s.params.masks.first(where: { $0.id == id }) else {
            return "点上方按钮新建一个蒙版，然后在这里给它单独设参数"
        }
        switch m.kind {
        case .brush: return "已在画笔模式：直接在画布上按住拖动涂抹（一次拖动算一笔）；调「笔刷」改大小、「羽化」改边缘软硬"
        case .linear: return "从「新建蒙版」选择线性渐变后，在画布上拖出三线渐变；拖中心移动，拖端点改宽度，拖旋转柄改变方向"
        case .radial: return "从「新建蒙版」选择径向渐变后，在画布上拖出椭圆；拖中心移动，拖横/竖边缩放，拖旋转柄改变角度，羽化控制内外过渡"
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
            HStack {
                Menu {
                    ForEach(MaskKind.allCases,id:\.self) { kind in
                        Button { s.createMask(kind) } label: { Label(kind.label,systemImage:kind.icon) }
                    }
                } label: { Label("新建蒙版",systemImage:"plus") }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button { s.showMaskOverlay.toggle() } label: { Image(systemName:"square.3.layers.3d") }
                    .buttonStyle(WorkspaceButtonStyle()).accessibilityLabel("显示或隐藏当前蒙版").help("显示或隐藏当前蒙版").disabled(s.selectedMask == nil)
            }.font(.system(size:11,weight:.medium))
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
                            .foregroundStyle(isSel ? WorkspaceTokens.accent : .secondary)
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
                        Button(maskName) { s.selectedMask = isSel ? nil : m.id }
                            .buttonStyle(.plain).font(.system(size:11,weight:.medium)).lineLimit(1)
                            .help("选择蒙版；右键重命名")
                            .contextMenu { Button("重命名…") { renameID = m.id; renameText = m.name; renaming = true } }
                        Spacer()
                        Toggle("", isOn: Binding(get: { m.enabled }, set: { var x = m; x.enabled = $0; s.updateMask(x) }))
                            .labelsHidden().controlSize(.mini).accessibilityLabel("启用蒙版：" + maskName)
                        Button {
                            var x = m; x.inverted.toggle(); s.updateMask(x)
                        } label: {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(WorkspaceButtonStyle())
                        .controlSize(.mini)
                        .help(m.inverted ? "取消反转" : "反转蒙版").accessibilityLabel(m.inverted ? "取消反转蒙版" : "反转蒙版")
                        Button {
                            s.duplicateMask(m.id)
                        } label: {
                            Image(systemName: "plus.square.on.square")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(WorkspaceButtonStyle())
                        .controlSize(.mini)
                        .help("复制蒙版").accessibilityLabel("复制蒙版")
                        Button {
                            s.removeMask(m.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(WorkspaceButtonStyle())
                        .controlSize(.mini)
                        .help("删除蒙版").accessibilityLabel("删除蒙版")
                    }
                    if s.selectedMask == m.id {
                        HStack {
                            Button("重命名…") { renameID = m.id; renameText = m.name; renaming = true }
                            Spacer()
                            Button("复位调整") { var x = m; x.adjust = LocalAdjust(); s.updateMask(x) }
                        }.font(.system(size:10)).buttonStyle(WorkspaceButtonStyle())
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
                                set: { var x = m; x.tolerance = $0; s.updateMaskLive(x) }), range: 0.02...0.8, defaultValue:Mask().tolerance) { s.endEdit() }
                        }
                        if m.kind == .luminanceRange {
                            SliderRow(label: "下限", value: Binding(
                                get: { m.lumLow },
                                set: { var x = m; x.lumLow = min($0, x.lumHigh); s.updateMaskLive(x) }), range: 0...1, defaultValue:Mask().lumLow) { s.endEdit() }
                            SliderRow(label: "上限", value: Binding(
                                get: { m.lumHigh },
                                set: { var x = m; x.lumHigh = max($0, x.lumLow); s.updateMaskLive(x) }), range: 0...1, defaultValue:Mask().lumHigh) { s.endEdit() }
                            SliderRow(label: "软边", value: Binding(
                                get: { m.lumSoft },
                                set: { var x = m; x.lumSoft = $0; s.updateMaskLive(x) }), range: 0.01...0.5, defaultValue:Mask().lumSoft) { s.endEdit() }
                        }
                        if (m.kind == .brush || m.kind == .depth) && s.maskTool == .position {
                            SliderRow(label: "笔刷", value: Binding(
                                get: { m.strokes.last?.radius ?? 0.05 },
                                set: { var x = m; if !x.strokes.isEmpty { x.strokes[x.strokes.count - 1].radius = $0 } else { x.strokes.append(Stroke(pts: [], radius: $0, feather: x.feather)) }; s.updateMaskLive(x) }),
                                range: 0.005...0.3, defaultValue:0.05) { s.endEdit() }
                        }
                        if m.kind == .radial {
                            SliderRow(label: "横半径", value: Binding(
                                get: { m.radiusX ?? m.radius },
                                set: { var x = MaskGeometry.ellipse(m); x.radiusX = $0; s.updateMaskLive(x) }), range: 0.05...1.5, defaultValue:Mask().radius) { s.endEdit() }
                            SliderRow(label: "纵半径", value: Binding(
                                get: { m.radiusY ?? m.radius },
                                set: { var x = MaskGeometry.ellipse(m); x.radiusY = $0; s.updateMaskLive(x) }), range: 0.05...1.5, defaultValue:Mask().radius) { s.endEdit() }
                            SliderRow(label: "旋转", value: Binding(
                                get: { m.radialAngle },
                                set: { var x = MaskGeometry.ellipse(m); x.radialAngle = $0; s.updateMaskLive(x) }), range: -180...180) { s.endEdit() }
                        }
                        SliderRow(label: "蒙版羽化", value: Binding(
                            get: { m.feather },
                            set: { var x = m; x.feather = $0; s.updateMaskLive(x) }), range: 0...1, defaultValue:Mask().feather) { s.endEdit() }
                        if m.kind != .depth {
                            Divider()
                            SliderRow(label: "曝光", value: Binding(
                                get: { m.adjust.exposure },
                                set: { var x = m; x.adjust.exposure = $0; s.updateMaskLive(x) }), range: -4...4) { s.endEdit() }
                            SliderRow(label: "对比", value: Binding(
                                get: { m.adjust.contrast },
                                set: { var x = m; x.adjust.contrast = $0; s.updateMaskLive(x) }),
                                response: contrastResponse) { s.endEdit() }
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
                        .fill(isSel ? WorkspaceTokens.accent.opacity(0.09)
                               : Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSel ? WorkspaceTokens.accent.opacity(0.4)
                            : Color(nsColor: .rfCardBorder), lineWidth: isSel ? 1 : 0.5))
            }
        }
        .alert("重命名蒙版",isPresented:$renaming) {
            TextField("蒙版名称",text:$renameText)
            Button("取消",role:.cancel) {}
            Button("保存") { if let id = renameID { s.renameMask(id,name:renameText) } }
                .disabled(renameText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
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
            SliderRow(label: "边距", value: $settings.watermarkMargin, range: 0...0.12, photoScoped:false)
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
                                .fill(pos == p ? WorkspaceTokens.accent : Color.secondary.opacity(0.22))
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
            .buttonStyle(WorkspaceButtonStyle())
            .help("在访达中显示")
        }
    }
}

