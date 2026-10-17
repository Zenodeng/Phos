import AppKit

// Keep this probe in step with every new AppKit symbol used by WorkspaceGlassSurface.
@MainActor
@available(macOS 26.0, *)
func probeNativeGlass(_ content: NSView) -> NSView {
    let glass = NSGlassEffectView()
    glass.style = .regular
    glass.cornerRadius = 20
    glass.tintColor = nil
    glass.contentView = content
    let group = NSGlassEffectContainerView()
    group.spacing = 0
    group.contentView = glass
    return group
}
