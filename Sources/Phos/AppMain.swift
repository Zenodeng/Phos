import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import ImageIO

struct PhotoItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var rating: Int = 0
    var picked: Bool = false
    var thumb: CGImage?
}

@MainActor
final class AppState: ObservableObject {
    // 浏览器
    @Published var folder: URL?
    @Published var items: [PhotoItem] = []
    @Published var currentIndex: Int = 0
    @Published var filterRating: Int = 0
    @Published var filterPicked = false
    @Published var searchText = ""
    @Published var folderLoading = false
    @Published var folderFailure: String?
    @Published var thumbnailFailures: Set<UUID> = []
    let workMetrics = WorkspaceWorkMetrics()
    var finishPendingPhotoEdit: (() -> Void)?
    @Published var pendingPhotoEditID: UUID?
    @Published var parameterInputGeneration: UInt = 0
    lazy var parameterEdits = ParameterEditCoordinator(state:self)
    let inspectorUI = WorkspaceInspectorState()
    private var savedSidecarFingerprint: Data?
    var visiblePhotoIndices: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.indices.filter {
            (filterRating == 0 || items[$0].rating >= filterRating) &&
            (!filterPicked || items[$0].picked) &&
            (query.isEmpty || items[$0].url.lastPathComponent.localizedStandardContains(query))
        }
    }
    var previousVisiblePhotoIndex: Int? {
        visiblePhotoIndices.last { $0 < currentIndex }
    }
    var nextVisiblePhotoIndex: Int? {
        visiblePhotoIndices.first { $0 > currentIndex }
    }
    var visiblePhotoPosition: Int? {
        visiblePhotoIndices.firstIndex(of: currentIndex).map { $0 + 1 }
    }
    @Published var selectedPhotos: Set<UUID> = []
    @Published var showSync = false
    @Published var showSnapshots = false
    @Published var syncRunning = false
    @Published var copiedParams: EditParams?
    @Published var copiedName = ""
    @Published var syncGroups = EditGroup.defaults
    @Published var snapshots: [EditSnapshot] = []
    @Published var workflowError: String?
    @Published var whiteBalancePicker = false
    @Published var whiteBalanceRunning = false
    // 自动影调：分析一次拿到 solution，强度滑杆按增量在此之上加减
    @Published var showPhotoAI = false
    @Published var autoRunning = false
    @Published var autoStrength: Double = 1
    @Published var autoSolution: AutoTone.Solution?
    /// 识别到的场景。留着给 UI 显示，用户不认同可以直接从菜单里换一个重跑。
    @Published var autoScene: SceneGuess?
    @Published var showMaskOverlay = false {
        didSet { if oldValue != showMaskOverlay { previewQueue.invalidate(); render() } }
    }
    @Published var maskTool: MaskTool = .position
    @Published var brushRadius: Double = 0.05
    @Published var brushFeather: Double = 0.5
    var maskPreviewImage: CGImage? { previewFrame?.mask }
    // A gradient is a transient draft until mouse-up: no sidecar writes or undo steps while drawing.
    @Published var maskDrawingKind: MaskKind?
    @Published var maskDrawingTarget: UUID?
    @Published var maskDraft: Mask?
    private var sidecarReadFailed = false

    // 编辑
    @Published var params = EditParams()
    @Published var source: CIImage?
    @Published private(set) var previewFrame: PreviewFrame?
    @Published private(set) var beforeFrame: PreviewFrame?
    var preview: CGImage? { previewFrame?.image }
    @Published var previewing: Bool = false
    @Published var showBefore: Bool = false {
        didSet { if showBefore { cancelMaskDrawing(); refreshBefore() } }
    }
    var beforeImage: CGImage? { beforeFrame?.image }
    var displayFrame: PreviewFrame? { showBefore ? beforeFrame : previewFrame }
    var hist: PreviewFrame.Histogram { displayFrame?.histogram ?? ([], [], [], []) }
    @Published var status: String = "准备就绪"
    @Published var selectedMask: UUID? {
        willSet { if newValue != selectedMask { parameterEdits.finishCurrent() } }
        didSet {
            if oldValue != selectedMask {
                cancelMaskDrawing()
                maskTool = .position
                previewQueue.invalidate()
                render()
            }
        }
    }
    @Published var zoom: Double = 1
    @Published var canvasResetID = UUID()
    @Published var cropMode = false   // 裁剪模式：画布显示未裁剪图 + 裁剪框

    // 预览精度：默认走 2200px 代理图求快；打开后走全像素
    @Published var fullResPreview: Bool = false {
        didSet { if oldValue != fullResPreview { previewQueue.invalidate(); render() } }
    }
    @Published var oneToOne: Bool = false {
        didSet { if oldValue != oneToOne { previewQueue.invalidate(); render(); if showBefore { refreshBefore() } } }
    }
    @Published var sourceSize: CGSize = .zero
    var lastPreviewScale: Double { Double(previewFrame?.proxyScale ?? 1) }

    // 导出
    @Published var exportSettings = ExportSettings()
    @Published var showExport = false
    @Published var showBatch = false
    @Published var exportRunning = false
    @Published var batchRunning = false
    @Published var batchProgress: Double = 0

    // 多重曝光合成
    @Published var showMerge = false
    @Published var mergeMode: MergeMode = .fusion
    @Published var mergeRunning = false
    @Published var mergeProgress: String = ""
    @Published var alignEnabled = true        // 合成前先做帧对齐
    @Published var alignMethod: AlignMethod = .translation

    // 当前照片是否带人像深度辅助数据
    @Published var hasDisparity = false

    // 版本更新：启动时静默查一次，有新版才在工具栏显示提示图标
    @Published var availableUpdate: UpdateInfo?
    @Published var showUpdateResult = false
    private var didCheckForUpdates = false

    let history = History()
    let cluts = CLUTLibrary.shared

    private lazy var thumbnails = WorkspaceThumbnailScheduler(metrics: workMetrics) { [weak self] url, image in
        guard let self, let index = items.firstIndex(where: { $0.url == url }) else { return }
        if let image { items[index].thumb = image; thumbnailFailures.remove(items[index].id) }
        else { thumbnailFailures.insert(items[index].id) }
    }
    var thumbnailCacheCount: Int { thumbnails.cachedCount }
    var thumbnailActiveCount: Int { thumbnails.activeCount }
    private var previewRevision: UInt64 = 0
    private var expectedPreview: PreviewFrameKey?
    private var expectedBefore: PreviewFrameKey?
    private let sourceCache = BoundedCache<URL, CIImage>(capacity: 3)
    private let previewLongEdge: CGFloat = 2200
    private struct PhotoLoad {
        let url: URL
        let cached: CIImage?
    }
    private struct PreviewRequest {
        let key: PreviewFrameKey
        let source: CIImage
        let params: EditParams
        let url: URL?
        let fullResolution: Bool
        let cropMode: Bool
        let longEdge: CGFloat
        let overlayMask: UUID?
    }
    private lazy var folderQueue = LatestWorkQueue<URL, [PhotoItem]?>(
        priority: .userInitiated,
        operation: { url in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil) else { return nil }
            return files.filter { Engine.browseSet.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { url in
                    var item = PhotoItem(url: url)
                    if let sidecar = SidecarStore.load(for: url) {
                        item.rating = sidecar.rating
                        item.picked = sidecar.picked
                    }
                    return item
                }
        },
        completion: { [weak self] url, result in
            guard let self, self.folder == url else { return }
            self.folderLoading = false
            guard let result else { self.status = "无法读取文件夹"; self.folderFailure = self.status; return }
            self.items = result
            self.status = result.isEmpty ? "文件夹里没有支持的图像" : "共 \(result.count) 张"
            if !result.isEmpty { self.select(0) }
            self.loadThumbnails()
        })
    private lazy var sourceQueue = LatestWorkQueue<PhotoLoad, (CIImage?, Bool)>(
        operation: { [workMetrics] request in
            if request.cached == nil { workMetrics.increment("decode") }
            return (request.cached ?? Engine.decode(request.url), Engine.hasDisparity(request.url))
        },
        completion: { [weak self] request, result in
            guard let self, self.current?.url == request.url else { return }
            self.source = result.0
            self.sourceSize = result.0?.extent.size ?? .zero
            self.hasDisparity = result.1
            self.sourceCache[request.url] = result.0
            if result.0 == nil {
                self.previewing = false
                self.status = "无法解码 \(request.url.lastPathComponent)"
                return
            }
            self.render()
            if self.showBefore { self.refreshBefore() }
        })
    private lazy var previewQueue: LatestWorkQueue<PreviewRequest, PreviewFrame?> = LatestWorkQueue(
        operation: { [workMetrics] request in
            workMetrics.increment("render")
            return Self.makePreview(request)
        },
        completion: { [weak self] request, result in
            guard let self else { return }
            guard request.key == expectedPreview, request.key.photoID == current?.id,
                  request.cropMode == cropMode,
                  request.fullResolution == (fullResPreview || oneToOne) else {
                workMetrics.increment("staleFrameRejected"); return
            }
            if let result { previewFrame = result }
            else { status = "预览生成失败，请重试或选择其他照片" }
            previewing = previewQueue.hasPendingWork
        })
    private struct BeforeRequest { let source: CIImage; let key: PreviewFrameKey; let fullResolution: Bool }
    private lazy var beforeQueue = LatestWorkQueue<BeforeRequest, PreviewFrame?>(
        operation: { [workMetrics] request in
            workMetrics.increment("before")
            let image = request.source
            let scale: CGFloat = request.fullResolution ? 1 : min(1, 2200 / max(image.extent.width, image.extent.height))
            let base = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let bitmap = Engine.ctx.createCGImage(base, from: base.extent, format: .RGBA8, colorSpace: Engine.srgb) else { return nil }
            return PreviewFrame(key: request.key, image: bitmap, mask: nil, maskID: nil,
                                histogram: Engine.histogram(CIImage(cgImage: bitmap)), renderExtent: base.extent,
                                editedExtent: image.extent, proxyScale: scale, fullResolution: scale == 1)
        },
        completion: { [weak self] request, result in
            guard let self, request.key == expectedBefore, request.key.photoID == current?.id else { return }
            beforeFrame = result
        })

    var current: PhotoItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    // MARK: - 打开文件夹
    func openFolder(_ requestedURL: URL) {
        guard !syncRunning, saveCurrent() else { return }
        #if PHOS_QA
        let url: URL
        do {
            url = try QAWorkspace.scope.importFolder(requestedURL, extensions: Engine.browseSet)
        } catch {
            workflowError = "QA 素材复制失败，未打开原目录。\n\(error.localizedDescription)"
            return
        }
        #else
        let url = requestedURL
        #endif
        cancelMaskDrawing()
        folderQueue.invalidate()
        sourceQueue.invalidate()
        previewQueue.invalidate()
        beforeQueue.invalidate()
        thumbnails.reset()
        currentIndex = -1
        source = nil
        previewFrame = nil
        beforeFrame = nil
        expectedPreview = nil; expectedBefore = nil
        sourceSize = .zero
        hasDisparity = false
        previewing = false
        items = []
        selectedPhotos = []
        snapshots = []
        selectedMask = nil
        whiteBalancePicker = false
        clearAutoTone()
        sourceCache.removeAll()
        folder = url
        folderLoading = true; folderFailure = nil; thumbnailFailures = []; savedSidecarFingerprint = nil
        status = "正在读取文件夹…"
        folderQueue.submit(url)
    }

    private func loadThumbnails() {
        requestThumbnails(Set(items.prefix(18).map(\.id)))
    }
    func requestThumbnails(_ ids: Set<UUID>) {
        let demand = items.filter { ids.contains($0.id) }
        thumbnails.request(demand.map(\.url))
        // The source model never retains an unbounded set of decoded thumbnails.
        var updated = items, changed = false
        for index in updated.indices {
            let image = ids.contains(updated[index].id) ? thumbnails.image(for: updated[index].url) : nil
            if updated[index].thumb !== image { updated[index].thumb = image; changed = true }
        }
        if changed { items = updated }
    }

    nonisolated static func thumb(for url: URL) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL,
                                                  [kCGImageSourceShouldCache: false] as CFDictionary),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 260,
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            return thumbnail
        }
        guard let ci = Engine.decode(url) else { return nil }
        let e = ci.extent
        let s = min(1, 260 / max(e.width, e.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return Engine.ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: Engine.srgb)
    }

    // MARK: - 选图
    @discardableResult func select(_ i: Int) -> Bool {
        guard !syncRunning, i >= 0, i < items.count else { return false }
        guard i != currentIndex || source == nil else { return true }
        let finish = finishPendingPhotoEdit; finishPendingPhotoEdit = nil; pendingPhotoEditID = nil; finish?()
        guard saveCurrent() else { return false }
        workMetrics.increment("select")
        cancelMaskDrawing()
        sourceQueue.invalidate()
        previewQueue.invalidate()
        beforeQueue.invalidate()
        currentIndex = i
        let u = items[i].url
        source = nil
        previewFrame = nil
        beforeFrame = nil
        expectedPreview = nil; expectedBefore = nil
        sourceSize = .zero
        previewing = true
        hasDisparity = false
        whiteBalancePicker = false
        clearAutoTone()
        sidecarReadFailed = false
        params = EditParams(); history.stack = []; history.index = -1
        do {
            let sc = try SidecarStore.read(for: u)
            params = sc?.params ?? EditParams()
            snapshots = sc?.snapshots ?? []
            if let sc { items[i].rating = sc.rating; items[i].picked = sc.picked }
            savedSidecarFingerprint = sidecarFingerprint()
        } catch {
            sidecarReadFailed = true
            snapshots = []
            selectedMask = nil
            previewing = false
            workflowError = "无法读取 \(u.lastPathComponent) 的编辑记录，原文件未修改。\n\(error.localizedDescription)"
            return false
        }
        history.stack = [params]; history.index = 0
        selectedMask = nil
        sourceQueue.submit(PhotoLoad(url: u, cached: sourceCache[u]))
        return true
    }

    // MARK: - 参数改动
    func commit(_ p: EditParams) {
        guard !syncRunning else { return }
        parameterEdits.invalidate()
        params = p
        history.push(p)
        render()
        autoSave()
    }

    func undo() {
        guard !syncRunning else { return }
        parameterEdits.invalidate()
        if maskDrawingKind != nil { cancelMaskDrawing(); return }
        if let p = history.undo() { params = p; render(); autoSave() }
    }
    func redo() {
        guard !syncRunning else { return }
        parameterEdits.invalidate()
        if let p = history.redo() { params = p; render(); autoSave() }
    }

    func autoSave() { saveCurrent() }

    /// 检查更新。
    ///
    /// `silent` 为 true 时用于启动时的静默检查：每次运行只跑一次，且只有真的发现新版本
    /// 才会在工具栏冒出提示图标，没有更新就什么都不做。
    /// 手动点「检查更新…」时传 false，无论有没有更新都会弹一个结果。
    func checkForUpdates(silent: Bool) {
        if silent {
            guard !didCheckForUpdates else { return }
            didCheckForUpdates = true
        }
        Task { [weak self] in
            let info = await UpdateChecker.check()
            await MainActor.run {
                guard let self else { return }
                self.availableUpdate = info
                if !silent { self.showUpdateResult = true }
            }
        }
    }

    /// 打开官网下载页（提示图标和更新结果弹窗共用）
    func openUpdatePage() {
        guard let page = availableUpdate?.page, let url = URL(string: page) else { return }
        NSWorkspace.shared.open(url)
    }

    private func sidecarFingerprint() -> Data? {
        guard let it = current else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Sidecar(params: params, rating: it.rating, picked: it.picked, snapshots: snapshots))
    }
    @discardableResult
    func saveCurrent() -> Bool {
        guard !sidecarReadFailed, let it = current else { return true }
        let fingerprint = sidecarFingerprint()
        if fingerprint != nil, fingerprint == savedSidecarFingerprint { return true }
        let sc = Sidecar(params: params, rating: it.rating, picked: it.picked, snapshots: snapshots)
        do {
            try SidecarStore.write(sc, for: it.url)
            workMetrics.increment("sidecarWrite"); savedSidecarFingerprint = fingerprint
            return true
        } catch {
            workflowError = "编辑记录保存失败：\(it.url.lastPathComponent)\n\(error.localizedDescription)"
            return false
        }
    }

    func setRating(_ r: Int) {
        guard current != nil, !sidecarReadFailed, !syncRunning else { return }
        items[currentIndex].rating = min(max(r, 0), 5)
        saveCurrent()
    }
    func togglePick() {
        guard current != nil, !sidecarReadFailed, !syncRunning else { return }
        items[currentIndex].picked.toggle()
        saveCurrent()
    }

    // MARK: - 裁剪模式辅助
    func toggleCropMode() {
        guard source != nil else { return }
        cancelMaskDrawing()
        if !cropMode { oneToOne = false; showBefore = false; whiteBalancePicker = false }
        previewQueue.invalidate()
        cropMode.toggle()
        if cropMode { selectedMask = nil; render() } else { endEdit(); render() }
    }

    /// 画幅比例预设：保持中心，调整裁剪框的宽高比（ratio = 宽/高，nil = 自由）
    func applyCropAspect(_ ratio: Double?) {
        guard let ratio = ratio else { s_endEditNoop(); return }
        let iw = Double(preview?.width ?? 1), ih = Double(preview?.height ?? 1)
        guard iw > 0, ih > 0 else { return }
        var cw = params.cropW
        let pixelW = cw * iw
        var ch = (pixelW / ratio) / ih
        if ch > 1 { ch = 1; cw = min(1, (ch * ih * ratio) / iw) }
        let cx = params.cropX + (params.cropW - cw) / 2
        let cy = params.cropY + (params.cropH - ch) / 2
        set(\.cropX, min(max(cx, 0), 1 - cw))
        set(\.cropY, min(max(cy, 0), 1 - ch))
        set(\.cropW, cw)
        set(\.cropH, ch)
        endEdit()
    }
    private func s_endEditNoop() {}

    /// 地平线自动校直：Vision 检测倾角 → 反向旋转 + 最大内接矩形裁切
    func autoStraighten() {
        guard let src = source else { return }
        let photoID = current?.id
        status = "检测地平线…"
        Task {
            let angle = await Task.detached { Engine.autoStraightenAngle(from: src) }.value
            guard current?.id == photoID else { return }
            guard var a = angle else {
                await MainActor.run { status = "未检测到地平线" }
                return
            }
            a = min(max(a, -15), 15)
            await MainActor.run {
                set(\.straighten, a)
                // 旋转后画幅外接框尺寸
                let rad = abs(a) * .pi / 180
                let cw = src.extent.width * CGFloat(cos(rad)) + src.extent.height * CGFloat(sin(rad))
                let chh = src.extent.width * CGFloat(sin(rad)) + src.extent.height * CGFloat(cos(rad))
                let ins = Engine.inscribedCrop(canvasW: cw, canvasH: chh, angleDeg: a)
                set(\.cropX, ins.x); set(\.cropY, ins.y)
                set(\.cropW, ins.w); set(\.cropH, ins.h)
                endEdit()
                status = String(format: "地平线校直 %.1f°，已按最大内接矩形裁切", a)
            }
        }
    }

    // MARK: - 渲染
    func render() {
        guard let src = source else { return }
        previewing = true
        // 裁剪模式下预览未裁剪的整幅（裁剪框叠加层直接在画布上改），退出后恢复
        submitPreview(source: src, parameters: cropMode ? params.cropNeutral : params,
                      mask: showMaskOverlay && !cropMode ? selectedMask : nil)
    }

    private func submitPreview(source: CIImage, parameters: EditParams, mask: UUID?) {
        guard let photoID = current?.id else { return }
        previewRevision &+= 1
        let key = PreviewFrameKey(photoID: photoID, revision: previewRevision,
                                  purpose: cropMode ? .cropReference : .edited,
                                  paramsFingerprint: PreviewFrame.fingerprint(parameters))
        expectedPreview = key
        previewQueue.submit(PreviewRequest(key: key, source: source, params: parameters,
                                           url: current?.url, fullResolution: fullResPreview || oneToOne,
                                           cropMode: cropMode, longEdge: previewLongEdge, overlayMask: mask))
    }
    nonisolated private static func makePreview(_ request: PreviewRequest) -> PreviewFrame? {
        let src = request.source, p = request.params, e = src.extent
        let scale: CGFloat = request.fullResolution ? 1 : min(1, request.longEdge / max(e.width, e.height))
        let base = scale < 1 ? src.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : src
        var disparity: CIImage?
        if !request.cropMode, p.bokehAmount > 0,
           !p.masks.contains(where: { $0.kind == .depth && $0.enabled }), let url = request.url {
            disparity = Engine.disparityBokehMask(for: url, target: base.extent)
        }
        var mask: CIImage?
        let out = Engine.render(base, p, disparityMask: disparity, selectedMask: request.overlayMask) { mask = $0 }
        guard let image = Engine.ctx.createCGImage(out, from: out.extent, format: .RGBA8,
                                                   colorSpace: Engine.srgb) else { return nil }
        // Histogram the displayed pixels without evaluating the RAW/filter graph a second time.
        let histogram = Engine.histogram(CIImage(cgImage: image))
        let maskCG = mask.flatMap { Engine.ctx.createCGImage($0, from: out.extent, format: .RGBA8, colorSpace: Engine.srgb) }
        return PreviewFrame(key: request.key, image: image, mask: maskCG, maskID: request.overlayMask,
                            histogram: histogram, renderExtent: out.extent,
                            editedExtent: out.extent.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)),
                            proxyScale: scale, fullResolution: request.fullResolution || scale == 1)
    }

    func refreshBefore() {
        guard let src = source, let photoID = current?.id else { return }
        if beforeFrame?.key.photoID == photoID, !oneToOne || beforeFrame?.fullResolution == true { return }
        previewRevision &+= 1
        let key = PreviewFrameKey(photoID: photoID, revision: previewRevision, purpose: .beforeOriginal, paramsFingerprint: "original")
        expectedBefore = key
        beforeQueue.submit(BeforeRequest(source: src, key: key, fullResolution: oneToOne))
    }

    // MARK: - 蒙版
    func startMaskDrawing(_ kind: MaskKind, replacing id: UUID? = nil) {
        guard source != nil, !syncRunning, kind == .linear || kind == .radial else { return }
        selectedMask = id
        cropMode = false
        showBefore = false
        whiteBalancePicker = false
        maskTool = .position
        maskDrawingTarget = id
        maskDrawingKind = kind
        maskDraft = nil
        showMaskOverlay = true
        status = "在画布上拖动绘制\(kind.label)，松手确认；Esc 取消"
    }

    func cancelMaskDrawing() {
        let hadDraft = maskDraft != nil
        maskDrawingKind = nil
        maskDrawingTarget = nil
        maskDraft = nil
        if hadDraft { previewQueue.invalidate(); render() }
    }

    func updateMaskDraft(_ draft: Mask) {
        guard maskDrawingKind != nil else { return }
        maskDraft = draft
        renderDraft(draft)
    }

    private func renderDraft(_ draft: Mask) {
        guard let source else { return }
        var draftParams = params
        if let index = draftParams.masks.firstIndex(where: { $0.id == draft.id }) {
            draftParams.masks[index] = draft
        } else {
            draftParams.masks.append(draft)
        }
        previewing = true
        submitPreview(source: source, parameters: draftParams, mask: showMaskOverlay ? draft.id : nil)
    }

    func finishMaskDrawing() {
        guard let draft = maskDraft, maskDrawingKind != nil else { cancelMaskDrawing(); return }
        var next = params
        if let id = maskDrawingTarget, let index = next.masks.firstIndex(where: { $0.id == id }) {
            next.masks[index] = draft
        } else {
            next.masks.append(draft)
        }
        cancelMaskDrawing()
        commit(next)
        selectedMask = draft.id
        maskTool = .position
        status = "已绘制\(draft.kind.label)；拖中心移动，拖边界缩放，拖旋转柄改变方向"
    }

    func duplicateMask(_ id: UUID) {
        guard let original = params.masks.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name += " 副本"
        var next = params
        next.masks.append(copy)
        commit(next)
        selectedMask = copy.id
        maskTool = .position
    }

    func addMask(_ kind: MaskKind) {
        var m = Mask()
        m.kind = kind
        m.name = kind.label
        var p = params
        p.masks.append(m)
        selectedMask = m.id
        maskTool = .position
        commit(p)
    }
    func updateMask(_ m: Mask) {
        var p = params
        if let i = p.masks.firstIndex(where: { $0.id == m.id }) { p.masks[i] = m }
        commit(p)
    }
    /// 拖动过程中的高频更新：只渲染，不进历史栈（否则拖一下就刷爆撤销栈）
    func updateMaskLive(_ m: Mask) {
        var p = params
        if let i = p.masks.firstIndex(where: { $0.id == m.id }) { p.masks[i] = m }
        params = p
        render()
    }
    func removeMask(_ id: UUID) {
        var p = params
        p.masks.removeAll { $0.id == id }
        if selectedMask == id { selectedMask = nil }
        commit(p)
    }

    // MARK: - 预设
    var presetsURL: URL {
        #if PHOS_QA
        return QAWorkspace.presetsURL
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Phos/presets.json")
        #endif
    }

    /// 读取新目录；首次改名时兼容旧版预设目录。
    private var legacyPresetsURL: URL {
        presetsURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RawForge/presets.json")
    }

    func loadPresets() -> [Preset] {
        #if PHOS_QA
        let urls = [presetsURL]
        #else
        let urls = [presetsURL, legacyPresetsURL]
        #endif
        for url in urls {
            guard let d = try? Data(contentsOf: url),
                  let ps = try? JSONDecoder().decode([Preset].self, from: d) else { continue }
            return ps
        }
        return defaultPresets
    }

    @discardableResult
    func savePresets(_ ps: [Preset]) -> Bool {
        let fm = FileManager.default
        let dir = presetsURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(ps)
            try data.write(to: presetsURL, options: .atomic)
            return true
        } catch {
            workflowError = "预设保存失败：\n\(error.localizedDescription)"
            return false
        }
    }
    let defaultPresets: [Preset] = {
        var a = EditParams(); a.contrast = 12; a.clarity = 15; a.vibrance = 12
        var b = EditParams(); b.mono = true; b.contrast = 18; b.clarity = 20
        var c = EditParams(); c.shadows = 35; c.blacks = -10; c.clarity = 10
        return [Preset(name: "通透", params: a, builtin: true),
                Preset(name: "黑白", params: b, builtin: true),
                Preset(name: "提亮暗部", params: c, builtin: true)]
    }()

    // MARK: - 多重曝光合成
    /// 全分辨率合成多个曝光帧，写成 16 位 TIFF 落盘，并插进浏览器里以便继续调色
    func mergeExposures(_ urls: [URL]) async {
        guard urls.count >= 2 else {
            status = "至少选 2 张才能合成（现在 \(urls.count) 张）"
            return
        }
        mergeRunning = true
        mergeProgress = "解码 \(urls.count) 张…"
        let mode = mergeMode
        // 降噪模式必须对齐；其余按开关
        let doAlign = alignEnabled || mode == .denoise
        let am = alignMethod

        let dest: (url: URL, dropped: Int, used: Int)? = await Task.detached(priority: .userInitiated) {
            var frames: [CIImage] = []
            for u in urls {
                autoreleasepool {
                    if let ci = Engine.decode(u) { frames.append(ci) }
                }
            }
            var dropped = 0
            if doAlign {
                await MainActor.run { self.mergeProgress = "对齐帧（Vision 注册 + 质量门）…" }
                let outcome = Engine.alignFrames(frames, method: am, threshold: 0.7)
                frames = outcome.frames
                dropped = outcome.dropped
            }
            guard frames.count >= 2 else { return nil }
            let frameCount = frames.count
            await MainActor.run { self.mergeProgress = "融合 \(frameCount) 帧…" }
            guard let merged = Engine.fuse(frames, mode: mode) else { return nil }
            let first = urls[0].deletingPathExtension()
            let out = first.deletingLastPathComponent()
                .appendingPathComponent(first.lastPathComponent + "_合成.tif")
            do { try Engine.write16(merged, to: out) } catch { return nil }
            return (out, dropped, frames.count)
        }.value

        guard let dest else {
            mergeRunning = false
            mergeProgress = ""
            status = "合成失败：对齐质量门后有效帧不足，或解码/写盘出错"
            return
        }

        // 结果若在当前文件夹里，插进列表并选中
        if let f = folder, dest.url.deletingLastPathComponent().standardizedFileURL == f.standardizedFileURL {
            let previousID = current?.id
            var it = PhotoItem(url: dest.url)
            if let sc = SidecarStore.load(for: dest.url) { it.rating = sc.rating; it.picked = sc.picked }
            items.append(it)
            items.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            currentIndex = items.firstIndex(where: { $0.id == previousID }) ?? -1
            sourceCache[dest.url] = nil
            if let idx = items.firstIndex(where: { $0.url == dest.url }) {
                select(idx)
                let u = dest.url
                let id = items[idx].id
                let cg = await Task.detached { Self.thumb(for: u) }.value
                if let cg, let index = items.firstIndex(where: { $0.id == id }) { items[index].thumb = cg }
            }
        }
        mergeRunning = false
        mergeProgress = ""
        showMerge = false
        if dest.dropped > 0 {
            status = "已合成 \(dest.used) 张（剔除 \(dest.dropped) 张对齐不合格）→ \(dest.url.lastPathComponent)"
        } else {
            status = "已合成 \(dest.used) 张 → \(dest.url.lastPathComponent)"
        }
    }

    func mergePicked() async {
        let picked = items.filter { $0.picked }.map { $0.url }
        guard picked.count >= 2 else {
            status = "请先在浏览器里标记至少 2 张（右下「标记」按钮）"
            return
        }
        await mergeExposures(picked)
    }

    // MARK: - 导出
    func exportCurrent(to url: URL) {
        startExport(to: url, foreground: nil)
    }

    /// 主体抠图导出：渲染整图 → 用「主体抠图」蒙版做 alpha → 透明背景落盘（PNG/TIFF）
    func exportCutout(to url: URL) {
        guard let fm = params.masks.first(where: { $0.kind == .foreground && $0.enabled })
        else {
            status = "没有可用的「主体抠图」蒙版，先在局部调整里新建一个"
            return
        }
        startExport(to: url, foreground: fm)
    }

    private func startExport(to url: URL, foreground: Mask?) {
        guard let src = source, !exportRunning else { return }
        let parameters = params, settings = exportSettings
        exportRunning = true
        status = "正在导出 \(url.lastPathComponent)…"
        Task {
            let error: String? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    var rendered = Engine.render(src, parameters)
                    if let foreground {
                        guard let mask = Engine.maskImage(for: foreground, extent: rendered.extent,
                                                          analyzed: rendered) else {
                            return "抠图蒙版计算失败"
                        }
                        let alphaMask = mask.applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0)
                        ])
                        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                            .cropped(to: rendered.extent)
                        rendered = rendered.applyingFilter("CIBlendWithAlphaMask", parameters: [
                            kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: alphaMask
                        ])
                    }
                    do {
                        try Engine.write(rendered, to: url, settings: settings)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }.value
            exportRunning = false
            status = error.map { "导出失败：\($0)" } ?? "已导出 \(url.lastPathComponent)"
        }
    }

    func batchExport(to dir: URL, onlyPicked: Bool) async {
        guard !batchRunning else { return }
        let list = items.filter { !onlyPicked || $0.picked }
        guard !list.isEmpty else {
            status = "没有符合条件的照片可导出"
            return
        }
        guard saveCurrent() else { return }
        batchRunning = true
        batchProgress = 0
        let settings = exportSettings
        var failed = 0
        for (i, it) in list.enumerated() {
            guard !Task.isCancelled else {
                batchRunning = false
                status = "批量导出已取消"
                return
            }
            let ext = settings.format
            let dest = dir.appendingPathComponent(it.url.deletingPathExtension().lastPathComponent + ".\(ext)")
            let error = await Task.detached(priority: .userInitiated) {
                Self.exportBatchItem(it.url, to: dest, settings: settings)
            }.value
            if error != nil { failed += 1 }
            batchProgress = Double(i + 1) / Double(max(list.count, 1))
        }
        batchRunning = false
        status = failed == 0
            ? "批量导出完成：\(list.count) 张"
            : "批量导出完成：成功 \(list.count - failed) 张，失败 \(failed) 张"
    }

    nonisolated private static func exportBatchItem(_ url: URL, to dest: URL,
                                                 settings: ExportSettings) -> String? {
        autoreleasepool {
            guard let src = Engine.decode(url) else { return "无法解码" }
            let params = SidecarStore.load(for: url)?.params ?? EditParams()
            let rendered = Engine.render(src, params)
            do {
                try Engine.write(rendered, to: dest, settings: settings)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}

#if PHOS_TESTING
extension AppState {
    func installPreviewFixture(_ image: CGImage, extent: CGRect) {
        let key = PreviewFrameKey(photoID: current?.id ?? UUID(), revision: 0, purpose: .edited,
                                  paramsFingerprint: PreviewFrame.fingerprint(params))
        previewFrame = PreviewFrame(key: key, image: image, mask: nil, maskID: nil,
                                    histogram: Engine.histogram(CIImage(cgImage: image)),
                                    renderExtent: extent, editedExtent: extent, proxyScale: 1, fullResolution: true)
    }
}
#endif

#if !PHOS_TESTING && !PHOS_APPEARANCE_TEST
@main
struct PhosApp: App {
    @NSApplicationDelegateAdaptor(PhosAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        #if PHOS_QA
        UserDefaults.standard.register(defaults: ["updateCheckDisabled": true])
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceWindow(state: state)
                .environmentObject(state)
                #if PHOS_QA
                .onAppear {
                    if state.folder == nil { state.openFolder(QAWorkspace.fixtureFolder) }
                }
                #endif
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            #if PHOS_QA
            CommandMenu("QA") {
                Button("平台基线检查…") { QAPlatformBaselineController.shared.show() }
                    .keyboardShortcut("b",modifiers:[.command,.option])
                Button("切换工作区应急材料") {
                    let defaults = UserDefaults.standard
                    defaults.set(!defaults.bool(forKey: "phos.ui.disableNativeGlass"), forKey: "phos.ui.disableNativeGlass")
                }
                Button("测试工作区错误提示") { state.workflowError = "R2-A QA：窗口级错误路由验证。" }
            }
            #endif
            WorkspaceMenuCommands(state: state, history: state.history)
        }
    }

}
#endif
