import SwiftUI
import AppKit

private struct WorkspaceNativeGlassDisabledKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var workspaceNativeGlassDisabled: Bool {
        get { self[WorkspaceNativeGlassDisabledKey.self] }
        set { self[WorkspaceNativeGlassDisabledKey.self] = newValue }
    }
}

/// Shared button chrome; geometry and actions remain owned by the original control.
struct WorkspaceGlassDecoration: ViewModifier {
    var selected = false
    var radius: CGFloat = 8
    @Environment(\.workspaceAccessibility) private var options
    @Environment(\.workspaceNativeGlassDisabled) private var disabledGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @ViewBuilder func body(content: Content) -> some View {
        #if PHOS_NATIVE_GLASS
        if !options.reduceTransparency && !reduceTransparency && !disabledGlass {
            content.glassEffect(.regular.tint(selected ? WorkspaceTokens.accent.opacity(0.20) : nil)
                .interactive(enabled && !options.reduceMotion && !reduceMotion), in: RoundedRectangle(cornerRadius: radius))
        } else { fallback(content) }
        #else
        fallback(content)
        #endif
    }
    private func fallback(_ content: Content) -> some View {
        content.background(selected ? WorkspaceTokens.accent.opacity(0.18) : WorkspaceTokens.readoutColor,
                           in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.primary.opacity(options.increaseContrast ? 0.5 : 0.12), lineWidth: options.increaseContrast ? 1.5 : 0.5).allowsHitTesting(false))
    }
}

private struct WorkspaceGlassPanelBackdrop: NSViewRepresentable {
    @Environment(\.workspaceAccessibility) private var options
    @Environment(\.workspaceNativeGlassDisabled) private var disabledGlass
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let signature = "\(options.reduceTransparency)-\(options.increaseContrast)-\(disabledGlass)"
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        guard view.identifier?.rawValue != signature else { return }
        view.identifier = NSUserInterfaceItemIdentifier(signature)
        view.subviews.forEach { $0.removeFromSuperview() }
        let surface = WorkspaceGlassSurface.make(content: NSView(), radius: 18, mode: .native,
            accessibility: options, disableNativeGlass: disabledGlass,
            tint: .rfDynamic(light: NSColor(white: 1, alpha: 0.26), dark: NSColor(white: 0.04, alpha: 0.28)))
        surface.frame = view.bounds; surface.autoresizingMask = [.width, .height]
        view.addSubview(surface)
    }
}
extension View {
    func workspaceGlassPanel() -> some View {
        background(WorkspaceGlassPanelBackdrop().allowsHitTesting(false))
    }
}
