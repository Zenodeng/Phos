import AppKit
import SwiftUI

enum WorkspaceSurfaceMode: String { case native, fallback, solid }
enum WorkspaceSurfaceKind: String { case nativeGlass, matte, solid }
enum WorkspaceMaterialActivity: String {
    case following, active, inactive
    var state: NSVisualEffectView.State {
        switch self { case .following: .followsWindowActiveState; case .active: .active; case .inactive: .inactive }
    }
}

struct WorkspaceMaterialPolicy {
    let mode: WorkspaceSurfaceMode
    let accessibility: WorkspaceAccessibilityOptions
    var disableNativeGlass = false
    static var nativeGlassCompiled: Bool {
        #if PHOS_NATIVE_GLASS
        true
        #else
        false
        #endif
    }
    var panel: WorkspaceSurfaceKind {
        mode == .solid || accessibility.reduceTransparency ? .solid : .matte
    }
    var tools: WorkspaceSurfaceKind {
        if panel == .solid { return .solid }
        return mode == .native && !disableNativeGlass && Self.nativeGlassCompiled ? .nativeGlass : .matte
    }
}

@MainActor
final class WorkspaceSolidPanel: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSurfaceColor()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColor()
    }
    private func updateSurfaceColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkspaceTokens.panel.cgColor
            if (layer?.borderWidth ?? 0) > 0 { layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.45).cgColor }
        }
    }
}

@MainActor
private final class WorkspaceEffectPanel: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if (layer?.borderWidth ?? 0) > 0 { layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.45).cgColor }
        }
    }
}

@MainActor
private final class WorkspacePanelTint: NSView {
    let increaseContrast: Bool
    init(increaseContrast: Bool) { self.increaseContrast = increaseContrast; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: dark ? 0.08 : 1, alpha: increaseContrast ? 0.98 : 0.84).setFill()
        bounds.fill()
    }
}

@MainActor
enum WorkspacePanelSurface {
    static func make(content:NSView,mode:WorkspaceSurfaceMode, radius:CGFloat = WorkspaceTokens.panelRadius,
                     accessibility:WorkspaceAccessibilityOptions? = nil, activity:WorkspaceMaterialActivity = .following) -> NSView {
        let accessibility = accessibility ?? .current
        let surface:NSView
        if WorkspaceMaterialPolicy(mode:mode,accessibility:accessibility).panel == .matte {
            let effect = WorkspaceEffectPanel()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = activity.state
            surface = effect
            let tint = WorkspacePanelTint(increaseContrast: accessibility.increaseContrast)
            pin(tint, in: effect)
        } else {
            let solid = WorkspaceSolidPanel()
            solid.wantsLayer = true
            solid.effectiveAppearance.performAsCurrentDrawingAppearance {
                solid.layer?.backgroundColor = WorkspaceTokens.panel.cgColor
            }
            surface = solid
        }
        surface.wantsLayer = true
        surface.layer?.cornerRadius = radius
        surface.layer?.masksToBounds = true
        if accessibility.increaseContrast {
            surface.layer?.borderWidth = 1
            surface.effectiveAppearance.performAsCurrentDrawingAppearance {
                surface.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.45).cgColor
            }
        }
        pin(content, in: surface)
        return surface
    }
    private static func pin(_ content:NSView, in surface:NSView) {
        surface.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:surface.leadingAnchor),content.trailingAnchor.constraint(equalTo:surface.trailingAnchor),content.topAnchor.constraint(equalTo:surface.topAnchor),content.bottomAnchor.constraint(equalTo:surface.bottomAnchor)])
    }
}

@MainActor
enum WorkspaceGlassSurface {
    static func make(content:NSView, radius:CGFloat = 20, mode:WorkspaceSurfaceMode,
                     accessibility:WorkspaceAccessibilityOptions? = nil, disableNativeGlass:Bool = false) -> NSView {
        let accessibility = accessibility ?? .current
        #if PHOS_NATIVE_GLASS
        let policy = WorkspaceMaterialPolicy(mode:mode,accessibility:accessibility,disableNativeGlass:disableNativeGlass)
        if policy.tools == .nativeGlass {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.cornerRadius = radius
                glass.contentView = content
                return glass
        }
        #endif
        return WorkspacePanelSurface.make(content:content,mode:mode,radius:radius,accessibility:accessibility)
    }
}

#if PHOS_NATIVE_GLASS
@MainActor
private final class WorkspaceGlassGroupContainer: NSGlassEffectContainerView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let content = contentView, let parent = content.superview else { return nil }
        let local = convert(point,from:superview)
        guard bounds.contains(local) else { return nil }
        // The container's private rendering views span the window. Route input only
        // through our actual content so empty space reaches the photo/title strip.
        let target = content.hitTest(parent.convert(local,from:self))
        return target === content ? nil : target
    }
}
#endif

@MainActor
enum WorkspaceGlassGrouping {
    static func make(content: NSView, enabled: Bool) -> NSView {
        #if PHOS_NATIVE_GLASS
        if enabled {
            let group = WorkspaceGlassGroupContainer()
            group.spacing = 0 // Batch the three groups without merging their static outlines.
            group.contentView = content
            return group
        }
        #endif
        return content
    }
}

/// Comparison-only bridge: the same carrier, underneath SwiftUI content in one ZStack.
struct WorkspaceMaterialBackdrop: NSViewRepresentable {
    let mode: WorkspaceSurfaceMode
    let accessibility: WorkspaceAccessibilityOptions
    var activity = WorkspaceMaterialActivity.following
    func makeNSView(context: Context) -> NSView {
        WorkspacePanelSurface.make(content: NSView(), mode: mode, accessibility: accessibility, activity:activity)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
    }
}
