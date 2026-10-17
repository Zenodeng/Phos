import AppKit
import SwiftUI

@main
struct WorkspaceMaterialPolicyTest {
    @MainActor static func main() {
        _ = NSApplication.shared
        var cases = 0
        func countEffects(_ view:NSView) -> Int {
            (view is NSVisualEffectView || view is NSGlassEffectView || view is NSGlassEffectContainerView ? 1 : 0)
                + view.subviews.reduce(0) { $0+countEffects($1) }
        }
        for mode in [WorkspaceSurfaceMode.native,.fallback,.solid] {
            for reduce in [false,true] {
                let options = WorkspaceAccessibilityOptions(reduceTransparency:reduce)
                let panel = WorkspacePanelSurface.make(content:NSView(),mode:mode,accessibility:options)
                let tools = WorkspaceGlassSurface.make(content:NSView(),mode:mode,accessibility:options)
                let policy = WorkspaceMaterialPolicy(mode:mode,accessibility:options)
                if mode == .solid || reduce {
                    precondition(policy.panel == .solid)
                    precondition(policy.tools == .solid)
                    precondition(countEffects(panel) == 0 && countEffects(tools) == 0)
                } else {
                    precondition(countEffects(panel) == 1)
                    precondition((panel as! NSVisualEffectView).state == .followsWindowActiveState)
                    precondition((panel as! NSVisualEffectView).blendingMode == .withinWindow)
                    if mode == .native {
                        precondition(policy.tools == .nativeGlass && tools is NSGlassEffectView)
                    } else {
                        precondition(policy.tools == .matte && tools is NSVisualEffectView)
                    }
                }
                cases += 1
            }
        }
        let disabled = WorkspaceMaterialPolicy(mode:.native,accessibility:.init(),disableNativeGlass:true)
        precondition(disabled.tools == .matte)
        precondition(WorkspaceGlassSurface.make(content:NSView(),mode:.native,disableNativeGlass:true) is NSVisualEffectView)
        precondition(WorkspaceGlassGrouping.make(content:NSView(),enabled:true) is NSGlassEffectContainerView)
        let ungrouped = NSView()
        precondition(WorkspaceGlassGrouping.make(content:ungrouped,enabled:false) === ungrouped)
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            let panel = WorkspacePanelSurface.make(content:NSView(),mode:.solid)
            let window = NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:200),styleMask:[],backing:.buffered,defer:false)
            window.appearance = NSAppearance(named:appearance)
            window.contentView = panel
            panel.layoutSubtreeIfNeeded()
            let color = NSColor(cgColor:panel.layer!.backgroundColor!)!.usingColorSpace(.deviceRGB)!
            precondition(appearance == .aqua ? color.redComponent > 0.90 : color.redComponent < 0.20)
            window.contentView = nil
            cases += 1
        }
        print("PASS material policy: \(cases+4) cases; real glass/group objects, solid removes effects, emergency matte, window activity, dynamic solid colors.")
    }
}
