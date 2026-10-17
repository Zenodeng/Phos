import AppKit
import SwiftUI
import Combine
import CoreImage
import ImageIO

@MainActor
final class VisualLabModel: ObservableObject {
    @Published var theme = "system"
    @Published var surface = WorkspaceSurfaceMode.native
    @Published var category = "明暗"
    @Published var browserVisible = true
    @Published var showComponents = false
    @Published var inputResetGeneration: UInt = 0
}

struct LabEnvironmentContent<Content:View>: View {
    @ObservedObject var environment: WorkspaceEnvironment
    let content: Content
    var body: some View {
        content.foregroundStyle(WorkspaceTokens.primaryText).tint(WorkspaceTokens.accent)
            .environment(\.workspaceAccessibility,environment.accessibility)
    }
}

struct LabBridgedPanel<Content:View>: View {
    @ObservedObject var model: VisualLabModel
    @ObservedObject var environment: WorkspaceEnvironment
    let activity: WorkspaceMaterialActivity
    let content: Content
    var body: some View {
        ZStack {
            WorkspaceMaterialBackdrop(mode:model.surface,accessibility:environment.accessibility,activity:activity)
                .id(model.surface.rawValue+String(environment.accessibility.reduceTransparency)+String(environment.accessibility.increaseContrast))
            content
        }.clipShape(RoundedRectangle(cornerRadius:WorkspaceTokens.panelRadius))
    }
}

private let fixtureTitles = ["00":"山湖与夕阳","01":"月亮 · 竖幅","02":"林间 · RAW","03":"亮背景","04":"暗背景","05":"沙丘纹理","06":"长文件名","07":"像素棋盘","08":"走廊 · HIF"]
private func fixtureTitle(_ name:String) -> String { fixtureTitles[String(name.prefix(2))] ?? name }

struct VisualLabBrowser: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing:0) {
            HStack { Text("照片").font(.system(size:15,weight:.semibold)); Spacer(); Image(systemName:"photo.stack").symbolRenderingMode(.hierarchical).foregroundStyle(WorkspaceTokens.secondaryText) }
                .padding(.horizontal,16).padding(.top,18)
            HStack { Text("视觉样板素材"); Spacer(); Text("\(state.items.count) 张").monospacedDigit() }.font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText).padding(.horizontal,16).padding(.top,4).padding(.bottom,14)
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing:4) {
                    ForEach(Array(state.items.enumerated()),id:\.element.id) { index,item in
                        Button { state.select(index) } label: {
                            HStack(spacing:12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius:7).fill(Color.primary.opacity(0.07))
                                    if let thumb = item.thumb { Image(decorative:thumb,scale:1).resizable().aspectRatio(contentMode:.fit).padding(2) }
                                }.frame(width:56,height:56).clipShape(RoundedRectangle(cornerRadius:7))
                                VStack(alignment:.leading,spacing:5) {
                                    Text(fixtureTitle(item.url.lastPathComponent)).font(.system(size:12,weight:index == state.currentIndex ? .medium : .regular)).foregroundStyle(WorkspaceTokens.primaryText)
                                    Text(item.url.lastPathComponent).font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth:.infinity,alignment:.leading)
                            }.padding(8).background(RoundedRectangle(cornerRadius:10).fill(index == state.currentIndex ? Color.accentColor.opacity(0.14) : .clear))
                                .overlay(RoundedRectangle(cornerRadius:10).stroke(index == state.currentIndex ? Color.accentColor.opacity(0.25) : .clear,lineWidth:0.5))
                        }.buttonStyle(.plain).help(item.url.lastPathComponent).accessibilityLabel("选择"+item.url.lastPathComponent)
                        HStack(spacing:4) {
                            Button { if state.selectedPhotos.contains(item.id) { state.selectedPhotos.remove(item.id) } else { state.selectedPhotos.insert(item.id) } } label: {
                                Image(systemName:state.selectedPhotos.contains(item.id) ? "checkmark.square.fill" : "square").symbolRenderingMode(.hierarchical)
                            }.accessibilityLabel("多选"+item.url.lastPathComponent)
                            Spacer(minLength:2)
                            ForEach(1...5,id:\.self) { rating in
                                Button { if state.currentIndex != index { state.select(index) }; if state.currentIndex == index { state.setRating(item.rating == rating ? 0 : rating) } } label: {
                                    Image(systemName:rating <= item.rating ? "star.fill" : "star").symbolRenderingMode(.hierarchical).font(.system(size:9))
                                }.frame(width:18,height:24).accessibilityLabel(item.url.lastPathComponent+"评分\(rating)星")
                            }
                            Button { if state.currentIndex != index { state.select(index) }; if state.currentIndex == index { state.togglePick() } } label: {
                                Image(systemName:item.picked ? "flag.fill" : "flag").symbolRenderingMode(.hierarchical)
                            }.accessibilityLabel("标记"+item.url.lastPathComponent)
                        }.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText).padding(.horizontal,8)
                    }
                }.padding(8)
            }
            Divider().opacity(0.35)
            HStack(spacing:6) { Image(systemName:"photo").symbolRenderingMode(.hierarchical); Text("\(state.currentIndex+1) / \(state.items.count)").monospacedDigit(); Spacer(); Text(state.selectedPhotos.isEmpty ? (state.current?.url.pathExtension.uppercased() ?? "") : "已选 \(state.selectedPhotos.count)") }
                .font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText).padding(14)
        }
    }
}

struct VisualLabHistogram: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing:8) {
            HStack { Text("直方图").font(.system(size:11)); Spacer(); HStack(spacing:3) { ForEach([Color.red,.green,.blue],id:\.self) { color in Circle().fill(color.opacity(0.65)).frame(width:3,height:3) } }; Text("RGB").font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText) }
            Canvas { context,size in
                let lists = [state.hist.r,state.hist.g,state.hist.b]
                let colors:[Color] = [.red,.green,.blue]
                let peak = Double(lists.flatMap{$0}.max() ?? 1)
                for (index,bins) in lists.enumerated() where !bins.isEmpty {
                    var line = Path()
                    for (i,v) in bins.enumerated() {
                        let point = CGPoint(x:CGFloat(i)/CGFloat(max(1,bins.count-1))*size.width,y:size.height-CGFloat(Double(v)/max(1,peak))*size.height)
                        if i == 0 { line.move(to:point) } else { line.addLine(to:point) }
                    }
                    context.stroke(line,with:.color(colors[index].opacity(0.55)),lineWidth:1)
                }
                var grid = Path(); grid.move(to:CGPoint(x:0,y:size.height)); grid.addLine(to:CGPoint(x:size.width,y:size.height))
                context.stroke(grid,with:.color(.primary.opacity(0.12)),lineWidth:0.5)
            }.frame(height:64)
        }.padding(12).background(RoundedRectangle(cornerRadius:10).fill(WorkspaceTokens.chartColor))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(WorkspaceTokens.hairline,lineWidth:0.5))
    }
}

struct VisualLabInspector: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: VisualLabModel
    func binding(_ path:WritableKeyPath<EditParams,Double>) -> Binding<Double> { Binding(get:{state.params[keyPath:path]},set:{state.set(path,$0)}) }
    func row(_ name:String,_ path:WritableKeyPath<EditParams,Double>,range:ClosedRange<Double> = -100...100,decimals:Int = 0) -> some View {
        WorkspaceParameterRow(label:name,value:binding(path),range:range,decimals:decimals,onCommit:{state.endEdit()})
    }
    func reset(_ paths:[WritableKeyPath<EditParams,Double>]) {
        var p = state.params; for key in paths { p[keyPath:key] = EditParams()[keyPath:key] }; state.commit(p)
    }
    var body: some View {
        VStack(spacing:0) {
            HStack { VStack(alignment:.leading,spacing:4) { Text("调整").font(.system(size:15,weight:.semibold)); Text(model.category).font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText) }; Spacer(); WorkspaceIconButton(symbol:"arrow.counterclockwise",title:"恢复所有调整",disabled:state.params == EditParams()) { model.inputResetGeneration &+= 1; state.commit(EditParams()) } }
                .padding(.horizontal,16).padding(.top,12).padding(.bottom,10)
            Divider().opacity(0.35)
            ScrollView {
                VStack(spacing:4) {
                    VisualLabHistogram(state:state).padding(.top,12).padding(.bottom,8)
                    if model.category == "明暗" {
                        WorkspaceAdjustmentGroup(title:"白平衡",modified:state.params.temperature != 0 || state.params.tint != 0,expanded:false,reset:{reset([\.temperature,\.tint])}) { row("色温偏移",\.temperature); row("色调",\.tint) }
                        Divider().opacity(0.35)
                        WorkspaceAdjustmentGroup(title:"基本",modified:state.params.exposure != 0 || state.params.contrast != 0 || state.params.highlights != 0 || state.params.shadows != 0 || state.params.whites != 0 || state.params.blacks != 0,reset:{reset([\.exposure,\.contrast,\.highlights,\.shadows,\.whites,\.blacks])}) {
                            row("曝光 · EV",\.exposure,range:-5...5,decimals:2)
                            row("对比",\.contrast)
                            row("高光",\.highlights)
                            row("阴影",\.shadows)
                            row("白色",\.whites)
                            row("黑色",\.blacks)
                        }
                        Divider().opacity(0.35)
                        WorkspaceAdjustmentGroup(title:"质感与饱和度",modified:state.params.texture != 0 || state.params.clarity != 0 || state.params.dehaze != 0 || state.params.vibrance != 0 || state.params.saturation != 0,expanded:false,reset:{reset([\.texture,\.clarity,\.dehaze,\.vibrance,\.saturation])}) {
                            row("纹理",\.texture); row("清晰度",\.clarity,range:0...100); row("去朦胧",\.dehaze); row("鲜艳度",\.vibrance); row("饱和度",\.saturation)
                        }
                    } else if model.category == "色彩" {
                        WorkspaceAdjustmentGroup(title:"白平衡",modified:state.params.temperature != 0 || state.params.tint != 0,reset:{reset([\.temperature,\.tint])}) { row("色温偏移",\.temperature); row("色调",\.tint) }
                        Divider().opacity(0.35)
                        WorkspaceAdjustmentGroup(title:"色彩",modified:state.params.vibrance != 0 || state.params.saturation != 0,reset:{reset([\.vibrance,\.saturation])}) { row("鲜艳度",\.vibrance); row("饱和度",\.saturation) }
                    } else {
                        WorkspaceAdjustmentGroup(title:"质感",modified:state.params.texture != 0 || state.params.clarity != 0 || state.params.dehaze != 0,reset:{reset([\.texture,\.clarity,\.dehaze])}) { row("纹理",\.texture); row("清晰度",\.clarity,range:0...100); row("去朦胧",\.dehaze) }
                    }
                }.padding(.horizontal,16).padding(.bottom,16)
            }
            Divider().opacity(0.35)
            HStack { Text("\(Int(state.sourceSize.width)) × \(Int(state.sourceSize.height))").monospacedDigit(); Spacer(); Text("sRGB") }
                .font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText).padding(14)
        }.environment(\.workspaceInputResetGeneration,model.inputResetGeneration)
    }
}

struct VisualLabTools: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: VisualLabModel
    var body: some View {
        HStack(spacing:2) {
            WorkspaceIconButton(symbol:"sidebar.left",title:"显示或隐藏照片",selected:model.browserVisible) { model.browserVisible.toggle() }
            Divider().frame(height:16).padding(.horizontal,4)
            WorkspaceIconButton(symbol:"arrow.uturn.backward",title:"撤销",disabled:!state.history.canUndo) { state.undo() }
            WorkspaceIconButton(symbol:"arrow.uturn.forward",title:"重做",disabled:!state.history.canRedo) { state.redo() }
        }.padding(4)
    }
}

struct VisualLabActions: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: VisualLabModel
    var body: some View {
        HStack(spacing:8) {
            Button { state.showBefore.toggle() } label: { Label(state.showBefore ? "原图" : "调整",systemImage:"square.lefthalf.filled").font(.system(size:12,weight:.medium)) }.buttonStyle(WorkspaceButtonStyle(selected:state.showBefore)).help("前后对比")
            Divider().frame(height:16)
            Menu {
                Button("跟随系统") { model.theme = "system" }
                Button("浅色") { model.theme = "light" }
                Button("深色") { model.theme = "dark" }
                Divider()
                Button("原生材质") { model.surface = .native }
                Button("兼容磨砂") { model.surface = .fallback }
                Button("实色表面") { model.surface = .solid }
                Divider()
                Button("组件样板") { model.showComponents = true }
            } label: { Image(systemName:"circle.lefthalf.filled").symbolRenderingMode(.hierarchical).frame(width:24,height:24) }.menuStyle(.borderlessButton).fixedSize().help("外观与表面")
        }.padding(8)
            .sheet(isPresented:$model.showComponents) { WorkspaceComponentGallery(state:state) }
    }
}

struct VisualLabCategoryRail: View {
    @ObservedObject var model: VisualLabModel
    var body: some View {
        VStack(spacing:4) {
            ForEach(Array(zip(["明暗","色彩","细节"],["sun.max","paintpalette","circle.lefthalf.filled"])),id:\.0) { name,symbol in
                WorkspaceIconButton(symbol:symbol,title:name,selected:model.category == name) { model.category = name }
            }
        }.padding(4)
    }
}

@MainActor
final class LabTransparentHost<Content:View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor
final class LabGlassGroupContent: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point:NSPoint) -> NSView? { let view = super.hitTest(point); return view === self ? nil : view }
}

@MainActor
final class LabLabelPlate: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect:NSRect) {
        let dark = effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        NSColor(white:dark ? 0.08 : 0.98,alpha:0.82).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill()
    }
}

@MainActor
final class LabPhotoView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var cover = false
    var dim: CGFloat = 0
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect:NSRect) {
        guard let image else { return }
        let size = image.size
        let scale = cover ? max(bounds.width/size.width,bounds.height/size.height) : min(bounds.width/size.width,bounds.height/size.height)
        let target = CGRect(x:(bounds.width-size.width*scale)/2,y:(bounds.height-size.height*scale)/2,width:size.width*scale,height:size.height*scale)
        image.draw(in:target,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high.rawValue])
        if dim > 0 { NSColor.black.withAlphaComponent(dim).setFill(); bounds.fill() }
    }
}

@MainActor
final class LabRootView: NSView {
    let state: AppState
    let model: VisualLabModel
    let environment: WorkspaceEnvironment
    let carrier: String
    let materialActivity: WorkspaceMaterialActivity
    let backdrop = LabPhotoView()
    let photo = LabPhotoView()
    let filename = NSTextField(labelWithString:"")
    let subtitle = NSTextField(labelWithString:"")
    let mark = NSImageView()
    let status = NSTextField(labelWithString:"")
    let titleDrag = WorkspaceTitlebarDragView()
    let titlePlate = LabLabelPlate()
    let statusPlate = LabLabelPlate()
    var glassGroups: NSView!
    var glassContent: LabGlassGroupContent!
    var hosts: [String:NSView] = [:]
    var browser: NSView!
    var inspector: NSView!
    var tools: NSView!
    var actions: NSView!
    var rail: NSView!
    var observations: [AnyCancellable] = []
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    init(state:AppState,model:VisualLabModel,environment:WorkspaceEnvironment,carrier:String = "direct",materialActivity:WorkspaceMaterialActivity = .following) {
        self.state = state; self.model = model
        self.environment = environment; self.carrier = carrier; self.materialActivity = materialActivity
        super.init(frame:.zero)
        backdrop.cover = true; backdrop.dim = 0.24
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        backdrop.wantsLayer = true
        addSubview(backdrop); addSubview(photo); addSubview(titleDrag); addSubview(titlePlate); addSubview(statusPlate)
        photo.wantsLayer = true; photo.layer?.cornerRadius = 4; photo.layer?.masksToBounds = true
        filename.font = .systemFont(ofSize:12,weight:.medium); filename.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize:11); subtitle.textColor = .secondaryLabelColor
        status.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); status.textColor = .secondaryLabelColor
        for view in [filename,subtitle,status,mark] { addSubview(view) }
        rebuildSurfaces()
        state.objectWillChange.receive(on:RunLoop.main).sink { [weak self] in self?.refresh() }.store(in:&observations)
        model.objectWillChange.receive(on:RunLoop.main).sink { [weak self] in
            guard let self else { return }; self.applyAppearance(); self.needsLayout = true
            self.refresh()
        }.store(in:&observations)
        model.$surface.dropFirst().receive(on:RunLoop.main).sink { [weak self] _ in self?.rebuildSurfaces() }.store(in:&observations)
        environment.objectWillChange.receive(on:RunLoop.main).sink { [weak self] in
            self?.rebuildSurfaces(); self?.applyAppearance()
        }.store(in:&observations)
        for name in [NSWindow.didEnterFullScreenNotification,NSWindow.didExitFullScreenNotification,NSWindow.didResizeNotification] {
            NotificationCenter.default.publisher(for:name).receive(on:RunLoop.main).sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.window else { return }
                self.needsLayout = true
            }.store(in:&observations)
        }
        NotificationCenter.default.publisher(for:NSWindow.didUpdateNotification).receive(on:RunLoop.main).sink { [weak self] note in
            guard let self,let window = note.object as? NSWindow,window === self.window else { return }
            WorkspaceWindowChrome.positionStandardButtons(in:self)
        }.store(in:&observations)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    func host<V:View>(_ view:V, id:String) -> NSView {
        if let existing = hosts[id] { return existing }
        let host = LabTransparentHost(rootView:LabEnvironmentContent(environment:environment,content:view.background(Color.clear)))
        // AppKit already positions each surface within the full-size window.
        // Inheriting its titlebar safe area shifts the top controls below their glass.
        host.safeAreaRegions = []
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        hosts[id] = host
        return host
    }
    func rebuildSurfaces() {
        [browser,inspector,glassGroups].compactMap{$0}.forEach{$0.removeFromSuperview()}
        hosts.values.forEach{$0.removeFromSuperview()}
        let options = environment.accessibility
        if carrier == "bridge" {
            browser = host(LabBridgedPanel(model:model,environment:environment,activity:materialActivity,content:VisualLabBrowser(state:state)),id:"browser")
            inspector = host(LabBridgedPanel(model:model,environment:environment,activity:materialActivity,content:VisualLabInspector(state:state,model:model)),id:"inspector")
        } else {
            browser = WorkspacePanelSurface.make(content:host(VisualLabBrowser(state:state),id:"browser"),mode:model.surface,accessibility:options,activity:materialActivity)
            inspector = WorkspacePanelSurface.make(content:host(VisualLabInspector(state:state,model:model),id:"inspector"),mode:model.surface,accessibility:options,activity:materialActivity)
        }
        tools = WorkspaceGlassSurface.make(content:host(VisualLabTools(state:state,model:model),id:"tools"),mode:model.surface,accessibility:options,disableNativeGlass:environment.disableNativeGlass)
        actions = WorkspaceGlassSurface.make(content:host(VisualLabActions(state:state,model:model),id:"actions"),mode:model.surface,accessibility:options,disableNativeGlass:environment.disableNativeGlass)
        rail = WorkspaceGlassSurface.make(content:host(VisualLabCategoryRail(model:model),id:"rail"),radius:22,mode:model.surface,accessibility:options,disableNativeGlass:environment.disableNativeGlass)
        glassContent = LabGlassGroupContent()
        [tools,actions,rail].forEach { glassContent.addSubview($0!) }
        let policy = WorkspaceMaterialPolicy(mode:model.surface,accessibility:options,disableNativeGlass:environment.disableNativeGlass)
        glassGroups = WorkspaceGlassGrouping.make(content:glassContent,enabled:policy.tools == .nativeGlass)
        [glassGroups,browser,inspector].forEach{addSubview($0!)}
        needsLayout = true
    }
    func applyAppearance() {
        let appearance = model.theme == "system" ? nil : NSAppearance(named:model.theme == "dark" ? .darkAqua : .aqua)
        NSApplication.shared.appearance = appearance; window?.appearance = appearance
        let dark = effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        backdrop.dim = dark ? 0.33 : 0.18
        backdrop.isHidden = environment.accessibility.reduceTransparency
        mark.image = NSImage(contentsOf:Bundle.main.url(forResource:dark ? "icon-dark-1024" : "icon-light-1024",withExtension:"png")!)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            filename.textColor = dark ? NSColor(white:0.96,alpha:1) : NSColor(white:0.10,alpha:1)
            subtitle.textColor = dark ? NSColor(white:0.79,alpha:1) : NSColor(white:0.20,alpha:1)
            status.textColor = subtitle.textColor
            layer?.backgroundColor = WorkspaceTokens.panel.cgColor
        }
        backdrop.needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    func refresh() {
        let image = state.showBefore ? state.beforeImage : state.preview
        if let image { let native = NSImage(cgImage:image,size:CGSize(width:image.width,height:image.height)); photo.image = native; backdrop.image = native }
        filename.stringValue = state.current.map{fixtureTitle($0.url.lastPathComponent)} ?? "Phos"
        subtitle.stringValue = state.current?.url.lastPathComponent ?? "正在读取素材"
        subtitle.toolTip = subtitle.stringValue
        status.stringValue = state.items.isEmpty ? state.status : state.previewing ? "正在生成预览…" : state.params == EditParams() ? "照片适配 · 原始调整" : "照片适配 · 已调整"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let topInset = WorkspaceWindowChrome.topInset(in:self)
        backdrop.frame = bounds
        titleDrag.frame = CGRect(x:0,y:topInset,width:width,height:64)
        glassGroups.frame = bounds; glassContent.frame = glassGroups.bounds
        WorkspaceWindowChrome.positionStandardButtons(in:self)
        browser.isHidden = !model.browserVisible
        browser.frame = CGRect(x:16,y:topInset+76,width:224,height:height-topInset-96)
        inspector.frame = CGRect(x:width-376,y:topInset+76,width:304,height:height-topInset-96)
        tools.frame = CGRect(x:88,y:topInset+8,width:136,height:44)
        mark.frame = CGRect(x:240,y:topInset+18,width:24,height:24)
        let infoWidth = min(320,max(120,max(filename.intrinsicContentSize.width,subtitle.intrinsicContentSize.width)+16))
        titlePlate.frame = CGRect(x:268,y:topInset+8,width:min(infoWidth,max(100,width-556)),height:44)
        filename.frame = CGRect(x:276,y:topInset+13,width:titlePlate.frame.width-16,height:19)
        subtitle.frame = CGRect(x:276,y:topInset+32,width:titlePlate.frame.width-16,height:16)
        actions.frame = CGRect(x:width-192,y:topInset+8,width:176,height:44)
        rail.frame = CGRect(x:width-60,y:topInset+84,width:44,height:124)
        let left:CGFloat = model.browserVisible ? 264 : 24
        let area = CGRect(x:left,y:topInset+96,width:width-400-left,height:height-topInset-156)
        let size = photo.image?.size ?? CGSize(width:3,height:2)
        let scale = min(area.width/size.width,area.height/size.height)
        photo.frame = CGRect(x:area.midX-size.width*scale/2,y:area.midY-size.height*scale/2,width:size.width*scale,height:size.height*scale)
        status.frame = CGRect(x:left,y:height-38,width:area.width,height:18)
        statusPlate.frame = CGRect(x:left-8,y:height-44,width:min(status.intrinsicContentSize.width+16,area.width+16),height:30)
    }
    func captureInfo() -> [String:Any] {
        guard let window else { return [:] }
        var visualEffects = 0, glass = 0, groups = 0
        var materialStates: [Int] = []
        func visit(_ view:NSView) {
            if let effect = view as? NSVisualEffectView { visualEffects += 1; materialStates.append(effect.state.rawValue) }
            #if PHOS_NATIVE_GLASS
            if #available(macOS 26.0, *) {
                if view is NSGlassEffectView { glass += 1 }
                if view is NSGlassEffectContainerView { groups += 1 }
            }
            #endif
            view.subviews.forEach(visit)
        }
        visit(self)
        let options = environment.accessibility
        let policy = WorkspaceMaterialPolicy(mode:model.surface,accessibility:options,disableNativeGlass:environment.disableNativeGlass)
        func rect(_ frame:CGRect) -> [String:CGFloat] { ["x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height] }
        func hitClass(_ point:CGPoint) -> String {
            guard let view = hitTest(convert(point,to:superview)) else { return "none" }
            return String(describing:type(of:view))
        }
        return ["bundleID":Bundle.main.bundleIdentifier ?? "","executable":Bundle.main.executablePath ?? "","processID":ProcessInfo.processInfo.processIdentifier,
                "windowID":window.windowNumber,"theme":model.theme,"effectiveAppearance":effectiveAppearance.name.rawValue,
                "surface":model.surface.rawValue,"carrier":carrier,"materialActivity":materialActivity.rawValue,
                "nativeGlassCompiled":WorkspaceMaterialPolicy.nativeGlassCompiled,"panelKind":policy.panel.rawValue,
                "toolsKind":policy.tools.rawValue,
                "visualEffectViewCount":visualEffects,"glassViewCount":glass,"glassContainerCount":groups,"visualEffectStates":materialStates,
                "backingScale":window.backingScaleFactor,"contentPt":["width":window.contentLayoutRect.width,"height":window.contentLayoutRect.height],
                "windowPt":["width":window.frame.width,"height":window.frame.height],"windowFrame":rect(window.frame),
                "photo":state.current?.url.lastPathComponent ?? "","photoRectPt":rect(photo.frame),
                "sourcePixels":["width":state.sourceSize.width,"height":state.sourceSize.height],
                "applicationIsActive":NSApplication.shared.isActive,"windowIsKey":window.isKeyWindow,
                "fullScreen":window.styleMask.contains(.fullScreen),"reduceTransparency":options.reduceTransparency,
                "increaseContrast":options.increaseContrast,"reduceMotion":options.reduceMotion,"backgroundHidden":backdrop.isHidden,
                "accessibilitySource":environment.forcedAccessibility,"selectedPhotos":state.selectedPhotos.count,
                "category":model.category,"previewing":state.previewing,"status":state.status,
                "isMovableByWindowBackground":window.isMovableByWindowBackground,"titleDragMouseDownCount":titleDrag.dragMouseDownCount,"titleDragEventCount":titleDrag.dragEventCount,
                "hitTestClasses":["titleBlank":hitClass(CGPoint(x:600,y:30)),"photo":hitClass(CGPoint(x:photo.frame.midX,y:photo.frame.midY)),"sidebarIcon":hitClass(CGPoint(x:110,y:30))],
                "nativeTitleButtons":[NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].compactMap { kind -> [String:Any]? in
                    guard let button = window.standardWindowButton(kind) else { return nil }
                    return ["type":kind.rawValue,"class":String(describing:type(of:button)),"frame":rect(convert(button.bounds,from:button)),"hidden":button.isHidden]
                }]
    }
}

@MainActor
final class VisualLabWindow: NSWindow {
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class VisualLabApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}

@main
struct WorkspaceVisualLab {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = VisualLabApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        var options:[String:String] = [:]
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count % 2 != 0 { fputs("Expected --option value pairs\n",stderr); exit(2) }
        let known:Set<String> = ["--folder","--theme","--surface","--size","--photo","--capture","--carrier","--material-state","--accessibility","--native-glass","--page","--trace"]
        for i in stride(from:0,to:args.count,by:2) {
            guard known.contains(args[i]),options[args[i]] == nil else { fputs("Unknown or duplicate option\n",stderr); exit(2) }
            options[args[i]] = args[i+1]
        }
        guard ["system","light","dark"].contains(options["--theme"] ?? "system"),WorkspaceSurfaceMode(rawValue:options["--surface"] ?? "native") != nil else { exit(2) }
        guard ["direct","bridge"].contains(options["--carrier"] ?? "direct"),WorkspaceMaterialActivity(rawValue:options["--material-state"] ?? "following") != nil,
              ["system","reduceTransparency","increaseContrast","reduceMotion"].contains(options["--accessibility"] ?? "system"),
              ["auto","disabled"].contains(options["--native-glass"] ?? "auto"),["workspace","components"].contains(options["--page"] ?? "workspace") else { exit(2) }
        if let path = options["--capture"],FileManager.default.fileExists(atPath:path) { fputs("Use a fresh capture path\n",stderr); exit(2) }
        // The self-contained lab reads only its bundled samples and edits disposable copies.
        let folder: String
        if let provided = options["--folder"] { folder = provided }
        else {
            let inputs = Bundle.main.resourceURL!.appendingPathComponent("FixtureInputs")
            let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("PhosVisualLab-"+UUID().uuidString).appendingPathComponent("fixtures")
            let work = fixtures.appendingPathComponent("work")
            do {
                try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
                let catalog = inputs.appendingPathComponent("catalog.json")
                try FileManager.default.copyItem(at:catalog,to:fixtures.appendingPathComponent("catalog.json"))
                let data = try JSONSerialization.jsonObject(with:Data(contentsOf:catalog)) as! [String:Any]
                for item in data["items"] as! [[String:Any]] {
                    let name = item["name"] as! String
                    try FileManager.default.copyItem(at:inputs.appendingPathComponent(name),to:work.appendingPathComponent(name))
                }
                folder = work.path
            } catch { fputs("Cannot prepare bundled fixtures: \(error)\n",stderr); exit(1) }
        }
        let folderURL = URL(fileURLWithPath:folder).resolvingSymlinksInPath()
        guard folderURL.lastPathComponent == "work",folderURL.deletingLastPathComponent().lastPathComponent == "fixtures",
              FileManager.default.fileExists(atPath:folderURL.deletingLastPathComponent().appendingPathComponent("catalog.json").path) else { fputs("Only catalogued fixtures/work can be opened\n",stderr); exit(2) }
        let state = AppState(); let model = VisualLabModel()
        let environment = WorkspaceEnvironment(forcedAccessibility:options["--accessibility"] ?? "system",forceFallback:options["--native-glass"] == "disabled")
        model.theme = options["--theme"] ?? "system"
        model.surface = WorkspaceSurfaceMode(rawValue:options["--surface"] ?? "native") ?? .native
        let parts = (options["--size"] ?? "1440x820").split(separator:"x").compactMap{Double($0)}
        guard parts.count == 2,parts[0] >= 1100,parts[1] >= 700,parts[0] <= 4096,parts[1] <= 2160 else { exit(2) }
        let window = VisualLabWindow(contentRect:CGRect(x:24,y:55,width:parts[0],height:parts[1]+32),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "Phos · 视觉样板"
        WorkspaceWindowChrome.configure(window)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.minSize = CGSize(width:1100,height:732)
        let root = LabRootView(state:state,model:model,environment:environment,carrier:options["--carrier"] ?? "direct",materialActivity:WorkspaceMaterialActivity(rawValue:options["--material-state"] ?? "following")!); window.contentView = root
        root.applyAppearance(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
        let icon = SystemAppIcon(); icon?.start(application:app)
        let menu = NSMenu(); let main = NSMenuItem(); menu.addItem(main)
        let submenu = NSMenu(); submenu.addItem(withTitle:"退出视觉样板",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); main.submenu = submenu
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title:"编辑")
        for (title,selector,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("拷贝",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:selector,keyEquivalent:key) }; editItem.submenu = edit
        let viewItem = NSMenuItem(); menu.addItem(viewItem); let viewMenu = NSMenu(title:"显示")
        let fullScreenItem = NSMenuItem(title:"切换全屏",action:#selector(NSWindow.toggleFullScreen(_:)),keyEquivalent:"f")
        fullScreenItem.keyEquivalentModifierMask = [.command,.control]; fullScreenItem.target = window
        viewMenu.addItem(fullScreenItem); viewItem.submenu = viewMenu
        app.mainMenu = menu
        state.openFolder(folderURL)
        var traceTimer: AnyCancellable?
        if let path = options["--trace"] {
            traceTimer = Timer.publish(every:0.3,on:.main,in:.common).autoconnect().sink { _ in
                if let data = try? JSONSerialization.data(withJSONObject:root.captureInfo(),options:[.prettyPrinted,.sortedKeys]) {
                    try? data.write(to:URL(fileURLWithPath:path),options:.atomic)
                }
            }
        }
        Task { @MainActor in
            let deadline = ProcessInfo.processInfo.systemUptime+90
            while state.preview == nil || state.previewing || state.items.contains(where:{$0.thumb == nil}) {
                if ProcessInfo.processInfo.systemUptime > deadline { fputs("Preview timed out\n",stderr); exit(1) }
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            if let name = options["--photo"],let index = state.items.firstIndex(where:{$0.url.lastPathComponent == name}) {
                state.select(index)
                while state.preview == nil || state.previewing { try? await Task.sleep(nanoseconds:10_000_000) }
            }
            root.refresh(); root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true); window.makeFirstResponder(root)
            if options["--page"] == "components" { model.showComponents = true }
            try? await Task.sleep(nanoseconds:500_000_000)
            if let capture = options["--capture"] {
                let expectedPhoto = state.current?.id; let expectedParams = state.params
                window.ignoresMouseEvents = true
                // Fixed captures cannot be interacted with; state tests retain the full AX tree.
                if options["--page"] != "components" { root.setAccessibilityChildren([]) }
                let info = root.captureInfo()
                let url = URL(fileURLWithPath:capture)
                try? JSONSerialization.data(withJSONObject:info,options:[.prettyPrinted,.sortedKeys]).write(to:url.appendingPathExtension("ready.json"),options:.atomic)
                print("READY "+capture); fflush(stdout)
                while !FileManager.default.fileExists(atPath:capture) { try? await Task.sleep(nanoseconds:50_000_000) }
                guard state.current?.id == expectedPhoto,state.params == expectedParams else { fputs("Capture state changed\n",stderr); exit(1) }
                if let source = CGImageSourceCreateWithURL(url as CFURL,nil),let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] {
                    var final = info; final["imagePixels"] = ["width":props[kCGImagePropertyPixelWidth as String] ?? 0,"height":props[kCGImagePropertyPixelHeight as String] ?? 0]
                    try? JSONSerialization.data(withJSONObject:final,options:[.prettyPrinted,.sortedKeys]).write(to:url.appendingPathExtension("json"))
                    if let sheet = window.attachedSheet { app.endSheet(sheet); sheet.orderOut(nil) }
                    app.terminate(nil)
                }
            }
        }
        withExtendedLifetime((window,root,icon,traceTimer,environment,delegate)) { app.run() }
    }
}
