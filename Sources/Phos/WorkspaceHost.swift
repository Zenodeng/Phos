import AppKit
import SwiftUI
import Combine

struct WorkspaceHost: NSViewRepresentable {
    let model: WorkspaceWindowModel
    func makeNSView(context: Context) -> WorkspaceRootView { WorkspaceRootView(model: model) }
    func updateNSView(_ view: WorkspaceRootView, context: Context) {}
}

private final class WorkspaceTransparentHost<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

private struct WorkspaceHostedContent<Content: View>: View {
    @ObservedObject var state: AppState
    @ObservedObject var environment: WorkspaceEnvironment
    let content: Content
    var blocksDuringSync = true
    var body: some View {
        content.environmentObject(state).tint(WorkspaceTokens.accent)
            .environment(\.workspaceAccessibility, environment.accessibility)
            .disabled(blocksDuringSync && state.syncRunning)
    }
}

/// The content never leaves this slot, even when its material or visibility changes.
@MainActor
final class WorkspaceSurfaceSlot: NSView {
    let content: NSView
    let tools: Bool
    private var carrier: NSView?
    private var signature = ""
    private(set) var displayed = true
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(content: NSView, tools: Bool) {
        self.content = content; self.tools = tools
        super.init(frame: .zero)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func refresh(environment: WorkspaceEnvironment) {
        let options = environment.accessibility
        let next = "\(options.reduceTransparency)-\(options.increaseContrast)-\(environment.disableNativeGlass)"
        guard next != signature else { return }
        signature = next
        carrier?.removeFromSuperview()
        let empty = NSView()
        let surface = tools
            ? WorkspaceGlassSurface.make(content: empty, radius: 13, mode: .native, accessibility: options,
                                         disableNativeGlass: environment.disableNativeGlass)
            : WorkspacePanelSurface.make(content: empty, mode: .native, radius: 13, accessibility: options)
        addSubview(surface, positioned: .below, relativeTo: content)
        carrier = surface
        needsLayout = true
    }
    func setDisplayed(_ value: Bool) {
        guard displayed != value else { return }
        displayed = value
        // isHidden removes a focused field from the key-view loop. Alpha + hit testing
        // preserves the existing field editor and its uncommitted text instead.
        alphaValue = value ? 1 : 0
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard displayed else { return nil }
        if tools {
            let local = convert(point, from: superview)
            guard bounds.contains(local), let hit = content.hitTest(local), hit !== content else { return nil }
            return hit
        }
        return super.hitTest(point)
    }
    override func layout() {
        super.layout()
        carrier?.frame = bounds; content.frame = bounds
    }
}

@MainActor
private final class WorkspaceToolButton: NSButton {
    var perform: () -> Void = {}
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }
    init(_ symbol: String, _ title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        imagePosition = .imageOnly
        isBordered = false; bezelStyle = .regularSquare
        toolTip = title; setAccessibilityLabel(title)
        target = self; self.action = #selector(invoke); perform = action
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event:NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect:NSRect) {
        if isEnabled && (hovered || state == .on || cell?.isHighlighted == true) {
            let opacity = cell?.isHighlighted == true ? 0.17 : state == .on ? 0.11 : 0.06
            (state == .on ? NSColor.controlAccentColor : NSColor.labelColor).withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:6,yRadius:6).fill()
        }
        super.draw(dirtyRect)
    }
    @objc private func invoke() { perform() }
    func select(_ selected: Bool) {
        contentTintColor = selected ? .controlAccentColor : .labelColor
        state = selected ? .on : .off
        needsDisplay = true
        setAccessibilityValue(selected ? "已选中" : "未选中")
    }
}

@MainActor
private final class WorkspaceToolGroup: NSView {
    var buttons: [WorkspaceToolButton] = []
    let vertical: Bool
    init(vertical: Bool = false) { self.vertical = vertical; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    func add(_ button: WorkspaceToolButton) { buttons.append(button); addSubview(button) }
    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() { button.frame = WorkspaceLayout.buttonFrame(index, vertical: vertical) }
    }
}

private final class WorkspaceTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class WorkspaceModeSwitch: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class WorkspaceRootView: NSView, NSMenuDelegate {
    let model: WorkspaceWindowModel
    private(set) var contentHosts: [String: NSView] = [:]
    private var slots: [String: WorkspaceSurfaceSlot] = [:]
    private var observations: [AnyCancellable] = []
    private let navigation = WorkspaceToolGroup(), viewing = WorkspaceToolGroup(), actions = WorkspaceToolGroup()
    private let rail = WorkspaceToolGroup(vertical: true)
    private let zoom = NSPopUpButton(frame: .zero, pullsDown: true)
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private var keyMonitor: Any?
    private let modeSwitch = WorkspaceModeSwitch(labels: ["A 沉浸", "B 选片"], trackingMode: .selectOne, target: nil, action: nil)
    private let title = WorkspaceTitleLabel(labelWithString: "Phos")
    let titleDrag = WorkspaceTitlebarDragView()
    private var menuActions: [Int: () -> Void] = [:]
    private let moreMenu = NSMenu(title: "更多")
    private var appearanceObservation: NSKeyValueObservation?
    private var windowObservations: [AnyCancellable] = []
    #if PHOS_QA
    private var qaRecorder: WorkspaceQARecorder?
    #endif
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init(model: WorkspaceWindowModel) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: 1440, height: 900)))
        wantsLayer = true
        mount("canvas", WorkspaceCanvas(session: model.session))
        addSubview(titleDrag)
        mount("browser", WorkspaceBrowser(model: model), panel: true)
        mount("inspector", WorkspaceInspector(state:model.state), panel: true)
        mount("status", PremiumStatusBar())
        configureTools()
        for (name, group) in [("navigation", navigation), ("viewing", viewing), ("actions", actions), ("rail", rail)] {
            let slot = WorkspaceSurfaceSlot(content: group, tools: true)
            slots[name] = slot; addSubview(slot)
        }
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.alignment = .center; title.lineBreakMode = .byTruncatingMiddle
        title.textColor = .secondaryLabelColor; addSubview(title)
        modeSwitch.controlSize = .small; modeSwitch.segmentStyle = .rounded
        modeSwitch.target = self; modeSwitch.action = #selector(changeWorkspace)
        modeSwitch.setAccessibilityLabel("工作区布局")
        modeSwitch.setToolTip("A 沉浸编辑：铺满画布与紧凑列表", forSegment: 0)
        modeSwitch.setToolTip("B 连续选片：完整画布与横向胶片条", forSegment: 1)
        addSubview(modeSwitch)
        moreMenu.delegate = self
        menuNeedsUpdate(moreMenu) // A pull-down with only its title item cannot begin tracking.
        model.state.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        model.state.history.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        model.state.inspectorUI.objectWillChange.receive(on:RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in:&observations)
        model.session.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        model.environment.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshMaterials() }.store(in: &observations)
        refreshMaterials(); refresh()
        model.state.resumePreviewWork()
        #if PHOS_QA
        qaRecorder = WorkspaceQARecorder(root: self)
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func mount<Content: View>(_ name: String, _ content: Content, panel: Bool = false) {
        let host = WorkspaceTransparentHost(rootView: WorkspaceHostedContent(state: model.state, environment: model.environment, content: content, blocksDuringSync:name != "status"))
        host.safeAreaRegions = []; host.sizingOptions = []
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        contentHosts[name] = host
        if panel {
            let slot = WorkspaceSurfaceSlot(content: host, tools: false)
            slots[name] = slot; addSubview(slot)
        } else { addSubview(host) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservations.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard let window else { model.window = nil; model.router.window = nil; model.selection.window = nil; return }
        model.window = window
        model.selection.window = window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.window?.isKeyWindow == true,
                      self.window?.attachedSheet == nil, self.model.router.presented == nil else { return event }
                let state = self.model.state
                let text = self.window?.firstResponder is NSTextView || self.window?.firstResponder is NSTextField
                if !text, event.keyCode == 53 {
                    if state.cropSession != nil { state.cancelCrop(); return nil }
                    if state.parameterEdits.token != nil { state.parameterEdits.invalidate(); return nil }
                    if state.maskDrawingKind != nil { state.cancelMaskDrawing(); return nil }
                }
                if !text, event.keyCode == 36, state.cropSession != nil { state.finishCrop(); return nil }
                return self.model.selection.handleKey(event, firstResponder: self.window?.firstResponder) ? nil : event
            }
        }
        model.router.window = window
        WorkspaceWindowChrome.configure(window)
        window.contentMinSize = WorkspaceLayout.minimumSize
        for notification in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                             NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                             NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didUpdateNotification,
                             NSWindow.didEndSheetNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.publisher(for: notification, object: window)
                .receive(on: RunLoop.main).sink { [weak self] _ in
                    guard let self else { return }
                    WorkspaceWindowChrome.positionStandardButtons(in: self)
                    if notification == NSWindow.willCloseNotification { model.state.finishWindowWork() }
                    if notification == NSWindow.didResignKeyNotification { model.state.temporaryPan = false }
                    if notification == NSWindow.willCloseNotification, let monitor = keyMonitor {
                        NSEvent.removeMonitor(monitor); keyMonitor = nil
                    }
                    if notification == NSWindow.didEndSheetNotification { model.router.resumePending() }
                    if notification == NSWindow.didBecomeKeyNotification { model.router.resumeLegacyRequests() }
                    if notification != NSWindow.didUpdateNotification { needsLayout = true }
                }.store(in: &windowObservations)
        }
        appearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshColors() }
        }
        refreshColors(); needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = NSColor(white: dark ? 0.055 : 0.89, alpha: 1).cgColor
        }
    }
    private func refreshMaterials() {
        for slot in slots.values { slot.refresh(environment: model.environment) }
        needsLayout = true
    }
    func refresh() {
        let s = model.state
        navigation.buttons[0].select(model.session.browserVisible)
        navigation.buttons[1].isEnabled = model.enabled(.undo)
        navigation.buttons[2].isEnabled = model.enabled(.redo)
        viewing.buttons[0].isEnabled = s.previousVisiblePhotoIndex != nil && !s.syncRunning
        viewing.buttons[1].isEnabled = s.nextVisiblePhotoIndex != nil && !s.syncRunning
        zoom.isEnabled = s.source != nil && !s.syncRunning
        zoom.item(at: 4)?.isEnabled = s.source != nil && !s.cropMode && !s.syncRunning
        zoom.item(at: 0)?.title = s.oneToOne ? (s.displayFrame?.fullResolution == true ? "1:1" : "准备1:1…") : (s.cropMode ? "裁剪" : model.session.viewingTitle)
        modeSwitch.selectedSegment = model.session.mode == .immersive ? 0 : 1
        actions.buttons[0].select(s.showBefore); actions.buttons[0].isEnabled = model.enabled(.beforeOriginal)
        actions.buttons[1].isEnabled = !s.syncRunning
        actions.buttons[2].isEnabled = model.enabled(.export)
        actions.buttons[3].select(model.session.inspectorVisible)
        rail.buttons[0].select(s.cropMode); rail.buttons[0].isEnabled = s.source != nil && !s.syncRunning
        rail.buttons[1].select(s.whiteBalancePicker); rail.buttons[1].isEnabled = model.enabled(.whiteBalance)
        rail.buttons[2].isEnabled = model.enabled(.autoTone)
        rail.buttons[3].select(s.inspectorUI.category == .masks && !s.cropMode); rail.buttons[3].isEnabled = model.enabled(.masks)
        rail.buttons[5].select(s.selectedMask != nil && s.maskTool != .position && !s.cropMode)
        rail.buttons[5].isEnabled = model.enabled(.brush)
        rail.buttons[5].image = NSImage(systemSymbolName:s.maskTool == .erase ? "eraser" : "paintbrush.pointed",accessibilityDescription:"局部画笔")
        rail.buttons[4].select(s.oneToOne); rail.buttons[4].isEnabled = s.source != nil && !s.cropMode && !s.syncRunning
        title.stringValue = s.current?.url.lastPathComponent ?? "Phos · 打开文件夹开始编辑"
        title.toolTip = s.current?.url.path
        slots["browser"]?.setDisplayed(model.session.browserVisible)
        slots["inspector"]?.setDisplayed(model.session.inspectorVisible)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let layout = WorkspaceLayout.resolve(size: bounds.size, topInset: WorkspaceWindowChrome.topInset(in: self),
                                             browserVisible: model.session.browserVisible, inspectorVisible: model.session.inspectorVisible,
                                             mode: model.session.mode, browserWidth: model.session.browserWidth,
                                             inspectorWidth: model.session.inspectorWidth)
        contentHosts["canvas"]?.frame = layout.canvas
        contentHosts["status"]?.frame = layout.status
        slots["browser"]?.frame = layout.browser; slots["inspector"]?.frame = layout.inspector
        slots["navigation"]?.frame = layout.navigation; slots["viewing"]?.frame = layout.viewing
        slots["actions"]?.frame = layout.actions; slots["rail"]?.frame = layout.rail
        titleDrag.frame = layout.drag
        let inset = WorkspaceWindowChrome.topInset(in: self)
        if model.session.topInset != inset { model.session.topInset = inset }
        let scale = window?.backingScaleFactor ?? 2
        if model.session.backingScale != scale { model.session.backingScale = scale }
        modeSwitch.frame = CGRect(x: layout.title.minX, y: layout.title.minY + 4, width: 156, height: 28)
        title.frame = CGRect(x: layout.title.minX + 168, y: layout.title.minY + 10,
                             width: max(0, layout.title.width - 168), height: 16)
        zoom.frame = CGRect(x: 68, y: 4, width: 72, height: 28)
        more.frame = WorkspaceLayout.buttonFrame(4)
        for slot in slots.values { slot.layoutSubtreeIfNeeded() }
        WorkspaceWindowChrome.positionStandardButtons(in: self)
    }
    private func configureTools() {
        let s = model.state
        navigation.add(WorkspaceToolButton("sidebar.left", "显示或隐藏照片浏览器") { [weak self] in self?.model.session.browserVisible.toggle() })
        navigation.add(WorkspaceToolButton("arrow.uturn.backward", "撤销") { [weak self] in self?.model.perform(.undo) })
        navigation.add(WorkspaceToolButton("arrow.uturn.forward", "重做") { [weak self] in self?.model.perform(.redo) })
        viewing.add(WorkspaceToolButton("chevron.left", "上一张照片") { [weak self] in
            self?.model.selection.navigate(-1)
        })
        viewing.add(WorkspaceToolButton("chevron.right", "下一张照片") { [weak self] in
            self?.model.selection.navigate(1)
        })
        zoom.isBordered = false; zoom.font = .systemFont(ofSize: 11, weight: .medium)
        zoom.menu?.autoenablesItems = false
        zoom.setAccessibilityLabel("画布观看方式")
        for name in ["铺满", "适合窗口", "铺满窗口", "跟随布局", "1:1 检查", "全像素预览"] { zoom.addItem(withTitle: name) }
        zoom.target = self; zoom.action = #selector(changeZoom)
        viewing.addSubview(zoom)
        actions.add(WorkspaceToolButton("rectangle.lefthalf.inset.filled", "原图与调整后对比") { [weak self] in self?.model.perform(.beforeOriginal) })
        actions.add(WorkspaceToolButton("folder", "打开文件夹") { [weak self] in self?.model.perform(.openFolder) })
        actions.add(WorkspaceToolButton("square.and.arrow.up", "导出当前照片") { [weak self] in self?.model.perform(.export) })
        actions.add(WorkspaceToolButton("sidebar.right", "显示或隐藏调整面板") { [weak self] in self?.model.session.inspectorVisible.toggle() })
        more.isBordered = false; more.imagePosition = .imageOnly
        more.toolTip = "更多操作与外观"; more.setAccessibilityLabel("更多操作与外观")
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        addMoreTitle(); more.menu = moreMenu; actions.addSubview(more)
        rail.add(WorkspaceToolButton("crop", "裁剪") { [weak self] in self?.model.perform(.crop) })
        rail.add(WorkspaceToolButton("eyedropper", "白平衡灰点取样") { [weak self] in self?.model.perform(.whiteBalance) })
        rail.add(WorkspaceToolButton("sparkles", "自动影调") { [weak self] in self?.model.perform(.autoTone) })
        rail.add(WorkspaceToolButton("square.3.layers.3d", "局部蒙版") { [weak self] in self?.model.perform(.masks) })
        rail.add(WorkspaceToolButton("1.magnifyingglass", "1:1 检查") { [weak self] in self?.model.perform(.pixel100) })
        rail.add(WorkspaceToolButton("paintbrush.pointed", "局部画笔") { [weak self] in self?.model.perform(.brush) })
    }
    @objc private func changeZoom() {
        switch zoom.indexOfSelectedItem {
        case 1: model.perform(.fit)
        case 2: model.state.oneToOne = false; model.session.viewport.mode = .fill
        case 3: model.state.oneToOne = false; model.session.viewport.mode = .automatic
        case 4: model.perform(.pixel100)
        case 5: model.state.fullResPreview.toggle()
        default: break
        }
        refresh()
    }
    @objc private func changeWorkspace() {
        model.session.mode = modeSwitch.selectedSegment == 0 ? .immersive : .filmstrip
    }
    private func addMoreTitle() {
        let title = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作与外观")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        moreMenu.addItem(title)
    }
    private func item(_ name: String, in menu: NSMenu, enabled: Bool = true, checked: Bool = false,
                      action: @escaping () -> Void) {
        let id = menuActions.count + 1
        let item = NSMenuItem(title: name, action: #selector(invokeMenu(_:)), keyEquivalent: "")
        item.target = self; item.tag = id; item.isEnabled = enabled; item.state = checked ? .on : .off
        menu.autoenablesItems = false; menu.addItem(item); menuActions[id] = action
    }
    @objc private func invokeMenu(_ sender: NSMenuItem) { menuActions[sender.tag]?() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === moreMenu else { return }
        menu.removeAllItems(); menuActions.removeAll()
        addMoreTitle()
        let s = model.state, ready = model.state.source != nil && !model.state.syncRunning
        for mode in WorkspaceMode.allCases {
            item(mode.title, in: menu, checked: model.session.mode == mode) { [weak self] in self?.model.session.mode = mode }
        }
        let widths = NSMenu(title: "面板宽度")
        for width: CGFloat in [196, 212, 240, 260] {
            item("照片列表 \(Int(width))", in: widths, checked: model.session.browserWidth == width) { [weak self] in self?.model.session.browserWidth = width }
        }
        widths.addItem(.separator())
        for width: CGFloat in [248, 264, 304] {
            item("调整面板 \(Int(width))", in: widths, checked: model.session.inspectorWidth == width) { [weak self] in self?.model.session.inspectorWidth = width }
        }
        let widthsItem = NSMenuItem(title: "面板宽度", action: nil, keyEquivalent: ""); widthsItem.submenu = widths; menu.addItem(widthsItem)
        menu.addItem(.separator())
        item("浏览预设…", in: menu, enabled: ready) { s.parameterEdits.finishCurrent(); self.model.session.inspectorVisible = true; s.inspectorUI.showPresets = true }
        item("照片信息…", in: menu, enabled: s.current != nil) { self.model.session.inspectorVisible = true; s.inspectorUI.showInformation = true }
        let presets = NSMenu(title: "预设")
        for preset in s.loadPresets() {
            item(preset.name, in: presets, enabled: ready) { [weak self] in s.commit(preset.params) }
        }
        presets.addItem(.separator())
        item("保存当前调整为预设…", in: presets, enabled: ready) { [weak self] in self?.model.savePreset() }
        let presetItem = NSMenuItem(title: "预设", action: nil, keyEquivalent: ""); presetItem.submenu = presets; menu.addItem(presetItem)
        for (name, command) in [("命名快照…", WorkspaceCommandID.snapshots), ("同步调整…", .sync), ("批量导出…", .batch), ("多重曝光合成…", .merge), ("同几何分割对比", .beforeGeometry), ("局部画笔", .brush), ("显示或隐藏当前蒙版", .overlay), ("取消当前处理", .cancelJob)] {
            item(name, in: menu, enabled: model.enabled(command),checked:command == .beforeGeometry && s.splitComparison) { [weak self] in self?.model.perform(command) }
        }
        item("复制调整", in: menu, enabled: model.enabled(.copy)) { [weak self] in self?.model.perform(.copy) }
        item("全像素预览", in: menu, enabled: ready, checked: s.fullResPreview) { s.fullResPreview.toggle() }
        menu.addItem(.separator())
        let appearance = NSMenu(title: "外观")
        for (name, value) in [("跟随系统", "system"), ("浅色", "light"), ("深色", "dark")] {
            item(name, in: appearance, checked: (UserDefaults.standard.string(forKey: "rf.appearance") ?? "system") == value) {
                UserDefaults.standard.set(value, forKey: "rf.appearance")
            }
        }
        let appearanceItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: ""); appearanceItem.submenu = appearance; menu.addItem(appearanceItem)
        #if PHOS_QA
        let qa = NSMenu(title:"QA辅助功能")
        for (label,value) in [("系统","system"),("减少透明度","reduceTransparency"),("增强对比度","increaseContrast"),("减少动态效果","reduceMotion")] {
            item(label,in:qa) { [weak self] in self?.model.environment.setQAAccessibilityMode(value) }
        }
        let qaItem = NSMenuItem(title:"QA辅助功能",action:nil,keyEquivalent:""); qaItem.submenu = qa; menu.addItem(qaItem)
        #endif
        item("检查更新…", in: menu) { s.checkForUpdates(silent: false) }
        if let update = s.availableUpdate { item("下载新版本 \(update.version)…", in: menu) { s.openUpdatePage() } }
    }

    /// Real hierarchy diagnostics shared by lifecycle tests and the opt-in QA recorder.
    var shellDiagnostics: [String: Any] {
        let groups = [navigation, viewing, actions, rail]
        return ["entry": "WorkspaceWindow", "rootID": String(describing: ObjectIdentifier(self)),
                "appStateID": String(describing: ObjectIdentifier(model.state)),
                "contentHostIDs": contentHosts.mapValues { String(describing: ObjectIdentifier($0)) },
                "contentHostFrames": contentHosts.mapValues { NSStringFromRect($0.convert($0.bounds, to: self)) },
                "slotFrames": slots.mapValues { NSStringFromRect($0.frame) },
                "canvasHostCount": contentHosts.keys.filter { $0 == "canvas" }.count,
                "moreMenuItemCount": moreMenu.items.count,
                "oneToOneMenuEnabled": zoom.item(at: 4)?.isEnabled ?? false,
                "workspaceMode": model.session.mode.rawValue, "viewingMode": model.session.viewingTitle,
                "workCounters": model.state.workMetrics.snapshot,
                "thumbnailCacheCount": model.state.thumbnailCacheCount,
                "thumbnailActiveCount": model.state.thumbnailActiveCount,
                "browserVisible": model.session.browserVisible, "inspectorVisible": model.session.inspectorVisible,
                "buttons": groups.flatMap { group in group.buttons.map { button in
                    ["title": button.toolTip ?? "", "frame": NSStringFromRect(button.convert(button.bounds, to: self)),
                     "localFrame": NSStringFromRect(button.frame), "enabled": button.isEnabled] as [String: Any]
                } }]
    }
}

