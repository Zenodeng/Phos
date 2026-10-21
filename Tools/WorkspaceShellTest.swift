import AppKit
import SwiftUI
import CoreImage

#if !PHOS_WORKSPACE_SUITE
@main
#endif
struct WorkspaceShellTest {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)); exit(1) }
            checks += 1
            print("PASS: \(name)")
            fflush(stdout)
        }
        var layoutCases = 0
        for size in [CGSize(width: 1200, height: 780), CGSize(width: 1440, height: 900), CGSize(width: 1728, height: 1117)] {
            for inset: CGFloat in [0, 32] {
                for browser in [false, true] { for inspector in [false, true] {
                    let l = WorkspaceLayout.resolve(size: size, topInset: inset, browserVisible: browser, inspectorVisible: inspector)
                    precondition(l.safeCanvas.width >= 560 && l.safeCanvas.height > 0)
                    precondition(!l.navigation.intersects(l.viewing) && !l.viewing.intersects(l.title) && !l.title.intersects(l.actions))
                    precondition(l.navigation.minX >= 80 && abs(l.navigation.midY - (inset + 30)) < 0.5)
                    precondition(!l.inspector.intersects(l.rail) && !l.rail.intersects(l.actions))
                    if browser { precondition(!l.safeCanvas.intersects(l.browser)) }
                    if inspector { precondition(!l.safeCanvas.intersects(l.inspector)) }
                    precondition(l.status.maxY == size.height && l.browser.maxY < l.status.minY)
                    for i in 0..<5 {
                        let b = WorkspaceLayout.buttonFrame(i)
                        precondition(b.size == CGSize(width: 28, height: 28) && abs(b.midY - 18) <= 0.5)
                        let r = WorkspaceLayout.buttonFrame(i, vertical: true)
                        precondition(abs(r.midX - 18) <= 0.5 && r.maxY <= l.rail.height)
                    }
                    layoutCases += 1
                } }
            }
        }
        check(layoutCases == 24, "24 size / safe area / visibility layouts have safe canvas, disjoint chrome and centered buttons")

        let s = AppState()
        let firstRouter = WorkspaceSheetRouter(state: s)
        let otherWindowRouter = WorkspaceSheetRouter(state: s)
        s.showExport = true
        try await Task.sleep(nanoseconds: 100_000_000)
        let router = firstRouter.presented != nil ? firstRouter : otherWindowRouter
        let idleRouter = router === firstRouter ? otherWindowRouter : firstRouter
        s.showSync = true; s.workflowError = "Test error"
        try await Task.sleep(nanoseconds: 100_000_000)
        check(router.presented == .export && router.pending == [.sync, .error], "legacy requests serialize to one window presentation")
        check(idleRouter.presented == nil && idleRouter.pending.isEmpty, "shared AppState flags do not duplicate sheets across window routers")
        router.request(.export); router.request(.sync)
        check(router.pending == [.sync, .error], "duplicate active and queued requests are coalesced")
        router.beginDismissal(); router.didDismiss()
        try await Task.sleep(nanoseconds: 100_000_000)
        check(!s.showExport && router.presented == .sync, "dismiss resets the originating flag before presenting the next sheet")
        router.beginDismissal(); router.didDismiss()
        try await Task.sleep(nanoseconds: 100_000_000)
        check(router.presented == .error && router.errorMessage == "Test error", "errors raised under a sheet remain accessible")
        router.beginDismissal(); router.didDismiss()
        check(router.presented == nil && s.workflowError == nil && !s.showSync, "cancel drains the router without stale business flags")
        router.nativePanelOpen = true
        router.request(.export)
        router.resumePending()
        check(router.presented == nil && router.pending == [.export], "application-modal native panels queue workspace requests")
        router.nativePanelOpen = false
        router.resumePending()
        check(router.presented == .export && router.pending.isEmpty, "closing a native modal panel resumes the queued workspace presentation")
        router.beginDismissal(); router.didDismiss()

        let model = WorkspaceWindowModel(state: s, session: WorkspaceSessionState(persist: false))
        let root = WorkspaceRootView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let identities = root.contentHosts.mapValues(ObjectIdentifier.init)
        let originalParams = s.params, history = s.history.stack, index = s.history.index
        for i in 0..<20 {
            model.session.browserVisible = i % 2 == 0; model.session.inspectorVisible = i % 3 == 0
            root.frame.size = i % 2 == 0 ? CGSize(width: 1200, height: 780) : CGSize(width: 1440, height: 900)
            root.refresh(); root.layoutSubtreeIfNeeded()
        }
        check(model.state === s && root.model === model, "root and commands use the same injected AppState")
        check((root.shellDiagnostics["moreMenuItemCount"] as? Int ?? 0) > 8, "native command menu is populated before its first opening")
        check(root.contentHosts.mapValues(ObjectIdentifier.init) == identities && identities.count == 4,
              "20 visibility and resize cycles retain all four hosts including the sole CanvasPane")
        check(s.params == originalParams && s.history.stack == history && s.history.index == index && s.source == nil,
              "presentation-only changes preserve photo / parameters / history and do not manufacture a source")
        model.session.browserVisible = true; model.session.inspectorVisible = true
        root.refresh(); root.layoutSubtreeIfNeeded()
        check(root.hitTest(root.convert(NSPoint(x: 750, y: 30), to: root.superview)) is WorkspaceTitlebarDragView,
              "empty title region reaches native drag handler")
        check(root.hitTest(root.convert(NSPoint(x: 90, y: 14), to: root.superview)) is WorkspaceTitlebarDragView,
              "empty glass tool padding passes through to the title drag strip")
        check(root.hitTest(root.convert(NSPoint(x: 106, y: 30), to: root.superview)) is NSButton,
              "real tool buttons retain input while surrounding glass passes through")
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        check(lights.count == 3 && lights.allSatisfy { abs($0.convert($0.bounds, to: root).midY - 30) <= 0.5 }, "real standard window controls share the tool centerline")

        let field = NSTextField(string: "1.23456789")
        let slot = WorkspaceSurfaceSlot(content: field, tools: true)
        slot.frame = CGRect(x: 500, y: 200, width: 200, height: 36)
        root.addSubview(slot)
        let native = WorkspaceEnvironment(), solid = WorkspaceEnvironment(forcedAccessibility: "reduceTransparency")
        slot.refresh(environment: native); slot.layoutSubtreeIfNeeded()
        window.makeFirstResponder(field)
        let responder = window.firstResponder
        let editor = responder as? NSTextView
        editor?.string = "-2.75"; editor?.setSelectedRange(NSRange(location: 2, length: 2))
        slot.setDisplayed(false); slot.refresh(environment: solid); slot.layoutSubtreeIfNeeded()
        slot.setDisplayed(true); slot.refresh(environment: native); slot.layoutSubtreeIfNeeded()
        check(window.firstResponder === responder && field.superview === slot && slot.content === field,
              "material and visibility changes retain content parent and firstResponder")
        check(editor != nil && editor?.string == "-2.75" && editor?.selectedRange() == NSRange(location: 2, length: 2),
              "uncommitted field editor text and selection survive carrier replacement")
        slot.refresh(environment: solid); slot.layoutSubtreeIfNeeded()
        func effects(_ v: NSView) -> Int {
            (v is NSVisualEffectView || v is NSGlassEffectView ? 1 : 0) + v.subviews.reduce(0) { $0 + effects($1) }
        }
        check(effects(slot) == 0, "solid carrier removes native effect objects without unmounting content")
        func glassViews(_ view: NSView) -> Int {
            (view is NSGlassEffectView ? 1 : 0) + view.subviews.reduce(0) { $0 + glassViews($1) }
        }
        let panelHosts = [root.contentHosts["browser"]!, root.contentHosts["inspector"]!]
        let panelParents = panelHosts.map { $0.superview! }
        model.session.mode = .immersive; root.refresh(); root.layoutSubtreeIfNeeded()
        let nativeExpected = WorkspaceMaterialPolicy(mode: .native, accessibility: model.environment.accessibility,
            disableNativeGlass: model.environment.disableNativeGlass).tools == .nativeGlass
        check(panelParents.allSatisfy { glassViews($0) == (nativeExpected ? 1 : 0) },
              "immersive sidebars use native glass carriers when transparency is available")
        model.session.mode = .filmstrip; root.refresh(); root.layoutSubtreeIfNeeded()
        check(panelParents.allSatisfy { glassViews($0) == (nativeExpected ? 1 : 0) }
              && zip(panelHosts, panelParents).allSatisfy { $0.superview === $1 },
              "filmstrip shares glass sidebars without replacing or reparenting their contents")
        let panelField = NSTextField(string: "draft")
        let floating = WorkspaceSurfaceSlot(content: panelField, tools: false)
        floating.frame = CGRect(x: 500, y: 250, width: 200, height: 100); root.addSubview(floating)
        floating.refresh(environment: native, floating: true); window.makeFirstResponder(panelField)
        let panelEditor = window.firstResponder
        floating.refresh(environment: solid, floating: true)
        check(effects(floating) == 0 && panelField.superview === floating && window.firstResponder === panelEditor,
              "floating sidebar transparency fallback keeps the active native field editor")
        let feedback = WorkspaceToolButton("checkmark", "feedback-test", action: {})
        feedback.frame = CGRect(x: 400, y: 100, width: 28, height: 28); root.addSubview(feedback)
        let hitFrame = feedback.frame
        feedback.animateFeedback(1.06)
        check((feedback.layer?.animation(forKey: "glassFeedback") != nil) == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
              && feedback.frame == hitFrame, "native glass button feedback preserves its exact hit frame")
        feedback.motionReduced = true
        check(feedback.layer?.animation(forKey: "glassFeedback") == nil,
              "Reduce Motion immediately cancels native tool button feedback")
        feedback.motionReduced = false; feedback.isEnabled = false; feedback.animateFeedback(1.06)
        check(feedback.layer?.animation(forKey: "glassFeedback") == nil,
              "disabled native action buttons never start interaction animations")
        let precision = -43.88451206140351
        check(!SliderRoundTripPolicy.isEdit(precision.nextDown, current: precision, range: -100...100)
              && SliderRoundTripPolicy.isEdit(precision + 0.0001, current: precision, range: -100...100),
              "native slider round-trip noise is ignored while real fine edits remain available")
        s.source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        var precise = s.params; precise.highlights = precision; precise.shadows = 27.60784313725491
        s.params = precise; root.refresh(); root.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(s.params == precise, "mounting the real Inspector preserves untouched high-precision parameters")
        s.cropMode = true; root.refresh()
        let cropDisabled = root.shellDiagnostics["oneToOneMenuEnabled"] as? Bool == false
        s.cropMode = false; root.refresh()
        check(cropDisabled && root.shellDiagnostics["oneToOneMenuEnabled"] as? Bool == true,
              "viewing menu preserves the existing 1:1 exclusion during crop and restores it afterward")
        window.makeFirstResponder(nil); window.contentView = nil
        let report: [String: Any] = ["status": "passed", "checks": checks, "layoutCases": layoutCases,
                                    "retainedHosts": identities.count, "visibilityCycles": 20]
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS workspace shell: \(checks) checks, \(layoutCases) layouts")
    }
}
