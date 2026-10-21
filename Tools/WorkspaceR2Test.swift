import AppKit
import CoreImage
import ImageIO

#if !PHOS_WORKSPACE_R3_SUITE
@main
#endif
struct WorkspaceR2Test {
    @MainActor private final class ModeActions: NSObject {
        var count = 0
        @objc func changed(_ sender: Any?) { count += 1 }
    }

    @MainActor static func main() async throws {
        try await WorkspaceShellTest.main()
        let shellReport = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let shellChecks = shellReport["checks"] as! Int
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
        let fixtures = output.appendingPathComponent("photo-fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { FileHandle.standardError.write(Data("FAIL R2: \(name)\n".utf8)); exit(1) }
            checks += 1; print("PASS R2: \(name)"); fflush(stdout)
        }
        func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
            for _ in 0..<1500 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "WorkspaceR2", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for real asynchronous preview work"])
        }
        for index in 0..<12 {
            let name = index == 5 ? "05-长文件名-旅行选片与精密输入-Long_English_Filename.png" : String(format: "%02d-photo.png", index)
            let image = CIImage(color: CIColor(red: CGFloat(index + 1) / 13, green: 0.35, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 96))
            let bitmap = Engine.ctx.createCGImage(image, from: image.extent)!
            let destination = CGImageDestinationCreateWithURL(fixtures.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, bitmap, nil); precondition(CGImageDestinationFinalize(destination))
        }
        let s = AppState()
        s.openFolder(fixtures)
        try await wait { s.preview != nil && !s.previewing }
        check(s.items.count == 12 && s.previewFrame?.key.photoID == s.current?.id, "folder opens into a frame bound to the current real photo")
        check(s.previewFrame?.key.paramsFingerprint == PreviewFrame.fingerprint(s.params) && s.previewFrame?.key.purpose == .edited,
              "the published frame has the exact parameter fingerprint and edited purpose")
        let frames = s.previewFrame!
        check(frames.bitmapSize == CGSize(width: 128, height: 96) && frames.editedExtent.size == frames.bitmapSize,
              "frame geometry records output bitmap dimensions independently of source metadata")
        check(frames.histogram.r == Engine.histogram(CIImage(cgImage: frames.image)).r, "the histogram is derived from the same published image pixels")
        let noEditWrites = s.workMetrics.snapshot["sidecarWrite"]!
        s.select(1); s.select(2); s.select(0)
        try await wait { s.preview != nil && !s.previewing }
        check(s.previewFrame?.key.photoID == s.current?.id && s.currentIndex == 0, "rapid photo selection cannot publish another photo's frame")
        check(s.workMetrics.snapshot["sidecarWrite"] == noEditWrites, "browsing untouched photos never creates or rewrites sidecars")
        s.params.exposure = -1; s.render()
        try await Task.sleep(nanoseconds: 1_000_000)
        for value in [0.2, 0.4, 0.6, 0.8] { s.params.exposure = value; s.render() }
        let latest = PreviewFrame.fingerprint(s.params)
        try await wait { !s.previewing && s.previewFrame?.key.paramsFingerprint == latest }
        check(s.previewFrame?.key.paramsFingerprint == latest, "continuous parameter requests finish on the latest matching revision")
        s.params.rotation = 90; s.params.cropX = 0.1; s.params.cropY = 0.2; s.params.cropW = 0.5; s.params.cropH = 0.6; s.render()
        try await wait { !s.previewing }
        let rotated = s.previewFrame!, geometry = Engine.geometry(s.source!, s.params).extent
        check(rotated.editedExtent == geometry && rotated.editedExtent.origin != .zero,
              "rotated offset crops retain the real nonzero output origin")
        let viewport = CGRect(x: 73, y: 51, width: 624, height: 416)
        let rect = DisplayTransform.rect(bitmap: rotated.bitmapSize, in: viewport, fill: false)
        let transform = DisplayTransform(frame: rotated, imageRect: rect, backingScale: 2)
        let point = CGPoint(x: geometry.minX + geometry.width * 0.23, y: geometry.minY + geometry.height * 0.71)
        let inverse = transform.outputPoint(transform.viewPoint(point))!
        check(hypot(inverse.x - point.x, inverse.y - point.y) < 0.000001,
              "output-to-view inverse survives rotation, cropped origin and Retina backing")
        check(transform.normalizedPoint(CGPoint(x: rect.minX + 1, y: rect.minY + 1))!.y > 0.9
              && transform.outputPoint(CGPoint(x: rect.maxX + 10, y: rect.midY)) == nil,
              "view y-down maps to output y-up and off-image samples are rejected")
        let pixelRect = CGRect(x: 0, y: 0, width: CGFloat(rotated.image.width) / 2, height: CGFloat(rotated.image.height) / 2)
        let pixel = DisplayTransform(frame: rotated, imageRect: pixelRect, backingScale: 2)
        check(abs(pixel.screenPixelsPerEditedPixel - 1) < 0.000001, "1:1 uses full output pixels divided by the backing scale")
        s.toggleCropMode()
        try await wait { !s.previewing && s.previewFrame?.key.purpose == .cropReference }
        check(s.previewFrame?.editedExtent == Engine.geometry(s.source!, s.params.cropNeutral).extent,
              "crop reference has its own uncropped geometry domain")
        s.toggleCropMode(); s.showBefore = true
        try await wait { s.beforeFrame != nil && !s.previewing }
        check(s.beforeFrame?.key.purpose == .beforeOriginal && s.beforeFrame?.editedExtent == s.source?.extent,
              "original comparison carries its own source extent rather than the cropped edited transform")
        s.showBefore = false
        var mask = Mask(); mask.kind = .linear; mask.adjust.exposure = 0.3
        s.params.masks = [mask]; s.selectedMask = mask.id; s.showMaskOverlay = true; s.render()
        try await wait { !s.previewing && s.previewFrame?.maskID == mask.id }
        check(s.previewFrame?.mask != nil && s.previewFrame?.mask?.width == s.preview?.width
              && s.previewFrame?.key.paramsFingerprint == PreviewFrame.fingerprint(s.params),
              "mask, edited image, histogram and geometry publish together for the same revision")

        s.startMaskDrawing(.linear, replacing: mask.id)
        var transient = mask; transient.adjust.exposure = 1.2
        s.updateMaskDraft(transient); s.cancelMaskDrawing()
        try await wait { !s.previewing && s.previewFrame?.key.paramsFingerprint == PreviewFrame.fingerprint(s.params) }
        check(s.maskDraft == nil && s.previewFrame?.key.paramsFingerprint == PreviewFrame.fingerprint(s.params),
              "cancelled transient mask work cannot publish a draft over the committed frame")

        var layouts = 0
        for mode in WorkspaceMode.allCases {
            for size in [CGSize(width: 1200, height: 780), CGSize(width: 1440, height: 900), CGSize(width: 1728, height: 1117)] {
                for browser in [false, true] { for inspector in [false, true] {
                    for widths in [(CGFloat(196), CGFloat(300)), (CGFloat(260), CGFloat(364))] {
                        let l = WorkspaceLayout.resolve(size: size, browserVisible: browser, inspectorVisible: inspector,
                                                        mode: mode, browserWidth: widths.0, inspectorWidth: widths.1)
                        precondition(l.safeCanvas.width >= 560 && l.safeCanvas.height >= 420)
                        precondition(l.canvas.origin == .zero && l.canvas.size == size)
                        if browser { precondition(!l.safeCanvas.intersects(l.browser)) }
                        if inspector { precondition(!l.safeCanvas.intersects(l.inspector)) }
                        precondition(!l.rail.intersects(l.inspector) && !l.navigation.intersects(l.actions))
                        layouts += 1
                    }
                } }
            }
        }
        check(layouts == 48, "48 A/B size, visibility and preferred-width layouts retain a 560x420 safe editing viewport")
        let suite = "Phos.WorkspaceR2Test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let preference = WorkspaceSessionState(defaults: defaults)
        preference.mode = .filmstrip; preference.browserVisible = false; preference.browserWidth = 260; preference.inspectorWidth = 364
        let restored = WorkspaceSessionState(defaults: defaults)
        check(restored.mode == .filmstrip && !restored.browserVisible && restored.browserWidth == 260 && restored.inspectorWidth == 364,
              "workspace preferences round-trip independently of photo sidecars")
        preference.viewport.mode = .fit
        preference.mode = .immersive; preference.viewport.mode = .fill
        preference.mode = .filmstrip
        check(preference.viewport.mode == .fit, "each layout restores its own automatic fit or fill viewing preference")
        let small = WorkspaceLayout.resolve(size: CGSize(width: 1200, height: 780), browserWidth: 260, inspectorWidth: 364)
        let large = WorkspaceLayout.resolve(size: CGSize(width: 1728, height: 1117), browserWidth: 260, inspectorWidth: 364)
        check(small.browser.width < large.browser.width && large.browser.width == 260 && large.inspector.width == 304,
              "window constraints shrink actual widths while preserving the user's preferred widths for expansion")

        let session = WorkspaceSessionState(persist: false), model = WorkspaceWindowModel(state: s, session: session)
        let panel = WorkspaceWindowModel.makeFolderPanel(directory: fixtures)
        check(panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection
              && panel.allowedContentTypes.map(\.identifier) == ["public.folder"] && panel.directoryURL == fixtures,
              "folder panel has an explicit folder type, single directory selection and current-folder context")
        let beforeMountRenders = s.workMetrics.snapshot["render"]
        let root = WorkspaceRootView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = root; root.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        check(s.workMetrics.snapshot["render"] == beforeMountRenders, "mounting an active workspace does not request a redundant render")
        session.mode = .filmstrip; root.refresh(); root.layoutSubtreeIfNeeded()
        try await wait { s.items.allSatisfy { $0.thumb != nil } }
        check(s.items.allSatisfy { $0.thumb != nil }, "expanding the filmstrip requests its newly visible thumbnails after native layout")
        session.mode = .immersive; root.refresh(); root.layoutSubtreeIfNeeded()
        let hosts = root.contentHosts.mapValues(ObjectIdentifier.init), previewID = ObjectIdentifier(s.preview!)
        let params = s.params, history = s.history.stack, historyIndex = s.history.index, selectedMask = s.selectedMask, current = s.current?.url
        let counters = s.workMetrics.snapshot
        for index in 0..<20 {
            session.mode = index % 2 == 0 ? .filmstrip : .immersive
            root.refresh(); root.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let switchCountersAfter = s.workMetrics.snapshot
        check(root.contentHosts.mapValues(ObjectIdentifier.init) == hosts && hosts.count == 4,
              "20 A/B switches preserve the same four hosts and a single canvas presenter")
        if ObjectIdentifier(s.preview!) != previewID {
            print("R5 diagnostic: image changed, previewing=\(s.previewing), countersBefore=\(counters), countersAfter=\(switchCountersAfter), paramsSame=\(s.params == params), historySame=\(s.history.stack == history)")
        }
        check(s.params == params && s.history.stack == history && s.history.index == historyIndex
              && s.selectedMask == selectedMask && s.current?.url == current && ObjectIdentifier(s.preview!) == previewID,
              "20 A/B switches preserve current photo, precise parameters, history, mask and published image identity")
        check(["select", "decode", "render", "sidecarWrite"].allSatisfy { s.workMetrics.snapshot[$0] == counters[$0] },
              "20 A/B switches cause zero select, source decode, render and sidecar writes")
        session.viewport.mode = .manual; session.viewport.editedImageCenter = CGPoint(x: 0.3, y: 0.6); session.viewport.screenPixelsPerEditedPixel = 0.7
        session.mode = .filmstrip
        check(session.viewport.mode == .manual && session.viewport.editedImageCenter == CGPoint(x: 0.3, y: 0.6)
              && session.viewport.screenPixelsPerEditedPixel == 0.7, "layout switches retain manual image center and physical pixel scale")

        s.showMaskOverlay = false; s.selectedMask = nil
        let selection = model.selection
        selection.activate(1)
        try await wait { !s.previewing && s.preview != nil }
        let prior = s.current!.url
        s.finishPendingPhotoEdit = { var value = s.params; value.exposure = 1.23; s.commit(value) }
        selection.activate(2)
        try await wait { !s.previewing && s.preview != nil }
        let priorSidecar = try SidecarStore.read(for: prior)
        check(priorSidecar?.params.exposure == 1.23 && s.params.exposure != 1.23,
              "a pending legal numeric draft finishes in the old photo before selecting a new photo")
        selection.activate(4, modifiers: .command)
        check(s.currentIndex == 2 && s.selectedPhotos == [s.items[4].id], "Command multi-selection is distinct from the currently edited photo")
        selection.activate(3)
        selection.activate(6, modifiers: .shift)
        check(s.currentIndex == 6 && s.selectedPhotos == Set((3...6).map { s.items[$0].id }), "Shift selects the visible anchored range and navigates through the same controller")
        s.searchText = "长文件名"
        check(s.visiblePhotoIndices == [5] && s.currentIndex == 6, "search retains a hidden current photo rather than silently changing the edited photo")
        selection.navigate(-1)
        try await wait { !s.previewing && s.preview != nil }
        check(s.currentIndex == 5 && s.visiblePhotoPosition == 1, "navigation from a filtered-out current item selects the correct visible URL")
        s.setRating(4); s.togglePick(); s.filterRating = 4; s.filterPicked = true
        check(s.visiblePhotoIndices == [5], "rating and picked filters share the same collection in both layouts")
        s.searchText = "missing-result"
        selection.navigate(1)
        check(s.visiblePhotoIndices.isEmpty && s.currentIndex == 5, "empty search results do not move or clear the current photo")
        s.searchText = ""; s.filterPicked = false; s.filterRating = 0
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        let unchanged = s.currentIndex
        check(!selection.handleKey(event, firstResponder: NSTextView()) && s.currentIndex == unchanged,
              "text input focus consumes navigation keys without selecting another photo")
        let modeActions = ModeActions()
        let modeControl = WorkspaceModeSwitch(labels: ["A 沉浸", "B 选片"], target: modeActions, action: #selector(ModeActions.changed(_:)))
        modeControl.frame = CGRect(x: 0, y: 0, width: 156, height: 28)
        window.contentView?.addSubview(modeControl); modeControl.layoutSubtreeIfNeeded()
        let segments = modeControl.subviews.compactMap { $0 as? WorkspaceModeSegmentButton }
        check(modeControl.accessibilityRole() == .radioGroup && segments.count == 2
              && segments.allSatisfy { $0.accessibilityRole() == .radioButton },
              "custom A/B control retains a radio group and two named radio buttons")
        check(segments.map { $0.accessibilityLabel() ?? "" } == ["A 沉浸", "B 选片"]
              && segments[0].state == .on && segments[1].state == .off,
              "layout radio labels and mutually exclusive values survive custom rendering")
        segments[0].performClick(nil)
        check(modeActions.count == 0 && segments[0].state == .on,
              "pressing the selected layout preserves its radio value without redundant actions")
        check(window.makeFirstResponder(segments[0]) && segments[0].acceptsFirstResponder && !segments[1].acceptsFirstResponder,
              "keyboard traversal enters the selected radio instead of adding two tab stops")
        check(!selection.handleKey(event, firstResponder: segments[0]) && s.currentIndex == unchanged,
              "a layout radio owns its arrows without navigating or editing the current photo")
        segments[0].keyDown(with: event)
        check(modeControl.selectedSegment == 1 && modeActions.count == 1 && window.firstResponder === segments[1]
              && segments[0].state == .off && segments[1].state == .on,
              "arrow navigation changes layout once and transfers keyboard focus with the selected radio")
        segments[1].keyDown(with: event)
        check(modeControl.selectedSegment == 1 && modeActions.count == 1,
              "arrow navigation at the final radio is bounded and emits no duplicate action")
        modeControl.selectedSegment = 0
        check(window.firstResponder === segments[0] && segments[0].state == .on && segments[1].state == .off,
              "external layout changes keep focus and radio values on the active segment")
        let lastRadio = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 119)!
        segments[0].keyDown(with: lastRadio)
        check(modeControl.selectedSegment == 1 && window.firstResponder === segments[1],
              "End selects the final radio even when the control contains a glass decoration")
        let highlight = modeControl.subviews.first { !($0 is NSButton) }!
        check(highlight.layer?.animation(forKey: "layoutTravel") != nil
              && highlight.layer?.animation(forKey: "layoutSwellx") != nil,
              "layout selection schedules a moving glass capsule with elastic expansion")
        let sameAnimation = highlight.layer?.animation(forKey: "layoutTravel")?.beginTime
        modeControl.selectedSegment = 1; modeControl.layoutSubtreeIfNeeded()
        check(highlight.layer?.animation(forKey: "layoutTravel")?.beginTime == sameAnimation,
              "unrelated layout refreshes do not restart or cancel the active transition")
        modeControl.refreshSurface(options: WorkspaceAccessibilityOptions(reduceMotion: true), disableNativeGlass: false)
        modeControl.selectedSegment = 0
        check(highlight.layer?.animationKeys()?.isEmpty != false && highlight.frame.minX == 2,
              "Reduce Motion cancels travel and expansion and immediately selects the correct capsule")
        modeControl.refreshSurface(options: WorkspaceAccessibilityOptions(reduceTransparency: true), disableNativeGlass: false)
        func glassViews(_ view: NSView) -> Int {
            (view is NSGlassEffectView ? 1 : 0) + view.subviews.reduce(0) { $0 + glassViews($1) }
        }
        check(glassViews(modeControl) == 0 && segments[0].state == .on && segments[1].state == .off,
              "Reduce Transparency removes glass without changing radio selection or controls")
        modeControl.removeFromSuperview(); window.makeFirstResponder(nil)
        s.pendingPhotoEditID = UUID()
        check(!selection.handleKey(event, firstResponder: NSResponder()) && s.currentIndex == unchanged,
              "a numeric draft awaiting native focus also blocks navigation and rating shortcuts")
        s.pendingPhotoEditID = nil
        selection.selectAllVisible()
        check(s.selectedPhotos.count == s.visiblePhotoIndices.count, "select-all is restricted to the visible filtered collection")
        let damaged = s.items[11].url, sidecar = SidecarStore.url(for: damaged), bytes = Data("{broken-sidecar".utf8)
        try bytes.write(to: sidecar)
        selection.activate(11)
        let damagedBeforeLeave = try Data(contentsOf: sidecar)
        check(s.source == nil && s.workflowError != nil && damagedBeforeLeave == bytes,
              "a damaged sidecar is surfaced and is never overwritten by selection")
        selection.activate(10)
        try await wait { !s.previewing && s.preview != nil }
        let damagedAfterLeave = try Data(contentsOf: sidecar)
        check(damagedAfterLeave == bytes && s.currentIndex == 10, "leaving a damaged photo safely restores navigation without replacing its edit file")
        window.contentView = nil

        let thumbnails = AppState()
        thumbnails.currentIndex = -1
        thumbnails.items = s.items + (12..<1000).map { PhotoItem(url: fixtures.appendingPathComponent("unseen-\($0).png")) }
        let visible = Set(thumbnails.items[2...5].map(\.id))
        thumbnails.requestThumbnails(Set(thumbnails.items[0...1].map(\.id)))
        thumbnails.requestThumbnails(visible)
        try await wait { thumbnails.thumbnailActiveCount == 0 && thumbnails.items[2...5].allSatisfy { $0.thumb != nil } }
        check(thumbnails.workMetrics.snapshot["thumbnail"]! <= 6 && thumbnails.thumbnailCacheCount <= 6,
              "a 1000-item collection decodes only visible demand plus at most two already-running requests")
        check(thumbnails.items.enumerated().allSatisfy { $0.element.thumb == nil || visible.contains($0.element.id) },
              "obsolete thumbnail replies never reattach to items outside the latest visible demand")
        check(thumbnails.items[999].thumb == nil && thumbnails.thumbnailFailures.isEmpty,
              "offscreen nonexistent files are neither decoded nor reported as visible failures")
        let report: [String: Any] = ["status": "passed", "shellChecks": shellChecks, "r2Checks": checks, "checks": checks + shellChecks,
                                    "layoutCases": layouts + 24, "workspaceSwitches": 20, "sameCanvasHosts": true,
                                    "switchCountersBefore": counters, "switchCountersAfter": switchCountersAfter,
                                    "switchWorkInvariant": true, "largeCollectionItems": 1000]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS R2 workspace: \(checks + shellChecks) checks, \(layouts + 24) layouts")
    }
}
