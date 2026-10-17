import AppKit

@MainActor
enum WorkspaceWindowChrome {
    static func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
    }

    static func topInset(in view: NSView) -> CGFloat {
        guard view.window?.styleMask.contains(.fullScreen) == true else { return 0 }
        return view.safeAreaInsets.top
    }
    static func positionStandardButtons(in view:NSView) {
        guard let window = view.window, !window.styleMask.contains(.fullScreen) else { return }
        let centerY = topInset(in:view)+30
        for (index,kind) in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind),let parent = button.superview else { continue }
            let target = CGRect(x:16+CGFloat(index)*20,y:centerY-button.frame.height/2,width:button.frame.width,height:button.frame.height)
            let origin = view.convert(target,to:parent).origin
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

/// Only the explicit title strip drags; photo and parameter content never move the window.
@MainActor
final class WorkspaceTitlebarDragView: NSView {
    override var isOpaque: Bool { false }
    private var dragStart: (pointer:NSPoint,origin:NSPoint)?
    private(set) var dragMouseDownCount = 0
    private(set) var dragEventCount = 0
    private(set) var nativeDragRequestCount = 0
    override func mouseDown(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        dragMouseDownCount += 1
        dragStart = (window.convertPoint(toScreen:event.locationInWindow),window.frame.origin)
        nativeDragRequestCount += 1
        window.performDrag(with:event)
    }
    // Window Server normally consumes the drag. If the event source continues
    // dispatching mouseDragged, keep the same absolute pointer-to-window mapping.
    override func mouseDragged(with event:NSEvent) {
        guard let window,let start = dragStart,!window.styleMask.contains(.fullScreen) else { return }
        dragEventCount += 1
        let pointer = window.convertPoint(toScreen:event.locationInWindow)
        window.setFrameOrigin(NSPoint(x:start.origin.x+pointer.x-start.pointer.x,
                                     y:start.origin.y+pointer.y-start.pointer.y))
    }
    override func mouseUp(with event:NSEvent) { dragStart = nil }
}
