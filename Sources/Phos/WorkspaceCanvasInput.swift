import AppKit
import SwiftUI

/// Input is scoped to the visible canvas. Text editors and sheets keep their own keys.
struct WorkspaceCanvasInput: NSViewRepresentable {
    let state: AppState
    let safeRect: CGRect
    let zoom: (CGFloat,CGPoint) -> Void
    func makeNSView(context: Context) -> CanvasInputView { CanvasInputView() }
    func updateNSView(_ v: CanvasInputView, context: Context) { v.state = state; v.safeRect = safeRect; v.zoom = zoom }
}
@MainActor final class CanvasInputView: NSView {
    weak var state: AppState?
    var safeRect = CGRect.zero
    var zoom: ((CGFloat,CGPoint) -> Void)?
    private var monitor: Any?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        state?.temporaryPan = false
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.magnify,.keyDown,.keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }
    private func handle(_ event:NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil, let state else { return event }
        if event.type == .keyUp, event.keyCode == 49, state.temporaryPan { state.temporaryPan = false; return nil }
        guard !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
              state.pendingPhotoEditID == nil, !state.syncRunning, !state.cropMode, state.source != nil else { return event }
        let p = convert(window.mouseLocationOutsideOfEventStream,from:nil)
        guard safeRect.contains(p) else { return event }
        if event.type == .keyDown, event.keyCode == 49,
           event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            state.temporaryPan = true; return nil
        }
        if event.type == .scrollWheel {
            zoom?(exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.005 : 0.06)),p)
            return nil
        }
        if event.type == .magnify { zoom?(max(0.1,1+event.magnification),p); return nil }
        return event
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

extension CanvasViewport {
    /// Solve a new center so the same edited pixel remains under the pointer.
    mutating func zoom(factor:CGFloat,anchor:CGPoint,transform:DisplayTransform,viewport:CGRect,backingScale:CGFloat) {
        guard let n = transform.normalizedPoint(anchor,requireInside:false), factor.isFinite else { return }
        let pixels = min(max(transform.screenPixelsPerEditedPixel*factor,0.02),16)
        let w = transform.outputExtent.width*pixels/max(backingScale,1)
        let h = transform.outputExtent.height*pixels/max(backingScale,1)
        guard w > 0,h > 0 else { return }
        mode = .manual; screenPixelsPerEditedPixel = pixels
        editedImageCenter = CGPoint(x:n.x+(viewport.midX-anchor.x)/w,y:n.y-(viewport.midY-anchor.y)/h)
    }
}
