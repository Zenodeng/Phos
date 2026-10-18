import AppKit
import Combine

enum WorkspaceMode: String, Codable, CaseIterable {
    case immersive, filmstrip
    var title: String { self == .immersive ? "A · 沉浸编辑" : "B · 连续选片" }
}
enum CanvasViewMode: String, Codable { case automatic, fit, fill, manual }
struct CanvasViewport {
    var mode: CanvasViewMode = .automatic
    var editedImageCenter = CGPoint(x: 0.5, y: 0.5)
    var screenPixelsPerEditedPixel: CGFloat = 1
}

/// Only UI preferences live here. Layout changes never touch the photo model.
@MainActor
final class WorkspaceSessionState: ObservableObject {
    private let defaults: UserDefaults?
    @Published var mode: WorkspaceMode = .immersive {
        didSet {
            defaults?.set(mode.rawValue, forKey: "phos.workspace.mode")
            if viewport.mode != .manual {
                viewport.mode = CanvasViewMode(rawValue: defaults?.string(forKey: "phos.workspace.viewMode." + mode.rawValue) ?? "") ?? .automatic
            }
        }
    }
    @Published var browserVisible = true { didSet { defaults?.set(browserVisible, forKey: "phos.workspace.browser") } }
    @Published var inspectorVisible = true { didSet { defaults?.set(inspectorVisible, forKey: "phos.workspace.inspector") } }
    @Published var browserWidth: CGFloat = 212 { didSet { defaults?.set(Double(browserWidth), forKey: "phos.workspace.browserWidth") } }
    // Compact Inspector widths; complex charts can expand into their own popover.
    @Published var inspectorWidth: CGFloat = 264 { didSet { defaults?.set(Double(inspectorWidth), forKey: "phos.workspace.inspectorWidth") } }
    @Published var viewport = CanvasViewport() {
        didSet {
            if viewport.mode != .manual { defaults?.set(viewport.mode.rawValue, forKey: "phos.workspace.viewMode." + mode.rawValue) }
        }
    }
    @Published var backingScale: CGFloat = 2
    @Published var topInset: CGFloat = 0
    init(persist: Bool = true, defaults: UserDefaults = .standard) {
        self.defaults = persist ? defaults : nil
        guard persist else { return }
        mode = WorkspaceMode(rawValue: defaults.string(forKey: "phos.workspace.mode") ?? "") ?? .immersive
        viewport.mode = CanvasViewMode(rawValue: defaults.string(forKey: "phos.workspace.viewMode." + mode.rawValue) ?? "") ?? .automatic
        if defaults.object(forKey: "phos.workspace.browser") != nil { browserVisible = defaults.bool(forKey: "phos.workspace.browser") }
        if defaults.object(forKey: "phos.workspace.inspector") != nil { inspectorVisible = defaults.bool(forKey: "phos.workspace.inspector") }
        if defaults.object(forKey: "phos.workspace.browserWidth") != nil { browserWidth = CGFloat(defaults.double(forKey: "phos.workspace.browserWidth")) }
        if defaults.object(forKey: "phos.workspace.inspectorWidth") != nil { inspectorWidth = CGFloat(defaults.double(forKey: "phos.workspace.inspectorWidth")) }
        if !defaults.bool(forKey:"phos.workspace.compactInspectorV3") {
            inspectorWidth = inspectorWidth == 330 ? 264 : min(max(inspectorWidth,248),304)
            defaults.set(true,forKey:"phos.workspace.compactInspectorV3")
        }
    }
    var usesFill: Bool { viewport.mode == .fill || (viewport.mode == .automatic && mode == .immersive) }
    var viewingTitle: String { viewport.mode == .manual ? "自定" : usesFill ? "铺满" : "适合" }
}

/// All frames, preferred width constraints and precision-safe bounds have one owner.
struct WorkspaceLayout {
    let canvas, safeCanvas, browser, inspector, rail, navigation, viewing, actions, title, drag, status: CGRect
    static let toolHeight: CGFloat = 36
    static let buttonSide: CGFloat = 28
    static let minimumSize = CGSize(width: 1200, height: 780)
    static func resolve(size: CGSize, topInset: CGFloat = 0, browserVisible: Bool = true,
                        inspectorVisible: Bool = true, mode: WorkspaceMode = .immersive,
                        browserWidth: CGFloat = 212, inspectorWidth: CGFloat = 264) -> Self {
        let w = max(size.width, minimumSize.width), h = max(size.height, minimumSize.height)
        let y = topInset + 12, bodyY = topInset + 64, bottom = h - 38
        let hasList = mode == .immersive && browserVisible
        let iw = min(max(inspectorWidth, 248), min(304, hasList ? w - 196 - 652 : w - 648))
        let bw = min(max(browserWidth, 196), hasList ? min(260, w - iw - 652) : 260)
        let inspector = CGRect(x: w - iw - 56, y: bodyY, width: iw, height: bottom - bodyY)
        let browser = mode == .immersive
            ? CGRect(x: 12, y: bodyY, width: bw, height: bottom - bodyY)
            : CGRect(x: 12, y: bottom - 122, width: (inspectorVisible ? inspector.minX - 12 : w - 56) - 12, height: 122)
        let left = mode == .immersive && browserVisible ? browser.maxX + 12 : 20
        let right = inspectorVisible ? inspector.minX - 12 : w - 56
        let safeBottom = mode == .filmstrip && browserVisible ? browser.minY - 12 : bottom
        let safe = CGRect(x: left, y: bodyY, width: max(1, right - left), height: max(100, safeBottom - bodyY))
        let navigation = CGRect(x: 88, y: y, width: 100, height: toolHeight)
        let viewing = CGRect(x: 200, y: y, width: 144, height: toolHeight)
        let actions = CGRect(x: w - 176, y: y, width: 164, height: toolHeight)
        return Self(canvas: CGRect(x: 0, y: 0, width: w, height: h), safeCanvas: safe,
                    browser: browser, inspector: inspector,
                    rail: CGRect(x: w - 48, y: bodyY, width: 36, height: 196),
                    navigation: navigation, viewing: viewing, actions: actions,
                    title: CGRect(x: viewing.maxX + 20, y: y, width: max(0, actions.minX - viewing.maxX - 40), height: toolHeight),
                    drag: CGRect(x: 80, y: topInset, width: w - 80, height: 60),
                    status: CGRect(x: 0, y: h - 29, width: w, height: 29))
    }
    static func buttonFrame(_ index: Int, vertical: Bool = false) -> CGRect {
        CGRect(x: vertical ? 4 : 4 + CGFloat(index) * 32,
               y: vertical ? 4 + CGFloat(index) * 32 : 4, width: buttonSide, height: buttonSide)
    }
}

enum WorkspacePresentation: String, Identifiable, CaseIterable {
    case export, batch, merge, sync, snapshots, error, update, photoAI
    var id: String { rawValue }
}

/// The only workspace sheet presenter. Existing feature views can still raise AppState flags.
@MainActor
final class WorkspaceSheetRouter: ObservableObject {
    private final class Owner {
        weak var router: WorkspaceSheetRouter?
        init(_ router: WorkspaceSheetRouter) { self.router = router }
    }
    private static var legacyOwners: [ObjectIdentifier: Owner] = [:]
    @Published private(set) var presented: WorkspacePresentation?
    private(set) var pending: [WorkspacePresentation] = []
    private var dismissing: WorkspacePresentation?
    var nativePanelOpen = false
    private var observations: [AnyCancellable] = []
    let state: AppState
    weak var window: NSWindow?
    private(set) var errorMessage = ""

    init(state: AppState) {
        self.state = state
        func watch(_ publisher: Published<Bool>.Publisher, _ route: WorkspacePresentation) {
            publisher.filter { $0 }.receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.requestLegacy(route) }.store(in: &observations)
        }
        watch(state.$showPhotoAI, .photoAI)
        watch(state.$showExport, .export); watch(state.$showBatch, .batch)
        watch(state.$showMerge, .merge); watch(state.$showSync, .sync)
        watch(state.$showSnapshots, .snapshots); watch(state.$showUpdateResult, .update)
        state.$workflowError.compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.errorMessage = message
                self?.requestLegacy(.error)
            }.store(in: &observations)
    }

    private func requestLegacy(_ route: WorkspacePresentation) {
        let key = ObjectIdentifier(state)
        if let owner = Self.legacyOwners[key]?.router, owner !== self { return }
        // Shared AppState flags must not open the same form in every WindowGroup window.
        if Self.legacyOwners[key]?.router == nil {
            guard window == nil || window?.isKeyWindow == true || window?.attachedSheet?.isKeyWindow == true || NSApp.keyWindow == nil else { return }
            Self.legacyOwners[key] = Owner(self)
        }
        request(route)
    }

    func resumeLegacyRequests() {
        for (flag, route) in [(state.showExport, WorkspacePresentation.export), (state.showBatch, .batch),
                              (state.showMerge, .merge), (state.showSync, .sync), (state.showSnapshots, .snapshots),
                              (state.showPhotoAI, .photoAI), (state.showUpdateResult, .update), (state.workflowError != nil, .error)] where flag {
            if route == .error { errorMessage = state.workflowError ?? "" }
            requestLegacy(route)
        }
    }

    func request(_ route: WorkspacePresentation) {
        guard route != presented, route != dismissing, !pending.contains(route) else { return }
        if presented == nil && dismissing == nil && window?.attachedSheet == nil && !nativePanelOpen { presented = route }
        else { pending.append(route) }
    }

    func beginDismissal() {
        guard let presented else { return }
        dismissing = presented
        self.presented = nil
    }

    func didDismiss() {
        let route = dismissing ?? presented
        presented = nil
        switch route {
        case .photoAI: state.showPhotoAI = false
        case .export: state.showExport = false
        case .batch: state.showBatch = false
        case .merge: state.showMerge = false
        case .sync: state.showSync = false
        case .snapshots: state.showSnapshots = false
        case .error: state.workflowError = nil
        case .update: state.showUpdateResult = false
        case nil: break
        }
        dismissing = nil
        if pending.isEmpty, Self.legacyOwners[ObjectIdentifier(state)]?.router === self {
            Self.legacyOwners.removeValue(forKey: ObjectIdentifier(state))
        }
        // SwiftUI must finish removing the old sheet before another one is attached.
        DispatchQueue.main.async { [weak self] in self?.resumePending() }
    }

    func resumePending() {
        guard presented == nil, dismissing == nil, window?.attachedSheet == nil, !nativePanelOpen, !pending.isEmpty else { return }
        presented = pending.removeFirst()
    }
}
