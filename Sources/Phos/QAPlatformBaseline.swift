import AppKit
import Combine

#if PHOS_QA
@MainActor
private final class QAPlatformRoot: NSView {
    var resized: (() -> Void)?
    var backgroundClicks = 0
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); resized?() }
    override func mouseDown(with event: NSEvent) { backgroundClicks += 1 }
}

@MainActor
private final class QAPlatformImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class QAPlatformPassthrough: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point:NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === self ? nil:target
    }
}

/// An opt-in QA window inside the real App process. Never part of the shipping editor.
@MainActor
final class QAPlatformBaselineController: NSObject {
    static let shared = QAPlatformBaselineController()
    private weak var delegate: PhosAppDelegate?
    private var window: NSWindow?
    private let root = QAPlatformRoot()
    private let image = QAPlatformImage()
    private let titleStrip = WorkspaceTitlebarDragView()
    private let toolsContent = NSStackView()
    private let panelContent = NSStackView()
    private let draft = NSTextField(string:"保留这段草稿")
    private var tools: NSView?
    private var panel: NSView?
    private var grouping: NSView?
    private var environment = WorkspaceEnvironment()
    private var mode = WorkspaceSurfaceMode.native
    private var appearancePicker: NSSegmentedControl!
    private var materialPicker: NSSegmentedControl!
    private var emergency: NSButton!
    private var observations: [AnyCancellable] = []
    private var timer: Timer?
    private var materialKey = ""
    private var lastState = Data()
    private var sequence = 0
    private var toolClicks = 0
    private var windowEvents: [String:Int] = [:]

    func start(delegate: PhosAppDelegate) {
        self.delegate = delegate
        timer = Timer.scheduledTimer(timeInterval:0.5,target:self,selector:#selector(record),userInfo:nil,repeats:true)
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect:NSRect(x:160,y:140,width:1000,height:650),
                              styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "R1-B 平台基线检查"
        window.minSize = NSSize(width:850,height:600)
        window.isReleasedWhenClosed = false
        WorkspaceWindowChrome.configure(window)
        self.window = window
        window.contentView = root
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        image.image = NSImage(contentsOf:QAWorkspace.fixtureFolder.appendingPathComponent("00-landscape-lake.jpg"))
        image.imageScaling = .scaleAxesIndependently
        root.addSubview(image)
        root.addSubview(titleStrip)
        let tool = NSButton(title:"工具点击",target:self,action:#selector(toolClicked))
        tool.bezelStyle = .rounded
        draft.placeholderString = "材料变化不丢草稿"
        draft.setAccessibilityLabel("材料检查草稿")
        toolsContent.orientation = .horizontal
        toolsContent.spacing = 16
        toolsContent.edgeInsets = NSEdgeInsets(top:16,left:16,bottom:16,right:16)
        toolsContent.addArrangedSubview(tool)
        toolsContent.addArrangedSubview(draft)
        draft.widthAnchor.constraint(equalToConstant:230).isActive = true
        panelContent.orientation = .vertical
        panelContent.edgeInsets = NSEdgeInsets(top:20,left:16,bottom:20,right:16)
        panelContent.addArrangedSubview(NSTextField(labelWithString:"中性 matte 参数载体"))
        panelContent.addArrangedSubview(NSTextField(labelWithString:"R1-B 平台检查 · 非最终工作区"))
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 12
        appearancePicker = NSSegmentedControl(labels:["跟随系统","浅色","深色"],trackingMode:.selectOne,target:self,action:#selector(appearanceChanged))
        appearancePicker.setAccessibilityLabel("外观来源")
        materialPicker = NSSegmentedControl(labels:["原生","matte","solid"],trackingMode:.selectOne,target:self,action:#selector(materialChanged))
        materialPicker.setAccessibilityLabel("材料模式")
        materialPicker.selectedSegment = 0
        emergency = NSButton(checkboxWithTitle:"应急关闭原生玻璃",target:self,action:#selector(emergencyChanged))
        for view in [appearancePicker!,materialPicker!,emergency!] as [NSView] { controls.addArrangedSubview(view) }
        controls.frame = NSRect(x:32,y:460,width:500,height:140)
        controls.autoresizingMask = [.maxYMargin]
        root.addSubview(controls)
        root.resized = { [weak self] in self?.layout() }
        for name in [NSWindow.didMoveNotification,NSWindow.didResizeNotification,NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification,NSWindow.willEnterFullScreenNotification,NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification,NSWindow.didExitFullScreenNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeScreenNotification,NSWindow.didChangeBackingPropertiesNotification] {
            NotificationCenter.default.publisher(for:name,object:window).sink { [weak self] notification in
                self?.windowEvents[notification.name.rawValue,default:0] += 1
            }.store(in:&observations)
        }
        refreshMaterials()
        layout()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    @objc private func toolClicked() { toolClicks += 1 }
    @objc private func materialChanged() { mode = [.native,.fallback,.solid][materialPicker.selectedSegment]; refreshMaterials() }
    @objc private func appearanceChanged() {
        UserDefaults.standard.set(["system","light","dark"][appearancePicker.selectedSegment],forKey:"rf.appearance")
    }
    @objc private func emergencyChanged() {
        UserDefaults.standard.set(emergency.state == .on,forKey:"phos.ui.disableNativeGlass")
        environment.refresh()
        refreshMaterials()
    }

    private func refreshMaterials() {
        environment.refresh()
        let a = environment.accessibility
        let key = "\(mode.rawValue)/\(a)/\(environment.disableNativeGlass)"
        guard key != materialKey else { return }
        materialKey = key
        let focused = window?.firstResponder
        let editingDraft = (focused as? NSTextView)?.delegate as AnyObject? === draft
        toolsContent.removeFromSuperview()
        panelContent.removeFromSuperview()
        grouping?.removeFromSuperview()
        panel?.removeFromSuperview()
        toolsContent.translatesAutoresizingMaskIntoConstraints = true
        let policy = WorkspaceMaterialPolicy(mode:mode,accessibility:a,disableNativeGlass:environment.disableNativeGlass)
        let tool = WorkspaceGlassSurface.make(content:toolsContent,mode:mode,accessibility:a,disableNativeGlass:environment.disableNativeGlass)
        let content = QAPlatformPassthrough()
        content.addSubview(tool)
        let group = WorkspaceGlassGrouping.make(content:content,enabled:policy.tools == .nativeGlass)
        root.addSubview(group,positioned:.above,relativeTo:image)
        let panel = WorkspacePanelSurface.make(content:panelContent,mode:mode,accessibility:a)
        root.addSubview(panel,positioned:.above,relativeTo:group)
        self.tools = tool
        self.grouping = group
        self.panel = panel
        layout()
        if editingDraft { window?.makeFirstResponder(draft) }
    }

    private func layout() {
        let inset = WorkspaceWindowChrome.topInset(in:root)
        image.frame = root.bounds
        titleStrip.frame = NSRect(x:80,y:inset,width:max(0,root.bounds.width-100),height:60)
        grouping?.frame = root.bounds
        tools?.frame = NSRect(x:32,y:inset+90,width:max(480,root.bounds.width-350),height:76)
        panel?.frame = NSRect(x:root.bounds.width-292,y:inset+90,width:260,height:260)
        WorkspaceWindowChrome.positionStandardButtons(in:root)
    }

    private func count(_ view:NSView, _ match:(NSView)->Bool) -> Int {
        (match(view) ? 1:0) + view.subviews.reduce(0) { $0 + count($1,match) }
    }

    @objc private func record() {
        refreshMaterialsIfOpen()
        var data: [String:Any] = ["hostOS":ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleID":Bundle.main.bundleIdentifier ?? "", "appearancePreference":UserDefaults.standard.string(forKey:"rf.appearance") ?? "system",
            "applicationAppearance":NSApp.effectiveAppearance.name.rawValue,
            "applicationOverride":NSApp.appearance?.name.rawValue ?? "system",
            "iconVariant":delegate?.systemIcon?.currentVariant ?? "unresolved",
            "windows":NSApp.windows.filter { $0.isVisible }.map { ["title":$0.title,"frame":NSStringFromRect($0.frame),
                "appearance":$0.contentView?.effectiveAppearance.name.rawValue ?? "", "key":$0.isKeyWindow] as [String:Any] }]
        if let window {
            let a = environment.accessibility
            let policy = WorkspaceMaterialPolicy(mode:mode,accessibility:a,disableNativeGlass:environment.disableNativeGlass)
            data["platformWindow"] = ["visible":window.isVisible,"miniaturized":window.isMiniaturized,"key":window.isKeyWindow,
                "frame":NSStringFromRect(window.frame),"fullScreen":window.styleMask.contains(.fullScreen),"topInset":WorkspaceWindowChrome.topInset(in:root),
                "mode":mode.rawValue,"toolsKind":policy.tools.rawValue,"panelKind":policy.panel.rawValue,
                "glassCount":count(root) { $0 is NSGlassEffectView },"groupCount":count(root) { $0 is NSGlassEffectContainerView },
                "visualEffectCount":count(root) { $0 is NSVisualEffectView },
                "reduceTransparency":a.reduceTransparency,"increaseContrast":a.increaseContrast,"reduceMotion":a.reduceMotion,
                "emergencyDisabled":environment.disableNativeGlass,"draft":draft.stringValue,
                "contentIdentity":String(describing:ObjectIdentifier(toolsContent)),"toolClicks":toolClicks,
                "backgroundClicks":root.backgroundClicks,"titleMouseDowns":titleStrip.dragMouseDownCount,
                "nativeDragRequests":titleStrip.nativeDragRequestCount,"continuedDragEvents":titleStrip.dragEventCount,
                "firstResponder":window.firstResponder.map { String(describing:type(of:$0)) } ?? "none",
                "windowEvents":windowEvents]
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]),encoded != lastState else { return }
        lastState = encoded
        sequence += 1
        data["sequence"] = sequence
        data["timestamp"] = ISO8601DateFormatter().string(from:Date())
        let folder = QAWorkspace.root.appendingPathComponent("reports")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        if let json = try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]) {
            try? json.write(to:folder.appendingPathComponent("platform-current.json"),options:.atomic)
            try? json.write(to:folder.appendingPathComponent(String(format:"platform-%04d.json",sequence)),options:.atomic)
        }
    }
    private func refreshMaterialsIfOpen() {
        guard window != nil else { return }
        let preference = UserDefaults.standard.string(forKey:"rf.appearance") ?? "system"
        appearancePicker.selectedSegment = ["system","light","dark"].firstIndex(of:preference) ?? 0
        emergency.state = UserDefaults.standard.bool(forKey:"phos.ui.disableNativeGlass") ? .on:.off
        refreshMaterials()
    }
}
#endif
