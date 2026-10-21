#if PHOS_QA
import AppKit
import CryptoKit

/// Diagnostics from the actual editor tree, excluded from production builds.
@MainActor
final class WorkspaceQARecorder: NSObject {
    private weak var root: WorkspaceRootView?
    private var timer: Timer?
    private var last = Data()
    private var sequence = 0
    private let runID = UUID().uuidString
    init(root: WorkspaceRootView) {
        self.root = root
        super.init()
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(record), userInfo: nil, repeats: true)
    }
    private func count(_ view: NSView, matching: (NSView) -> Bool) -> Int {
        (matching(view) ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1, matching: matching) }
    }
    @objc private func record() {
        guard !WorkspaceReviewBench.running else { return }
        guard let root else { timer?.invalidate(); timer = nil; return }
        guard let window = root.window else { return }
        let s = root.model.state, a = root.model.environment.accessibility
        var data = root.shellDiagnostics
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let params = (try? encoder.encode(s.params)) ?? Data()
        data["paramsSHA256"] = SHA256.hash(data: params).map { String(format: "%02x", $0) }.joined()
        data["photo"] = s.current?.url.path ?? ""
        data["historyIndex"] = s.history.index; data["historyCount"] = s.history.stack.count
        data["selectedMask"] = s.selectedMask?.uuidString ?? ""
        data["previewID"] = s.preview.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        data["sourceID"] = s.source.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        if let frame = s.displayFrame {
            data["framePhotoID"] = frame.key.photoID.uuidString; data["frameRevision"] = frame.key.revision
            data["framePurpose"] = frame.key.purpose.rawValue; data["frameFingerprint"] = frame.key.paramsFingerprint
            data["frameExtent"] = NSStringFromRect(frame.editedExtent); data["frameBitmap"] = NSStringFromSize(frame.bitmapSize)
            data["frameFullResolution"] = frame.fullResolution
        }
        data["inspectorCategory"] = s.inspectorUI.category.rawValue
        data["expandedGroups"] = s.inspectorUI.expanded
        data["curveChannel"] = s.inspectorUI.curveChannel
        data["parameterInputGeneration"] = s.parameterInputGeneration
        data["parameterEditing"] = s.parameterEdits.token != nil
        data["exportSettings"] = (try? JSONSerialization.jsonObject(with:encoder.encode(s.exportSettings))) ?? [:]
        data["snapshotNames"] = s.snapshots.map(\.name)
        data["visiblePhotos"] = s.visiblePhotoIndices.count
        data["filterRating"] = s.filterRating; data["filterPicked"] = s.filterPicked; data["searchText"] = s.searchText
        data["selection"] = s.selectedPhotos.map(\.uuidString).sorted()
        data["oneToOne"] = s.oneToOne; data["status"] = s.status
        data["cropSession"] = s.cropSession != nil; data["splitComparison"] = s.splitComparison
        data["maskDrawingKind"] = s.maskDrawingKind?.rawValue ?? "none"
        data["maskTool"] = s.maskTool.rawValue
        data["maskCount"] = s.params.masks.count; data["maskNames"] = s.params.masks.map(\.name)
        data["strokeCount"] = s.params.masks.map { $0.strokes.count+$0.refinements.count }
        data["temporaryPan"] = s.temporaryPan
        data["jobRunning"] = s.jobRunning; data["jobFailures"] = s.jobFailures
        data["batchProgress"] = s.batchProgress; data["syncProgress"] = s.syncProgress
        data["viewportCenter"] = [root.model.session.viewport.editedImageCenter.x,root.model.session.viewport.editedImageCenter.y]
        data["viewportScale"] = root.model.session.viewport.screenPixelsPerEditedPixel
        data["geometryBeforeRevision"] = s.geometryBeforeFrame?.key.revision ?? 0
        data["previewing"] = s.previewing; data["photoCount"] = s.items.count
        data["sheet"] = root.model.router.presented?.rawValue ?? "none"
        data["pendingSheets"] = root.model.router.pending.map(\.rawValue)
        if let panel = root.model.folderPanel {
            data["folderPanel"] = ["directories": panel.canChooseDirectories, "files": panel.canChooseFiles,
                                   "multiple": panel.allowsMultipleSelection,
                                   "types": panel.allowedContentTypes.map(\.identifier),
                                   "directory": panel.directoryURL?.path ?? "",
                                   "selection": panel.urls.map(\.path)] as [String: Any]
        }
        data["windowKey"] = window.isKeyWindow
        data["fullScreen"] = window.styleMask.contains(.fullScreen)
        data["windowFrame"] = NSStringFromRect(window.frame); data["contentBounds"] = NSStringFromRect(root.bounds)
        data["topInset"] = WorkspaceWindowChrome.topInset(in: root)
        data["appearance"] = root.effectiveAppearance.name.rawValue
        data["appearancePreference"] = UserDefaults.standard.string(forKey: "rf.appearance") ?? "system"
        data["reduceMotion"] = a.reduceMotion; data["reduceTransparency"] = a.reduceTransparency; data["increaseContrast"] = a.increaseContrast
        data["emergencyDisabled"] = root.model.environment.disableNativeGlass
        data["glassCount"] = count(root) { $0 is NSGlassEffectView }
        data["visualEffectCount"] = count(root) { $0 is NSVisualEffectView }
        data["firstResponderID"] = window.firstResponder.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        data["firstResponder"] = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        if let editor = window.firstResponder as? NSTextView {
            data["draft"] = editor.string; data["textSelection"] = NSStringFromRange(editor.selectedRange())
        }
        data["titleDragRequests"] = root.titleDrag.nativeDragRequestCount
        data["titleDragEvents"] = root.titleDrag.dragEventCount
        data["trafficLights"] = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> [String: Any]? in
            guard let button = window.standardWindowButton(kind) else { return nil }
            return ["kind": kind.rawValue, "frame": NSStringFromRect(button.convert(button.bounds, to: root)), "visible": !button.isHidden]
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), encoded != last else { return }
        last = encoded; sequence += 1
        data["sequence"] = sequence; data["runID"] = runID
        data["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let folder = QAWorkspace.root.appendingPathComponent("reports/workspace-\(runID)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: folder.appendingPathComponent(String(format: "%04d.json", sequence)), options: .atomic)
            try? json.write(to: folder.deletingLastPathComponent().appendingPathComponent("workspace-current.json"), options: .atomic)
        }
    }
}
#endif
